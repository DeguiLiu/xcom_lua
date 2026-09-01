--[[--------------------------------------------------------------------------
core/view_model.lua - hierarchical UI-state mirror of the native port HSM.

Pure Lua port of xcom_client/app/view_model.py (SerialUiHsm + ViewModel).  The
native core is authoritative for port state; this module mirrors it on the
single UI thread and derives one immutable-ish state table consumed by the
connection panel, send panel and status bar to drive interlock:

  * params_enabled - only true while OFFLINE (CLOSED/FAULT): baud/data/parity/
    stop/flow/DTR/RTS edits are only safe before a port is opened;
  * open_enabled   - only true from CLOSED/FAULT (mirrors can_open);
  * close_enabled  - only true from OPEN/OPENING/FAULT (mirrors can_close);
  * send_enabled / autosend_enabled - only true exactly in OPEN.

Generation guards discard stale core notifications (a port_state signal from
an older `xcom_open` session that raced with a newer one), exactly like the
Python `on_port_state`/`on_snapshot`.

No FFI/Win32 dependency: fully unit-testable on Linux with plain luajit.
------------------------------------------------------------------------]]--

local M = {}

-- Core port-state codes (xcom.h / xcom_ffi.lua port_closed..port_fault).
local CORE_CLOSED, CORE_OPENING, CORE_OPEN, CORE_CLOSING, CORE_FAULT = 0, 1, 2, 3, 4

M.STATE_CLOSED = "closed"
M.STATE_OPENING = "opening"
M.STATE_OPEN = "open"
M.STATE_CLOSING = "closing"
M.STATE_FAULT = "fault"

M.SUPER_OFFLINE = "offline"
M.SUPER_TRANSITIONAL = "transitional"
M.SUPER_ONLINE = "online"

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
}
local PARENT_STATE = {
    [M.STATE_CLOSED] = M.SUPER_OFFLINE,
    [M.STATE_FAULT] = M.SUPER_OFFLINE,
    [M.STATE_OPENING] = M.SUPER_TRANSITIONAL,
    [M.STATE_CLOSING] = M.SUPER_TRANSITIONAL,
    [M.STATE_OPEN] = M.SUPER_ONLINE,
}
local ALLOWED_OPEN = { [M.STATE_CLOSED] = true, [M.STATE_FAULT] = true }
local ALLOWED_CLOSE = { [M.STATE_OPEN] = true, [M.STATE_OPENING] = true, [M.STATE_FAULT] = true }

-- ---------------------------------------------------------------------------
-- Hsm: thread-affine (single UI thread) hierarchical state-machine mirror.
-- ---------------------------------------------------------------------------
local Hsm = {}
Hsm.__index = Hsm

function M.new_hsm()
    return setmetatable({ state = M.STATE_CLOSED, generation = 0 }, Hsm)
end

function Hsm:super_state()
    return PARENT_STATE[self.state]
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
    self.state = M.STATE_OPENING
    return true
end

function Hsm:intent_close()
    if not self:can_close() then
        return false
    end
    self.state = M.STATE_CLOSING
    return true
end

-- Rollback an open intent rejected before the worker received it.
function Hsm:reject_open()
    if self.state ~= M.STATE_OPENING then
        return false
    end
    self.state = M.STATE_CLOSED
    return true
end

-- Leave a transient state after a worker-side error notification.
function Hsm:force_fault()
    if self.state ~= M.STATE_OPENING and self.state ~= M.STATE_CLOSING then
        return false
    end
    self.state = M.STATE_FAULT
    return true
end

-- Apply an authoritative core notification, rejecting stale generations.
function Hsm:on_port_state(core_state, generation)
    if generation < self.generation then
        return false
    end
    local state = CORE_TO_UI[core_state]
    if state == nil then
        return false
    end
    if state == self.state and generation == self.generation then
        return false
    end
    self.generation = generation
    self.state = state
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

function M.new()
    return setmetatable({
        hsm = M.new_hsm(),
        snapshot = { port_state = CORE_CLOSED, generation = 0 },
    }, ViewModel)
end

-- Build the current immutable-ish render-state table.
function ViewModel:ui_state()
    local state = self.hsm.state
    return {
        state = state,
        super_state = self.hsm:super_state(),
        snapshot = self.snapshot,
        params_enabled = self.hsm:super_state() == M.SUPER_OFFLINE,
        open_enabled = self.hsm:can_open(),
        close_enabled = self.hsm:can_close(),
        send_enabled = state == M.STATE_OPEN,
        autosend_enabled = state == M.STATE_OPEN,
        connected = self.hsm:super_state() == M.SUPER_ONLINE,
        port_state_code = UI_TO_CORE[state],
    }
end

-- Consume a full core snapshot table (fields: port_state, generation, ...).
-- Returns true if anything changed (caller should re-render).
function ViewModel:on_snapshot(snap)
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
    self.snapshot = snap
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
    self.snapshot.port_state = CORE_CLOSED
    return true
end

function ViewModel:force_fault()
    if not self.hsm:force_fault() then
        return false
    end
    self.snapshot.port_state = CORE_FAULT
    return true
end

M.ViewModel = ViewModel

return M
