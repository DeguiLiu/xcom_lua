-- test_ansi.lua - unit tests for core/ansi.lua (pure Lua, run with luajit)
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit test_ansi.lua

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local ansi = require("ansi")

local passed = 0
local failed = 0
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

-- helper: concatenate segment text
local function plain(segs)
    local parts = {}
    for _, s in ipairs(segs) do
        parts[#parts + 1] = s.text
    end
    return table.concat(parts)
end
local function total_text(segs)
    return plain(segs)
end

local ESC = "\27"

-- 1) plain text, no escapes -> single segment, fg=nil (default colour at render)
local segs = ansi.AnsiParser.new():feed("hello")
eq("plain seg count", #segs, 1)
eq("plain text", segs[1].text, "hello")
eq("plain default fg is nil", segs[1].fg, nil)
eq("plain not bold", segs[1].bold, false)

-- 2) a red fg segment
local segs = ansi.AnsiParser.new():feed(ESC .. "[31mRED" .. ESC .. "[0mreset")
-- segments: "RED" (fg red), "reset" (default)
eq("red seg count", #segs, 2)
eq("red text", segs[1].text, "RED")
eq("red fg", segs[1].fg, 0xA64242) -- "#A64242"
eq("red bold", segs[1].bold, false)
eq("red reset text", segs[2].text, "reset")
eq("red reset fg is nil", segs[2].fg, nil)

-- 3) bold via SGR 1 and reset via 22
local segs = ansi.AnsiParser.new():feed(ESC .. "[1mB" .. ESC .. "[22mN")
eq("bold count", #segs, 2)
eq("bold first", segs[1].bold, true)
eq("bold second", segs[2].bold, false)

-- 4) CSI cursor move (A) should be stripped, leaving "go"
local segs = ansi.AnsiParser.new():feed("g" .. ESC .. "[2A" .. "o")
eq("cursor move stripped text", total_text(segs), "go")

-- 5) cross-batch residue: split an SGR escape across two feeds
local p = ansi.AnsiParser.new()
local segs1 = p:feed("ab" .. ESC .. "[3")
eq("batch1 text", total_text(segs1), "ab")
eq("batch1 residue set", p.residue == (ESC .. "[3"), true)
local segs2 = p:feed("1mX")
eq("batch2 text", total_text(segs2), "X")
eq("batch2 fg is red", segs2[1].fg, 0xA64242) -- red (31), "#A64242"

-- 6) lone trailing ESC -> residue
local p = ansi.AnsiParser.new()
local segs = p:feed("x" .. ESC)
eq("trailing esc residue", p.residue, ESC)
eq("trailing esc visible", total_text(segs), "x")

-- 7) extended colour 38 (ignored best-effort, fg stays default/nil)
local segs = ansi.AnsiParser.new():feed(ESC .. "[38;5;200mC" .. ESC .. "[0m")
-- C should appear with default fg (38 ignored)
eq("extended fg ignored", segs[1].fg, nil)

-- 8) bg colour 41 (red background)
local segs = ansi.AnsiParser.new():feed(ESC .. "[41mX")
eq("bg red", segs[1].bg, 0xF7E6E5) -- "#F7E6E5"

-- 9) bright fg 91
local segs = ansi.AnsiParser.new():feed(ESC .. "[91mX")
eq("bright red fg", segs[1].fg, 0xBD5555) -- "#BD5555"

-- 10) SGR 0 resets both fg and bg
local segs = ansi.AnsiParser.new():feed(ESC .. "[31;41mA" .. ESC .. "[0mB")
eq("reset fg", segs[2].fg, nil)
eq("reset bg", segs[2].bg, nil)

-- 11) multi-param single SGR: 1;31 (bold red)
local segs = ansi.AnsiParser.new():feed(ESC .. "[1;31mX")
eq("bold+red fg", segs[1].fg, 0xA64242)
eq("bold+red bold", segs[1].bold, true)

-- 12) empty feed returns nothing, residue preserved
local p = ansi.AnsiParser.new()
local empty = p:feed("")
eq("empty feed", #empty, 0)

-- 13) malformed: ESC right before end followed by non-[ is treated literally?
-- "a\x1bX" -> ESC is stray literal, but index rules: buf[i]=ESC, i+1='X' != '[',
-- so ESC advances, 'X' is text.
local segs = ansi.AnsiParser.new():feed("a" .. ESC .. "X")
eq("stray esc literal text", total_text(segs), "a" .. ESC .. "X")

-- 14) raw C0 inside params -> malformed, residue carries
local p = ansi.AnsiParser.new()
local segs = p:feed(ESC .. "[3" .. "\0" .. "1m")
-- C0 (0x00) inside param -> _match_csi None -> residue carries whole. But our
-- is_csi via string byte comparison: 0x00 < 0x20 -> nil. visible kept 'ab'? no,
-- here just check that nothing wrong: residue is the whole escape.
ok("c0 malformed carried", #segs == 0 and #p.residue > 0)

print(string.format("\nansi tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
