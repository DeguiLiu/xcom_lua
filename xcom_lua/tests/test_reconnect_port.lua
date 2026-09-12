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
    ok = 0, err_busy = 4,
    port_closed = 0, port_opening = 1, port_open = 2,
    port_closing = 3, port_fault = 4,
    port_text = {},
    send_text = 1,
    list_ports = function() return {} end,
    close = function() return 0 end,
    open_async = function() return 0 end,
    take_open_result = function() return 0 end,
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
    local b = { status_log = status_log, set_ports_calls = 0 }
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

print(string.format("%d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
