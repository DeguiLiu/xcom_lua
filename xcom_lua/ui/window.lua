--[[--------------------------------------------------------------------------
ui/window.lua - main window: frameless chrome, message loop, WndProc dispatch.

Single-thread serial console on Win32 (design §3).  One WndProc routes:

  * WM_NCHITTEST  -> drag (HTCAPTION) + edge resize (HTLEFT/..) on a frameless
    WS_POPUP window, and header-area hit test;
  * WM_PAINT      -> self-drawn header (brand chip, title, ON/OFFLINE badge,
    min/max/close);
  * WM_COMMAND    -> child-id dispatch into self._handlers[name](payload);
  * WM_TIMER      -> two ABI pollers: display drain (10 ms) and status
    snapshot (250 ms) — the single-thread open/close may block the UI;
  * WM_CTLCOLOR*  -> Siemens light theme brushes (page background, input white).

Panels are created as children of the main window and laid out on WM_SIZE.
On Linux this module is syntax-checked only; the Win32 host resolves the DLLs.
------------------------------------------------------------------------]]--

local ffi = require("ffi")
local uv = require("luv")
local bit = require("bit")

local w = require("win32")
local c = require("controls")
local conn_panel = require("connection_panel")
local recv_panel = require("receive_view")
local send_panel = require("send_panel")
local status_bar = require("status_bar")
local view_model = require("view_model")
local config = require("config")
local xcom = require("xcom_ffi")
local imgui_bridge = require("imgui_bridge")

-- Serial-config combo text -> ABI-int maps and helpers (declared up-front so
-- every method below closes over the same upvalues regardless of where in
-- the file it is defined; see the create_class forward-declaration note).
local STOP_MAP = { ["1"] = 0, ["1.5"] = 1, ["2"] = 2 }
local PARITY_MAP = { ["None"] = 0, ["Odd"] = 1, ["Even"] = 2, ["Mark"] = 3, ["Space"] = 4 }
local FLOW_MAP = { ["None"] = 0, ["HW (RTS/CTS)"] = 1, ["SW (XON/XOFF)"] = 2 }
local function stop_index(t) return STOP_MAP[t] or 0 end
local function parity_index(t) return PARITY_MAP[t] or 0 end
local function flow_index(t) return FLOW_MAP[t] or 0 end

