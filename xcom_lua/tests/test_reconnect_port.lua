-- test_reconnect_port.lua - offline tests for the reconnect port-resolution path
-- (Window:_port_description / _resolve_reconnect_port / _drive_reconnect).
--
-- Bug being pinned: the reconnect grace window re-opened the OLD port name even
-- after a USB device re-enumerated to a different COMx, so recovery could never
-- succeed and the window always timed out to FAULT.  The fix re-enumerates every
-- attempt and follows the adapter to a new name when exactly one enumerated port
-- carries the original's registry description; otherwise it keeps the old
-- original-name retry unchanged and just tells the user the port vanished
-- instead of silently counting down.
--
-- Sections M/N reuse the same window harness for two adjacent guards:
--   M) Window:core_close / on_close must surface a close timeout (P1-1).
--   N) Window:_serial_config must never forward 8 data bits + 1.5 stop bits,
--      a format the core rejects (§6 #4).
--
-- Runs on the Linux review host: luv is stubbed via package.preload and
-- win32.lua's DLL load() is patched off (same harness as
-- tests/test_multi_send.lua).  xcom_ffi's list_ports/open_async/close/
-- take_open_result are replaced with recording stubs; no DLL is touched.
--
-- Usage: cd xcom_lua && luajit tests/test_reconnect_port.lua

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

local fake_now = 1000000
package.preload["luv"] = function()
    return { now = function() return fake_now end }
end
local uv = require("luv")
uv.now = function() return fake_now end

local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

-- Preload a minimal xcom_ffi stub.  window.lua only needs the reconnection
-- symbols here, and stubbing isolates this pure-logic test from the real
-- module's DLL/layout checks (which another agent may be editing).
local xcom_stub = {
    ok = 0, err_busy = 4, err_timeout = -7, err_full = -5,
    port_closed = 0, port_opening = 1, port_open = 2,
    port_closing = 3, port_fault = 4,
    port_text = {},
    send_text = 1,
    list_ports = function() return {} end,
    close = function() return 0 end,
    open_async = function() return 0 end,
    take_open_result = function() return 0 end,
}
-- NOTE: this fallback makes any constant the stub omits look like a FUNCTION,
-- not nil.  Production constants therefore have to be listed above or a
-- comparison such as `rc == xcom.err_full` silently never matches.  err_full is
-- listed for exactly that reason.
setmetatable(xcom_stub, {
    __index = function() return function() return 0 end end,
})
package.preload["xcom_ffi"] = function() return xcom_stub end

local window_mod = require("window")
local view_model = require("view_model")
local xcom = xcom_stub

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%q want=%q)", label, tostring(got), tostring(want)),
       got == want)
end

-- Mutable port-list backing xcom.list_ports().
local PORTS = {}
xcom.list_ports = function() return PORTS end

-- Recording xcom stubs.  open_async must be queued (xcom.ok) so _drive_reconnect
-- arms its pending flag exactly as against the real core.
local last_open_port = nil
xcom.close = function() return xcom.ok end
xcom.open_async = function(_, port) last_open_port = port; return xcom.ok end
xcom.take_open_result = function() return xcom.ok end

