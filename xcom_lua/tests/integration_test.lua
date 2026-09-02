-- Windows integration test for the packaged LuaJIT + xcom_core runtime.
-- Run from xcom_lua:  runtime\luajit.exe tests\integration_test.lua

local script = (arg and arg[0]) or "tests/integration_test.lua"
local tests_dir = script:match("^(.*)[/\\]") or "."
local root = tests_dir:gsub("[/\\]$", "") .. "/.."
package.path = root .. "/core/?.lua;" .. package.path

local xcom = require("xcom_ffi")
local passed, failed = 0, 0

local function check(label, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        io.stderr:write("FAIL  " .. label .. "\n")
    end
end

local handle, create_error = xcom.create()
check("core create", handle ~= nil)
if not handle then
    io.stderr:write("create error: " .. tostring(create_error) .. "\n")
    os.exit(1)
end

local snapshot = xcom.get_snapshot(handle)
check("initial snapshot", snapshot ~= nil)
check("initial state closed", snapshot and snapshot.port_state == xcom.port_closed)

local ports = xcom.list_ports()
check("port enumeration", type(ports) == "table")

local send_status = tonumber(xcom.send(handle, "integration", xcom.send_text))
check("send rejects closed session", send_status == xcom.err_not_open)

local option_status = tonumber(xcom.set_options(handle, {
    hex_view = false,
    timestamp = true,
    pause_display = false,
    auto_clear_bytes = 0,
    max_display_bytes = 2 * 1024 * 1024,
}))
check("set display options", option_status == xcom.ok)

local log_path = root .. "/integration-test.log"
os.remove(log_path)
local open_status = tonumber(xcom.log_open(handle, log_path, false))
check("open log", open_status == xcom.ok)
if open_status == xcom.ok then
    local payload = "integration-log\r\n"
    check("append log", tonumber(xcom.log_append(handle, payload, #payload)) == xcom.ok)
    check("flush log", tonumber(xcom.log_flush(handle, 2000)) == xcom.ok)
    check("close log", tonumber(xcom.log_close(handle, 2000)) == xcom.ok)
    local file = io.open(log_path, "rb")
    local contents = file and file:read("*a") or ""
    if file then file:close() end
    check("log contents", contents == payload)
end
os.remove(log_path)

xcom.destroy(handle)
print(string.format("integration tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
