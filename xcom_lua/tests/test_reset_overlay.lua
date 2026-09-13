-- test_reset_overlay.lua - offline tests for design-device-profiles steps 4 & 5:
-- the non-blocking reset-sequencer driver and the recovery-overlay fields in
-- Window:ui_state().
--
-- Sections:
--   A) auto reset: profile resolution (hardware_id), 5 ms dedicated luv timer,
--      boolean set_lines wrapper, edge order/timing, terminal stop.
--   B) manual reset: no pins driven, instructions + countdown surfaced, the
--      auto->manual downgrade `note` (unsupported flow control) never swallowed.
--   C) failure path: set_lines error -> "reset failed", safety deassert, stop.
--   D) send interlock: core_send refuses while a sequence is in flight, and
--      accepts again once the sequence reaches a terminal state.
--   E) overlay: port_gone / port_reenum / port_ambiguous derived from the real
--      _resolve_reconnect_port candidate scan, each with a real exit.
--   F) overlay: link_silent driven through the real poll_status path.
--   G) overlay: tx_stalled driven through the real poll_status path.
--
-- Harness: luv is stubbed (fake now + fake timer with fire()); win32.load() is
-- patched off; xcom_ffi is replaced with recording stubs.  No DLL is touched.
--
-- Usage: cd xcom_lua && luajit tests/test_reset_overlay.lua

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

local fake_now = 1000
local fake_timers = {}
local FakeTimer = {}
FakeTimer.__index = FakeTimer
function FakeTimer:start(initial, repeat_ms, cb)
    self.initial, self.repeat_ms, self.cb = initial, repeat_ms, cb
    self.stopped = false
end
function FakeTimer:stop() self.stopped = true end
function FakeTimer:close() self.closed = true end
function FakeTimer:fire()
    if self.cb then self.cb() end
end
local function new_fake_timer()
    local t = setmetatable({}, FakeTimer)
    fake_timers[#fake_timers + 1] = t
    return t
end

package.preload["luv"] = function()
    return { now = function() return fake_now end,
             new_timer = new_fake_timer }
end
local uv = require("luv")
uv.now = function() return fake_now end

local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})
real_win32.user32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

-- Recording xcom stub -------------------------------------------------------
local set_line_calls = {}
local send_calls = {}
local auto_template_calls = {}
local PORTS = {}
local set_lines_fail_at = nil   -- 1-based call index that returns non-zero

