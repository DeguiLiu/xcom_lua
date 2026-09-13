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
local device_profiles = require("device_profiles")
local reset_sequencer = require("reset_sequencer")
local imgui_bridge = require("imgui_bridge")
local script_engine = require("script_engine")
local waveform = require("waveform")
local charset = require("charset")
local serial_sim = require("serial_sim")

-- Frame pacing under WARP (software) rendering.  A full frame costs ~45-60 ms
-- of CPU, so the old fixed 16 ms cadence burned ~70% of a core redrawing an
-- idle UI.  Frames are now demand-driven with a per-cause interval:
--   * interactive (mouse/keyboard/window messages): 16 ms  — feels instant
--   * receive data pending: 100 ms (10 FPS coalesced log tail)
--   * idle heartbeat: 500 ms (status text, cursor blink, clock fallbacks)
-- Anything that changes what is on screen calls request_frame() to pull the
-- next frame earlier; the floor keeps one heartbeat frame alive.
-- Declared here, above every method that calls request_frame(): a local binds
-- by lexical position, so a declaration further down the file leaves the
-- earlier call sites (receive-data requests included) reading a nil global.
-- They then silently degrade to the ACTIVE cadence -- the exact CPU burn this
-- pacing exists to avoid.
local FRAME_INTERVAL_ACTIVE_MS = 16
local FRAME_INTERVAL_DATA_MS = 100
local FRAME_INTERVAL_IDLE_MS = 500

-- Serial-config combo text -> ABI-int maps and helpers (declared up-front so
-- every method below closes over the same upvalues regardless of where in
-- the file it is defined; see the create_class forward-declaration note).
local STOP_MAP = { ["1"] = 0, ["1.5"] = 1, ["2"] = 2 }
local PARITY_MAP = { ["None"] = 0, ["Odd"] = 1, ["Even"] = 2, ["Mark"] = 3, ["Space"] = 4 }
local FLOW_MAP = { ["None"] = 0, ["HW (RTS/CTS)"] = 1, ["SW (XON/XOFF)"] = 2 }
local function stop_index(t) return STOP_MAP[t] or 0 end
local function parity_index(t) return PARITY_MAP[t] or 0 end
local function flow_index(t) return FLOW_MAP[t] or 0 end

-- Forward declarations for the pure port-combo helpers (their bodies live with
-- the device-change/refresh code further down).  Lua binds a local by lexical
-- position, so the slot must exist before the first reference -- the
-- device-change backstop above uses port_list_signature.
local port_key, port_combo_entries, find_key_index, port_list_signature,
      unique_port_by_desc

-- Receive-display pipeline constants (docs/design-rx-display-pipeline.md).
-- The C++ side owns collection (①), frame/gap detection (②) and line
-- normalisation (③: CR/CRLF -> LF, ANSI/C0 stripped).  Lua then runs charset
-- conversion (④), the whole-line bridge, the user-script stage (⑤) and
-- timestamping (⑥), in that order.
local RX_LINE_CAP = 4096          -- §2: force-flush a held partial past this
local DEFAULT_TIMESTAMP_GAP_MS = 200  -- §3: batch gap that opens a SEGMENT
-- Idle RX gap after which an OPEN line is reported "silent" (MCU powered down
-- behind a USB-UART bridge, where the device/port stay present and no
-- device-change event exists).  3 s: long enough that normal request/response
-- gaps do not trip it, short enough to notice a board that just lost power.
local LINE_SILENT_MS = 3000

-- Reset-sequencer poll cadence.  The DTR/RTS edges of the auto profiles are
-- 50-120 ms apart, so a 5 ms luv timer resolves them with margin.  The sequence
-- is advanced from its own timer and NEVER by sleeping/busy-waiting on the UI
-- thread (a sleep there would freeze the message pump).
local RESET_TICK_MS = 5

-- Quiet window for the recovery overlay's tx_stalled flag: after the core's
-- flow_hold_events counter last rises, keep the stall flag raised this long so
-- "hold released" (the counter stops rising) clears it on its own.
local FLOW_HOLD_QUIET_MS = 2000

-- Split `text` into its complete LF-terminated lines plus the unterminated
-- tail.  The caller holds the tail across drain batches so scripts only ever
-- receive whole lines.  No CR handling belongs here: ③ guarantees LF is the
-- only line break by the time Lua sees the bytes.
local function split_complete_lines(text)
    local last_nl = text:match(".*()\n")
    if not last_nl then
        return "", text
    end
    return text:sub(1, last_nl), text:sub(last_nl + 1)
end

-- Local wall clock at millisecond resolution for the ⑥ timestamp.  os.date
-- only resolves whole seconds, so anchor a monotonic uv.now() counter to the
-- wall second ONCE and let the pair advance together for the session.  We do
-- NOT format the drain's ingress_ms directly: it is a monotonic uptime value
-- (coact::pal::monotonic_ms), not an epoch, so os.date on it would print a
-- bogus wall time.  Instead the caller maps ingress_ms through
-- Window._rx_ts_wall_anchor (set at the first batch), so a stamp reads as the
-- wall time the bytes actually entered the machine — a burst that waited out a
-- pause is stamped with its real arrival time, not the resume time.
local wall_anchor = nil
local function wall_clock_ms()
    local mono = uv.now()
    if wall_anchor == nil then
        wall_anchor = os.time() * 1000 - mono
    end
    return mono + wall_anchor
end

local function rx_timestamp_prefix(wall_ms)
    local t = wall_ms or wall_clock_ms()
    return string.format("[%s.%03d] ",
        os.date("%H:%M:%S", math.floor(t / 1000)), t % 1000)
end

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

-- LogWriter::append accepts at most one block per call and rejects a larger
-- one whole with XCOM_ERR_FULL (xcom_core/src/io/log_writer.cpp: `size >
-- kFileBlockBytes` -> FULL, no partial acceptance).  kFileBlockBytes is
-- 64 KiB.  The ABI exposes no size query, so the save path chunks to this
-- bound itself; keep it in step with the core constant.
local LOG_APPEND_BLOCK_BYTES = 64 * 1024

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
    -- Display-pause is enforced HERE, not in the core: the core's pause also
    -- freezes the format/drain lane that feeds the file capture, so bytes
    -- received while paused would never reach the log (and would be lost for
    -- good if the app closed while still paused).  Keeping the core running and
    -- dropping only the viewport append keeps capture byte-faithful; the
    -- skipped-byte count is kept Lua-side for the "pause: N" status line.
    self._pause_display = cfg.pause_display and true or false
    self._paused_display_bytes = 0
    -- uv.now() of the last drained batch (nil = none yet) and whether the
    -- view tail currently ends mid-line (the auto frame-break anchor).
    self._rx_last_batch_ms = nil
    self._view_tail_open = false
    -- Whole-line bridge (design §2) between charset conversion (④) and the
    -- script stage (⑤).  _rx_line_pending holds the converted stream's
    -- unterminated tail across drain batches so scripts only ever see whole
    -- lines; _rx_line_forced counts forced flushes (new segment / cap / close /
    -- reload) so a binary device that never sends LF is observable, and
    -- _rx_line_discarded counts bytes dropped by a view clear (never silent).
    self._rx_line_pending = ""
    self._rx_line_forced = 0
    self._rx_line_discarded = 0
    -- uv.now() of the last batch that entered the funnel.  A device that never
    -- delimits frames (no LF) can leave a short frame held in _rx_line_pending
    -- forever; the 10 ms drain tick flushes it once this anchor is older than
    -- _timestamp_gap_ms (an idle gap IS a frame boundary).  nil = none yet.
    self._rx_idle_ms = nil
    -- Timestamp stage (design §3).  _rx_ingress_ms is the previous batch's
    -- earliest ingress time; _rx_segment_stamp_pending is armed when the drain
    -- reports a new SEGMENT and consumed by the first line that survives ⑤.
    self._rx_ingress_ms = nil
    self._rx_segment_stamp_pending = false
    -- Monotonic -> wall-clock mapping shared by every stamp (see
    -- rx_timestamp_prefix) and the ingress of the segment currently owed a
    -- stamp.
    self._rx_ts_mono_anchor = nil
    self._rx_ts_wall_anchor = nil
    self._rx_segment_ingress_ms = nil
    self._rx_ts_notice_given = false
    -- Lifetime count of script-stage pcall failures (design §4 item 5); the
    -- indication is rate-limited so a per-batch failure cannot spam the ring.
    self._rx_funnel_errors = 0
    -- A batch gap of at least this many ms opens a new segment (one stamp).
    -- Validated like reconnect_grace_ms: a nonsensical value falls back to the
    -- default rather than disabling the feature.
    local gap = tonumber(config.get(cfg_data, "display", "timestamp_gap_ms",
                                    DEFAULT_TIMESTAMP_GAP_MS))
    if gap and gap >= 10 and gap <= 60000 then
        self._timestamp_gap_ms = gap
    else
        self._timestamp_gap_ms = DEFAULT_TIMESTAMP_GAP_MS
    end
    -- Cached [display] timestamp checkbox.  The core no longer injects a
    -- timestamp after design §4 item 2, so this flag gates the Lua ⑥ stage.
    self._timestamp_enabled = cfg.timestamp and true or false
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
    -- Derived recovery-overlay inputs (design-device-profiles step 5).  These
    -- are raw observations the overlay in Window:ui_state() turns into the five
    -- derived flags; none of them changes the HSM or the core ABI.
    self._reconnect_candidate_names = nil -- uniquely-matching re-enumerated names
    self._silent_warn_ms = nil            -- per-profile idle threshold (cached)
    self._flow_hold_last = nil            -- last seen flow_hold_events counter
    self._flow_hold_active_until = nil    -- tx_stalled decays after this uv.now()
    -- Reset sequencer (design step 4): one in-flight sequence and the luv timer
    -- that advances it.  Both nil outside a reset.
    self._reset_seq = nil
    self._reset_timer = nil
    self._reset_timer_callback = nil
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

function Window:_refresh_imgui_ports(ports, enum_err)
    if not self.imgui then return end
    -- Probe only when _port_probe_flag() says it is safe (see its note): a
    -- device-change refresh can arrive mid-session, and probing would touch
    -- the open port.  This only replaces the CANDIDATE list: the bridge's
    -- selection lives in its `port` buffer and xcom_imgui_set_ports never
    -- writes it (native/xcom_imgui_bridge.cpp:3297 only stores ports_), so a
    -- refresh cannot move the user's chosen port here.
    if ports == nil then
        ports, enum_err = xcom.list_ports({ probe = self:_port_probe_flag() })
    end
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
    self:_install_open_line_combos()
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

-- Open-time modem-line tri-state for the LEGACY Win32 panel.  The two DTR/RTS
-- checkboxes can only express assert/deassert, so they are hidden and replaced
-- by a three-way combo per line (Deassert / Assert / Leave alone) that feeds
-- XcomPortConfig.dtr_enable/rts_enable at open.  The checkboxes stay alive so
-- the panel module keeps laying out the row they occupy; the combos are parked
-- on top of it and re-parked after every layout pass.
function Window:_install_open_line_combos()
    local conn = self.conn
    if not (conn and conn.dtr and conn.rts) then
        return
    end
    conn.dtr_open = c.combo(self.hwnd, xcom.OPEN_LINE_ITEMS,
                            { sel = xcom.line_from_ui_index(self.cfg.dtr_open) })
    conn.rts_open = c.combo(self.hwnd, xcom.OPEN_LINE_ITEMS,
                            { sel = xcom.line_from_ui_index(self.cfg.rts_open) })
    if conn.dtr_open then w.user32.ShowWindow(conn.dtr_open.hwnd, 1) end
    if conn.rts_open then w.user32.ShowWindow(conn.rts_open.hwnd, 1) end
    -- Hide (not destroy) the boolean checkboxes: the panel's layout function
    -- still moves them, which is how these combos learn their row position.
    w.user32.ShowWindow(conn.dtr.hwnd, 0)
    w.user32.ShowWindow(conn.rts.hwnd, 0)
    self:_place_open_line_combos()
    local base_layout = conn.layout
    local place = function(px, py, width)
        base_layout(px, py, width)
        self:_place_open_line_combos()
    end
    conn.layout = place
    -- layout drives MoveWindow (synchronous WndProc re-entry): pin it like the
    -- panel's own layout closure (bad-callback rule, see main.lua).
    if jit and jit.off then jit.off(place, true) end
end

-- Park each tri-state combo exactly where its hidden checkbox sits, so the
-- legacy row geometry stays owned by connection_panel.lua and no coordinate
-- constants are duplicated here.
function Window:_place_open_line_combos()
    local conn = self.conn
    if not (conn and conn.dtr_open and conn.rts_open and conn.dtr and conn.rts) then
        return
    end
    local rect = ffi.new("RECT")
    local function cell(ctl)
        if w.user32.GetWindowRect(ctl.hwnd, rect) == 0 then return nil end
        local pt = ffi.new("POINT")
        pt.x = rect.left
        pt.y = rect.top
        w.user32.ScreenToClient(self.hwnd, pt)
        return pt.x, pt.y, rect.right - rect.left, rect.bottom - rect.top
    end
    local x1, y1, _, h1 = cell(conn.dtr)
    local x2, _, w2 = cell(conn.rts)
    if x1 == nil or x2 == nil then return end
    -- Two combos share the single checkbox row; keep a 4 px gap between them.
    local half = math.max(40, math.floor((x2 - x1 + (w2 or 0) - 4) / 2))
    c.move(conn.dtr_open, x1, y1, half, h1)
    c.move(conn.rts_open, x2, y1, half, h1)
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
    -- Open-time tri-state combos (legacy panel only; the ImGui panel seeds its
    -- own buffers in imgui_bridge.new).  line_from_ui_index normalises a stale
    -- config value so an unknown entry shows as the safe Leave alone.
    if conn.dtr_open then
        c.combo_set(conn.dtr_open, xcom.OPEN_LINE_ITEMS,
                    xcom.line_from_ui_index(cfg.dtr_open))
    end
    if conn.rts_open then
        c.combo_set(conn.rts_open, xcom.OPEN_LINE_ITEMS,
                    xcom.line_from_ui_index(cfg.rts_open))
    end
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
    if m == w.wm.WM_DEVICECHANGE then
        -- DBT_DEVNODES_CHANGED is broadcast to every top-level window on any
        -- device-node change (USB plug/unplug, a USB-CDC MCU powering up/down),
        -- so no RegisterDeviceNotification is needed.  We only mark the port
        -- list stale and schedule a coalesced refresh -- never any device I/O
        -- from the WndProc (same rule as _on_power_broadcast) and never an
        -- open/close.  Let it fall through to DefWindowProc afterwards.
        if (tonumber(wparam) or 0) == w.dbt.DBT_DEVNODES_CHANGED then
            self:_on_device_nodes_changed()
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