local function new_fake_imgui(status_log)
    local b = { status_log = status_log, set_ports_calls = 0,
                auto_save = { 0 } }
    function b:set_status(s) status_log[#status_log + 1] = s end
    function b:serial_config() return 115200, 8, 0, 0, false, false end
    function b:set_ports(_ports) self.set_ports_calls = self.set_ports_calls + 1 end
    return b
end

local function new_win(ports, desc, port_name)
    PORTS = ports
    last_open_port = nil
    local cfg = {
        window = { x = 0, y = 0, w = 920, h = 650 },
        port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
        parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
        receive_hex = false, timestamp = false, pause_display = false,
        auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
        auto_save = false, save_path = "", always_on_top = false,
        send_hex = false, send_crlf = false, autosend_period_ms = 0,
        quick_pages = { { text = {}, enabled = {} } },
        quick = { text = {}, enabled = {} },
        script_enabled = {}, script_auto_reload = false,
        script_autorun_console = false, baud_custom = 0, multi_gap_ms = 100,
        charset = "ASCII", frame_gap_ms = 0, tx_echo = false,
    }
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.conn = nil                 -- imgui mode: no native combo to update
    win.core = true
    win.vm = view_model.new()
    win.vm:enter_reconnecting(1)
    win._status_log = {}
    win.imgui = new_fake_imgui(win._status_log)
    win._imgui_port = port_name
    win._reconnect_port_desc = desc
    win._reconnect_deadline = fake_now + view_model.RECONNECT_GRACE_MS
    win._reconnect_attempt = 0
    win._reconnect_pending = false
    win._reconnect_phase = "open"
    return win
end

-- ===========================================================================
-- A) _port_description: registry description lookup, nil when gone/blank
-- ===========================================================================
do
    local win = new_win({ { name = "COM3", description = "USB-SERIAL CH340" } },
                        nil, "COM3")
    eq("A1 description found", win:_port_description("COM3"), "USB-SERIAL CH340")
    eq("A2 missing name is nil", win:_port_description("COM9"), nil)
    eq("A3 empty name is nil", win:_port_description(""), nil)
    eq("A4 nil name is nil", win:_port_description(nil), nil)

    local blank = new_win({ { name = "COM3", description = "" } }, nil, "COM3")
    eq("A5 blank description is nil", blank:_port_description("COM3"), nil)
end

-- ===========================================================================
-- B) _resolve_reconnect_port: name/description matching contract
-- ===========================================================================
do
    -- B1 original still present: keep it, no description needed.
    local win = new_win({ { name = "COM3", description = "CH340" } }, nil, "COM3")
    local t, m = win:_resolve_reconnect_port("COM3", nil)
    eq("B1 target is original", t, "COM3")
    eq("B1 matched", m, true)

    -- B2 original gone, exactly one new port carries the description.
    win = new_win({ { name = "COM7", description = "CH340" } }, "CH340", "COM3")
    t, m = win:_resolve_reconnect_port("COM3", "CH340")
    eq("B2 target is re-enumerated name", t, "COM7")
    eq("B2 matched", m, true)

    -- B3 original gone, no description match -> no reliable target.
    win = new_win({ { name = "COM7", description = "Other" } }, "CH340", "COM3")
    t, m = win:_resolve_reconnect_port("COM3", "CH340")
    eq("B3 target falls back to original", t, "COM3")
    eq("B3 not matched", m, false)

    -- B4 ambiguous: two ports share the description -> do not guess.
    win = new_win({ { name = "COM7", description = "CH340" },
                    { name = "COM8", description = "CH340" } }, "CH340", "COM3")
    t, m = win:_resolve_reconnect_port("COM3", "CH340")
    eq("B4 ambiguous not matched", m, false)

    -- B5 nothing enumerated -> no target.
    win = new_win({}, "CH340", "COM3")
    t, m = win:_resolve_reconnect_port("COM3", "CH340")
    eq("B5 empty list not matched", m, false)

    -- B6 no remembered description -> a same-named-looking port cannot match.
    win = new_win({ { name = "COM7", description = "CH340" } }, nil, "COM3")
    t, m = win:_resolve_reconnect_port("COM3", nil)
    eq("B6 no desc not matched", m, false)

    -- B7 empty original never matches (no wildcard open).
    win = new_win({ { name = "COM7", description = "CH340" } }, "CH340", "")
    t, m = win:_resolve_reconnect_port("", "CH340")
    eq("B7 empty original not matched", m, false)
end

