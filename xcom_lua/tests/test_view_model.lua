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

-- =========================================================================
-- Exception matrix: reconnect grace window (RECONNECTING) and the missing
-- abnormal transitions the original HSM did not model.
-- =========================================================================

-- 9) Grace window: a fault while OPEN enters RECONNECTING, not FAULT.
--    Send/params/close interlock mirrors OFFLINE; open is refused so the user
--    cannot race the watchdog.
local g = vm_mod.new()
g:intent_open()
g:on_port_state(2, 1)                       -- OPEN
ok("fault enters grace window", g:enter_reconnecting(2))
eq("state RECONNECTING", g.hsm.state, vm_mod.STATE_RECONNECTING)
eq("grace super state OFFLINE", g.hsm:super_state(), vm_mod.SUPER_OFFLINE)
local gs = g:ui_state()
ok("grace: send disabled", not gs.send_enabled)
ok("grace: autosend disabled", not gs.autosend_enabled)
ok("grace: connected false", not gs.connected)
ok("grace: close allowed (user abort)", gs.close_enabled)
ok("grace: open refused (no race)", not gs.open_enabled)
ok("grace: params editable", gs.params_enabled)
ok("grace: reconnecting flag set", gs.reconnecting)
ok("grace: faulted flag clear", not gs.faulted)
eq("grace: port_state_code reports core FAULT", gs.port_state_code, 4)
-- 8 s, not 3: the target devices reboot into a ROM bootloader, which is a full
-- USB detach/re-enumerate that takes several seconds to come back. A 3 s window
-- expired just before the device returned, so every ROM-mode switch ended in
-- FAULT. [serial] reconnect_grace_ms overrides it (see Window:new).
eq("grace: banner timeout constant", gs.reconnect_timeout_ms, 8000)
ok("enter_reconnecting is not re-entrant", not g:enter_reconnecting(2))

-- 10) Grace window never loses the FAULT: a FAULT snapshot inside the window
--     keeps RECONNECTING (the core stays faulted for the whole window).
ok("FAULT snapshot during grace stays RECONNECTING",
   g:on_port_state(4, 3))
eq("still RECONNECTING after FAULT snapshot", g.hsm.state, vm_mod.STATE_RECONNECTING)

-- 11) Recovery: an OPEN snapshot inside the window is latched, not adopted;
--     settle dips to the latched state once.
ok("OPEN snapshot during grace latched", g:on_port_state(2, 4))
eq("still RECONNECTING before settle", g.hsm.state, vm_mod.STATE_RECONNECTING)
ok("settle_recovering confirms recovery", g:settle_recovering())
eq("state OPEN after settle", g.hsm.state, vm_mod.STATE_OPEN)
ok("settle is edge-triggered (no-op again)", not g:settle_recovering())
eq("post-recovery super state ONLINE", g.hsm:super_state(), vm_mod.SUPER_ONLINE)
local gs2 = g:ui_state()
ok("post-recovery send enabled", gs2.send_enabled)
ok("post-recovery connected", gs2.connected)
ok("post-recovery reconnecting flag clear", not gs2.reconnecting)

-- 12) Timeout: no recovery inside the window -> FAULT, manual reconnect only.
local t = vm_mod.new()
t:intent_open()
t:on_port_state(2, 1)
t:enter_reconnecting(2)
ok("reconnect_timeout fires", t:reconnect_timeout())
eq("state FAULT after timeout", t.hsm.state, vm_mod.STATE_FAULT)
ok("can_open after timeout", t.hsm:can_open())
ok("can_close after timeout", t.hsm:can_close())
ok("reconnect_timeout no-op outside grace", not t:reconnect_timeout())
-- A FAULT snapshot after timeout must NOT be swallowed back into RECONNECTING.
ok("FAULT after timeout keeps FAULT", t:on_port_state(4, 3))
eq("state FAULT after FAULT snapshot", t.hsm.state, vm_mod.STATE_FAULT)

-- 13) Grace window reached from a transitional state (fault while OPENING).
local g2 = vm_mod.new()
g2:intent_open()
ok("grace from OPENING", g2:enter_reconnecting(1))
eq("RECONNECTING from OPENING", g2.hsm.state, vm_mod.STATE_RECONNECTING)

