-- test_log_save_report.lua - truthful reporting for the receive-log writers.
--
-- Defect 1: Window:on_btn_save reported "saved: <path>" unconditionally after
-- ignoring the return values of xcom.log_append / xcom.log_flush (and of
-- _log_close_with_retry).  LogWriter::append rejects any block larger than
-- kFileBlockBytes (64 KiB) whole with XCOM_ERR_FULL, and can also reject on a
-- saturated pool, so a large receive buffer or a busy writer produced a success
-- message for a file that was silently missing data.  The fix chunks the
-- buffer to the block bound, counts what the core actually accepted, and
-- reports full success / partial / failure distinctly.
--
-- Defect 2: Window:_echo_tx discarded xcom.log_append's status, so a rejected
-- TX echo vanished from the capture file while still rendering in the view.
-- The fix surfaces a "TX not logged" status.
--
-- Defect 3 evidence: the async-open take_open_result path now yields a negative
-- XCOM_ERR_* (a raw Win32 code is folded to an enumerator; the raw value lives
-- only in the error ring), so describe_open_error no longer matches it there.
-- Section C pins that the specific cause still reaches the user through
-- _poll_errors, which drains that ring and translates the raw code.
--
-- Runs on the Linux review host with luv / win32 / xcom_ffi stubbed through
-- package.preload (same idiom as tests/test_reconnect_port.lua).  NOTE the
-- __index fallback below makes every omitted stub value look like a FUNCTION,
-- so every constant the code under test compares against must be listed here.

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

package.preload["luv"] = function()
    return { now = function() return 1000000 end }
end
local uv = require("luv")
uv.now = function() return 1000000 end

local real_win32 = require("win32")
real_win32.load = function() return true end
local function any_stub()
    return setmetatable({}, {
        __index = function() return function() return 0 end end,
    })
end
real_win32.kernel32 = any_stub()
real_win32.user32 = any_stub()

local xcom_stub = {
    ok = 0, err_param = -1, err_not_open = -2, err_already_open = -3,
    err_busy = -4, err_full = -5, err_io = -6, err_timeout = -7,
    err_drain_incomplete = -8, err_unsupported = -9,
    port_closed = 0, port_opening = 1, port_open = 2,
    port_closing = 3, port_fault = 4,
    port_text = {}, send_text = 1,
}
-- Mirror of xcom_ffi.open_error_causes for the one raw Win32 code this suite
-- exercises (ERROR_ACCESS_DENIED, i.e. "port in use or permission denied").
local OPEN_CAUSES = { [5] = "端口被其他程序占用或权限不足" }
xcom_stub.describe_open_error = function(code)
    local n = tonumber(code)
    return n and OPEN_CAUSES[n] or nil
end
setmetatable(xcom_stub, {
    __index = function() return function() return 0 end end,
})
package.preload["xcom_ffi"] = function() return xcom_stub end

local window_mod = require("window")
local view_model = require("view_model")
local xcom = xcom_stub

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then
        pass_n = pass_n + 1
    else
        fail_n = fail_n + 1; print("FAIL  " .. label)
    end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%q want=%q)", label, tostring(got), tostring(want)),
       got == want)
end
local function contains(label, hay, needle)
    ok(string.format("%s (got=%q want~=%q)", label, tostring(hay),
                     tostring(needle)),
       type(hay) == "string" and hay:find(needle, 1, true) ~= nil)
end
local function not_contains(label, hay, needle)
    ok(string.format("%s (got=%q must_not~=%q)", label, tostring(hay),
                     tostring(needle)),
       type(hay) == "string" and hay:find(needle, 1, true) == nil)
end

