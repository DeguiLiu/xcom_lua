-- test_shipped_scripts.lua - pure-Lua load + behavior tests for the plugin
-- scripts in scripts/ (the llcom/UartAssist ports plus the originals).
--
-- No luv: the Linux dev box has no Linux luv build, so core/script_engine.lua
-- is required only for its pure surface (string.toHex/fromHex/split extensions
-- are installed at require time) and the scripts are executed inside a
-- hand-built stub environment that mirrors the engine's script surface
-- (uart / on / filter / highlight / log / sys / wave / apiAddPoint / struct /
-- ui).  That lets us assert the registered send/receive hooks actually
-- transform bytes as documented, not just that the files parse.
--
-- Usage (Linux, from xcom_lua/):
--     /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_shipped_scripts.lua

package.path = "./core/?.lua;./libs/protocol/?.lua;" .. package.path
require("script_engine")          -- installs string.toHex/fromHex/split/utf8Len
local ok_struct, struct = pcall(require, "struct")

local passed, failed = 0, 0
local function ok(label, cond, extra)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end

-- ---- scripts dir resolution (repo-root or xcom_lua/ cwd) -------------------
local script_dir = nil
for _, dir in ipairs({ "scripts", "xcom_lua/scripts" }) do
    local probe = io.open(dir .. "/绘制曲线.lua", "rb")
    if probe then probe:close() script_dir = dir break end
end
ok("scripts dir found", script_dir ~= nil)
if not script_dir then
    print(string.format("shipped_scripts: %d passed, %d failed", passed, failed))
    os.exit(1)
end

