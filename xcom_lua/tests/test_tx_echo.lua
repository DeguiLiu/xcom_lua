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
local uv = require("luv")
uv.now = function() return fake_now end
package.path = "./ui/?.lua;./core/?.lua;" .. package.path

-- Recording xcom stub: window.lua captures require("xcom_ffi") at load
-- time, so the fake must sit in package.loaded BEFORE the window require.
local log_calls = {}
-- xcom.log_append is exposed as a plain variadic (h, data, size) — the
-- recorded `data` is the second positional argument the production code
-- passes (window.lua: `xcom.log_append(self.core, text, #text)`).  The earlier
-- 4-arg stub `(self, h, data, size)` shifted everything by one slot and the
-- `data` slot ended up holding the size integer (e.g. 11), masking the log
-- content for every assertion in A2/D2.
package.loaded["xcom_ffi"] = {
    ok = 0,
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
        set_receive_text = function(self, text, base)
            self.pushes[#self.pushes + 1] = { text = text, base = base }
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
w3:_process_rx_batch("partial")             -- no trailing newline
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

print(string.format("\ntest_tx_echo: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