-- 14) Grace window rejected when the session is genuinely offline.
local g3 = vm_mod.new()
ok("grace refused from CLOSED", not g3:enter_reconnecting())
local g4 = vm_mod.new()
g4:force_fault()  -- from nothing: no-op
g4:intent_open(); g4:force_fault()      -- OPENING -> FAULT
ok("force_fault reached FAULT for the refusal case", g4.hsm.state == vm_mod.STATE_FAULT)
ok("grace re-arms from FAULT (repeated fault edge)", g4:enter_reconnecting(2))
eq("RECONNECTING from FAULT", g4.hsm.state, vm_mod.STATE_RECONNECTING)

-- 15) User retry inside the grace window: intent_close wins (abort recovery).
local u = vm_mod.new()
u:intent_open(); u:on_port_state(2, 1); u:enter_reconnecting(2)
ok("user can close during grace", u:intent_close())
eq("CLOSING after grace abort", u.hsm.state, vm_mod.STATE_CLOSING)
ok("reject_close rolls back to grace, not FAULT", u:reject_close())
eq("RECONNECTING after reject_close", u.hsm.state, vm_mod.STATE_RECONNECTING)

-- 16) A rejected retry open must return to the state the retry was issued
--     from, not strand the user in CLOSED.
local r = vm_mod.new()
r:intent_open(); r:on_port_state(2, 1); r:enter_reconnecting(2); r:reconnect_timeout()
ok("retry open accepted from FAULT", r:intent_open())
eq("OPENING after retry", r.hsm.state, vm_mod.STATE_OPENING)
ok("reject_open restores FAULT", r:reject_open())
eq("FAULT restored after rejected FAULT retry", r.hsm.state, vm_mod.STATE_FAULT)
ok("clean reject_open still lands CLOSED", (function()
    local c = vm_mod.new()
    c:intent_open()
    return c:reject_open() and c.hsm.state == vm_mod.STATE_CLOSED
end)())

-- 17) Generation guard while recovering: a stale OPEN from the pre-fault
--     session must not settle the window, and it must not un-latch either.
local s = vm_mod.new()
s:intent_open(); s:on_port_state(2, 5); s:enter_reconnecting(6)
ok("stale OPEN (gen 4) rejected during grace", not s:on_port_state(2, 4))
eq("grace gen unchanged", s.hsm.generation, 6)
ok("stale does not settle", not s:settle_recovering())
eq("still RECONNECTING after stale", s.hsm.state, vm_mod.STATE_RECONNECTING)
-- A fresh non-fault generation during the window latches and settles.
ok("fresh OPEN (gen 7) accepted during grace", s:on_port_state(2, 7))
ok("fresh OPEN settles", s:settle_recovering())
eq("OPEN after fresh settle", s.hsm.state, vm_mod.STATE_OPEN)

-- 18) Snapshot-driven grace: on_snapshot(FAULT) while OPEN must NOT tear the
--     session down by itself (the caller decides the grace window); once the
--     watchdog is armed the same snapshot is folded into RECONNECTING.
local sv = vm_mod.new()
sv:intent_open(); sv:on_snapshot({ port_state = 2, generation = 1 })
ok("snapshot FAULT while OPEN is a plain FAULT state", sv:on_snapshot({ port_state = 4, generation = 2 }))
eq("FAULT before watchdog", sv.hsm.state, vm_mod.STATE_FAULT)
-- FAULT can re-arm the window (repeated fault edge), then FAULT snapshots hold.
sv:enter_reconnecting(2)
-- Re-verify with a clean session: OPEN -> snapshot FAULT -> enter grace.
local sv2 = vm_mod.new()
sv2:intent_open(); sv2:on_snapshot({ port_state = 2, generation = 1 })
sv2:enter_reconnecting(2)
ok("snapshot FAULT during grace stays RECONNECTING",
   sv2:on_snapshot({ port_state = 4, generation = 3 }))
eq("grace held across snapshot", sv2.hsm.state, vm_mod.STATE_RECONNECTING)
-- A field-only change in the same snapshot still triggers a re-render.
ok("field-only snapshot during grace re-renders",
   sv2:on_snapshot({ port_state = 4, generation = 3, rx_bytes = 9 }))

-- 19) Port list refresh / core reset while in grace: a CLOSED snapshot at the
--     same or a later generation is our own reset-in-progress and must neither
--     tear the window down nor be adopted as "recovered".
local p = vm_mod.new()
p:intent_open(); p:on_port_state(2, 1); p:enter_reconnecting(2)
ok("CLOSED snapshot during grace latches (does not tear down)",
   p:on_port_state(0, 2))
