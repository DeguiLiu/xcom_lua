-- Receive bytes from an external process/device (no test injection).
-- Usage: runtime\luajit.exe tests\serial_external_receive_test.lua COM3 5000
--
-- NOT convertible to the VIRTUAL session by design: this test exercises the
-- REAL Win32 read-callback ingress (it deliberately never calls the
-- xcom_test_inject_rx seam), which needs bytes arriving from an external
-- partner on a physical port.  A VIRTUAL session has no backend and no peer,
-- so nothing would ever show up.  With no COM port argument on a host without
-- hardware it prints an explicit SKIP (exit 0); pass a COM name to run it on
-- a machine wired for loopback.
local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/serial_external_receive_test.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root = tests_dir:gsub("[/\\]$", "") .. "/.."
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")
local port = (arg and arg[1])
local duration = tonumber(arg and arg[2]) or 5000
-- VIRTUAL/TEST sessions cannot carry external traffic: skip explicitly.
if port and (port == "VIRTUAL" or port:sub(1, 4) == "TEST") then
    print("SKIP " .. port .. ": requires physical COM loopback (this test never injects)")
    os.exit(0)
end
local handle, err = xcom.create()
assert(handle, err)
local function finish(code)
    xcom.destroy(handle)
    os.exit(code or 0)
end
if not port then
    -- No COM given: only auto-skip when the host really has no ports;
    -- otherwise keep the original COM3 default unchanged.
    local ports = xcom.list_ports()
    if #ports == 0 then
        print("SKIP (no COM port enumerated): requires physical COM loopback")
        xcom.destroy(handle)
        os.exit(0)
    end
    port = "COM3"
end
local rc = tonumber(xcom.open_async(handle, port, 115200, 8, 0, 0, 0, false, false))
print(string.format("open_async(%s)=%d", port, rc))
if rc ~= xcom.ok then finish(1) end
local opened = false
for _ = 1, 50 do
    local state = xcom.get_snapshot(handle)
    if state and state.port_state == xcom.port_open then opened = true; break end
    ffi.C.Sleep(50)
end
if not opened then print("open timeout"); finish(1) end
local deadline = os.clock() + duration / 1000
local received = ""
while os.clock() < deadline do
    local status, text = xcom.drain_display(handle, 65536)
    if status == xcom.ok and text then received = received .. text end
    ffi.C.Sleep(20)
end
print("received_bytes=" .. #received)
if #received > 0 then print("received_text=" .. received:gsub("\r", "\\r"):gsub("\n", "\\n")) end
local close_status = tonumber(xcom.close(handle, 2000))
print("close=" .. tostring(close_status))
finish((close_status == xcom.ok and #received > 0) and 0 or 1)
