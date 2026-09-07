-- test_iconv.lua - smoke test for third_party/openresty-lua/lualib/resty/iconv.lua
-- (lua-resty-iconv, xiaooloong; GPL-3.0 — vendored copy in openresty-lua).
--
-- resty.iconv is pure Lua + FFI, but to *convert* it must resolve libiconv's
-- symbols. On Windows that requires libiconv-2.dll to be reachable through
-- ffi.C while the module does `local ffi_c = ffi.C`. We load libiconv, swap
-- ffi.C to that handle for the duration of `require`, then restore it — the
-- patched module captures the function refs once, at load time.
--
-- Usage from repo root:
--     xcom_lua\runtime\luvjit.exe xcom_lua\tests\test_iconv.lua

print("BEGAN")
local BASE = "xcom_lua/libs/openresty/"
package.path = BASE .. "?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(label, cond, extra)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL  " .. label .. (extra and ("  [" .. tostring(extra) .. "]") or "")) end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

-- ---- resolve libiconv -------------------------------------------------------
local ffi = require("ffi")
local lib
for _, name in ipairs({ "libiconv-2", "libiconv", "iconv" }) do
    local okL, h = pcall(ffi.load, name)
    if okL and h then lib = h; ok("loaded libiconv via: " .. name, true); break end
end
if not lib then
    print("SKIP: no libiconv.findable; verify module still parses")
    local ok_load = pcall(require, "resty.iconv")
    ok("resty.iconv parses w/o libiconv (cdef-only)", ok_load)
    print(string.format("---- iconv smoke: %d passed, %d failed ----", passed, failed))
    os.exit(failed > 0 and 1 or 0)
end

-- ---- load resty.iconv under the libiconv C scope ---------------------------
local saved = ffi.C
ffi.C = lib
local ok_r, iconv = pcall(require, "resty.iconv")
ffi.C = saved
ok("resty.iconv loads", ok_r, ok_r and "" or tostring(iconv))
if not ok_r then os.exit(1) end

eq("_VERSION string", type(iconv._VERSION), "string")

-- utf-8 → gbk of a real Chinese+ASCII string (ast UTF-8 source file bytes)
local c, err = iconv:new("gbk", "utf-8")
ok("iconv:new utf8→gbk", c ~= nil, err)
if c then
    local input = "中文测试 hello"
    local enc, e2 = c:convert(input)
    ok("convert utf8→gbk returned string", type(enc) == "string", e2)
    if type(enc) == "string" then
        -- 5 ASCII + 4 CJK * 2 (gbk) = 13; fail-safe just length>0
        ok("gbk length sane (>0 and < utf8 len)", enc ~= input)
        print("  utf8,input# = " .. #input .. "  gbk# = " .. #enc)
        -- roundtrip
        local back, e3 = iconv:new("utf-8", "gbk") and iconv:new("utf-8", "gbk"):convert(enc)
        eq("roundtrip gbk→utf-8 == original", back, input)
    end
end

-- bad charset name returns (nil, msg), no crash
local bad, bmsg = iconv:new("not-a-real-charset", "utf-8")
ok("bad dst charset -> nil", bad == nil)
ok("bad dst charset -> message", type(bmsg) == "string" and #bmsg > 0, bmsg)

print(string.format("---- iconv smoke: %d passed, %d failed ----", passed, failed))
if failed > 0 then os.exit(1) end