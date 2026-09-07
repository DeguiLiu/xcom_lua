--[[--------------------------------------------------------------------------
core/waveform.lua - Lua-driven Win32 GDI oscilloscope popup (pic/3.png style).

A standalone overlapped window (class "XComWave") painted entirely from Lua
via GDI — the same proven pattern as the legacy ui/receive_view.lua path, so
it needs ZERO native-side changes and works today.  The main window's message
loop (window.lua run_message_loop) pumps all thread messages with
PeekMessageW(msg, nil, ...), so this popup receives paint/input without any
loop modification.

Visual model (reference pic/3.png):
  * dark background + major/minor grid;
  * one polyline per series in its configured colour;
  * right-edge channel labels with live last value;
  * left margin Y scale, bottom time scale;
  * follow-tail auto-scroll, wheel/drag pan for look-back (回看);
  * F12 / "Snap" button -> 24-bpp BMP screenshot via BitBlt + GetDIBits +
    core/bmp_writer.lua.

Data model: per-series fixed ring (capacity points, default 65536).  push()
appends {x, y}; x defaults to sys.now() ms.  Rendering walks only the VISIBLE
x window of the ring (two index bounds), so cost is proportional to pixels,
not history.

Script API (exposed by script_engine as `wave`):
  wave.config{title=..., series={{name=,color=0xRRGGBB,min=,max=},...}}
  wave.push(series, y)          -- series = 1-based index or name; x = now
  wave.push(series, x, y)       -- explicit x (ms)
  wave.show() / wave.hide() / wave.visible()
  wave.clear()                  -- drop all points
  wave.set_follow(bool)         -- auto-scroll to newest (default true)
  wave.snapshot([path]) -> path -- BMP screenshot
------------------------------------------------------------------------]]--

local ffi = require("ffi")

local M = { _version = 1 }

local ok_uv, uv = pcall(require, "luv")
if not ok_uv then uv = nil end

local bmp_writer_ok, bmp_writer = pcall(require, "bmp_writer")
if not bmp_writer_ok then bmp_writer = nil end

-- ---- ImPlot scope backend (optional dual-render path) -----------------------
-- When the xcom_imgui DLL exports the scope API, every wave.push ALSO feeds
-- the in-dashboard ImPlot panel (xcom_imgui_scope_push), and show()/hide()
-- toggle that panel.  The GDI popup remains available for a detached window
-- with screenshot; scripts do not need to know which backend is active.
local scope_push, scope_clear, scope_set_visible
do
    local probe_ok, imgui_lib = pcall(function()
        local f = require("ffi")
        return f.load("xcom_imgui")
    end)
    if probe_ok then
        local f = require("ffi")
        local ok1, p = pcall(function() return imgui_lib.xcom_imgui_scope_push end)
        local ok2, c = pcall(function() return imgui_lib.xcom_imgui_scope_clear end)
        local ok3, v = pcall(function()
            return imgui_lib.xcom_imgui_scope_set_visible
        end)
        if ok1 and p then scope_push = p end
        if ok2 and c then scope_clear = c end
        if ok3 and v then scope_set_visible = v end
    end
end

-- ---------------------------------------------------------------------------
-- Constants / palette
-- ---------------------------------------------------------------------------

local CAPACITY = 65536            -- points per series ring
local WND_CLASS = "XComWave"
local DEFAULT_W, DEFAULT_H = 900, 480
local MARGIN_L, MARGIN_R, MARGIN_T, MARGIN_B = 56, 96, 12, 26
local REPAINT_MS = 33             -- ~30 FPS while visible

local COLOR = {
    bg      = 0x00141419,         -- COLORREF (BGR): near-black
    grid    = 0x00303038,
    grid_hi = 0x00484850,
    text    = 0x00C8C8D0,
    text_hi = 0x00E8E8F0,
    cursor  = 0x00FF9800,
}

local SERIES_DEFAULTS = {
    { name = "CH0", color = 0x00CC66 },   -- 0xRRGGBB
    { name = "CH1", color = 0x6699FF },
    { name = "CH2", color = 0xFF5555 },
    { name = "CH3", color = 0xFFCC00 },
    { name = "CH4", color = 0xAA66FF },
    { name = "CH5", color = 0x66DDDD },
}

-- Module state (single popup; a second config reconfigures in place).
local state = nil

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

-- 0xRRGGBB -> COLORREF 0x00BBGGRR
local function cref(rgb)
    local r = math.floor(rgb / 65536) % 256
    local g = math.floor(rgb / 256) % 256
    local b = rgb % 256
    return r + g * 256 + b * 65536