-- ===========================================================================
-- C) _drive_reconnect: same port still present -> reopen the original name
-- ===========================================================================
do
    local win = new_win({ { name = "COM3", description = "CH340" } }, "CH340", "COM3")
    local done = win:_drive_reconnect(1)
    eq("C1 not timed out", done, false)
    eq("C2 opened original port", last_open_port, "COM3")
    eq("C3 port unchanged", win._imgui_port, "COM3")
end

-- ===========================================================================
-- D) _drive_reconnect: device re-enumerated COM3 -> COM7 -> opens COM7
-- ===========================================================================
do
    local win = new_win({ { name = "COM7", description = "CH340" } }, "CH340", "COM3")
    -- Adoption re-arms the reset->open phase machine, so the new port is opened
    -- on the next attempt tick (as in production, one poll later).
    win:_drive_reconnect(1)
    eq("D0 first tick resets the core, no open yet", last_open_port, nil)
    win:_drive_reconnect(1)
    eq("D1 opened the re-enumerated port", last_open_port, "COM7")
    eq("D2 imgui port adopted", win._imgui_port, "COM7")
    local adopted = false
    for _, s in ipairs(win._status_log) do
        if s:find("COM7", 1, true) then adopted = true end
    end
    ok("D3 status names the new port", adopted)
end

-- ===========================================================================
-- E) _drive_reconnect: port vanished, no match -> informative status; the
--    original-name retry is preserved (fail safe to pre-change behaviour)
-- ===========================================================================
do
    local win = new_win({ { name = "COM9", description = "Unrelated" } }, "CH340", "COM3")
    win:_drive_reconnect(1)
    eq("E1 still retries the original name", last_open_port, "COM3")
    local informed = false
    for _, s in ipairs(win._status_log) do
        if s:find("端口已消失", 1, true) then informed = true end
    end
    ok("E2 status tells the user the port vanished", informed)
    eq("E3 original name kept", win._imgui_port, "COM3")
end

-- ===========================================================================
-- F) _drive_reconnect: ambiguous description -> never guess another device;
--    falls back to the original-name retry
-- ===========================================================================
do
    local win = new_win({ { name = "COM7", description = "CH340" },
                          { name = "COM8", description = "CH340" } }, "CH340", "COM3")
    win:_drive_reconnect(1)
    eq("F1 not switched to an ambiguous match", last_open_port, "COM3")
end

-- ===========================================================================
-- G) _drive_reconnect: window elapsed -> FAULT, no open
-- ===========================================================================
do
    local win = new_win({ { name = "COM3", description = "CH340" } }, "CH340", "COM3")
    win._reconnect_deadline = fake_now - 1
    local done = win:_drive_reconnect(1)
    eq("G1 signals timeout to caller", done, true)
    eq("G2 no open on timeout", last_open_port, nil)
    eq("G3 deadline cleared", win._reconnect_deadline, nil)
end

