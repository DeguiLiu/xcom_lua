-- test_tx_echo.lua - offline audit for the display/log echo of transmitted
-- payloads ([display] tx_echo, "发送回显").  Usage:
--   runtime\luvjit.exe tests\test_tx_echo.lua
--
-- Neither the C core nor the ImGui DLL participates: Window:core_send calls
-- Window:_echo_tx after a successful xcom.send, which appends a "TX: "
-- prefixed line to the SAME display funnel RX uses (_append_imgui_receive,
-- so auto_clear/frame_gap bookkeeping applies) and writes the identical line
-- to the auto-save log via xcom.log_append.  Same harness pattern as
-- tests/test_rx_display_caps.lua (fake deps, no window/DLL/port).
--
-- Asserts:
--   A) default: echo on; payload without trailing newline gets one.
--   B) payload WITH trailing newline is not double-broken.
--   C) mid-line view tail: the echoed line starts on a fresh row.
--   D) CRLF payload is LF-normalised for the display; the log keeps it raw
--      (byte-faithful capture contract).
--   E) tx_echo = false in config: neither display nor log receives anything.
--   F) echoed bytes count toward auto_clear_bytes exactly like RX bytes.
--   G) empty payload: no echo at all (core_send never sees empty anyway).
--   H) the core's rx/tx counters and _log_active flag are untouched.

local fake_now = 1000000
-- luv is a Windows binary module (runtime/luvjit.exe); stub it through
-- package.preload so this suite also runs on the Linux review host and can
-- join the CI list, exactly like tests/test_multi_send.lua.  Only now() and
-- new_timer() are referenced on any path these assertions take.
local fake_timers = {}
package.preload["luv"] = function()
    return {
        now = function() return fake_now end,
        new_timer = function()
            local t = { start = function() end, stop = function() end,
                        close = function() end, again = function() end,
                        set_repeat = function() end }
            fake_timers[#fake_timers + 1] = t
            return t
        end,
        hrtime = function() return fake_now * 1000000 end,
        backend_timeout = function() return 100 end,
    }
end
local uv = require("luv")
uv.now = function() return fake_now end
package.path = "./ui/?.lua;./core/?.lua;" .. package.path

-- win32.lua refuses to load its DLLs off Windows; patch load() on the REAL
-- module and stub the lazy handles this pure logic path never touches (same
-- harness as tests/test_multi_send.lua).  Without it the suite can only run
-- under runtime/luvjit.exe on Windows.
local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})
real_win32.user32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

