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
local script_engine = require("script_engine")
local waveform = require("waveform")
local charset = require("charset")
local serial_sim = require("serial_sim")

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

-- Reference-tool light palette (Win32 COLORREF).  Keep in sync with the
-- ImGui bridge palette (native/xcom_imgui/xcom_imgui_bridge.cpp).
local PAL = {
    page    = w.rgb(0xee, 0xee, 0xf0),  -- background #EEEEF0 (light gray card)
    surface = w.rgb(0xff, 0xff, 0xff),  -- input/panel white
    text    = w.rgb(0x1b, 0x1b, 0x1b),
    accent  = w.rgb(0x00, 0x5a, 0x9e),  -- reference deep blue
    trigger = w.rgb(0x00, 0x99, 0x99),  -- cyan-teal
    dark    = w.rgb(0x00, 0x42, 0x75),  -- reference darker blue
    online  = w.rgb(0x00, 0x80, 0x00),  -- status green
    danger  = w.rgb(0xc5, 0x05, 0x00),  -- reference red
    header  = w.rgb(0x1e, 0x1e, 0x1e),  -- title bar bg (matches ImGui header)
    btnface = w.rgb(0xf0, 0xf0, 0xf0),
}

-- WndProc: one __stdcall C callback; delegates to Active:dispatch.
-- The dispatch is wrapped in pcall so a Lua error inside a handler no longer
-- escapes the FFI callback boundary (which Windows turns into
-- STATUS_FATAL_USER_CALLBACK_EXCEPTION / exit code 0xC000041D, with no
-- diagnostic).  On error we print the offending message + error to stderr and
-- return 0 so the window can keep pumping messages during bring-up.
-- page_brush: GDI solid brush matching PAL.page, reused as the WNDCLASS
-- background brush so the pre-first-frame client area paints gray (not white).
local page_brush
-- Diagnostics: with XCOM_DEBUG=1 every line below lands on stderr, which the
-- 诊断模式 launcher script redirects to xcom_debug.log (stderr is unbuffered,
-- so the last lines before a hard crash -- including LuaJIT's own panic text,
-- which bypasses Lua entirely -- survive in the file).  The wndproc stream is
-- filtered to INPUT messages only (keys, IME, clicks, WM_INPUT raw-input that
-- ImGui_ImplWin32 registers for): logging every message would emit thousands
-- of paint/hit-test lines per second and bury the smoking gun.
local DEBUG_MODE = os.getenv("XCOM_DEBUG") == "1"
local function dbg(fmt, ...)
    if DEBUG_MODE then
        io.stderr:write(string.format(fmt, ...) .. "\n")
    end
