-- Send the literal help command with LF and print the real device response.
-- Usage: runtime\luajit.exe tests\send_help_test.lua COM3
--
-- NOT convertible to the VIRTUAL session: the whole point is the peer's TEXT
-- REPLY to a physical send.  VIRTUAL TX is acceptance-only (xcom_core.cpp
-- owner_write counts tx_bytes and drops the payload -- no wire, no peer, no
-- echo), so response_bytes would always be 0 and a green exit would be
-- vacuous.  With no COM port argument on a host without hardware it prints an
-- explicit SKIP (exit 0); pass a COM name wired to a real device to run it.
local ffi = require("ffi")
ffi.cdef[[void Sleep(unsigned long ms);]]
local script = (arg and arg[0]) or "tests/send_help_test.lua"
local dir = script:match("^(.*)[/\\]") or "."
local root = dir:gsub("[/\\]$", "") .. "/.."
package.path = root .. "/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")
local port = (arg and arg[1])
local handle, err = xcom.create()
assert(handle, err)
local function finish(code)
    xcom.destroy(handle)
    os.exit(code or 0)
end
-- VIRTUAL/TEST sessions cannot produce a device reply: skip explicitly.
if port and (port == "VIRTUAL" or port:sub(1, 4) == "TEST") then
    print("SKIP " .. port .. ": requires physical COM loopback (VIRTUAL TX is acceptance-only)")
    finish(0)
end
if not port then
    -- No COM given: only auto-skip when the host really has no ports;
    -- otherwise keep the original COM3 default unchanged.
    local ports = xcom.list_ports()
    if #ports == 0 then
        print("SKIP (no COM port enumerated): requires physical COM loopback (device reply expected)")
        finish(0)
    end
    port = "COM3"
end
local rc = tonumber(xcom.open_async(handle, port, 115200, 8, 0, 0, 0, false, false))
print("open_async=" .. tostring(rc))
if rc ~= xcom.ok then finish(1) end
local opened = false
for _ = 1, 50 do
    local state = xcom.get_snapshot(handle)
    if state and state.port_state == xcom.port_open then opened = true; break end
    ffi.C.Sleep(50)
end
if not opened then print("open timeout"); finish(1) end
local command = "help\n"
print("send_help=" .. tostring(tonumber(xcom.send(handle, command, xcom.send_text))))
local response = ""
for _ = 1, 150 do
    local status, text = xcom.drain_display(handle, 65536)
    if status == xcom.ok and text then response = response .. text end
    ffi.C.Sleep(20)
end
print("response_bytes=" .. #response)
if #response > 0 then print(response:gsub("\r", "\\r"):gsub("\n", "\\n")) end
local close_status = tonumber(xcom.close(handle, 2000))
print("close=" .. tostring(close_status))
finish(close_status == xcom.ok and 0 or 1)