-- ===========================================================================
-- H) F1 regression: a FAILED open must not arm the reconnect grace window.
--    The core now publishes CLOSED (same generation) when an open attempt never
--    established a session, and take_open_result carries the recorded native
--    failure code.  The mirror must land on CLOSED, show the real cause, and NOT
--    enter the 8 s close/open reconnect loop.  Chosen here (not test_view_model)
--    because only this harness drives the real Window:poll_status grace-entry
--    condition at window.lua ("port_fault and was_open"); test_view_model has
--    no Window/poll_status path.
-- ===========================================================================
do
    local win = new_win({ { name = "COM3", description = "CH340" } }, "CH340", "COM3")
    win.vm = view_model.new()              -- fresh mirror, generation 0
    ok("H0 open intent arms OPENING", win.vm:intent_open())
    eq("H0 mirror is OPENING", win.vm.hsm.state, view_model.STATE_OPENING)

    local FAIL_CODE = 5                    -- ERROR_ACCESS_DENIED (busy / denied)
    local snap = {
        port_state = 0, generation = 0, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0,
        rx_backpressure_events = 0, framing_errors = 0, parity_errors = 0,
        break_events = 0, display_paused_bytes = 0, rx_loss_offset = 0,
        rx_sequence = 0,
    }
    local saved = { xcom.get_snapshot, xcom.take_error,
                    xcom.take_open_result, xcom.describe_open_error }
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end
    xcom.take_open_result = function() return FAIL_CODE end
    xcom.describe_open_error = function(code)
        return (code == FAIL_CODE) and "端口被其他程序占用或权限不足" or nil
    end
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end

    win:poll_status()

    rw.user32 = saved_user32
    xcom.get_snapshot, xcom.take_error, xcom.take_open_result,
        xcom.describe_open_error = saved[1], saved[2], saved[3], saved[4]

    eq("H1 failed open lands CLOSED, not RECONNECTING",
       win.vm.hsm.state, view_model.STATE_CLOSED)
    eq("H2 no grace window was armed", win._reconnect_deadline, nil)
    ok("H3 reopen is still allowed after a failed open", win.vm.hsm:can_open())
    local log = table.concat(win._status_log, "\n")
    ok("H4 the failure is surfaced as an open failure",
       log:find("Open failed", 1, true) ~= nil)
    ok("H5 the real native cause is shown, not just a code",
       log:find("占用", 1, true) ~= nil)
end

-- ===========================================================================
-- I) F2 regression: the CLOSING watchdog must not force FAULT while the core
--    itself still reports CLOSING.  owner_close runs stop_and_join() on the
--    writer thread bounded by a 60 s write timeout, so a slow disk legitimately
--    keeps the CORE in CLOSING past the 5 s UI deadline.  Faulting then made the
--    next Open read the still-CLOSING core and return BUSY.
-- ===========================================================================
do
    local win = new_win({ { name = "COM3", description = "CH340" } }, "CH340", "COM3")
    win.vm = view_model.new()
    win.vm:intent_open()
    win.vm:on_port_state(2, 1)             -- OPEN, gen 1
    ok("I0 close intent arms CLOSING", win.vm:intent_close())
    eq("I0 mirror is CLOSING", win.vm.hsm.state, view_model.STATE_CLOSING)

    local snap = {
        port_state = 3, generation = 1, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0,
        rx_backpressure_events = 0, framing_errors = 0, parity_errors = 0,
        break_events = 0, display_paused_bytes = 0, rx_loss_offset = 0,
        rx_sequence = 0,
    }
    local saved = { xcom.get_snapshot, xcom.take_error }
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end
    win.port_state = 3                     -- last snapshot: core still closing
    win._closing_deadline = fake_now - 1   -- UI deadline long past

    win:poll_status()

    eq("I1 still CLOSING while the core is genuinely closing",
       win.vm.hsm.state, view_model.STATE_CLOSING)
    ok("I2 no false 'Close timed out'",
       table.concat(win._status_log, "\n"):find("Close timed out", 1, true) == nil)

    -- Negative: once the core is no longer CLOSING the watchdog still fires, so
    -- the frozen-interlock recovery path is preserved.
    snap.port_state = 4                    -- core FAULT
    win.port_state = 4
    win._closing_deadline = fake_now - 1
    win:poll_status()
    ok("I3 watchdog still fires when the core is not closing",
       table.concat(win._status_log, "\n"):find("Close timed out", 1, true) ~= nil)
    eq("I4 watchdog restored the manual FAULT route",
       win.vm.hsm.state, view_model.STATE_FAULT)

    rw.user32 = saved_user32
    xcom.get_snapshot, xcom.take_error = saved[1], saved[2]
end

