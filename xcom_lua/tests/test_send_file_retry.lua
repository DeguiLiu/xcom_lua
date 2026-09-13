-- test_send_file_retry.lua - offline, luv-free tests for scripts/send_file.lua's
-- handling of a TRANSIENT send rejection.
--
-- Drives the REAL send_file.lua inside a hand-built environment (no luv, no
-- script_engine) so it runs on the Linux dev box: a deterministic one-shot
-- timer pump mirrors the engine's timer array, and sys.file_read_at_async fires
-- its completion inline.
--
-- Pins the alignment this suite exists for: uart.send's -4 (err_busy: the
-- scheduler declined the event) and -5 (err_full: pool / queue at capacity)
-- are BOTH transient refusals and must take the SAME BOUNDED retry path; -2
-- (not open) must still abort at once.  The numeric codes mirror
-- core/xcom_ffi.lua (M.err_busy = -4, M.err_full = -5); the script sandbox
-- exposes no FFI, so send_file re-declares them as named locals.
--
-- Usage (from xcom_lua/):
--   /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_send_file_retry.lua

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

-- ---- scripts dir resolution (repo-root or xcom_lua/ cwd) -------------------
local script_dir = nil
for _, dir in ipairs({ "scripts", "xcom_lua/scripts" }) do
    local probe = io.open(dir .. "/send_file.lua", "rb")
    if probe then probe:close() script_dir = dir break end
end
ok("scripts dir found", script_dir ~= nil)
if not script_dir then
    print(string.format("send_file_retry: %d passed, %d failed", pass_n, fail_n))
    os.exit(1)
end