-- ---------------------------------------------------------------------------
-- Device-change awareness (USB plug/unplug, MCU power, re-enumeration).
--
-- Hybrid, matching the surveyed prior art (event-driven is the MINORITY
-- practice: most tools poll):
--   * PRIMARY: WM_DEVICECHANGE / DBT_DEVNODES_CHANGED, broadcast to every
--     top-level window with no RegisterDeviceNotification;
--   * BACKSTOP: a ~1 s idle re-enumerate (see _poll_ports_backstop) so a
--     notification lost to a modal loop or a driver that does not broadcast is
--     still caught.  Polling is the backstop, not the primary signal.
-- Both coalesce at 500 ms: one plug emits a burst of parent/child node
-- messages (Tera Term needs a whole state machine to dedup them), and the
-- opt-in occupancy probe opens every port -- so a per-message refresh would
-- multiply the most expensive and most intrusive work.
--
-- While a session is live/transitional or inside the reconnect grace window
-- NONE of this acts: LLCOM deliberately ignores device-change while the port is
-- open for exactly this reason, and it is the concrete guarantee that device
-- churn cannot disturb an in-flight open/close (or the port a pending reopen
-- targets).  The backstop picks the change up once the app is idle again.
local DEVICE_CHANGE_DEBOUNCE_MS = 500
Window.DEVICE_CHANGE_DEBOUNCE_MS = DEVICE_CHANGE_DEBOUNCE_MS

-- True while the port list may be rebuilt safely: OFFLINE (CLOSED/FAULT) and
-- not inside the reconnect grace window.  OPEN/OPENING/CLOSING all return
-- false; so does RECONNECTING, whose retry loop owns its own enumeration.
function Window:_ports_refresh_allowed()
    if not self.vm then return true end
    return self.vm:ui_state().super_state == view_model.SUPER_OFFLINE
           and not self.vm:recovering()
end

-- Coalescing gate.  Accepts the first notification of a burst and ignores the
-- rest for one window; a fixed window (rather than re-arming on every message)
-- guarantees at most one refresh per 500 ms and cannot be starved by a stream
-- of child-node messages.  Pure arithmetic -> unit-testable without libuv.
function Window:_device_change_should_arm(now)
    local last = self._device_change_armed_ms
    if last and (now - last) < DEVICE_CHANGE_DEBOUNCE_MS then
        return false
    end
    self._device_change_armed_ms = now
    return true
end

-- WndProc side: arm the coalesced refresh.  No device I/O here -- luv start()
-- only schedules (same contract as _on_power_broadcast); enumeration runs in
-- the timer callback.  No "list is stale" flag is kept: the backstop decides by
-- comparing the port-list signature, so a refresh that a live session made us
-- skip is still caught when the app goes idle.
function Window:_on_device_nodes_changed()
    if not self:_device_change_should_arm(uv.now()) then
        return
    end
    if self._device_change_timer and self._device_change_timer_callback then
        self._device_change_timer:start(DEVICE_CHANGE_DEBOUNCE_MS, 0,
                                        self._device_change_timer_callback)
    else
        -- No loop running (unit tests / early bring-up): fall back to a
        -- deferred refresh so the list still updates.
        self:schedule_defer(function() self:_refresh_ports_after_change() end)
    end
    self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
end

-- Timer callback: the single coalesced refresh for a burst.
function Window:_refresh_ports_after_change()
    if not self:_ports_refresh_allowed() then
        -- Session live: do not rebuild the list, do not touch the selection,
        -- do not probe (the backstop will refresh once idle).
        return
    end
    local ports, enum_err = xcom.list_ports({ probe = self:_port_probe_flag() })
    self:_apply_ports(ports, enum_err)
end

-- ~1 Hz backstop: cheap registry enumeration (NEVER probe -- a 1 Hz DTR pulse
-- could reset an auto-reset board, and this is a safety net, not a device
-- probe).  Refreshes only when the name set actually changed, so an unchanged
-- idle app does no rendering work.
function Window:_poll_ports_backstop()
    if not self:_ports_refresh_allowed() then
        return
    end
    local ports, enum_err = xcom.list_ports({ probe = false })
    if port_list_signature(ports) ~= self._ports_signature then
        self:schedule_defer(function()
            if self:_ports_refresh_allowed() then
                self:_apply_ports(ports, enum_err)
            end
        end)
    end
end

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
-- accepted-but-undisplayed bytes.  Pump the display drain in 64 KiB rounds
-- (same budget as the 10 ms poller) with a hard round cap so a pathological
-- stream can never spin the close path or balloon the receive buffer — the
-- ImGui tail is already clamped to 64 KiB chars by poll_display's substring.
-- Persistence is NOT done here: the core's raw-byte lane (read thread ->
-- LogWriter) already wrote every accepted byte, so a Lua log_append would
-- duplicate the file (design §4 item 1).
-- Python parity: MainWindow._drain_for_close polls until display_pending
-- reaches zero before quitting.
function Window:_final_drain()
    if not self.core then
        return
    end
    local max_rounds = 500  -- 500 * 64 KiB = 32 MiB hard ceiling
    for _ = 1, max_rounds do
        local rc, text, ingress_ms, ts_ok =
            xcom.drain_display_ts(self.core, 64 * 1024)
        if rc ~= xcom.ok or not text or #text == 0 then
            break
        end
        if self._pause_display then
            self._paused_display_bytes = (self._paused_display_bytes or 0) + #text
        else
            self:_process_rx_batch(text, ingress_ms, ts_ok)
            if not self.imgui and self.recv and self.recv.feed then
                self.recv.feed(text)
            end
        end
    end
    -- Deliver the whole-line bridge's held partial now: on session close there
    -- is no next batch to complete it, and holding it past the session would
    -- merge it with the next connection's first line.
    self:_flush_rx_lines(false)
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
    if self._device_change_timer then self._device_change_timer:stop() end
    if self._ports_backstop_timer then self._ports_backstop_timer:stop() end
    if self._sequence_timer then self:_stop_sequence() end
    -- Abandon any in-flight reset sequence: the timer must not fire after the
    -- core handle is torn down, and a running sequence is left at rest.
    if self._reset_seq then self:abort_reset_sequence("reset aborted: closing") end
    if self._reset_timer then self._reset_timer:stop() end
    -- SIM: disarm the pump before the drain/close (its uv handle must not
    -- survive past the core session; stop() is cheap and idempotent).
    if self._sim_active then self.sim:stop() end
    if self.scripts then self.scripts:shutdown() end
    self:_final_drain()
    self:_save_config()
    if self.core then
        self:_log_close_with_retry()
        if self.connected then
            -- 2000 ms, unlike the click path's short CLOSE_WAIT_MS: this IS the
            -- process-exit path, so the wait is necessary rather than avoidable
            -- -- the handle must be released before the runtime and the DLL are
            -- torn down, and there is no UI left to keep responsive.  A wedged
            -- driver still returns at the deadline, so exit stays bounded.
            local rc = xcom.close(self.core, 2000)
            self.connected = false
            -- The window is destroyed a few lines below, so a status line has
            -- no time to be read; still route a timeout through the visible
            -- channel and the stderr diagnostic rather than swallow it, so the
            -- result is not lost if any frame paints before teardown.
            if tonumber(rc) == xcom.err_timeout then
                self:_set_port_status(
                    "Close timed out; the port did not confirm teardown")
                io.stderr:write("[close] xcom_close timed out during exit\n")
            end
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
        -- Open-time tri-state (XCOM_LINE_*: 0/1/2) persisted alongside the
        -- legacy booleans so the choice survives a restart and a LEAVE_ALONE is
        -- not collapsed back to a boolean.
        config.set(data, "serial", "dtr_open", serial.dtr_open)
        config.set(data, "serial", "rts_open", serial.rts_open)
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
    local cfg
    if self.imgui then
        local baud, data_bits, stop, parity, flow, dtr, rts, dtr_open, rts_open = self.imgui:serial_config()
        cfg = {
            port = self._imgui_port or ffi.string(self.imgui.port),
            baud_rate = baud, data_bits = data_bits, stop_bits = stop,
            parity = parity, flow_control = flow, dtr = dtr, rts = rts,
            dtr_open = dtr_open, rts_open = rts_open,
        }
    else
        -- The legacy panel's DTR/RTS controls ARE the open-time tri-state (two
        -- combos created by _install_open_line_combos); the runtime booleans are
        -- derived from the same choice so both views of the pin agree.
        local dtr_open = xcom.line_from_ui_index(
            conn.dtr_open and c.combo_cur(conn.dtr_open))
        local rts_open = xcom.line_from_ui_index(
            conn.rts_open and c.combo_cur(conn.rts_open))
        cfg = {
            -- The combo displays a COMPOSED label (name + description + "(busy)"
            -- or "(not present)"), so GetWindowTextA is the wrong source for the
            -- ABI port name.  Map the current index back through the bare-key array
            -- built by _reload_port_combo; fall back to the text only before the
            -- first enumeration, where the combo is empty anyway.
            port = (self._port_keys and
                    self._port_keys[c.combo_cur(conn.port) + 1])
                   or c.get_text(conn.port),
            baud_rate = tonumber(c.combo_text(conn.baud)) or 115200,
            data_bits = tonumber(c.combo_text(conn.data)) or 8,
            stop_bits = stop_index(c.combo_text(conn.stop)),
            parity = parity_index(c.combo_text(conn.parity)),
            flow_control = flow_index(c.combo_text(conn.flow)),
            dtr = dtr_open == xcom.line_assert,
            rts = rts_open == xcom.line_assert,
            dtr_open = dtr_open, rts_open = rts_open,
        }
    end
    -- A missing/unknown selection must never reach the core as an out-of-range
    -- value (the core rejects it with XCOM_ERR_PARAM and the open dies).  Force
    -- both lines back into 0..2; an unselected combo degrades to LEAVE_ALONE,
    -- which is the safe "do not drive the pin" state.
    cfg.dtr_open = xcom.line_from_ui_index(cfg.dtr_open)
    cfg.rts_open = xcom.line_from_ui_index(cfg.rts_open)
    -- 1.5 stop bits exists only for a 5-data-bit word; serial_backend_win.cpp's
    -- valid_line_format() rejects every other pairing, so an "8 data bits + 1.5
    -- stop bits" selection would make Open fail on a combination the Stop combo
    -- still offers.  Normalise at this choke point -- the single place open,
    -- reconnect and save read the line format from -- and reflect the correction
    -- back to the native combo so the panel shows what will be programmed
    -- (CB_SETCURSEL does not raise a change notification, so this is safe in a
    -- getter and self-corrects on the first read).
    if cfg.stop_bits == 1 and cfg.data_bits ~= 5 then
        cfg.stop_bits = 0
        if conn and conn.stop then
            c.combo_select_text(conn.stop, "1")
        end
    end
    return cfg
end

-- Keep the live DTR/RTS toggles consistent with the open-time tri-state before
-- an open so the panel never shows a level the open path did not program.  A
-- non-LeaveAlone mode is mirrored into the live toggle; LeaveAlone maps to
-- "toggle off" (the open-line combo is the honest "line untouched" indicator).
-- This also seeds the change trackers, so the first poll after connect does not
-- treat nil -> false as a user edge and fire an implicit CLRDTR/CLRRTS.
function Window:_mirror_open_lines(serial)
    if not (self.imgui and self.imgui.dtr and self.imgui.rts) then
        return
    end
    local dtr = 0
    if serial.dtr_open == xcom.line_assert then dtr = 1 end
    local rts = 0
    if serial.rts_open == xcom.line_assert then rts = 1 end
    self.imgui.dtr[0] = dtr
    self.imgui.rts[0] = rts
    self._lines_dtr = dtr ~= 0
    self._lines_rts = rts ~= 0
end
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
    -- Presence is orthogonal to the state interlock: the Open BUTTON is already
    -- disabled via open_enabled, but the keyboard/action path can still reach
    -- here, so refuse an absent port explicitly rather than opening a stale
    -- name (or, worse, "whatever is first").
    if self.vm:ui_state().port_present == false then
        self.vm:reject_open()
        if self.imgui then
            self.imgui:set_status("Selected port is not present; reconnect or reselect")
        else
            self:_set_port_status("selected port not present - select a port")
        end
        return
    end
    local serial = self:_serial_config()
    if not serial.port or serial.port == "" then
        self.vm:reject_open()
        -- Refuse rather than "open whatever is first": an empty selection means
        -- either nothing chosen yet or the chosen port vanished.  The Open
        -- button is already disabled via the presence input; this covers the
        -- keyboard/action path too.
        if self.imgui then
            self.imgui:set_status("Select a port first")
        else
            self:_set_port_status("select a port before opening")
        end
        return
    end
    if self.imgui then self.imgui:set_status("Opening " .. serial.port .. " ...") end
    -- SIM: remember the requested port so the connected edge (in
    -- _render_ui_state, where port_state is confirmed OPEN) can decide
    -- whether to arm the simulator pump.  Only ever consulted while
    -- _sim_active.  Recorded here (not in _imgui_open) because the native
    -- on_btn_open path reaches the same core_open.
    self._sim_open_port = serial.port
    -- Open-time DTR/RTS are the explicit tri-state, NOT the live toggles: a
    -- Leave alone entry must reach the core as 2 so the open path issues no
    -- EscapeCommFunction and the target board is not reset.
    self:_mirror_open_lines(serial)
    local rc = xcom.open_async(self.core, serial.port, serial.baud_rate,
        serial.data_bits, serial.stop_bits, serial.parity, serial.flow_control,
        serial.dtr_open, serial.rts_open)
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

-- Close intent: allowed from OPEN/OPENING/FAULT only; a close already in
-- flight cannot be re-issued.
--
-- The wait budget is deliberately small.  xcom_close is synchronous, so every
-- millisecond of it is a millisecond the message pump is not running — on a
-- click that reads as the window locking up.  A healthy teardown confirms
-- CLOSED on the first poll (the ABI loop exits as soon as the state flips), so
-- the budget only matters when the port is genuinely wedged, and that case is
-- already handled: poll_status's CLOSING watchdog force-faults after
-- CLOSING_TIMEOUT_MS and restores the reconnect route.  Waiting the full
-- budget here just freezes the UI before the watchdog would have acted anyway.
local CLOSE_WAIT_MS = 200