end

local function now_ms()
    if uv then return uv.now() end
    return math.floor((os.clock()) * 1000)
end

-- ---------------------------------------------------------------------------
-- Ring buffer (per series): plain arrays x[], y[], head, count.
-- ---------------------------------------------------------------------------

local function ring_new()
    return { x = {}, y = {}, head = 1, count = 0, last_y = nil }
end

local function ring_push(ring, x, y)
    local slot = (ring.head - 1 + ring.count) % CAPACITY + 1
    ring.x[slot] = x
    ring.y[slot] = y
    if ring.count < CAPACITY then
        ring.count = ring.count + 1
    else
        ring.head = (ring.head % CAPACITY) + 1
    end
    ring.last_y = y
end

-- Physically iterate [first, last] (1-based logical indices) of the ring.
local function ring_iter(ring, first, last)
    local i = first
    return function()
        if i > last then return nil end
        local slot = (ring.head - 2 + i) % CAPACITY + 1
        local x, y = ring.x[slot], ring.y[slot]
        i = i + 1
        return x, y
    end
end

-- Binary-search the smallest logical index with x >= target (ring is time-
-- ordered by construction).  Returns clamp(1, count).
local function ring_lower_bound(ring, target)
    local lo, hi = 1, ring.count
    while lo < hi do
        local mid = math.floor((lo + hi) / 2)
        local slot = (ring.head - 2 + mid) % CAPACITY + 1
        if ring.x[slot] < target then lo = mid + 1 else hi = mid end
    end
    return lo
end

local function ring_clear(ring)
    ring.x, ring.y, ring.head, ring.count = {}, {}, 1, 0
    ring.last_y = nil
end

