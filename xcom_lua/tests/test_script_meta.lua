-- test_script_meta.lua - pure-Lua unit tests for the script metadata header
-- parser and the fs_event reload debounce scheduler in core/script_engine.lua.
--
-- These tests deliberately avoid `luv`: the Linux dev box has no Linux luv
-- build (only the Windows runtime/luv.dll), so anything importing uv cannot
-- run here.  The two features below are structured as pure functions with an
-- injectable clock, so the logic is fully covered on any LuaJIT.  The uv-only
-- integration (real fs_event watching) is exercised on Windows via
-- runtime/luvjit.exe in tests/test_script_engine.lua; see the TODO note there.
--
-- Usage (Linux, from xcom_lua/):
--     /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_script_meta.lua

package.path = "./core/?.lua;" .. package.path
local engine_mod = require("script_engine")

-- The engine module's pure helpers must be reachable without uv.  If this
-- require itself fails, the test is a syntax/API smoke check only.
local meta = engine_mod.meta
local debounce = engine_mod.debounce

local passed, failed = 0, 0
local function ok(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end

-- ---- 1) parse_meta: @name / @desc tags in the file header ------------------
do
    ok("meta module exposed", meta ~= nil)
    ok("parse_meta exposed", meta and type(meta.parse) == "function")

    local text = table.concat({
        "-- @name 绘制曲线",
        "-- @desc 解析串口数值行，绘制实时曲线（最多4条）",
        "-- some other comment",
        "on.receive(function(t) return t end)",
    }, "\n")
    local m = meta.parse(text)
    eq("name parsed", m.name, "绘制曲线")
    eq("desc parsed", m.desc, "解析串口数值行，绘制实时曲线（最多4条）")
end

-- tag order independence + whitespace tolerance
do
    local text = "-- @desc   spaced desc  \n-- @name\tTabbed Name\n"
    local m = meta.parse(text)
    eq("desc with padding", m.desc, "spaced desc")
    eq("name with tab", m.name, "Tabbed Name")
end

-- no tags -> both nil (caller falls back to filename)
do
    local m = meta.parse("-- just a script\nreturn 1\n")
    eq("no name tag", m.name, nil)
    eq("no desc tag", m.desc, nil)
end

-- tags only read from the HEAD; a tag deep in the body is ignored
do
    local body = {}
    for i = 1, 40 do body[i] = "-- filler " .. i end
    body[#body + 1] = "-- @name Late Name"
    local m = meta.parse(table.concat(body, "\n"))
    eq("late tag ignored past head window", m.name, nil)
end

-- only first occurrence of a tag wins
do
    local m = meta.parse("-- @name First\n-- @name Second\n")
    eq("first name wins", m.name, "First")
end

-- empty / non-table input is nil-safe
do
    eq("nil text -> nil name", meta.parse(nil).name, nil)
    eq("empty text -> nil desc", meta.parse("").desc, nil)
end

-- ---- 2) display_name: description preferred, filename fallback -------------
do
    ok("display_name exposed", type(meta.display_name) == "function")
    eq("uses @name when present",
        meta.display_name("scope.lua", { name = "绘制曲线" }), "绘制曲线")
    eq("falls back to filename",
        meta.display_name("scope.lua", { name = nil }), "scope.lua")
    eq("falls back on empty name",
        meta.display_name("scope.lua", { name = "" }), "scope.lua")
    -- desc is NOT used as the label; it stays available for a tooltip.
    eq("desc not used as label",
        meta.display_name("scope.lua", { desc = "some desc" }), "scope.lua")
end

-- ---- 3) debounce scheduler: coalesce rapid events per name ------------------
do
    ok("debounce module exposed", debounce ~= nil)
    ok("debounce.new exposed", debounce and type(debounce.new) == "function")

    local clock = 1000
    local d = debounce.new({ window_ms = 200, now = function() return clock end })
    ok("fresh name not ready", not d:ready("a.lua"))

    d:touch("a.lua")                 -- event at t=1000
    ok("not ready before window", not d:ready("a.lua"))
    clock = 1100
    ok("still not ready mid-window", not d:ready("a.lua"))
    clock = 1200
    ok("ready exactly at window", d:ready("a.lua"))
    ok("consumed -> not ready again", not d:ready("a.lua"))
end

-- a second event inside the window restarts the timer (trailing debounce)
do
    local clock = 0
    local d = debounce.new({ window_ms = 200, now = function() return clock end })
    d:touch("b.lua")     -- t=0
    clock = 150
    d:touch("b.lua")     -- t=150: restart
    clock = 300
    ok("restarted window not elapsed", not d:ready("b.lua"))
    clock = 351
    ok("restarted window elapsed", d:ready("b.lua"))
end

-- names are independent
do
    local clock = 0
    local d = debounce.new({ window_ms = 200, now = function() return clock end })
    d:touch("x.lua")
    clock = 250
    ok("x ready", d:ready("x.lua"))
    ok("y never touched -> not ready", not d:ready("y.lua"))
end

