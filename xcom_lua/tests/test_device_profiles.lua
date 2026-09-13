-- test_device_profiles.lua - unit tests for core/device_profiles.lua and the
-- [profile] config helpers (pure Lua, run with luajit).
--
-- These call the real resolve/for_config/set_override functions, so a comment
-- edit or a deleted match branch cannot pass them.  A suite that only greps
-- source text or asserts on constants would stay green with the production
-- logic ripped out; every case here drives behaviour instead.
--
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_device_profiles.lua

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local profiles = require("device_profiles")
local config = require("config")

local passed = 0
local failed = 0
local function eq(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL  %s  (got=%s want=%s)", tostring(label),
                            tostring(got), tostring(want)))
    end
end

-- 1) table completeness: every profile must be fully usable by the sequencer
--    and the overlay, not a half-written entry.
local ids = {}
for _, p in ipairs(profiles.PROFILES) do
    ids[p.id] = true
end
for _, want in ipairs({ "ch340", "cp2102", "ft232r", "cdc_acm", "default" }) do
    eq("profile present: " .. want, ids[want], true)
end
local shape_ok = true
for _, p in ipairs(profiles.PROFILES) do
    if type(p.match) ~= "table" or type(p.reset) ~= "table"
        or (p.reset.mode ~= "auto" and p.reset.mode ~= "manual" and p.reset.mode ~= "none")
        or (p.flow_control ~= "ok" and p.flow_control ~= "warn" and p.flow_control ~= "unsupported")
        or type(p.silent_warn_ms) ~= "number" then
        shape_ok = false
    end
end
eq("all profiles well formed", shape_ok, true)

-- 2) hardware_id prefix resolution, and that it is a PREFIX not an equality
local p, src = profiles.resolve("USB\\VID_1A86&PID_7523", nil)
eq("ch340 hwid id", p.id, "ch340")
eq("ch340 hwid source", src, "hardware_id")

p, src = profiles.resolve("USB\\VID_1A86&PID_7523&REV_0264", "whatever")
eq("ch340 prefix (extra suffix)", p.id, "ch340")
eq("ch340 prefix source", src, "hardware_id")

-- case-insensitive identity (Windows ids are upper; be forgiving of lower)
p = profiles.resolve("usb\\vid_1a86&pid_7523", nil)
eq("ch340 hwid lowercase", p.id, "ch340")

p = profiles.resolve("USB\\VID_10C4&PID_EA60", nil)
eq("cp2102 hwid", p.id, "cp2102")
p = profiles.resolve("USB\\VID_0403&PID_6001", nil)
eq("ft232r hwid", p.id, "ft232r")

-- 3) identity outranks a contradictory description
p, src = profiles.resolve("USB\\VID_10C4&PID_EA60", "USB-SERIAL CH340")
eq("hwid beats desc id", p.id, "cp2102")
eq("hwid beats desc source", src, "hardware_id")

-- 4) description fallback when hardware_id is absent (design step 6 pending)
p, src = profiles.resolve(nil, "USB-SERIAL CH340")
eq("ch340 desc id", p.id, "ch340")
eq("ch340 desc source", src, "description")
p = profiles.resolve("", "Silicon Labs CP210x USB to UART Bridge")
eq("cp2102 desc", p.id, "cp2102")

-- 5) unknown identities fall to `default`; an unrecognised USB bridge is the
--    cdc_acm catch-all, NOT an auto sequence.
p, src = profiles.resolve(nil, nil)
eq("nil/nil -> default id", p.id, "default")
eq("nil/nil -> default source", src, "default")
p, src = profiles.resolve("ACPI\\PNP0501", "Communications Port")
eq("non-usb unknown -> default", p.id, "default")
eq("non-usb unknown source", src, "default")
p = profiles.resolve("USB\\VID_9999&PID_0001", nil)
eq("unknown usb -> cdc_acm", p.id, "cdc_acm")