end
local DBG_MSGS = {
    [0x00F5] = "NCHITTEST", [0x0201] = "LBUTTONDOWN", [0x0202] = "LBUTTONUP",
    [0x0203] = "LBUTTONDBLCLK", [0x0100] = "KEYDOWN", [0x0101] = "KEYUP",
    [0x0102] = "CHAR", [0x0109] = "SYSCHAR",
    [0x010D] = "IME_STARTCOMP", [0x010E] = "IME_ENDCOMP", [0x010F] = "IME_COMP",
    [0x0281] = "IME_SETCTX", [0x0282] = "IME_NOTIFY", [0x0285] = "IME_SELECT",
    [0x00FF] = "INPUT", [0x0111] = "COMMAND", [0x0005] = "SIZE",
    [0x0007] = "SETFOCUS", [0x0008] = "KILLFOCUS",
}
local wndproc_callback = function(hwnd, msg, wparam, lparam)
    local win = Active
    if not win then
        return 0
    end
    local m = tonumber(msg) or 0
    local name = DBG_MSGS[m]
    if name then
        dbg("[dbg] wndproc %s(0x%04X) wp=0x%X lp=0x%X", name, m,
            tonumber(wparam) or 0, tonumber(lparam) or 0)
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
    scripts_window = 134217728,   -- 1 << 27 (Phase 4 C++ bridge; header "Lua")
    run_sequence = 268435456,     -- 1 << 28 (Phase 4 C++ bridge; Multi "Run")
    -- 1 << 29 is retired as a header chip: the "波形/Scope" chip is gone.  The
    -- scope panel is owned by the script engine — it appears while a script
    -- pushes wave points (waveform.active()) and hides after the idle grace
    -- period.  The bit itself still arrives when the panel's own title-bar X
    -- closes it (scope_retired_bit below), so Lua can record the dismissal.
    -- Kept in the table so the value has a name (parity with the C-side mask).
    scope_retired_bit = 536870912, -- 1 << 29 (scope panel X, no header chip)
    settings_window = 1073741824, -- 1 << 30 (header "Set" chip)
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
    { IMGUI_ACTION.scripts_window, "_imgui_scripts_toggle" },
    { IMGUI_ACTION.run_sequence, "_imgui_run_sequence" },
    { IMGUI_ACTION.settings_window, "_imgui_settings_toggle" },
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
-- ImGui header interactive cluster width.  The C++ bridge renders the
-- min/max/close window buttons AND the two toggle chips (Settings/Lua) as
-- right-aligned ImGui::InvisibleButton controls starting at
-- `button_group_start - 96` = `window_width - 108 - 96` = `width - 204`
-- (xcom_imgui_bridge.cpp Header(): button_group_start = width - 108, the
-- Settings chip is offset -96; the Scope chip was removed).  When the ImGui
-- bridge is active, the NCHITTEST caption zone must NOT swallow those five
-- controls, so this whole right strip is reserved as HTCLIENT and the
-- left/middle header remains HTCAPTION for window dragging.
local IMGUI_HEADER_CLUSTER_W = 204

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
    -- Receive-tail window (bytes).  Configurable via [display]
    -- receive_window_bytes in config.ini (clamped to 16 KiB..1 MiB); the
    -- historical fixed 64 KiB is the default.  Pushed into the ImGui bridge
    -- at _init_imgui so both sides trim the same tail.
    self._receive_window = imgui_bridge.clamp_receive_window(
        cfg.receive_window_bytes)
    -- Display-side charset (ASCII/UTF-8 passthrough by default).  The
    -- _charset_active flag keeps the drain funnel's fast path free of any
    -- function call when no conversion is configured.
    self._charset_name = cfg.charset or "ASCII"
    self._charset_active = false
    charset.set(self._charset_name)
    self._imgui_receive = ""
    self._imgui_receive_chunks = {}
    self._imgui_receive_cursor = 1
    self._imgui_receive_chunk_bytes = 0
    self._imgui_receive_dirty = false
    -- Lifetime byte counter of the display stream (every byte that ever went
    -- through _append_imgui_receive since the last clear).  The visible
    -- buffer is only a sliding tail window; the native selection is stored
    -- in these absolute coordinates (pushed with each set_receive_text) so
    -- a shaded range keeps tracking its own text while the window slides.
    self._imgui_receive_total = 0
    -- Display-side enforcement state for [display] auto_clear_bytes and
    -- frame_gap_ms.  Neither feature is enforced by the core or the ImGui
    -- DLL: xcom_set_options stores only hex/timestamp/pause (xcom_abi.cpp),
    -- and the DLL merely renders the two widgets against Lua-owned int
    -- buffers (see _push_display_options).  The cache below is refreshed on
    -- every ActionSyncDisplay and seeded from cfg so the receive path can
    -- consult plain Lua numbers at drain cadence without FFI reads.
    self._auto_clear_bytes = 0
    self._frame_gap_en = false
    self._frame_gap_ms = 0
    local cfg_gap = tonumber(cfg.frame_gap_ms) or 0
    if cfg_gap > 0 then
        self._frame_gap_en = true
        self._frame_gap_ms = cfg_gap
    end
    local cfg_clear = tonumber(cfg.auto_clear_bytes) or 0
    if cfg_clear > 0 then
        self._auto_clear_bytes = cfg_clear
    end
    -- uv.now() of the last drained batch (nil = none yet) and whether the
    -- view tail currently ends mid-line (the auto frame-break anchor).
    self._rx_last_batch_ms = nil
    self._view_tail_open = false
    -- TX echo ([display] tx_echo): sent payloads appear in the receive view
    -- and the auto-save log as "TX: " lines (see Window:_echo_tx).  Default
    -- on; the config round-trips it so the user can silence the transcript.
    self._tx_echo = cfg.tx_echo ~= false
    -- P2 layer of run_message_loop: high-priority deferred jobs.  Handlers
    -- that must not run inside a WndProc/timer callback (re-entrancy or
    -- ordering) push closures here; the loop drains the whole queue between
    -- uv callbacks and rendering.  See schedule_defer.
    self._defer_queue = {}
    -- HSM mirror of the native port state (design: interlock parity with the
    -- Python client's ViewModel — see core/view_model.lua).
    self.vm = view_model.new()
    -- How long a faulted session is given to come back before the UI declares
    -- it dead. Configurable because the right value is a property of the
    -- target device, not of the tool: a board that reboots into a ROM
    -- bootloader detaches the USB device and needs seconds to re-enumerate,
    -- while a plain cable glitch recovers in well under one. Clamped to a sane
    -- floor so a typo cannot disable recovery entirely.
    local grace = tonumber(config.get(cfg_data, "serial", "reconnect_grace_ms",
                                      self.vm.RECONNECT_GRACE_MS))
    if grace and grace >= 1000 and grace <= 60000 then
        self.vm.RECONNECT_GRACE_MS = grace
    end
    -- [serial] probe_port_busy: whether enumeration marks a port held by
    -- another program. OFF by default because the check opens every port, and
    -- opening can drive DTR on some USB-UART bridges — which resets a board
    -- wired for auto-reset. That is too destructive to do behind the user's
    -- back on every refresh, so it is an explicit opt-in for people who want
    -- to see "(busy)" in the list and accept the risk. Without it, an occupied
    -- port still reports its cause when the open fails.
    self._probe_port_busy = config.get(cfg_data, "serial", "probe_port_busy",
                                       false) == true
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
-- Same reason: create_class calls load_window_icon, which is defined further
-- down (after the class factory it belongs to). Without the declaration the
-- call resolves to a global nil and init_window crashes on first run.
local load_window_icon

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
    -- Warm the first frame BEFORE the window is shown.  ShowWindow exposes the
    -- window immediately, but the DX11 swapchain presents nothing until the
    -- first render pass completes (~0.3-1 s while the font atlas bakes on the
    -- first NewFrame); that gap is the "startup flash" where the client area
    -- shows the class brush/whatever is behind instead of the dashboard
    -- (measured: capture at t=0.98 s has no client content; t=1.31 s does).
    -- Drawing one full frame into the still-hidden swapchain makes the first
    -- visible moment already show the complete dashboard.  All bridge buffers
    -- were allocated (defaults) by imgui_bridge.new, so an empty dashboard
    -- draw is safe before Window:start() wires the core handle.
    if self.imgui then
        pcall(function()
            if self.imgui:frame() then
                pcall(self.imgui.draw, self.imgui, false, 0, 0)
                self.imgui:render()
            end
        end)
    end
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
    local ports, enum_err = xcom.list_ports({ probe = self._probe_port_busy })
    ports = ports or {}
    if enum_err ~= nil then
        -- Enumeration itself failed (not merely "no ports"): surface the cause
        -- instead of silently showing an empty list. Never touches device I/O.
        local msg = (xcom.describe_enum_error and xcom.describe_enum_error(enum_err))
                    or ("port enumeration failed (error " .. tostring(enum_err) .. ")")
        self:set_status_deferred(msg)
    end
    -- SIM: hardware-free generators live here (see core/serial_sim.lua).
    -- Only ever when the sim flag is on — machines with real ports keep the
    -- exact registry-only list (sim:available() gates on #list_ports()==0).
    if self._sim_active then
        for _, p in ipairs(self.sim:ports()) do
            ports[#ports + 1] = p
        end
    end
    self.imgui:set_ports(ports)
end

-- SIM helper: did the just-issued open target one of the simulator's virtual
-- port names?  Reads _sim_open_port (stamped in core_open).  Never called
-- unless _sim_active, so it is a no-op on hardware machines.
function Window:_sim_port_selected()
    local port = self._sim_open_port
    if not port or port == "" then return false end
    if not self.sim then return false end
    return self.sim.is_sim_port(port) and true or false
end


create_class = function(hinst)
    local wc = ffi.new("WNDCLASSA")
    wc.lpfnWndProc = WndProc
    wc.lpszClassName = "XComSerialLua"
    wc.hInstance = hinst
    -- Background brush: color the client area with the SAME page gray the
    -- dashboard paints (PAL.page #EEEEF0) instead of the white COLOR_WINDOW.
    -- Before the first DX11 present, Windows erases the just-shown window with
    -- this brush, so a white brush is exactly the "large white flash" seen on
    -- startup.  A gray brush removes the flash without any ShowWindow-timing
    -- refactor (see the startup-flicker note).  The handle is held at module
    -- scope for the window-class lifetime; WNDCLASS copies the value, so it
    -- must not be deleted before the last window is destroyed.
    if not page_brush then
        page_brush = w.gdi32.CreateSolidBrush(PAL.page)
    end
    wc.style = 0x0020  -- CS_OWNDC keeps the DX11 swap-chain target stable.
    wc.hbrBackground = ffi.cast("HBRUSH", page_brush)
    wc.hIcon = load_window_icon(w)
    return wc
end
Window._create_class = create_class

-- Window icon. The tray/Alt-Tab/taskbar image is the WINDOW's icon, not the
-- executable's, so the .rc resource alone is not enough — the class must carry
-- a handle. Three sources, most robust first:
--
--   1. the icon embedded in the running executable (IDI_APP in the launcher
--      .rc). Resolved through the module handle, so it is independent of the
--      working directory — which is what broke the taskbar icon in a packaged
--      build: the old code loaded "runtime\xcom.ico", a path that exists in the
--      source tree but not in the release layout, where the .ico sits beside
--      xcom.exe.
--   2. <exe dir>\xcom.ico and <exe dir>\runtime\xcom.ico, for a tree that ships
--      the icon as a loose file. Anchored on the module path rather than the CWD
--      so a shortcut with a different working directory still resolves it.
--   3. the predefined IDI_APPLICATION, so the window always shows something
--      rather than falling back to the generic blank frame.
load_window_icon = function(w)
    -- A NULL return is nil in LuaJIT (a null cdata compares equal to nil), so a
    -- plain truthiness test is the correct "did this load?" check.
    local module = w.user32.GetModuleHandleA(nil)
    local icon = w.user32.LoadIconA(module, ffi.cast("const char*", w.IDI_APP))
    if icon then
        return icon
    end
    -- Loose-file fallbacks. GetModuleFileNameA gives the running exe's path;
    -- strip the file name to get its directory.
    local buf = ffi.new("char[?]", 1024)
    local n = w.kernel32.GetModuleFileNameA(module, buf, 1024)
    if n and n > 0 then
        local exe = ffi.string(buf, n)
        local dir = exe:match("^(.*)[/\\][^/\\]*$") or "."
        for _, rel in ipairs({ "xcom.ico", "runtime\\xcom.ico" }) do
            icon = w.user32.LoadImageA(nil, dir .. "\\" .. rel, w.image.ICON,
                                       0, 0, w.image.LOAD_FROM_FILE +
                                       w.image.DEFAULT_SIZE)
            if icon then
                return icon
            end
        end
    end
    return w.user32.LoadIconA(nil, ffi.cast("const char*", w.IDI_APPLICATION))
end

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
-- System power broadcast (WM_POWERBROADCAST).  Values are Win32 constants kept
-- local here so ui/win32.lua (shared by other panels) stays untouched.
local WM_POWERBROADCAST = 0x0218
local PBT_APMRESUMESUSPEND = 0x0007
local PBT_APMRESUMEAUTOMATIC = 0x0008

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
    if m == WM_POWERBROADCAST then
        -- Handled resume returns TRUE (1); anything else falls through to the
        -- default handler so Windows state bookkeeping is untouched.
        if self:_on_power_broadcast(tonumber(wparam) or 0) then
            return 1
        end
    end

    if imgui_handled then
        return 0
    end

    return w.user32.DefWindowProcA(hwnd, msg, wparam, lparam)
end
jit.off(Window.dispatch)

-- Resume-from-sleep handler.  A suspended/reset USB serial adapter can leave
-- the session holding a stale handle: reads stall and writes fail with no
-- local cause.  We deliberately issue NO port I/O from a WndProc (it would
-- race the owner thread and the backend's overlapped handle); instead the
-- event is made visible and the authoritative status poll is pulled forward,
-- so a dead/vanished port surfaces through the existing status/FAULT/reconnect
-- path on the next frame.  A clearCommError-style active probe is a possible
-- follow-up but needs a new ABI entry point and real hardware to validate.
function Window:_on_power_broadcast(event)
    if event ~= PBT_APMRESUMESUSPEND and event ~= PBT_APMRESUMEAUTOMATIC then
        return false
    end
    if self.core and self.connected then
        self:set_status_deferred(
            "System resumed from sleep - verify the serial connection")
        -- Re-arm the 250 ms status timer to fire on the next loop iteration, so
        -- a port that faulted during sleep is reflected immediately rather than
        -- up to 250 ms later.  luv's start() is safe to call from a WndProc:
        -- it schedules, it does not re-enter Lua.
        if self._status_timer and self._status_timer_callback then
            self._status_timer:start(0, 250, self._status_timer_callback)
        end
    end
    self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
    return true
end
jit.off(Window._on_power_broadcast)

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
            -- Same empty-payload guard as _imgui_send_enabled: a truthy ""
            -- (whitespace-only HEX) would be silently dropped by core_send.
            if payload and payload ~= "" then self:core_send(payload, xcom.send_text) end
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

    -- header => caption for drag (unless on an interactive control).
    if cy < HEADER_H then
        -- When the ImGui bridge owns the header, it renders the window
        -- buttons AND the Settings/Lua toggle chips as InvisibleButtons
        -- in the rightmost IMGUI_HEADER_CLUSTER_W px.  Reserve that whole
        -- strip as HTCLIENT so clicks reach ImGui; the window buttons are
        -- dispatched inside the bridge (they are NOT the legacy GDI strip
        -- handled by _header_button_at).  Only the left/middle header stays
        -- HTCAPTION for dragging.
        if self.imgui then
            if cx >= client_w - IMGUI_HEADER_CLUSTER_W then
                return w.ht.HTCLIENT
            end
            return w.ht.HTCAPTION
        end
        -- Legacy GDI path: skip only the right 3 window-button boxes.
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
        self:_process_rx_batch(text)
        if self._log_active then
            xcom.log_append(self.core, text, #text)
        end
        if self.recv and self.recv.feed then
            self.recv.feed(text)
        end
    end
    -- Drain any charset bytes still held pending from a character torn at the
    -- final batch boundary (best effort; the converter shows the orphan byte
    -- as the code page default).  Without this a split trailing character
    -- would stay held forever, silently missing from the last viewport.
    if self._charset_active then
        local tail = charset.flush()
        if tail and #tail > 0 then
            self:_append_imgui_receive(tail)
        end
    end
end

function Window:on_close()
    -- WM_CLOSE can arrive more than once (custom button, Alt+F4, or a
    -- queued system message).  Closing is a one-shot transaction; ignoring
    -- re-entrant requests prevents duplicate core drains and DestroyWindow
    -- calls from leaving the message loop alive.
    if self._closing then return end
    self._closing = true
    -- Mirrors Python's closeEvent pipeline: stop auto-send, stop the poll
    -- timers (no new data while we drain), drain accepted bytes to the
    -- display, flush the log, then close the port and destroy the window.
    self:_set_autosend_enabled(false)
    if self._multi_timer then self._multi_timer:stop() end
    if self._display_timer then self._display_timer:stop() end
    if self._status_timer then self._status_timer:stop() end
    if self._script_timer then self._script_timer:stop() end
    if self._script_watch_timer then self._script_watch_timer:stop() end
    if self._sequence_timer then self:_stop_sequence() end
    -- SIM: disarm the pump before the drain/close (its uv handle must not
    -- survive past the core session; stop() is cheap and idempotent).
    if self._sim_active then self.sim:stop() end
    if self.scripts then self.scripts:shutdown() end
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
    if self.hwnd then
        w.user32.DestroyWindow(self.hwnd)
        self.hwnd = nil
    else
        w.user32.PostQuitMessage(0)
    end
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
    -- Persist the effective receive-tail window so a hand-edited config.ini
    -- survives round-trips (clamped value is what both sides actually use).
    config.set(data, "display", "receive_window_bytes", self._receive_window)
    config.set(data, "display", "charset", self._charset_name or "ASCII")
    config.set(data, "display", "tx_echo", self._tx_echo and true or false)
    -- Script engine state: enabled list + console visibility + auto-reload.
    if self.scripts then
        config.set(data, "script", "enabled",
            table.concat(self.scripts:enabled_list() or {}, ","))
        config.set(data, "script", "autorun_console",
            self._scripts_console_open and true or false)
        config.set(data, "script", "auto_reload",
            self.cfg.script_auto_reload and true or false)
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
    -- SIM: remember the requested port so the connected edge (in
    -- _render_ui_state, where port_state is confirmed OPEN) can decide
    -- whether to arm the simulator pump.  Only ever consulted while
    -- _sim_active.  Recorded here (not in _imgui_open) because the native
    -- on_btn_open path reaches the same core_open.
    self._sim_open_port = serial.port
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
    if DEBUG_MODE then
        dbg("[dbg] core_send len=%d flags=%d",
            data_bytes and #data_bytes or -1, tonumber(flags) or -1)
    end
    if not self.core then
        return false, xcom.err_not_open
    end
    -- Reconnect grace interlock: the send controls are disabled while the HSM
    -- is RECONNECTING, but a keyboard shortcut / script / send-file path can
    -- still reach here. Refuse with a visible prompt instead of pushing bytes
    -- at a port that is mid-recovery.
    if self.vm:recovering() then
        if self.imgui then
            self.imgui:set_status("串口连接异常，等待恢复，暂不能发送")
        end
        return false, xcom.err_not_open
    end
    if data_bytes and #data_bytes > 0 then
        -- Send-convert hook (on.send): a script may transform the payload or
        -- cancel the send by returning nil.  Errors fall back to the original
        -- payload (a broken script must not block transmission).
        if self.scripts then
            local ok, hooked = pcall(self.scripts.dispatch_send, self.scripts,
                data_bytes)
            if ok then
                if hooked == nil then return false, nil end
                if type(hooked) == "string" then data_bytes = hooked end
            else
                io.stderr:write("[scripts] send funnel: " .. tostring(hooked) .. "\n")
            end
        end
        local rc = tonumber(xcom.send(self.core, data_bytes, flags or xcom.send_text))
        if rc ~= xcom.ok then
            if self.status and self.status.labels then
                c.set_text(self.status.labels[3],
                           "send failed: " .. (STATUS_TEXT[rc] or tostring(rc)))
            end
            -- Return the status so a streaming caller (send_file) can
            -- distinguish "buffer full" (back off and retry) from "not open"
            -- / "io error" (abort).  errcode is the ABI status (e.g. -5 full).
            return false, rc
        else
            self:_echo_tx(data_bytes)
            if self._sim_active and self.sim:is_running() then
                -- SIM: a successful TX on a virtual session lets the echo /
                -- at-modem profiles queue their reply.  Only reached while
                -- the pump owns the session, so a real-port send never
                -- touches it.
                self.sim:tx_observe(data_bytes)
            end
        end
    end
    return true, nil
end

-- Echo a transmitted payload into the SAME view and log the receive path
-- uses ([display] tx_echo, default on — llcom's showSend semantics: the
-- user types a command and sees it land in the receive window, and the
-- auto-save capture keeps it so the log reads like a session transcript).
-- Display side goes through _append_imgui_receive (so auto_clear/frame-gap
-- bookkeeping applies and the tail trims identically), with a "TX: " prefix
-- on its own row; the log gets the same line RAW (byte-faithful contract:
-- CRLF payloads keep their CR on disk, while the view folds it to LF like
-- every RX line).  Runs only on the success path of core_send: a failed
-- write never pollutes the transcript.
function Window:_echo_tx(payload)
    if not self._tx_echo or not payload or payload == "" then
        return
    end
    -- Open a fresh row when the view tail sits mid-line (RX fragment or a
    -- previous echo without its own newline — the same anchor the frame-gap
    -- breaker consults).
    if self._view_tail_open then
        self:_append_imgui_receive("\n")
    end
    local line = "TX: " .. payload
    if self._log_active and self.core then
        -- Raw copy keeps the payload's own bytes (a CRLF payload stays CRLF on
        -- disk); only close the row when the payload did not end with one —
        -- an unconditional "\n" here used to double-terminate CRLF payloads.
        local raw = line
        if raw:sub(-1) ~= "\n" then
            raw = raw .. "\n"
        end
        xcom.log_append(self.core, raw, #raw)
    end
    -- Display copy: guarantee the row closes even for payloads that lack a
    -- terminator, and fold CRLF the way the receive text view does.
    local display = line:gsub("\r\n", "\n")
    if display:sub(-1) ~= "\n" then
        display = display .. "\n"
    end
    self:_append_imgui_receive(display)
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
    -- Display-side enforcement cache for the two options the core/DLL never
    -- act on (see the _append_imgui_receive decision comments).  Refreshed
    -- here because this runs on every ActionSyncDisplay (widget edits write
    -- straight into the Lua-owned int buffers) and on every connect edge.
    self._auto_clear_bytes = opts.auto_clear_bytes or 0
    if self.imgui and self.imgui.frame_gap_enabled and self.imgui.frame_gap_ms then
        local en = self.imgui.frame_gap_enabled[0] ~= 0
        local ms = self.imgui.frame_gap_ms[0]
        if not (ms > 0) then ms = 0 end
        self._frame_gap_en = en and ms > 0
        self._frame_gap_ms = ms
    end
    if self.imgui and self.imgui.charset then
        -- Charset selection: the C++ combo (Phase 4) writes the index into
        -- imgui.charset; resolve it back to a name here.  Hex view is
        -- byte-faithful "AA BB" text, so conversion is suspended while active.
        local name = imgui_bridge.CHARSET_ITEMS[self.imgui.charset[0] + 1]
        if name and name ~= self._charset_name then
            self._charset_name = name
            charset.set(name)
        end
    end
    self._charset_active = not opts.receive_hex and
        (self._charset_name ~= "ASCII" and self._charset_name ~= "UTF-8")
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
        -- The log always records the RAW batch: display-side transforms
        -- (charset conversion, script hooks, line filter) must never alter
        -- the byte-faithful capture.
        if self._log_active then
            xcom.log_append(self.core, text, #text)
        end
        self:_process_rx_batch(text)
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

-- Display-side receive funnel.  Runs the RAW drained batch through the
-- user-script engine (charset convert -> on.receive hooks -> line filter —
-- the engine itself is a no-op passthrough when no script is enabled) and
-- appends the result to the ImGui tail.  nil result = the batch was consumed
-- by a script or filtered out entirely; nothing reaches the viewport.
-- Perf note: this sits on the 10 ms drain path, so the engine's fast paths
-- (no scripts -> single boolean check; no filter rules -> single table scan)
-- are the budget-critical ones (see MEMORY.md receive-chain rules).
function Window:_process_rx_batch(text)
    -- Auto frame-break ([display] frame_gap_ms, "自动断帧").  NEITHER the
    -- core nor the ImGui DLL acts on it (the DLL only renders the toggle +
    -- ms field against Lua-owned int buffers; the core ABI has no gap
    -- concept), so it is enforced here, display-side: when this drained
    -- batch lands more than N ms after the previous one AND the view tail
    -- ends mid-line, force a chunk boundary + newline first so a half frame
    -- never sits open across an idle gap.  The auto-save log written by
    -- poll_display carries the raw batch untouched — this is a pure display
    -- transform.  uv.now() is the loop-cached monotonic clock, so the
    -- several batches drained inside ONE poll never fake a gap.
    if self._frame_gap_en then
        local now = uv.now()
        local last = self._rx_last_batch_ms
        if last and now - last > self._frame_gap_ms and self._view_tail_open then
            self:_append_imgui_receive("\n")
        end
        self._rx_last_batch_ms = now
    else
        -- While off, keep the anchor unarmed so re-enabling never breaks on
        -- a stale timestamp from the previous enabled stretch.
        self._rx_last_batch_ms = nil
    end
    -- Charset conversion (display only; GB2312/BIG5/SJIS/UTF-16 -> UTF-8).
    -- Passthrough returns the same string reference at zero cost.
    -- IMPORTANT: convert() returns NIL when this batch was entirely consumed
    -- by a multi-byte character split across the drain boundary — the bytes
    -- are held INSIDE charset.lua (pending) for the next batch.  Never coerce
    -- that nil back to the raw text (the old `or text` did): a lone DBCS lead
    -- byte is not valid UTF-8, so displaying it put garbage in the viewport.
    -- Withhold the batch and let the next drain complete the character.
    if self._charset_active then
        text = charset.convert(text)
        if text == nil then
            return
        end
    end
    if self.scripts then
        local ok, processed = pcall(self.scripts.process_rx, self.scripts, text)
        if not ok then
            io.stderr:write("[scripts] rx funnel: " .. tostring(processed) .. "\n")
            return
        end
        if processed == nil or processed == "" then
            return
        end
        text = processed
    end
    self:_append_imgui_receive(text)
end

-- Append a receive batch to the tail window.  With an incremental-capable
-- ImGui DLL the bytes are handed straight to C++ (which owns the sliding
-- window, the line-offset index AND the absolute base across trims), so Lua
-- keeps NO copy of the view text: no chunk table, no per-frame concat/trim,
-- one FFI call per drained batch.  Legacy path (old DLL, or the fake bridge
-- in tests): retain chunks and rebuild the tail in _flush_imgui_receive.
function Window:_append_imgui_receive(text)
    if not text or #text == 0 then return end
    self._imgui_receive_total = (self._imgui_receive_total or 0) + #text
    local window = self._receive_window or 65535
    local incremental = self.imgui and self.imgui.can_append_receive
        and self.imgui:can_append_receive()
    if incremental then
        self.imgui:append_receive(text)
    else
        local chunks = self._imgui_receive_chunks
        chunks[#chunks + 1] = text
        self._imgui_receive_chunk_bytes = self._imgui_receive_chunk_bytes + #text
        -- Retire whole exhausted chunks by advancing the cursor; their bytes
        -- leave the accounting immediately so the next append starts clean.
        -- A chunk is only retired when what REMAINS after retiring it still
        -- exceeds the window — otherwise a huge middle chunk would be dropped
        -- whole and the flush's :sub(-window) tail-trim handles it instead.
        local cursor = self._imgui_receive_cursor or 1
        while cursor < #chunks and
              self._imgui_receive_chunk_bytes - #chunks[cursor] > window do
            self._imgui_receive_chunk_bytes = self._imgui_receive_chunk_bytes - #chunks[cursor]
            cursor = cursor + 1
        end
        self._imgui_receive_cursor = cursor
        self._imgui_receive_dirty = true
    end
    -- Auto frame-break anchor: the view ends mid-line unless this chunk's
    -- last byte is '\n' (the DLL line model — see xcom_imgui_bridge.cpp's
    -- receive_line_offsets_ rescan: only '\n' opens a new row).
    self._view_tail_open = text:byte(-1) ~= 10
    -- Auto-clear enforcement ([display] auto_clear_bytes, "自动清空").  The
    -- core ABI stores this field in XcomDisplayOptions but never acts on it
    -- (xcom_set_options only keeps hex/timestamp/pause — xcom_abi.cpp), and
    -- the ImGui DLL only renders the widget, so the threshold lives HERE.
    -- Anchor decision: at the end of every append, because
    -- _imgui_receive_total is exactly "bytes shown since the last clear" and
    -- the append is the single funnel all display bytes flow through
    -- (charset/script transforms already applied, so the byte count matches
    -- what the user actually sees).  Semantics mirror SSCOM's: once the
    -- accumulated view since the last clear REACHES the threshold, the whole
    -- view resets — including the batch that crossed the line — and display
    -- continues from empty.  The reset touches view state only: the
    -- auto-save log was already written from the RAW batch in poll_display
    -- (data-loss contract) and the core counters stay untouched.
    local limit = self._auto_clear_bytes or 0
    if limit > 0 and self._imgui_receive_total >= limit then
        self:_clear_imgui_view()
    end
end

function Window:_flush_imgui_receive()
    if not self._imgui_receive_dirty then return false end
    local chunks = self._imgui_receive_chunks
    local cursor = self._imgui_receive_cursor or 1
    local window = self._receive_window or 65535
    -- The flush APPENDS the newly drained batches to the retained tail from
    -- the previous flush, then trims the combined buffer to the window.
    -- (Replacing the buffer with just the new batches — the old behaviour —
    -- made every flush discard all prior history, so the viewport only ever
    -- showed the last few hundred bytes of an active stream.)
    local combined
    local count = #chunks - cursor + 1
    if count <= 0 then
        combined = self._imgui_receive or ""
    elseif count == 1 then
        combined = (self._imgui_receive or "") .. chunks[cursor]
    else
        combined = (self._imgui_receive or "") .. table.concat(chunks, "", cursor)
    end
    -- Keep the tail one byte under the window size: the native buffer is
    -- sized capacity-1 (NUL) and TRUNCATES PREFIX-FIRST, so pushing exactly
    -- `window` bytes would silently drop the freshest byte at saturation.
    local tail = #combined >= window and combined:sub(-(window - 1)) or combined
    self._imgui_receive = tail
    self._imgui_receive_chunks = {}
    self._imgui_receive_cursor = 1
    self._imgui_receive_chunk_bytes = 0
    self._imgui_receive_dirty = false
    return true
end

-- Reset the receive VIEW only (ImGui tail buffer + absolute coordinate
-- space).  Shared by the manual Clear action and the auto_clear_bytes
-- threshold hit in _append_imgui_receive.  Deliberately NOT part of this:
-- the auto-save log (byte-faithful, written from the raw batch in
-- poll_display) and the core rx/tx counters — an auto clear must never
-- touch either, per the data-loss contract documented on poll_display.
function Window:_clear_imgui_view()
    self._imgui_receive = ""
    self._imgui_receive_chunks = {}
    self._imgui_receive_cursor = 1
    self._imgui_receive_chunk_bytes = 0
    self._imgui_receive_dirty = false
    -- Restart the absolute coordinate space with the buffer: the native side
    -- drops any selection on the empty push, base resets there too.
    self._imgui_receive_total = 0
    self._view_tail_open = false
    if self.imgui then
        self.imgui:set_receive_text("")
    end
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

-- Upper bound on the OPENING transitional state. The core's native serial open
-- is bounded to ~2 s; 5 s leaves generous headroom (slow USB enumeration,
-- driver retries) before the UI declares the open dead and faults back so the
-- user can retry.
local OPENING_TIMEOUT_MS = 5000

-- Close-side counterpart. The ABI close waits up to 2 s for its own teardown,
-- so a healthy close resolves inside this with room to spare; the timeout only
-- fires when the core never confirms, which is the case that would otherwise
-- strand the session in CLOSING permanently.
local CLOSING_TIMEOUT_MS = 5000

function Window:request_frame(interval_ms)
    if not self.imgui then return end
    local now = uv.now()
    local next_frame = now + (interval_ms or FRAME_INTERVAL_ACTIVE_MS)
    if not self._imgui_next_frame or next_frame < self._imgui_next_frame then
        self._imgui_next_frame = next_frame
    end
    -- Demand latch: any producer that pulls a frame means real screen content
    -- may have changed.  render_imgui drains this; when it is zero it skips the
    -- expensive idle-heartbeat redraw (below).  Only a request here (input,
    -- receive, status, data-loss, script, timer) lifts the frame off the floor.
    self._frame_demand = (self._frame_demand or 0) + 1
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
    -- Demand-gated idle suppression.  A WARP (software) frame costs ~45-60 ms of
    -- CPU, so redrawing twice a second while the app sits quiet (no input, no
    -- receive, no status change) is pure burn.  Only render when a producer has
    -- asked for a frame (request_frame/set_status_deferred/input/receive bump
    -- self._frame_demand) since the last render.  Otherwise we do NOT call the
    -- expensive frame(); we merely re-arm a conservative probe so a missed
    -- producer can never leave the screen permanently stale.  A nil
    -- _imgui_next_frame (startup, expose, resize) always forces a frame.
    if self._imgui_next_frame ~= nil and (self._frame_demand or 0) == 0 then
        self._imgui_next_frame = now + FRAME_INTERVAL_IDLE_MS
        return
    end
    self._frame_demand = 0
    self._imgui_next_frame = now + FRAME_INTERVAL_IDLE_MS
    if not self.imgui:frame() then return end
    -- P3 commit: the deferred status text (set_status_deferred) lands in this
    -- frame — one FFI call, newest value wins.
    if self._status_dirty ~= nil then
        self.imgui:set_status(self._status_dirty)
        self._status_dirty = nil
    end
    -- P3 commit: highlight rules from the script engine (coalesced the same
    -- way — one packed push per frame at most; no-op on pre-Phase-4 DLLs
    -- where set_highlight_rules is nil).
    if self._script_rules_dirty and self.imgui.set_highlight_rules then
        self._script_rules_dirty = false
        self.imgui:set_highlight_rules(self._script_rules or {})
    end
    -- P3 commit: script console log tail (ring snapshot, only when the
    -- engine logged something new since the last frame).
    if self.scripts and self.imgui.set_script_log then
        local log_text, dirty = self.scripts:log_lines()
        if dirty then self.imgui:set_script_log(log_text) end
    end
    self:_pump_script_console()
    self:_pump_plugin_pages()
    -- Scope panel follows the script engine, not a header chip: before the
    -- frame is drawn, flip the DLL's scope visibility to match whether any
    -- script is currently feeding wave points.
    self:_reconcile_scope_visibility()
    local receive_changed = self:_flush_imgui_receive()
    local rx = self._imgui_receive or ""
    if receive_changed then
        -- Window start in absolute bytes: total minus what the tail keeps.
        self.imgui:set_receive_text(rx, (self._imgui_receive_total or 0) - #rx)
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
    -- Bit 29 (retired header-scope bit) now arrives ONLY from the scope
    -- panel's own title-bar X (scope_visible_ was cleared natively).  Record
    -- the dismissal so the activity reconciler does not immediately reopen it.
    if bit.band(actions, IMGUI_ACTION.scope_retired_bit) ~= 0 then
        self._scope_dismissed = true
        self._scope_open = false
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
    local sent = 0
    local skipped_unchecked = false   -- has text but the enable box is clear
    local bad_hex = nil               -- first slot whose HEX text failed to parse
    for index = 0, 7 do
        local text, enabled = self.imgui:multi_entry(index)
        if text ~= "" and not enabled then
            skipped_unchecked = true
        end
        if enabled and text ~= "" then
            local payload = xcom.build_send_payload(text,
                self.imgui.multi_hex[0] ~= 0, self.imgui.multi_crlf[0] ~= 0)
            if payload == nil and bad_hex == nil then
                bad_hex = index + 1
            end
            -- build_send_payload returns "" (a TRUTHY empty string) for a
            -- whitespace-only HEX slot; core_send silently drops empty data,
            -- which reads as "clicked Send enabled and nothing happened".
            if payload and payload ~= "" then
                self:core_send(payload, xcom.send_text)
                sent = sent + 1
            end
        end
    end
    -- Silence is what made the original report ("clicked it and nothing
    -- happened") unactionable, so every no-send path explains itself once.
    if sent == 0 and self.imgui then
        if bad_hex then
            self:set_status_deferred("multi slot " .. bad_hex ..
                ": invalid HEX, nothing sent")
        elseif skipped_unchecked then
            self:set_status_deferred(
                "multi: tick the enable box on the rows to send")
        else
            self:set_status_deferred("multi: no enabled rows with text")
        end
    end
end

function Window:_imgui_send_slot(index)
    if not self.imgui then return end
    local text, enabled = self.imgui:multi_entry(index)
    if not enabled or text == "" then return end
    local payload = xcom.build_send_payload(text,
        self.imgui.multi_hex[0] ~= 0, self.imgui.multi_crlf[0] ~= 0)
    if payload == nil then
        self:set_status_deferred("multi slot " .. (index + 1) ..
            ": invalid HEX, nothing sent")
        return
    end
    if payload ~= "" then self:core_send(payload, xcom.send_text) end
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
    -- Bounded read via the bridge (ffi.string(self.imgui.send) would keep
    -- scanning past the SEND_CAPACITY buffer until a '\0' if ImGui ever left
    -- the input unterminated at capacity -- the over-read crashes the process).
    local text = self.imgui:send_text()
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

-- ---- script console (Phase 4 C++ widgets; handlers exist now so the
-- action bits map before the DLL ships) --------------------------------------

function Window:_imgui_scripts_toggle()
    -- The C++ side owns the open/close state (scripts_visible_); Lua only
    -- mirrors it for config persistence.
    self._scripts_console_open = not self._scripts_console_open
    self:request_frame()
end

-- Scope panel ownership.  The header "波形/Scope" chip is gone: the script
-- engine owns the panel's lifetime.  While an enabled script is feeding wave
-- points (core/waveform.lua M.active() — a push within the idle grace period)
-- the ImPlot surface is shown; once every feeder goes quiet (script disabled /
-- unloaded / stopped pushing) the panel hides.  Called once per rendered frame
-- from render_imgui, so the DLL visibility always tracks the engine state.
--
-- The panel's own title-bar X still reports ActionToggleScope (bit 29), which
-- Lua no longer maps to a command.  _dispatch_imgui_actions watches for it and
-- sets `_scope_dismissed`, which sticks until a script explicitly reopens the
-- panel via wave.show() — activity alone must never pop it back, so a user who
-- closed the plot keeps it closed across data bursts.
function Window:_reconcile_scope_visibility()
    if not self.imgui or not self.imgui.set_scope_visible then return end
    if not self._scope_owner then
        self._scope_owner = waveform
        -- Script-side explicit reopen: the only way to clear the dismissal
        -- latch below.  Without this a closed panel could never come back.
        waveform.set_host_reopen(function()
            self._scope_dismissed = false
            self:request_frame()
        end)
    end
    local want = self._scope_owner.active() and true or false
    if self._scope_dismissed then want = false end
    if want ~= self._scope_open then
        self._scope_open = want
        self.imgui:set_scope_visible(want)
    end
end

function Window:_imgui_settings_toggle()
    self._settings_open = not self._settings_open
    self:request_frame()
end

-- ---------------------------------------------------------------------------
-- Headless UI smoke hooks (automated screenshot verification).
--
-- Synthetic mouse input cannot reach the ImGui backend, so a verification
-- script forces the floating windows open through env vars instead of
-- clicks.  Both branches are strict no-ops unless the env var equals "1",
-- so normal runs see zero behavior change.  Called once from Window:start()
-- after the imgui bridge and the _scope_open/_settings_open mirrors exist.
-- ---------------------------------------------------------------------------

function Window:_smoke_env_hooks()
    if not self.imgui then return end
    if os.getenv("XCOM_SMOKE_SETTINGS") == "1" then
        -- Mirror the header gear chip: the Lua flag drives config
        -- persistence; the DLL owns the real visibility (settings_visible_)
        -- through the imgui_bridge wrapper over xcom_imgui_set_settings_visible.
        self._settings_open = true
        if self.imgui.set_settings_visible then
            self.imgui:set_settings_visible(true)
        end
    end
    if os.getenv("XCOM_SMOKE_SCOPE") == "1" then
        -- The scope panel is script-owned now: scripts/smoke_ui.lua feeds
        -- wave.push on a timer, which stamps waveform activity and makes
        -- _reconcile_scope_visibility() show the panel on the next frame.
        -- Nothing to force here — the env var only needs to prove the route;
        -- leave the visibility to the same path production uses so the smoke
        -- check exercises the real ownership logic.
        self._scope_open = false
    end
    if os.getenv("XCOM_SMOKE_OPEN") == "1" and self._sim_active then
        -- Synthetic clicks cannot reach ImGui, so the end-to-end simulator
        -- check opens the VIRTUAL session programmatically: stamp the combo
        -- selection exactly like a user pick would (_serial_config reads
        -- _imgui_port first) and issue the same core_open the "打开" button
        -- routes through.  The connected edge in _render_ui_state then arms
        -- the sim pump as usual.  Strictly gated: hardware machines and
        -- plain runs never enter this branch.
        self._imgui_port = "VIRTUAL"
        -- Optional profile override for the E2E check (e.g. "wave" feeds the
        -- Scope window); unknown names are rejected by the sim itself.
        local want_profile = os.getenv("XCOM_SMOKE_SIM_PROFILE")
        if want_profile and want_profile ~= "" then
            self.sim:profile(want_profile)
        end
        self:core_open()
    end
    local hw_port = os.getenv("XCOM_SMOKE_HW_PORT")
    if hw_port and hw_port ~= "" then
        -- Real-hardware E2E: open an actual COM port through the exact same
        -- core_open path the "打开" button uses.  The name is not VIRTUAL/TEST
        -- so the connected edge never arms the sim pump — bytes come from the
        -- physical read thread, exercising the full C-read -> ring -> drain ->
        -- incremental append -> ImGui render chain on production data.
        self._imgui_port = hw_port
        self:core_open()
    end
    self:request_frame()
end

-- Plugin settings pages (C++ spec-rendered widgets -> Lua callbacks):
-- diff the engine's ui.page() declarations against what the DLL currently
-- holds, push additions/changes (removals as spec=nil), then drain queued
-- interactions back into the owning script's ui.event callback.
function Window:_pump_plugin_pages()
    if not self.scripts or not self.imgui then return end
    if not self.imgui.set_plugin_page then return end   -- pre-settings DLL
    self._plugin_pushed = self._plugin_pushed or {}
    local pages = self.scripts:collect_ui_pages()
    local seen = {}
    for _, page in ipairs(pages) do
        seen[page.id] = true
        local signature = page.title .. "\1" .. page.spec
        if self._plugin_pushed[page.id] ~= signature then
            self._plugin_pushed[page.id] = signature
            self.imgui:set_plugin_page(page.id, page.title, page.spec)
        end
    end
    for id in pairs(self._plugin_pushed) do
        if not seen[id] then
            self._plugin_pushed[id] = nil
            self.imgui:set_plugin_page(id, id, nil)   -- remove stale tab
        end
    end
    local events = self.imgui:take_plugin_events()
    if events then
        for _, event in ipairs(events) do
            pcall(function() self.scripts:dispatch_ui_event(
                event.page, event.kind, event.widget, event.value) end)
        end
    end
end

-- Script Console event pump (one batch per rendered frame):
--   * push the script list + sync enable checkboxes (engine <-> C++ buffer);
--   * drain C++ events (select/reload/new/folder/clear) into the engine;
--   * drain the REPL command and the editor Ctrl+S save event.
-- All no-ops on a pre-Phase-4 DLL (symbol probes return nil).
function Window:_pump_script_console()
    if not self.scripts or not self.imgui then return end
    -- 1) Keep the list + enable buffer in sync (cheap: only when the set of
    --    scripts changed OR enable states diverge — compare the packed list
    --    signature).
    if self.imgui.set_scripts then
        local names = self.scripts:script_names()
        -- Signature covers names AND labels: an external editor can change a
        -- script's @name/@desc (after a hot reload) without the filename set
        -- changing, and the console list must follow that too.
        local labels = self.scripts:script_labels()
        local signature = table.concat(names, ",") .. "\1" ..
            table.concat(labels, ",")
        if signature ~= self._script_list_signature then
            self._script_list_signature = signature
            self.imgui:set_scripts(names, labels)
        end
        -- Copy enable state engine -> C++ checkbox buffer once per frame
        -- only when the console is open (the checkboxes write back through
        -- the same buffer the engine reads below).
        if self._scripts_console_open and self.imgui._script_enabled_buf then
            local buf = self.imgui._script_enabled_buf
            for i, name in ipairs(names) do
                buf[i - 1] = self.scripts:is_enabled(name) and 1 or 0
            end
        end
    end
    -- 2) Editor save event (Ctrl+S): write the file, reload the script.
    if self.imgui.take_editor_save then
        local path, text = self.imgui:take_editor_save()
        if path then
            local f = io.open(path, "wb")
            if f then
                f:write(text)
                f:close()
                if self.scripts then
                    for i, name in ipairs(self.scripts:script_names()) do
                        if self.scripts.scripts[name] and
                            self.scripts.scripts[name].path == path then
                            self.scripts:reload(name)
                            break
                        end
                    end
                end
            else
                io.stderr:write("[scripts] cannot save " .. tostring(path) .. "\n")
            end
        end
    end
    -- 3) Console events.
    if self.imgui.take_script_events then
        local events = self.imgui:take_script_events()
        if events then
            local names = self.scripts:script_names()
            for _, event in ipairs(events) do
                local name = names[event.index + 1]
                if event.type == 1 then       -- Edit / select
                    if event.flag then
                        -- Ctrl+S save marker: consumed by take_editor_save.
                    elseif name then
                        self._script_edit_name = name
                        self.imgui:script_select(event.index)
                        local record = self.scripts.scripts[name]
                        if record then
                            local f = io.open(record.path, "rb")
                            if f then
                                local text = f:read("*a")
                                f:close()
                                self.imgui:script_load_editor(record.path, text or "")
                            end
                        end
                    end
                elseif event.type == 2 then   -- Reload
                    if name then self.scripts:reload(name) end
                elseif event.type == 3 then   -- Open folder (shell-execute)
                    local dir = (self.config_path and
                        self.config_path:match("^(.*)[/\\]") or ".") .. "/scripts"
                    -- Non-blocking shell dispatch; see w.open_folder. The
                    -- previous os.execute('start ...') blocked the message
                    -- pump and interpolated the path into a command line.
                    w.open_folder(dir)
                elseif event.type == 4 then   -- Clear log
                    self.scripts:clear_log()
                elseif event.type == 5 then   -- New script
                    self:_script_create_new()
                end
            end
        end
    end
    -- 4) Enable-state feedback: C++ checkboxes -> engine (the buffer is
    --    Lua-owned; compare against the engine state and apply deltas).
    if self._scripts_console_open and self.imgui._script_enabled_buf then
        local names = self.scripts:script_names()
        local buf = self.imgui._script_enabled_buf
        for i, name in ipairs(names) do
            local want = buf[i - 1] ~= 0
            if want ~= self.scripts:is_enabled(name) then
                self.scripts:enable(name, want)
            end
        end
    end
    -- 5) REPL command.
    if self.imgui.take_script_command then
        local command = self.imgui:take_script_command()
        if command and command ~= "" then
            self.scripts:eval_command(command)
        end
    end
end

-- Create a new script file with a starter template (unique numbered name).
function Window:_script_create_new()
    local dir = (self.config_path and
        self.config_path:match("^(.*)[/\\]") or ".") .. "/scripts"
    local n = 1
    while self.scripts.scripts[string.format("new_%d.lua", n)] or
          io.open(dir .. string.format("/new_%d.lua", n), "rb") do
        n = n + 1
    end
    local name = string.format("new_%d.lua", n)
    local path = dir .. "/" .. name
    local f = io.open(path, "wb")
    if not f then
        io.stderr:write("[scripts] cannot create " .. path .. "\n")
        return
    end
    f:write("-- " .. name .. "\n-- TODO: your script here.\n\n")
    f:close()
    self.scripts:load_all()
    self._script_list_signature = nil  -- force list re-push next frame
    self.scripts:enable(name, true)
    self.scripts:log(3, name, "created")
end

-- ---- sequential multi-send ("Run" command list) ------------------------------
-- Sends every ENABLED entry on the current page, one per gap interval, via a
-- self-rearming one-shot uv timer (not a period timer: entries can be
-- disabled/skipped, and a period timer would drift and double-fire across a
-- stop/restart).  Run doubles as Stop while a sequence is in flight.
function Window:_imgui_run_sequence()
    if self._sequence_timer then
        self:_stop_sequence()
        return
    end
    if not self.imgui then return end
    local entries = {}
    for index = 0, 7 do
        local text, enabled = self.imgui:multi_entry(index)
        if enabled and text ~= "" then entries[#entries + 1] = text end
    end
    if #entries == 0 then
        self:set_status_deferred("sequence: no enabled entries on this page")
        return
    end
    local gap = 100
    if self.imgui.multi_gap then
        gap = math.max(0, tonumber(self.imgui.multi_gap[0]) or 100)
    end
    self._sequence_entries = entries
    self._sequence_index = 0
    self._sequence_timer = uv.new_timer()
    local step
    step = function()
        self._sequence_index = self._sequence_index + 1
        local index = self._sequence_index
        if index > #entries or not self.imgui then
            self:_stop_sequence()
            return
        end
        local ok, err = pcall(function()
            local payload = xcom.build_send_payload(entries[index],
                self.imgui.multi_hex[0] ~= 0, self.imgui.multi_crlf[0] ~= 0)
            if payload then self:core_send(payload, xcom.send_text) end
        end)
        if not ok then io.stderr:write("[sequence] " .. tostring(err) .. "\n") end
        if index >= #entries then
            self:_stop_sequence()
            return
        end
        self:set_status_deferred(string.format("sequence %d/%d", index, #entries))
    end
    jit.off(step, true)
    self._sequence_timer:start(0, gap, step)
end

function Window:_stop_sequence()
    if self._sequence_timer then
        self._sequence_timer:stop()
        self._sequence_timer:close()
        self._sequence_timer = nil
    end
    self._sequence_entries = nil
    self:set_status_deferred("sequence done")
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
        -- Open failures push the raw native Win32 code (CreateFileW /
        -- SetCommState) into this ring, so translate the codes we know into an
        -- actionable cause instead of showing a bare "io error". Unknown codes
        -- keep the original message untouched.
        local cause = xcom.describe_open_error and xcom.describe_open_error(err.code)
        local text
        if cause then
            text = string.format("E%d: %s (%s)", err.code, cause, err.message)
        else
            text = string.format("E%d: %s", err.code, err.message)
        end
        if self.imgui then
            -- P3 deferred: coalesced into the next rendered frame.
            self:set_status_deferred(text)
        end
        c.set_text(self.status.labels[4], text)
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
        -- OPENING watchdog: the async open should resolve within the core's
        -- own ~2 s native window. If neither take_open_result nor the snapshot
        -- has moved us out of OPENING after OPENING_TIMEOUT_MS, force the
        -- transitional state to FAULT so the user is not stuck on a spinner
        -- with the port interlock frozen.
        if self._opening_deadline == nil then
            self._opening_deadline = uv.now() + OPENING_TIMEOUT_MS
        elseif uv.now() >= self._opening_deadline and
               self.vm.hsm.state == self.vm.STATE_OPENING then
            self.vm:force_fault()
            self._opening_deadline = nil
            if self.imgui then
                self.imgui:set_status("Open timed out; check the port and parameters")
            end
            self:_render_ui_state()
            return self:_poll_errors()
        end
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
    else
        -- Any state other than OPENING clears the watchdog anchor so the next
        -- open intent starts a fresh window.
        self._opening_deadline = nil
    end
    if self.vm.hsm.state == self.vm.STATE_CLOSING then
        -- CLOSING watchdog, mirroring the OPENING one. xcom_close waits on the
        -- core (bounded there by the ABI's own timeout), but a port whose
        -- teardown never completes leaves the HSM in CLOSING with open and
        -- close both refused — the same frozen-interlock symptom as a stuck
        -- OPENING, and with no recovery path at all. Forcing FAULT restores
        -- the manual reconnect route, which is strictly better than a state
        -- the user cannot leave.
        if self._closing_deadline == nil then
            self._closing_deadline = uv.now() + CLOSING_TIMEOUT_MS
        elseif uv.now() >= self._closing_deadline then
            self.vm:force_fault()
            self._closing_deadline = nil
            if self.imgui then
                self.imgui:set_status(
                    "Close timed out; the port did not confirm teardown")
            end
            self:_render_ui_state()
            return self:_poll_errors()
        end
    else
        self._closing_deadline = nil
    end
    -- Live DTR/RTS hot switch.  The header toggles only write the Lua-owned
    -- int buffers, so without this a user check would not reach the wire until
    -- the NEXT open — the panel would show a level the port is not actually
    -- driving.  Apply on change while OPEN; errors are reported once per edge.
    if self.vm.hsm.state == self.vm.STATE_OPEN and self.imgui and self.imgui.dtr then
        local dtr = self.imgui.dtr[0] ~= 0
        local rts = self.imgui.rts[0] ~= 0
        if dtr ~= self._lines_dtr or rts ~= self._lines_rts then
            self._lines_dtr = dtr
            self._lines_rts = rts
            local rc = xcom.set_lines and xcom.set_lines(self.core, dtr, rts)
            if rc ~= nil and tonumber(rc) ~= xcom.ok and self.imgui then
                self:set_status_deferred(
                    "DTR/RTS not applied: " .. (STATUS_TEXT[tonumber(rc)] or tostring(rc)))
                -- Snap the mirrors back so the UI does not claim a level the
                -- port rejected (e.g. RTS under flow control).
                self._lines_dtr = nil
                self._lines_rts = nil
            end
        end
    end
    local snap = xcom.get_snapshot(self.core)
    if snap then
        self._rx_bytes = snap.rx_bytes
        self._tx_bytes = snap.tx_bytes
        self.port_state = snap.port_state
        self.generation = snap.generation
        -- Data-loss accounting is per SESSION.  The core counters are monotonic
        -- across opens, so "lost this session" is measured from the first
        -- snapshot of each generation, never from zero.  A generation change
        -- (new open) also retires any latched loss banner.
        if snap.generation ~= self._loss_gen then
            self._loss_gen = snap.generation
            self._loss_base_pool = snap.rx_pool_exhausted_bytes or 0
            self._loss_base_overrun = snap.overrun_errors or 0
            self._loss_base_bp = snap.rx_backpressure_events or 0
            self._loss_seen = 0
            self._bp_seen = 0
            self._loss_banner = nil
        end
        -- Abandon the grace driver if the session left RECONNECTING for any
        -- reason other than the driver itself. A user Close moves the HSM to
        -- CLOSING/CLOSED/FAULT, and a watchdog force-fault moves it to FAULT,
        -- but the deadline stayed armed: the next poll's _drive_reconnect (and
        -- the OPEN/OPENING recovery absorb below) would then resume the
        -- reset -> reopen sequence and reopen a port the user explicitly asked
        -- to close. Once state is no longer RECONNECTING, drop the window.
        if self._reconnect_deadline and not self.vm:recovering() then
            self._reconnect_deadline = nil
            self._reconnect_attempt = 0
            self._reconnect_pending = false
            self._reconnect_phase = nil
            self._reconnect_port_desc = nil
        end
        -- Reconnect grace window: a fault while the session was OPEN does not
        -- tear the UI down immediately. If the port recovers within
        -- RECONNECT_GRACE_MS we resume; otherwise we fall through to FAULT and
        -- the user reconnects manually. The core released the physical handle
        -- on fault, so recovery is a fresh open of the same port.
        local was_open = self.vm.hsm.state == self.vm.STATE_OPEN or
                         self.vm.hsm.state == self.vm.STATE_OPENING
        if snap.port_state == xcom.port_fault and (was_open or self._reconnect_deadline) then
            if not self._reconnect_deadline then
                self.vm:enter_reconnecting(snap.generation)
                self._reconnect_deadline = uv.now() + self.vm.RECONNECT_GRACE_MS
                self._reconnect_attempt = 0
                self._reconnect_pending = false
                self._reconnect_phase = nil
                -- USB re-enumeration can move the same adapter to a different
                -- COMx. Capture the registry description now, while the old
                -- name may still be enumerated, so _resolve_reconnect_port can
                -- follow the device to its new name once it reappears.
                self._reconnect_port_desc =
                    self:_port_description(self:_serial_config().port)
            end
            self:_drive_reconnect(snap.generation)
            self:_render_ui_state()
            return self:_poll_errors()
        end
        if self._reconnect_deadline then
            -- Inside the grace window. The recovery probe must keep running on
            -- every poll, not only when the snapshot already looks healthy: the
            -- first thing _drive_reconnect does is issue xcom_close, which is
            -- synchronous, so the next several snapshots report CLOSED — our
            -- OWN reset rather than a recovery. Treating CLOSED as "nothing to
            -- do, return" left the reopen request unissued forever and the HSM
            -- parked in RECONNECTING (a Close click in that state was likewise
            -- swallowed, wedging the session in CLOSING with no way out).
            self:_drive_reconnect(snap.generation)
            -- _drive_reconnect clears the deadline when the window expires, so
            -- re-read it rather than assuming the window is still open.
            if self._reconnect_deadline then
                -- Only OPEN/OPENING counts as recovery. A CLOSED snapshot at
                -- this point is our own close succeeding; it must not reach
                -- on_snapshot, which would latch it as a real state change.
                if snap.port_state == xcom.port_open or
                   snap.port_state == xcom.port_opening then
                    -- Only disarm the window once the generation-guarded latch
                    -- is accepted. A stale OPEN (same generation as the pre-fault
                    -- session) is rejected by on_port_state; clearing the
                    -- deadline anyway would strand the HSM in RECONNECTING with
                    -- no watchdog: _drive_reconnect never runs again and the
                    -- session wedges until a manual Close.
                    local latched =
                        self.vm.hsm:on_port_state(snap.port_state, snap.generation)
                    if latched then
                        self._reconnect_deadline = nil
                        self._reconnect_pending = false
                        self._reconnect_phase = nil
                        self._reconnect_port_desc = nil
                    end
                    if latched and self.vm:settle_recovering() then
                        if self.imgui then
                            -- Mark the boundary in the view. After a ROM-mode
                            -- switch the device re-enumerates, so everything
                            -- the bootloader prints arrives in a NEW session;
                            -- without a visible separator mixed into the old
                            -- transcript it reads as "the reconnect worked but
                            -- no output came back". The banner is prefixed so
                            -- it cannot be mistaken for device data, and a
                            -- blank line keeps it off the tail of the last
                            -- pre-reset line.
                            self:_append_imgui_receive("\n[XCOM] reconnected to " ..
                                (self._imgui_port or "serial port") ..
                                " - device output resumes below\n")
                            self.imgui:set_status("Reconnected: " ..
                                (self._imgui_port or "serial port"))
                        end
                        self:_render_ui_state()
                    end
                end
                self:_poll_errors()
                return
            end
            -- The window just expired inside _drive_reconnect: fall through so
            -- on_snapshot lands the session in FAULT for a manual reconnect.
        end
        -- Window elapsed with no recovery: the FAULT branch above already ran
        -- _drive_reconnect (which times out to FAULT and clears the deadline),
        -- so on_snapshot below lands the session in FAULT for a manual
        -- reconnect. Nothing extra to do here.
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
        if snap.port_state ~= self._last_port_state or self.vm:recovering() then
            self._last_port_state = snap.port_state
            local label = xcom.port_text[snap.port_state] or tostring(snap.port_state)
            if self.vm:recovering() then
                label = "RECONNECT"
            end
            c.set_text(self.status.labels[1], label)
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
        -- Session-scoped loss, from two distinct sources:
        --   * pool drop (rx_pool_exhausted_bytes): exact byte count. Only the
        --     injected seam can hit this; the live serial callback withholds
        --     reads instead of dropping.
        --   * driver overrun (overrun_errors): bytes lost inside the driver
        --     FIFO, count unknowable, event countable. This is the live path's
        --     real (uncorrectable) loss.
        local sess_pool = (snap.rx_pool_exhausted_bytes or 0) -
                          (self._loss_base_pool or 0)
        local sess_overrun = (snap.overrun_errors or 0) -
                             (self._loss_base_overrun or 0)
        if sess_pool < 0 then sess_pool = 0 end
        if sess_overrun < 0 then sess_overrun = 0 end
        local loss_events = sess_pool + sess_overrun
        if loss_events ~= (self._loss_seen or 0) then
            self._loss_seen = loss_events
            if loss_events > 0 then
                -- Latched banner: re-asserted every poll below so an unrelated
                -- status write cannot make the loss flash and vanish.
                if sess_pool > 0 and sess_overrun > 0 then
                    self._loss_banner = string.format(
                        "DATA LOSS: %d B pool + overrun x%d @ offset %d",
                        sess_pool, sess_overrun, snap.rx_loss_offset or 0)
                elseif sess_pool > 0 then
                    self._loss_banner = string.format(
                        "DATA LOSS: %d B dropped @ offset %d (seq %d)",
                        sess_pool, snap.rx_loss_offset or 0, snap.rx_sequence or 0)
                else
                    self._loss_banner = string.format(
                        "DATA LOSS: driver RX overrun x%d @ offset %d - lower baud/flow",
                        sess_overrun, snap.rx_loss_offset or 0)
                end
                -- Drain now: this relieves a full pool and narrows the window in
                -- which the driver FIFO can overrun.
                self:poll_display()
                -- Vivid + immediate: route the message to the ImGui status path
                -- and pull a frame right away rather than at the 500 ms beat.
                self:set_status_deferred(self._loss_banner)
                self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
            else
                self._loss_banner = nil
            end
        end
        if drops ~= self._last_drops or trim ~= self._last_trim or paused ~= self._last_paused then
            self._last_drops, self._last_trim, self._last_paused = drops, trim, paused
            -- Only paint the informational drop/trim/pause line when no loss
            -- banner is latched; otherwise it would immediately be overwritten
            -- by the banner below anyway.
            if not self._loss_banner then
                c.set_text(self.status.labels[3],
                           string.format("drops: %d  trim: %d  pause: %d", drops, trim, paused))
            end
        end
        -- Persistence: re-assert the loss banner every poll while this session
        -- carries loss, so the next frame and every later frame show it.
        if self._loss_banner then
            c.set_text(self.status.labels[3], self._loss_banner)
        end
        -- Early warning BEFORE any loss: the RX pool was full and the live read
        -- callback withheld reads (rx_backpressure_events).  No bytes are lost
        -- yet on that path, but the driver FIFO is what fills next, so surface
        -- it once per new count.  No persistent banner here.
        local sess_bp = (snap.rx_backpressure_events or 0) -
                        (self._loss_base_bp or 0)
        if sess_bp < 0 then sess_bp = 0 end
        if sess_bp ~= (self._bp_seen or 0) then
            self._bp_seen = sess_bp
            if sess_bp > 0 and loss_events == 0 then
                self:set_status_deferred(string.format(
                    "RX backpressure x%d: host not draining the receive pool",
                    sess_bp))
                self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
            end
        end
        -- v1.5 line errors: ClearCommError counters from the core. Surface only
        -- on change (this poller runs at 250 ms) so a storm cannot flood the
        -- status line, and keep it off the RX/TX label so normal traffic stays
        -- readable. A rising count means received bytes may be corrupted.
        local line_errors = (snap.framing_errors or 0) + (snap.parity_errors or 0) +
                            (snap.overrun_errors or 0) + (snap.break_events or 0)
        if line_errors ~= self._last_line_errors then
            self._last_line_errors = line_errors
            -- Overrun is already inside the loss banner; suppress the weaker
            -- line-error notice while a banner is latched so the banner wins.
            if line_errors > 0 and not self._loss_banner then
                self:set_status_deferred(string.format(
                    "Line errors: frame %d parity %d overrun %d break %d",
                    snap.framing_errors or 0, snap.parity_errors or 0,
                    snap.overrun_errors or 0, snap.break_events or 0))
            end
        end
    end
    self:_poll_errors()
end
jit.off(Window.poll_status)

-- Port-list helpers for the reconnect grace window. USB re-enumeration can
-- move the same physical adapter from COMx to COMy, so retrying the old name
-- never recovers. Enumeration only returns {name, description}, so the adapter
-- is identified by its description (the SERIALCOMM value name, stable per
-- device instance): a name change carrying the same description is treated as
-- the same device.

-- Registry description of `name` from the current enumeration, or nil when the
-- port is gone or carries no description.
function Window:_port_description(name)
    if not name or name == "" then
        return nil
    end
    for _, p in ipairs(xcom.list_ports() or {}) do
        if p.name == name then
            if p.description and p.description ~= "" then
                return p.description
            end
            return nil
        end
    end
    return nil
end

-- Resolve the port to reopen. Returns (target, matched):
--   * original still enumerated -> (original, true)
--   * original gone, exactly one newly enumerated port carries the same
--     description -> (that name, true)   [the USB re-enumeration case]
--   * otherwise -> (original, false)     [no reliable match]
-- Ambiguity (0 or >1 description matches) counts as no match on purpose:
-- opening the wrong device is worse than asking the user to reselect.
function Window:_resolve_reconnect_port(original, desc)
    if not original or original == "" then
        return original, false
    end
    local present = false
    local candidate = nil
    local candidate_count = 0
    for _, p in ipairs(xcom.list_ports() or {}) do
        if p.name == original then
            present = true
        elseif desc and p.description and p.description ~= "" and
               p.description == desc then
            candidate = p.name
            candidate_count = candidate_count + 1
        end
    end
    if present then
        return original, true
    end
    if candidate_count == 1 then
        return candidate, true
    end
    return original, false
end

-- Grace-window driver: called from poll_status while the HSM mirrors a
-- RECONNECTING session (core faulted, UI holding the window open). It arms a
-- fresh open of the same port at most once per grace-retry interval and times
-- the window out to FAULT. The core released the old handle on the fault, so
-- this is a real CreateFile-style reopen, not a handle probe.
function Window:_drive_reconnect(generation)
    if not self.core then
        return false
    end
    local now = uv.now()
    if now >= self._reconnect_deadline then
        self.vm:reconnect_timeout()
        self._reconnect_deadline = nil
        self._reconnect_attempt = 0
        self._reconnect_pending = false
        self._reconnect_phase = nil
        self._reconnect_port_desc = nil
        if self.imgui then
            self.imgui:set_status("串口连接已断开，请手动重连")
        end
        -- Signal the caller to re-render: the HSM left RECONNECTING for FAULT,
        -- which flips the open/close/send interlock back to the manual path.
        return true
    end
    -- The HSM stays in RECONNECTING for the whole window (that is what gates
    -- send/params); `_reconnect_phase` tracks the core reset -> reopen
    -- sequence. The core's queue_open only accepts CLOSED, and a fault leaves
    -- it in FAULT, so each attempt must first issue close() to drive
    -- FAULT -> CLOSED (this also drains the faulted session's remaining
    -- teardown) before open_async can be queued.
    local serial = self:_serial_config()
    local original = serial.port
    -- Re-enumerate every attempt (device hot-plug is exactly what we are
    -- recovering from) and follow the adapter to a new COMx when possible.
    local target, matched = self:_resolve_reconnect_port(
        original, self._reconnect_port_desc)
    if matched and target and target ~= "" and target ~= original then
        -- The adapter came back under a new name: adopt it in every place the
        -- serial config is read from, refresh the dropdown, and re-arm so the
        -- next attempt opens the new port instead of the stale one.
        self._imgui_port = target
        if self.conn and self.conn.port then
            c.set_text(self.conn.port, target)
        end
        self:_refresh_imgui_ports()
        serial.port = target
        self._reconnect_pending = false
        self._reconnect_phase = nil
    end
    -- Prefer the original name exactly as before (never regress a retry); use a
    -- description-matched replacement only when one is unambiguously found.
    local have_port = serial.port and serial.port ~= ""
    if self._reconnect_phase == nil then
        -- Kick off the core reset for this attempt.
        xcom.close(self.core, 500)
        self._reconnect_phase = "open"
    elseif self._reconnect_phase == "open" then
        if not self._reconnect_pending and have_port then
            self._reconnect_attempt = (self._reconnect_attempt or 0) + 1
            local rc = xcom.open_async(self.core, serial.port, serial.baud_rate,
                serial.data_bits, serial.stop_bits, serial.parity, serial.flow_control,
                serial.dtr, serial.rts)
            -- XCOM_OK only means the request was queued; XCOM_ERR_BUSY means the
            -- core is still tearing down. Either way the next snapshot /
            -- take_open_result judges the attempt.
            self._reconnect_pending = (rc == xcom.ok)
        elseif self._reconnect_pending then
            -- Probe the in-flight reopen. A definitive failure clears the
            -- pending flag and re-arms the core reset for a fresh attempt.
            local open_result = tonumber(xcom.take_open_result(self.core))
            if open_result and open_result ~= xcom.ok and open_result ~= xcom.err_busy then
                self._reconnect_pending = false
                self._reconnect_phase = nil
            end
        end
    end
    if self.imgui then
        if not matched then
            -- Original port vanished and no single description-matched
            -- replacement exists (a re-enumerated device we cannot identify
            -- from {name, description} alone). Say so instead of a meaningless
            -- countdown so the user can reselect; the window still runs in case
            -- the device reappears.
            self.imgui:set_status("端口已消失，可能是设备重新枚举，请重新选择端口")
        else
            local left = math.max(0, math.floor((self._reconnect_deadline - now) / 1000))
            local suffix = (target ~= original) and ("  已切换到 " .. target) or ""
            self.imgui:set_status(string.format(
                "串口连接异常，等待恢复... (%ds)%s", left, suffix))
        end
    end
    return false
end
jit.off(Window._drive_reconnect)

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
        -- SIM: the port reached OPEN.  If the selected port is one of the
        -- simulator's virtual names, arm the pump (injects on a 20 ms timer).
        -- Guarded by _sim_active, so real-port machines never reach this.
        if self._sim_active and self:_sim_port_selected() then
            self.sim:start(self._sim_open_port)
        end
    end
    if was_connected and not state.connected then
        -- SIM: session went OFFLINE (Close / fault) — disarm the pump so no
        -- uv timer keeps injecting into a closed core.
        if self._sim_active and self.sim:is_running() then
            self.sim:stop()
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

    -- SIM: hardware-free serial data simulator (core/serial_sim.lua).  It
    -- auto-activates ONLY when the registry enumeration sees no real ports
    -- (sim:available() == #list_ports()==0), so machines with hardware keep
    -- bit-identical behaviour: every call site below is gated on _sim_active.
    -- The sim feeds bytes through xcom.test_inject_rx into the REAL display
    -- pipeline once a VIRTUAL/TEST* session is opened.
    self.sim = serial_sim.new({
        xcom = xcom, win = self, uv = uv,
        -- Low-frequency lifecycle diagnostics (arm/stop/overflow) -> stderr.
        log = function(tag, msg) io.stderr:write("[" .. tag .. "] " .. msg .. "\n") end,
    })
    self._sim_active = self.sim:available() and true or false
    if self._sim_active then
        -- Re-publish the port combo so the SIM entries appear (the bridge was
        -- populated during init_window, before the core handle existed).
        self:_refresh_imgui_ports()
    end

    -- User script engine (scripts/ directory beside the app).  Enabled
    -- names come from config [script] enabled (comma-separated).  The
    -- engine no-ops everywhere when no script is enabled.
    local script_dir = (self.config_path and
        self.config_path:match("^(.*)[/\\]") or ".") .. "/scripts"
    self.scripts = script_engine.new({
        script_dir = script_dir,
        send = function(payload) return self:core_send(payload, xcom.send_text) end,
        is_open = function() return self.connected end,
        on_rules_changed = function(rules)
            self._script_rules = rules
            self._script_rules_dirty = true
        end,
        wave = waveform,
        charset = charset,
        open_file = function() return self:_open_file_dialog("Send file") end,
        sim = self._sim_active and self.sim or nil,
        auto_reload = self.cfg.script_auto_reload and true or false,
        -- fs_event watch of scripts/ so an external editor save hot-reloads the
        -- script (debounced 200 ms).  Independent of [script] auto_reload: the
        -- watcher is the primary path, auto_reload is the mtime fallback.
        watch = true,
    })
    local ok_scripts, err_scripts = pcall(function()
        self.scripts:load_all()
        for _, name in ipairs(self.cfg.script_enabled or {}) do
            self.scripts:enable(name, true)
        end
        self.scripts:watch_start()
    end)
    if not ok_scripts then
        io.stderr:write("[scripts] init: " .. tostring(err_scripts) .. "\n")
    end
    -- Script console visibility (config [script] autorun_console).  The C++
    -- state mirrors this through set_scripts_visible; the header "Lua" button
    -- toggles it later through the action bit.
    self._scripts_console_open = self.cfg.script_autorun_console and true or false
    -- Scope mirror starts explicit-false.  It is no longer driven by a header
    -- chip: _reconcile_scope_visibility() flips it (and the DLL visibility) to
    -- match waveform.active() each frame.  `not nil` would read true on the
    -- first reconcile and skip the initial hide, so keep it explicitly false.
    self._scope_open = false
    self._scope_dismissed = false   -- panel X click suppresses re-show (see reconcile)
    -- Settings mirror starts explicit-false: the flag is only flipped by the
    -- C++ action bit, and `not nil` would desync from the false-initial native
    -- visibility on the first toggle.
    self._settings_open = false
    if self._scripts_console_open and self.imgui and self.imgui.set_scripts_visible then
        self.imgui:set_scripts_visible(true)
    end
    -- Env-driven smoke hooks (no-ops unless XCOM_SMOKE_* is set); the bridge
    -- already exists because _init_imgui ran during construction.
    self:_smoke_env_hooks()
    -- One-shot rules push so the C++ highlighter starts warm.
    local rules = self.scripts:take_rules_if_dirty()
    if rules then
        self._script_rules = rules
        self._script_rules_dirty = true
    end
    -- 1 Hz housekeeping: pending partial-line idle flush + optional mtime
    -- hot-reload.  (poll() itself is cheap; the timer stays alive for the
    -- whole session and does nothing when the engine is idle.)
    self._script_timer = uv.new_timer()
    local script_poll_callback = function()
        local ok, err = pcall(self.scripts.poll, self.scripts)
        if not ok then io.stderr:write("[scripts] poll: " .. tostring(err) .. "\n") end
    end
    jit.off(script_poll_callback, true)
    self._script_poll_callback = script_poll_callback
    self._script_timer:start(1000, 1000, script_poll_callback)

    -- Fast fs_event drain (250 ms): the watcher records changed filenames
    -- immediately, and this tick applies the 200 ms debounce and reloads them.
    -- It runs faster than the 1 Hz housekeeping timer so an external editor
    -- save hot-reloads within roughly a quarter second instead of a whole
    -- second.  pump() is a no-op when no watcher/files are pending.
    self._script_watch_timer = uv.new_timer()
    local script_watch_callback = function()
        local ok, err = pcall(self.scripts.pump, self.scripts)
        if not ok then io.stderr:write("[scripts] watch: " .. tostring(err) .. "\n") end
    end
    jit.off(script_watch_callback, true)
    self._script_watch_callback = script_watch_callback
    self._script_watch_timer:start(250, 250, script_watch_callback)

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
    -- SIM: idempotent defensive stop (on_close already armed this); ensures
    -- the pump's uv handle is released even if the loop exited via a path
    -- that skipped on_close.
    if self._sim_active then self.sim:stop() end
    for _, t in ipairs({ self._display_timer, self._status_timer,
                         self._multi_timer, self._script_timer,
                         self._script_watch_timer }) do
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
    -- Manual Clear: same view reset as the auto_clear threshold path (which
    -- deliberately skips the RICHEDIT fallback below).
    self:_clear_imgui_view()
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

-- Open-picker mirroring _save_file_dialog (GetOpenFileNameW): returns a
-- UTF-8 path string or nil on cancel.  Script plugins reach it through the
-- engine's sys.open_file hook injected below; the settings UI has no text
-- field, so a native dialog is the only path entry.
function Window:_open_file_dialog(title)
    local ofn = ffi.new("OPENFILENAMEW")
    ofn.lStructSize = ffi.sizeof("OPENFILENAMEW")
    ofn.hwndOwner = self.hwnd
    ofn.lpstrFilter = w.utf8_to_utf16("All files (*.*)\0*.*\0")
    ofn.lpstrTitle = w.utf8_to_utf16(title or "Open file")
    ofn.Flags = w.ofn.OFN_FILEMUSTEXIST + w.ofn.OFN_PATHMUSTEXIST +
                w.ofn.OFN_HIDEREADONLY + w.ofn.OFN_EXPLORER

    local buf_len = 1024
    local buf = ffi.new("unsigned short[?]", buf_len)
    buf[0] = 0
    ofn.lpstrFile = buf
    ofn.nMaxFile = buf_len

    if w.comdlg32.GetOpenFileNameW(ofn) == 0 then
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
    -- intentionally not fed in that mode.  With the incremental DLL the Lua
    -- side keeps no tail copy at all — read the native window back (rare,
    -- user-triggered path; the copy is bounded by the window size).
    local data
    if self.imgui then
        if self.imgui.get_receive_text then
            data = (self.imgui:get_receive_text()) or ""
        else
            data = self._imgui_receive or ""
        end
    else
        data = receive_text(self.recv.richedit.hwnd)
    end
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
    local ports, enum_err = xcom.list_ports({ probe = self._probe_port_busy })
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
        -- Distinguish "no ports" from "enumeration failed" so the user is not
        -- left guessing at an empty combo.
        if enum_err ~= nil then
            local msg = (xcom.describe_enum_error and xcom.describe_enum_error(enum_err))
                        or ("port enumeration failed (error " .. tostring(enum_err) .. ")")
            c.set_text(self.status.labels[3], msg)
        else
            c.set_text(self.status.labels[3], "no COM ports detected")
        end
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

-- ---------------------------------------------------------------------------
-- Hard guarantee: NO Lua function reachable from the WndProc callback may
-- ever be trace-compiled.  Why jit.off(wndproc_callback, true) is not enough:
--   * the recursive flag only walks LEXICALLY nested protos; Window methods
--     attach to the metatable at file scope, so the whole dispatch tree stays
--     individually traceable; and
--   * any function that is hot enough gets a trace (window.lua on_nchittest
--     ran compiled -- "start trace#54 entry=window.lua:685" in the JIT log --
--     while Windows synchronously dispatched ANOTHER message into the same
--     WndProc; lj_ccallback_enter saw jit_base live -> PANIC: bad callback ->
--     exit(1)).
-- Enumerate every reachable function directly and pin it off.  Costs nothing:
-- the WndProc path is event-paced, never a throughput hot spot; the RX drain
-- and file-I/O hot loops live in luv timer callbacks (pinned at their own
-- scope) and C code.
local function jit_off_deep(fn, seen)
    if type(fn) ~= "function" or seen[fn] then return end
    seen[fn] = true
    local ok = pcall(jit.off, fn)
    if not ok then
        io.stderr:write("[init] jit.off failed for " .. tostring(fn) .. "\n")
    end
    local info = debug.getinfo(fn, "u")
    if info then
        for i = 1, info.nups do
            local name = debug.getupvalue(fn, i)
            local value = select(2, debug.getupvalue(fn, i))
            -- Only descend into plain Lua functions; C functions and
            -- metatables/stdlib come through as other kinds and stay
            -- untouched (the "(" prefix marks for/pcall/C control upvalues).
            if name:sub(1, 1) ~= "(" and type(value) == "function" then
                jit_off_deep(value, seen)
            end
        end
    end
end

-- wndproc_callback + everything it lexically reaches (Active/pcall chain).
jit_off_deep(wndproc_callback, {})
-- The dynamic half: Window methods dispatch via the metatable, invisible to
-- the upvalue walk; enumerate the method table itself (all methods are
-- defined by this point in the file).
for _, fn in pairs(Window) do
    if type(fn) == "function" then jit_off_deep(fn, {}) end
end

return M