function Window:core_close(timeout)
    if not self.core then
        return
    end
    if not self.vm:intent_close() then
        return
    end
    -- A batch sender must not survive a close.  The port is about to go away,
    -- so every remaining step would silently fail while the UI still advanced
    -- and finally reported "sequence done" -- a false success the user cannot
    -- see through.  Stopping on close is a DELIBERATE decision of THIS tool:
    -- no surveyed serial tool auto-cancels a periodic send on disconnect
    -- (COMTool's loop keeps spinning after sendData quietly returns), but a
    -- fake success plus a status bar that keeps re-flashing errors is worse.
    -- Done here so both close edges (_imgui_close / on_btn_close) share one
    -- choke point; the fault-disconnect edge is handled in _render_ui_state.
    if self._sequence_timer then
        self:_stop_sequence("sequence stopped: port closed")
    end
    if self._multi_timer then
        self._multi_timer:stop()
    end
    self:_render_ui_state()
    local rc = xcom.close(self.core, timeout or CLOSE_WAIT_MS)
    self:poll_status()
    -- Do NOT report a timeout here.  The wait above is deliberately short
    -- (CLOSE_WAIT_MS): the core's teardown can legitimately take ~1.7 s (write
    -- drain + read-thread cancellation grace), so a short-wait timeout is the
    -- EXPECTED outcome for any close that is not instantaneous, not a failure.
    -- Reporting it would put a false "did not confirm teardown" on the status
    -- bar for every slow-but-healthy close.  The CLOSING watchdog
    -- (CLOSING_TIMEOUT_MS, in poll_status) is the single owner of that report,
    -- and it fires only once the core has actually failed to converge.
    -- A REJECTED close event is different: nothing was submitted at all, so the
    -- session is still live and the user must be told.
    if tonumber(rc) == xcom.err_full then
        self:_set_port_status("Close was rejected by the core; the port may still be open")
    end
    return rc
end