-- ---------------------------------------------------------------------------
-- Module-level WndProc (module-reachable so the FFI closure upvalue never
-- gets collected; pcall discipline identical to window.lua's WndProc).
-- ---------------------------------------------------------------------------

local WndProcCallback
local bit = require("bit")

local function dispatch(msg, wparam, lparam)
    local s = state
    if not s then return 0 end
    local w = require("win32")
    local wm = w.wm
    if msg == wm.WM_PAINT then
        local ps = ffi.new("PAINTSTRUCT")
        local hdc = w.gdi32.BeginPaint(s.hwnd, ps)
        if hdc ~= nil then
            local ok, err = pcall(M._paint, s, hdc)
            if not ok then io.stderr:write("[wave] paint: " .. tostring(err) .. "\n") end
            w.gdi32.EndPaint(s.hwnd, ps)
        end
        return 0
    elseif msg == wm.WM_ERASEBKGND then
        return 1  -- _paint fills everything; skipping avoids flicker
    elseif msg == wm.WM_SIZE then
        s.width = bit.band(lparam, 0xFFFF)
        s.height = bit.rshift(lparam, 16)
        if s.width == 0 then s.width = DEFAULT_W end
        if s.height == 0 then s.height = DEFAULT_H end
        w.user32.InvalidateRect(s.hwnd, nil, 0)
        return 0
    elseif msg == wm.WM_MOUSEWHEEL then
        -- Horizontal pan on wheel: one notch = 120 -> 1/8 viewport.
        local delta = bit.tobit(bit.rshift(wparam, 16))
        M._pan(s, -delta * (s.view_ms or 10000) / (120 * 8))
        return 0
    elseif msg == wm.WM_MOUSEHWHEEL then
        local delta = bit.tobit(bit.rshift(wparam, 16))
        M._pan(s, delta * (s.view_ms or 10000) / (120 * 8))
        return 0
    elseif msg == wm.WM_LBUTTONDOWN then
        s.dragging = true
        s.drag_x = bit.band(lparam, 0xFFFF)
        w.user32.SetCapture(s.hwnd)
        return 0
    elseif msg == wm.WM_MOUSEMOVE then
        if s.dragging then
            local x = bit.band(lparam, 0xFFFF)
            local dx_pixels = x - s.drag_x
            s.drag_x = x
            local px_per_ms = (s.plot_w > 0) and (s.view_ms / s.plot_w) or 0
            M._pan(s, -dx_pixels * px_per_ms)
        end
        return 0
    elseif msg == wm.WM_LBUTTONUP then
        s.dragging = false
        w.user32.ReleaseCapture()
        return 0
    elseif msg == wm.WM_KEYDOWN then
        local vk = bit.band(wparam, 0xFF)
        if vk == 0x77 then        -- F12: snapshot
            M.snapshot()
        elseif vk == 0x27 then    -- RIGHT: nudge forward
            M._pan(s, (s.view_ms or 10000) / 8)
        elseif vk == 0x25 then    -- LEFT: nudge back
            M._pan(s, -(s.view_ms or 10000) / 8)
        end
        return 0
    elseif msg == wm.WM_CLOSE or msg == wm.WM_DESTROY then
        -- Hide, don't destroy: scripts may re-show() later.
        M.hide()
        return 0
    end
    return w.user32.DefWindowProcA(s.hwnd, msg, wparam, lparam)
end

-- ---------------------------------------------------------------------------
-- Painting
-- ---------------------------------------------------------------------------

function M._pan(s, delta_ms)
    local newest = M._newest_x(s)
    local span = s.view_ms or 10000
    -- Clamp pan so the view stays within [oldest, newest] (at most one empty
    -- screen of look-back beyond the oldest sample).
    local oldest = M._oldest_x(s)
    local target = (s.view_end or newest) + delta_ms
    local min_end = oldest + span
    if newest < min_end then min_end = newest end
    if target > newest then target = newest end
    if target < min_end then target = min_end end
    if target ~= s.view_end then
        s.view_end = target
        s.follow = false
        require("win32").user32.InvalidateRect(s.hwnd, nil, 0)
    end
end

function M._newest_x(s)
    local newest = nil
    for i = 1, #s.rings do
        local ring = s.rings[i]
        if ring.count > 0 then
            local slot = (ring.head - 2 + ring.count) % CAPACITY + 1
            local x = ring.x[slot]
            if newest == nil or x > newest then newest = x end
        end
    end
    return newest or now_ms()
end

function M._oldest_x(s)
    local oldest = nil
    for i = 1, #s.rings do
        local ring = s.rings[i]
        if ring.count > 0 then
            local slot = ring.head
            local x = ring.x[slot]
            if oldest == nil or x < oldest then oldest = x end
        end
    end
    return oldest or now_ms()
end

-- Full scene paint into the window DC (double-buffered via a compatible DC).
function M._paint(s, hdc)
    local w = require("win32")
    local g = w.gdi32
    local width, height = s.width or DEFAULT_W, s.height or DEFAULT_H
    local plot_w = width - MARGIN_L - MARGIN_R
    local plot_h = height - MARGIN_T - MARGIN_B
    if plot_w < 10 or plot_h < 10 then return end
    s.plot_w = plot_w

    local mem = g.CreateCompatibleDC(hdc)
    local bmp = g.CreateCompatibleBitmap(hdc, width, height)
    local old_bmp = g.SelectObject(mem, bmp)

    local bg_brush = g.CreateSolidBrush(COLOR.bg)
    local rc = ffi.new("RECT")
    rc.left, rc.top, rc.right, rc.bottom = 0, 0, width, height
    g.FillRect(mem, rc, bg_brush)
    g.DeleteObject(bg_brush)

    -- ---- grid ----------------------------------------------------------
    local grid_pen = g.CreatePen(w.gdi.PS_SOLID, 1, COLOR.grid)
    local grid_hi_pen = g.CreatePen(w.gdi.PS_SOLID, 1, COLOR.grid_hi)
    local old_pen = g.SelectObject(mem, grid_pen)
    local COLS, ROWS = 10, 8
    for i = 0, COLS do
        local x = MARGIN_L + math.floor(plot_w * i / COLS + 0.5)
        g.SelectObject(mem, i % 5 == 0 and grid_hi_pen or grid_pen)
        g.MoveToEx(mem, x, MARGIN_T, nil)
        g.LineTo(mem, x, MARGIN_T + plot_h)
    end
    for i = 0, ROWS do
        local y = MARGIN_T + math.floor(plot_h * i / ROWS + 0.5)
        g.SelectObject(mem, i % 4 == 0 and grid_hi_pen or grid_pen)
        g.MoveToEx(mem, MARGIN_L, y, nil)
        g.LineTo(mem, MARGIN_L + plot_w, y)
    end
    g.SelectObject(mem, old_pen)
    g.DeleteObject(grid_pen)
    g.DeleteObject(grid_hi_pen)

    -- ---- view window ----------------------------------------------------
    local newest = M._newest_x(s)
    local view_ms = s.view_ms or 10000
    if s.follow or s.view_end == nil then s.view_end = newest end
    local view_end = s.view_end
    local view_begin = view_end - view_ms

    -- ---- series ---------------------------------------------------------
    local old_bk = g.SetBkMode(mem, w.opa.TRANSPARENT)
    for i = 1, #s.rings do
        local ring = s.rings[i]
        if ring.count > 1 then
            local series = s.series[i]
            local ymin, ymax = series.min, series.max
            -- Auto-scale when the series has no fixed range.
            if not ymin or not ymax then
                ymin, ymax = math.huge, -math.huge
                local first = ring_lower_bound(ring, view_begin)
                for x, y in ring_iter(ring, first, ring.count) do
                    if x > view_end then break end
                    if y < ymin then ymin = y end
                    if y > ymax then ymax = y end
                end
                if ymin == math.huge then ymin, ymax = -1, 1 end
                if ymin == ymax then ymin, ymax = ymin - 1, ymax + 1 end
                local pad = (ymax - ymin) * 0.08
                ymin, ymax = ymin - pad, ymax + pad
            end
            local yspan = ymax - ymin
            local pen = g.CreatePen(w.gdi.PS_SOLID, i == s.trace_series and 2 or 1,
                cref(series.color))
            g.SelectObject(mem, pen)
            local started = false
            local first = ring_lower_bound(ring, view_begin)
            for x, y in ring_iter(ring, first, ring.count) do
                if x > view_end then break end
                local px = MARGIN_L + (x - view_begin) * plot_w / view_ms
                local py = MARGIN_T + plot_h - (y - ymin) * plot_h / yspan
                if py < MARGIN_T then py = MARGIN_T end
                if py > MARGIN_T + plot_h then py = MARGIN_T + plot_h end
                if not started then
                    g.MoveToEx(mem, math.floor(px + 0.5), math.floor(py + 0.5), nil)
                    started = true
                else
                    g.LineTo(mem, math.floor(px + 0.5), math.floor(py + 0.5))
                end
            end
            g.SelectObject(mem, old_pen)
            g.DeleteObject(pen)
            -- Channel label + live value at the right margin.
            g.SetTextColor(mem, cref(series.color))
            local label = string.format("%s %s", series.name or ("CH" .. (i - 1)),
                ring.last_y ~= nil and string.format("%.3g", ring.last_y) or "-")
            g.TextOutA(mem, MARGIN_L + plot_w + 6, MARGIN_T + (i - 1) * 16,
                label, #label)
        end
    end

    -- ---- scales ----------------------------------------------------------
    g.SetTextColor(mem, COLOR.text)
    for i = 0, ROWS / 2 do
        local y = MARGIN_T + math.floor(plot_h * i * 2 / ROWS + 0.5)
        -- Only series 1's fixed range is labeled on the axis (auto-scale
        -- ranges differ per series); fixed ranges share ymin/ymax semantics.
        local series = s.series[1]
        local ymin, ymax = series.min or -1, series.max or 1
        local value = ymax - (ymax - ymin) * (i * 2 / ROWS)
        local label = string.format("%g", value)
        g.SetTextAlign(mem, w.textAlign.TA_RIGHT)
        g.TextOutA(mem, MARGIN_L - 4, y - 6, label, #label)
    end
    g.SetTextAlign(mem, w.textAlign.TA_LEFT)
    local span_label = string.format("%.1f s", view_ms / 1000)
    g.TextOutA(mem, MARGIN_L, MARGIN_T + plot_h + 6, span_label, #span_label)
    local end_label = os.date("%H:%M:%S", math.floor(view_end / 1000))
    g.SetTextAlign(mem, w.textAlign.TA_RIGHT)
    g.TextOutA(mem, MARGIN_L + plot_w, MARGIN_T + plot_h + 6, end_label, #end_label)
    g.SetTextAlign(mem, w.textAlign.TA_LEFT)
    if not s.follow then
        local hint = "LOOK-BACK  (wheel/drag pan, F12 snapshot)"
        g.SetTextColor(mem, COLOR.cursor)
        g.TextOutA(mem, MARGIN_L + math.floor(plot_w / 2) - 90, MARGIN_T + 4,
            hint, #hint)
    end

    g.SetBkMode(mem, old_bk)
    g.BitBlt(hdc, 0, 0, width, height, mem, 0, 0, w.gdi.SRCCOPY)
    g.SelectObject(mem, old_bmp)
    g.DeleteObject(bmp)
    g.DeleteDC(mem)
end

-- ---------------------------------------------------------------------------
-- Public API (script surface)
-- ---------------------------------------------------------------------------

function M.config(opts)
    opts = opts or {}
    local s = state
    if not s then
        s = {
            hwnd = nil,
            width = DEFAULT_W, height = DEFAULT_H,
            rings = {}, series = {},
            view_ms = 10000,        -- default 10 s window
            view_end = nil,
            follow = true,
            dragging = false, drag_x = 0,
            trace_series = 1,
            dirty = false,
            repaint_timer = nil,
            class_registered = false,
        }
        state = s
    end
    if opts.title then s.title = tostring(opts.title) end
    if opts.view_ms then s.view_ms = math.max(100, tonumber(opts.view_ms) or 10000) end
    if opts.series then
        s.series = {}
        s.rings = {}
        for i, spec in ipairs(opts.series) do
            local defaults = SERIES_DEFAULTS[i] or
                { name = "CH" .. (i - 1), color = 0xAAAAAA }
            s.series[i] = {
                name = tostring(spec.name or defaults.name),
                color = tonumber(spec.color) or defaults.color,
                min = spec.min and tonumber(spec.min) or nil,
                max = spec.max and tonumber(spec.max) or nil,
            }
            s.rings[i] = ring_new()
        end
    end
    -- Ensure at least one series exists.
    if #s.series == 0 then
        for i = 1, 2 do
            s.series[i] = { name = SERIES_DEFAULTS[i].name,
                color = SERIES_DEFAULTS[i].color, min = nil, max = nil }
            s.rings[i] = ring_new()
        end
    end
    M._ensure_repaint_timer()
end

local function series_index(s, key)
    if type(key) == "number" then
        local i = math.floor(key)
        if i >= 1 and i <= #s.rings then return i end
        return nil
    end
    if type(key) == "string" then
        for i, series in ipairs(s.series) do
            if series.name == key then return i end
        end
    end
    return nil
end

function M.push(key, a, b)
    local s = state
    if not s then return false end
    local i = series_index(s, key)
    if not i then return false end
    local x, y
    if b == nil then
        x, y = now_ms(), tonumber(a)
    else
        x, y = tonumber(a), tonumber(b)
    end
    if y == nil or x == nil then return false end
    ring_push(s.rings[i], x, y)
    -- Dual-backend: also feed the ImPlot scope panel (channel = the 1-based
    -- series index, x rescaled to seconds).  No-op when the DLL lacks it.
    if scope_push and i <= 4 then
        pcall(scope_push, i, x / 1000.0, y)
    end
    s.dirty = true
    if s.hwnd then
        -- Follow-tail windows repaint on the timer cadence; a panned view
        -- still needs the new data visible, so the timer handles both.
        M._ensure_repaint_timer()
    end
    return true
end

function M.clear()
    local s = state
    if not s then return end
    for _, ring in ipairs(s.rings) do ring_clear(ring) end
    if scope_clear then pcall(scope_clear) end
    s.view_end = nil
    if s.hwnd then
        require("win32").user32.InvalidateRect(s.hwnd, nil, 0)
    end
end

function M.set_follow(follow)
    local s = state
    if not s then return end
    s.follow = follow and true or false
    if s.follow then
        s.view_end = M._newest_x(s)
        if s.hwnd then
            require("win32").user32.InvalidateRect(s.hwnd, nil, 0)
        end
    end
end

function M.visible()
    return state ~= nil and state.hwnd ~= nil
end

-- ---- test/inspection hooks (pure data access; no Win32) ---------------------

function M._state_series()
    return state and state.series or {}
end

function M._state_counts()
    local out = {}
    if state then
        for i, ring in ipairs(state.rings) do out[i] = ring.count end
    end
    return out
end

function M._state_last()
    local out = {}
    if state then
        for i, ring in ipairs(state.rings) do out[i] = ring.last_y end
    end
    return out
end

function M.show()
    local s = state
    if not s then M.config({}) s = state end
    -- ImPlot panel first: it is the primary in-dashboard scope surface.
    if scope_set_visible then pcall(scope_set_visible, 1) end
    local w = require("win32")
    w.load()
    if not s.hwnd then
        if not s.class_registered then
            local wc = ffi.new("WNDCLASSA")
            WndProcCallback = WndProcCallback or (function()
                local cb = function(hwnd, msg, wp, lp)
                    local ok, result = pcall(dispatch, msg, wp, lp)
                    if not ok then
                        io.stderr:write("[wave wndproc] " .. tostring(result) .. "\n")
                        return 0
                    end
                    return tonumber(result) or 0
                end
                if jit and jit.off then jit.off(cb, true) end
                return ffi.new("WNDPROC", cb)
            end)()
            wc.lpfnWndProc = WndProcCallback
            wc.lpszClassName = WND_CLASS
            wc.hInstance = w.kernel32.GetModuleHandleA(nil)
            wc.hCursor = w.user32.LoadCursorA(nil, w.gdi.IDC_ARROW)
            w.user32.RegisterClassA(wc)
            s.class_registered = true
        end
        local style = w.style.WS_OVERLAPPED + w.style.WS_CAPTION +
            w.style.WS_SYSMENU + w.style.WS_THICKFRAME +
            w.style.WS_MINIMIZEBOX + w.style.WS_MAXIMIZEBOX
        s.hwnd = w.user32.CreateWindowExA(0, WND_CLASS,
            s.title or "XCOM Waveform", style,
            120, 120, s.width or DEFAULT_W, s.height or DEFAULT_H,
            nil, nil, w.kernel32.GetModuleHandleA(nil), nil)
        if not s.hwnd or s.hwnd == ffi.new("HWND[1]")[0] then
            s.hwnd = nil
            return false
        end
    end
    w.user32.ShowWindow(s.hwnd, w.style.SW_SHOW)
    w.user32.SetForegroundWindow(s.hwnd)
    w.user32.InvalidateRect(s.hwnd, nil, 0)
    M._ensure_repaint_timer()
    return true
end

function M.hide()
    local s = state
    if not s or not s.hwnd then return end
    require("win32").user32.ShowWindow(s.hwnd, 0)  -- SW_HIDE
    -- Keep data + class; the next show() reuses the window.
end

function M._ensure_repaint_timer()
    local s = state
    if not s or not uv or s.repaint_timer then return end
    local callback = function()
        if not s.hwnd then return end
        if s.dirty or s.follow then
            s.dirty = false
            require("win32").user32.InvalidateRect(s.hwnd, nil, 0)
        end
    end
    if jit and jit.off then jit.off(callback, true) end
    s.repaint_timer = uv.new_timer()
    s.repaint_timer:start(REPAINT_MS, REPAINT_MS, callback)
end

-- BMP screenshot of the current window content.
function M.snapshot(path)
    local s = state
    if not s or not s.hwnd then return nil, "waveform window not visible" end
    if not bmp_writer then return nil, "bmp_writer unavailable" end
    local w = require("win32")
    local g = w.gdi32
    local width, height = s.width or DEFAULT_W, s.height or DEFAULT_H

    local hdc_win = w.user32.GetDC(s.hwnd)
    if hdc_win == nil then return nil, "GetDC failed" end
    local mem = g.CreateCompatibleDC(hdc_win)
    local bmp = g.CreateCompatibleBitmap(hdc_win, width, height)
    local old_bmp = g.SelectObject(mem, bmp)

    local ok, err = pcall(M._paint, s, mem)
    local result_path
    if ok then
        -- Read the DIB bits (24 bpp, top-down requested then flipped by the
        -- writer which expects bottom-up storage).
        local bi = ffi.new("BITMAPINFO")
        local hdr = bi.bmiHeader
        hdr.biSize = ffi.sizeof("BITMAPINFOHEADER")
        hdr.biWidth = width
        hdr.biHeight = -height      -- top-down rows
        hdr.biPlanes = 1
        hdr.biBitCount = 24
        hdr.biCompression = w.gdi.BI_RGB
        local row = math.floor((width * 3 + 3) / 4) * 4   -- pad to 4
        local buf = ffi.new("uint8_t[?]", row * height)
        if g.GetDIBits(mem, bmp, 0, height, buf, bi, w.gdi.DIB_RGB_COLORS) ~= 0 then
            if not path then
                path = string.format("wave_%s.bmp", os.date("%Y%m%d_%H%M%S"))
            end
            local wok, werr = bmp_writer.save(path, width, height, buf, row)
            if wok then result_path = path else err = werr end
        else
            err = "GetDIBits failed"
        end
    end

    g.SelectObject(mem, old_bmp)
    g.DeleteObject(bmp)
    g.DeleteDC(mem)
    w.user32.ReleaseDC(s.hwnd, hdc_win)
    if not ok or not result_path then
        return nil, tostring(err)
    end
    return result_path
end

return M
