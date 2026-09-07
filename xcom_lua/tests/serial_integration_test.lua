-- Integration test for the open -> send -> rx-pipeline -> close contract.
-- Usage:
--   runtime\luajit.exe tests\serial_integration_test.lua            (VIRTUAL)
--   runtime\luajit.exe tests\serial_integration_test.lua COM4       (hardware)
--
-- Default port is the hardware-free VIRTUAL session (xcom_abi.cpp
-- is_virtual_port): it opens in-process with no serial backend.  TX semantics
-- on VIRTUAL are acceptance-only (xcom_core.cpp owner_write: the payload is
-- consumed, tx_bytes counts; nothing reaches a wire and nothing echoes back),
-- so the display assertion below is fed by xcom_test_inject_rx -- the very
-- seam the real rx callback shares.  Pass a COM name to run the same checks
-- against physical hardware.

local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/serial_integration_test.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root = tests_dir:gsub("[/\\]$", "") .. "/.."
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")

local port = (arg and arg[1]) or "VIRTUAL"
local handle, err = xcom.create()
assert(handle, err)
local function finish(code)
    xcom.destroy(handle)
    os.exit(code or 0)
end

local rc = tonumber(xcom.open_async(handle, port, 115200, 8, 0, 0, 0, false, false))
print(string.format("open_async(%s)=%d", port, rc))
if rc ~= xcom.ok then finish(1) end

local opened = false
for _ = 1, 40 do
    local state = xcom.get_snapshot(handle)
    if state and state.port_state == xcom.port_open then
        opened = true
        break
    end
    local result = tonumber(xcom.take_open_result(handle))
    if result ~= xcom.err_busy and result ~= xcom.ok then
        print("open result=" .. tostring(result))
        break
    end
    ffi.C.Sleep(50)
end
if not opened then
    print("open failed or timed out")
    finish(1)
end
print("port state=open")

local payload = "XCOM_TEST\r\n"
print("send=" .. tostring(tonumber(xcom.send(handle, payload, xcom.send_text))))
print("inject=" .. tostring(tonumber(xcom.test_inject_rx(handle, payload, #payload))))

local received = ""
for _ = 1, 40 do
    local status, text = xcom.drain_display(handle, 65536)
    if status == xcom.ok and text then
        received = received .. text
        if #received >= #payload then break end
    end
    ffi.C.Sleep(25)
end
print("receive=" .. (received:find("XCOM_TEST", 1, true) and "ok" or "timeout"))
local close_status = tonumber(xcom.close(handle, 2000))
print("close=" .. tostring(close_status))
finish((close_status == xcom.ok and received:find("XCOM_TEST", 1, true)) and 0 or 1)
