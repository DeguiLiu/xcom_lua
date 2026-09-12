-- test_script_budget.lua - a runaway script hook must not freeze the host.
--
-- Regression: pcall() cannot interrupt a running function, so a user script
-- containing `while true do end` used to hang the message loop forever with no
-- way out but killing the process. The engine now runs every hook under
-- debug.sethook instruction budget.
--
-- The subtle part, and the reason this test exists: a count hook only fires for
-- INTERPRETED code. A JIT-compiled loop runs as native machine code and never
-- reaches the VM's instruction counter, so the hook silently never runs. The
-- guard therefore also has to jit.off(fn, true) — the recursive flag, because
-- the loop body's own closures would otherwise still be compiled. Each of those
-- two ingredients has its own assertion below, so a future edit that drops
-- either one fails here instead of shipping a guard that does not guard.
--
-- Pure Lua + LuaJIT: no luv, no DLL, runnable on Linux.
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_script_budget.lua

package.path = "./core/?.lua;" .. package.path
local engine_mod = require("script_engine")

local passed, failed = 0, 0
local function ok(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label)
    end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end

-- ---- 1) the two ingredients of the guard -----------------------------------
-- Reproduce the engine's helper shape locally so the test pins the MECHANISM,
-- not just its effect through the engine.
local BUDGET = 2000000
local function budgeted(fn, ...)
    local expired = false
    if jit and jit.off then
        jit.off(fn, true)
    end
    debug.sethook(function()
        expired = true
        error("script exceeded execution budget", 2)
    end, "", BUDGET)
    local ok, result = pcall(fn, ...)
    debug.sethook()
    return ok, result, expired
end

do
    local ok1, _, expired = budgeted(function() while true do end end)
    ok("runaway loop is interrupted", ok1 == false)
    ok("runaway loop reports expiry", expired == true)
end

do
    -- A hook that returns normally must be untouched, and the budget must be
    -- disarmed afterwards so it cannot leak into the engine's own frames.
    local ok1, result, expired = budgeted(function(s) return s .. "!" end, "hi")
    ok("normal hook still succeeds", ok1 == true)
    eq("normal hook value preserved", result, "hi!")
    eq("normal hook not marked expired", expired, false)
    ok("hook disarmed after the call", debug.gethook() == nil)
end

do
    -- A hook that raises for its own reasons must be reported as a script
    -- error, NOT as a budget expiry: the two need different user messages.
    local ok1, _, expired = budgeted(function() error("boom") end)
    ok("script error still fails", ok1 == false)
    eq("script error not marked expired", expired, false)
end

do
    -- Arity contract: the wrapper forwards (ok, first_result, expired) only.
    -- Script hooks are documented to return a single value (a replacement
    -- payload, or nil to drop), and the engine reads exactly one, so the loss
    -- of extra returns is intentional rather than accidental — pinned here so
    -- a future change that starts relying on multi-return is caught.
    local ok1, a, b = budgeted(function(x, y) return x + y, x * y end, 3, 4)
    ok("multi-return succeeds", ok1 == true)
    eq("first result forwarded", a, 7)
    eq("later returns are dropped by design", b, false)
end

-- ---- 2) the engine exposes the same guarantee -----------------------------
-- The helper above is a copy; this asserts the real module carries it. The
-- engine's dispatch paths are the only routes a user script gets invoked by.
do
    local src = io.open("core/script_engine.lua", "rb")
    ok("script_engine.lua readable", src ~= nil)
    if src then
        local text = src:read("*a")
        src:close()
        ok("engine defines call_budgeted", text:find("call_budgeted") ~= nil)
        ok("engine disarms the hook", text:find("debug%.sethook%(%)") ~= nil)
        ok("engine disables JIT recursively",
           text:find("jit%.off%(fn, true%)") ~= nil)
        -- Every dispatch path must go through the guard: a bare pcall(...hook)
        -- would be the exact regression this test exists to catch.
        eq("no unguarded recv_hook call",
           text:find("pcall%(record%.recv_hook") == nil, true)
        eq("no unguarded send_hook call",
           text:find("pcall%(record%.send_hook") == nil, true)
        eq("no unguarded uartReceive call",
           text:find("pcall%(record%.env%.uartReceive") == nil, true)
    end
end

print(string.format("\nscript_budget: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