-- ---- stub environment mirroring core/script_engine.lua ----------------------
local function make_env(h)
    local env = {
        string = string, table = table, math = math,
        os = { date = os.date, time = os.time, clock = os.clock,
               difftime = os.difftime, getenv = os.getenv },
        ipairs = ipairs, pairs = pairs, next = next, select = select,
        unpack = unpack, type = type, tostring = tostring, tonumber = tonumber,
        pcall = pcall, xpcall = xpcall, error = error, assert = assert,
        setmetatable = setmetatable, getmetatable = getmetatable,
        rawget = rawget, rawset = rawset, rawequal = rawequal,
        _SCRIPT = "test", _PATH = "test",
        struct = ok_struct and struct or nil,
    }
    env.on = {
        receive = function(fn) h.recv = fn end,
        send = function(fn) h.send = fn end,
    }
    env.uart = {
        send = function(data) h.sent = data return true end,
        send_hex = function() return true end,
        is_open = function() return true end,
    }
    env.filter = { keep = function() end, drop = function() end, clear = function() end }
    env.highlight = { rule = function() end, clear = function() end }
    local logs = {} h.logs = logs
    local function mk(level)
        return function(tag, ...)
            local parts = {}
            for i = 1, select("#", ...) do
                parts[#parts + 1] = tostring(select(i, ...))
            end
            logs[#logs + 1] = level .. ":" .. tostring(tag) .. ":" ..
                table.concat(parts, " ")
        end
    end
    env.log = { trace = mk("trace"), debug = mk("debug"), info = mk("info"),
                warn = mk("warn"), error = mk("error"), fatal = mk("fatal") }
    env.sys = {
        now = function() return h.now or 1699999999123 end,
        timer_start = function() end, timer_loop_start = function() end,
        timer_stop = function() end,
    }
    env.wave = { config = function() end, push = function() return true end,
                 show = function() end, hide = function() end,
                 visible = function() return false end, clear = function() end }
    h.points = {}
    env.apiAddPoint = function(v, line)
        h.points[#h.points + 1] = { v = v, line = line }
    end
    env.ui = { page = function() end, event = function() end }
    env.print = function() end
    env.base64 = { encode = function() return "" end }
    return env
end

-- compile + run one script; returns true|nil, err
local function run_script(name, h)
    local path = script_dir .. "/" .. name
    local chunk, err = loadfile(path)
    if not chunk then return nil, "compile: " .. tostring(err) end
    local env = make_env(h)
    setfenv(chunk, env)
    local okk, run_err = pcall(chunk)
    if not okk then return nil, "run: " .. tostring(run_err) end
    return true
end

-- ===========================================================================
-- 1) every shipped script must compile (loadfile), new ones included
-- ===========================================================================
local SHIPPED = {
    -- originals
    "auto_reply.lua", "filter_log_level.lua", "highlight_keywords.lua",
    "scope_demo.lua", "send_convert_demo.lua", "send_file.lua",
    "settings_demo.lua", "sim_control.lua", "smoke_ui.lua",
    "wave_demo.lua", "绘制曲线.lua",
    -- llcom / UartAssist ports added with this change
    "16进制数据.lua", "加上换行回车.lua",
    "解析换行回车的转义字符.lua", "绘制曲线-多条.lua",
    "绘制曲线-解析结构体.lua",
    "时间戳前缀.lua", "大小写转换.lua", "数据截断.lua",
}
for _, name in ipairs(SHIPPED) do
    local chunk, err = loadfile(script_dir .. "/" .. name)
    ok("compiles: " .. name, chunk ~= nil, err)
end

-- ===========================================================================
-- 2) send-convert plugins
-- ===========================================================================
do -- 16进制数据
    local h = {} local okk, err = run_script("16进制数据.lua", h)
    ok("16进制数据 loads+runs", okk, err)
    eq("16进制数据 registers on.send", type(h.send), "function")
    local out = h.send("31 32 33 34")
    eq("hex decode #bytes", #out, 4)
    eq("hex decode b1", out:byte(1), 0x31)
    eq("hex decode b4", out:byte(4), 0x34)
    eq("hex decode space separated", h.send("41 42"), "AB")
    eq("empty/invalid hex aborts send", h.send("zz--"), nil)
end

do -- 加上换行回车
    local h = {} local okk, err = run_script("加上换行回车.lua", h)
    ok("加上换行回车 loads+runs", okk, err)
    eq("append CRLF", h.send("AT"), "AT\r\n")
end

do -- 解析换行回车的转义字符
    local h = {} local okk, err = run_script("解析换行回车的转义字符.lua", h)
    ok("转义字符 loads+runs", okk, err)
    eq("literal \\r\\n -> CRLF", h.send("AT\\r\\n"), "AT\r\n")
    eq("literal \\t -> TAB", h.send("A\\tB"), "A\tB")
    eq("no escape unchanged", h.send("plain"), "plain")
end

-- ===========================================================================
-- 3) receive-convert plugins
-- ===========================================================================
do -- 绘制曲线-多条
    local h = {} local okk, err = run_script("绘制曲线-多条.lua", h)
    ok("绘制曲线-多条 loads+runs", okk, err)
    eq("registers on.receive", type(h.recv), "function")
    local ret = h.recv("1.5,2.5\r\n")
    eq("returns text unchanged", ret, "1.5,2.5\r\n")
    eq("two points pushed", #h.points, 2)
    eq("point0 ch0", h.points[1].line, 0) eq("point0 val", h.points[1].v, 1.5)
    eq("point1 ch1", h.points[2].line, 1) eq("point1 val", h.points[2].v, 2.5)
    h.points = {}
    h.recv("-3,notanumber\r\n")
    eq("non-numeric pair ignored", #h.points, 0)
end

do -- 绘制曲线-解析结构体
    local h = {} local okk, err = run_script("绘制曲线-解析结构体.lua", h)
    ok("结构体曲线 loads+runs", okk, err)
    local frame = string.char(5, 0xE8, 0x03, 0x00, 0x00,
                                 0x00, 0x00, 0xC0, 0x3F) .. string.char(0x0A)
    local ret = h.recv(frame)
    eq("struct frame returned unchanged", ret, frame)
    eq("three points pushed", #h.points, 3)
    eq("u8 -> ch0 val 5", h.points[1].v, 5)
    eq("i32 -> ch1 val 1000", h.points[2].v, 1000)
    eq("f32 -> ch2 val 1.5", h.points[3].v, 1.5)
    eq("channels 0/1/2", h.points[1].line + h.points[2].line * 10 +
        h.points[3].line * 100, 210)
    h.points = {}
    h.recv("bad")   -- too short -> ignored
    eq("short frame ignored", #h.points, 0)
end

do -- 时间戳前缀
    local h = { now = 1699999999123 } local okk, err = run_script("时间戳前缀.lua", h)
    ok("时间戳前缀 loads+runs", okk, err)
    local out = h.recv("OK\nERROR\n")
    ok("timestamp format", out:find("^%[%d%d:%d%d:%d%d%.%d%d%d%] OK\n") ~= nil, out)
    ok("second line stamped",
        out:find("\n%[%d%d:%d%d:%d%d%.%d%d%d%] ERROR\n") ~= nil, out)

    -- A line split across two batches must carry ONE stamp, at its true start.
    -- Stamping every non-newline segment would give the continuation its own
    -- timestamp and present one event as two, which is the defect this pins.
    local h2 = { now = 1699999999123 }
    ok("时间戳前缀 reloads", run_script("时间戳前缀.lua", h2))
    local first = h2.recv("PART")
    local second = h2.recv("IAL\n")
    local stamps = 0
    for _ in first:gmatch("%[%d%d:%d%d:%d%d%.%d%d%d%]") do stamps = stamps + 1 end
    for _ in second:gmatch("%[%d%d:%d%d:%d%d%.%d%d%d%]") do stamps = stamps + 1 end
    eq("split line stamped exactly once", stamps, 1)
    ok("continuation carries no stamp",
        second:find("%[%d%d:%d%d:%d%d%.%d%d%d%]") == nil, second)
    ok("split line reassembles",
        (first .. second):find("PARTIAL\n", 1, true) ~= nil, first .. second)
end

do -- 大小写转换
    local h = {} local okk, err = run_script("大小写转换.lua", h)
    ok("大小写转换 loads+runs", okk, err)
    eq("upper default", h.recv("ok\r\n"), "OK\r\n")
end

do -- 数据截断
    local h = {} local okk, err = run_script("数据截断.lua", h)
    ok("数据截断 loads+runs", okk, err)
    local long = string.rep("b", 300)
    local out = h.recv(long)
    eq("truncated length", #out, 256 + 3)
    eq("ellipsis suffix", out:sub(-3), "...")
    eq("short line untouched", h.recv("short"), "short")
end

-- ---- summary ---------------------------------------------------------------
print(string.format("shipped_scripts: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
