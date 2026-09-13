-- Enumerate ports with the active occupancy probe and report each port's
-- `busy` flag - the field xcom.h documents as "1 = currently open by another
-- handle", and the classification the cause table relies on.
--
-- NOTE: the probe opens every enumerated port, which drives modem lines and can
-- reset an auto-reset target.  xcom_ffi keeps it off unless asked, for that
-- reason; this script asks deliberately.
-- Usage (from xcom_lua/):  runtime\luajit.exe ..\..\hw\list_probe.lua
package.path = "./core/?.lua;" .. package.path
local x = require("xcom_ffi")

local ports, native_error = x.list_ports({ probe = true })
print(string.format("enumerated %d port(s); native_error=%s", #ports, tostring(native_error)))
for _, p in ipairs(ports) do
    print(string.format("  %-8s busy=%s  desc=%s", p.name, tostring(p.busy), tostring(p.description)))
    print(string.format("           hardware_id=%s", tostring(p.hardware_id)))
end
