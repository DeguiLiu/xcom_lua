-- render_probe.lua - boots the real window and reports whether ImGui
-- frames actually RENDER (draw + present succeed) plus the pixel color
-- readback test via GDI on the client area.  Headless-friendly verdict.
if arg and arg[0] and arg[0]:sub(1, 1) ~= "@" then
    local dir = arg[0]:match("^(.*[/\\])") or "."
    package.path = dir .. "../core/?.ljbc;" .. dir .. "../ui/?.ljbc;" ..
                   dir .. "../core/?.lua;" .. dir .. "../ui/?.lua;" .. package.path
end
local config = require("config")
local window = require("window")
local w = require("win32")
local uv = require("luv")

w.load()
if jit and jit.off then jit.off() end

local APP = ".."
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
    io.stderr:write("init failed: " .. tostring(win) .. "\n"); os.exit(2)
end
if not win:init_window() then
    io.stderr:write("window create failed\n"); os.exit(2)
end

-- Instrument: count rendered frames (render() true) for 3 seconds.
local frames = { new_frame = 0, drawn = 0, presented = 0 }
local real_render = win.render_imgui
win.render_imgui = function(self)
    local now = uv.now()
    if self._imgui_next_frame and now < self._imgui_next_frame then return end
    if self.imgui and self.imgui:frame() then
        frames.new_frame = frames.new_frame + 1
        -- draw without action side effects
        self.imgui:draw(self.connected and 1 or 0, self._rx_bytes or 0,
            self._tx_bytes or 0)
        frames.drawn = frames.drawn + 1
        if self.imgui:render() then
            frames.presented = frames.presented + 1
        end
        self._imgui_next_frame = uv.now() + 500
    end
end

-- Read back the CENTER pixel of the client area through GDI (independent
-- of screen capture): if WARP presented the ImGui dashboard, the center
-- is a light panel color, not the dark window-class background.
local ffi = require("ffi")
local function center_pixel()
    local hdc = w.user32.GetDC(win.hwnd)
    if not hdc or hdc == nil then return nil end
    local cr = ffi.new("COLORREF[1]")
    -- GetPixel
    local g = w.gdi32
    if g.GetPixel == nil then
        w.user32.ReleaseDC(win.hwnd, hdc)
        return nil, "GetPixel not declared"
    end
    cr[0] = g.GetPixel(hdc, 460, 300)
    w.user32.ReleaseDC(win.hwnd, hdc)
    return tonumber(cr[0])
end

win:start()
local t0 = uv.now()
local probe_timer = uv.new_timer()
win._probe_timer = probe_timer
probe_timer:start(3000, 0, function()
    local px = center_pixel()
    print(string.format("PROBE new_frame=%d drawn=%d presented=%d center_pixel=%s",
        frames.new_frame, frames.drawn, frames.presented,
        px and string.format("0x%06X", px) or "n/a"))
    os.exit(0)
end)
return win:run()