eq("still RECONNECTING after CLOSED latch", p.hsm.state, vm_mod.STATE_RECONNECTING)
ok("settle refuses CLOSED (reset, not recovery)",
   not (p:on_port_state(0, 3) and p:settle_recovering()))
eq("still RECONNECTING after refused CLOSED settle", p.hsm.state, vm_mod.STATE_RECONNECTING)
-- A later real OPEN does settle it.
ok("OPEN after reset settles", p:on_port_state(2, 4) and p:settle_recovering())
eq("OPEN after reset settle", p.hsm.state, vm_mod.STATE_OPEN)

-- 20) End-to-end window sequence: OPEN -> fault -> grace -> core reset
--     (CLOSED) -> reopen queued (OPENING) -> OPEN -> settle. The CLOSED and
--     OPENING snapshots must NOT settle the window; only a confirmed OPEN does.
local e = vm_mod.new()
e:intent_open(); e:on_snapshot({ port_state = 2, generation = 1 })   -- OPEN
e:enter_reconnecting(2)                                              -- fault edge
ok("reset CLOSED during grace does not settle",
   e:on_snapshot({ port_state = 0, generation = 3 }) == true)
eq("still RECONNECTING after reset CLOSED", e.hsm.state, vm_mod.STATE_RECONNECTING)
ok("no settle on CLOSED", not e:settle_recovering())
ok("reopen OPENING during grace is latched, not settled",
   e:on_snapshot({ port_state = 1, generation = 4 }))
eq("still RECONNECTING while OPENING", e.hsm.state, vm_mod.STATE_RECONNECTING)
ok("reopen OPEN confirms recovery", e:on_snapshot({ port_state = 2, generation = 5 }))
ok("settle adopts OPEN", e:settle_recovering())
eq("OPEN after settle", e.hsm.state, vm_mod.STATE_OPEN)
ok("send re-enabled after recovery", e:ui_state().send_enabled)

-- 21) Device unplugged during CLOSE: CLOSING -> force_fault -> FAULT, and a
--     later fault edge may still arm the grace window (unplug while closing is
--     a legitimate fault even though the user asked to close).
local c2 = vm_mod.new()
c2:intent_open(); c2:on_port_state(2, 1); c2:intent_close()
eq("CLOSING before fault", c2.hsm.state, vm_mod.STATE_CLOSING)
ok("fault during CLOSE forces FAULT", c2:force_fault())
eq("FAULT after close-time fault", c2.hsm.state, vm_mod.STATE_FAULT)
ok("fault edge after close-time fault arms grace", c2:enter_reconnecting(5))
eq("RECONNECTING after close-time fault edge", c2.hsm.state, vm_mod.STATE_RECONNECTING)

-- 22) User close during grace is a legal abort; a subsequent open intent is
--     refused while the close is in flight (no reopening into a half-closed
--     core), and reject_close restores RECONNECTING for the watchdog.
local c3 = vm_mod.new()
c3:intent_open(); c3:on_port_state(2, 1); c3:enter_reconnecting(2)
ok("user close during grace", c3:intent_close())
ok("open refused while closing during grace", not c3:intent_open())
ok("reject_close during grace restores RECONNECTING", c3:reject_close())
eq("RECONNECTING restored", c3.hsm.state, vm_mod.STATE_RECONNECTING)

