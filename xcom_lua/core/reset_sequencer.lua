--[[--------------------------------------------------------------------------
core/reset_sequencer.lua - non-blocking DTR/RTS reset / ROM-entry sequencer.

Pure Lua, no DLL, no clock of its own.  The caller injects `now_fn` (a
monotonic millisecond source) and `set_lines` (a recorder/actuator) so the
timing rules are unit-testable with no hardware:

    local seq = reset_sequencer.new(profile, set_lines, now_fn)
    seq:start()
    -- from a ~5 ms luv timer, never sleep on the UI thread:
    seq:step(now_fn())
    seq:state()   --> "idle"|"running"|"settling"|"done"|"failed"|"manual"

`set_lines(dtr, rts)` receives the *full* desired line state as 0/1 and must
return 0 on success (non-zero or nil = failure).  The Win32 wrapper converts to
booleans: function(d, r) return xcom.set_lines(h, d ~= 0, r ~= 0) end.

Edge timing: each `profile.reset.edges[i].delay` is the wait BEFORE that edge,
measured from the previous edge's apply time; the first edge (no delay) fires
immediately.  For the CH340 profile that is RTS=1 at +0, DTR=1 at +120,
RTS=0 at +180, DTR=0 at +230 ms.

Invariant: on EVERY terminal path -- done, failed, or the manual path which
drives no pins -- DTR and RTS are left deasserted, so a board is never left
held in reset/BOOT.
------------------------------------------------------------------------]]--

local M = {}

M.STATES = {
    IDLE = "idle",
    RUNNING = "running",
    SETTLING = "settling",
    DONE = "done",
    FAILED = "failed",
    MANUAL = "manual",
}

-- UI hint window for the manual "press BOOT / tap RST" prompt; overridable per
-- profile via reset.manual_countdown_ms (or reset.settle_ms).
M.MANUAL_COUNTDOWN_MS = 10000

local Seq = {}
Seq.__index = Seq

local function default_now()
    return os.clock() * 1000
end

function M.new(profile, set_lines, now_fn)
    return setmetatable({
        profile = profile or {},
        set_lines = set_lines,
        now_fn = now_fn or default_now,
        _state = M.STATES.IDLE,
        index = 0,
        cur = { dtr = 0, rts = 0 },
        edge_at = {},
        t0 = 0,
        settle_until = 0,
        deadline = 0,
        err = nil,
        note = nil,
        manual_instructions = (profile and profile.manual_instructions) or nil,
    }, Seq)
end

function Seq:now()
    return self.now_fn()
end

function Seq:state()
    return self._state
end

-- remaining time for the UI: the settle window while "settling", the prompt
-- countdown while "manual", 0 otherwise.
function Seq:remaining_ms(now)
    if now == nil then
        now = self:now()
    end
    if self._state == M.STATES.SETTLING then
        local r = self.settle_until - now
        if r < 0 then r = 0 end
        return r
    end
    if self._state == M.STATES.MANUAL then
        local r = self.deadline - now
        if r < 0 then r = 0 end
        return r
    end
    return 0
end

-- apply the current desired line state; returns the status (0 == ok).
function Seq:_apply()
    if self.set_lines == nil then
        return -1
    end
    local rc = self.set_lines(self.cur.dtr, self.cur.rts)
    if rc == nil then
        return -1
    end
    return tonumber(rc) or -1
end

-- best-effort safety deassert; the original failure message is preserved.
function Seq:_fail(msg)
    self.err = msg
    self.cur.dtr = 0
    self.cur.rts = 0
    if self.set_lines ~= nil then
        self.set_lines(0, 0)
    end
    self._state = M.STATES.FAILED
end

local function manual_countdown(reset)
    return tonumber(reset.manual_countdown_ms)
        or tonumber(reset.settle_ms)
        or M.MANUAL_COUNTDOWN_MS
end

function Seq:start()
    self.err = nil
    self.note = nil
    self.index = 0
    self.cur.dtr = 0
    self.cur.rts = 0
    self.settle_until = 0
    self.edge_at = {}
    local reset = self.profile.reset or {}
    local mode = reset.mode or "manual"
    self.manual_instructions = self.profile.manual_instructions
    self.t0 = self:now()

    if mode == "auto" and self.profile.flow_control == "unsupported" then
        -- RTS cannot be driven under unsupported flow control; never degrade
        -- silently -- fall to manual and say why.
        mode = "manual"
        self.note = "flow_control unsupported: manual reset required"
    end

    if mode == "manual" then
        self.deadline = self.t0 + manual_countdown(reset)
        self._state = M.STATES.MANUAL
        return self._state
    end

    local edges = reset.edges or {}
    if mode ~= "auto" or #edges == 0 then
        self._state = M.STATES.DONE
        return self._state
    end

    local acc = 0
    for i = 1, #edges do
        acc = acc + (tonumber(edges[i].delay) or 0)
        self.edge_at[i] = acc
    end
    self._state = M.STATES.RUNNING
    return self._state
end

function Seq:_run_edges(now)
    local edges = self.profile.reset.edges
    local elapsed = now - self.t0
    while self.index < #edges do
        local i = self.index + 1
        if elapsed < self.edge_at[i] then
            return
        end
        local e = edges[i]
        if e.rts ~= nil then
            self.cur.rts = e.rts
        end
        if e.dtr ~= nil then
            self.cur.dtr = e.dtr
        end
        local rc = self:_apply()
        if rc ~= 0 then
            self:_fail(string.format("edge %d set_lines failed (rc=%s)", i, tostring(rc)))
            return
        end
        self.index = i
    end

    -- all edges applied: guarantee the safe resting level even if the last
    -- edge left a line asserted.
    if self.cur.dtr ~= 0 or self.cur.rts ~= 0 then
        self.cur.dtr = 0
        self.cur.rts = 0
        local rc = self:_apply()
        if rc ~= 0 then
            self:_fail("final deassert failed")
            return
        end
    end

    local settle = tonumber(self.profile.reset.settle_ms) or 0
    if settle > 0 then
        self.settle_until = self.t0 + self.edge_at[#edges] + settle
        self._state = M.STATES.SETTLING
    else
        self._state = M.STATES.DONE
    end
end

function Seq:step(now)
    if now == nil then
        now = self:now()
    end
    if self._state == M.STATES.RUNNING then
        self:_run_edges(now)
    elseif self._state == M.STATES.SETTLING then
        if now >= self.settle_until then
            self._state = M.STATES.DONE
        end
    end
    return self._state
end

return M