-- ===========================================================================
-- J) Defect: a reconnect silently turned auto-save OFF and showed a false
--    error.  The log SURVIVES a disconnect (only an explicit close tears it
--    down; the core's kCloseCommit does not touch the LogWriter), so the
--    OFFLINE -> ONLINE edge re-issuing log_open met XCOM_ERR_BUSY, which the
--    old else branch misread as failure -- flipping the persisted setting off.
-- ===========================================================================
do
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })

    local win = new_win({}, "CH340", "COM3")
    win.conn = {}                       -- the real _render_ui_state indexes conn
    win.cfg.save_path = "C:/logs/x.log"
    win.status = { labels = { {}, {}, {}, {} } }
    win._sync_imgui_autosend = function() end
    win._sync_imgui_multi_auto = function() end
    win.vm = view_model.new()
    win.vm:intent_open()
    win.vm:on_port_state(2, 1)          -- OPEN gen 1 => connected
    win.connected = true
    win._log_active = true
    win._log_open_path = "C:/logs/x.log"
    win.imgui.auto_save[0] = 1

    local opens = 0
    local saved_open = xcom.log_open
    xcom.log_open = function() opens = opens + 1; return xcom.err_busy end

    win.vm:on_port_state(0, 2)          -- disconnect: CLOSED gen 2
    win:_render_ui_state()
    ok("J1 disconnect keeps the log open", win._log_active == true)

    win.vm:intent_open()
    win.vm:on_port_state(2, 3)          -- reconnect: OPEN gen 3
    win:_render_ui_state()

    xcom.log_open = saved_open
    eq("J2 reconnect never re-opened the log", opens, 0)
    eq("J3 auto-save stayed on", win.imgui.auto_save[0], 1)
    ok("J4 log mirror still active", win._log_active == true)
    ok("J5 no false 'cannot open'", (win.status.labels[3]._last_text or "")
        :find("cannot open", 1, true) == nil)
    eq("J6 tracked path unchanged", win._log_open_path, "C:/logs/x.log")

    -- J7-J9 legitimate case: a NEW path while open must still reopen.
    win.cfg.save_path = "C:/logs/y.log"
    local opened_paths, closes = {}, 0
    local saved_close = xcom.log_close
    xcom.log_close = function() closes = closes + 1; return xcom.ok end
    xcom.log_open = function(_, p) opened_paths[#opened_paths + 1] = p; return xcom.ok end
    win:_sync_imgui_autosave()
    xcom.log_open, xcom.log_close = saved_open, saved_close
    eq("J7 old log closed once", closes, 1)
    eq("J8 new path reopened", opened_paths[1], "C:/logs/y.log")
    eq("J9 tracked path follows the new file", win._log_open_path, "C:/logs/y.log")

    -- J10/J11 legitimate case: a genuinely failed open still reports + disables.
    win._log_active = false
    win._log_open_path = nil
    win.imgui.auto_save[0] = 1
    win.cfg.save_path = "C:/logs/z.log"
    xcom.log_open = function() return 5 end   -- a real native error code
    win:_sync_imgui_autosave()
    xcom.log_open = saved_open
    eq("J10 failed open turns auto-save back off", win.imgui.auto_save[0], 0)
    -- The report must reach a channel the SHIPPING ImGui UI can actually show.
    -- The hidden Win32 label (status.labels[3]) is not that channel, so this
    -- asserts the ImGui status log, which is where _set_port_status routes it.
    local reported = false
    for _, text in ipairs(win._status_log) do
        if type(text) == "string" and
           text:find("cannot open C:/logs/z.log", 1, true) then
            reported = true
            break
        end
    end
    ok("J11 failed open is reported", reported)

    rw.user32 = saved_user32
end

-- ===========================================================================
-- K) Defect: the "[XCOM] reconnected" separator was written only to the
--    viewport, while the log spans sessions and showed no boundary.  The
--    separator must reach the log too, in the TX-echo synthetic-write form
--    (the raw-byte lane carries RX only, so this is not a double write).
-- ===========================================================================
do
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })

    local win = new_win({}, "CH340", "COM3")
    win.conn = {}
    win.cfg.port = "COM3"
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end     -- isolate the separator branch
    win.vm = view_model.new()
    win.vm:intent_open()
    win.vm:on_port_state(2, 1)                -- establish OPEN gen 1
    win.vm:enter_reconnecting(1)              -- fault edge -> grace window
    win._reconnect_deadline = fake_now + view_model.RECONNECT_GRACE_MS
    win._reconnect_phase = "open"
    win._reconnect_pending = true             -- in-flight probe; no new open
    win._log_active = true
    win._log_open_path = "C:/logs/x.log"

    local appended = {}
    local orig_append = win._append_imgui_receive
    win._append_imgui_receive = function(self, text)
        appended[#appended + 1] = text
        return orig_append(self, text)
    end
    local logged = {}
    local saved_append = xcom.log_append
    xcom.log_append = function(_, text) logged[#logged + 1] = text; return xcom.ok end

    local saved = { xcom.get_snapshot, xcom.take_error }
    local snap = {
        port_state = 2, generation = 2, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0,
        rx_backpressure_events = 0, framing_errors = 0, parity_errors = 0,
        break_events = 0, display_paused_bytes = 0, rx_loss_offset = 0,
        rx_sequence = 0,
    }
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end

    win:poll_status()

    xcom.get_snapshot, xcom.take_error, xcom.log_append = saved[1], saved[2], saved_append
    rw.user32 = saved_user32

    local view_sep = table.concat(appended)
    ok("K1 viewport got the reconnect separator",
       view_sep:find("[XCOM] reconnected", 1, true) ~= nil)
    eq("K2 log got the identical separator", logged[1], view_sep)
end

-- ===========================================================================
-- L) Defect: the per-generation loss baseline swallowed the outgoing
--    session's final losses.  The close-boundary unowned_drop increments
--    save_rejected_bytes while the core is CLOSING, before kCloseCommit bumps
--    the generation, so the increment landed between the last poll of the old
--    generation and the first poll of the new one and was folded into the
--    fresh baseline.  The residual must be carried so a real loss banners.
-- ===========================================================================
do
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })

    local win = new_win({}, "CH340", "COM3")
    win.conn = {}
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end
    win.vm = view_model.new()

    local snap = {
        port_state = 2, generation = 1, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 100, overrun_errors = 0,
        rx_backpressure_events = 0, framing_errors = 0, parity_errors = 0,
        break_events = 0, display_paused_bytes = 0, rx_loss_offset = 0,
        rx_sequence = 0,
    }
    local saved = { xcom.get_snapshot, xcom.take_error }
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end

    win:poll_status()                       -- gen 1: baseline observed
    ok("L1 no loss banner on the healthy session", win._loss_banner == nil)
    eq("L2 baseline is the observed counter", win._loss_base_log, 100)

    -- Close boundary: the final unowned_drop lands (100 -> 150) and the
    -- generation advances before the next poll looks again.
    snap.port_state = 0                     -- CLOSED (close committed)
    snap.generation = 2
    snap.save_rejected_bytes = 150
    win:poll_status()

    xcom.get_snapshot, xcom.take_error = saved[1], saved[2]
    rw.user32 = saved_user32

    eq("L3 the final 50 B are not swallowed", win._loss_seen, 50)
    ok("L4 a real final loss still banners", win._loss_banner ~= nil and
        win._loss_banner:find("50 B", 1, true) ~= nil)
    ok("L5 the banner is surfaced to the UI",
       (win._status_dirty or ""):find("DATA LOSS", 1, true) ~= nil)
