--[[--------------------------------------------------------------------------
core/view_model.lua - hierarchical UI-state mirror of the native port HSM.

Pure Lua port of xcom_client/app/view_model.py (SerialUiHsm + ViewModel).  The
native core is authoritative for port state; this module mirrors it on the
single UI thread and derives one immutable-ish state table consumed by the
connection panel, send panel and status bar to drive interlock:

  * params_enabled - only true while OFFLINE (the CLOSED/FAULT/RECONNECTING
    super-state, not just CLOSED/FAULT): baud/data/parity/stop/flow/DTR/RTS
    edits are only safe before a port is opened;
  * open_enabled   - only true from CLOSED/FAULT (mirrors can_open);
  * close_enabled  - only true from OPEN/OPENING/FAULT/RECONNECTING (mirrors
    can_close; the transitional OPENING case is what lets a slow open be
    cancelled);
  * send_enabled / autosend_enabled - only true exactly in OPEN.

Generation guards discard stale core notifications (a port_state signal from
an older `xcom_open` session that raced with a newer one), exactly like the
Python `on_port_state`/`on_snapshot`.

No FFI/Win32 dependency: fully unit-testable on Linux with plain luajit.
------------------------------------------------------------------------]]--

--[[--------------------------------------------------------------------------
Authority contract (native core <-> this mirror)
------------------------------------------------
  * Port facts are CORE-authoritative.  The native HSM owns closed/opening/
    open/closing/fault; on_port_state/on_snapshot only replay what the core
    published.  The mirror never invents a port state and never writes one
    back to the core.
  * Recovery POLICY is LUA-authoritative.  The reconnect grace window, its
    duration and retry cadence, and whether to retry at all are UI decisions
    (M.RECONNECT_GRACE_MS, window.lua's _drive_reconnect); the core has no
    equivalent timer.  The mirror owns the derived interlock because it is the
    single place send/params/close is computed from.
  * Lua influences the core ONLY by submitting open/close REQUESTS (xcom_open/
    xcom_close via the UI driver).  It never forges a transition locally:
    intent_open/intent_close only show an optimistic OPENING/CLOSING and roll
    back if the request is rejected.
  * RECONNECTING exists ONLY in the mirror.  The core reports FAULT for the
    whole grace window; UI_TO_CORE maps RECONNECTING back to CORE_FAULT so the
    wire view stays truthful, and the mirror owns downgrading that FAULT for
    display.
------------------------------------------------------------------------]]--

local M = {}

-- Core port-state codes (xcom.h / xcom_ffi.lua port_closed..port_fault).
local CORE_CLOSED, CORE_OPENING, CORE_OPEN, CORE_CLOSING, CORE_FAULT = 0, 1, 2, 3, 4

M.STATE_CLOSED = "closed"
M.STATE_OPENING = "opening"
M.STATE_OPEN = "open"
M.STATE_CLOSING = "closing"
M.STATE_FAULT = "fault"
-- RECONNECTING mirrors the core's FAULT while a short grace window is running
-- (port dropped, core has not yet been reset).  It exists only in the UI HSM:
-- UI_TO_CORE keeps mapping it to CORE_FAULT so a snapshot that reports FAULT
-- does not flip the derived state away from the grace window.
M.STATE_RECONNECTING = "reconnecting"

M.SUPER_OFFLINE = "offline"
M.SUPER_TRANSITIONAL = "transitional"
M.SUPER_ONLINE = "online"

-- Reconnect grace window: a port fault (device unplugged, IO aborted, access
-- denied) does not immediately tear the session down; the UI holds a
-- RECONNECTING state for this long while re-opening the same port.  Recovery
-- inside the window resumes normal traffic; past it the session goes FAULT and
-- the user reconnects manually.  Owned by the UI layer on purpose: the core
-- has no timer the app can verify on this host, and the HSM is the single
-- place every interlock (send/params/close) is derived from.
--
-- 8 s rather than 3: the devices this is built for reboot into a ROM
-- bootloader, which is a full USB detach and re-enumeration. Windows plays the
-- unplug/replug chime and the port takes several seconds to come back, so a
-- 3 s window expired just before the device returned and every ROM-mode switch
-- ended in FAULT. Override with [serial] reconnect_grace_ms.
M.RECONNECT_GRACE_MS = 8000

local CORE_TO_UI = {
    [CORE_CLOSED] = M.STATE_CLOSED,
    [CORE_OPENING] = M.STATE_OPENING,
    [CORE_OPEN] = M.STATE_OPEN,
    [CORE_CLOSING] = M.STATE_CLOSING,
    [CORE_FAULT] = M.STATE_FAULT,
}
local UI_TO_CORE = {
    [M.STATE_CLOSED] = CORE_CLOSED,
    [M.STATE_OPENING] = CORE_OPENING,
    [M.STATE_OPEN] = CORE_OPEN,
    [M.STATE_CLOSING] = CORE_CLOSING,
    [M.STATE_FAULT] = CORE_FAULT,
    -- The core has no RECONNECTING state: the port really is faulted there,
    -- the grace window is UI policy.  Reporting CORE_FAULT keeps the read-only
    -- view (status-bar code, snapshot comparisons) truthful.
    [M.STATE_RECONNECTING] = CORE_FAULT,
}
local PARENT_STATE = {
    [M.STATE_CLOSED] = M.SUPER_OFFLINE,
    [M.STATE_FAULT] = M.SUPER_OFFLINE,
    -- OFFLINE: params stay editable and the watchdog can decline to recover,
    -- which is exactly the interlock FAULT has.
    [M.STATE_RECONNECTING] = M.SUPER_OFFLINE,
    [M.STATE_OPENING] = M.SUPER_TRANSITIONAL,
    [M.STATE_CLOSING] = M.SUPER_TRANSITIONAL,
    [M.STATE_OPEN] = M.SUPER_ONLINE,
}
local ALLOWED_OPEN = { [M.STATE_CLOSED] = true, [M.STATE_FAULT] = true }
local ALLOWED_CLOSE = { [M.STATE_OPEN] = true, [M.STATE_OPENING] = true,
                        [M.STATE_FAULT] = true, [M.STATE_RECONNECTING] = true }

-- ---------------------------------------------------------------------------
-- Hsm: thread-affine (single UI thread) hierarchical state-machine mirror.
-- ---------------------------------------------------------------------------
local Hsm = {}
Hsm.__index = Hsm

function M.new_hsm()
    return setmetatable({ state = M.STATE_CLOSED, effective = M.STATE_CLOSED,
                          faulted = false, generation = 0 }, Hsm)
end

function Hsm:super_state()
    -- Derived from the *effective* state, EXCEPT that a RECONNECTING grace
    -- window is always OFFLINE for interlock purposes: `effective` may already
    -- hold a latched recovery candidate (OPEN/OPENING) before
    -- settle_recovering() commits it, and deriving ONLINE from that candidate
    -- would flip connected/send_enabled on while Window:core_send still
    -- refuses (it gates on recovering(), i.e. state == RECONNECTING).  Keep
    -- the two readers agreeing: the data path reopens only at settle.
    if self.state == M.STATE_RECONNECTING then
        return M.SUPER_OFFLINE
    end
    return PARENT_STATE[self.effective]
end

function Hsm:can_open()
    return ALLOWED_OPEN[self.state] == true
end

function Hsm:can_close()
    return ALLOWED_CLOSE[self.state] == true
end

function Hsm:intent_open()
    if not self:can_open() then
        return false
    end
    self._return_to = self.state
    self.state = M.STATE_OPENING
    self.effective = M.STATE_OPENING
    self.faulted = false
    return true
end

function Hsm:intent_close()
    if not self:can_close() then
        return false
    end
    self._return_to = self.state
    self.state = M.STATE_CLOSING
    self.effective = M.STATE_CLOSING
    self.faulted = false
    return true
end

-- Rollback an open intent rejected before the worker received it.  Restores
-- the state the open was issued from (CLOSED, FAULT or RECONNECTING), so a
-- rejected retry re-arms the watchdog instead of stranding the user in CLOSED.
function Hsm:reject_open()
    if self.state ~= M.STATE_OPENING then
        return false
    end
    -- Consume the rollback target: a returned-to state must never be reused by
    -- a later, unrelated reject (which would roll back into a stale state).
    local return_to = self._return_to or M.STATE_CLOSED
    self._return_to = nil
    self.state = return_to
    self.effective = return_to
    self.faulted = return_to ~= M.STATE_CLOSED
    return true
end

-- Rollback a close intent rejected before the worker received it.  Symmetric
-- with reject_open: a close aborted during the grace window returns to
-- RECONNECTING, a close aborted from OPEN/OPENING returns to FAULT.
function Hsm:reject_close()
    if self.state ~= M.STATE_CLOSING then
        return false
    end
    -- Consume the rollback target (see reject_open).
    local return_to = self._return_to or M.STATE_FAULT
    self._return_to = nil
    self.state = return_to
    self.effective = return_to
    self.faulted = return_to ~= M.STATE_OPEN
    return true
end

-- Leave a transient state after a worker-side error notification.
function Hsm:force_fault()
    if self.state ~= M.STATE_OPENING and self.state ~= M.STATE_CLOSING then
        return false
    end
    self.state = M.STATE_FAULT
    self.effective = M.STATE_FAULT
    self.faulted = true
    return true
end

-- Enter the reconnect grace window.  Valid whenever the session has left
-- OFFLINE (a port was open or being opened), from any state including FAULT
-- itself (so repeated fault signals during the window keep it alive).
-- Generations are preserved: the caller supplies a monotonic generation for
-- the fault edge exactly as it would for on_port_state.
function Hsm:enter_reconnecting(generation)
    if self.effective == M.STATE_RECONNECTING then
        return false
    end
    if PARENT_STATE[self.effective] == M.SUPER_OFFLINE and
       self.effective ~= M.STATE_FAULT then
        return false
    end
    local gen = generation or self.generation
    if gen < self.generation then
        return false
    end
    self.generation = gen
    self.state = M.STATE_RECONNECTING
    self.effective = M.STATE_RECONNECTING
    self.faulted = true
    return true
end

-- The grace window elapsed with no recovery: hand the session back to the
-- normal OFFLINE/FAULT interlock for a manual close/reopen.
function Hsm:reconnect_timeout()
    if self.state ~= M.STATE_RECONNECTING then
        return false
    end
    self.state = M.STATE_FAULT
    self.effective = M.STATE_FAULT
    self.faulted = true
    return true
end

-- Apply an authoritative core notification, rejecting stale generations.
function Hsm:on_port_state(core_state, generation)
    -- Reject unparseable input as a no-op instead of raising: this runs inside
    -- the 250 ms status poller, and a Lua error there would abort the whole
    -- interlock refresh for that tick.  The core always supplies a numeric
    -- generation; a script/UI caller might not.
    if type(generation) ~= "number" then
        return false
    end
    if generation < self.generation then
        return false
    end
    local state = CORE_TO_UI[core_state]
    if state == nil then
        return false
    end
    -- A FAULT snapshot is downgraded to RECONNECTING only while the grace
    -- window is actually armed (the core reports FAULT for the whole window).
    if self.state == M.STATE_RECONNECTING and state == M.STATE_FAULT then
        state = M.STATE_RECONNECTING
    end
    if self.state == M.STATE_RECONNECTING then
        -- Inside the window the derived state stays RECONNECTING, but the first
        -- non-fault snapshot is latched in `effective`; settle_recovering()
        -- commits it once recovery is confirmed.  Clearing `faulted` here is
        -- what lets a genuinely-fresh non-fault state through later.
        if state ~= M.STATE_RECONNECTING then
            -- A recovery candidate (OPENING/OPEN) must come from a *newer*
            -- generation than the one the grace window was armed at.  The core
            -- does not advance the generation on a fault, so the pre-fault
            -- session has the same generation as the window; a stale OPEN/open
            -- notification from that session must not be mistaken for recovery.
            -- The driver's own recovery always bumps the generation twice
            -- (its close() then open() each advance it), so a real recovery is
            -- never rejected here.  Same-generation CLOSED/CLOSING is still
            -- latched: it is the driver's own reset-in-progress, and settle
            -- refuses it anyway.
            if (state == M.STATE_OPENING or state == M.STATE_OPEN) and
               generation <= self.generation then
                return false
            end
            if generation > self.generation then
                -- Resync boundary: the core advanced a whole round the mirror
                -- never observed, so the previous session's rollback target is
                -- worthless.  Drop it (and the fault flag), but KEEP the grace
                -- window: a recovery candidate must go on latching until
                -- settle_recovering() commits it.  Exiting RECONNECTING here
                -- would destroy the recovery design (the driver's own reset ->
                -- reopen sequence advances the generation on every step), so
                -- the window is deliberately not torn down on generation alone.
                self._return_to = nil
                self.faulted = false
            elseif state == M.STATE_OPENING or state == M.STATE_OPEN or
                   state == M.STATE_CLOSING then
                self.faulted = false
            end
            if generation == self.generation and state == self.effective then
                return false
            end
            self.generation = generation
            self.effective = state
            return true
        end
        if generation == self.generation then
            return false
        end
        -- A strictly newer generation still reporting FAULT: keep the window
        -- alive, but drop the previous session's rollback target.
        self._return_to = nil
        self.generation = generation
        return true
    end
    if state == self.state and state == self.effective and
       generation == self.generation then
        return false
    end
    if generation > self.generation then
        -- Strictly newer generation: the core completed a whole open/close
        -- round (both advance the generation) that the mirror never observed.
        -- Nothing local survives that boundary -- clear the pending rollback
        -- target and the fault flag, then take the core's state as both the
        -- mirror's own and the effective one.  A greater-generation FAULT
        -- therefore still lands on FAULT.
        self._return_to = nil
        self.faulted = false
    end
    self.generation = generation
    self.state = state
    self.effective = state
    return true
end

M.Hsm = Hsm
M.core_to_ui = CORE_TO_UI
M.ui_to_core = UI_TO_CORE

-- ---------------------------------------------------------------------------
-- ViewModel: builds a render-input table from HSM + last snapshot.
-- ---------------------------------------------------------------------------
local ViewModel = {}
ViewModel.__index = ViewModel

-- Mirror the state names and timings onto the class so an INSTANCE exposes
-- them. They live on the module table, and `ViewModel.__index = ViewModel`
-- means `vm.new().STATE_OPENING` resolves here — but only if the value is
-- present. Without these, every `self.vm.STATE_OPEN` style read in window.lua
-- returned nil, so comparisons like `self.vm.hsm.state == self.vm.STATE_OPEN`
-- were silently always false: the OPENING watchdog never armed, DTR/RTS live
-- switching never ran, and the reconnect grace window never opened. Keep this
-- list in step with the module-level constants above.
ViewModel.STATE_CLOSED = M.STATE_CLOSED
ViewModel.STATE_OPENING = M.STATE_OPENING
ViewModel.STATE_OPEN = M.STATE_OPEN
ViewModel.STATE_CLOSING = M.STATE_CLOSING
ViewModel.STATE_FAULT = M.STATE_FAULT
ViewModel.STATE_RECONNECTING = M.STATE_RECONNECTING
ViewModel.RECONNECT_GRACE_MS = M.RECONNECT_GRACE_MS
-- OPENING_TIMEOUT_MS is deliberately NOT mirrored: it belongs to the UI driver
-- (window.lua's own local), not to the state model.

function M.new()
    return setmetatable({
        hsm = M.new_hsm(),
        snapshot = { port_state = CORE_CLOSED, generation = 0 },
        -- Presence of the SELECTED port in the current enumeration.  Orthogonal
        -- to the port state machine (same reasoning as the health axis, design
        -- §4.1): it is NOT a state, is not in ALLOWED_OPEN/ALLOWED_CLOSE, and
        -- can never force a close or override an active OPEN.  Its only effect
        -- is to withhold the Open button for a port the UI knows is absent.
        -- Default true so a caller that never enumerates keeps the pure
        -- port-state interlock.
        port_present = true,
    }, ViewModel)
end

-- Orthogonal presence input (USB plug/unplug, MCU power, re-enumeration).
-- Returns true only when the value changed, so the caller can re-render once.
function ViewModel:set_port_present(present)
    present = present and true or false
    if self.port_present == present then
        return false
    end
    self.port_present = present
    return true
end

-- Build the current immutable-ish render-state table.
function ViewModel:ui_state()
    local state = self.hsm.state
    local parent = self.hsm:super_state()
    local online = parent == M.SUPER_ONLINE
    return {
        state = state,
        super_state = parent,
        snapshot = self.snapshot,
        port_present = self.port_present,
        params_enabled = parent == M.SUPER_OFFLINE,
        -- Open additionally requires presence: never offer Open for a port the
        -- enumeration no longer lists.  Presence only ever gates THIS flag --
        -- close_enabled/send_enabled stay purely state-derived, so a vanished
        -- port can never force a close or cut an OPEN session.
        open_enabled = self.hsm:can_open() and self.port_present,
        close_enabled = self.hsm:can_close(),
        send_enabled = online,
        autosend_enabled = online,
        connected = online,
        -- RECONNECTING is a UI-only policy state; in the core the port is
        -- FAULT, so the wire code stays FAULT and no reader needs to know
        -- about the grace window.
        port_state_code = UI_TO_CORE[state],
        -- UI interlock extras: reconnect grace in progress, and a session that
        -- is simply broken now (FAULT) as opposed to recovering.
        reconnecting = state == M.STATE_RECONNECTING,
        faulted = state == M.STATE_FAULT,
        reconnect_timeout_ms = M.RECONNECT_GRACE_MS,
    }
end

-- Consume a full core snapshot table (fields: port_state, generation, ...).
-- Returns true if anything changed (caller should re-render).
function ViewModel:on_snapshot(snap)
    -- A malformed snapshot (nil, or missing the numeric generation) is a
    -- rejected no-op rather than a crash: this is called from the status
    -- poller, and the HSM already treats an unknown port_state as a no-op.
    if type(snap) ~= "table" or type(snap.generation) ~= "number" then
        return false
    end
    if snap.generation < self.hsm.generation then
        return false
    end
    local state_changed = self.hsm:on_port_state(snap.port_state, snap.generation)
    local same_snapshot = true
    for k, v in pairs(snap) do
        if self.snapshot[k] ~= v then
            same_snapshot = false
            break
        end
    end
    if same_snapshot and not state_changed then
        return false
    end
    -- Copy into the OWN retained table instead of aliasing `snap`.  xcom_ffi's
    -- get_snapshot hands out a reused module-level buffer (a fresh table per
    -- 250 ms tick was pure GC churn), so retaining `snap` by reference would let
    -- the next poll overwrite the "previous" values in place and silently
    -- disable this very diff.  The copy runs only on an actual change, so
    -- unchanged ticks allocate nothing.  Stale keys are dropped first so a
    -- subset snapshot (tests) does not leave fields from an earlier one.
    local retained = self.snapshot
    for k in pairs(retained) do
        if snap[k] == nil then retained[k] = nil end
    end
    for k, v in pairs(snap) do
        retained[k] = v
    end
    return true
end

-- Consume a lightweight state signal before its next full snapshot.
function ViewModel:on_port_state(core_state, generation)
    if not self.hsm:on_port_state(core_state, generation) then
        return false
    end
    self.snapshot.port_state = core_state
    self.snapshot.generation = generation
    return true
end

function ViewModel:intent_open()
    return self.hsm:intent_open()
end

function ViewModel:intent_close()
    return self.hsm:intent_close()
end

function ViewModel:reject_open()
    if not self.hsm:reject_open() then
        return false
    end
    self.snapshot.port_state = UI_TO_CORE[self.hsm.state]
    return true
end

function ViewModel:force_fault()
    if not self.hsm:force_fault() then
        return false
    end
    self.snapshot.port_state = CORE_FAULT
    return true
end

function ViewModel:reject_close()
    if not self.hsm:reject_close() then
        return false
    end
    self.snapshot.port_state = UI_TO_CORE[self.hsm.state]
    return true
end

function ViewModel:enter_reconnecting(generation)
    if not self.hsm:enter_reconnecting(generation) then
        return false
    end
    self.snapshot.port_state = CORE_FAULT
    return true
end

function ViewModel:reconnect_timeout()
    if not self.hsm:reconnect_timeout() then
        return false
    end
    self.snapshot.port_state = CORE_FAULT
    return true
end

function ViewModel:recovering()
    return self.hsm.state == M.STATE_RECONNECTING
end

-- Confirm a grace-window recovery: the HSM has latched a recovery-candidate
-- snapshot; adopt it as the derived state.  Returns true only on the settling
-- edge (RECONNECTING -> OPENING/OPEN) so the caller renders once.  A latched
-- CLOSED is deliberately NOT a recovery: inside the window the driver issues
-- its own xcom_close() to reset the core (FAULT -> CLOSED) before reopening, so
-- a CLOSED snapshot means "reset in progress", not "port is back".
function ViewModel:settle_recovering()
    if self.hsm.state ~= M.STATE_RECONNECTING then
        return false
    end
    local settled = self.hsm.effective
    if settled ~= M.STATE_OPEN and settled ~= M.STATE_OPENING then
        return false
    end
    self.hsm.state = settled
    self.snapshot.port_state = UI_TO_CORE[settled]
    return true
end

M.ViewModel = ViewModel

return M
