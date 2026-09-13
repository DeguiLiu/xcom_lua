-- test_open_line_tristate.lua - open-time DTR/RTS tri-state contract.
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_open_line_tristate.lua
--
-- Covers the UI-index -> XCOM_LINE_* mapping and the persisted default/migration
-- helper (both pure, in core/xcom_ffi.lua), and the [serial] dtr_open/rts_open
-- config round-trip through core/config.lua.  No DLL / Win32 is needed.

package.path = "./core/?.lua;./ui/?.lua;../xcom_lua/core/?.lua;" .. package.path
local xcom = require("xcom_ffi")
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

-- 1) constants and the shared dropdown item contract.  Index order MUST equal
--    the ABI enum, otherwise the combo index and XCOM_LINE_* drift apart.
eq("deassert const", xcom.line_deassert, 0)
eq("assert const", xcom.line_assert, 1)
eq("leave-alone const", xcom.line_leave_alone, 2)
eq("three UI items", #xcom.OPEN_LINE_ITEMS, 3)
eq("item 0 is deassert", xcom.OPEN_LINE_ITEMS[1], "Deassert")
eq("item 1 is assert", xcom.OPEN_LINE_ITEMS[2], "Assert")
eq("item 2 is leave alone", xcom.OPEN_LINE_ITEMS[3], "Leave alone")

-- 2) line_from_ui_index: in-range pass-through, bool back-compat, and the safe
--    fallback for missing/garbage selections.
eq("index 0", xcom.line_from_ui_index(0), 0)
eq("index 1", xcom.line_from_ui_index(1), 1)
eq("index 2 survives", xcom.line_from_ui_index(2), 2)
eq("string index", xcom.line_from_ui_index("2"), 2)
eq("bool true -> assert", xcom.line_from_ui_index(true), 1)
eq("bool false -> deassert", xcom.line_from_ui_index(false), 0)
eq("nil -> leave alone", xcom.line_from_ui_index(nil), 2)
eq("unselected combo (-1) -> leave alone", xcom.line_from_ui_index(-1), 2)
eq("out of range 3 -> leave alone", xcom.line_from_ui_index(3), 2)
eq("garbage -> leave alone", xcom.line_from_ui_index("nope"), 2)

-- 3) open_line_default: explicit value wins (must NOT collapse 2), legacy bool
--    migrates, and an absent setting is the safe leave-alone default.
eq("explicit 0 wins", xcom.open_line_default(0, true), 0)
eq("explicit 2 beats legacy true", xcom.open_line_default(2, true), 2)
eq("legacy true -> assert", xcom.open_line_default(nil, true), 1)
eq("legacy false -> deassert", xcom.open_line_default(nil, false), 0)
eq("absent -> leave alone", xcom.open_line_default(nil, nil), 2)

-- 4) config round-trip: all three values survive save/load as numbers.
local blob = { [""] = {}, serial = { dtr_open = 2, rts_open = 0 } }
local path = os.tmpname()
config.save(path, blob)
local back = config.load(path)
eq("rt dtr_open 2", back["serial"].dtr_open, 2)
eq("rt rts_open 0", back["serial"].rts_open, 0)
os.remove(path)

local blob2 = { [""] = {}, serial = { dtr_open = 1, rts_open = 2 } }
local path2 = os.tmpname()
config.save(path2, blob2)
local back2 = config.load(path2)
eq("rt dtr_open 1", back2["serial"].dtr_open, 1)
eq("rt rts_open 2", back2["serial"].rts_open, 2)
-- A missing key is nil (not coerced), so the loader's default path runs.
eq("missing key stays nil", back2["serial"].no_such_key, nil)
os.remove(path2)

-- 5) a config that only has the legacy booleans resolves to 0/1 via the shared
--    default helper (the main.lua migration path).
eq("legacy false config", xcom.open_line_default(
    config.get(back2, "serial", "dtr_open", nil),
    config.get(back2, "serial", "dtr_enable", false)), 1)

print(string.format("\nopen_line_tristate: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
