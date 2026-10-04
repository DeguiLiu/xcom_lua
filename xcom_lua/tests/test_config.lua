-- test_config.lua - unit tests for core/config.lua (pure Lua, run with luajit)
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit test_config.lua

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local config = require("config")

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

local function check(label, condition)
    if condition then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label)
    end
end

-- 1) basic sections + typed parsing
local s = [[
window_x = 100
; comment line

[window]
w = 920
h = 650

[serial]
baud_rate = 115200
# another comment
dtr_enable = true
parity = 0
]]
local data = config.parse(s)
eq("default section", type(data[""]), "table")
eq("unsigned int", data["window"].w, 920)
eq("unsigned int2", data["window"].h, 650)
eq("bool true", data["serial"].dtr_enable, true)
eq("int 0 keeps number", data["serial"].parity, 0)
eq("float", data["serial"].baud_rate, 115200)
eq("int main-sect", data[""].window_x, 100)

-- 2) value typed edge cases
local d2 = config.parse("a=true\nb=false\nc=123\nd=-4\ne=1.5\nf=hello\ng=on\nh=off")
eq("a true", d2[""].a, true)
eq("b false", d2[""].b, false)
eq("c int", d2[""].c, 123)
eq("d negint", d2[""].d, -4)
eq("e float", d2[""].e, 1.5)
eq("f string keeps", d2[""].f, "hello")
eq("g on->true", d2[""].g, true)
eq("h off->false", d2[""].h, false)

-- strings that look like numbers must NOT coerce: "COM3"
local d3 = config.parse("port = COM3")
eq("COM3 stays string", d3[""].port, "COM3")

-- bare key without '='
local d4 = config.parse("barekey")
eq("bare key present", d4[""].barekey, nil)

-- 3) round-trip serialize -> parse
local sample = {
    [""] = { theme = "light", top_x = 100 },
    window = { w = 920, h = 650 },
    serial = { baud_rate = 115200, dtr_enable = true, data_bits = 8 },
    multipage = {
        ["entry.0.0.text"] = "ping",
        ["entry.0.0.enabled"] = true,
    },
}
local serialized = config.serialize(sample)
local reparsed = config.parse(serialized)
eq("rt theme", reparsed[""].theme, "light")
eq("rt window w", reparsed["window"].w, 920)
eq("rt serial baud", reparsed["serial"].baud_rate, 115200)
eq("rt bool", reparsed["serial"].dtr_enable, true)
eq("rt multipage text", reparsed["multipage"]["entry.0.0.text"], "ping")
eq("rt multipage enabled", reparsed["multipage"]["entry.0.0.enabled"], true)

-- 4) file round-trip
local tmp = os.tmpname()
local ok = config.save(tmp, sample)
eq("save ok", ok, true)
local loaded = config.load(tmp)
eq("load window", loaded["window"].w, 920)
eq("load bool", loaded["serial"].dtr_enable, true)
os.remove(tmp)

-- 5) typed getters with defaults
local cfg = { [""] = {}, window = { w = 900 } }
eq("get present", config.get(cfg, "window", "w", 800), 900)
eq("get default", config.get(cfg, "window", "h", 800), 800)
eq("get missing sec", config.get(cfg, "nope", "k", 7), 7)

-- 6) multi-entry helpers
config.set_multi_entry(cfg, 0, 3, "text", "abc")
config.set_multi_entry(cfg, 0, 3, "enabled", true)
eq("multi get text", config.get_multi_entry(cfg, 0, 3, "text", ""), "abc")
eq("multi get enabled", config.get_multi_entry(cfg, 0, 3, "enabled", false), true)

-- 7) empty / missing file load
local cfg2 = config.load("/nonexistent/definitely/missing.ini")
eq("missing load returns default blob", type(cfg2[""]), "table")

-- 8) open-time modem-line tri-state keys ([serial] dtr_open/rts_open) persist
--    as plain ints in 0/1/2; 2 (XCOM_LINE_LEAVE_ALONE) must survive a
--    save/load round-trip, not be coerced to a bool.
local tri = { [""] = {}, serial = { dtr_open = 0, rts_open = 2 } }
local tmp_tri = os.tmpname()
config.save(tmp_tri, tri)
local tri_rt = config.load(tmp_tri)
eq("rt dtr_open 0", tri_rt["serial"].dtr_open, 0)
eq("rt rts_open 2", tri_rt["serial"].rts_open, 2)
os.remove(tmp_tri)