-- Recording xcom stub: window.lua captures require("xcom_ffi") at load
-- time, so the fake must sit in package.loaded BEFORE the window require.
local log_calls = {}
-- Successful-send recorder: window.lua's core_send calls xcom.send(h, data,
-- flags) and only echoes on XCOM_OK, so the stub must report success for the
-- section-I frame-pull assertion to exercise the real success branch.
local send_calls = {}
-- xcom.log_append is exposed as a plain variadic (h, data, size) — the
-- recorded `data` is the second positional argument the production code
-- passes (window.lua: `xcom.log_append(self.core, text, #text)`).  The earlier
-- 4-arg stub `(self, h, data, size)` shifted everything by one slot and the
-- `data` slot ended up holding the size integer (e.g. 11), masking the log
-- content for every assertion in A2/D2.
package.loaded["xcom_ffi"] = {
    ok = 0,
    -- _imgui_send_single encodes the typed text before sending; the real
    -- builder also decodes HEX and appends CRLF.  Both ticks are off in the
    -- history cases, so returning the text (and "" for a blank box, which is
    -- what the real one does for a whitespace-only HEX payload) is enough to
    -- drive the path under test.
    build_send_payload = function(text, _hex, _crlf)
        if text == "" then return "" end
        return text
    end,
    send = function(h, data, size, flags)
        send_calls[#send_calls + 1] = data
        return 0
    end,
    log_append = function(h, data, size)
        log_calls[#log_calls + 1] = data
        return 0
    end,
}

local window_mod = require("window")

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

-- Recording xcom surface (asserted through log_calls above); the fake in
-- package.loaded already routes window.lua's calls into it.
local xcom_stub = nil  -- log_append assertions read log_calls directly

local function new_fake_bridge()
    return {
        pushes = {},
        statuses = {},
        set_receive_text = function(self, text, base)
            self.pushes[#self.pushes + 1] = { text = text, base = base }
        end,
        -- _set_port_status (refused-send path) routes through the ACTIVE UI's
        -- status channel, so the fake must accept it.
        set_status = function(self, text)
            self.statuses[#self.statuses + 1] = text
        end,
    }
end

local function new_fake_window(cfg_over)
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
        charset = "ASCII", frame_gap_ms = 0, tx_echo = true,
    }
    for k, v in pairs(cfg_over or {}) do cfg[k] = v end
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.imgui = new_fake_bridge()
    win.core = {}
    win._log_active = false
    return win
end

local function view_text(win)
    win:_flush_imgui_receive()
    return win._imgui_receive
end

local function fresh_log(win)
    log_calls = {}
    win._log_active = true
end

-- ===========================================================================
-- A) default on: newline is appended when the payload has none
-- ===========================================================================
local w1 = new_fake_window({})
fresh_log(w1)
w1:_echo_tx("AT+RST")
eq("A1 view: TX-prefixed line with newline",
   view_text(w1), "TX: AT+RST\n")
eq("A2 log: same line recorded raw", log_calls[1], "TX: AT+RST\n")
eq("A3 log: exactly one append", #log_calls, 1)

-- ===========================================================================
-- B) payload already newline-terminated: no double break
-- ===========================================================================
local w2 = new_fake_window({})
fresh_log(w2)
w2:_echo_tx("hello\n")
eq("B1 view: no extra newline", view_text(w2), "TX: hello\n")

-- ===========================================================================
-- C) mid-line tail: the echo opens a fresh row
-- ===========================================================================
local w3 = new_fake_window({})
-- The whole-line bridge (design §2) HOLDS a partial line until a frame
-- boundary, so "partial" is in _rx_line_pending, not in the view: without the
-- explicit flush below the echo opens the view and the assertion fails on the
-- current design (it was written against the pre-§2 immediate-append
-- behaviour).  Flushing with the same call the idle/drain path uses is the
-- boundary the case actually means.
w3:_process_rx_batch("partial")             -- no trailing newline
w3:_flush_rx_lines(false)                   -- frame boundary: tail becomes visible
w3:_echo_tx("CMD")
eq("C1 view: RX tail kept, TX on new row",
   view_text(w3), "partial\nTX: CMD\n")

-- ===========================================================================
-- D) CRLF: display is LF-normalised, log keeps raw bytes
-- ===========================================================================
local w4 = new_fake_window({})
fresh_log(w4)
w4:_echo_tx("ping\r\n")
eq("D1 view: CRLF folded to LF", view_text(w4), "TX: ping\n")
eq("D2 log: raw CRLF preserved", log_calls[1], "TX: ping\r\n")

-- ===========================================================================
-- E) tx_echo = false: silent
-- ===========================================================================
local w5 = new_fake_window({ tx_echo = false })
fresh_log(w5)
w5:_echo_tx("quiet")
eq("E1 view: nothing echoed", view_text(w5), "")
eq("E2 log: nothing appended", #log_calls, 0)

-- ===========================================================================
-- F) echoed bytes count toward auto_clear_bytes like RX bytes
-- ===========================================================================
local w6 = new_fake_window({ auto_clear_bytes = 11 })
w6:_echo_tx("12345")                        -- 5 bytes ("TX: " + payload + \n = 10)
eq("F1 10/11: view kept", view_text(w6), "TX: 12345\n")
w6:_echo_tx("x")                            -- 5 + 6 = 11 == threshold: fire
eq("F2 11/11: view cleared", w6._imgui_receive_total, 0)

-- ===========================================================================
-- G) empty payload: no echo, no log
-- ===========================================================================
local w7 = new_fake_window({})
fresh_log(w7)
w7:_echo_tx("")
eq("G1 empty: no view bytes", view_text(w7), "")
eq("G2 empty: no log appends", #log_calls, 0)

-- ===========================================================================
-- H) counters / flags untouched
-- ===========================================================================
local w8 = new_fake_window({})
w8._rx_bytes = 111
w8._tx_bytes = 222
fresh_log(w8)
w8:_echo_tx("data")
eq("H1 rx counter untouched", w8._rx_bytes, 111)
eq("H2 tx counter untouched", w8._tx_bytes, 222)
eq("H3 log flag still active", w8._log_active, true)

