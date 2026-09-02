--[[--------------------------------------------------------------------------
preview_rx.lua - DRY-UI preview: paints a streaming mock receive log into the
ImGui dashboard WITHOUT a real serial port, so the receive-region layout can
be reviewed visually before touching hardware.

It reuses ui/window but asks it to run and, instead of opening a COM port,
appends mock line-frames into the same _imgui_receive buffer the drain would
fill.  A luv timer pads a growing 64 KiB log with a repeating motorframe
pattern; render_imgui pushes it via set_receive_text on the next dirty flush.

Usage (Windows): runtime\luvjit.exe preview_rx.lua [--plain|--ansi]
------------------------------------------------------------------------]]--

if arg and arg[0] and arg[0]:sub(1, 1) ~= "@" then
    local dir = arg[0]:match("^(.*)[/\\]") or "."
    package.path = dir .. "/core/?.lua;" .. dir .. "/ui/?.lua;" ..
                   package.path
end

local config = require("config")
local window = require("window")
local w = require("win32")
local uv = require("luv")
local xcom = require("xcom_ffi")

w.load()
if jit and jit.off then jit.off() end

-- ---- mock rx frame builder ---------------------------------------------
local USE_ANSI = arg and (arg[1] == "--ansi")
local lines = {}
if USE_ANSI then
    -- A simple rotating line generator that emits a few SGR-coloured lines
    -- so coloured receive rendering (if any) can also be inspected.
    local pal = {
        "\27[31m", "\27[32m", "\27[33m", "\27[36m", "\27[34m", "\27[35m",
    }
    for i = 1, 4 do lines[i] = "  [blk " .. tostring(i) .. "]"
        for j = 0, 5 do
            lines[i] = lines[i] .. " " .. pal[(i + j) % #pal + 1] .. "0x" ..
                       string.format("%04X", (i * 977 + j * 31) % 65536) ..
                       "\27[0m"
        end
        lines[i] = lines[i] .. "\r\n"
    end
else
    -- Readable pseudo-packet dump (resembles a real AT / binary-log tail).
    for i = 1, 6 do
        lines[i] = string.format(
            "[%02d:%02d:%02d.%03d] RX %04d B  dst=0x%02X  seq=%03d\n",
            (i * 3) % 24, (i * 7) % 60, (i * 11) % 60, (i * 977) % 1000,
            (i * 137) % 4096, (i * 51) % 256, i)
    end
end

local function mock_chunk()
    -- Repeat the frame lines with a changing header so the buffer fills and
    -- wraps like a real live stream over the 64 KiB window.
    local acc = {}
    for _ = 1, 12 do
        for _, ln in ipairs(lines) do acc[#acc + 1] = ln end
    end
    return table.concat(acc)
end

-- ---- minimal window startup --------------------------------------------
local APP = "."
local cfg_data = config.load(APP .. "/config.ini")
local cfg = {
    window = { x = 40, y = 40, w = 920, h = 650 },
    port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
    parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
    receive_hex = false, timestamp = true, pause_display = false,
    auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
    auto_save = false, save_path = "", always_on_top = false,
    send_hex = false, send_crlf = false, autosend_period_ms = 0,
    quick_pages = { { text = {}, enabled = {} } },
    quick = { text = {}, enabled = {} },
}

local ok, win = pcall(window.new, cfg, cfg_data, APP .. "/config.ini")
if not (ok and win) then
    io.stderr:write("preview init failed: " .. tostring(win) .. "\n")
    os.exit(2)
end
if not win:init_window() then
    io.stderr:write("preview window create failed\n")
    os.exit(2)
end
-- Do not try to open a real port in preview; the dashboard renders offline.
-- win:start() would create an xcom handle + poll timers against empty core.

-- ---- stream mock data into the same receive buffer ----------------------
-- Each tick appends ~REPEAT lines (a few KiB).  Bigger still lands under the
-- 64 KiB software cap; _append_imgui_receive trims old head as it grows, so
-- running this lets the receive region show a *rolling* live tail.
local REPEAT = 60           -- mock "line" per tick (bytes read shape)
local append_all = function()
    local buf = {}
    for _ = 1, REPEAT do buf[#buf + 1] = mock_chunk() end
    win:_append_imgui_receive(table.concat(buf))
end

-- Seed a full viewport first so the very first frame is not near-empty:
-- append several ticks before entering the run loop.
for _ = 1, 14 do append_all() end

-- Let render_imgui() flush via its own dirty flag each 16 ms frame; hitting
-- the 64 KiB ceiling then wraps the oldest bytes so the log keeps scrolling.
local tick_timer = uv.new_timer()
-- keep a strong reference so libuv does not GC it mid-run
win._mock_tick = tick_timer
tick_timer:start(12, 12, append_all)

-- Next frame will flush whatever the seed already appended.
return win:run()