-- ---------------------------------------------------------------------------
-- Harness: a stub env mirroring the engine's script surface (uart/log/sys/ui)
-- plus a manual pump that mirrors engine.timers (at most one armed one-shot).
-- ---------------------------------------------------------------------------
local function make_harness()
    local h = {
        files = {},    -- path -> content
        spec = nil,    -- last ui.page() spec string
        sent = {},     -- successfully delivered payloads
        logs = {},     -- "level:tag:message"
        open = true,   -- uart.is_open()
        pick = nil,    -- sys.open_file() result
        send_fn = nil, -- programmable uart.send override
        busy_calls = {}, -- ordered sys.busy(v) publishes (host interlock)
    }
    local live = {}    -- mirrors engine.timers
    local pending = nil
    local n = 0

    local env = {
        string = string, table = table, math = math, os = os,
        tostring = tostring, tonumber = tonumber, ipairs = ipairs,
        pairs = pairs, next = next, select = select, unpack = unpack,
        type = type, pcall = pcall, error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable,
    }
    local function mk(level)
        return function(tag, ...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            h.logs[#h.logs + 1] = level .. ":" .. tostring(tag) .. ":" ..
                table.concat(parts, " ")
        end
    end
    env.log = { trace = mk("trace"), debug = mk("debug"), info = mk("info"),
                warn = mk("warn"), error = mk("error"), fatal = mk("fatal") }
    env.ui = { page = function(_, _, spec) h.spec = spec end }
    env.uart = {
        is_open = function() return h.open end,
        send = function(data)
            if h.send_fn then return h.send_fn(data) end
            h.sent[#h.sent + 1] = data
            return true, nil
        end,
    }
    env.sys = {
        open_file = function() return h.pick end,
        file_size = function(path)
            return h.files[path] and #h.files[path] or nil
        end,
        file_open = function(path)
            if h.files[path] then return { path = path } end
            return nil
        end,
        file_close = function() end,
        file_read_at_async = function(fd, offset, want, cb)
            -- inline completion (no event loop)
            local data = h.files[fd.path]:sub(offset + 1, offset + want)
            cb(nil, data)
            return true
        end,
        timer_start = function(_, fn)
            n = n + 1
            local handle = { id = n, fn = fn }
            live[#live + 1] = handle
            pending = handle
            return handle
        end,
        timer_stop = function(handle)
            for i = #live, 1, -1 do
                if live[i] == handle then table.remove(live, i) end
            end
            if pending == handle then pending = nil end
        end,
        -- Record the host interlock publishes: the stream must go busy(true)
        -- for its whole lifetime and, on EVERY termination path, release it
        -- with busy(false).  A stub that swallows the value cannot catch a
        -- termination that forgets the release and wedges the host.
        busy = function(v) h.busy_calls[#h.busy_calls + 1] = v end,
    }

    local chunk, err = loadfile(script_dir .. "/send_file.lua")
    assert(chunk, err)
    setfenv(chunk, env)
    local okk, run_err = pcall(chunk)
    assert(okk, run_err)

    h.dispatch = function(kind, widget, value)
        env.ui.event("file", kind, widget, value)
    end
    h.tick = function()
        if not pending then return false end
        local fn = pending.fn
        pending = nil
        fn()
        return true
    end
    h.run = function(limit)
        local i = 0
        while pending and i < (limit or 100000) do
            h.tick()
            i = i + 1
        end
        return i
    end
    h.live_count = function() return #live end
    h.last_busy = function() return h.busy_calls[#h.busy_calls] end
    h.saw_busy = function(v)
        for _, b in ipairs(h.busy_calls) do
            if b == v then return true end
        end
        return false
    end
    return h
end

-- An absurdly high tick budget: a bounded retry path must abort well under it,
-- so if the loop ever burns all of these the abort is not bounded at all.
local RUNAWAY = 1000

-- scripts/send_file.lua's MAX_STALL_RETRIES: the number of CONSECUTIVE
-- transient rejections tolerated before the stream gives up.  The abort fires
-- on the (MAX+1)-th rejected attempt, so the OBSERVABLE attempt count IS the
-- bound and pinning it makes any raise/lower fail.  Deliberately hardcoded and
-- NOT scraped from the script: reading the constant would move the expectation
-- in lockstep with production and never fail.  Change this only together with
-- production, and the mismatch is then the point.
local MAX_STALL_RETRIES = 100

-- ---- A) -5 (err_full) once, then ok: retried, both chunks delivered --------
do
    local h = make_harness()
    h.pick = "/full.bin"; h.files["/full.bin"] = string.rep("F", 2048)
    local calls = 0
    h.send_fn = function(data)
        calls = calls + 1
        if calls == 1 then return false, -5 end
        h.sent[#h.sent + 1] = data
        return true, nil
    end
    h.dispatch("click", "browse")
    h.dispatch("click", "start")
    h.run(RUNAWAY)
    eq("A1 -5 once: both chunks delivered", #h.sent, 2)
    eq("A2 -5 once: attempt count failed+2ok", calls, 3)
    ok("A3 -5 once: stream completes (Send restored)",
       h.spec:find("button:start:Send", 1, true) ~= nil)
    eq("A4 -5 once: stream published busy", h.saw_busy(true), true)
    eq("A5 -5 once: normal completion releases busy (last=false)",
       h.last_busy(), false)
end

-- ---- B) -4 (err_busy) once, then ok: SAME path, both chunks delivered ------
do
    local h = make_harness()
    h.pick = "/busy.bin"; h.files["/busy.bin"] = string.rep("U", 2048)
    local calls = 0
    h.send_fn = function(data)
        calls = calls + 1
        if calls == 1 then return false, -4 end
        h.sent[#h.sent + 1] = data
        return true, nil
    end
    h.dispatch("click", "browse")
    h.dispatch("click", "start")
    h.run(RUNAWAY)
    eq("B1 -4 once: both chunks delivered", #h.sent, 2)
    eq("B2 -4 once: attempt count failed+2ok", calls, 3)
    ok("B3 -4 once: stream completes (Send restored)",
       h.spec:find("button:start:Send", 1, true) ~= nil)
    eq("B4 -4 once: stream published busy", h.saw_busy(true), true)
    eq("B5 -4 once: normal completion releases busy (last=false)",
       h.last_busy(), false)
end

-- ---- C) permanent -4 / -5: bounded, IDENTICAL budget, and named in the log -
do
    local r = {}
    for _, code in ipairs({ -4, -5 }) do
        local h = make_harness()
        h.pick = "/stuck.bin"; h.files["/stuck.bin"] = string.rep("S", 1024)
        local tries = 0
        h.send_fn = function() tries = tries + 1; return false, code end
        h.dispatch("click", "browse")
        h.dispatch("click", "start")
        h.run(RUNAWAY)
        r[code] = {
            tries = tries,
            restored = h.spec:find("button:start:Send", 1, true) ~= nil,
            logged = table.concat(h.logs, "\n"),
            live = h.live_count(),
            saw_busy_true = h.saw_busy(true),
            last_busy = h.last_busy(),
        }
    end
    eq("C1 permanent -4 is retried more than once", r[-4].tries > 1, true)
    -- Pin the EXACT bound, not merely "under the runaway budget": a bare
    -- tries < RUNAWAY passes even if MAX_STALL_RETRIES is raised (audit: a
    -- mutant with MAX=500 still passed), which is the whole hole this suite
    -- exists to close.
    eq("C2 permanent -4 aborts at exactly MAX+1 attempts",
       r[-4].tries, MAX_STALL_RETRIES + 1)
    eq("C3 permanent -4 aborts with Send restored", r[-4].restored, true)
    ok("C4 permanent -4 abort names the retry limit",
       r[-4].logged:find("retry limit", 1, true) ~= nil)
    eq("C5 permanent -4 leaves no live timer", r[-4].live, 0)
    eq("C6 -4 and -5 exhaust the IDENTICAL retry budget",
       r[-5].tries, r[-4].tries)
    eq("C7 permanent -5 aborts at exactly MAX+1 attempts",
       r[-5].tries, MAX_STALL_RETRIES + 1)
    ok("C8 permanent -5 abort names the retry limit",
       r[-5].logged:find("retry limit", 1, true) ~= nil)
    -- The retry-limit abort is a normal termination and MUST release the host
    -- interlock; otherwise the host refuses every future sequence forever.
    eq("C9 retry-limit abort published busy", r[-4].saw_busy_true, true)
    eq("C10 retry-limit abort releases busy (last=false)", r[-4].last_busy, false)
    eq("C11 -5 retry-limit abort releases busy (last=false)",
       r[-5].last_busy, false)
end

-- ---- D) -2 (not open): abort at once, never retried ------------------------
do
    local h = make_harness()
    h.pick = "/closed.bin"; h.files["/closed.bin"] = string.rep("C", 2048)
    local tries = 0
    h.send_fn = function() tries = tries + 1; return false, -2 end
    h.dispatch("click", "browse")
    h.dispatch("click", "start")
    h.run(RUNAWAY)
    eq("D1 -2 aborts on the first attempt (no retry)", tries, 1)
    ok("D2 -2 abort reports the port error",
       table.concat(h.logs, "\n"):find("port error", 1, true) ~= nil)
    ok("D3 -2 abort restores Send",
       h.spec:find("button:start:Send", 1, true) ~= nil)
    eq("D4 -2 non-transient abort releases busy (last=false)",
       h.last_busy(), false)
end

print(string.format("send_file_retry: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n > 0 and 1 or 0)