-- ---- 4) reload planning: enabled-only, name preservation -------------------
-- schedule() is the pure decision layer over load_script(): given the engine's
-- record table and a set of changed names, it returns the names that must be
-- reloaded (enabled scripts whose files changed), leaving disabled ones alone.
do
    ok("reload_plan exposed", type(engine_mod.reload_plan) == "function")
    local records = {
        ["on.lua"]  = { enabled = true },
        ["off.lua"] = { enabled = false },
        ["new.lua"] = { enabled = false },
    }
    local plan = engine_mod.reload_plan(records, { "on.lua", "off.lua", "ghost.lua" })
    eq("plan count", #plan, 1)
    eq("only enabled known script reloads", plan[1], "on.lua")

    -- sorted, stable order regardless of input order
    local rec2 = { ["z.lua"] = { enabled = true }, ["a.lua"] = { enabled = true } }
    local plan2 = engine_mod.reload_plan(rec2, { "z.lua", "a.lua" })
    eq("plan sorted[1]", plan2[1], "a.lua")
    eq("plan sorted[2]", plan2[2], "z.lua")
end

-- ---- 5) engine surface: script_labels / script_meta ------------------------
-- M.new() itself is uv-free (uv is only touched by load_all / fs / timers), so
-- a bare engine can be constructed and its label/plan layer exercised without
-- luv.  load_all would need uv.fs_scandir, so we seed records directly.
do
    local engine = engine_mod.new({ script_dir = "/nonexistent" })
    ok("engine constructs without uv", engine ~= nil)

    engine.scripts = {
        ["scope_demo.lua"] = { enabled = true,
            meta = { name = "绘制曲线", desc = "解析串口数值行" }, label = "绘制曲线" },
        ["raw.lua"] = { enabled = false, meta = { name = nil, desc = nil },
            label = "raw.lua" },
    }
    engine.order = { "raw.lua", "scope_demo.lua" }

    local labels = engine:script_labels()
    eq("labels count", #labels, 2)
    eq("label falls back to filename", labels[1], "raw.lua")
    eq("label uses @name", labels[2], "绘制曲线")

    local m = engine:script_meta("scope_demo.lua")
    eq("script_meta desc", m.desc, "解析串口数值行")
    eq("script_meta unknown -> nil", engine:script_meta("ghost.lua"), nil)

    -- script_names() must STILL be the engine index keys (filenames).
    eq("names stay filenames[1]", engine:script_names()[1], "raw.lua")
    eq("names stay filenames[2]", engine:script_names()[2], "scope_demo.lua")

    -- pump() with no watcher is a safe no-op returning an empty list.
    local reloaded = engine:pump()
    eq("pump without watcher -> 0 reloads", #reloaded, 0)
end

-- ---- 6) real shipped scripts: every one declares a usable @name ------------
-- Guards the regression that matters in production: a script with no @name
-- silently falls back to its filename in the console list.  Read-only file
-- access (plain io.open), so this needs no uv.
do
    local META_HEAD = 64
    local function read_head(path)
        local f = io.open(path, "rb")
        if not f then return nil end
        local head = {}
        for _ = 1, META_HEAD do
            local line = f:read("*l")
            if line == nil then break end
            head[#head + 1] = line
        end
        f:close()
        return table.concat(head, "\n")
    end

    -- Resolve the scripts dir relative to this test file's repo layout.  Try
    -- both the repo-root invocation (xcom_lua/tests/..) and the xcom_lua/ cwd.
    local candidates = { "scripts", "xcom_lua/scripts" }
    local script_dir = nil
    for _, dir in ipairs(candidates) do
        local probe = io.open(dir .. "/scope_demo.lua", "rb")
        if probe then probe:close(); script_dir = dir; break end
    end
    ok("scripts dir found", script_dir ~= nil)

    if script_dir then
        local names = {
            "auto_reply.lua", "filter_log_level.lua", "highlight_keywords.lua",
            "scope_demo.lua", "send_convert_demo.lua", "send_file.lua",
            "settings_demo.lua", "sim_control.lua", "smoke_ui.lua",
            "wave_demo.lua", "绘制曲线.lua",
            -- llcom / UartAssist plugin ports
            "16进制数据.lua", "checksum.lua", "加上换行回车.lua",
            "解析换行回车的转义字符.lua", "GPS NMEA.lua", "ModbusCRC16.lua",
            "LRC校验.lua", "绘制曲线-多条.lua", "绘制曲线-解析结构体.lua",
            "时间戳前缀.lua", "大小写转换.lua", "数据截断.lua",
        }
        local missing = {}
        for _, name in ipairs(names) do
            local head = read_head(script_dir .. "/" .. name)
            if head then
                local parsed = meta.parse(head)
                if not parsed.name or parsed.name == "" then
                    missing[#missing + 1] = name
                end
            end
        end
        ok("all shipped scripts declare @name (missing: " ..
            table.concat(missing, ",") .. ")", #missing == 0)

        -- The label must never equal the raw filename when @name is declared.
        local parsed = meta.parse(read_head(script_dir .. "/scope_demo.lua"))
        ok("shipped @name differs from filename",
            parsed.name ~= "scope_demo.lua" and parsed.name ~= nil)
    end
end

-- ---- cleanup ---------------------------------------------------------------
print(string.format("script_meta: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