end

-- ===========================================================================
-- M) P1-1: xcom_close's status must not be discarded.  A teardown timeout has
--    to reach the visible status channel (imgui:set_status) instead of
--    vanishing, on both the Close button and the exit path.
-- ===========================================================================
do
    local function open_win()
        local win = new_win({}, nil, "COM3")
        win.vm = view_model.new()
        win.vm:intent_open()
        win.vm:on_port_state(2, 1)          -- OPEN, gen 1
        win.core = true
        win._render_ui_state = function() end
        win.poll_status = function() end       -- isolate the close-status handling
        return win
    end

    local saved_close = xcom.close

    local win = open_win()
    xcom.close = function() return xcom.err_timeout end
    local rc = win:core_close(200)
    eq("M1 core_close returns the close status", rc, xcom.err_timeout)
    -- M2: a timeout from the SHORT wait is expected, not a failure, and must NOT
    -- be reported as one.  CLOSE_WAIT_MS is deliberately short (a 2000 ms wait
    -- froze the message pump for up to two seconds), but the core's teardown
    -- grace is ~1.7 s -- and as much as 60 s when owner_close's stop_and_join()
    -- waits on a slow writer thread -- so every close that is not instantaneous
    -- returns a timeout.  Reporting it put a false "did not confirm teardown" on
    -- the status bar for healthy closes.  The genuinely-unconverged case is owned
    -- by the CLOSING watchdog in poll_status, which fires only once the core has
    -- LEFT CLOSING without reaching CLOSED; the core's own bound resolves the
    -- rest, which is why a core merely still-CLOSING is not reported either.
    ok("M2 a short-wait timeout is NOT reported as a failure",
       table.concat(win._status_log, "\n"):find("Close timed out", 1, true) == nil)

    -- M2b: the opposite case.  A REJECTED close event means nothing was even
    -- submitted, so the session is still live -- that one must be surfaced.
    local rej = open_win()
    xcom.close = function() return xcom.err_full end
    rej:core_close(200)
    ok("M2b a rejected close IS reported",
       table.concat(rej._status_log, "\n"):find("rejected", 1, true) ~= nil)

    local clean = open_win()
    xcom.close = function() return xcom.ok end
    local rc2 = clean:core_close(200)
    eq("M3 a clean close returns ok", rc2, xcom.ok)
    ok("M4 no timeout notice on a clean close",
       table.concat(clean._status_log, "\n"):find("Close timed out", 1, true) == nil)

    -- Exit path: on_close drains the core too and must not swallow a timeout.
    local exit_win = open_win()
    exit_win.connected = true
    exit_win._set_autosend_enabled = function() end
    exit_win._final_drain = function() end
    exit_win._save_config = function() end
    exit_win._log_close_with_retry = function() end
    exit_win.imgui.close = function() end
    xcom.close = function() return xcom.err_timeout end
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })
    exit_win:on_close()
    rw.user32 = saved_user32
    ok("M5 exit-path close timeout reaches the visible status channel",
       table.concat(exit_win._status_log, "\n"):find("Close timed out", 1, true) ~= nil)

    xcom.close = saved_close
