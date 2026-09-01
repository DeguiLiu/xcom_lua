-- test_view_model.lua - unit tests for core/view_model.lua (pure Lua)
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_view_model.lua
-- Mirrors the behaviour asserted by xcom_client's SerialUiHsm/ViewModel
-- (app/view_model.py), including the interlock semantics.

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local vm_mod = require("view_model")

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
local function ok(label, cond)
    if cond then passed = passed + 1 else failed = failed + 1; print("FAIL  " .. label) end
end

-- 1) initial state: CLOSED / OFFLINE, params enabled, open allowed, close not.
local hsm = vm_mod.new_hsm()
eq("initial state", hsm.state, vm_mod.STATE_CLOSED)
eq("initial super", hsm:super_state(), vm_mod.SUPER_OFFLINE)
ok("can_open initially", hsm:can_open())
ok("cannot_close initially", not hsm:can_close())

-- 2) intent_open transitions to OPENING (transitional); a second intent_open
--    fails because OPENING is not in the allowed-start set for "open".
ok("intent_open succeeds from CLOSED", hsm:intent_open())
eq("state after intent_open", hsm.state, vm_mod.STATE_OPENING)
eq("super after intent_open", hsm:super_state(), vm_mod.SUPER_TRANSITIONAL)
ok("cannot re-open while OPENING", not hsm:can_open())
ok("can close while OPENING", hsm:can_close())

-- 3) reject_open rolls back to CLOSED (queue-full / rejected before worker).
ok("reject_open from OPENING", hsm:reject_open())
eq("state after reject_open", hsm.state, vm_mod.STATE_CLOSED)
ok("reject_open no-op elsewhere", not hsm:reject_open())

-- 4) authoritative on_port_state drives OPEN; generation guards stale signals.
local hsm2 = vm_mod.new_hsm()
hsm2:intent_open()
ok("on_port_state OPEN gen=1", hsm2:on_port_state(2, 1))  -- CORE_OPEN=2
eq("state OPEN", hsm2.state, vm_mod.STATE_OPEN)
eq("super ONLINE", hsm2:super_state(), vm_mod.SUPER_ONLINE)
ok("stale generation rejected", not hsm2:on_port_state(0, 0))  -- gen 0 < 1
eq("state unchanged by stale signal", hsm2.state, vm_mod.STATE_OPEN)
ok("same state+gen is a no-op (returns false)", not hsm2:on_port_state(2, 1))

-- 5) can_close while OPEN/OPENING/FAULT; NOT while CLOSED/CLOSING.
ok("can_close while OPEN", hsm2:can_close())
ok("intent_close from OPEN", hsm2:intent_close())
eq("state CLOSING", hsm2.state, vm_mod.STATE_CLOSING)
ok("cannot open while CLOSING", not hsm2:can_open())
-- Python's _ALLOWED_START["close"] = {OPEN, OPENING, FAULT} does NOT include
-- CLOSING: a close already in flight cannot be re-issued (no double-close).
ok("cannot re-close while already CLOSING", not hsm2:can_close())

-- 6) force_fault only from a transitional state (OPENING/CLOSING).
ok("force_fault from CLOSING", hsm2:force_fault())
eq("state FAULT", hsm2.state, vm_mod.STATE_FAULT)
eq("super OFFLINE on FAULT", hsm2:super_state(), vm_mod.SUPER_OFFLINE)
ok("can_open from FAULT", hsm2:can_open())
ok("can_close from FAULT", hsm2:can_close())

local hsm3 = vm_mod.new_hsm()
ok("force_fault no-op from CLOSED", not hsm3:force_fault())

-- 7) ViewModel: params_enabled only OFFLINE; send/autosend only OPEN.
local vm = vm_mod.new()
local state = vm:ui_state()
ok("params_enabled initially", state.params_enabled)
ok("open_enabled initially", state.open_enabled)
ok("close_enabled false initially", not state.close_enabled)
ok("send_enabled false initially", not state.send_enabled)

vm:intent_open()
state = vm:ui_state()
ok("params disabled while OPENING", not state.params_enabled)
ok("send disabled while OPENING", not state.send_enabled)

vm:on_port_state(2, 1)  -- CORE_OPEN
state = vm:ui_state()
ok("connected true when OPEN", state.connected)
ok("send_enabled true when OPEN", state.send_enabled)
ok("autosend_enabled true when OPEN", state.autosend_enabled)
ok("params still disabled when OPEN", not state.params_enabled)
eq("port_state_code OPEN", state.port_state_code, 2)

-- 8) on_snapshot: stale generation rejected; identical snapshot+state -> false.
local vm2 = vm_mod.new()
vm2:intent_open()
ok("on_snapshot accepts first OPEN", vm2:on_snapshot({ port_state = 2, generation = 1, rx_bytes = 0 }))
ok("on_snapshot stale generation rejected",
   not vm2:on_snapshot({ port_state = 0, generation = 0, rx_bytes = 0 }))
ok("on_snapshot identical is no-op",
   not vm2:on_snapshot({ port_state = 2, generation = 1, rx_bytes = 0 }))
ok("on_snapshot changed field triggers re-render",
   vm2:on_snapshot({ port_state = 2, generation = 1, rx_bytes = 42 }))

print(string.format("\nview_model tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