-- 23) Grace window generation hole: the session generation does NOT advance on
--     a core fault (xcom_ao.cpp serial_do_fault), so enter_reconnecting() is
--     armed at the *same* generation as the pre-fault OPEN.  A stale OPEN
--     notification from that session (async signal / re-delivered snapshot)
--     must NOT be mistaken for recovery.  Only a strictly newer generation --
--     which is what the driver's own close()+open() produces (each bumps the
--     generation) -- may latch a recovery candidate.
local f = vm_mod.new()
f:intent_open(); f:on_port_state(2, 7)   -- OPEN, session generation 7
ok("grace armed at the fault's own generation", f:enter_reconnecting(7))
eq("grace generation preserved", f.hsm.generation, 7)
ok("stale same-gen OPEN is rejected while recovering", not f:on_port_state(2, 7))
eq("still RECONNECTING after stale same-gen OPEN", f.hsm.state, vm_mod.STATE_RECONNECTING)
ok("stale same-gen OPEN cannot settle recovery", not f:settle_recovering())
eq("still RECONNECTING after refused settle", f.hsm.state, vm_mod.STATE_RECONNECTING)
-- Same-generation OPENING is equally stale (the pre-fault session never
-- re-emits it; a real reopen is a fresh generation).
ok("stale same-gen OPENING is rejected", not f:on_port_state(1, 7))
eq("still RECONNECTING after stale OPENING", f.hsm.state, vm_mod.STATE_RECONNECTING)
-- A genuinely newer generation (the driver's close->open sequence) recovers.
ok("newer-generation OPEN is accepted", f:on_port_state(2, 9))
ok("newer-generation OPEN settles", f:settle_recovering())
eq("OPEN after newer-generation settle", f.hsm.state, vm_mod.STATE_OPEN)
ok("send re-enabled after generation-guarded recovery", f:ui_state().send_enabled)

-- A same-generation CLOSED is still our own reset-in-progress (it latches but
-- must never settle), preserving the reset semantics of test 19.
local f2 = vm_mod.new()
f2:intent_open(); f2:on_port_state(2, 4); f2:enter_reconnecting(4)
ok("same-gen CLOSED during grace still latches (reset)", f2:on_port_state(0, 4))
eq("reset CLOSED does not tear down grace", f2.hsm.state, vm_mod.STATE_RECONNECTING)
ok("reset CLOSED never settles", not f2:settle_recovering())

-- 24) Malformed inputs must never raise: a nil/string generation, an unknown
--     core state code, or a nil/mis-shaped snapshot is a rejected no-op, not a
--     Lua error (an error inside the 250 ms status poller would break the
--     interlock refresh for that tick).
do
    local m = vm_mod.new()
    local okc, res = pcall(function() return m.hsm:on_port_state(2, nil) end)
    ok("nil generation rejected without error", okc and res == false)
    okc, res = pcall(function() return m.hsm:on_port_state(2, "3") end)
    ok("string generation rejected without error", okc and res == false)
    okc, res = pcall(function() return m.hsm:on_port_state(99, 1) end)
    ok("unknown core state code ignored without error", okc and res == false)
    okc, res = pcall(function() return m:on_port_state(2, nil) end)
    ok("ViewModel:on_port_state nil generation rejected", okc and res == false)
    okc, res = pcall(function() return m:on_snapshot({ port_state = 2 }) end)
    ok("snapshot without generation rejected without error", okc and res == false)
    okc, res = pcall(function() return m:on_snapshot(nil) end)
    ok("nil snapshot rejected without error", okc and res == false)
    eq("malformed inputs left state CLOSED", m.hsm.state, vm_mod.STATE_CLOSED)
end

-- 25) Grace-window interlock consistency: a latched recovery candidate must
--     not reopen the data path before settle_recovering() commits it.  The
--     Window:core_send funnel refuses while hsm.state is RECONNECTING (it is
--     gated on vm:recovering()), so ui_state().send_enabled / connected must
--     agree and stay false until settle -- otherwise the button says "send"
--     while the funnel answers XCOM_ERR_NOT_OPEN.
local lat = vm_mod.new()
lat:intent_open(); lat:on_port_state(2, 1); lat:enter_reconnecting(2)
ok("recovery candidate latched", lat:on_port_state(2, 4))
eq("still RECONNECTING until settle", lat.hsm.state, vm_mod.STATE_RECONNECTING)
ok("latched candidate still recovering", lat:recovering())
eq("latched candidate super stays OFFLINE", lat.hsm:super_state(), vm_mod.SUPER_OFFLINE)
local ls = lat:ui_state()
ok("latched candidate send stays disabled", not ls.send_enabled)
ok("latched candidate autosend stays disabled", not ls.autosend_enabled)
ok("latched candidate connected stays false", not ls.connected)
ok("settle commits the candidate", lat:settle_recovering())
eq("settled super ONLINE", lat.hsm:super_state(), vm_mod.SUPER_ONLINE)
ok("settled send enabled", lat:ui_state().send_enabled)

-- NOTE (UI-side, unfixed here): window.lua reads state constants and the grace
-- timeout off a ViewModel *instance* (self.vm.STATE_OPENING / self.vm.STATE_OPEN
-- / self.vm.RECONNECT_GRACE_MS).  They live on the module table only, so on an
-- instance they are nil today: the OPENING watchdog and the reconnect grace
-- window silently never arm.  Exposing them here is NOT sufficient on its own --
-- once the grace window arms, poll_status() wedges (see report): its
-- `_reconnect_deadline` branch never calls _drive_reconnect and never times out,
-- so a successful reset-close leaves the HSM stuck in RECONNECTING (or CLOSING
-- after a user close).  Fix both in window.lua together, then expose the
-- constants here.

print(string.format("\nview_model tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