-- 12) atomic save.  save() writes a sibling .tmp and renames it over the
--     target, so a process killed mid-write cannot leave a truncated config
--     (io.open(path,"wb") truncates first, which is why a periodic save is
--     only safe with this indirection).  The properties worth pinning: no
--     .tmp survives a successful save, the target holds exactly the new text,
--     a stale .tmp from an earlier failure is not read back as config, and a
--     save that cannot create its temp file leaves the existing config intact.
do
    local path = os.tmpname()
    -- A first generation, then an overwrite: the rename path on POSIX replaces
    -- the target in one step, on Windows the remove+rename fallback runs.
    eq("atomic: first save ok", config.save(path, { [""] = {}, a = { w = 1 } }), true)
    eq("atomic: overwrite ok", config.save(path, { [""] = {}, a = { w = 2 } }), true)
    eq("atomic: target holds the new value", config.load(path)["a"].w, 2)
    local tmp_left = io.open(path .. ".tmp", "rb")
    if tmp_left then tmp_left:close() end
    eq("atomic: no .tmp left behind", tmp_left == nil, true)

    -- A stale temp file (e.g. from a killed run) must not shadow the config:
    -- load() reads the target only.
    local stale = io.open(path .. ".tmp", "wb")
    stale:write("[a]\nw = 999\n")
    stale:close()
    eq("atomic: stale .tmp is ignored by load", config.load(path)["a"].w, 2)
    os.remove(path .. ".tmp")

    -- Unwritable target: the temp file cannot be created, so save reports
    -- false and the existing config is untouched (the old truncate-in-place
    -- behaviour would have destroyed it).
    local blocked = "/nonexistent-dir-xcom/config.ini"
    eq("atomic: unwritable path reports false", config.save(blocked, { [""] = {} }), false)
    eq("atomic: existing config survives a failed save", config.load(path)["a"].w, 2)
    os.remove(path)
end

-- 13) quoted literals.  A command is arbitrary text: it can carry a newline
--     (a multi-line block), a trailing space the device needs, or digits that
--     would otherwise read back as a NUMBER.  Bare values keep the historical
--     format (and stay readable in the file); anything that would not survive
--     that treatment is written as a quoted, escaped literal instead.
do
    local path = os.tmpname()
    local volatile = {
        [""] = {},
        cmd = {
            multi = "AT+CGDCONT=1\nAT+CGACT=1",   -- newline: would break the file
            spaced = "AT ",                       -- trailing space: trimmed away
            indented = "  AT",                    -- leading space: trimmed away
            numeric = "1234",                     -- would come back as a number
            booleanish = "true",                  -- would come back as a boolean
            quoted = 'say "hi"',                  -- embedded quote
            mirrored = "D:\\logs\\a.log",         -- embedded backslash
            cjk = "温度=25",                       -- non-ASCII payload
            hash = "cmd#1",                       -- '#' is only a comment at line start
            empty = "",                           -- empty string is not "missing"
        },
    }
    eq("quoted: save ok", config.save(path, volatile), true)
    local text = io.open(path, "rb"):read("*a")
    check("quoted: the newline was written escaped, not literal",
       text:find("\\n", 1, true) ~= nil and text:find("\nAT+CGACT", 1, true) == nil)
    local rt = config.load(path)
    for _, key in ipairs({ "multi", "spaced", "indented", "numeric",
                           "booleanish", "quoted", "mirrored", "cjk", "hash" }) do
        eq("quoted round-trip: " .. key, rt["cmd"][key], volatile.cmd[key])
    end
    eq("quoted round-trip: empty stays empty (not nil)", rt["cmd"].empty, "")
    -- A continuation line that leaked out of its value would show up as a key
    -- in the default section: the corruption this escaping exists to prevent.
    local stray = 0
    for key in pairs(rt[""] or {}) do
        if key:find("AT+", 1, true) then stray = stray + 1 end
    end
    eq("quoted: no continuation leaked into another section", stray, 0)
    os.remove(path)
end

-- 14) Backward compatibility: a file written in the historical bare format
--     (hand-edited, or produced before quoted literals existed) must load
--     exactly as it did -- a Windows path keeps its backslashes because the
--     unescaper only runs on values that were quoted.
do
    local path = os.tmpname()
    local f = io.open(path, "wb")
    f:write("[display]\nsave_path = D:\\logs\\a.log\ncharset = ASCII\n",
            "flag = true\nnum = 42\nblank =\n")
    f:close()
    local rt = config.load(path)
    eq("legacy bare path keeps its backslashes", rt["display"].save_path,
       "D:\\logs\\a.log")
    eq("legacy bare string", rt["display"].charset, "ASCII")
    eq("legacy bare boolean", rt["display"].flag, true)
    eq("legacy bare number", rt["display"].num, 42)
    eq("legacy bare empty value is nil", rt["display"].blank, nil)
    -- An unterminated quote must not swallow the value.
    local f2 = io.open(path, "wb")
    f2:write('[cmd]\nbroken = "unterminated\n')
    f2:close()
    eq("unterminated quote still yields the text",
       config.load(path)["cmd"].broken, '"unterminated')
    os.remove(path)
end

print(string.format("\nconfig tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