-- Recording fake ImGui bridge.  set_status appends so a test can inspect the
-- LAST status written (the user-visible line).
local function new_fake_imgui(receive_text)
    local b = { status_log = {}, auto_save = { 0 } }
    function b:set_status(s) self.status_log[#self.status_log + 1] = s end
    function b:get_receive_text() return receive_text or "" end
    function b:serial_config() return 115200, 8, 0, 0, false, false end
    function b:set_ports() end
    return b
end

-- Per-test log-writer behavior, replaceable before each save/echo.
local log_behavior
local append_calls

local function new_win(receive_text)
    append_calls = {}
    log_behavior = {
        open = function() return xcom.ok end,
        append = function() return xcom.ok end,
        flush = function() return xcom.ok end,
        close = function() return xcom.ok end,
    }
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
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.core = true
    win.vm = view_model.new()
    win.imgui = new_fake_imgui(receive_text)
    win.status = { labels = { [3] = { hwnd = 0 }, [4] = { hwnd = 0 } } }
    win._tx_echo = true
    win._log_active = false
    win._view_tail_open = false
    -- Route the view append into a recorder so _echo_tx never touches the real
    -- bridge buffer.
    win._echo_display = {}
    win._append_imgui_receive = function(_, text)
        win._echo_display[#win._echo_display + 1] = text
    end
    return win
end

xcom.log_open = function() return log_behavior.open() end
xcom.log_append = function(_, _data, n)
    append_calls[#append_calls + 1] = n
    return log_behavior.append(n)
end
xcom.log_flush = function() return log_behavior.flush() end
xcom.log_close = function() return log_behavior.close() end

local function last_status(win)
    local log = win.imgui.status_log
    return log[#log]
end

local function save(win, path)
    win._save_file_dialog = function() return path end
    win:on_btn_save()
end

-- ===========================================================================
-- A) Defect 1: on_btn_save must never claim success it did not achieve
-- ===========================================================================

-- A1 sanity: a clean write still reports success and records the byte count.
do
    local win = new_win(string.rep("x", 1000))
    save(win, "C:/out.txt")
    eq("A1 success message", last_status(win), "saved: C:/out.txt")
    eq("A1 one append", #append_calls, 1)
    eq("A1 append size", append_calls[1], 1000)
    eq("A1 cfg.save_path updated", win.cfg.save_path, "C:/out.txt")
end

-- A2 log_open failure is still reported (existing behaviour, pinned).
do
    local win = new_win("x")
    log_behavior.open = function() return xcom.err_io end
    save(win, "C:/out.txt")
    eq("A2 open failure message", last_status(win), "save failed: io error")
    eq("A2 nothing appended", #append_calls, 0)
end

-- A3 append rejected (saturated pool) must not read as success.
do
    local win = new_win(string.rep("x", 1000))
    log_behavior.append = function() return xcom.err_full end
    save(win, "C:/out.txt")
    not_contains("A3 no success", last_status(win), "saved:")
    contains("A3 reads as failure, not partial",
             last_status(win), "save failed: C:/out.txt")
    contains("A3 names the failure", last_status(win), "append full")
    contains("A3 states nothing was written",
             last_status(win), "nothing written")
end

-- A4 flush timeout must not read as success.
do
    local win = new_win(string.rep("x", 1000))
    log_behavior.flush = function() return xcom.err_timeout end
    save(win, "C:/out.txt")
    not_contains("A4 no success", last_status(win), "saved:")
    contains("A4 names partial", last_status(win), "save incomplete:")
    contains("A4 names the failure", last_status(win), "flush timeout")
    contains("A4 durability unconfirmed",
             last_status(win), "not confirmed on disk")
end

-- A5 close failure (after the bounded retries) must not read as success.
do
    local win = new_win(string.rep("x", 1000))
    log_behavior.close = function() return xcom.err_io end
    save(win, "C:/out.txt")
    not_contains("A5 no success", last_status(win), "saved:")
    contains("A5 names partial", last_status(win), "save incomplete:")
    contains("A5 names the failure", last_status(win), "log close failed")
    eq("A5 cfg.save_path untouched on failure", win.cfg.save_path, "")
end

-- A6 a buffer larger than one 64 KiB block is chunked, not rejected whole.
-- The stub rejects n > 65536 exactly like LogWriter::append.
do
    local win = new_win(string.rep("A", 70 * 1024))
    log_behavior.append = function(n)
        return (n <= 65536) and xcom.ok or xcom.err_full
    end
    save(win, "C:/big.txt")
    eq("A6 big save succeeds", last_status(win), "saved: C:/big.txt")
    eq("A6 chunk count", #append_calls, 2)
    eq("A6 first chunk", append_calls[1], 65536)
    eq("A6 remainder", append_calls[2], 70 * 1024 - 65536)
end

-- A7 a rejection mid-walk reports the partial byte count and never says saved.
do
    local win = new_win(string.rep("A", 70 * 1024))
    local calls = 0
    log_behavior.append = function()
        calls = calls + 1
        if 1 == calls then return xcom.ok end
        return xcom.err_full
    end
    save(win, "C:/big.txt")
    not_contains("A7 no success", last_status(win), "saved:")
    contains("A7 names partial", last_status(win), "save incomplete:")
    contains("A7 names the failure", last_status(win), "append full")
    contains("A7 reports written bytes",
             last_status(win), "wrote 65536 of 71680 bytes")
end

-- ===========================================================================
-- B) Defect 2: _echo_tx must surface a rejected capture write
-- ===========================================================================

-- B1 clean echo: no error status, view still gets the line.
do
    local win = new_win()
    win._log_active = true
    win:_echo_tx("hello")
    eq("B1 no error status", #win.imgui.status_log, 0)
    eq("B1 one append", #append_calls, 1)
    eq("B1 raw line length", append_calls[1], #"TX: hello\n")
    eq("B1 view line", win._echo_display[1], "TX: hello\n")
end

-- B2 rejected capture write: the view has the line but the file does not, so
-- the divergence must be visible.
do
    local win = new_win()
    win._log_active = true
    log_behavior.append = function() return xcom.err_full end
    win:_echo_tx("hello")
    contains("B2 surfaces the miss", last_status(win), "TX not logged")
    contains("B2 names the failure", last_status(win), "full")
    eq("B2 view still shows the line", win._echo_display[1], "TX: hello\n")
end

-- B3 no active log => no append and no spurious status.
do
    local win = new_win()
    win._log_active = false
    win:_echo_tx("hello")
    eq("B3 no append", #append_calls, 0)
    eq("B3 no status", #win.imgui.status_log, 0)
    eq("B3 view line still shown", win._echo_display[1], "TX: hello\n")
end

-- ===========================================================================
-- C) Defect 3 evidence: the raw Win32 cause survives via the error ring
-- ===========================================================================
do
    local win = new_win()
    -- The exact record sink_owner_open pushes for a Win32 open failure: the raw
    -- ERROR_ACCESS_DENIED (5) code, which take_open_result folds to XCOM_ERR_IO
    -- (-6).  _poll_errors is the tail of Window:poll_status.
    local pending = { code = 5, source = 2, message = "Win32 serial open failed" }
    xcom.take_error = function()
        local r = pending
        pending = nil
        return r
    end
    win:_poll_errors()
    contains("C1 raw code preserved", win._status_dirty, "E5")
    contains("C2 cause translated",
             win._status_dirty, "端口被其他程序占用或权限不足")
end

print(string.format("log_save_report: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
