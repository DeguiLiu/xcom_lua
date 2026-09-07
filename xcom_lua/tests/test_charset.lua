-- test_charset.lua - unit tests for core/charset.lua.
-- Pure-Lua parts run anywhere; live Win32 conversion is Windows-guarded.
-- Usage: runtime\luvjit.exe tests\test_charset.lua

package.path = "./core/?.lua;" .. package.path
local charset = require("charset")

local passed, failed = 0, 0
local function ok(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end

-- ---- 1) code-page table ------------------------------------------------------
eq("ASCII passthrough", charset.CP.ASCII, nil)
eq("UTF-8 passthrough", charset.CP["UTF-8"], nil)
eq("GB2312 -> 936", charset.CP.GB2312, 936)
eq("BIG5 -> 950", charset.CP.BIG5, 950)
eq("SHIFT-JIS -> 932", charset.CP["SHIFT-JIS"], 932)
eq("UTF-16 special", charset.CP["UTF-16"], "utf16")

-- ---- 2) set()/name() ---------------------------------------------------------
ok("set ASCII", charset.set("ASCII"))
eq("name ASCII", charset.name(), "ASCII")
ok("set GB2312", charset.set("GB2312"))
eq("name GB2312", charset.name(), "GB2312")
ok("set unknown rejected", charset.set("KOI8-R") == false)
eq("unknown keeps previous", charset.name(), "GB2312")
charset.set("ASCII")

-- ---- 3) DBCS lead-byte classification (pure logic) ---------------------------
ok("GBK lead 0x81", charset._dbcs_lead_byte(0x81, 936))
ok("GBK lead 0xFE", charset._dbcs_lead_byte(0xFE, 936))
ok("GBK not-lead 0x41", not charset._dbcs_lead_byte(0x41, 936))
ok("GBK not-lead 0x80", not charset._dbcs_lead_byte(0x80, 936))
ok("SJIS lead 0x89", charset._dbcs_lead_byte(0x89, 932))
ok("SJIS lead 0xE0", charset._dbcs_lead_byte(0xE0, 932))
ok("SJIS not-lead 0xA5 (katakana)", not charset._dbcs_lead_byte(0xA5, 932))
ok("SJIS not-lead 0xDF", not charset._dbcs_lead_byte(0xDF, 932))
ok("BIG5 lead 0xA4", charset._dbcs_lead_byte(0xA4, 950))

-- ---- 4) passthrough conversion ------------------------------------------------
eq("ASCII convert identity", charset.convert("hello"), "hello")
charset.set("UTF-8")
eq("UTF-8 convert identity", charset.convert("caf\195\169"), "caf\195\169")
charset.set("ASCII")

local is_windows = package.config:sub(1, 1) == "\\"
if not is_windows then
    print(string.format("charset: %d passed, %d failed (Win32 conversion skipped)",
        passed, failed))
    if failed > 0 then os.exit(1) end
    return
end

-- ---- 5) live GB2312 -> UTF-8 ("中文" = D6 D0 CE C4) ---------------------------
charset.set("GB2312")
local utf8_zh = charset.convert("\214\208\206\196")
eq("GB2312 中文 -> UTF-8", utf8_zh, "\228\184\173\230\150\135")

-- ASCII inside GB2312 stream passes through
eq("GB2312 ascii mixed", charset.convert("A"), "A")

-- ---- 6) DBCS split across batches ---------------------------------------------
-- "中" (D6 D0) torn: lead byte in batch 1, trail byte in batch 2.
charset.reset()
local part1 = charset.convert("\214")         -- lead byte held pending
eq("split batch1 holds", part1, nil)
local part2 = charset.convert("\208\206\196") -- trail + "文"
eq("split batch2 completes", part2, "\228\184\173\230\150\135")

-- ---- 7) UTF-16LE -> UTF-8 ------------------------------------------------------
-- "中" = U+4E2D -> LE bytes 2D 4E
charset.set("UTF-16")
eq("UTF-16 中", charset.convert("\45\78"), "\228\184\173")

-- odd byte split: hold 1 byte
charset.reset()
local u1 = charset.convert("\45")
eq("utf16 odd byte held", u1, nil)
local u2 = charset.convert("\78\45\78")
eq("utf16 odd byte joins", u2, "\228\184\173\228\184\173")

-- lone high surrogate held until pair arrives (U+1F600 = D83D DE00)
charset.reset()
local s1 = charset.convert("\61\216")   -- D83D alone
eq("lone surrogate held", s1, nil)
local s2 = charset.convert("\0\222")    -- DE00 arrives
eq("surrogate pair completes", s2, "\240\159\152\128")

-- ---- 8) flush() drains pending --------------------------------------------------
charset.set("GB2312")
charset.reset()
local held = charset.convert("\214")    -- dangling lead byte
eq("flush input pending", held, nil)
local flushed = charset.flush()
-- An orphan DBCS lead decodes to the code page default char ('?') — the
-- honest representation of a torn byte at stream end.
eq("flush emits default char", flushed, "?")

charset.set("ASCII")
print(string.format("charset: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