-- ===========================================================================
-- I) a successful send pulls the next frame at the interactive cadence
-- ===========================================================================
-- The send runs inside _dispatch_imgui_actions, i.e. AFTER the frame that
-- produced the action was drawn, so the TX echo row, the status line and the
-- TX counter are all next-frame content.  Without the request the next frame
-- arrives only on the idle heartbeat (500 ms) or the next input message: the
-- bytes are queued on the wire while the UI looks dead for up to half a second.
local w9 = new_fake_window({})
fresh_log(w9)
w9._imgui_next_frame = nil
w9._frame_demand = 0
local sent_ok = w9:core_send("AT", 0)
eq("I1 core_send reported success", sent_ok, true)
eq("I2 payload reached xcom.send", send_calls[1], "AT")
ok("I3 send pulled a frame", (w9._frame_demand or 0) > 0)
eq("I4 frame deadline armed", type(w9._imgui_next_frame), "number")

-- I5 negative control: a REFUSED send (interlock) must not pull a frame.
-- w10._reset_seq reports RUNNING, so the reset interlock refuses the send.
local w10 = new_fake_window({})
w10._reset_seq = { state = function()
    return require("reset_sequencer").STATES.RUNNING
end }
w10._imgui_next_frame = nil
w10._frame_demand = 0
local refused = w10:core_send("AT", 0)
eq("I5 refused send returns false", refused, false)
eq("I6 refused send queued nothing", #send_calls, 1)
eq("I7 refused send pulled no frame", w10._frame_demand, 0)

-- ===========================================================================
-- J) Command history ("历史命令要能记住"): a send from the single box is
--    remembered and published to the bridge; a refused send is not; a repeat of
--    the newest command does not re-publish.  The policy itself (dedupe, cap,
--    blanks) is pinned in tests/test_send_history.lua -- what is checked here is
--    the WIRING: which sends reach the list, and that persistence is requested.
-- ===========================================================================
do
    local win = new_fake_window({})
    local pushed = {}
    win.imgui.send_text = function() return win._typed or "" end
    win.imgui.send_hex = { 0 }
    win.imgui.send_crlf = { 0 }
    win.imgui.set_send_history = function(_, list)
        pushed[#pushed + 1] = table.concat(list, "|")
    end
    eq("J1 history starts empty", #win._send_history, 0)
    -- The save itself is debounced (see test_multi_send AK), so what a history
    -- change owes the config layer is the REQUEST, not a dirty flag it cannot
    -- set without the startup timer.
    local dirty_marks = 0
    win._mark_config_dirty = function() dirty_marks = dirty_marks + 1 end

    win._typed = "AT+GMR"
    win:_imgui_send_single()
    eq("J2 a sent command is remembered", win._send_history[1], "AT+GMR")
    eq("J3 and published to the bridge", pushed[#pushed], "AT+GMR")
    eq("J4 the change asks for the config to be written", dirty_marks, 1)

    win._typed = "AT+RST"
    win:_imgui_send_single()
    eq("J5 the newest command leads the list",
       table.concat(win._send_history, "|"), "AT+RST|AT+GMR")

    -- Same command twice in a row: the list is unchanged, so nothing is
    -- re-published (no churn in the widget, no needless write).
    local pushes_before = #pushed
    local marks_before = dirty_marks
    win._typed = "AT+RST"
    win:_imgui_send_single()
    eq("J6 a repeat is not a new entry", #win._send_history, 2)
    eq("J7 and is not re-published", #pushed, pushes_before)
    eq("J7b and does not ask for a write", dirty_marks, marks_before)

    -- A refused send never happened, so it must not be recallable.
    local w11 = new_fake_window({})
    w11.imgui.send_text = function() return "AT+REFUSED" end
    w11.imgui.send_hex = { 0 }
    w11.imgui.send_crlf = { 0 }
    w11._reset_seq = { state = function()
        return require("reset_sequencer").STATES.RUNNING
    end }
    w11:_imgui_send_single()
    eq("J8 a refused send is not remembered", #w11._send_history, 0)

    -- Blank box: nothing typed, nothing sent, nothing remembered.
    local w12 = new_fake_window({})
    w12.imgui.send_text = function() return "" end
    w12._send_history = require("send_history").push({}, "AT")
    w12:_imgui_send_single()
    eq("J9 an empty box leaves the history alone", #w12._send_history, 1)
end

print(string.format("\ntest_tx_echo: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
