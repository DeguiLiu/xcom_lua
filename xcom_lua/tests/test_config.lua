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

print(string.format("\nconfig tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
