-- test_runtime_bundle.lua - assert the DLL that SHIPS is the ABI the client pins.
--
-- Why this exists: xcom_lua/runtime/ is a checked-in bundle (runtime/README.md)
-- and xcom_ffi.load() prefers it over a local build, so the committed
-- xcom_core.dll - not the CMake output - is what a user without a compiler
-- actually runs.  That DLL once drifted: it was still v1.3 while the client
-- pinned v1.6, so it lacked xcom_list_ports_ex / xcom_set_lines /
-- xcom_drain_display_ts and the documented integration check died on the first
-- port enumeration with "cannot resolve symbol 'xcom_list_ports_ex'".
-- No C++ ctest can see this: those tests link the freshly built DLL, never the
-- bundle that is actually distributed.  build_release.ps1's gate compares the
-- core DLL by SIZE, which a same-size different build passes; this check asks
-- the DLL what ABI it implements.
--
-- Usage (from xcom_lua/):  runtime\luajit.exe tests\test_runtime_bundle.lua
-- Exits 0 when the bundle matches, 1 on any mismatch, and 0 (SKIP) on a host
-- with no DLL, so it stays runnable from the Linux CI side.

package.path = "./core/?.lua;" .. package.path
local x = require("xcom_ffi")

local passed, failed = 0, 0
local function eq(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL  %s  (got=%s want=%s)", tostring(label),
                            tostring(got), tostring(want)))
    end
end
local function ok(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label)
    end
end

local lib = x.load()
if lib == nil then
    print("SKIP test_runtime_bundle: no xcom_core.dll on this host")
    os.exit(0)
end

local want = x.packed_version()
local got = x.version()
print(string.format("resolved DLL xcom_version() = 0x%06X   client pin = 0x%06X",
                    got, want))
if got ~= want then
    print("HINT  a mismatched version here means runtime/xcom_core.dll is a stale")
    print("HINT  build output.  Rebuild xcom_core and copy it over the bundle.")
end
eq("bundled DLL reports the pinned ABI version", got, want)

-- Optional exports.  The client probes these and degrades when they are
-- missing, so their absence is not fatal - but it silently drops capabilities
-- (error-aware port enumeration, DTR/RTS control, timestamped display drain),
-- which is exactly how the stale bundle went unnoticed.  In a shipped bundle
-- they must all be present.
for _, name in ipairs({ "xcom_list_ports_ex", "xcom_set_lines",
                        "xcom_drain_display_ts" }) do
    ok("bundle exports " .. name, pcall(function() return lib[name] end))
end

print(string.format("\ntest_runtime_bundle: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