function Window:core_send(data_bytes, flags)
    if DEBUG_MODE then
        dbg("[dbg] core_send len=%d flags=%d",
            data_bytes and #data_bytes or -1, tonumber(flags) or -1)
    end
    if not self.core then
        return false, xcom.err_not_open
    end
    -- Reset-sequence interlock: a reset drives DTR/RTS edges (and may detach the
    -- USB device), so bytes sent mid-pulse would race the detach and land on a
    -- handle the core is about to drop.  Refuse with a visible prompt; this one
    -- choke point covers single/multi/autosend/sequence/send-file/scripts.
    if self:_reset_in_flight() then
        self:_set_port_status("reset sequence in progress; send blocked")
        return false, (xcom.err_busy or -4)
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
            -- Route through the ACTIVE UI's status channel.  The legacy Win32
            -- label[3] is hidden in the shipped ImGui dashboard, so a manual
            -- send failure was completely silent there; _set_port_status reaches
            -- the visible one (imgui:set_status) and falls back to the label
            -- only in Win32 mode.
            self:_set_port_status("send failed: " .. (STATUS_TEXT[rc] or tostring(rc)))
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

-- Echo a transmitted payload into the SAME view the receive path uses
-- ([display] tx_echo, default on — llcom's showSend semantics: the user types
-- a command and sees it land in the receive window, and the auto-save capture
-- keeps it so the log reads like a session transcript).
--
-- This is the ONLY Lua writer into the log.  It does NOT double-write: the
-- core's raw-byte lane carries RX only, so the "TX: " line is new content, not
-- a second copy of something the lane already wrote (the RX log_append calls
-- were removed for exactly that reason — design §4 item 1).  Known debt, spec
-- A1: this direct xcom_log_append is a second producer into the file beside
-- the LogWriter's own RX queue, so strict TX/RX interleaving order is not
-- guaranteed; folding TX through an explicit marked LogWriter write is the
-- deferred correct arrangement.
--
-- Display side goes through _append_imgui_receive (so auto_clear/frame-gap
-- bookkeeping applies and the tail trims identically), with a "TX: " prefix
-- on its own row; the log gets the same line RAW (byte-faithful: CRLF payloads
-- keep their CR on disk, while the view folds it to LF like every RX line).
-- Runs only on the success path of core_send: a failed write never pollutes
-- the transcript.
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
        local rc = tonumber(xcom.log_append(self.core, raw, #raw))
        if rc ~= xcom.ok then
            -- The view renders this TX line but the capture file will not hold
            -- it (rejected block / saturated pool).  Surface the divergence so
            -- the log and the view never disagree silently.
            self:_set_port_status("TX not logged: " ..
                                  (STATUS_TEXT[rc] or tostring(rc)))
        end
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
    -- The [display] timestamp checkbox now gates the Lua ⑥ stage; the core
    -- no longer formats a timestamp (design §4 item 2), so this cache is what
    -- the drain funnel consults without touching the widget.
    self._timestamp_enabled = opts.timestamp and true or false
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
    -- Refresh the display-pause cache, consulted by the drain funnel.
    self._pause_display = opts.pause_display and true or false
    self:core_set_options({
        hex_view = opts.receive_hex,
        -- `timestamp` is deliberately NOT forwarded: after design §4 item 2
        -- the core formats no timestamp, and Lua owns ⑥.  Forwarding the flag
        -- would imply the core still acts on it — and would double-stamp if an
        -- older DLL (one that still injects) were loaded.
        -- The core's pause flag is deliberately NOT set either: it would freeze
        -- the same drain lane the viewport reads, so a pause would stall the
        -- display pipeline.  Pause is enforced in _process_rx_batch /
        -- poll_display instead, which skips only the viewport append.
        pause_display = false,
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
                self._log_open_path = path
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
-- Persistence contract (design §4 item 1): the core's raw-byte lane (read
-- thread -> LogWriter) is the ONLY writer of received bytes to the file.  Lua
-- deliberately does NOT log the drained batch — doing so wrote every RX byte
-- twice (once raw by the lane, once as formatted display text).  The 64 KiB
-- receive-tail window therefore only ever drops *visible* history; the file
-- keeps everything.  The drain runs until the core lane is empty (not a single
-- 64 KiB budget) so a brief UI stall cannot let the 512 KiB core pool fill up
-- and count rx_pool_exhausted_bytes — a full pool is the only true data-loss
-- path.  A hard round cap bounds the loop against a pathological producer.
function Window:poll_display()
    if not self.core or not self.connected then
        return
    end
    local drained_any = false
    local max_rounds = 8  -- 8 × 64 KiB = 512 KiB, one full core pool per poll
    for _ = 1, max_rounds do
        local rc, text, ingress_ms, ts_ok =
            xcom.drain_display_ts(self.core, 64 * 1024)
        if rc ~= xcom.ok or not text or #text == 0 then
            break
        end
        drained_any = true
        if self._pause_display then
            -- Display paused: the raw-byte lane has ALREADY persisted the
            -- batch, so pausing only skips the viewport funnel (the reason
            -- pause is not delegated to the core).  Account the skipped bytes
            -- so the status line can report "pause: N"; on resume only newly
            -- arriving data is shown.
            self._paused_display_bytes = (self._paused_display_bytes or 0) + #text
        else
            self:_process_rx_batch(text, ingress_ms, ts_ok)
            -- The native RICHEDIT is hidden while the ImGui dashboard is
            -- active; feeding it is invisible work that still walks the whole
            -- batch through EM_REPLACESEL + colouring.  Only feed when visible.
            if not self.imgui and self.recv and self.recv.feed then
                self.recv.feed(text)
            end
        end
    end
    if drained_any then
        -- New receive data changed the log tail; pull the next frame at the
        -- data cadence instead of waiting for the idle heartbeat.
        self:request_frame(FRAME_INTERVAL_DATA_MS)
    elseif self._rx_line_pending and #self._rx_line_pending > 0 and
           self._rx_idle_ms and not self._pause_display and
           (uv.now() - self._rx_idle_ms) >= self._timestamp_gap_ms then
        -- Idle flush (design §2): a device that never delimits frames (no LF)
        -- otherwise holds ONE short binary frame in the line bridge until the
        -- next arrival — or forever if nothing else comes.  An idle gap IS a
        -- frame boundary for such a device, so reuse the same segment-gap
        -- interval as a timer rather than adding one.  This stays consistent
        -- with the new-segment rule: the next batch, arriving after the same
        -- threshold, opens a fresh segment, so the frame is shown exactly once
        -- and later data still starts a new one.
        self:_flush_rx_lines(false)
        self:request_frame(FRAME_INTERVAL_DATA_MS)
    end
end
jit.off(Window.poll_display)

-- Design §3: does this batch open a new SEGMENT?  The clock is the batch's
-- EARLIEST ingress time supplied by the C++ drain export, not uv.now(): a
-- paused/backpressured stream that resumes must still be split by when the
-- bytes actually entered the machine, not when the UI got around to them.
-- With no export (older DLL) or no ingress value the gap rule is UNAVAILABLE,
-- so stamping stays OFF rather than stamping the wrong clock — and the
-- degradation is announced once, not per batch.
function Window:_rx_batch_is_new_segment(ingress_ms, ts_supported)
    if not ts_supported or ingress_ms == nil then
        if self._timestamp_enabled and not self._rx_ts_notice_given then
            self._rx_ts_notice_given = true
            local msg = "timestamp gap rule unavailable " ..
                        "(xcom_drain_display_ts missing); timestamping disabled"
            io.stderr:write("[display] " .. msg .. "\n")
            if self.scripts and self.scripts.log then
                self.scripts:log(4, "display", msg)
            end
            self:set_status_deferred(msg)
        end
        self._rx_ingress_ms = nil
        return false
    end
    -- Anchor the monotonic ingress clock to the wall clock on the first batch,
    -- so every stamp can be rendered as the wall time of ARRIVAL (§3).
    if self._rx_ts_mono_anchor == nil then
        self._rx_ts_mono_anchor = ingress_ms
        self._rx_ts_wall_anchor = wall_clock_ms()
    end
    local prev = self._rx_ingress_ms
    self._rx_ingress_ms = ingress_ms
    if prev == nil then
        return true   -- first batch of the session opens a segment
    end
    return (ingress_ms - prev) >= self._timestamp_gap_ms
end

-- Whole-line bridge (design §2).  Force the held partial line out now.
-- `discard` is reserved for the view-clear path, where the user asked the
-- visible history away and the partial would otherwise reappear; that path
-- counts the bytes in _rx_line_discarded so the drop is observable.  Every
-- other caller DELIVERS the partial (a device that never sends LF must not
-- have its data held forever), incrementing _rx_line_forced.
function Window:_flush_rx_lines(discard)
    local line = self._rx_line_pending
    if not line or #line == 0 then
        return
    end
    self._rx_line_pending = ""
    if discard then
        self._rx_line_discarded = (self._rx_line_discarded or 0) + #line
        return
    end
    self._rx_line_forced = (self._rx_line_forced or 0) + 1
    self:_emit_rx_text(line)
end

-- User-script stage (design §1 ⑤).  Runs the whole-line text through the
-- engine (transform -> filter; highlight rules are aggregated by the engine
-- and applied by the renderer to the surviving text).  A pcall failure here
-- used to make the whole batch vanish with only a stderr line; it is now
-- counted and surfaced (script log ring + status) and the batch is shown
-- UNCHANGED, so a broken user script reads as broken rather than as data that
-- never arrived.  The log entry is rate-limited (first + every 100th) so a
-- per-batch failure cannot flood the bounded ring.
function Window:_run_rx_scripts(text)
    if not self.scripts then
        return text
    end
    local ok, processed = pcall(self.scripts.process_rx, self.scripts, text)
    if not ok then
        self._rx_funnel_errors = (self._rx_funnel_errors or 0) + 1
        io.stderr:write("[scripts] rx funnel: " .. tostring(processed) .. "\n")
        local n = self._rx_funnel_errors
        if n == 1 or (n % 100) == 0 then
            local msg = string.format(
                "script rx funnel error x%d: %s (batch shown unchanged)",
                n, tostring(processed))
            if self.scripts.log then
                self.scripts:log(5, "engine", msg)
            end
            self:set_status_deferred(msg)
        end
        return text
    end
    if processed == nil or processed == "" then
        return nil
    end
    return processed
end

-- Final pipeline stage (design §1 ⑥): timestamp the first DISPLAYED line of
-- a segment.  It runs after ⑤ so scripts and the line filter see pure data, and
-- is the sole owner of stamping (the core no longer injects one).  Everything
-- that reaches the viewport funnels through here, including a force-flushed
-- partial line, so a segment whose first line was held still gets exactly one
-- stamp on the first text that survives.
function Window:_emit_rx_text(text)
    local out = self:_run_rx_scripts(text)
    if out == nil or out == "" then
        return
    end
    if self._rx_segment_stamp_pending then
        self._rx_segment_stamp_pending = false
        if self._timestamp_enabled then
            -- Render the segment's ARRIVAL wall time from its ingress value;
            -- nil (no anchor yet) falls back to now inside the helper.
            local wall
            local ing = self._rx_segment_ingress_ms
            if ing and self._rx_ts_mono_anchor then
                wall = self._rx_ts_wall_anchor + (ing - self._rx_ts_mono_anchor)
            end
            out = rx_timestamp_prefix(wall) .. out
        end
    end
    self:_append_imgui_receive(out)
end

-- Display-side receive funnel.  Order (design §1, immutable): segment decision
-- -> char auto-break -> charset conversion (④) -> whole-line bridge -> script
-- stage (⑤) -> timestamp (⑥) -> ImGui append (⑦).  The raw batch's
-- ingress time rides alongside because ②/③ no longer inject anything textual.
-- Perf note: this sits on the 10 ms drain path, so the engine's fast paths
-- (no scripts -> single boolean check; no filter rules -> single table scan)
-- are the budget-critical ones (see MEMORY.md receive-chain rules).
function Window:_process_rx_batch(text, ingress_ms, ts_supported)
    if not text or #text == 0 then
        return
    end
    -- A non-empty batch is an arrival: reset the idle anchor the poll tick
    -- uses to decide that a held partial line has gone quiet (see poll_display).
    self._rx_idle_ms = uv.now()
    -- Segment decision FIRST: an unterminated frame from the previous segment
    -- must not sit in the line bridge across a real gap, so it is flushed (and
    -- any stamp still owed to that segment applied) before this batch starts.
    local new_segment = self:_rx_batch_is_new_segment(ingress_ms, ts_supported)
    if new_segment then
        self:_flush_rx_lines(false)
    end
    -- Auto frame-break ([display] frame_gap_ms, "自动断帧").  NEITHER the
    -- core nor the ImGui DLL acts on it (the DLL only renders the toggle +
    -- ms field against Lua-owned int buffers; the core ABI has no gap
    -- concept), so it is enforced here, display-side: when this drained
    -- batch lands more than N ms after the previous one AND the view tail
    -- ends mid-line, force a chunk boundary + newline first so a half frame
    -- never sits open across an idle gap.  Persistence no longer depends on
    -- this path at all (the raw-byte lane writes the file untouched) — it is
    -- a pure display transform.  uv.now() is the loop-cached monotonic clock,
    -- so the several batches drained inside ONE poll never fake a gap.
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
    -- ④ -> ⑤ whole-line bridge: append to the held partial, hand only complete
    -- LF-terminated lines to the scripts, and keep the tail for the next batch.
    -- The evidence that scripts are line-oriented is the shipped plugin
    -- library: scripts/时间戳前缀.lua splits on "\n", scripts/绘制曲线-多条.lua
    -- parses "1.5,2.5\r\n" per line, scripts/数据截断.lua truncates per line.
    -- The hand-fixed mid-line double-stamp bug in 时间戳前缀.lua this session
    -- was a symptom of scripts seeing half lines — this stage removes the
    -- root cause, so a plugin never needs its own continuation bookkeeping.
    self._rx_line_pending = self._rx_line_pending .. text
    local complete, tail = split_complete_lines(self._rx_line_pending)
    self._rx_line_pending = tail
    if #tail > RX_LINE_CAP then
        -- Cap flush: a binary/never-terminated stream must not be held
        -- forever.  Deliver the WHOLE held tail atomically (splitting at the
        -- cap could cut a UTF-8 character in half) as one unterminated frame.
        complete = complete .. tail
        self._rx_line_pending = ""
        self._rx_line_forced = (self._rx_line_forced or 0) + 1
    end
    if new_segment and self._timestamp_enabled and ts_supported then
        self._rx_segment_stamp_pending = true
        self._rx_segment_ingress_ms = ingress_ms
    end
    if #complete > 0 then
        self:_emit_rx_text(complete)
    end
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
        -- Compact the retired prefix.  The table is only reset by
        -- _flush_imgui_receive, which runs from the ImGui frame; when the
        -- dashboard is unavailable (imgui == nil, no DLL) no frame ever flushes,
        -- so without this the retained table would pin every drained batch for
        -- the whole session (unbounded growth under a chatty link).  What
        -- remains is exactly the window-sized live tail.
        if cursor > 64 then
            local kept = {}
            for i = cursor, #chunks do
                kept[#kept + 1] = chunks[i]
            end
            self._imgui_receive_chunks = kept
            cursor = 1
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
    -- continues from empty.  The reset touches view state only: persistence
    -- is owned entirely by the core's raw-byte lane (design §4 item 1), and
    -- the core counters stay untouched.
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
-- the auto-save log (owned by the core's raw-byte lane, design §4 item 1) and
-- the core rx/tx counters — an auto clear must never touch either.  The
-- whole-line bridge's held partial is DISCARDED here (counted, not silent):
-- the user asked the visible history away, so replaying that partial into the
-- cleared view would resurrect it.
function Window:_clear_imgui_view()
    self:_flush_rx_lines(true)
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

-- Upper bound on the OPENING transitional state. The core's native serial open
-- is bounded to ~2 s; 5 s leaves generous headroom (slow USB enumeration,
-- driver retries) before the UI declares the open dead and faults back so the
-- user can retry.
local OPENING_TIMEOUT_MS = 5000

-- Close-side counterpart. The ABI close is synchronous, so the caller gives it
-- only CLOSE_WAIT_MS: a healthy teardown confirms CLOSED on the first poll,
-- and this watchdog is what catches one that never does — the case that would
-- otherwise strand the session in CLOSING permanently.
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

-- jit.off: this is the ImGui frame driver — it calls into the xcom_imgui C
-- DLL, whose wndproc path re-enters Lua through the WndProc FFI callback.
-- Traced frames were the second source of the "bad callback" PANIC.
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
    -- No explicit budget: core_close's CLOSE_WAIT_MS default is the short,
    -- non-blocking wait designed for exactly this click path.  Passing 2000
    -- here silently overrode that default and froze the message pump for up to
    -- two seconds on every close -- the freeze that commit b0994c2 set out to
    -- remove but could not, because this argument wins over the default.
    self:core_close()
end

function Window:_imgui_send_single()
    if not self.imgui then return end
    local send_text = self.imgui:send_text()
    if send_text == "" then return end
    local payload = xcom.build_send_payload(send_text,
        self.imgui.send_hex[0] ~= 0, self.imgui.send_crlf[0] ~= 0)
    -- build_send_payload returns nil for invalid HEX and "" (truthy) for a
    -- whitespace-only HEX box; both used to fall through to core_send or out
    -- silently, so the button looked dead.  Say why nothing was sent.
    if payload == nil then
        self:set_status_deferred("send: invalid HEX, nothing sent")
        return
    end
    if payload == "" then
        self:set_status_deferred("send: blank HEX, nothing sent")
        return
    end
    self:core_send(payload, xcom.send_text)
end

-- Snapshot the current Multi page for a batch sender.  Captures the enabled,
-- non-empty entry texts AND the HEX/CRLF encoding in one shot, at the moment
-- the batch starts.  Both the sequential Run and the auto-cycle timer take
-- their snapshot here, so paging or flipping an encoding toggle mid-flight
-- cannot silently change what goes on the wire (the "what the user saw when
-- they pressed the button" rule).  `lines` keeps the 1-based row number for
-- each entry so a skipped row can be named.
function Window:_snapshot_multi_batch()
    local entries, lines = {}, {}
    for index = 0, 7 do
        local text, enabled = self.imgui:multi_entry(index)
        if enabled and text ~= "" then
            entries[#entries + 1] = text
            lines[#lines + 1] = index + 1
        end
    end
    return {
        entries = entries,
        lines = lines,
        hex = self.imgui.multi_hex[0] ~= 0,
        crlf = self.imgui.multi_crlf[0] ~= 0,
    }
end

-- Send every enabled entry on the current multi page.  Serves the "Send
-- enabled" button (live read) and the auto-cycle timer (which passes a batch
-- snapshot taken when the cycle started, so a page switch in flight cannot
-- change the content).
function Window:_imgui_send_enabled(batch)
    local sent = 0
    local failed = 0                  -- core_send refused (port fault / not open)
    local skipped_unchecked = false   -- has text but the enable box is clear
    local bad_hex = nil               -- first slot whose HEX text failed to parse
    local slots = {}                  -- { text =, line = } in page order
    local hex, crlf
    if batch then
        hex, crlf = batch.hex, batch.crlf
        for i, text in ipairs(batch.entries) do
            slots[#slots + 1] = { text = text, line = batch.lines[i] }
        end
    else
        hex = self.imgui.multi_hex[0] ~= 0
        crlf = self.imgui.multi_crlf[0] ~= 0
        for index = 0, 7 do
            local text, enabled = self.imgui:multi_entry(index)
            if text ~= "" and not enabled then
                skipped_unchecked = true
            end
            if enabled and text ~= "" then
                slots[#slots + 1] = { text = text, line = index + 1 }
            end
        end
    end
    for _, slot in ipairs(slots) do
        local payload = xcom.build_send_payload(slot.text, hex, crlf)
        if payload == nil and bad_hex == nil then
            bad_hex = slot.line
        end
        -- build_send_payload returns "" (a TRUTHY empty string) for a
        -- whitespace-only HEX slot; core_send silently drops empty data,
        -- which reads as "clicked Send enabled and nothing happened".
        if payload and payload ~= "" then
            -- A refused write (port FAULT / not open) must NOT count as
            -- sent: the old unconditional increment made a batch that put
            -- nothing on the wire look successful and suppressed every hint.
            local ok = self:core_send(payload, xcom.send_text)
            if ok then
                sent = sent + 1
            else
                failed = failed + 1
            end
        end
    end
    -- Silence is what made the original report ("clicked it and nothing
    -- happened") unactionable, so every no-send path explains itself once.
    -- A refused batch reports the count so the user knows nothing was sent.
    if self.imgui and failed > 0 then
        self:set_status_deferred("multi: " .. failed .. " slot(s) not sent")
    elseif self.imgui and sent == 0 then
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
    if payload ~= "" then
        local ok, rc = self:core_send(payload, xcom.send_text)
        if not ok then
            self:set_status_deferred("multi slot " .. (index + 1) ..
                ": not sent" .. (rc and
                (" (" .. (STATUS_TEXT[tonumber(rc)] or tostring(rc)) .. ")") or ""))
        end
    end
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
    -- Refuse to (re)arm a core-side auto template during a reset: it would
    -- transmit from inside the core, bypassing core_send's interlock.
    if self:_reset_in_flight() then
        if self.imgui.send_auto then self.imgui.send_auto[0] = 0 end
        if xcom.set_auto_template then
            xcom.set_auto_template(self.core, "", 0, xcom.send_text)
        end
        self:set_status_deferred("autosend refused: reset sequence running")
        return
    end
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
        -- Visible channel: the legacy labels[3] is a HIDDEN Win32 control under
        -- the ImGui dashboard, so this was a silent failure there.  Same route
        -- as core_send's send-failure message (_set_port_status).
        self:_set_port_status("autosend payload invalid: " .. tostring(err))
        return
    end
    xcom.set_auto_template(self.core, payload, math.max(10, self.imgui.send_period[0]), xcom.send_text)
end

function Window:_send_imgui_multi()
    if not self.imgui then return end
    -- Auto-cycle sends the snapshot taken when the cycle started; a page
    -- switch or encoding toggle mid-flight must not change the batch.
    if self._multi_snapshot then
        self:_imgui_send_enabled(self._multi_snapshot)
    else
        self:_imgui_send_enabled()
    end
end
jit.off(Window._send_imgui_multi)  -- entered from a libuv timer callback

function Window:_sync_imgui_multi_auto()
    if not self.imgui then return end
    -- Same reset interlock as autosend: the auto-cycle must not start while a
    -- reset owns the bus.
    if self:_reset_in_flight() then
        if self.imgui.multi_auto then self.imgui.multi_auto[0] = 0 end
        self:set_status_deferred("auto-cycle refused: reset sequence running")
        return
    end
    if self.imgui.multi_auto[0] == 0 then
        if self._multi_timer then
            self._multi_timer:stop()
            self._multi_timer:close()
            self._multi_timer = nil
        end
        self._multi_snapshot = nil
        return
    end
    -- Batch-vs-batch interlock: the auto-cycle and the sequential Run are both
    -- long-running paced senders and must never share the bus (they would
    -- interleave on the wire and, under TX backpressure, starve each other).
    -- Refuse and clear the toggle so the UI shows it did not start; do NOT
    -- silently stop the sequence the user started.
    if self._sequence_timer then
        self.imgui.multi_auto[0] = 0
        self:set_status_deferred("auto-cycle refused: sequence running")
        return
    end
    -- File-send interlock (see _imgui_run_sequence): a streaming file send
    -- retries a full TX queue with backoff while the auto-cycle ignores the
    -- core_send return, so the cycle would starve the file send.  Refuse and
    -- clear the toggle so the UI shows it did not start; never stop the file
    -- send.
    if self.scripts and self.scripts.any_script_busy and
       self.scripts:any_script_busy() then
        self.imgui.multi_auto[0] = 0
        self:set_status_deferred("auto-cycle refused: file send in progress")
        return
    end
    -- Snapshot the page once, here, so paging cannot change an in-flight batch.
    self._multi_snapshot = self:_snapshot_multi_batch()
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
        self:_set_port_status("auto-save: choose a log path first")
        return
    end
    if enabled then
        -- A reconnect re-runs this (the OFFLINE -> ONLINE edge re-pushes every
        -- per-session display option), but the log SURVIVES a disconnect: only
        -- an explicit close tears it down, and the core's kCloseCommit does
        -- not touch the LogWriter.  Re-issuing log_open against the still-open
        -- writer returns XCOM_ERR_BUSY (log_writer.cpp), which the else branch
        -- below used to misread as a failure -- flipping the persisted
        -- auto-save setting off and showing "cannot open" as a side effect of
        -- a disconnect.  Same path while already open is a no-op, not an error.
        if self._log_active and path == self._log_open_path then
            return
        end
        -- Path changed while open (the user picked a new file): the writer
        -- refuses a second open, so retire the old file first.  Synchronous
        -- close matches the quit path and keeps the new open from racing the
        -- old writer's teardown; it runs only on a real path change, never on
        -- the reconnect edge.
        if self._log_active and path ~= self._log_open_path then
            self:_log_close_with_retry()
        end
        -- Status codes are cdata ints; 0 is truthy in Lua, so compare
        -- explicitly against xcom.ok rather than using `not`.
        if tonumber(xcom.log_open(self.core, path, true)) == xcom.ok then
            self._log_active = true
            self._log_open_path = path
        else
            self.imgui.auto_save[0] = 0
            self:_set_port_status("auto-save: cannot open " .. path)
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
        -- Hover tooltips, index-aligned with names/labels exactly as the
        -- engine builds both from the same self.order ("" == no tooltip).
        local descs = self.scripts:script_tooltips()
        local signature = table.concat(names, ",") .. "\1" ..
            table.concat(labels, ",") .. "\1" ..
            table.concat(descs, ",")
        if signature ~= self._script_list_signature then
            self._script_list_signature = signature
            self.imgui:set_scripts(names, labels, descs)
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
    -- Batch-vs-batch interlock: the auto-cycle and the sequential Run must not
    -- run at once.  Refuse and say so; do NOT silently stop the other batch.
    if self._multi_timer then
        self:set_status_deferred("sequence refused: auto-cycle running")
        return
    end
    -- File-send interlock: send_file streams with a backoff-RETRY on a full TX
    -- queue (send_file.lua err_full -5), while a sequence ignores core_send's
    -- return value and charges on.  Run together and the sequence starves the
    -- file send, whose chunks are then silently dropped.  Refuse to start while
    -- any script is streaming; never stop the file send (the user's own action
    -- stands).  XCOM states the same rule: single / auto / file transfer are
    -- mutually exclusive (docs/design-serial-tool-comparison.md).
    if self.scripts and self.scripts.any_script_busy and
       self.scripts:any_script_busy() then
        self:set_status_deferred("sequence refused: file send in progress")
        return
    end
    local batch = self:_snapshot_multi_batch()
    local entries = batch.entries
    if #entries == 0 then
        self:set_status_deferred("sequence: no enabled entries on this page")
        return
    end
    -- libuv treats repeat=0 as a ONE-SHOT timer: gap=0 sent only the first
    -- entry and left _sequence_timer non-nil (Run flipped to Stop forever).
    -- Clamp to >= 1 so the timer always repeats (auto-cycle clamps to 10).
    local gap = 100
    if self.imgui.multi_gap then
        gap = math.max(1, tonumber(self.imgui.multi_gap[0]) or 100)
    end
    -- Encoding is snapshotted WITH the texts (same call) so a mid-flight HEX /
    -- CRLF toggle cannot make the second half of a sequence encode differently
    -- from the first.
    local hex, crlf = batch.hex, batch.crlf
    self._sequence_entries = entries
    self._sequence_index = 0
    local skipped_bad = {}    -- 1-based lines whose HEX text failed to parse
    local skipped_blank = {}  -- 1-based lines that were whitespace-only HEX
    self._sequence_timer = uv.new_timer()
    local step
    step = function()
        self._sequence_index = self._sequence_index + 1
        local index = self._sequence_index
        if index > #entries or not self.imgui then
            self:_stop_sequence()
            return
        end
        local abort = nil
        local ok, err = pcall(function()
            local payload = xcom.build_send_payload(entries[index], hex, crlf)
            if payload == nil then
                skipped_bad[#skipped_bad + 1] = batch.lines[index]
                return
            end
            if payload == "" then
                skipped_blank[#skipped_blank + 1] = batch.lines[index]
                return
            end
            -- A refused send (port FAULT / not open) must stop the sequence,
            -- not be swallowed: otherwise the remaining entries all fail
            -- silently and the run still ends on "sequence done".
            local sent, rc = self:core_send(payload, xcom.send_text)
            if not sent then abort = { rc = rc } end
        end)
        if not ok then io.stderr:write("[sequence] " .. tostring(err) .. "\n") end
        if abort then
            local reason = ""
            if abort.rc then
                reason = " (" ..
                    (STATUS_TEXT[tonumber(abort.rc)] or tostring(abort.rc)) .. ")"
            end
            self:_stop_sequence(string.format("sequence stopped at %d/%d: send failed%s",
                index, #entries, reason))
            return
        end
        -- Name every line that produced no payload, even when other entries
        -- did send, so a partial batch is never reported as fully successful.
        local notice = ""
        if #skipped_bad > 0 then
            notice = "line " .. table.concat(skipped_bad, ",") .. " invalid HEX"
        end
        if #skipped_blank > 0 then
            if notice ~= "" then notice = notice .. "; " end
            notice = notice .. "line " .. table.concat(skipped_blank, ",") .. " blank HEX"
        end
        if notice ~= "" then notice = " [" .. notice .. " not sent]" end
        if index >= #entries then
            self:_stop_sequence(string.format("sequence done %d/%d%s",
                index, #entries, notice))
            return
        end
        self:set_status_deferred(string.format("sequence %d/%d%s",
            index, #entries, notice))
    end
    jit.off(step, true)
    self._sequence_timer:start(0, gap, step)
end

function Window:_stop_sequence(final_status)
    if self._sequence_timer then
        self._sequence_timer:stop()
        self._sequence_timer:close()
        self._sequence_timer = nil
    end
    self._sequence_entries = nil
    self:set_status_deferred(final_status or "sequence done")
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
        self._log_open_path = nil
        return true
    end
    for _ = 1, 3 do
        rc = tonumber(xcom.log_close(self.core, 500))
        if rc == xcom.ok then
            self._log_active = false
            self._log_open_path = nil
            return true
        end
    end
    self:_set_port_status("log close failed: " ..
                          (STATUS_TEXT[rc] or tostring(rc)))
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
        self._log_open_path = nil
        self._log_close_defer_attempts = nil
        self:_set_port_status("log closed")
        return
    end
    self._log_close_defer_attempts = (self._log_close_defer_attempts or 0) + 1
    if self._log_close_defer_attempts <= 20 then
        self:schedule_defer(function() self:_log_close_deferred() end)
    else
        self._log_close_defer_attempts = nil
        self:_set_port_status("log close failed: " ..
                              (STATUS_TEXT[rc] or tostring(rc)))
    end
end

function Window:_choose_imgui_log_path()
    local path = self:_save_file_dialog(self.cfg and self.cfg.save_path or "")
    if not path or path == "" then return end
    self.cfg.save_path = path
    if self.imgui and self.imgui.auto_save[0] ~= 0 then self:_sync_imgui_autosave() end
    self:_set_port_status("auto-save: " .. path)
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
            -- take_open_result now returns the recorded owner result mapped to
            -- an XCOM_ERR_* enumerator (core abi/open_failure_status.hpp): a raw
            -- positive Win32 code is folded to the closest enumerator, so
            -- describe_open_error (keyed on positive Win32 codes) no longer
            -- matches here and the fallback is the generic status text.  The
            -- specific, actionable cause is NOT lost: sink_owner_open pushes the
            -- raw Win32 code into the error ring, which _poll_errors drains at
            -- the end of this same poll and translates ("E5: 端口被其他程序占用
            -- 或权限不足").  This line stays as the immediate enumerator-level
            -- fallback; it does not replace the ring-derived message.
            local cause = xcom.describe_open_error and
                          xcom.describe_open_error(open_result)
            if self.imgui then
                self.imgui:set_status("Open failed: " ..
                    (cause or STATUS_TEXT[open_result] or tostring(open_result)))
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
        -- OPENING, and with no recovery path at all.
        --
        -- Force FAULT only when the last authoritative snapshot is NOT itself
        -- CLOSING. owner_close runs stop_and_join() on the writer thread,
        -- bounded by a 60 s write timeout, so a slow disk legitimately keeps
        -- the CORE in CLOSING past this 5 s UI deadline. Faulting then made the
        -- next Open read the still-CLOSING core and return BUSY ("Open failed:
        -- busy"), and repeated polls oscillated FAULT <-> CLOSING. While the
        -- core is genuinely closing, keep the UI in its CLOSING presentation;
        -- the core's own bound resolves it and on_snapshot then converges.
        if self._closing_deadline == nil then
            self._closing_deadline = uv.now() + CLOSING_TIMEOUT_MS
        elseif uv.now() >= self._closing_deadline and
               self.port_state ~= xcom.port_closing then
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
    -- Suppressed while a reset sequence owns the lines, or this 250 ms poll
    -- would fight the sequencer's millisecond edges.
    if self.vm.hsm.state == self.vm.STATE_OPEN and self.imgui and self.imgui.dtr and
       not self:_reset_in_flight() then
        local dtr = self.imgui.dtr[0] ~= 0
        local rts = self.imgui.rts[0] ~= 0
        -- RTS is driven by the driver under RTS/CTS flow control, and
        -- xcom_set_lines rejects the ENTIRE request (before applying DTR) when
        -- rts ~= 0 while flow_control == 1.  Ask only for the DTR half then, so
        -- a DTR change still reaches the wire instead of being dragged down by
        -- the RTS half; RTS itself is left to the driver.
        local flow_hw = self.imgui.flow and self.imgui.flow[0] == 1
        local want_rts = (not flow_hw) and rts
        local dtr_changed = dtr ~= self._lines_dtr
        local rts_changed = rts ~= self._lines_rts
        if dtr_changed or rts_changed then
            -- Record the DESIRED UI levels BEFORE the call so a rejected or
            -- driver-owned edge is not retried on every 250 ms poll.  The old
            -- code reset these to nil on error, which re-fired the same failing
            -- call and flashed the same status line forever.
            self._lines_dtr = dtr
            self._lines_rts = rts
            -- Under HW flow control the RTS half is driver-owned: apply only
            -- when there is a DTR half to send, never poke the pin just to
            -- clear it (the ABI would reject rts=1 outright anyway).
            local need_call = dtr_changed or (rts_changed and not flow_hw)
            local rc = need_call and xcom.set_lines and
                       xcom.set_lines(self.core, dtr, want_rts)
            -- Under HW flow control the core applies DTR FIRST and then reports
            -- XCOM_ERR_UNSUPPORTED for the RTS half it cannot honor.  The code
            -- therefore means "DTR applied, RTS is driver-owned" -- NOT "nothing
            -- happened".  Treating it as an error would put "DTR/RTS not applied"
            -- on screen for a DTR change that did reach the wire, which is the
            -- mirror image of the false success this whole path was fixed for.
            -- Only a real IO/NOT_OPEN failure means the change did not land.
            local rts_driver_owned = flow_hw and
                tonumber(rc) == xcom.err_unsupported
            if need_call and rc ~= nil and tonumber(rc) ~= xcom.ok and
               not rts_driver_owned and self.imgui then
                self:set_status_deferred(
                    "DTR/RTS not applied: " .. (STATUS_TEXT[tonumber(rc)] or tostring(rc)))
            elseif flow_hw and rts_changed and rts then
                -- DTR was applied (or had nothing to change), but the checked
                -- RTS box cannot be honored while HW flow control owns the pin;
                -- say so once per edge.
                self:set_status_deferred("RTS is driven by HW flow control")
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
            -- Losses that accrued between the OLD generation's last poll and the
            -- first snapshot of the new one must not vanish.  The close-boundary
            -- drain counts a final unowned_drop in save_rejected_bytes while the
            -- core is still CLOSING, and only kCloseCommit (which is what
            -- advances the generation) ends that window -- so the increment
            -- lands after our last look at the old generation.  Carry the
            -- residual from the last observed raw counter into the new
            -- session's baseline: the new generation opens with that deficit,
            -- so a real final loss still raises the DATA LOSS banner instead of
            -- being folded into the fresh baseline.  Display backlog
            -- (rx_pool_exhausted_bytes) is deliberately NOT carried: it is not
            -- loss and stays per-session, as does the backpressure warning.
            local carry_log = 0
            local carry_overrun = 0
            if self._loss_last_log then
                carry_log = (snap.save_rejected_bytes or 0) - self._loss_last_log
                if carry_log < 0 then carry_log = 0 end
            end
            if self._loss_last_overrun then
                carry_overrun = (snap.overrun_errors or 0) -
                                 self._loss_last_overrun
                if carry_overrun < 0 then carry_overrun = 0 end
            end
            self._loss_gen = snap.generation
            self._loss_base_pool = snap.rx_pool_exhausted_bytes or 0
            self._loss_base_overrun = (snap.overrun_errors or 0) - carry_overrun
            self._loss_base_bp = snap.rx_backpressure_events or 0
            self._loss_base_log = (snap.save_rejected_bytes or 0) - carry_log
            -- Line-error counters are monotonic across opens too: baseline them
            -- per session so the display reads "since this open", matching the
            -- loss ledger.  No carry: these are event counts, not bytes.
            self._line_base_frame = snap.framing_errors or 0
            self._line_base_parity = snap.parity_errors or 0
            self._line_base_overrun = snap.overrun_errors or 0
            self._line_base_break = snap.break_events or 0
            self._line_banner = nil
            self._loss_seen = 0
            self._bp_seen = 0
            self._loss_banner = nil
            -- Pause-skip accounting is per SESSION too (reset on a new open).
            self._paused_display_bytes = 0
            -- Recovery-overlay per-session baselines: the flow-hold counter and
            -- the profile's silent threshold both describe THIS session.
            self._flow_hold_last = snap.flow_hold_events or 0
            self._flow_hold_active_until = nil
            self._silent_warn_ms = nil
        end
        -- Remember this poll's raw ledger values so the NEXT generation change
        -- can measure what accrued after it (see the carry comments above).
        self._loss_last_log = snap.save_rejected_bytes or 0
        self._loss_last_overrun = snap.overrun_errors or 0
        -- Recovery overlay: a RISE in the v1.6 flow_hold_events counter means the
        -- driver held TX (CTS deasserted / XOFF).  Keep tx_stalled raised while
        -- the counter keeps rising, then let it decay: this is the "hold
        -- released -> OPEN" exit.  It NEVER forces a fault or closes the port.
        local hold = snap.flow_hold_events or 0
        if hold ~= (self._flow_hold_last or 0) then
            self._flow_hold_last = hold
            self._flow_hold_active_until = uv.now() + FLOW_HOLD_QUIET_MS
            self:set_status_deferred("TX held by flow control (peer not ready)")
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
            self._reconnect_known_ports = nil
            self._reconnect_candidate_names = nil
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
                -- Fresh window: no re-enumeration candidate has been observed
                -- yet (the overlay derives port_gone/reenum/ambiguous from this).
                self._reconnect_candidate_names = nil
                -- Snapshot the ports attached NOW.  A description match is only
                -- trusted when the candidate's name was NOT in this set: that
                -- rules out silently adopting a peer that was already plugged
                -- in (two adapters of the same model, original unplugged),
                -- while still following the original device when USB
                -- re-enumerates it to a new COMx.
                self._reconnect_known_ports = self:_present_port_names()
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
                        self._reconnect_known_ports = nil
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
                            local sep = "\n[XCOM] reconnected to " ..
                                (self._imgui_port or "serial port") ..
                                " - device output resumes below\n"
                            self:_append_imgui_receive(sep)
                            -- The log spans sessions (it is not closed on a
                            -- reconnect), so without the same boundary in the
                            -- file a reader of the .log cannot tell where one
                            -- session ended.  This is the synthetic-write form
                            -- the TX echo uses, and it is NOT a double write:
                            -- the core's raw-byte lane carries RX only (see
                            -- _echo_tx / poll_display), so the separator is new
                            -- content.  Same bytes as the viewport so both read
                            -- alike.
                            if self._log_active and self.core then
                                xcom.log_append(self.core, sep, #sep)
                            end
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
        -- Pause is enforced display-side (see _process_rx_batch), so the core
        -- counter stays 0; report the bytes skipped by the Lua viewport instead.
        local paused = self._paused_display_bytes or 0
        -- Loss ledger, from two genuinely-lost sources. rx_pool_exhausted_bytes
        -- is NOT one of them: it is display backlog that an open log still
        -- holds, so it is reported as backlog, never as DATA LOSS.
        --   * save_rejected_bytes: accepted bytes no consumer kept - no log
        --     was open, the writer queue was full, or an unwritten tail at
        --     close. Exact byte count, so it is the primary loss ledger.
        --   * overrun_errors: bytes lost inside the driver FIFO, count
        --     unknowable, event countable.
        local sess_overrun = (snap.overrun_errors or 0) -
                             (self._loss_base_overrun or 0)
        local sess_log = (snap.save_rejected_bytes or 0) -
                         (self._loss_base_log or 0)
        if sess_overrun < 0 then sess_overrun = 0 end
        if sess_log < 0 then sess_log = 0 end
        local loss_events = sess_overrun + sess_log
        if loss_events ~= (self._loss_seen or 0) then
            self._loss_seen = loss_events
            if loss_events > 0 then
                -- Latched banner: re-asserted every poll below so an unrelated
                -- status write cannot make the loss flash and vanish.
                if sess_overrun > 0 and sess_log > 0 then
                    self._loss_banner = string.format(
                        "DATA LOSS: driver overrun x%d + %d B not stored @ offset %d",
                        sess_overrun, sess_log, snap.rx_loss_offset or 0)
                elseif sess_overrun > 0 then
                    self._loss_banner = string.format(
                        "DATA LOSS: driver RX overrun x%d @ offset %d - lower baud/flow",
                        sess_overrun, snap.rx_loss_offset or 0)
                else
                    -- Received bytes no consumer kept: no log was open, the
                    -- writer queue was full, or a tail went unwritten at close.
                    -- The overrun wording would name the wrong cause.
                    self._loss_banner = string.format(
                        "DATA LOSS: %d B received but not stored @ offset %d (seq %d)",
                        sess_log, snap.rx_loss_offset or 0, snap.rx_sequence or 0)
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
            -- by the banner below anyway.  Route it through BOTH the legacy
            -- Win32 status bar and the ImGui status path: the legacy bar is
            -- hidden while the dashboard is active, so writing labels[3] alone
            -- left a paused user with no visible indication that data was
            -- accumulating (same set_status_deferred route as DATA LOSS).
            if not self._loss_banner then
                local info = string.format("drops: %d  trim: %d  pause: %d",
                                           drops, trim, paused)
                c.set_text(self.status.labels[3], info)
                self:set_status_deferred(info)
            end
        end
        -- v1.5 line errors: ClearCommError counters from the core, counted
        -- SESSION-relative (baselines reset per generation, like the loss
        -- ledger).  A wrong baud rate shows up as a frame/parity storm, so the
        -- per-kind breakdown must stay visible instead of flashing once.  Line
        -- errors are a DIFFERENT fault from DATA LOSS (far end / wiring vs the
        -- driver dropping bytes): combine the two, never let one suppress the
        -- other.  No polarity/baud heuristic here - only the raw per-kind
        -- counts (thresholds would need real-line calibration).
        local line_frame = (snap.framing_errors or 0) - (self._line_base_frame or 0)
        local line_parity = (snap.parity_errors or 0) - (self._line_base_parity or 0)
        local line_overrun = (snap.overrun_errors or 0) - (self._line_base_overrun or 0)
        local line_break = (snap.break_events or 0) - (self._line_base_break or 0)
        if line_frame < 0 then line_frame = 0 end
        if line_parity < 0 then line_parity = 0 end
        if line_overrun < 0 then line_overrun = 0 end
        if line_break < 0 then line_break = 0 end
        if line_frame + line_parity + line_overrun + line_break > 0 then
            self._line_banner = string.format(
                "LINE ERRORS: frame %d parity %d overrun %d break %d (this session)",
                line_frame, line_parity, line_overrun, line_break)
        else
            self._line_banner = nil
        end
        -- Persistence: the status line is a single slot, so a banner written
        -- once is overwritten by the next status producer.  Re-assert every
        -- poll while either banner is active; show BOTH when both are present.
        local banner = self._loss_banner
        if self._line_banner then
            banner = banner and (banner .. "  |  " .. self._line_banner)
                            or self._line_banner
        end
        if banner then
            c.set_text(self.status.labels[3], banner)
            if self._line_banner then
                -- The ImGui status slot is one-shot too; re-push so the line
                -- breakdown cannot be overwritten while the error persists.
                self:set_status_deferred(banner)
            end
        end
        -- Early warning BEFORE any loss: the file lane's blocks were all in use
        -- because the write thread stopped draining them -- a dead disk or a
        -- wedged write (rx_backpressure_events).  No bytes are lost yet: the
        -- read callback blocks for storage rather than dropping, and the
        -- writer's own ErrorRing entry names the Win32 cause.  The driver FIFO
        -- is what fills next, so surface it once per new count.  No persistent
        -- banner here.
        local sess_bp = (snap.rx_backpressure_events or 0) -
                        (self._loss_base_bp or 0)
        if sess_bp < 0 then sess_bp = 0 end
        if sess_bp ~= (self._bp_seen or 0) then
            self._bp_seen = sess_bp
            if sess_bp > 0 and loss_events == 0 then
                self:set_status_deferred(string.format(
                    "storage stalled x%d: write thread not draining (disk slow or device gone)",
                    sess_bp))
                self:request_frame(FRAME_INTERVAL_ACTIVE_MS)
            end
        end
        -- v1.5 line errors are folded into the session-relative LINE ERRORS
        -- banner above (combined with DATA LOSS, re-asserted every poll).
        -- USB-UART bridge, MCU powered down: the adapter stays enumerated and
        -- the COM port stays present, so there is NO device-change event and
        -- this must never be reported as "device gone".  The honest signal is a
        -- SILENT line -- optionally with framing/break noise, reported above,
        -- as the far end collapses.  Report once per idle stretch while OPEN;
        -- the next byte clears it.  (A direct-USB MCU is different: its device
        -- node disappears -> WM_DEVICECHANGE + read fault -> FAULT.)
        if snap.port_state == xcom.port_open then
            -- Per-profile idle threshold (design step 5 / silent_warn_ms),
            -- resolved once per session; falls back to the legacy constant.
            if self._silent_warn_ms == nil then
                local profile = self:_resolve_device_profile()
                self._silent_warn_ms = tonumber(profile.silent_warn_ms)
                                      or LINE_SILENT_MS
            end
            local warn_ms = self._silent_warn_ms or LINE_SILENT_MS
            if snap.rx_bytes ~= self._silent_rx_bytes then
                self._silent_rx_bytes = snap.rx_bytes
                self._silent_since = uv.now()
                self._silent_reported = false
            elseif self._silent_since and not self._silent_reported and
                   (uv.now() - self._silent_since) >= warn_ms then
                self._silent_reported = true
                local frame_n = snap.framing_errors or 0
                local break_n = snap.break_events or 0
                local msg
                if frame_n > 0 or break_n > 0 then
                    -- Collapse signature: the far end went away mid-character
                    -- and the line is now quiet.  Still not "device gone".
                    msg = string.format(
                        "line silent for %ds with frame/break noise (frame %d break %d) - device may be powered off",
                        math.floor(warn_ms / 1000), frame_n, break_n)
                else
                    -- Plain silence is normal for a command/response device;
                    -- report it factually, never as a fault.
                    msg = string.format("no RX for %ds (line silent)",
                        math.floor(warn_ms / 1000))
                end
                self:set_status_deferred(msg)
            end
        else
            -- Leaving OPEN for any reason resets the idle window, so a later
            -- open starts its own fresh stretch.
            self._silent_since = nil
            self._silent_reported = false
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

-- Names enumerated right now, as a set (name -> true).  The reconnect path
-- snapshots this when the grace window is armed so _resolve_reconnect_port can
-- tell a genuinely NEW port (the original adapter re-enumerated under a new
-- COMx) from a peer that was already attached: only the former may be adopted.
function Window:_present_port_names()
    local names = {}
    for _, p in ipairs(xcom.list_ports() or {}) do
        if p and p.name and p.name ~= "" then
            names[p.name] = true
        end
    end
    return names
end

-- Resolve the port to reopen. Returns (target, matched):
--   * original still enumerated -> (original, true)
--   * original gone, exactly one NEWLY appeared port carries the same
--     description -> (that name, true)   [the USB re-enumeration case]
--   * otherwise -> (original, false)     [no reliable match]
-- Ambiguity (0 or >1 description matches) counts as no match on purpose: opening
-- the wrong device is worse than asking the user to reselect.  A port that was
-- already present when the window armed (self._reconnect_known_ports) is never a
-- match, or a second adapter of the same model would be silently adopted when
-- the original is unplugged.
function Window:_resolve_reconnect_port(original, desc)
    if not original or original == "" then
        return original, false
    end
    local known = self._reconnect_known_ports
    local present = false
    local candidate = nil
    local candidate_count = 0
    -- Names of NEWLY-appeared same-description peers.  Retained on `self` so the
    -- recovery overlay can distinguish a unique re-enumeration (port_reenum)
    -- from an ambiguous one (port_ambiguous); only the count is used here.
    local candidates = {}
    for _, p in ipairs(xcom.list_ports() or {}) do
        if p.name == original then
            present = true
        elseif desc and p.description and p.description ~= "" and
               p.description == desc and not (known and known[p.name]) then
            candidate = p.name
            candidate_count = candidate_count + 1
            candidates[#candidates + 1] = p.name
        end
    end
    self._reconnect_candidate_names = candidates
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
        self._reconnect_known_ports = nil
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
    self:_mirror_open_lines(serial)
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
        -- Kick off the core reset for this attempt.  This runs inside the
        -- status poll, so keep the synchronous wait short for the same reason
        -- core_close does: a long block here stalls the pump mid-reconnect,
        -- and the CLOSING watchdog is what covers a teardown that does not
        -- confirm.
        xcom.close(self.core, CLOSE_WAIT_MS)
        self._reconnect_phase = "open"
    elseif self._reconnect_phase == "open" then
        if not self._reconnect_pending and have_port then
            self._reconnect_attempt = (self._reconnect_attempt or 0) + 1
            local rc = xcom.open_async(self.core, serial.port, serial.baud_rate,
                serial.data_bits, serial.stop_bits, serial.parity, serial.flow_control,
                serial.dtr_open, serial.rts_open)
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
            -- the device reappears.  When the cause is ambiguity, name the
            -- candidates so the user knows which choice is at stake.
            local candidates = self._reconnect_candidate_names or {}
            if #candidates > 1 then
                self.imgui:set_status(string.format(
                    "端口已消失，检测到多个同名设备(%s)，请重新选择端口",
                    table.concat(candidates, ", ")))
            else
                self.imgui:set_status("端口已消失，可能是设备重新枚举，请重新选择端口")
            end
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

-- ===========================================================================
-- Reset / ROM-entry sequencer driver (design-device-profiles step 4)
--
-- The sequencer itself (core/reset_sequencer.lua) never sleeps and owns no
-- timer.  This window owns the ~5 ms luv timer that advances it with
-- seq:step(uv.now()); the UI thread stays free the whole time.  The set_lines
-- wrapper converts the sequencer's numeric 0/1 line state to the booleans
-- xcom.set_lines() expects.
-- ===========================================================================

-- The port the user has selected.  Kept independent of _serial_config so the
-- profile lookup works even before the panel controls exist (and never touches
-- the native combo getters).
function Window:_selected_port_name()
    if self._imgui_port and self._imgui_port ~= "" then
        return self._imgui_port
    end
    if self.cfg and self.cfg.port and self.cfg.port ~= "" then
        return self.cfg.port
    end
    return nil
end

-- Enumerated record for `name` (carries description + v1.6 hardware_id), or nil.
function Window:_port_info_by_name(name)
    if not name or name == "" then
        return nil
    end
    for _, p in ipairs(xcom.list_ports() or {}) do
        if p.name == name then
            return p
        end
    end
    return nil
end

-- Resolve the device profile for the selected port.  hardware_id is the stable
-- key (design step 6); when the DLL does not report one this degrades to the
-- description heuristic, then to the table's `default` profile.  Never raises:
-- a resolution problem must not break the reset button.
function Window:_resolve_device_profile()
    local info = self:_port_info_by_name(self:_selected_port_name())
    local port_info = {
        hardware_id = info and info.hardware_id or nil,
        description = info and info.description or nil,
    }
    local ok, profile, source = pcall(device_profiles.for_config,
                                      self.cfg_data, port_info)
    if not ok or type(profile) ~= "table" then
        return device_profiles.resolve(nil, port_info.description, nil)
    end
    return profile, source
end

-- True while a sequence is actively driving lines (or prompting the user).
-- RUNNING/SETTLING drive pins; MANUAL drives none but is still "in flight"
-- until its countdown ends, which is what keeps sends blocked for its duration.
function Window:_reset_in_flight()
    if not self._reset_seq then
        return false
    end
    local st = self._reset_seq:state()
    return st == reset_sequencer.STATES.RUNNING or
           st == reset_sequencer.STATES.SETTLING or
           st == reset_sequencer.STATES.MANUAL
end

-- Create the dedicated reset timer once.  On the Linux review host uv.new_timer
-- may be absent; return false so start_reset_sequence can still surface the
-- plan without a timer.
function Window:_ensure_reset_timer()
    if self._reset_timer then
        return true
    end
    if not uv.new_timer then
        return false
    end
    local timer = uv.new_timer()
    local callback = function()
        local ok, err = pcall(self._reset_tick, self)
        if not ok then io.stderr:write("[uv reset] " .. tostring(err) .. "\n") end
    end
    jit.off(callback, true)
    self._reset_timer = timer
    self._reset_timer_callback = callback
    return true
end

-- Surface the manual prompt and its countdown on BOTH existing status channels
-- (the ImGui one is the shipped UI; the Win32 label is the fallback).  A
-- sequencer `note` (the auto -> manual downgrade under unsupported flow
-- control) is prefixed, so it can never be swallowed.
function Window:_report_reset_manual(seq)
    local left = math.max(0, math.floor(seq:remaining_ms(uv.now()) / 1000))
    local instr = seq.manual_instructions or "reset the board manually"
    local text = string.format("manual reset: %s (%ds)", instr, left)
    if seq.note then
        text = seq.note .. "; " .. text
    end
    self:_set_port_status(text)
    self:set_status_deferred(text)
end

-- Terminal path for every exit (done/failed/manual-finished/abort): report, stop
-- the timer, drop the sequence.
function Window:_finish_reset(final_status)
    if final_status then
        self:_set_port_status(final_status)
        self:set_status_deferred(final_status)
    end
    if self._reset_timer then
        self._reset_timer:stop()
    end
    self._reset_seq = nil
    self._reset_last_state = nil
end

-- The timer body.  Called at ~RESET_TICK_MS; does a bounded amount of work and
-- never sleeps.
function Window:_reset_tick()
    local seq = self._reset_seq
    if not seq then
        if self._reset_timer then self._reset_timer:stop() end
        return
    end
    local now = uv.now()
    local st = seq:step(now)
    if st == reset_sequencer.STATES.RUNNING then
        return
    end
    if st == reset_sequencer.STATES.MANUAL then
        if seq:remaining_ms(now) <= 0 then
            self:_finish_reset("reset: manual prompt finished")
        else
            self:_report_reset_manual(seq)
        end
        return
    end
    if st == reset_sequencer.STATES.SETTLING then
        self:set_status_deferred(string.format(
            "reset: settling (%d ms)", math.floor(seq:remaining_ms(now))))
        return
    end
    if st == reset_sequencer.STATES.FAILED then
        self:_finish_reset("reset failed: " .. tostring(seq.err))
    else
        self:_finish_reset("reset done")
    end
end

-- Public entry: resolve the selected port's profile and run its reset/ROM
-- sequence without blocking.  Returns false when there is no core session or a
-- sequence is already running.
function Window:start_reset_sequence()
    if not self.core then
        self:_set_port_status("reset: no core session")
        return false
    end
    if self:_reset_in_flight() then
        return false
    end
    -- A reset owns the bus: stop every paced sender first so nothing races the
    -- millisecond edges or lands on the handle as the device detaches.  This is
    -- the same "a batch sender must not survive a session teardown" rule close
    -- uses, applied to the reset trigger.  core_send's own interlock covers the
    -- one-shot and script paths for the whole duration.
    if self._sequence_timer then
        self:_stop_sequence("sequence stopped: reset")
    end
    if self._multi_timer then
        self._multi_timer:stop()
    end
    if self.imgui and self.imgui.send_auto then
        self.imgui.send_auto[0] = 0
    end
    if self.core and xcom.set_auto_template then
        xcom.set_auto_template(self.core, "", 0, xcom.send_text)
    end
    if self.imgui and self.imgui.multi_auto then
        self.imgui.multi_auto[0] = 0
    end
    local profile, source = self:_resolve_device_profile()
    self._reset_profile = profile
    -- Numeric 0/1 from the sequencer -> booleans for xcom.set_lines.
    local set_lines = function(dtr, rts)
        if not self.core or not xcom.set_lines then
            return -1
        end
        return xcom.set_lines(self.core, dtr ~= 0, rts ~= 0)
    end
    local seq = reset_sequencer.new(profile, set_lines, uv.now)
    self._reset_seq = seq
    seq:start()
    -- Profile-resolution visibility: which profile matched and by which key.
    local msg = string.format("reset %s (%s)", tostring(profile.id), tostring(source))
    if seq.note then
        msg = msg .. "; " .. seq.note
    end
    self:set_status_deferred(msg)
    self._reset_last_state = seq:state()
    if not self:_ensure_reset_timer() then
        -- No luv timer (not reachable when luv is present, but never leave the
        -- session wedged with an in-flight sequence that can never advance).
        self:_finish_reset("reset: timer unavailable")
        return true
    end
    self._reset_timer:start(RESET_TICK_MS, RESET_TICK_MS, self._reset_timer_callback)
    if seq:state() == reset_sequencer.STATES.MANUAL then
        self:_report_reset_manual(seq)
    end
    return true
end

-- Cancel an in-flight sequence (Close / exit).  A running sequence is left at
-- the safe resting level, never mid-pulse.
function Window:abort_reset_sequence(reason)
    local seq = self._reset_seq
    if not seq then
        return false
    end
    local st = seq:state()
    if (st == reset_sequencer.STATES.RUNNING or
        st == reset_sequencer.STATES.SETTLING) and self.core and xcom.set_lines then
        xcom.set_lines(self.core, false, false)
    end
    self:_finish_reset(reason or "reset aborted")
    return true
end

-- Recovery overlay (design-device-profiles step 5).  Derives the five overlay
-- flags on top of the UNCHANGED UI 6-state HSM (view_model) and the unchanged
-- core 5-state ABI.  `reconnecting` stays UI-owned; these flags are read-only
-- observability, never a state transition.  Every flag has a user exit:
--   port_gone      - reselect/Open, or the device reappears (presence clears it)
--   port_reenum    - automatic: reopen settles, or Close
--   port_ambiguous - manually reselect a port, or Close
--   link_silent    - receive data (idle anchor resets), or Close
--   tx_stalled     - the flow-hold counter stops rising, or Close
function Window:ui_state()
    local state = self.vm:ui_state()
    local recovering = state.reconnecting
    local candidates = self._reconnect_candidate_names or {}
    local n_candidates = #candidates

    -- Exactly one newly-appeared same-description port -> the adapter came back
    -- under a new COMx (USB re-enumeration).
    state.port_reenum = recovering and n_candidates == 1
    -- More than one candidate: never guess (see _resolve_reconnect_port); the
    -- user must reselect.  Consistent with the "do not adopt a pre-existing
    -- peer" guard: only newly-appeared ports are counted as candidates.
    state.port_ambiguous = recovering and n_candidates > 1
    -- The selected port is gone with no unique replacement: inside the grace
    -- window with nothing to follow, or faulted once the window elapsed.
    state.port_gone = (not state.port_present) and (recovering or state.faulted)
                      and not state.port_reenum and not state.port_ambiguous

    -- OPEN but no RX for the profile's silent_warn_ms.  Deliberately report
    -- only, never fault: killing a compliant idle link is worse than leaving it.
    local silent = false
    if state.state == self.vm.STATE_OPEN and self._silent_since then
        local warn = self._silent_warn_ms or LINE_SILENT_MS
        silent = (uv.now() - self._silent_since) >= warn
    end
    state.link_silent = silent

    -- Flow-control hold rose recently: TX is stalled, the port stays OPEN.
    state.tx_stalled = state.state == self.vm.STATE_OPEN and
        (self._flow_hold_active_until or 0) > uv.now()

    return state
end

-- Render every connection-dependent control from one HSM snapshot (mirrors
-- Python's MainWindow._render_ui_state).  params_enabled gates the serial
-- combos + DTR/RTS; open/close buttons follow can_open/can_close; send
-- controls follow send_enabled (exactly OPEN).
function Window:_render_ui_state()
    local state = self:ui_state()
    local conn = self.conn
    local params_ctls = { conn.port, conn.baud, conn.data, conn.parity,
                         conn.stop, conn.flow, conn.dtr_open, conn.rts_open }
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
    if was_connected and not state.connected then
        -- Session ended.  A batch sender cannot keep running against a closed
        -- core: every remaining step would silently fail while the UI advanced
        -- and finally claimed success.  Stopping here is a DELIBERATE decision
        -- of THIS tool -- no surveyed serial tool auto-cancels a periodic send
        -- on disconnect (COMTool's loop keeps spinning after sendData quietly
        -- returns) -- chosen because a false "sequence done" plus a status bar
        -- re-flashing errors is worse than stopping.  This is the FAULT edge;
        -- the Close paths share the same stop in core_close.
        if self._sequence_timer then
            self:_stop_sequence("sequence stopped: port closed")
        end
        if self._multi_timer then
            self._multi_timer:stop()
        end
        -- deliver the whole-line bridge's held partial (there is
        -- no next batch to complete it) and clear the ingress anchor so a
        -- reconnect's first batch opens a fresh segment rather than comparing
        -- against a stale pre-disconnect time.
        self:_flush_rx_lines(false)
        -- Charset pending is the OTHER half of the per-session display state:
        -- a DBCS lead byte (or UTF-16 surrogate/odd byte) torn at the session
        -- boundary is still held INSIDE charset.lua and would otherwise be
        -- prepended to session N+1's first bytes, garbling its opening
        -- characters.  FLUSH (not discard), mirroring _final_drain: the orphan
        -- bytes are emitted through charset.flush() and appended, so a torn
        -- character is VISIBLE as the code page default / raw byte rather than
        -- silently dropped -- the harness rejects silent loss.  No separate
        -- loss counter is needed: the bytes were already persisted by the
        -- raw-byte lane, so this is a display-conversion artifact, not data
        -- loss, and the append accounts for them in the view.
        if self._charset_active then
            local tail = charset.flush()
            if tail and #tail > 0 then
                self:_append_imgui_receive(tail)
            end
        end
        self._rx_ingress_ms = nil
        self._rx_segment_stamp_pending = false
        -- The next session's ingress clock is re-anchored from scratch (its
        -- monotonic base may differ), so drop the old mapping.
        self._rx_ts_mono_anchor = nil
        self._rx_ts_wall_anchor = nil
        self._rx_segment_ingress_ms = nil
    end
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
        -- Same visible-channel rule as every other status message: labels[3] is
        -- a hidden Win32 control under the ImGui dashboard, so a DLL-load
        -- failure there showed nothing (_set_port_status falls back to labels[3]
        -- in Win32 mode).
        self:_set_port_status(err or "xcom_core.dll unavailable")
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
        -- A script (re)load clears its hooks; flush the whole-line bridge
        -- through the OLD hooks first so a held partial line is never silently
        -- reinterpreted by the new script (design §2 force-flush condition).
        on_reload = function() self:_flush_rx_lines(false) end,
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
    -- 1 Hz housekeeping: script engine poll + optional mtime hot-reload.  (The
    -- held-partial idle flush lives in poll_display's 10 ms drain tick, not
    -- here; poll() itself is cheap, and the timer stays alive for the whole
    -- session doing nothing when the engine is idle.)
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
    -- Dedicated reset-sequencer timer (design step 4).  Created once here but
    -- only started while a sequence is in flight, so an idle session keeps its
    -- shortest luv deadline at the 250 ms status poll.
    self:_ensure_reset_timer()
    -- Device-change refresh: a one-shot, armed (and coalesced) by
    -- _on_device_nodes_changed from the WndProc.
    self._device_change_timer = uv.new_timer()
    local device_change_timer_callback = function()
        local ok, err = pcall(self._refresh_ports_after_change, self)
        if not ok then io.stderr:write("[uv device] " .. tostring(err) .. "\n") end
    end
    jit.off(device_change_timer_callback, true)
    self._device_change_timer_callback = device_change_timer_callback
    -- ~1 Hz backstop re-enumerate: catches a WM_DEVICECHANGE we never saw
    -- (modal loop, driver that does not broadcast).  Prior art polls at 1 Hz
    -- (Serial Studio) to ~200 ms (CoolTerm); 1 s is chosen because this is the
    -- fallback, not the primary signal, and a faster tick only burns
    -- enumeration + signature churn while the primary event still fires first.
    self._ports_backstop_timer = uv.new_timer()
    local ports_backstop_callback = function()
        local ok, err = pcall(self._poll_ports_backstop, self)
        if not ok then io.stderr:write("[uv ports] " .. tostring(err) .. "\n") end
    end
    jit.off(ports_backstop_callback, true)
    self._ports_backstop_callback = ports_backstop_callback
    self._ports_backstop_timer:start(1000, 1000, ports_backstop_callback)

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

        -- P1+P2 as one reusable unit.  The modal common-file dialogs run their
        -- own Win32 message loop and never return here while they are open, so
        -- the same pump has to be reachable from the dialog hook; see
        -- _ensure_ofn_hook for the failure it prevents.
        self:_pump_events()

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
                         self._multi_timer, self._sequence_timer,
                         self._reset_timer,
                         self._script_timer,
                         self._script_watch_timer, self._device_change_timer,
                         self._ports_backstop_timer }) do
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
    -- Same short, non-blocking budget as _imgui_close (see the note there).
    self:core_close()
end

function Window:on_btn_clear()
    -- Manual Clear: same view reset as the auto_clear threshold path (which
    -- deliberately skips the RICHEDIT fallback below).
    self:_clear_imgui_view()
    if self.recv and self.recv.clear then
        self.recv.clear(self.recv)
    end
end

-- Layers P1+P2 of the main loop, factored so the modal dialogs can run them
-- too (see _ensure_ofn_hook).  Deliberately NOT the whole loop: no Win32
-- message pump (the dialog is already pumping its own queue) and no render
-- (the dialog owns the interaction; a frame here would fight it for the paint).
--
-- No pcall here: every luv timer callback on this path is itself pcall-wrapped
-- (display drain, status poll, script watch) and each deferred job is wrapped
-- below, so nothing can raise out and strand the _pumping flag.
function Window:_pump_events()
    if self._pumping then
        return   -- the hook and the main loop must never nest
    end
    self._pumping = true
    -- P1: run due luv timers — this is what advances the 10 ms receive drain,
    -- and therefore also the auto-save log written from the drained text.
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
    self._pumping = false
end

-- Build (once per Window) and return the OFN_ENABLEHOOK callback installed on
-- the common-file dialogs.
--
-- Why this is not optional: GetSaveFileNameW / GetOpenFileNameW run their OWN
-- modal Win32 message loop on the UI thread.  run_message_loop is not iterated
-- while one is open, so the receive drain timer never fires and the drained
-- text stops being consumed.  Acquisition does NOT stop — the serial read
-- thread and the coact dispatcher are separate threads — so the Rx pool
-- (128 x 4 KiB) and the display lane (32 x 16 KiB) keep filling.  Past roughly
-- 11.6 s at the 921600 peak (~90 KiB/s) the read thread runs out of blocks and
-- bytes are lost; and because the auto-save log is written from the drained
-- text, those bytes are lost from the FILE too, not just from the view.
-- Pumping luv from inside the dialog's own message loop keeps the consumer
-- alive for as long as the dialog is up.
--
-- The callback is created once and cached on self: an FFI callback object must
-- outlive the call that uses it, and rebuilding one per dialog would leak a
-- callback slot each time.
function Window:_ensure_ofn_hook()
    if self._ofn_hook then
        return self._ofn_hook
    end
    local win = self
    local proc = function(hwnd, msg, wparam, lparam)
        -- An error escaping an FFI callback would propagate into the Win32
        -- modal loop with no Lua frame to catch it, so it is contained here.
        local ok, err = pcall(win._pump_events, win)
        if not ok then
            io.stderr:write("[ofn hook] " .. tostring(err) .. "\n")
        end
        return 0   -- documented "handled"; the dialog ignores it for CDN_*
    end
    jit.off(proc, true)
    self._ofn_hook = ffi.new("OFNHookProc", proc)
    return self._ofn_hook
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
    -- OFN_ENABLEHOOK + the hook below: the dialog runs its own modal message
    -- loop, so the hook is what keeps the receive drain (and the auto-save log
    -- written from it) running while the dialog is open — see _ensure_ofn_hook.
    -- OFN_EXPLORER is both the modern dialog and the mode the hook is written
    -- for.
    ofn.Flags = w.ofn.OFN_OVERWRITEPROMPT + w.ofn.OFN_PATHMUSTEXIST +
                w.ofn.OFN_EXPLORER + w.ofn.OFN_ENABLEHOOK
    ofn.hInstance = self.hinst
    ofn.lpfnHook = self:_ensure_ofn_hook()

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
                w.ofn.OFN_HIDEREADONLY + w.ofn.OFN_EXPLORER +
                w.ofn.OFN_ENABLEHOOK
    ofn.hInstance = self.hinst
    ofn.lpfnHook = self:_ensure_ofn_hook()

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
            self:_set_port_status("save failed: " ..
                                  (STATUS_TEXT[rc] or tostring(rc)))
            return
        end
        self._log_active = true
        self._log_open_path = path

        -- Walk the buffer in block-sized steps and COUNT what the core actually
        -- accepted.  append() refuses a block bigger than kFileBlockBytes whole
        -- (no partial accept) and can also reject on a saturated pool, so the
        -- old single append + unconditional "saved" claimed success for a file
        -- that was silently missing data.  Accepted here means "queued"; the
        -- subsequent flush is what durably writes it.
        local total = #data
        local accepted = 0
        local append_err = nil
        local base = ffi.cast("const uint8_t*", data)
        while accepted < total do
            local n = total - accepted
            if n > LOG_APPEND_BLOCK_BYTES then
                n = LOG_APPEND_BLOCK_BYTES
            end
            local arc = tonumber(xcom.log_append(self.core, base + accepted, n))
            if arc ~= xcom.ok then
                append_err = arc
                break
            end
            accepted = accepted + n
        end

        local flush_rc = tonumber(xcom.log_flush(self.core, 2000))
        local closed_ok = self:_log_close_with_retry()

        if append_err == nil and flush_rc == xcom.ok and closed_ok then
            self:_set_port_status("saved: " .. path)
            self.cfg.save_path = path
        else
            -- Name the failure and the byte count; never round a partial or
            -- failed save up to "saved".  The accepted count is only "written"
            -- once flush confirms it reached the file.
            local why
            if append_err ~= nil then
                why = "append " .. (STATUS_TEXT[append_err] or tostring(append_err))
            elseif flush_rc ~= xcom.ok then
                why = "flush " .. (STATUS_TEXT[flush_rc] or tostring(flush_rc))
            else
                why = "log close failed"
            end
            local amount
            if accepted == 0 then
                amount = string.format("nothing written (%d bytes requested)",
                                       total)
            elseif flush_rc == xcom.ok then
                amount = string.format("wrote %d of %d bytes", accepted, total)
            else
                amount = string.format(
                    "accepted %d of %d bytes, not confirmed on disk",
                    accepted, total)
            end
            local prefix = (accepted > 0) and "save incomplete: " or "save failed: "
            self:_set_port_status(prefix .. path ..
                                  " (" .. why .. "; " .. amount .. ")")
        end
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

-- ---------------------------------------------------------------------------
-- Native port combo: key seam + refresh.
--
-- Which identity does the port combo remember across a refresh / device change?
-- Today xcom_list_ports exposes ONLY { name, description, busy }
-- (xcom_core/include/xcom/xcom.h:230; enumeration in
-- core/io/serial_backend_win.cpp:721 copies the COMx name and the
-- HARDWARE\DEVICEMAP\SERIALCOMM value name).  `description` is a device-map
-- key such as "\Device\VCP0" -- NOT a USB instance ID / VID / PID / serial
-- number, and there is no SetupAPI path in xcom_core (no SetupDi symbols).
-- So the only stable handle available without new C++ work is the COM name.
--
-- IF prior-art review decides the right key is a stable device identity (the
-- same physical device returning as a different COMx after re-enumeration),
-- this is the ONE place to change: give port_key() the richer key and
-- find_key_index() a matching lookup.  Everything else consumes
-- port_combo_entries()/find_key_index() and is key-agnostic.  (The reconnect
-- grace path already follows a name change by registry description --
-- Window:_resolve_reconnect_port -- with the same "ambiguous -> do not guess"
-- rule.)
port_key = function(p)
    return p.name
end

-- Build {items, keys}: composed display labels and the parallel BARE keys, in
-- the same order.  The label is what the user reads; the key is what the
-- selection is preserved by, so a "(busy)" suffix or description change can
-- never move the selection (the old exact-text re-select compared the bare
-- name against the composed label and always failed).
port_combo_entries = function(ports)
    local items, keys = {}, {}
    for _, p in ipairs(ports or {}) do
        local label = p.name
        if p.description and p.description ~= "" then
            label = label .. "  " .. p.description
        end
        if p.busy then label = label .. "  (busy)" end
        items[#items + 1] = label
        keys[#keys + 1] = port_key(p)
    end
    return items, keys
end

-- 0-based combo index of `want` in the key array, or -1 when absent/empty.
find_key_index = function(keys, want)
    if not want or want == "" then
        return -1
    end
    for i = 1, #keys do
        if keys[i] == want then
            return i - 1
        end
    end
    return -1
end

-- Stable signature of an enumeration's NAME set, for the ~1 Hz backstop poll
-- to detect a change it missed without re-rendering an unchanged list.  Busy
-- flags are deliberately excluded: occupancy flapping must not churn the list.
port_list_signature = function(ports)
    local names = {}
    for _, p in ipairs(ports or {}) do
        names[#names + 1] = p.name
    end
    table.sort(names)
    return table.concat(names, "\1")
end

-- Unique enumerated port whose registry description matches `desc`, or nil.
-- Ambiguity (0 or >1 match) is deliberately NO match: the SERIALCOMM value
-- name is instance-stable but two identical adapters without a serial number
-- share it, and guessing would open the wrong device.  Used only to ANNOUNCE a
-- probable renumbering; the selection is never switched silently.
unique_port_by_desc = function(ports, desc)
    if not desc or desc == "" then
        return nil
    end
    local found, count = nil, 0
    for _, p in ipairs(ports or {}) do
        if p.description and p.description ~= "" and p.description == desc then
            found = p.name
            count = count + 1
        end
    end
    if count == 1 then
        return found
    end
    return nil
end

-- Occupancy-probe gate shared by the manual and device-change refreshes.
-- XCOM_LIST_PORTS_PROBE_BUSY makes enumeration CreateFile(share=0) EVERY
-- listed port; a plain open delivers an open IRP and some USB-UART drivers
-- assert DTR on open, which can reset a board wired for auto-reset (xcom.h:246
-- note).  While a session is live/transitional, or inside the reconnect grace
-- window, one of those boards is the one we are talking to or trying to
-- reopen, so never probe then: names are still enumerated (cheap, no I/O) with
-- busy left 0.  An occupied port still reports its cause when the open fails.
function Window:_port_probe_flag()
    if self.vm then
        if self.vm:ui_state().super_state ~= view_model.SUPER_OFFLINE then
            return false
        end
        if self.vm:recovering() then
            return false
        end
    end
    return self._probe_port_busy == true
end

-- Report a port-list status line to whichever UI is active.
function Window:_set_port_status(text)
    if self.imgui then
        self.imgui:set_status(text)
    elseif self.status and self.status.labels and self.status.labels[3] then
        c.set_text(self.status.labels[3], text)
    end
end

-- Distinguish "no ports" from "enumeration failed" so the user is not left
-- guessing at an empty combo.
function Window:_report_empty_ports(enum_err)
    local msg
    if enum_err ~= nil then
        msg = (xcom.describe_enum_error and xcom.describe_enum_error(enum_err))
              or ("port enumeration failed (error " .. tostring(enum_err) .. ")")
    else
        msg = "no COM ports detected"
    end
    self:_set_port_status(msg)
end

-- Feed presence into the HSM as an ORTHOGONAL input (never a port state, never
-- a forced close) and re-render the interlock once on a change.  This is what
-- makes Open refuse an absent port; close/send stay purely state-derived.
function Window:_set_port_present(present)
    self._port_present = present and true or false
    if self.vm and self.vm:set_port_present(self._port_present) then
        self:_render_ui_state()
    end
end

-- Rebuild the native port combo from an enumeration (optionally pre-fetched),
-- preserving the user's LIVE selection by BARE KEY.  Never issues an open or
-- close and never touches the state machine; the only HSM input it sets is
-- presence.  The chosen name stays SELECTED even when absent, on an explicit
-- "(not present)" row -- the prior-art rule: never move the user to index 0,
-- and never silently fall back to another device.
function Window:_reload_port_combo(ports, enum_err)
    local ctl = self.conn and self.conn.port
    if not ctl then return end
    -- Capture the live selection BEFORE the reset: map the current combo index
    -- back through the key array stored at the last rebuild.  The displayed
    -- text is composed, so the index+key array (not the text) is the record of
    -- which bare port is selected; reading it here also picks up a pick the
    -- user made in the dropdown since the last refresh (there is no
    -- CBN_SELCHANGE handler, and none is needed with the key array).
    local idx = c.combo_cur(ctl)
    if self._port_keys and idx >= 0 and self._port_keys[idx + 1] then
        self._port_want = self._port_keys[idx + 1]
    end
    if ports == nil then
        ports, enum_err = xcom.list_ports({ probe = self:_port_probe_flag() })
    end
    ports = ports or {}
    local want = self._port_want
    local items, keys = port_combo_entries(ports)
    local sel = find_key_index(keys, want)
    local present = sel >= 0
    if not present and want and want ~= "" then
        -- Want absent (unplugged / re-enumerated away): keep the NAME selected
        -- but mark it explicitly.  This is the "(not present)" row -- an
        -- index-0 fallback here is the documented wrong-device defect.
        items[#items + 1] = want .. "  (not present)"
        keys[#keys + 1] = want
        sel = #keys - 1
    end
    if sel < 0 then
        -- No selection at all (nothing wanted yet, or an empty enumeration):
        -- leave the list unselected rather than defaulting to index 0.
        c.combo_set(ctl, items, -1)
    else
        c.combo_set(ctl, items, sel)
    end
    self._port_keys = keys
    -- Remember the wanted port's description while it is present, so a later
    -- renumbering can be recognised (below) and in the reconnect path.
    if present then
        for _, p in ipairs(ports) do
            if p.name == want then
                self._port_desc = (p.description ~= "" and p.description) or nil
                break
            end
        end
    end
    self:_set_port_present(present)
    if not present and want and want ~= "" then
        -- Announce a probable renumbering instead of switching; description is
        -- instance-stable but ambiguous across identical adapters (see
        -- unique_port_by_desc), so this is a hint only.
        local alt = unique_port_by_desc(ports, self._port_desc)
        if alt then
            self:_set_port_status(string.format(
                "port %s not present; %s may be the same device - select it",
                want, alt))
        else
            self:_set_port_status(string.format(
                "port %s not present - select a port", want))
        end
    elseif #ports == 0 then
        self:_report_empty_ports(enum_err)
    elseif not present then
        self:_set_port_status("select a port")
    end
end

-- Apply one enumeration to whichever UI is live: the ImGui candidate list
-- (selection lives in its own buffer; set_ports never writes it) and/or the
-- native fallback combo.  Never touches the enable table or issues I/O.
function Window:_apply_ports(ports, enum_err)
    self._ports_signature = port_list_signature(ports)
    if self.imgui then
        self:_refresh_imgui_ports(ports, enum_err)
        -- Presence for the ImGui selection: its name buffer is authoritative
        -- (native/xcom_imgui_bridge.cpp:1882 -- no index-0 fallback there).
        local want = self._imgui_port
        if (not want or want == "") and self.imgui.port_name then
            want = self.imgui:port_name()
        end
        self:_remember_imgui_desc(ports, want)
        local present = false
        for _, p in ipairs(ports or {}) do
            if p.name == want then
                present = true
                break
            end
        end
        self:_set_port_present(present)
        if not present and want and want ~= "" then
            local alt = unique_port_by_desc(ports, self._port_desc)
            if alt then
                self.imgui:set_status(string.format(
                    "port %s not present; %s may be the same device - select it",
                    want, alt))
            else
                self.imgui:set_status(string.format(
                    "port %s not present - select a port", want))
            end
        end
    elseif self.conn and self.conn.port then
        self:_reload_port_combo(ports, enum_err)
    end
    self:request_frame()
end

-- Cache the selected ImGui port's description for the renumber hint.
function Window:_remember_imgui_desc(ports, want)
    if not want or want == "" then return end
    for _, p in ipairs(ports or {}) do
        if p.name == want then
            self._port_desc = (p.description ~= "" and p.description) or nil
            return
        end
    end
end

-- Manual Refresh button (native fallback path).  Only the list + selection
-- change; no device I/O beyond enumeration.
function Window:on_btn_refresh()
    local ports, enum_err = xcom.list_ports({ probe = self:_port_probe_flag() })
    self:_apply_ports(ports, enum_err)
end

-- Test seams for the pure key/compose logic (no host needed).
M._port_key = port_key
M._port_combo_entries = port_combo_entries
M._find_key_index = find_key_index
M._port_list_signature = port_list_signature
M._unique_port_by_desc = unique_port_by_desc

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
    local failed = 0
    for i, e in ipairs(sp.multi.entries) do
        if sp.entry_enabled(i - 1) then
            local text = sp.entry_text(i - 1)
            local payload = xcom.build_send_payload(
                text, c.checkbox_checked(sp.multi.hex),
                c.checkbox_checked(sp.multi.crlf))
            if payload then
                -- Count refused writes instead of silently treating them as sent.
                if not self:core_send(payload, xcom.send_text) then
                    failed = failed + 1
                end
            end
        end
    end
    if failed > 0 then
        self:set_status_deferred("multi: " .. failed .. " slot(s) not sent")
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