-- 6) an explicit profile id wins over any inferred match
p, src = profiles.resolve("USB\\VID_1A86&PID_7523", nil, "cp2102")
eq("override id wins", p.id, "cp2102")
eq("override source", src, "override")
-- a bogus override id must not shadow the real identity match
p, src = profiles.resolve("USB\\VID_1A86&PID_7523", nil, "no-such-profile")
eq("bogus override falls through", p.id, "ch340")
eq("bogus override source", src, "hardware_id")

-- 7) config [profile] helpers round-trip
local blob = { [""] = {} }
config.set_profile(blob, "USB\\VID_1A86&PID_7523", "custom",
                   { flow_control = "unsupported", ["reset.mode"] = "manual" })
local sec, custom = config.get_profile(blob)
eq("get_profile key", sec.key, "USB\\VID_1A86&PID_7523")
eq("get_profile mode", sec.mode, "custom")
eq("custom dotted key", custom["reset.mode"], "manual")
eq("custom flat key", custom.flow_control, "unsupported")
-- get_profile on an empty blob yields empty tables, never nil
local esec, ecustom = config.get_profile({ [""] = {} })
eq("empty get_profile sec is table", type(esec), "table")
eq("empty get_profile custom is table", type(ecustom), "table")

-- 8) set_override -> for_config round trip, with a deep merge that must not
--    drop the untouched base fields
local cfg = { [""] = {} }
profiles.set_override(cfg, "USB\\VID_1A86&PID_7523",
    { reset = { mode = "manual" }, flow_control = "unsupported", silent_warn_ms = 8000 })
eq("stored key", cfg["profile"].key, "USB\\VID_1A86&PID_7523")
eq("stored mode", cfg["profile"].mode, "custom")
eq("stored flat reset.mode", cfg["profile.custom"]["reset.mode"], "manual")
eq("stored flat silent_warn_ms", cfg["profile.custom"]["silent_warn_ms"], 8000)

local rp, rsrc = profiles.for_config(cfg,
    { hardware_id = "USB\\VID_1A86&PID_7523", description = "USB-SERIAL CH340" })
eq("for_config id", rp.id, "ch340")
eq("for_config source", rsrc, "custom")
eq("override reset.mode", rp.reset.mode, "manual")
eq("override flow_control", rp.flow_control, "unsupported")
eq("override silent_warn_ms", rp.silent_warn_ms, 8000)
-- deep merge kept the base sequence fields
eq("base edges survive", type(rp.reset.edges), "table")
eq("base reenumerates survive", rp.reset.reenumerates, true)

-- the module-level table must NOT have been mutated by the override
local base = profiles.resolve("USB\\VID_1A86&PID_7523", nil)
eq("base profile unmuted flow_control", base.flow_control, "warn")
eq("base profile unmuted reset.mode", base.reset.mode, "auto")
eq("patched profile is a copy", rawequal(rp, base), false)

-- a custom entry bound to one key must not leak onto another device
local other, osrc = profiles.for_config(cfg, { hardware_id = "USB\\VID_10C4&PID_EA60" })
eq("custom keyed to ch340", other.id, "cp2102")
eq("other device source", osrc, "hardware_id")
eq("other device flow_control", other.flow_control, "warn")

-- 9) the override survives a serialize/parse round trip (persistence)
local tmp = os.tmpname()
config.save(tmp, cfg)
local reloaded = config.load(tmp)
local pp, psrc = profiles.for_config(reloaded,
    { hardware_id = "USB\\VID_1A86&PID_7523" })
eq("persisted source", psrc, "custom")
eq("persisted flow_control", pp.flow_control, "unsupported")
eq("persisted reset.mode", pp.reset.mode, "manual")
os.remove(tmp)

-- 10) an empty-key custom entry applies unconditionally (no recorded key)
local cfg2 = { [""] = {} }
profiles.set_override(cfg2, nil, { flow_control = "unsupported" })
local up = profiles.for_config(cfg2, { hardware_id = "USB\\VID_0403&PID_6001" })
eq("empty-key override applies", up.flow_control, "unsupported")
eq("empty-key source", select(2, profiles.for_config(cfg2,
    { hardware_id = "USB\\VID_0403&PID_6001" })), "custom")

print(string.format("\ndevice_profiles tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
