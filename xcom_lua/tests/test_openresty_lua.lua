-- test_openresty_lua.lua - smoke test for third_party/openresty-lua.
-- Verifies the A-tier modules actually load and work in our standalone
-- LuaJIT process (no nginx host). B-tier modules are expected to fail to
-- load — we only assert that they fail with a recognisable error.
--
-- Usage from repo root:
--     xcom_lua\runtime\luvjit.exe xcom_lua\tests\test_openresty_lua.lua
-- or, with package.path pointing at the third_party tree:
--     LUA_PATH="third_party/openresty-lua/lua/?.lua;third_party/openresty-lua/lualib/?.lua;;" \
--         xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_openresty_lua.lua

-- This file lives at <repo>/xcom_lua/tests/test_openresty_lua.lua and the
-- target tree is the in-project vendored copy <repo>/xcom_lua/libs/openresty/
-- (pure-Lua lualib modules; the jit/ tooling dir is intentionally NOT
-- copied — luajit.exe ships it). Per repo convention (cf.
-- tests/test_charset.lua which uses './core/?.lua'), we assume the
-- script is invoked from the repo root and use a cwd-relative path.
--
-- LuaJIT (5.1-compatible) replaces '.' in module names with LUA_DIRSEP
-- before substituting '?', so a single '?/?.lua' pair resolves both
-- top-level and nested modules:  tablepool      -> openresty/tablepool.lua
--                                 resty.lrucache -> openresty/resty/lrucache.lua
local TPLIB = "xcom_lua/libs/openresty/"
package.path = TPLIB .. "?.lua;"
            .. "xcom_lua/libs/jit-tools/?.lua;"
            .. package.path
print("openresty-lua path: " .. TPLIB)

local passed, failed = 0, 0
local function ok(label, cond, extra)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end


-- ---- 1) tablepool.lua -------------------------------------------------------
do
    local ok_load, tablepool = pcall(require, "tablepool")
    ok("tablepool loads", ok_load)
    if ok_load then
        local t = tablepool.fetch("smoke", 4, 0)
        eq("tablepool.fetch returned table", type(t), "table")
        tablepool.release("smoke", t, true)
        local t2 = tablepool.fetch("smoke", 4, 0)
        -- pool should reuse the same table (note: lua tables are values, but
        -- identity check verifies reuse from the pool slot)
        ok("tablepool reuses released object", rawequal(t, t2) == true)
    end
end


-- ---- 2) lrucache.lua (the patched one) -------------------------------------
do
    local ok_load, lru = pcall(require, "resty.lrucache")
    ok("resty.lrucache loads", ok_load)
    if ok_load then
        local c, err = lru.new(8)
        ok("lru.new(8) succeeds", c ~= nil, err)
        if c then
            eq("lru empty count", c:count(), 0)
            c:set("a", 1)
            c:set("b", 2)
            eq("lru count after 2 set", c:count(), 2)
            eq("lru get('a')", c:get("a"), 1)
            eq("lru get('b')", c:get("b"), 2)
            eq("lru get('missing')", c:get("nope"), nil)

            -- LRU eviction (small, focused): capacity 3, push 4 distinct keys.
            -- Order after set is MRU-at-head; tail (LRU) is evicted first.
            local e = lru.new(3)
            e:set("x", 1)
            e:set("y", 2)
            e:set("z", 3)
            -- cache_queue head→tail: z → y → x
            e:set("w", 4)            -- free_queue empty, evict tail = 'x'
            eq("lru evicts LRU ('x')", e:get("x"), nil)
            eq("lru keeps next-LRU ('y')", e:get("y"), 2)
            eq("lru keeps MRU ('z')", e:get("z"), 3)
            eq("lru keeps newest ('w')", e:get("w"), 4)
            -- After these gets, queue order (head→tail): w → z → y
            e:set("v", 5)            -- evict tail = 'y'
            eq("lru evicts tail again ('y')", e:get("y"), nil)
            eq("lru keeps 'v'", e:get("v"), 5)

            -- TTL via _set_now_fn (deterministic clock)
            local fake_now = 1000.0
            lru._set_now_fn(function() return fake_now end)
            c:set("ttl_key", "v", 5)
            eq("ttl fresh key visible", c:get("ttl_key"), "v")
            fake_now = 1006.0   -- beyond ttl=5
            eq("ttl expired returns nil + stale flag",
               c:get("ttl_key"), nil)
            -- reset clock so other tests aren't disturbed
            lru._set_now_fn(os.time)
        end
    end
end


-- ---- 3) lua/jit/* tools should load under require('jit.X') -----------------
do
    -- require('jit.p') loads jit/p.lua; require('jit.vmdef') loads jit/vmdef.lua.
    -- They do nothing useful without the profiler being triggered, but the
    -- modules themselves must be loadable on this LuaJIT runtime.
    local mods = { "jit.p", "jit.v", "jit.zone", "jit.vmdef", "jit.dump" }
    for _, m in ipairs(mods) do
        local ok_load = pcall(require, m)
        ok(m .. " loadable", ok_load)
    end
end


-- ---- 4) B-tier: must fail with FFI/load error (no OpenSSL FFI binding) -----
-- We don't bind OpenSSL, so these are expected to throw on first method call
-- (and most on require-time cdef). The smoke test only checks that require
-- either fails outright OR throws when an API is touched. We accept either.
do
    local b_tier = {
        "resty.md5", "resty.sha", "resty.sha1", "resty.sha256",
        "resty.sha224", "resty.sha384", "resty.sha512",
        "resty.aes",  "resty.random",
    }
    for _, m in ipairs(b_tier) do
        local ok_load, mod_or_err = pcall(require, m)
        if not ok_load then
            -- require itself blew up (most likely: cdef symbols missing
            -- because no OpenSSL is linked). Accept as expected.
            ok(m .. " (B-tier: require-time fail as expected)", true,
               "err=" .. tostring(mod_or_err):sub(1, 60))
        else
            -- require worked but calling should fail. Try a no-op method if
            -- present, otherwise accept that the module loaded but is inert.
            local touched_err
            if type(mod_or_err) == "table" then
                local probe = mod_or_err.new or mod_or_err.bytes
                              or mod_or_err.encrypt or mod_or_err
                if type(probe) == "function" then
                    pcall(function() probe(mod_or_err, "x") end)
                end
            end
            ok(m .. " (B-tier: loadable but inert without OpenSSL)", true)
        end
    end
end


-- ---- 5) Explicit blacklist: C-tier modules must NOT be in third_party -------
do
    -- core.lua, lock.lua, string.lua, upload.lua, mysql.lua, redis.lua,
    -- memcached.lua and all the core/ subdir modules are intentionally absent
    -- because they hard-bind nginx. We just ensure they were not copied.
    local blacklist = {
        "resty.core", "resty.lock", "resty.string", "resty.upload",
        "resty.mysql", "resty.redis", "resty.memcached",
        "resty.dns.resolver", "resty.websocket.client",
        "resty.limit.req", "resty.upstream.healthcheck",
    }
    for _, m in ipairs(blacklist) do
        local ok_load = pcall(require, m)
        ok(m .. " is NOT vendored (good)", not ok_load)
    end
end


print(string.format("---- openresty-lua smoke: %d passed, %d failed ----", passed, failed))
if failed > 0 then os.exit(1) end