end

-- ===========================================================================
-- N) §6 #4: the Stop combo offers 1.5, but 1.5 stop bits is only valid with a
--    5-data-bit word (serial_backend_win.cpp valid_line_format rejects the
--    rest).  _serial_config is the single choke point every open / reconnect /
--    save reads, so it must normalise the pairing rather than forward an open
--    the core is guaranteed to refuse.
-- ===========================================================================
do
    local win = new_win({}, nil, "COM3")
    win.imgui.serial_config = function() return 115200, 8, 1, 0, 0, false, false end
    local s = win:_serial_config()
    eq("N1 8 data + 1.5 stop normalised to 1 stop", s.stop_bits, 0)
    eq("N2 data bits unchanged", s.data_bits, 8)

    win.imgui.serial_config = function() return 115200, 5, 1, 0, 0, false, false end
    eq("N3 5 data + 1.5 stop kept", win:_serial_config().stop_bits, 1)

    win.imgui.serial_config = function() return 115200, 8, 2, 0, 0, false, false end
    eq("N4 2 stop bits unaffected", win:_serial_config().stop_bits, 2)

    win.imgui.serial_config = function() return 115200, 7, 1, 0, 0, false, false end
    eq("N5 7 data + 1.5 stop normalised", win:_serial_config().stop_bits, 0)
end

print(string.format("%d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
