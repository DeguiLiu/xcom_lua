--[[--------------------------------------------------------------------------
e2e_com3_receive.lua - real-hardware receive E2E for the INCREMENTAL append
display path (xcom_imgui_receive_append).

Opens a REAL window (init + start, exactly like the shipping entry) with
XCOM_SMOKE_HW_PORT=<port> so Window:start() issues the same core_open the
"打开" button uses.  A peer process streams marker lines into the port; the
C read thread -> ring -> 10 ms drain -> charset passthrough ->
_append_imgui_receive -> DLL append chain then moves them with no Lua-side
tail copy.  Verification reads the view back through the SAME export the
Save-visible button uses (xcom_imgui_get_receive_text), proving end to end
that production hardware bytes reached the native window.

Usage (the peer sender must be running or start shortly after):
  set XCOM_SMOKE_HW_PORT=COM3
  runtime\luvjit.exe tests\e2e_com3_receive.lua [seconds]

Exit 0 = markers observed + sane stats; 1 = failure.
------------------------------------------------------------------------]]--

if arg and arg[0] and arg[0]:sub(1, 1) ~= "@" then
    local dir = arg[0]:match("^(.*)[/\\]") or "."
    local root
    if dir == "tests" then root = "." else root = dir:gsub("[/\\]tests$", "") end
    package.path = root .. "/core/?.lua;" .. root .. "/ui/?.lua;" .. package.path
end

local config = require("config")
local window = require("window")
local w = require("win32")
local uv = require("luv")

w.load()

local port = os.getenv("XCOM_SMOKE_HW_PORT")
if not port or port == "" then
    print("SKIP: set XCOM_SMOKE_HW_PORT=COMx (real port with a peer sender)")
    os.exit(0)
end
local seconds = tonumber(arg and arg[1]) or 12

local APP = "."
local cfg_data = config.load(APP .. "/config.ini")
local cfg = {
    window = { x = 40, y = 40, w = 920, h = 650 },
    port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
    parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
    receive_hex = false, timestamp = false, pause_display = false,
    auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
    auto_save = false, save_path = "", always_on_top = false,
    receive_window_bytes = 65536,
    send_hex = false, send_crlf = false, autosend_period_ms = 0,
    quick_pages = { { text = {}, enabled = {} } },
    quick = { text = {}, enabled = {} },
}

local ok, win = pcall(window.new, cfg, cfg_data, APP .. "/config.ini")
if not (ok and win) then
    io.stderr:write("init failed: " .. tostring(win) .. "\n")
    os.exit(1)
end
if not win:init_window() then
    io.stderr:write("window create failed\n")
    os.exit(1)
end
-- start() wires the drain/status timers AND runs _smoke_env_hooks, which
-- opens `port` through the production core_open path (XCOM_SMOKE_HW_PORT).
win:start()

assert(win.imgui and win.imgui:can_append_receive(),
    "DLL lacks xcom_imgui_receive_append — rebuild runtime/xcom_imgui.dll")

local t0 = uv.now()
local saw_connected = false
local markers = 0
local lines_total = 0
local sent = 0

-- The device on COM3 is an interactive console (msh): it ECHOES input and
-- answers with its own lines, so the marker written by this test comes back
-- through the real read thread.  This also exercises the production TX path.
local send_timer = uv.new_timer()
local function send_marker()
    if not win.connected then return end
    sent = sent + 1
    win:core_send(("HW-SEQ-%03d\r\n"):format(sent), 0)
end
jit.off(send_marker, true)
send_marker()
send_timer:start(300, 300, send_marker)

local check_timer = uv.new_timer()
local function check()
    if win.connected then saw_connected = true end
    if not saw_connected then return end
    local text = win.imgui:get_receive_text()
    if text and text ~= "" then
        local n = select(2, text:gsub("HW%-SEQ%-%d+", ""))
        if n and n > markers then markers = n end
        lines_total = select(2, text:gsub("\n", "")) or 0
    end
end
jit.off(check, true)
check_timer:start(250, 250, check)

local done_timer = uv.new_timer()
local function finish()
    done_timer:stop()
    send_timer:stop(); send_timer:close()
    check_timer:stop(); check_timer:close()
    done_timer:close()
    local secs = (uv.now() - t0) / 1000
    print(string.format("connected:      %s", saw_connected and "yes" or "NO"))
    print(string.format("rx_total(Lua):  %d bytes", win._imgui_receive_total or 0))
    local view, base = win.imgui:get_receive_text()
    view = view or ""
    print(string.format("native tail:    %d B, base=%d", #view, base or 0))
    print(string.format("markers sent:   %d", sent))
    print(string.format("markers seen:   %d (echoed lines in view: %d)", markers, lines_total))
    print(string.format("Lua heap:       %.1f KiB after %d s", collectgarbage("count"), secs))
    local pass = saw_connected and markers > 0
    print(pass and "E2E_COM3_RECEIVE: PASS" or "E2E_COM3_RECEIVE: FAIL")
    win:on_close()
    os.exit(pass and 0 or 1)
end
jit.off(finish, true)
done_timer:start(seconds * 1000, 0, finish)

return win:run()
