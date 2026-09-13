-- test_reconnect_known_peers.lua - reconnect must not silently adopt a PEER.
-- Usage: cd xcom_lua && luajit tests/test_reconnect_known_peers.lua
--
-- Latent defect pinned here: _resolve_reconnect_port matched a port purely by
-- registry description.  With two same-model adapters attached (no serial
-- number), if the original was unplugged the surviving peer became the sole
-- description match and was silently opened as the reconnect target.  The fix
-- snapshots the port names present when the grace window is armed and accepts
-- a description match only when that name is NEWLY appeared.
--
-- Runs headless on Linux with the same luv/win32/xcom_ffi stubs as
-- tests/test_reconnect_port.lua; that file is another agent's territory, so
-- this guard lives in its own file.

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

local xcom_stub = {
    ok = 0, err_busy = 4, err_timeout = -7,
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
local xcom = xcom_stub

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

local PORTS = {}
xcom.list_ports = function() return PORTS end

local function new_win()
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
    win.conn = nil
    win.core = true
    return win
end

local DESC = "USB-SERIAL CH340"

-- 1) _present_port_names snapshots the enumerated set, blank names ignored.
PORTS = { { name = "COM3", description = DESC }, { name = "COM4", description = DESC } }
do
    local win = new_win()
    local names = win:_present_port_names()
    eq("snapshot has original", names["COM3"], true)
    eq("snapshot has peer", names["COM4"], true)
    eq("snapshot ignores absent", names["COM9"], nil)
end

-- 2) Original gone, a PRE-EXISTING same-description peer remains: the peer must
--    NOT be adopted (this is the silently-wrong-device case).
do
    local win = new_win()
    win._reconnect_known_ports = { ["COM3"] = true, ["COM4"] = true }
    PORTS = { { name = "COM4", description = DESC } }   -- original vanished
    local target, matched = win:_resolve_reconnect_port("COM3", DESC)
    eq("pre-existing peer not matched", matched, false)
    eq("pre-existing peer target stays original", target, "COM3")
end

-- 3) Original gone, a NEW same-description port appears (USB re-enumeration):
--    it IS adopted.
do
    local win = new_win()
    win._reconnect_known_ports = { ["COM3"] = true, ["COM4"] = true }
    PORTS = { { name = "COM4", description = DESC },
              { name = "COM5", description = DESC } }  -- re-enumerated original
    local target, matched = win:_resolve_reconnect_port("COM3", DESC)
    eq("new port matched", matched, true)
    eq("new port target", target, "COM5")
end

-- 4) Same peer scenario but with no snapshot: old behaviour (documents that the
--    snapshot is what enables the guard).  A production arm always snapshots.
do
    local win = new_win()
    win._reconnect_known_ports = nil
    PORTS = { { name = "COM4", description = DESC } }
    local target, matched = win:_resolve_reconnect_port("COM3", DESC)
    eq("no snapshot keeps legacy match", matched, true)
    eq("no snapshot legacy target", target, "COM4")
end

-- 5) Original still enumerated: matched by name regardless of snapshot.
do
    local win = new_win()
    win._reconnect_known_ports = { ["COM3"] = true, ["COM4"] = true }
    PORTS = { { name = "COM3", description = DESC },
              { name = "COM4", description = DESC } }
    local target, matched = win:_resolve_reconnect_port("COM3", DESC)
    eq("present original matched", matched, true)
    eq("present original target", target, "COM3")
end

print(string.format("\nreconnect_known_peers: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