local xcom_stub = {
    ok = 0, err_busy = 4, err_timeout = -7, err_full = -5, err_not_open = -2,
    port_closed = 0, port_opening = 1, port_open = 2,
    port_closing = 3, port_fault = 4,
    port_text = {}, send_text = 1,
    list_ports = function() return PORTS end,
    set_lines = function(_, dtr, rts)
        set_line_calls[#set_line_calls + 1] = { dtr, rts }
        if set_lines_fail_at and #set_line_calls == set_lines_fail_at then
            return 1
        end
        return 0
    end,
    send = function(_, data, flags)
        send_calls[#send_calls + 1] = { data, flags }
        return 0
    end,
    set_auto_template = function(_, data, interval, flags)
        auto_template_calls[#auto_template_calls + 1] = { data, interval, flags }
        return 0
    end,
    take_error = function() return nil end,
    describe_open_error = function() return nil end,
}
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

local function new_fake_imgui(status_log)
    local b = { status_log = status_log, send_hex = { [0] = 0 },
                send_crlf = { [0] = 0 }, send_period = { [0] = 1000 },
                multi_hex = { [0] = 0 }, multi_crlf = { [0] = 0 },
                multi_period = { [0] = 1000 } }
    function b:set_status(s) status_log[#status_log + 1] = s end
    function b:serial_config() return 115200, 8, 0, 0, false, false end
    function b:send_text() return "" end
    function b:multi_entry() return "", false end
    return b
end

local function new_win(cfg_data)
    local cfg = {
        window = { x = 0, y = 0, w = 920, h = 650 },
        port = "COM3", baud_rate = 115200, data_bits = 8, stop_bits = 0,
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
    local win = window_mod.new(cfg, cfg_data or { [""] = {} }, "_test.ini")
    win.conn = nil
    win.core = "core-handle"
    win._imgui_port = "COM3"
    win._status_log = {}
    win.imgui = new_fake_imgui(win._status_log)
    return win
end

local function last_log(win)
    return table.concat(win._status_log, "\n")
end

-- ===========================================================================
-- A) auto reset sequence: profile + non-blocking timer + boolean set_lines
-- ===========================================================================
do
    set_line_calls = {}
    set_lines_fail_at = nil
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local win = new_win()
    -- Keep a handle on the timer the driver creates.
    local before = #fake_timers
    fake_now = 1000
    ok("A0 sequence starts", win:start_reset_sequence())
    eq("A1 one reset timer created", #fake_timers - before, 1)
    local timer = fake_timers[#fake_timers]
    eq("A2 tick is ~5 ms", timer.initial, 5)
    eq("A3 repeating tick", timer.repeat_ms, 5)
    eq("A4 no lines driven yet (work is deferred, not done inline)",
       #set_line_calls, 0)
    eq("A5 run state is RUNNING", win._reset_last_state, "running")
    ok("A6 send is blocked in flight", win:_reset_in_flight())

    -- Fire the timer manually as luv would, advancing the injected clock.
    fake_now = 1000                       -- t0
    timer:fire()
    eq("A7 first edge RTS=1", #set_line_calls, 1)
    eq("A8 dtr stays 0", set_line_calls[1][1], false)
    eq("A9 rts asserted", set_line_calls[1][2], true)
    eq("A10 wrapper converts to BOOLEAN not 0/1",
       type(set_line_calls[1][1]) .. "/" .. type(set_line_calls[1][2]),
       "boolean/boolean")

    fake_now = 1119
    timer:fire()
    eq("A11 no edge before the 120 ms delay", #set_line_calls, 1)

    fake_now = 1120
    timer:fire()
    eq("A12 second edge dtr=1", #set_line_calls, 2)
    eq("A13 rts still 1", set_line_calls[2][2], true)
    eq("A14 dtr now 1", set_line_calls[2][1], true)

    fake_now = 1180
    timer:fire()
    eq("A15 third edge rts=0", #set_line_calls, 3)
    eq("A16 rts released", set_line_calls[3][2], false)

    fake_now = 1230
    timer:fire()
    eq("A17 fourth edge dtr=0", #set_line_calls, 4)
    eq("A18 resting level deasserted",
       set_line_calls[4][1] == false and set_line_calls[4][2] == false, true)
    eq("A19 now settling", win._reset_seq:state(), "settling")

    fake_now = 4230                        -- t0 + 230 + settle 3000
    timer:fire()
    eq("A20 terminal: sequence dropped", win._reset_seq, nil)
    ok("A21 timer stopped", timer.stopped == true)
    ok("A22 send unblocked after done", not win:_reset_in_flight())
    ok("A23 status reports done", last_log(win):find("reset done", 1, true) ~= nil)
end

-- ===========================================================================
-- B) manual reset: no pins, instructions + countdown, `note` surfaced
-- ===========================================================================
do
    set_line_calls = {}
    set_lines_fail_at = nil
    PORTS = { { name = "COM3", description = "USB Serial Device",
                hardware_id = "USB\\VID_1234&PID_5678" } }   -- cdc_acm = manual
    local win = new_win()
    ok("B0 manual reset starts", win:start_reset_sequence())
    eq("B1 state is MANUAL", win._reset_last_state, "manual")
    eq("B2 manual drives no pins", #set_line_calls, 0)
    ok("B3 instructions on screen",
       last_log(win):find("Hold BOOT, tap RST, release BOOT", 1, true) ~= nil)
    ok("B4 countdown on screen", last_log(win):find("(%d+s)", 1) ~= nil)
    eq("B5 profile resolved by hardware_id", win._reset_profile.id, "cdc_acm")

    -- Countdown end is the user exit: the sequence finalises itself.
    local timer = fake_timers[#fake_timers]
    fake_now = fake_now + 100000
    timer:fire()
    eq("B6 manual sequence finished", win._reset_seq, nil)
    ok("B7 finished status surfaced",
       last_log(win):find("manual prompt finished", 1, true) ~= nil)
    ok("B8 send unblocked after manual", not win:_reset_in_flight())
end

-- ===========================================================================
-- B2) auto -> manual downgrade under unsupported flow control: the sequencer
--     `note` must reach the user, and no pins may be driven.
-- ===========================================================================
do
    set_line_calls = {}
    set_lines_fail_at = nil
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local cfg_data = {
        [""] = {},
        ["profile"] = { key = "", mode = "custom" },
        ["profile.custom"] = { flow_control = "unsupported" },
    }
    local win = new_win(cfg_data)
    ok("B9 downgraded reset starts", win:start_reset_sequence())
    eq("B10 auto downgraded to MANUAL", win._reset_last_state, "manual")
    eq("B11 no pins driven under unsupported flow control", #set_line_calls, 0)
    ok("B12 the downgrade note is never swallowed",
       last_log(win):find("flow_control unsupported", 1, true) ~= nil)
end

-- ===========================================================================
-- C) failure path: set_lines error -> failed status + safety deassert + stop
-- ===========================================================================
do
    set_line_calls = {}
    set_lines_fail_at = 2                  -- second edge fails
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local win = new_win()
    fake_now = 1000
    win:start_reset_sequence()
    local timer = fake_timers[#fake_timers]
    fake_now = 1000
    timer:fire()                           -- edge 1 ok
    fake_now = 1120
    timer:fire()                           -- edge 2 fails
    eq("C1 sequence dropped on failure", win._reset_seq, nil)
    ok("C2 timer stopped on failure", timer.stopped == true)
    ok("C3 failure reason surfaced",
       last_log(win):find("reset failed", 1, true) ~= nil)
    local n = #set_line_calls
    eq("C4 safety deassert after failure",
       set_line_calls[n][1] == false and set_line_calls[n][2] == false, true)
end

-- ===========================================================================
-- D) send interlock through the real core_send
-- ===========================================================================
do
    set_line_calls = {}
    send_calls = {}
    set_lines_fail_at = nil
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local win = new_win()
    fake_now = 1000
    win:start_reset_sequence()
    local ok_send, rc = win:core_send("AB", xcom.send_text)
    eq("D1 send refused during reset", ok_send, false)
    eq("D2 refusal carries err_busy", rc, xcom.err_busy)
    eq("D3 no bytes reached the core", #send_calls, 0)
    ok("D4 refusal is visible",
       last_log(win):find("send blocked", 1, true) ~= nil)

    local timer = fake_timers[#fake_timers]
    fake_now = 1000; timer:fire()
    fake_now = 1120; timer:fire()
    fake_now = 1180; timer:fire()
    fake_now = 1230; timer:fire()
    fake_now = 4230; timer:fire()          -- done
    eq("D5 sequence terminal", win._reset_seq, nil)
    local ok2 = win:core_send("AB", xcom.send_text)
    ok("D6 send allowed after the sequence", ok2 == true)
    eq("D7 bytes reached the core", #send_calls, 1)
end

-- ===========================================================================
-- E) recovery overlay: gone / reenum / ambiguous from the REAL candidate scan
-- ===========================================================================
do
    local function open_recovering(win)
        win.vm:intent_open()
        win.vm:on_port_state(2, 1)
        win.vm:enter_reconnecting(1)
        return win
    end

    -- E1: original gone, no candidate -> port_gone, exit by the device returning.
    local win = open_recovering(new_win())
    win.vm:set_port_present(false)
    PORTS = { { name = "COM9", description = "Unrelated" } }
    win:_resolve_reconnect_port("COM3", "CH340")
    local st = win:ui_state()
    eq("E1 port_gone", st.port_gone, true)
    eq("E1b not reenum", st.port_reenum, false)
    eq("E1c not ambiguous", st.port_ambiguous, false)
    win.vm:set_port_present(true)          -- device reappears
    eq("E2 presence clears port_gone", win:ui_state().port_gone, false)

    -- E3: exactly one newly-appeared same-description port -> port_reenum.
    win = open_recovering(new_win())
    win.vm:set_port_present(false)
    PORTS = { { name = "COM7", description = "CH340" } }
    win:_resolve_reconnect_port("COM3", "CH340")
    st = win:ui_state()
    eq("E3 port_reenum", st.port_reenum, true)
    eq("E3b not gone", st.port_gone, false)
    win.vm:reconnect_timeout()             -- window elapsed -> not recovering
    eq("E4 leaving recovery clears port_reenum", win:ui_state().port_reenum, false)

    -- E5: two candidates -> port_ambiguous, never a guess.
    win = open_recovering(new_win())
    win.vm:set_port_present(false)
    PORTS = { { name = "COM7", description = "CH340" },
              { name = "COM8", description = "CH340" } }
    local target, matched = win:_resolve_reconnect_port("COM3", "CH340")
    st = win:ui_state()
    eq("E5 port_ambiguous", st.port_ambiguous, true)
    eq("E5b not gone", st.port_gone, false)
    eq("E5c never adopted an ambiguous match", matched, false)
    win.vm:reconnect_timeout()
    eq("E6 leaving recovery clears port_ambiguous",
       win:ui_state().port_ambiguous, false)

    -- E7: the pre-existing-peer guard stays consistent -- a same-description
    -- port that was already attached is NOT a re-enumeration candidate.
    win = open_recovering(new_win())
    win.vm:set_port_present(false)
    PORTS = { { name = "COM7", description = "CH340" } }
    win._reconnect_known_ports = { COM7 = true }
    win:_resolve_reconnect_port("COM3", "CH340")
    st = win:ui_state()
    eq("E7 known peer is not a reenum candidate", st.port_reenum, false)
    eq("E7b it degrades to port_gone", st.port_gone, true)
end

-- ===========================================================================
-- F) overlay: link_silent through the real poll_status path
-- ===========================================================================
local function full_snap(over)
    local snap = {
        port_state = 2, generation = 1, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0,
        rx_backpressure_events = 0, framing_errors = 0, parity_errors = 0,
        break_events = 0, display_paused_bytes = 0, rx_loss_offset = 0,
        rx_sequence = 0, flow_hold_events = 0,
    }
    for k, v in pairs(over or {}) do snap[k] = v end
    return snap
end

local function poll(win, snap)
    local saved = { xcom.get_snapshot, xcom.take_error }
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end
    win:poll_status()
    xcom.get_snapshot, xcom.take_error = saved[1], saved[2]
end

local function open_win()
    local win = new_win()
    win.vm:intent_open()
    win.vm:on_port_state(2, 1)
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end
    return win
end

do
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local win = open_win()
    poll(win, full_snap())                 -- seeds the idle anchor at fake_now
    eq("F1 not silent at t0", win:ui_state().link_silent, false)
    fake_now = fake_now + 6000             -- > silent_warn_ms (5000)
    poll(win, full_snap())
    eq("F2 silent past the profile threshold", win:ui_state().link_silent, true)
    -- Exit: any received byte resets the idle anchor.
    fake_now = fake_now + 10
    poll(win, full_snap({ rx_bytes = 10 }))
    eq("F3 RX clears link_silent", win:ui_state().link_silent, false)
    -- Negative: before the threshold it must not be raised.
    fake_now = fake_now + 100
    poll(win, full_snap({ rx_bytes = 10 }))
    eq("F4 under threshold stays clear", win:ui_state().link_silent, false)
end

-- ===========================================================================
-- G) overlay: tx_stalled through the real poll_status path (no auto-fault)
-- ===========================================================================
do
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local win = open_win()
    poll(win, full_snap())                 -- baseline flow_hold_events = 0
    eq("G1 no stall on a fresh session", win:ui_state().tx_stalled, false)
    poll(win, full_snap({ flow_hold_events = 3 }))
    eq("G2 a rise raises tx_stalled", win:ui_state().tx_stalled, true)
    eq("G3 port stays OPEN (never auto-faulted)", win.vm.hsm.state,
       view_model.STATE_OPEN)
    -- Exit: the counter stops rising; the quiet window elapses.
    fake_now = fake_now + 2001
    poll(win, full_snap({ flow_hold_events = 3 }))
    eq("G4 hold released clears tx_stalled", win:ui_state().tx_stalled, false)
    ok("G5 a stall message reached the user",
       (win._status_dirty or ""):find("flow control", 1, true) ~= nil)
end

-- ===========================================================================
-- H) a reset stops (and refuses to re-arm) the paced core-side senders
-- ===========================================================================
do
    set_line_calls = {}
    PORTS = { { name = "COM3", description = "USB-SERIAL CH340",
                hardware_id = "USB\\VID_1A86&PID_7523" } }
    local win = new_win()
    win.imgui.send_auto = { [0] = 1 }
    win.imgui.multi_auto = { [0] = 1 }
    auto_template_calls = {}
    fake_now = 1000
    win:start_reset_sequence()
    eq("H1 autosend cleared when the reset starts", win.imgui.send_auto[0], 0)
    eq("H2 multi auto-cycle cleared when the reset starts", win.imgui.multi_auto[0], 0)
    local last = auto_template_calls[#auto_template_calls]
    ok("H3 the core auto template is cleared",
       last ~= nil and last[1] == "")

    -- Re-arming mid-sequence is refused and the toggle is cleared.
    win.imgui.send_auto[0] = 1
    win.imgui.multi_auto[0] = 1
    win:_sync_imgui_autosend()
    eq("H4 re-arming autosend refused", win.imgui.send_auto[0], 0)
    win:_sync_imgui_multi_auto()
    eq("H5 re-arming multi auto-cycle refused", win.imgui.multi_auto[0], 0)
    ok("H6 the refusal is surfaced",
       (win._status_dirty or ""):find("reset sequence running", 1, true) ~= nil)
end

print(string.format("\nreset_overlay tests: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
