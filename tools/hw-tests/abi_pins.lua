-- Observe the real ABI values from the freshly built xcom_core.dll.
-- The module's struct-size assertion runs at require() time.
local ffi = require("ffi")

package.path = "D:/workspace/e2e2/xcom_lua/xcom_lua/core/?.lua;" .. package.path

local x = require("xcom_ffi")

-- Optional: load a specific DLL instead of the one the module resolves.
local dll_arg = arg and arg[1]
local lib
if dll_arg then
    local ok, h = pcall(ffi.load, dll_arg)
    lib = ok and h or nil
    if lib == nil then
        print("FATAL: could not load " .. dll_arg)
        os.exit(2)
    end
else
    lib = x.load()
end
if lib == nil then
    print("FATAL: xcom_core.dll did not load")
    os.exit(2)
end

print("dll = " .. tostring(dll_arg or "module-resolved"))

-- When a specific DLL is loaded, bind the symbols from it directly.
local version_fn = dll_arg and lib.xcom_version or x.version

print(string.format("xcom_version()                      = 0x%06X  (decimal %d)",
                    version_fn(), version_fn()))
print(string.format("sizeof(XcomSnapshot)                = %d", ffi.sizeof("XcomSnapshot")))
print(string.format("sizeof(XcomPortInfo)                = %d", ffi.sizeof("XcomPortInfo")))
print(string.format("offsetof(XcomSnapshot,flow_hold_events) = %d",
                    ffi.offsetof("XcomSnapshot", "flow_hold_events")))
print(string.format("sizeof(XcomPortConfig)              = %d", ffi.sizeof("XcomPortConfig")))
print(string.format("sizeof(XcomError)                   = %d", ffi.sizeof("XcomError")))

print("module SIZEOF pins: snapshot=" .. tostring(x.SIZEOF.snapshot) ..
      " port_info=" .. tostring(x.SIZEOF.port_info))

local expect_version = 0x010600
local expect_snapshot = 84
local expect_portinfo = 420
local expect_flowoff = 80

local ok = true
local function check(label, got, want)
    local pass = (got == want)
    if not pass then ok = false end
    print(string.format("%-34s got=%-6s want=%-6s %s", label, tostring(got), tostring(want),
                        pass and "OK" or "MISMATCH"))
end

check("xcom_version()", version_fn(), expect_version)
check("sizeof(XcomSnapshot)", ffi.sizeof("XcomSnapshot"), expect_snapshot)
check("sizeof(XcomPortInfo)", ffi.sizeof("XcomPortInfo"), expect_portinfo)
check("offsetof(flow_hold_events)", ffi.offsetof("XcomSnapshot", "flow_hold_events"), expect_flowoff)

os.exit(ok and 0 or 1)