-- The single active window captured by the WndProc callback.  Kept as a
-- module-level local so the FFI callback closure has one upvalue that stays
-- reachable for the whole process lifetime (never GC'd).
local Active = nil

-- Siemens light palette (Win32 COLORREF).
local PAL = {
    page    = w.rgb(0xee, 0xf1, 0xf4),  -- background #EEF1F4
    surface = w.rgb(0xff, 0xff, 0xff),  -- input/panel white
    text    = w.rgb(0x26, 0x32, 0x38),
    accent  = w.rgb(0x00, 0x78, 0xd7),  -- industrial blue
    trigger = w.rgb(0x00, 0x99, 0x99),  -- cyan-teal
    dark    = w.rgb(0x00, 0x5a, 0x9e),  -- deep blue
    online  = w.rgb(0x00, 0x80, 0x00),  -- status green
    danger  = w.rgb(0xc4, 0x00, 0x00),  -- close/red
    header  = w.rgb(0x00, 0x5a, 0x9e),  -- title bar bg
    btnface = w.rgb(0xf0, 0xf0, 0xf0),
}

-- WndProc: one __stdcall C callback; delegates to Active:dispatch.
-- The dispatch is wrapped in pcall so a Lua error inside a handler no longer
-- escapes the FFI callback boundary (which Windows turns into
-- STATUS_FATAL_USER_CALLBACK_EXCEPTION / exit code 0xC000041D, with no
-- diagnostic).  On error we print the offending message + error to stderr and
-- return 0 so the window can keep pumping messages during bring-up.
local wndproc_callback = function(hwnd, msg, wparam, lparam)
    local win = Active
    if not win then
        return 0
    end
    local ok, result = pcall(win.dispatch, win, hwnd, msg, wparam, lparam)
    if not ok then
        io.stderr:write(string.format(
            "[wndproc] error in dispatch msg=0x%04X: %s\n", tonumber(msg), tostring(result)))
        return 0
    end
    return tonumber(result) or 0
end
jit.off(wndproc_callback, true)
local WndProc = ffi.new("WNDPROC", wndproc_callback)

local Window = {}
Window.__index = Window
local M = {}

local IMGUI_ACTION = {
    open = 1,
    close = 2,
    clear = 4,
    send = 8,
    save_log = 16,
    send_enabled = 32,
    refresh_ports = 64,
    sync_settings = 128,
    sync_display = 256,
    previous_page = 512,
    next_page = 1024,
    add_page = 2048,
    remove_page = 4096,
    sync_multi_auto = 8192,
    sync_auto_save = 16384,
    choose_log_path = 32768,
    minimize = 65536,
    maximize = 131072,
    close_window = 262144,
    send_slot_0 = 524288,
    send_slot_1 = 1048576,
    send_slot_2 = 2097152,
    send_slot_3 = 4194304,
    send_slot_4 = 8388608,
    send_slot_5 = 16777216,
    send_slot_6 = 33554432,
    send_slot_7 = 67108864,
}

local IMGUI_COMMANDS = {
    { IMGUI_ACTION.open, "_imgui_open" },
    { IMGUI_ACTION.close, "_imgui_close" },
    { IMGUI_ACTION.clear, "on_btn_clear" },
    { IMGUI_ACTION.send, "_imgui_send_single" },
    { IMGUI_ACTION.save_log, "on_btn_save" },
    { IMGUI_ACTION.send_enabled, "_imgui_send_enabled" },
    { IMGUI_ACTION.refresh_ports, "_refresh_imgui_ports" },
    { IMGUI_ACTION.sync_settings, "_sync_imgui_autosend" },
    { IMGUI_ACTION.sync_display, "_push_display_options" },
    { IMGUI_ACTION.previous_page, "_imgui_previous_page" },
    { IMGUI_ACTION.next_page, "_imgui_next_page" },
    { IMGUI_ACTION.add_page, "_imgui_add_page" },
    { IMGUI_ACTION.remove_page, "_imgui_remove_page" },
    { IMGUI_ACTION.sync_multi_auto, "_sync_imgui_multi_auto" },
    { IMGUI_ACTION.sync_auto_save, "_sync_imgui_autosave" },
    { IMGUI_ACTION.choose_log_path, "_choose_imgui_log_path" },
    { IMGUI_ACTION.minimize, "_imgui_minimize" },
    { IMGUI_ACTION.maximize, "_toggle_maximize" },
    { IMGUI_ACTION.close_window, "on_close" },
    { IMGUI_ACTION.send_slot_0, "_imgui_send_slot", 0 },
    { IMGUI_ACTION.send_slot_1, "_imgui_send_slot", 1 },
    { IMGUI_ACTION.send_slot_2, "_imgui_send_slot", 2 },
    { IMGUI_ACTION.send_slot_3, "_imgui_send_slot", 3 },
    { IMGUI_ACTION.send_slot_4, "_imgui_send_slot", 4 },
    { IMGUI_ACTION.send_slot_5, "_imgui_send_slot", 5 },
    { IMGUI_ACTION.send_slot_6, "_imgui_send_slot", 6 },
    { IMGUI_ACTION.send_slot_7, "_imgui_send_slot", 7 },
}

local STATUS_TEXT = {
    [0] = "ok", [-1] = "bad parameter", [-2] = "not open",
    [-3] = "already open", [-4] = "busy", [-5] = "full",
    [-6] = "io error", [-7] = "timeout", [-8] = "drain incomplete",
    [-9] = "unsupported",
}

local HEADER_H = 36
local STATUS_H = 22
local CONN_W = 180
local PAGE_MARGIN = 1
local PANEL_GAP = 0
-- Header window-button strip (min/max/close), drawn in on_paint and hit
-- tested in on_nchittest / _header_button_at — keep these three in sync.
local HEADER_BUTTON_W = 40
local HEADER_BUTTONS_W = HEADER_BUTTON_W * 3

-- Read the full text of a RICHEDIT/edit control as a Lua string.
local function receive_text(hwnd)
    local n = w.user32.GetWindowTextLengthA(hwnd)
    if n <= 0 then
        return ""
    end
    local buf = ffi.new("char[?]", n + 1)
    w.user32.GetWindowTextA(hwnd, buf, n + 1)
    return ffi.string(buf)
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------
function M.new(cfg, cfg_data, config_path)
    w.load()  -- resolve Win32 DLLs (Windows host)
    local self = setmetatable({}, Window)
    self.cfg = cfg
    -- Raw INI-shaped table (core/config.lua) and its file path, retained so
    -- _save_config() can write back the values the user actually changed —
    -- without this, config.load() at startup would be the only place the
    -- config file is ever touched, and every UI change would be lost on exit.
    self.cfg_data = cfg_data
    self.config_path = config_path
    self.hwnd = nil
    self.hinst = w.kernel32.GetModuleHandleA(nil)
    self.core = nil                 -- xcom_core handle
    self.connected = false
    self.port_state = 0
    self.generation = 0
    self._handlers = {}             -- id -> handler name string
    self._autosend_on = false
    self._max_display_bytes = 2 * 1024 * 1024
    self._imgui_receive = ""
    self._imgui_receive_chunks = {}
    self._imgui_receive_chunk_bytes = 0
    self._imgui_receive_dirty = false
    -- P2 layer of run_message_loop: high-priority deferred jobs.  Handlers
    -- that must not run inside a WndProc/timer callback (re-entrancy or
    -- ordering) push closures here; the loop drains the whole queue between
    -- uv callbacks and rendering.  See schedule_defer.
    self._defer_queue = {}
    -- HSM mirror of the native port state (design: interlock parity with the
    -- Python client's ViewModel — see core/view_model.lua).
    self.vm = view_model.new()
    Active = self
    return self
end

-- Forward-declared: Lua resolves a same-scope `local function` reference only
-- if the local already exists at the point of use (upvalues are captured by
-- lexical position, not by name at call time). init_window() below refers to
-- create_class before its original definition line, which would otherwise
-- resolve to an undefined global and crash on first call. Declare the local
-- slot here so both functions close over the same upvalue.
local create_class

function Window:init_window()
    local wc = create_class(self.hinst)
    w.user32.RegisterClassA(wc)
    local cfg = self.cfg
    local tw = cfg.window and cfg.window.w or 920
    local th = cfg.window and cfg.window.h or 650
    local tx = cfg.window and cfg.window.x or 80
    local ty = cfg.window and cfg.window.y or 60

    -- Do not make the window visible during CreateWindowExA.  That call
    -- synchronously re-enters WndProc before its return value can be assigned
    -- to self.hwnd, so a paint/erase handler would otherwise receive a NULL
    -- target while initialising the UI.
    local style = w.style.WS_POPUP +
                  w.style.WS_CLIPCHILDREN + w.style.WS_CLIPSIBLINGS
    self.hwnd = w.user32.CreateWindowExA(
        0, wc.lpszClassName, "XCOM Serial Console", style,
        tx, ty, tw, th, nil, ffi.cast("void*", 0), self.hinst, nil
    )
    if not self.hwnd or self.hwnd == ffi.new("HWND[1]")[0] then
        return false
    end
    self:build_ui(tw, th)
    self:_init_imgui()
    w.user32.ShowWindow(self.hwnd, w.style.SW_SHOW)
    w.user32.UpdateWindow(self.hwnd)
    if self.cfg.always_on_top then
        self:_set_always_on_top(true)
    end
    return true
end

-- Apply/clear HWND_TOPMOST without moving or resizing (persisted in
-- config.ini as display.always_on_top; previously saved but never applied).
function Window:_set_always_on_top(enabled)
    w.user32.SetWindowPos(self.hwnd,
        ffi.cast("HWND", enabled and w.style.HWND_TOPMOST or w.style.HWND_NOTOPMOST),
        0, 0, 0, 0, w.style.SWP_NOMOVE + w.style.SWP_NOSIZE + w.style.SWP_NOACTIVATE)
    self._always_on_top = enabled
end

local function set_tree_visible(value, node, seen)
    if type(node) ~= "table" then return end
    seen = seen or {}
    if seen[node] then return end
    seen[node] = true
    if node.hwnd then
        w.user32.ShowWindow(node.hwnd, value and 1 or 0)
    end
    for _, child in pairs(node) do
        if type(child) == "table" then set_tree_visible(value, child, seen) end
    end
end

function Window:_init_imgui()
    if not imgui_bridge.available then return end
    local bridge = imgui_bridge.new(self.hwnd, self.cfg)
    if not bridge then return end
    self.imgui = bridge
    local port = self.cfg.port or ""
    if port ~= "" then ffi.copy(self.imgui.port, port, math.min(#port, 126)) end
    self.imgui:set_pages(self.cfg.quick_pages or { { text = {}, enabled = {} } })
    self:_refresh_imgui_ports()
    -- Keep every native control alive as a fallback, but remove it from the
    -- visual tree while the ImGui dashboard is active.
    set_tree_visible(false, self.conn)
    set_tree_visible(false, self.recv)
    set_tree_visible(false, self.send)
    set_tree_visible(false, self.status)
end

function Window:_refresh_imgui_ports()
    if not self.imgui then return end
    self.imgui:set_ports(xcom.list_ports() or {})
end

create_class = function(hinst)
    local wc = ffi.new("WNDCLASSA")
    wc.lpfnWndProc = WndProc
    wc.lpszClassName = "XComSerialLua"
    wc.hInstance = hinst
    -- Background brush: (HBRUSH)(COLOR_WINDOW+1) requests the system window
    -- color, so the client area is never transparent/desktop-passthrough even
    -- before the first WM_PAINT.  A NULL hbrBackground leaves the client area
    -- un-painted (transparent) and makes WM_ERASEBKGND pointless.
    wc.style = 0x0020  -- CS_OWNDC keeps the DX11 swap-chain target stable.
    wc.hbrBackground = ffi.cast("HBRUSH", 6)  -- COLOR_WINDOW + 1 = 6
    wc.hIcon = ffi.cast("HICON", w.user32.LoadImageA(
        nil, "runtime\\xcom.ico", w.image.ICON, 0, 0,
        w.image.LOAD_FROM_FILE + w.image.DEFAULT_SIZE))
    return wc
end
Window._create_class = create_class

-- ---------------------------------------------------------------------------
-- UE layout
-- ---------------------------------------------------------------------------
function Window:build_ui(tw, th)
    local body_h = th - HEADER_H - STATUS_H
    local send_h = 196
    local content_y = HEADER_H
    local send_y = th - STATUS_H - send_h
    local conn_x = tw - PAGE_MARGIN - CONN_W
    local recv_w = conn_x - PANEL_GAP - PAGE_MARGIN
    local recv_h = send_y - content_y - PANEL_GAP

    -- The old layout placed both columns at x=8.  The receive view then
    -- covered the serial controls, producing the overlapping screenshot.
    self.conn = conn_panel.build(self.hwnd, conn_x, content_y, CONN_W)
    self.recv = recv_panel.build(self.hwnd, PAGE_MARGIN, content_y,
                                 recv_w, recv_h)
    self.send = send_panel.build(self.hwnd, PAGE_MARGIN, send_y,
                                 tw - PAGE_MARGIN * 2, send_h)

    -- status bar.
    self.status = status_bar.create(self.hwnd, { y = th - STATUS_H, height = STATUS_H })

    self._layout = {
        body_y = HEADER_H, body_h = body_h, body_w = tw,
        content_y = content_y, recv_w = recv_w, recv_h = recv_h,
        send_h = send_h, send_y = send_y, conn_x = conn_x,
    }
    self.status.layout(tw, th - STATUS_H)
    self:_initial_ui_state()
end

-- Serial-config combo text maps and helpers (declared before _initial_ui_state
-- so that function's references resolve as upvalues, not undefined globals;
-- see the create_class forward-declaration note above).
local STOP_TEXT = { [0] = "1", [1] = "1.5", [2] = "2" }
local PARITY_TEXT = { [0] = "None", [1] = "Odd", [2] = "Even", [3] = "Mark", [4] = "Space" }
local FLOW_TEXT = { [0] = "None", [1] = "HW (RTS/CTS)", [2] = "SW (XON/XOFF)" }
local stop_text, parity_text, flow_text

-- Apply persisted settings to the panel controls (serial combos, DTR/RTS, and
-- display flags), matching the Python client's initial UI state.
function Window:_initial_ui_state()
    local cfg = self.cfg
    local conn = self.conn
    if conn.baud then c.combo_select_text(conn.baud, cfg.baud_rate or 115200) end
    if conn.data then c.combo_select_text(conn.data, tostring(cfg.data_bits or 8)) end
    if conn.stop then c.combo_select_text(conn.stop, stop_text(cfg.stop_bits or 0)) end
    if conn.parity then c.combo_select_text(conn.parity, parity_text(cfg.parity or 0)) end
    if conn.flow then c.combo_select_text(conn.flow, flow_text(cfg.flow_control or 0)) end
    if cfg.dtr_enable then c.set_checked(conn.dtr, true) end
    if cfg.rts_enable then c.set_checked(conn.rts, true) end
    if cfg.port and cfg.port ~= "" then
        self._port_want = cfg.port
    end
    self:_refresh_status()
end

stop_text = function(i) return STOP_TEXT[i] or "1" end
parity_text = function(i) return PARITY_TEXT[i] or "None" end
flow_text = function(i) return FLOW_TEXT[i] or "None" end

-- ---------------------------------------------------------------------------
-- WndProc dispatch
-- ---------------------------------------------------------------------------
-- jit.off: entered from the WndProc FFI callback (C re-entry).  Must never be
-- JIT-compiled — see the LuaJIT FFI callback rule in run_message_loop's note.
function Window:dispatch(hwnd, msg, wparam, lparam)
    local m = msg
    local imgui_handled = false
    if self.imgui then
        local ok, handled = pcall(self.imgui.wndproc, self.imgui, hwnd, msg, wparam, lparam)
        imgui_handled = ok and handled
    end

    -- Demand-driven repaint (see render_imgui): any real input message pulls
    -- the next frame to the interactive 16 ms cadence.  High-frequency system
    -- chatter (NCHITTEST, ERASEBKGND, PAINT, TIMER) deliberately does NOT —
    -- triggering on those would defeat the idle heartbeat entirely.
    if self.imgui then
        if (m >= 0x0005 and m <= 0x0019) or     -- WM_SIZE..WM_SETFOCUS range
           (m >= 0x00A0 and m <= 0x00A9) or     -- nonclient mouse (drag/resize)
           (m >= 0x0100 and m <= 0x0109) or     -- WM_KEYDOWN..WM_SYSDEADCHAR
           (m >= 0x0200 and m <= 0x020E) or     -- mouse move/click/wheel
           m == 0x0007 or                       -- WM_SETFOCUS
           m == 0x000C then                     -- WM_SETTEXT (title/status)
            self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
        end
    end

    if m == w.wm.WM_NCHITTEST then
        return self:on_nchittest(lparam)
    end
    if m == w.wm.WM_COMMAND then
        return self:on_command(wparam, lparam)
    end
    if m == w.wm.WM_PAINT then
        if self.imgui then
            -- DX11 owns the client surface while ImGui is active.  Calling
            -- the legacy GDI painter here races SwapBuffers during expose and
            -- resize, which causes stale frames and visible flicker.  Begin/
            -- EndPaint only acknowledges the invalid region; the next loop
            -- iteration performs the actual redraw through DX11.
            local ps = ffi.new("PAINTSTRUCT")
            local hdc = w.user32.BeginPaint(self.hwnd, ps)
            if hdc then w.user32.EndPaint(self.hwnd, ps) end
            self._imgui_next_frame = nil
            return 0
        end
        self:on_paint()
        return 0
    end
    if m == w.wm.WM_ERASEBKGND then
        if self.imgui then
            -- Do not let GDI erase a DX11-owned surface between frames.
            return 1
        end
        -- Fill the whole client area with the page background colour so the
        -- window is never transparent/desktop-passthrough.  Returning 1 tells
        -- Windows we did the erase (prevents the default black fill + flicker).
        local hdc = ffi.cast("HDC", wparam)
        local rc = ffi.new("RECT")
        w.user32.GetClientRect(hwnd, rc)
        if not self._page_brush then
            self._page_brush = w.gdi32.CreateSolidBrush(PAL.page)
        end
        w.user32.FillRect(hdc, rc, self._page_brush)
        return 1
    end
    if m == w.wm.WM_CTLCOLORBTN or m == w.wm.WM_CTLCOLORSTATIC or
       m == w.wm.WM_CTLCOLORDLG or m == w.wm.WM_CTLCOLOREDIT or
       m == w.wm.WM_CTLCOLORLISTBOX then
        if not self._page_brush then
            self._page_brush = w.gdi32.CreateSolidBrush(PAL.page)
        end
        -- Text boxes and combos sit on white cards; static labels remain
        -- transparent against the page.  Returning a white brush for the
        -- edit/listbox notifications removes the grey blocks from labels.
        local brush = self._page_brush
        local hdc = ffi.cast("HDC", wparam)
        if m == w.wm.WM_CTLCOLORSTATIC then
            w.gdi32.SetBkMode(hdc, w.opa.TRANSPARENT)
            w.gdi32.SetTextColor(hdc, PAL.text)
        end
        if m == w.wm.WM_CTLCOLOREDIT or m == w.wm.WM_CTLCOLORLISTBOX then
            if not self._surface_brush then
                self._surface_brush = w.gdi32.CreateSolidBrush(PAL.surface)
            end
            brush = self._surface_brush
        end
        return ffi.cast("intptr_t", brush)
    end
    if m == w.wm.WM_SIZE then
        self:on_size(wparam, lparam)
        return 0
    end
    if m == w.wm.WM_SYSKEYDOWN then
        -- Alt+0..7: fire the matching multi-send entry (Python's QShortcut
        -- Alt+0..7 parity).  Alt+<digit> arrives as WM_SYSKEYDOWN; we consume
        -- only the digit range so other Alt combos (menu mnemonics) pass on.
        if self:_on_alt_digit(tonumber(wparam) or 0) then
            return 0
        end
    end
    if m == w.wm.WM_DESTROY then
        w.user32.PostQuitMessage(0)
        return 0
    end
    if m == w.wm.WM_CLOSE then
        self:on_close()
        return 0
    end
    if m == w.wm.WM_LBUTTONUP then
        self:on_lbuttonup(lparam)
        return 0
    end

    if imgui_handled then
        return 0
    end

    return w.user32.DefWindowProcA(hwnd, msg, wparam, lparam)
end
jit.off(Window.dispatch)

-- Alt+digit handling (WM_SYSKEYDOWN).  Returns true when the key was a
-- digit we consumed, so the caller can skip DefWindowProc.
function Window:_on_alt_digit(vk)
    local index
    if vk >= 0x30 and vk <= 0x39 then        -- '0'..'9' main row
        index = vk - 0x30
    elseif vk >= 0x60 and vk <= 0x69 then    -- VK_NUMPAD0..9
        index = vk - 0x60
    else
        return false
    end
    if index > 7 then
        return false  -- only slots 0..7 exist
    end
    if self.imgui then
        local text, enabled = self.imgui:multi_entry(index)
        if enabled and text ~= "" then
            local payload = xcom.build_send_payload(text,
                self.imgui.multi_hex[0] ~= 0, self.imgui.multi_crlf[0] ~= 0)
            if payload then self:core_send(payload, xcom.send_text) end
        end
    elseif self.send then
        local sp = self.send
        if sp.entry_enabled(index) then
            local payload = xcom.build_send_payload(
                sp.entry_text(index), c.checkbox_checked(sp.multi.hex),
                c.checkbox_checked(sp.multi.crlf))
            if payload then self:core_send(payload, xcom.send_text) end
        end
    end
    return true
end

-- Header hit-test: title bar drag + edge resize + custom window buttons.
function Window:on_nchittest(lparam)
    -- lparam encodes screen X in the low word, Y in the high word.  lparam is
    -- an intptr_t cdata; unpack LOWORD/HIWORD via integer arithmetic.
    local lp = tonumber(lparam) or 0
    local x = lp % 65536
    local y = math.floor(lp / 65536) % 65536
    -- convert screen -> client
    local pt = ffi.new("POINT", x, y)
    w.user32.ScreenToClient(self.hwnd, pt)
    local cx, cy = pt.x, pt.y

    -- header buttons region: we draw min/max/close at the top-right.
    local rc = self._layout or {}
    local edge = 6
    -- bottom/right resize edges
    local client_w = rc.body_w or 920
    local client_h = (rc.body_y or HEADER_H) + (rc.body_h or 0) + (rc.status_h or STATUS_H)
    if cx >= client_w - edge then
        if cy >= client_h - edge then return w.ht.HTBOTTOMRIGHT end
        if cy <= edge then return w.ht.HTTOPRIGHT end
        return w.ht.HTRIGHT
    end
    if cx <= edge then
        if cy >= client_h - edge then return w.ht.HTBOTTOMLEFT end
        if cy <= edge then return w.ht.HTTOPLEFT end
        return w.ht.HTLEFT
    end
    if cy >= client_h - edge then return w.ht.HTBOTTOM end
    if cy <= edge then return w.ht.HTTOP end

    -- header => caption for drag (unless on a window button).
    if cy < HEADER_H then
        -- Skip the right 3 button boxes (avoid dragging when pressing them).
        -- Must match on_paint's `bx0 = body_w - HEADER_BUTTONS_W` exactly, or
        -- clicking near a button would instead start a caption drag.
        local bx = client_w - HEADER_BUTTONS_W
        if cx >= bx then
            -- we'll still return HTCLIENT so clicks dispatch to our button hittest
            return w.ht.HTCLIENT
        end
        return w.ht.HTCAPTION
    end
    return w.ht.HTCLIENT
end

-- Which of the three header buttons (min/max/close) is at client (cx, cy),
-- or nil.  Mirrors the layout drawn in on_paint (bx0, 40px each, 3 buttons).
function Window:_header_button_at(cx, cy)
    if cy < 0 or cy >= HEADER_H then
        return nil
    end
    local body_w = (self._layout and self._layout.body_w) or 920
    local bx0 = body_w - HEADER_BUTTONS_W
    if cx < bx0 or cx >= bx0 + HEADER_BUTTONS_W then
        return nil
    end
    local index = math.floor((cx - bx0) / HEADER_BUTTON_W)
    if index == 0 then return "minimize" end
    if index == 1 then return "maximize" end
    if index == 2 then return "close" end
    return nil
end

-- WM_LBUTTONUP: header window-button clicks (min/max/close).  on_nchittest
-- already returns HTCLIENT (not HTCAPTION) over this strip so these clicks
-- reach here instead of starting a caption drag.
function Window:on_lbuttonup(lparam)
    local lp = tonumber(lparam) or 0
    local x = lp % 65536
    local y = math.floor(lp / 65536) % 65536
    local which = self:_header_button_at(x, y)
    if which == "minimize" then
        w.user32.ShowWindow(self.hwnd, w.style.SW_MINIMIZE)
    elseif which == "maximize" then
        self:_toggle_maximize()
    elseif which == "close" then
        w.user32.SendMessageA(self.hwnd, w.wm.WM_CLOSE, 0, 0)
    end
end

-- Toggle maximize/restore.  IsZoomed isn't declared; track state ourselves
-- since this window only ever transitions via this button or the system
-- double-click-caption gesture below.
function Window:_toggle_maximize()
    if self._maximized then
        w.user32.ShowWindow(self.hwnd, w.style.SW_RESTORE)
        self._maximized = false
    else
        w.user32.ShowWindow(self.hwnd, w.style.SW_MAXIMIZE)
        self._maximized = true
    end
end

-- WM_COMMAND: child-id dispatch.
function Window:on_command(wparam, lparam)
    local id = (tonumber(wparam) or 0) % 65536
    local handler = self._handlers[id]
    if type(handler) == "function" then
        return handler(wparam, lparam)
    elseif type(handler) == "string" and self[handler] then
        return self[handler](self, wparam, lparam)
    end
    return 0
end

-- Bounded final drain: after the port is closed the core may still hold
-- accepted-but-undisplayed bytes.  Pump drain_display in 64 KiB rounds (same
-- budget as the 10 ms poller) with a hard round cap so a pathological stream
-- can never spin the close path or balloon the receive buffer — the ImGui
-- tail is already clamped to 64 KiB chars by poll_display's substring.
-- Python parity: MainWindow._drain_for_close polls until display_pending
-- reaches zero before quitting.
function Window:_final_drain()
    if not self.core then
        return
    end
    local max_rounds = 500  -- 500 * 64 KiB = 32 MiB hard ceiling
    for _ = 1, max_rounds do
        local rc, text = xcom.drain_display(self.core, 64 * 1024)
        if rc ~= xcom.ok or not text or #text == 0 then
            break
        end
        self:_append_imgui_receive(text)
        if self._log_active then
            xcom.log_append(self.core, text, #text)
        end
        if self.recv and self.recv.feed then
            self.recv.feed(text)
        end
    end
end

function Window:on_close()
    -- Mirrors Python's closeEvent pipeline: stop auto-send, stop the poll
    -- timers (no new data while we drain), drain accepted bytes to the
    -- display, flush the log, then close the port and destroy the window.
    self:_set_autosend_enabled(false)
    if self._multi_timer then self._multi_timer:stop() end
    if self._display_timer then self._display_timer:stop() end
    if self._status_timer then self._status_timer:stop() end
    self:_final_drain()
    self:_save_config()
    if self.core then
        self:_log_close_with_retry()
        if self.connected then
            xcom.close(self.core, 2000)
            self.connected = false
        end
    end
    if self.imgui then
        self.imgui:close()
        self.imgui = nil
    end
    w.user32.DestroyWindow(self.hwnd)
end

-- Persist the current UI state to config.ini (mirrors Python's DebouncedSaver
-- flush on close — this port skips debouncing and simply writes once, on
-- exit, since there is no dedicated writer thread to serialise concurrent
-- config saves against). Without this, config.load() at startup would be the
-- only place the file is ever touched and every change the user made in a
-- session (serial params, display options, window geometry) would be lost.
function Window:_save_config()
    if not self.cfg_data or not self.config_path then
        return
    end
    local data = self.cfg_data
    local rc = ffi.new("RECT")
    if w.user32.GetWindowRect(self.hwnd, rc) ~= 0 then
        local width = rc.right - rc.left
        local height = rc.bottom - rc.top
        -- Minimized windows report (-32000, -32000, 160, 28).  Never persist
        -- that sentinel geometry or the next launch will be invisible.
        if width >= 640 and height >= 480 and rc.left > -10000 and rc.top > -10000 then
            config.set(data, "window", "x", rc.left)
            config.set(data, "window", "y", rc.top)
            config.set(data, "window", "w", width)
            config.set(data, "window", "h", height)
        end
    end
    local conn = self.conn
    if conn then
        local serial = self:_serial_config()
        config.set(data, "port", "name", serial.port)
        config.set(data, "serial", "baud_rate", serial.baud_rate)
        config.set(data, "serial", "data_bits", serial.data_bits)
        config.set(data, "serial", "stop_bits", serial.stop_bits)
        config.set(data, "serial", "parity", serial.parity)
        config.set(data, "serial", "flow_control", serial.flow_control)
        config.set(data, "serial", "dtr_enable", serial.dtr)
        config.set(data, "serial", "rts_enable", serial.rts)
    end
    local recv = self.recv
    if recv then
        local opts = self:_display_options()
        config.set(data, "display", "timestamp", opts.timestamp)
        config.set(data, "display", "pause_display", opts.pause_display)
        config.set(data, "display", "auto_clear_bytes", opts.auto_clear_bytes)
        config.set(data, "display", "auto_save", c.checkbox_checked(recv.auto_save_cb))
        config.set(data, "send", "receive_hex", opts.receive_hex)
    end
    if self.imgui then
        config.set(data, "send", "hex", self.imgui.send_hex[0] ~= 0)
        config.set(data, "send", "crlf", self.imgui.send_crlf[0] ~= 0)
        config.set(data, "send", "autosend_period_ms", math.max(10, self.imgui.send_period[0]))
        config.set(data, "display", "auto_save", self.imgui.auto_save[0] ~= 0)
        config.set(data, "display", "save_path", self.cfg.save_path or "")
        self.imgui:_store_page()
        config.set(data, "multipage", "page_count", self.imgui.multi_page_count[0])
        for page_index, page in ipairs(self.imgui.pages) do
            for entry_index = 1, 8 do
                config.set_multi_entry(data, page_index - 1, entry_index - 1, "text", page.text[entry_index] or "")
                config.set_multi_entry(data, page_index - 1, entry_index - 1, "enabled", page.enabled[entry_index] == true)
            end
        end
    end
    config.save(self.config_path, data)
end

-- ---------------------------------------------------------------------------
-- ABI lifecycle helpers (single-thread; called from message-loop handlers).
-- ---------------------------------------------------------------------------

-- Current serial configuration as a plain record
-- {port, baud_rate, data_bits, stop_bits, parity, flow_control, dtr, rts},
-- read from the ImGui bridge when active and from the native panel controls
-- otherwise.  Single source for core_open() and _save_config(), which used to
-- each duplicate the imgui-vs-native branch.
function Window:_serial_config()
    local conn = self.conn
    if self.imgui then
        local baud, data_bits, stop, parity, flow, dtr, rts = self.imgui:serial_config()
        return {
            port = self._imgui_port or ffi.string(self.imgui.port),
            baud_rate = baud, data_bits = data_bits, stop_bits = stop,
            parity = parity, flow_control = flow, dtr = dtr, rts = rts,
        }
    end
    return {
        port = c.get_text(conn.port),
        baud_rate = tonumber(c.combo_text(conn.baud)) or 115200,
        data_bits = tonumber(c.combo_text(conn.data)) or 8,
        stop_bits = stop_index(c.combo_text(conn.stop)),
        parity = parity_index(c.combo_text(conn.parity)),
        flow_control = flow_index(c.combo_text(conn.flow)),
        dtr = c.checkbox_checked(conn.dtr),
        rts = c.checkbox_checked(conn.rts),
    }
end

-- Current display options as a plain record {receive_hex, timestamp,
-- pause_display, auto_clear_bytes}, from the same dual source.  Shared by
-- _push_display_options() and _save_config().
function Window:_display_options()
    local recv = self.recv
    if self.imgui then
        local hex_view, timestamp, pause_display, auto_clear_bytes = self.imgui:display_options()
        return { receive_hex = hex_view, timestamp = timestamp,
                 pause_display = pause_display, auto_clear_bytes = auto_clear_bytes }
    end
    return {
        receive_hex = c.checkbox_checked(recv.rx_hex_cb),
        timestamp = c.checkbox_checked(recv.ts_cb),
        pause_display = c.checkbox_checked(recv.pause_cb),
        auto_clear_bytes = c.checkbox_checked(recv.auto_clear_cb) and
            (tonumber(c.get_text(recv.auto_clear_sb)) or 0) or 0,
    }
end

-- Open intent: mirrors Python MainWindow._on_open_clicked — the HSM must
-- accept the intent (CLOSED/FAULT only) before any ABI call is made; a
-- rejected intent (e.g. already opening) leaves state untouched.
--
-- Asynchronous open (C ABI v1.3): we queue the open with xcom_open_async
-- (returns immediately, no ~2s UI freeze) and let poll_status() drive
-- completion — xcom_take_open_result is polled on timer id 2 until the core
-- publishes OPEN inside its snapshot, which on_snapshot then folds into the
-- HSM.  Only an immediate queue failure (bad port/param/busy) rolls the open
-- intent back synchronously here.
function Window:core_open()
    if not self.core then
        return
    end
    if not self.vm:intent_open() then
        self:_render_ui_state()
        return
    end
    self:_render_ui_state()
    -- xcom_open_async returns XCOM_OK when the request is *queued* on the
    -- Dispatcher (NOT that the port is open); completion is observed via
    -- xcom_take_open_result() in poll_status().  A non-OK result is an
    -- immediate failure the synchronous path would also have returned before
    -- blocking, so roll the intent back instead of waiting for a snapshot
    -- that will never report OPEN.
    local serial = self:_serial_config()
    if not serial.port or serial.port == "" then
        self.vm:reject_open()
        if self.imgui then self.imgui:set_status("Select a port first") end
        return
    end
    if self.imgui then self.imgui:set_status("Opening " .. serial.port .. " ...") end
    local rc = xcom.open_async(self.core, serial.port, serial.baud_rate,
        serial.data_bits, serial.stop_bits, serial.parity, serial.flow_control,
        serial.dtr, serial.rts)
    if rc ~= xcom.ok then
        self.vm:reject_open()
        if self.imgui then
            self.imgui:set_status("Open failed: " .. (STATUS_TEXT[tonumber(rc)] or tostring(rc)))
        end
        c.set_text(self.status.labels[1], "OPEN FAILED")
        self:_render_ui_state()
    end
    self:poll_status()
end

-- Close intent: mirrors Python MainWindow._on_close_clicked — allowed from
-- OPEN/OPENING/FAULT only; a close already in flight cannot be re-issued.
function Window:core_close(timeout)
    if not self.core then
        return
    end
    if not self.vm:intent_close() then
        return
    end
    self:_render_ui_state()
    xcom.close(self.core, timeout or 2000)
    self:poll_status()
end

function Window:core_send(data_bytes, flags)
    if not self.core then
        return
    end
    if data_bytes and #data_bytes > 0 then
        local rc = tonumber(xcom.send(self.core, data_bytes, flags or xcom.send_text))
        if rc ~= xcom.ok and self.status and self.status.labels then
            c.set_text(self.status.labels[3],
                       "send failed: " .. (STATUS_TEXT[rc] or tostring(rc)))
        end
    end
end

function Window:core_set_options(opts)
    if self.core then
        xcom.set_options(self.core, opts)
    end
end

-- Collect the receive-options row into one xcom_set_options call, mirroring
-- Python's _push_display_options (app/main_window.py).  Also toggles the
-- auto-clear byte edit's enabled state and the receive_view's own hex_view
-- flag, and is re-run on every OFFLINE -> ONLINE edge (native display state
-- resets per session, same as Python's _on_connected_transition).
function Window:_push_display_options()
    local recv = self.recv
    if not recv then
        return
    end
    local opts = self:_display_options()
    recv.hex_view = opts.receive_hex
    recv.timestamp = opts.timestamp
    self:core_set_options({
        hex_view = opts.receive_hex,
        timestamp = opts.timestamp,
        pause_display = opts.pause_display,
        auto_clear_bytes = opts.auto_clear_bytes,
        max_display_bytes = self._max_display_bytes,
    })
end

function Window:on_chk_receive_hex_toggled()
    self:_push_display_options()
end

function Window:on_chk_display_opt_toggled()
    -- Timestamp / Pause / Auto-clear checkbox or spin changed.
    if self.recv and self.recv.on_auto_clear_toggled then
        self.recv.on_auto_clear_toggled()
    end
    self:_push_display_options()
end

function Window:on_chk_autosave_toggled()
    local enabled = c.checkbox_checked(self.recv.auto_save_cb)
    local path = self.cfg and self.cfg.save_path
    if enabled and (not path or path == "") then
        c.set_text(self.status.labels[3], "auto-save: no path configured")
        c.set_checked(self.recv.auto_save_cb, false)
        return
    end
    if self.core then
        if enabled then
            local rc = tonumber(xcom.log_open(self.core, path, true))  -- append
            if rc == xcom.ok then
                self._log_active = true
            else
                c.set_checked(self.recv.auto_save_cb, false)
                c.set_text(self.status.labels[3],
                           "auto-save: " .. (STATUS_TEXT[rc] or tostring(rc)))
            end
        else
            -- Deferred: log_close is a synchronous drain wait; the retry loop
            -- must not freeze the UI when the writer still has bytes.
            self:_log_close_deferred()
        end
    end
end

-- Timer poll 1 (P1 DATA priority): display drain.
-- jit.off: entered from a luv timer callback (C re-entry into Lua).
--
-- Data-loss contract: every drained batch reaches the Lua side exactly once
-- and is appended to the auto-save log BEFORE any display-side trimming, so
-- the 64 KiB receive-tail window only ever drops *visible* history, never
-- data.  The drain runs until the core lane is empty (not a single 64 KiB
-- budget) so a brief UI stall cannot let the 512 KiB core pool fill up and
-- count rx_pool_exhausted_bytes — a full pool is the only true data-loss
-- path.  A hard round cap bounds the loop against a pathological producer.
function Window:poll_display()
    if not self.core or not self.connected then
        return
    end
    local drained_any = false
    local max_rounds = 8  -- 8 × 64 KiB = 512 KiB, one full core pool per poll
    for _ = 1, max_rounds do
        local rc, text = xcom.drain_display(self.core, 64 * 1024)
        if rc ~= xcom.ok or not text or #text == 0 then
            break
        end
        drained_any = true
        -- Log first (persistence), then the display tail (trimmable).
        if self._log_active then
            xcom.log_append(self.core, text, #text)
        end
        self:_append_imgui_receive(text)
        -- The native RICHEDIT is hidden while the ImGui dashboard is active;
        -- feeding it is invisible work that still walks the whole batch
        -- through EM_REPLACESEL + colouring.  Only feed when visible.
        if not self.imgui and self.recv and self.recv.feed then
            self.recv.feed(text)
        end
    end
    if drained_any then
        -- New receive data changed the log tail; pull the next frame at the
        -- data cadence instead of waiting for the idle heartbeat.
        self:request_frame(FRAME_INTERVAL_DATA_MS)
    end
end
jit.off(Window.poll_display)

function Window:_append_imgui_receive(text)
    if not text or #text == 0 then return end
    local chunks = self._imgui_receive_chunks
    chunks[#chunks + 1] = text
    self._imgui_receive_chunk_bytes = self._imgui_receive_chunk_bytes + #text
    while self._imgui_receive_chunk_bytes > 65535 and #chunks > 1 do
        self._imgui_receive_chunk_bytes = self._imgui_receive_chunk_bytes - #chunks[1]
        table.remove(chunks, 1)
    end
    if #chunks == 1 and #chunks[1] > 65535 then
        chunks[1] = chunks[1]:sub(-65535)
        self._imgui_receive_chunk_bytes = #chunks[1]
    end
    self._imgui_receive_dirty = true
end

function Window:_flush_imgui_receive()
    if not self._imgui_receive_dirty then return false end
    local chunks = self._imgui_receive_chunks
    -- One concat produces the tail in a single allocation; the chunks list is
    -- already trimmed to <= 64 KiB by _append_imgui_receive, so no second
    -- concatenation or :sub() copy is needed here.
    self._imgui_receive = #chunks == 1 and chunks[1] or table.concat(chunks)
    self._imgui_receive_chunks = {}
    self._imgui_receive_chunk_bytes = 0
    self._imgui_receive_dirty = false
    return true
end

-- jit.off: this is the ImGui frame driver — it calls into the xcom_imgui C
-- DLL, whose wndproc path re-enters Lua through the WndProc FFI callback.
-- Traced frames were the second source of the "bad callback" PANIC.
-- Frame pacing under WARP (software) rendering.  A full frame costs ~45-60 ms
-- of CPU, so the old fixed 16 ms cadence burned ~70% of a core redrawing an
-- idle UI.  Frames are now demand-driven with a per-cause interval:
--   * interactive (mouse/keyboard/window messages): 16 ms  — feels instant
--   * receive data pending: 100 ms (10 FPS coalesced log tail)
--   * idle heartbeat: 500 ms (status text, cursor blink, clock fallbacks)
-- Anything that changes what is on screen calls request_frame() to pull the
-- next frame earlier; the floor keeps one heartbeat frame alive.
local FRAME_INTERVAL_ACTIVE_MS = 16
local FRAME_INTERVAL_DATA_MS = 100
local FRAME_INTERVAL_IDLE_MS = 500

function Window:request_frame(interval_ms)
    if not self.imgui then return end
    local now = uv.now()
    local next_frame = now + (interval_ms or FRAME_INTERVAL_ACTIVE_MS)
    if not self._imgui_next_frame or next_frame < self._imgui_next_frame then
        self._imgui_next_frame = next_frame
    end
end

-- Queue a closure for the P2 layer of run_message_loop.  Use this instead of
-- running work directly inside a WndProc dispatch or a luv timer callback when
-- either (a) the work may re-enter those callbacks, or (b) ordering relative
-- to other queued work matters.  Jobs run once per loop iteration, after the
-- due luv timers and before rendering; the queue is drained fully.
function Window:schedule_defer(job)
    local queue = self._defer_queue
    queue[#queue + 1] = job
    -- A queued job may need a frame (e.g. it updates status text); the idle
    -- heartbeat guarantees it renders even without an explicit request.
end

-- P3 UI-priority status update: cache the newest status string and let the
-- next rendered frame commit it via one FFI call.  An error-ring storm (one
-- take_error hit per 250 ms poll) then costs one set_status per frame at
-- most instead of one per producer; intermediate strings simply coalesce.
function Window:set_status_deferred(text)
    self._status_dirty = text or ""
    self:request_frame()
end

function Window:render_imgui()
    if not self.imgui then return end
    local now = uv.now()
    if self._imgui_next_frame and now < self._imgui_next_frame then return end
    -- Skip frames entirely while minimized: nothing is visible, and WARP
    -- repaints are pure wasted CPU.
    if self._minimized then
        self._imgui_next_frame = now + FRAME_INTERVAL_IDLE_MS
        return
    end
    self._imgui_next_frame = now + FRAME_INTERVAL_IDLE_MS
    if not self.imgui:frame() then return end
    -- P3 commit: the deferred status text (set_status_deferred) lands in this
    -- frame — one FFI call, newest value wins.
    if self._status_dirty ~= nil then
        self.imgui:set_status(self._status_dirty)
        self._status_dirty = nil
    end
    local receive_changed = self:_flush_imgui_receive()
    local rx = self._imgui_receive or ""
    if receive_changed then
        self.imgui:set_receive_text(rx)
    end
    local actions = self.imgui:draw(
        self.connected, self._rx_bytes or 0, self._tx_bytes or 0)
    -- The action handlers may tear the bridge down (on_close destroys the
    -- window); re-check self.imgui before rendering the finished frame.
    local dispatch_ok, dispatch_error = pcall(self._dispatch_imgui_actions, self,
        actions or 0)
    if not dispatch_ok then
        io.stderr:write("[imgui] action dispatch failed: " .. tostring(dispatch_error) .. "\n")
    end
    if self.imgui then
        self.imgui:render()
    end
end
jit.off(Window.render_imgui)

function Window:_dispatch_imgui_actions(actions)
    if bit.band(actions, IMGUI_ACTION.open) ~= 0 or
        bit.band(actions, IMGUI_ACTION.sync_settings) ~= 0 then
        self._imgui_port = self.imgui:port_name()
    end
    for _, command in ipairs(IMGUI_COMMANDS) do
        if bit.band(actions, command[1]) ~= 0 then
            self[command[2]](self, command[3])
        end
    end
end

function Window:_imgui_open()
    self:core_open()
end

function Window:_imgui_close()
    self:core_close(2000)
end

function Window:_imgui_send_single()
    local send_text = self.imgui:send_text()
    if send_text == "" then return end
    local payload = xcom.build_send_payload(send_text,
        self.imgui.send_hex[0] ~= 0, self.imgui.send_crlf[0] ~= 0)
    if payload then self:core_send(payload, xcom.send_text) end
end

-- Send every enabled entry on the current multi page.  Serves both the "Send
-- enabled" button and the auto-cycle timer (they used to duplicate this loop).
function Window:_imgui_send_enabled()
    for index = 0, 7 do
        local text, enabled = self.imgui:multi_entry(index)
        if enabled and text ~= "" then
            local payload = xcom.build_send_payload(text,
                self.imgui.multi_hex[0] ~= 0, self.imgui.multi_crlf[0] ~= 0)
            if payload then self:core_send(payload, xcom.send_text) end
        end
    end
end

function Window:_imgui_send_slot(index)
    if not self.imgui then return end
    local text, enabled = self.imgui:multi_entry(index)
    if not enabled or text == "" then return end
    local payload = xcom.build_send_payload(text,
        self.imgui.multi_hex[0] ~= 0, self.imgui.multi_crlf[0] ~= 0)
    if payload then self:core_send(payload, xcom.send_text) end
end

function Window:_imgui_previous_page()
    self.imgui:change_page(-1)
end

function Window:_imgui_next_page()
    self.imgui:change_page(1)
end

function Window:_imgui_add_page()
    self.imgui:add_page()
end

function Window:_imgui_remove_page()
    self.imgui:remove_page()
end

function Window:_imgui_minimize()
    w.user32.ShowWindow(self.hwnd, w.style.SW_MINIMIZE)
end

function Window:_sync_imgui_autosend()
    if not self.imgui or not self.core then return end
    if self.imgui.send_auto[0] == 0 then
        xcom.set_auto_template(self.core, "", 0, xcom.send_text)
        return
    end
    local text = ffi.string(self.imgui.send)
    local payload, err = xcom.build_send_payload(text,
        self.imgui.send_hex[0] ~= 0, self.imgui.send_crlf[0] ~= 0)
    if not payload then
        self.imgui.send_auto[0] = 0
        c.set_text(self.status.labels[3], "autosend payload invalid: " .. tostring(err))
        return
    end
    xcom.set_auto_template(self.core, payload, math.max(10, self.imgui.send_period[0]), xcom.send_text)
end

function Window:_send_imgui_multi()
    if not self.imgui then return end
    self:_imgui_send_enabled()
end
jit.off(Window._send_imgui_multi)  -- entered from a libuv timer callback

function Window:_sync_imgui_multi_auto()
    if not self.imgui then return end
    if self.imgui.multi_auto[0] == 0 then
        if self._multi_timer then self._multi_timer:stop() end
        return
    end
    local period = math.max(10, self.imgui.multi_period[0])
    if not self._multi_timer then self._multi_timer = uv.new_timer() else self._multi_timer:stop() end
    local timer_callback = function()
        local ok, err = pcall(self._send_imgui_multi, self)
        if not ok then io.stderr:write("[uv multi] " .. tostring(err) .. "\n") end
    end
    jit.off(timer_callback, true)
    self._multi_timer_callback = timer_callback
    self._multi_timer:start(period, period, timer_callback)
end

function Window:_sync_imgui_autosave()
    if not self.imgui or not self.core then return end
    local enabled = self.imgui.auto_save[0] ~= 0
    local path = self.cfg and self.cfg.save_path or ""
    if enabled and path == "" then
        self.imgui.auto_save[0] = 0
        c.set_text(self.status.labels[3], "auto-save: choose a log path first")
        return
    end
    if enabled then
        -- Status codes are cdata ints; 0 is truthy in Lua, so compare
        -- explicitly against xcom.ok rather than using `not`.
        if tonumber(xcom.log_open(self.core, path, true)) == xcom.ok then
            self._log_active = true
        else
            self.imgui.auto_save[0] = 0
            c.set_text(self.status.labels[3], "auto-save: cannot open " .. path)
        end
    else
        -- Deferred: same drain-wait concern as on_chk_autosave_toggled.
        self:_log_close_deferred()
    end
end

-- Close the log with a bounded retry.  The core's log_close(timeout_ms) is a
-- SYNCHRONOUS wait for the writer to drain; calling it four times back-to-
-- back froze the UI for up to 2 s whenever the user toggled auto-save off
-- mid-stream.  The runtime paths (auto-save toggle, save-path change) now
-- retry through the P2 defer queue — one log_close(500) attempt per loop
-- iteration, so the UI keeps pumping messages between attempts.  The close
-- path stays synchronous: quitting must guarantee the log is flushed.
--
-- A no-log-open close returns err_io from the ABI, so skip silently when no
-- log session is active.  Returns true on success or "nothing to do".
function Window:_log_close_with_retry()
    if not self.core or not self._log_active then return true end
    local rc = tonumber(xcom.log_close(self.core, 500))
    if rc == xcom.ok then
        self._log_active = false
        return true
    end
    for _ = 1, 3 do
        rc = tonumber(xcom.log_close(self.core, 500))
        if rc == xcom.ok then
            self._log_active = false
            return true
        end
    end
    c.set_text(self.status.labels[3],
               "log close failed: " .. (STATUS_TEXT[rc] or tostring(rc)))
    return false
end

-- Non-blocking variant for runtime paths: try once now; if the writer is
-- still draining, requeue one attempt via schedule_defer instead of spinning
-- in place.  Bounded to _log_close_defer_attempts so a wedged writer cannot
-- queue retries forever.
function Window:_log_close_deferred()
    if not self.core or not self._log_active then return end
    local rc = tonumber(xcom.log_close(self.core, 50))  -- short probe
    if rc == xcom.ok then
        self._log_active = false
        self._log_close_defer_attempts = nil
        c.set_text(self.status.labels[3], "log closed")
        return
    end
    self._log_close_defer_attempts = (self._log_close_defer_attempts or 0) + 1
    if self._log_close_defer_attempts <= 20 then
        self:schedule_defer(function() self:_log_close_deferred() end)
    else
        self._log_close_defer_attempts = nil
        c.set_text(self.status.labels[3],
                   "log close failed: " .. (STATUS_TEXT[rc] or tostring(rc)))
    end
end

function Window:_choose_imgui_log_path()
    local path = self:_save_file_dialog(self.cfg and self.cfg.save_path or "")
    if not path or path == "" then return end
    self.cfg.save_path = path
    if self.imgui and self.imgui.auto_save[0] ~= 0 then self:_sync_imgui_autosave() end
    c.set_text(self.status.labels[3], "auto-save: " .. path)
end

-- Drain the core's error ring into the status bar.  The ring lives in the
-- core; Lua only materialises the *last* record as one short status string
-- (no accumulation), keeping the per-poll cost to one bounded pop.
-- Python parity: MainWindow drains take_error() and shows the message in the
-- status bar.
function Window:_poll_errors()
    local err = xcom.take_error(self.core)
    if err then
        if self.imgui then
            -- P3 deferred: coalesced into the next rendered frame.
            self:set_status_deferred(string.format("E%d: %s", err.code, err.message))
        end
        c.set_text(self.status.labels[4],
                   string.format("E%d: %s", err.code, err.message))
    end
end

-- Timer poll 2: 250 ms status snapshot.  Feeds the HSM mirror (design parity
-- with Python's MainWindow._on_snapshot_ready -> ViewModel.on_snapshot) so
-- open/close/params interlock reacts to the *authoritative* core state, not
-- just the optimistic transition set by the button handler.
--
-- The v1.3 asynchronous open is driven here too: while the HSM mirror is
-- OPENING, we poll xcom_take_open_result, but treat it only as a PROBE of the
-- new ABI -- the authoritative convergence is the snapshot's own port_state
-- (below), which folds OPENING -> OPEN on success or OPENING -> FAULT on
-- failure through on_snapshot, exactly like the Python synchronous path.  We
-- deliberately do NOT rewrite the HSM from take_open_result's return value;
-- doing so would fight the snapshot's authoritative transition (a fast
-- take_open_result failure races the snapshot that already carries FAULT).
function Window:poll_status()
    if not self.core then
        return
    end
    if self.vm.hsm.state == self.vm.STATE_OPENING then
        -- Probe (and exercise) the v1.3 async-open result so the open does not
        -- depend solely on snapshot phase; any definitive state (OPEN/FAULT)
        -- is still applied by on_snapshot below.
        local open_result = tonumber(xcom.take_open_result(self.core))
        if open_result and open_result ~= xcom.ok and open_result ~= xcom.err_busy then
            if self.imgui then
                self.imgui:set_status("Open failed: " ..
                    (STATUS_TEXT[open_result] or tostring(open_result)))
            end
        end
    end
    local snap = xcom.get_snapshot(self.core)
    if snap then
        self._rx_bytes = snap.rx_bytes
        self._tx_bytes = snap.tx_bytes
        self.port_state = snap.port_state
        self.generation = snap.generation
        if self.vm:on_snapshot(snap) then
            self:_render_ui_state()
            if self.imgui then
                if snap.port_state == xcom.port_open then
                    self.imgui:set_status("Connected: " .. (self._imgui_port or "serial port"))
                elseif snap.port_state == xcom.port_fault then
                    self.imgui:set_status("Open failed; check the port and parameters")
                end
            end
        end
        -- Skip the string.format allocations when the counters are unchanged
        -- (the 250 ms poller otherwise formats four identical strings per
        -- second even on a quiet line).
        if snap.port_state ~= self._last_port_state then
            self._last_port_state = snap.port_state
            c.set_text(self.status.labels[1],
                       xcom.port_text[snap.port_state] or tostring(snap.port_state))
        end
        if snap.rx_bytes ~= self._last_rx_fmt or snap.tx_bytes ~= self._last_tx_fmt then
            self._last_rx_fmt = snap.rx_bytes
            self._last_tx_fmt = snap.tx_bytes
            c.set_text(self.status.labels[2],
                       string.format("RX %d  TX %d", snap.rx_bytes, snap.tx_bytes))
            -- Byte counters are drawn in the ImGui header; refresh at the data
            -- cadence while traffic flows, else fall back to the heartbeat.
            self:request_frame(FRAME_INTERVAL_DATA_MS)
        end
        local drops = snap.rx_pool_exhausted_bytes + snap.tx_rejected
        local trim = snap.ui_trimmed_bytes
        local paused = snap.display_paused_bytes
        if drops ~= self._last_drops or trim ~= self._last_trim or paused ~= self._last_paused then
            self._last_drops, self._last_trim, self._last_paused = drops, trim, paused
            -- Backpressure escalation: a growing rx_pool_exhausted_bytes means
            -- the 512 KiB core pool filled and bytes were dropped at the source
            -- — the one true data-loss path.  React immediately instead of at
            -- the next 10 ms tick: drain right now and surface the overflow.
            local prev_exhausted = self._last_pool_exhausted or 0
            if snap.rx_pool_exhausted_bytes > prev_exhausted then
                self._last_pool_exhausted = snap.rx_pool_exhausted_bytes
                c.set_text(self.status.labels[3],
                           string.format("DATA LOSS: rx pool overflow (total %d) - draining",
                                         snap.rx_pool_exhausted_bytes))
                self:poll_display()
                self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
            else
                c.set_text(self.status.labels[3],
                           string.format("drops: %d  trim: %d  pause: %d", drops, trim, paused))
            end
        end
    end
    self:_poll_errors()
end
jit.off(Window.poll_status)

-- Render every connection-dependent control from one HSM snapshot (mirrors
-- Python's MainWindow._render_ui_state).  params_enabled gates the serial
-- combos + DTR/RTS; open/close buttons follow can_open/can_close; send
-- controls follow send_enabled (exactly OPEN).
function Window:_render_ui_state()
    local state = self.vm:ui_state()
    local conn = self.conn
    local params_ctls = { conn.port, conn.baud, conn.data, conn.parity,
                         conn.stop, conn.flow, conn.dtr, conn.rts }
    for _, ctl in ipairs(params_ctls) do
        if ctl and ctl.hwnd then
            w.user32.EnableWindow(ctl.hwnd, state.params_enabled and 1 or 0)
        end
    end
    if conn.open and conn.open.hwnd then
        w.user32.EnableWindow(conn.open.hwnd, state.open_enabled and 1 or 0)
    end
    if conn.close and conn.close.hwnd then
        w.user32.EnableWindow(conn.close.hwnd, state.close_enabled and 1 or 0)
    end
    if self.send then
        if self.send.single and self.send.single.send and self.send.single.send.hwnd then
            w.user32.EnableWindow(self.send.single.send.hwnd, state.send_enabled and 1 or 0)
        end
        if self.send.multi and self.send.multi.btn_send_enabled and
           self.send.multi.btn_send_enabled.hwnd then
            w.user32.EnableWindow(self.send.multi.btn_send_enabled.hwnd,
                                  state.send_enabled and 1 or 0)
        end
    end
    -- Connected-transition hook (mirrors Python's _on_connected_transition):
    -- re-push the auto-send template on the OFFLINE -> ONLINE edge, because
    -- the native session generation resets on every xcom_open and does not
    -- retain a prior template across sessions.
    local was_connected = self.connected
    self.connected = state.connected
    -- Demand-driven display drain: arm the 10 ms poller only while data can
    -- actually arrive, and stop it on disconnect so the event loop's shortest
    -- deadline returns to the 250 ms status poll (the message loop then blocks
    -- properly in MsgWait when idle).
    if self._display_timer then
        if state.connected and not self._display_timer_armed then
            self._display_timer:start(10, 10, self._display_timer_callback)
            self._display_timer_armed = true
        elseif not state.connected and self._display_timer_armed then
            self._display_timer:stop()
            self._display_timer_armed = false
        end
    end
    if state.connected and not was_connected then
        self:_push_display_options()
        if self.imgui then
            self:_sync_imgui_autosend()
            self:_sync_imgui_multi_auto()
            self:_sync_imgui_autosave()
        elseif self._autosend_on then
            self:_set_autosend_enabled(true)
        end
    end
    if self.recv and self.recv.set_monitor_connected then
        self.recv.set_monitor_connected(state.connected)
    end
end

-- dispatch helpers used by panels.
function Window:on_size(wparam, lparam)
    -- store new client dims; panels re-layout (no-op child move kept simple).
    -- lparam is an intptr_t cdata; LOWORD/HIWORD unpack via integer arithmetic.
    local lp = tonumber(lparam) or 0
    local wd = lp % 65536
    local hg = math.floor(lp / 65536) % 65536
    -- SIZE_MINIMIZED = 1: nothing is visible, so render_imgui skips frames at
    -- the idle cadence until restore; SIZE_RESTORED = 0 / SIZE_MAXIMIZED = 2
    -- clear the flag and resume normal pacing.  A minimized WM_SIZE also
    -- reports a 0x0 client area — skip the layout update so restore repaints
    -- from the last valid geometry.
    if tonumber(wparam) == 1 then
        self._minimized = true
        return 0
    end
    self._minimized = false
    if self._layout then
        self._layout.body_w = wd
        local layout = self._layout
        layout.body_h = hg - HEADER_H - STATUS_H
        layout.conn_x = wd - PAGE_MARGIN - CONN_W
        layout.recv_w = math.max(320, layout.conn_x - PANEL_GAP - PAGE_MARGIN)
        layout.send_y = hg - STATUS_H - layout.send_h
        layout.recv_h = math.max(100, layout.send_y - layout.content_y - PANEL_GAP)
        if self.conn and self.conn.layout then
            self.conn.layout(layout.conn_x, layout.content_y, CONN_W)
        end
        if self.recv and self.recv.layout then
            self.recv.layout(PAGE_MARGIN, layout.content_y, layout.recv_w, layout.recv_h)
        end
        if self.status and self.status.layout then
            self.status.layout(wd, hg - STATUS_H)
        end
        self._imgui_next_frame = nil
        -- DX11 clears and redraws the client surface; requesting a GDI erase
        -- here creates a visible flash and can expose an old swap-chain frame
        -- while the user is dragging the border.
        w.user32.InvalidateRect(self.hwnd, nil, 0)
    end
    return 0
end

function Window:on_paint()
    -- Self-draw the header strip: brand chip + title + badge + window buttons.
    -- BeginPaint (not raw GetDC) marks the invalid region as painted, which
    -- stops Windows from re-sending WM_PAINT forever (the flicker), and its
    -- fErase flag triggers a proper background erase (the transparency /
    -- un-clickable client area).
    local ps = ffi.new("PAINTSTRUCT")
    local hdc = w.user32.BeginPaint(self.hwnd, ps)
    local client_w = (self._layout and self._layout.body_w) or 920
    local rect = ffi.new("RECT", 0, 0, client_w, HEADER_H)
    -- header background
    local hbrush = w.gdi32.CreateSolidBrush(PAL.header)
    w.user32.FillRect(hdc, rect, hbrush)
    w.gdi32.DeleteObject(hbrush)

    -- Flat cards establish the visual hierarchy that stock Win32 controls do
    -- not provide on their own: live data first, configuration second, then
    -- the send workspace.  Child controls are painted afterwards by Windows.
    local layout = self._layout or {}
    local card_brush = w.gdi32.CreateSolidBrush(PAL.surface)
    local function card(left, top, right, bottom)
        local card_rect = ffi.new("RECT", left, top, right, bottom)
        w.user32.FillRect(hdc, card_rect, card_brush)
    end
    local content_y = layout.content_y or HEADER_H
    local send_y = layout.send_y or 466
    card(PAGE_MARGIN, content_y, (layout.conn_x or 700) - PANEL_GAP / 2,
         send_y - 4)
    card((layout.conn_x or 700), content_y, client_w - PAGE_MARGIN, send_y - 4)
    card(PAGE_MARGIN, send_y, client_w - PAGE_MARGIN, client_w > 0 and
         ((layout.body_h or 560) + HEADER_H) or send_y + 150)
    w.gdi32.DeleteObject(card_brush)
    -- brand chip
    local chip = w.rgb(0x00, 0xbb, 0xbb)
    local chip_brush = w.gdi32.CreateSolidBrush(chip)
    local chip_rect = ffi.new("RECT", 6, 6, 34, HEADER_H - 6)
    w.user32.FillRect(hdc, chip_rect, chip_brush)
    w.gdi32.DeleteObject(chip_brush)
    -- title text
    local old_text = w.gdi32.SetTextColor(hdc, w.rgb(0xff, 0xff, 0xff))
    local old_bk = w.gdi32.SetBkMode(hdc, 1)  -- TRANSPARENT
    local font = w.gdi32.CreateFontA(16, 0, 0, 0, 700, 0, 0, 0,
                                     1, 0, 0, 5, 0, "Segoe UI")
    local of = w.gdi32.SelectObject(hdc, font)
    w.gdi32.TextOutA(hdc, 40, 7, "XCOM", 4)
    local sub_font = w.gdi32.CreateFontA(12, 0, 0, 0, 400, 0, 0, 0,
                                         1, 0, 0, 5, 0, "Segoe UI")
    w.gdi32.SelectObject(hdc, sub_font)
    w.gdi32.TextOutA(hdc, 40, 20, "SERIAL CONSOLE", 14)
    -- badge
    local badge_on = self.connected
    local badge_col = badge_on and w.rgb(0x4e, 0xcb, 0x71) or w.rgb(0x9a, 0x9a, 0x9a)
    local bw, bh = 92, 24
    local bx = client_w - bw - HEADER_BUTTONS_W - 14
    local badge_brush = w.gdi32.CreateSolidBrush(badge_col)
    local badge_rect = ffi.new("RECT", bx, 15, bx + bw, 15 + bh)
    w.user32.FillRect(hdc, badge_rect, badge_brush)
    w.gdi32.DeleteObject(badge_brush)
    w.gdi32.SelectObject(hdc, font)
    w.gdi32.SetTextColor(hdc, w.rgb(0xff, 0xff, 0xff))
    w.gdi32.TextOutA(hdc, bx + 10, 19, badge_on and "ONLINE" or "OFFLINE",
                     badge_on and 6 or 7)
    -- window buttons: draw three little rects at right.
    local bx0 = client_w - 120
    for i = 0, 2 do
        local r = ffi.new("RECT", bx0 + i * 40, 0, bx0 + i * 40 + 40, HEADER_H)
        local b_brush = w.gdi32.CreateSolidBrush(w.rgb(0x00, 0x4a, 0x8a))
        w.user32.FillRect(hdc, r, b_brush)
        w.gdi32.DeleteObject(b_brush)
        local label = i == 0 and "-" or (i == 1 and "[]" or "x")
        w.gdi32.SetTextColor(hdc, w.rgb(0xff, 0xff, 0xff))
        w.gdi32.TextOutA(hdc, bx0 + i * 40 + 13, 18, label, #label)
    end
    w.gdi32.SelectObject(hdc, of)
    w.gdi32.DeleteObject(sub_font)
    w.gdi32.DeleteObject(font)
    w.gdi32.SetTextColor(hdc, old_text)
    w.gdi32.SetBkMode(hdc, old_bk)
    w.user32.EndPaint(self.hwnd, ps)
    return 0
end

-- ---------------------------------------------------------------------------
-- Startup + message loop + button wiring.
-- ---------------------------------------------------------------------------

-- Register a control id -> Lua handler name (string).  The window's
-- WM_COMMAND dispatch resolves it as a method on self.
function Window:bind_handler(id, name)
    self._handlers[id] = name
end

-- Called once after the window is shown: create the xcom handle, start the two
-- ABI poll timers, and wire panel buttons to their handlers.
function Window:start()
    -- Create the core instance.
    local h, err = xcom.create()
    if not h then
        c.set_text(self.status.labels[1], "CORE ERROR")
        c.set_text(self.status.labels[3], err or "xcom_core.dll unavailable")
        return
    end
    self.core = h

    -- Wire connection-panel buttons / combos to handlers by control id.
    self:bind_handler(self.conn.open.id, "on_btn_open")
    self:bind_handler(self.conn.close.id, "on_btn_close")
    self:bind_handler(self.conn.clear.id, "on_btn_clear")
    self:bind_handler(self.conn.save.id, "on_btn_save")
    self:bind_handler(self.conn.refresh.id, "on_btn_refresh")
    -- send panel single + multi send buttons
    self:bind_handler(self.send.tab_single.id, "on_btn_tab_single")
    self:bind_handler(self.send.tab_multi.id, "on_btn_tab_multi")
    self:bind_handler(self.send.single.send.id, "on_btn_send_single")
    self:bind_handler(self.send.multi.btn_send_enabled.id, "on_btn_send_enabled")
    self:bind_handler(self.send.single.auto.id, "on_chk_autosend_toggled")
    self:bind_handler(self.send.multi.auto.id, "on_chk_multi_auto_toggled")
    self:bind_handler(self.send.multi.period.id, "on_edit_multi_period_changed")
    -- receive-options row (mirrors Python's ReceivePanel toggled signals).
    self:bind_handler(self.recv.rx_hex_cb.id, "on_chk_receive_hex_toggled")
    self:bind_handler(self.recv.ts_cb.id, "on_chk_display_opt_toggled")
    self:bind_handler(self.recv.pause_cb.id, "on_chk_display_opt_toggled")
    self:bind_handler(self.recv.auto_clear_cb.id, "on_chk_display_opt_toggled")
    self:bind_handler(self.recv.auto_save_cb.id, "on_chk_autosave_toggled")

    -- Two pollers as libuv timers.  The 10 ms display drain is DEMAND-DRIVEN:
    -- it only runs while a port is connected (see _render_ui_state), so an
    -- idle session's shortest luv deadline is the 250 ms status poll and the
    -- event-driven loop can actually block in MsgWait instead of waking every
    -- 10 ms for a no-op drain check.
    self._display_timer = uv.new_timer()
    local display_timer_callback = function()
        local ok, err = pcall(self.poll_display, self)
        if not ok then io.stderr:write("[uv display] " .. tostring(err) .. "\n") end
    end
    jit.off(display_timer_callback, true)
    self._display_timer_callback = display_timer_callback
    self._status_timer = uv.new_timer()
    local status_timer_callback = function()
        local ok, err = pcall(self.poll_status, self)
        if not ok then io.stderr:write("[uv status] " .. tostring(err) .. "\n") end
    end
    jit.off(status_timer_callback, true)
    self._status_timer_callback = status_timer_callback
    self._status_timer:start(250, 250, status_timer_callback)

    self:poll_status()
    collectgarbage("collect")
end

-- Message loop; blocks until WM_QUIT.  Returns when the window closes.
--
-- Event-driven, priority-layered loop (design: "luv 充分使用 + 消息/任务分
-- 优先级").  Each iteration runs layers strictly in order:
--
--   P0 Win32 input   — pump every pending message (user input always first;
--                      input-class messages request an interactive frame).
--   P1 luv timers    — uv.run("nowait") fires the 10 ms display drain, the
--                      250 ms status snapshot and the multi-send cycle when
--                      they are due — never late because the loop slept.
--   P2 deferred jobs — high-priority task queue drained fully (schedule_defer).
--   P3 GC step       — triggered by >=128 KiB of heap growth since the last
--                      step (dense input bursts don't starve the collector;
--                      a steady receive stream doesn't over-commit it).
--
-- Then render (paced by cause inside render_imgui) and SLEEP until the next
-- event: MsgWaitForMultipleObjectsEx wakes on any queued message or at the
-- earlier of the luv timer deadline (uv.backend_timeout) and the next frame
-- deadline (0 if the deadline already passed).  This replaces the old
-- uv.sleep(1) poll — the process wakes a handful of times per idle second
-- instead of ~64.
--
-- jit.off on this function only: it calls into DispatchMessageW, which in
-- turn re-enters the WndProc callback (an FFI closure created via
-- ffi.new("WNDPROC", ...)).  LuaJIT cannot trace through a C call that calls
-- back into an FFI callback — the documented-safe choice is to run this hot
-- loop interpreted (LuaJIT FFI semantics: "C function pointers to Lua closures
-- must not be called from JIT-compiled code").
local run_message_loop = function(self)
    local msg = ffi.new("MSG")
    while true do
        -- P0: pump ALL pending Win32 messages (non-blocking).
        while w.user32.PeekMessageW(msg, nil, 0, 0, 1) ~= 0 do  -- 1 = PM_REMOVE
            if msg.message == w.wm.WM_QUIT then
                return
            end
            w.user32.TranslateMessage(msg)
            w.user32.DispatchMessageW(msg)
        end

        -- P1: run due luv timers (display drain / status snapshot / multi).
        uv.run("nowait")

        -- P2: drain the deferred high-priority task queue fully.
        local queue = self._defer_queue
        if queue and #queue > 0 then
            self._defer_queue = {}
            for _, job in ipairs(queue) do
                local ok, err = pcall(job)
                if not ok then
                    io.stderr:write("[defer] " .. tostring(err) .. "\n")
                end
            end
        end

        -- P3: bounded GC step.  Trigger by heap growth since the last step,
        -- not by "this iteration saw input": a dense input burst must not
        -- starve the collector (chunks keep piling), and a sustained receive
        -- stream must not step every 10 ms either (step(8) is 8 KiB of GC
        -- budget per call — 100 calls/s would over-commit the collector).
        local heap_now = collectgarbage("count")
        if heap_now - (self._gc_last_heap or 0) >= 128 then  -- >= 128 KiB new
            collectgarbage("step", 32)
            self._gc_last_heap = collectgarbage("count")
        end

        self:render_imgui()

        -- Sleep until the next event.  The timeout is the earlier of the
        -- next luv timer deadline and the next frame deadline; MsgWait wakes
        -- immediately on any newly queued message.
        local timeout_ms = uv.backend_timeout()
        if not timeout_ms or timeout_ms < 0 then timeout_ms = 100 end
        local frame_wait = self._imgui_next_frame and
            (self._imgui_next_frame - uv.now()) or 0
        if frame_wait <= 0 then
            -- The frame deadline already passed while the layers above ran
            -- (e.g. a WARP frame or drain overran the budget): render on the
            -- very next iteration instead of sleeping out the timer deadline.
            timeout_ms = 0
        elseif frame_wait < timeout_ms then
            timeout_ms = frame_wait
        end
        w.user32.MsgWaitForMultipleObjectsEx(
            0, nil, math.floor(timeout_ms), w.wait.QS_ALLINPUT,
            w.wait.MWMO_INPUTAVAILABLE)
    end
end
jit.off(run_message_loop)

function Window:run()
    run_message_loop(self)
    -- Close the libuv timer handles (they are no longer advanced once the
    -- message loop has returned; libuv requires explicit close to release).
    for _, t in ipairs({ self._display_timer, self._status_timer, self._multi_timer }) do
        if t then
            t:stop()
            t:close()
        end
    end
    -- Release the 1 ms system-timer resolution requested in w.load().
    if w.winmm then
        w.winmm.timeEndPeriod(1)
    end
    if self.imgui then
        self.imgui:close()
        self.imgui = nil
    end
    -- Tear down the core handle.
    if self.core then
        xcom.destroy(self.core)
        self.core = nil
    end
    Active = nil
    return 0
end

-- ---------------------------------------------------------------------------
-- Button handlers (resolved by WM_COMMAND dispatch above).
-- ---------------------------------------------------------------------------
function Window:on_btn_open()
    self:core_open()
end

function Window:on_btn_tab_single()
    self.send.show_single()
end

function Window:on_btn_tab_multi()
    self.send.show_multi()
end

function Window:on_btn_close()
    -- Mirrors Python's _on_close_clicked: stop auto-send before closing.
    self:_set_autosend_enabled(false)
    c.set_checked(self.send.single.auto, false)
    self:core_close(2000)
end

function Window:on_btn_clear()
    self._imgui_receive = ""
    self._imgui_receive_chunks = {}
    self._imgui_receive_chunk_bytes = 0
    self._imgui_receive_dirty = false
    if self.imgui then
        self.imgui:set_receive_text("")
    end
    if self.recv and self.recv.clear then
        self.recv.clear(self.recv)
    end
end

-- Common Item Dialog save-picker: returns a UTF-8 path string, or nil on
-- cancel.  Uses the W entry point (UTF-16) plus the utf8<->utf16 bridge in
-- ui/win32.lua so non-ASCII paths survive.  `default_name` is an optional
-- preloaded filename (UTF-8).
function Window:_save_file_dialog(default_name)
    local ofn = ffi.new("OPENFILENAMEW")
    ofn.lStructSize = ffi.sizeof("OPENFILENAMEW")
    ofn.hwndOwner = self.hwnd
    ofn.lpstrFilter = w.utf8_to_utf16("Log files (*.log)\0*.log\0All files (*.*)\0*.*\0")
    ofn.lpstrDefExt = w.utf8_to_utf16("log")
    ofn.lpstrTitle = w.utf8_to_utf16("Save receive log")
    ofn.Flags = w.ofn.OFN_OVERWRITEPROMPT + w.ofn.OFN_PATHMUSTEXIST

    -- Preload the filename into the buffer (existing save_path).
    local buf_len = 1024
    local buf = ffi.new("unsigned short[?]", buf_len)
    if default_name and default_name ~= "" then
        local pre = w.utf8_to_utf16(default_name)
        if pre then
            for i = 0, #default_name - 1 do
                buf[i] = pre[i]
            end
            buf[#default_name] = 0
        end
    else
        buf[0] = 0
    end
    ofn.lpstrFile = buf
    ofn.nMaxFile = buf_len

    if w.comdlg32.GetSaveFileNameW(ofn) == 0 then
        return nil  -- cancelled or error
    end
    return w.utf16_to_utf8(ofn.lpstrFile, buf_len)
end

function Window:on_btn_save()
    -- Manual save: pick a path via the common dialog, then write the receive
    -- view to that path (truncate).  Falls back to the configured save_path
    -- only as the dialog's default filename, not as a silent target.
    local cfg_path = self.cfg and self.cfg.save_path or ""
    local path = self:_save_file_dialog(cfg_path)
    if not path or path == "" then
        return  -- user cancelled
    end
    if not self.core then
        return
    end
    -- ImGui owns the visible receive buffer; the native RichEdit is hidden and
    -- intentionally not fed in that mode.
    local data = self.imgui and (self._imgui_receive or "") or
        receive_text(self.recv.richedit.hwnd)
    if data and #data > 0 then
        -- Explicit status comparisons: ABI codes are cdata ints (0 is truthy
        -- in Lua), so `not rc` would misread success as failure.
        local rc = tonumber(xcom.log_open(self.core, path, false))  -- truncate
        if rc ~= xcom.ok then
            c.set_text(self.status.labels[3],
                       "save failed: " .. (STATUS_TEXT[rc] or tostring(rc)))
            return
        end
        self._log_active = true
        xcom.log_append(self.core, data, #data)
        xcom.log_flush(self.core, 2000)
        self:_log_close_with_retry()
        c.set_text(self.status.labels[3], "saved: " .. path)
        self.cfg.save_path = path
    end
end

-- Auto-cycle single-send: mirrors Python's _set_autosend_enabled. Disabling
-- clears the native template (interval_ms=0); enabling re-encodes the current
-- single-send text and re-pushes it at the current period, un-checking the
-- box on an invalid HEX payload (Python: `autosend_enable.setChecked(False)`).
function Window:_set_autosend_enabled(enabled)
    self._autosend_on = enabled
    if not self.core then
        return
    end
    if not enabled then
        xcom.set_auto_template(self.core, "", 0, xcom.send_text)
        return
    end
    local text = c.get_text(self.send.single.edit)
    local use_hex = c.checkbox_checked(self.send.single.hex)
    local add_crlf = c.checkbox_checked(self.send.single.crlf)
    local payload, err = xcom.build_send_payload(text, use_hex, add_crlf)
    if err or payload == nil then
        c.set_text(self.status.labels[3], "autosend payload invalid: " .. tostring(err))
        c.set_checked(self.send.single.auto, false)
        self._autosend_on = false
        return
    end
    local period = tonumber(c.get_text(self.send.single.period)) or 1000
    xcom.set_auto_template(self.core, payload, period, xcom.send_text)
end

function Window:on_chk_autosend_toggled()
    self:_set_autosend_enabled(c.checkbox_checked(self.send.single.auto))
end

-- Multi-send page "Auto cycle": mirrors Python's _on_multi_auto_toggled /
-- _multi_timer, a GUI-side timer distinct from the core auto-template (which
-- only holds one payload and is used by the single-send tab).  The Win32
-- SetTimer is replaced by a libuv timer so all polling is driven by the same
-- luv event loop.
function Window:on_chk_multi_auto_toggled()
    local enabled = c.checkbox_checked(self.send.multi.auto)
    self._multi_auto_on = enabled
    if enabled then
        local period = tonumber(c.get_text(self.send.multi.period)) or 1000
        if not self._multi_timer then
            self._multi_timer = uv.new_timer()
        else
            self._multi_timer:stop()
        end
        local timer_callback = function()
            local ok, err = pcall(self.on_btn_send_enabled, self)
            if not ok then io.stderr:write("[uv multi] " .. tostring(err) .. "\n") end
        end
        jit.off(timer_callback, true)
        self._multi_timer_callback = timer_callback
        self._multi_timer:start(period, period, timer_callback)
    else
        if self._multi_timer then
            self._multi_timer:stop()
        end
    end
end

-- Period edit changed: re-arm the timer at the new period if currently
-- running (mirrors Python's _on_multi_period_changed).
function Window:on_edit_multi_period_changed()
    if self._multi_auto_on then
        local period = tonumber(c.get_text(self.send.multi.period)) or 1000
        if self._multi_timer then
            self._multi_timer:set_repeat(period)
            self._multi_timer:again()
        end
    end
end

function Window:on_btn_refresh()
    -- Re-enumerate ports into the combo, re-selecting a persisted port if set.
    local ports = xcom.list_ports()
    local items = {}
    for _, p in ipairs(ports or {}) do
        local label = p.name
        if p.description and p.description ~= "" then
            label = label .. "  " .. p.description
        end
        if p.busy then label = label .. "  (busy)" end
        items[#items + 1] = label
    end
    c.combo_set(self.conn.port, items)
    if self._port_want then
        c.combo_select_text(self.conn.port, self._port_want)
    end
    if #items == 0 then
        c.set_text(self.status.labels[3], "no COM ports detected")
    end
end

function Window:on_btn_send_single()
    local text = c.get_text(self.send.single.edit)
    local use_hex = c.checkbox_checked(self.send.single.hex)
    local add_crlf = c.checkbox_checked(self.send.single.crlf)
    local payload = xcom.build_send_payload(text, use_hex, add_crlf)
    if payload then
        self:core_send(payload, xcom.send_text)
    end
end

function Window:on_btn_send_enabled()
    -- Send enabled entries from the current multi page for simple single-pass.
    local sp = self.send
    for i, e in ipairs(sp.multi.entries) do
        if sp.entry_enabled(i - 1) then
            local text = sp.entry_text(i - 1)
            local payload = xcom.build_send_payload(
                text, c.checkbox_checked(sp.multi.hex),
                c.checkbox_checked(sp.multi.crlf))
            if payload then
                self:core_send(payload, xcom.send_text)
            end
        end
    end
end

function Window:_refresh_status()
    if self.status then
        c.set_text(self.status.labels[1],
                   self.connected and "ONLINE" or "OFFLINE")
    end
end

return M
