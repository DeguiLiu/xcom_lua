-- test_reset_sequencer.lua - unit tests for core/reset_sequencer.lua.
--
-- No clock and no hardware: a mutable fake clock drives now_fn and a recording
-- set_lines captures every DTR/RTS transition with the clock value at the time.
-- The tests therefore fail if the edge timing, the per-step failure reporting,
-- or the deassert-on-exit invariant is removed -- they call the real methods,
-- they do not grep source text.
--
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_reset_sequencer.lua

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local seqmod = require("reset_sequencer")
local profiles = require("device_profiles")

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

local clock = 0
local function now_fn()
    return clock
end

local function make_rec()
    local rec = { calls = {}, fail_at = nil, fail_rc = -7 }
    rec.set = function(d, r)
        rec.calls[#rec.calls + 1] = { d = d, r = r, at = clock }
        if rec.fail_at ~= nil and #rec.calls == rec.fail_at then
            return rec.fail_rc
        end
        return 0
    end
    return rec
end

-- 1) idle before start
clock = 0
local rec = make_rec()
local seq = seqmod.new(profiles.resolve("USB\\VID_1A86&PID_7523", nil), rec.set, now_fn)
eq("idle before start", seq:state(), "idle")
eq("no calls while idle", #rec.calls, 0)

-- 2) CH340 auto sequence: order, per-edge delay, exactly-once.
--    edges = {rts=1}, {dtr=1,+120}, {rts=0,+60}, {dtr=0,+50}
clock = 0
rec = make_rec()
seq = seqmod.new(profiles.resolve("USB\\VID_1A86&PID_7523", nil), rec.set, now_fn)
eq("start -> running", seq:start(), "running")
for k = 0, 400 do
    clock = k
    seq:step(clock)
end
eq("four edges emitted", #rec.calls, 4)
eq("edge1 dtr", rec.calls[1] and rec.calls[1].d, 0)
eq("edge1 rts", rec.calls[1] and rec.calls[1].r, 1)
eq("edge1 at t0", rec.calls[1] and rec.calls[1].at, 0)
eq("edge2 dtr", rec.calls[2] and rec.calls[2].d, 1)
eq("edge2 rts", rec.calls[2] and rec.calls[2].r, 1)
eq("edge2 at +120", rec.calls[2] and rec.calls[2].at, 120)
eq("edge3 dtr", rec.calls[3] and rec.calls[3].d, 1)
eq("edge3 rts", rec.calls[3] and rec.calls[3].r, 0)
eq("edge3 at +180", rec.calls[3] and rec.calls[3].at, 180)
eq("edge4 dtr", rec.calls[4] and rec.calls[4].d, 0)
eq("edge4 rts", rec.calls[4] and rec.calls[4].r, 0)
eq("edge4 at +230", rec.calls[4] and rec.calls[4].at, 230)
-- delay BETWEEN edges (the doc's 120 / 60 / 50)
eq("delay edge1->edge2", rec.calls[2].at - rec.calls[1].at, 120)
eq("delay edge2->edge3", rec.calls[3].at - rec.calls[2].at, 60)
eq("delay edge3->edge4", rec.calls[4].at - rec.calls[3].at, 50)
-- exactly-once: further steps emit nothing more
clock = 401
seq:step(clock)
eq("no re-emission", #rec.calls, 4)
eq("settling after edges", seq:state(), "settling")

-- 3) settle window then done
clock = 3229
eq("still settling at +3229", seq:step(clock), "settling")
clock = 3230
eq("done at +3230", seq:step(clock), "done")
local last = rec.calls[#rec.calls]
eq("rests deasserted (dtr)", last.d, 0)
eq("rests deasserted (rts)", last.r, 0)

-- 4) deassert-on-exit even when the edge list ends asserted
clock = 0
rec = make_rec()
seq = seqmod.new({ reset = { mode = "auto", edges = { { rts = 1 } } } }, rec.set, now_fn)
seq:start()
clock = 0
seq:step(clock)
eq("asserted-edge profile -> done", seq:state(), "done")
eq("safety deassert emitted", #rec.calls, 2)
eq("edge applied", rec.calls[1].r, 1)
eq("safety deassert dtr", rec.calls[2].d, 0)
eq("safety deassert rts", rec.calls[2].r, 0)

-- 5) per-step failure is reported, and the board is still left deasserted
clock = 0
rec = make_rec()
rec.fail_at = 2
rec.fail_rc = -7
seq = seqmod.new(
    { reset = { mode = "auto", edges = { { rts = 1 }, { dtr = 1, delay = 50 } } } },
    rec.set, now_fn)
seq:start()
clock = 0
seq:step(clock)
eq("edge1 ok", seq:state(), "running")
clock = 50
seq:step(clock)
eq("failure -> failed", seq:state(), "failed")
eq("failure reported not swallowed", type(seq.err), "string")
eq("failure names the edge", seq.err and seq.err:find("edge 2", 1, true) ~= nil, true)
eq("last call is deassert", rec.calls[#rec.calls].d, 0)
eq("last call is deassert rts", rec.calls[#rec.calls].r, 0)
-- failed is terminal: no further pin traffic
local n_fail = #rec.calls
clock = 200
seq:step(clock)
eq("failed stays failed", seq:state(), "failed")
eq("no traffic after failure", #rec.calls, n_fail)

-- 6) manual mode drives no pins and exposes instructions + countdown
clock = 0
rec = make_rec()
seq = seqmod.new(
    { reset = { mode = "manual", settle_ms = 4000 },
      manual_instructions = "Hold BOOT, tap RST, release BOOT" },
    rec.set, now_fn)
eq("start manual", seq:start(), "manual")
for k = 0, 100 do
    clock = k
    seq:step(clock)
end
eq("manual drives no pins", #rec.calls, 0)
eq("manual instructions exposed", seq.manual_instructions,
   "Hold BOOT, tap RST, release BOOT")
clock = 0
eq("manual countdown full", seq:remaining_ms(clock), 4000)
clock = 2000
eq("manual countdown half", seq:remaining_ms(clock), 2000)
clock = 9000
eq("manual countdown clamps at 0", seq:remaining_ms(clock), 0)
eq("manual stays manual", seq:state(), "manual")

-- 7) unsupported flow control degrades auto -> manual, and says why
clock = 0
seq = seqmod.new(
    { reset = { mode = "auto", edges = { { rts = 1 } } },
      flow_control = "unsupported" }, make_rec().set, now_fn)
eq("unsupported -> manual", seq:start(), "manual")
eq("unsupported is not silent", type(seq.note), "string")

-- 8) mode "none" and empty edge lists terminate immediately, no pins driven
clock = 0
rec = make_rec()
seq = seqmod.new({ reset = { mode = "none" } }, rec.set, now_fn)
eq("none -> done", seq:start(), "done")
eq("none drives no pins", #rec.calls, 0)
seq = seqmod.new({ reset = { mode = "auto" } }, make_rec().set, now_fn)
eq("auto with no edges -> done", seq:start(), "done")

print(string.format("\nreset_sequencer tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
