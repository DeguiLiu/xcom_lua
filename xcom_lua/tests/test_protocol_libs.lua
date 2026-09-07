-- test_protocol_libs.lua - smoke test for third_party/lua-protocol-libs/
-- Covers struct.lua (iryont) and json.lua (rxi). CRC assertions are added
-- when the CRC vendor lands.
--
-- struct.lua format syntax (from source, NOT Python-style):
--   '<' / '>'   endianness switch (default little-endian)
--   b B h H i I l L   1/2/4/8-byte integers (signed via unpack sign-extend)
--   f d        4/8-byte floats (pure-Lua frexp/ldexp implementation)
--   s          zero-terminated string (pack appends NUL)
--   c<n>       fixed-width string, space-padded
--
-- Usage from repo root:
--   ./xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_protocol_libs.lua

local BASE = "xcom_lua/libs/protocol/"
package.path = BASE .. "?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(label, cond, extra)
    if cond then passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label .. (extra and ("  [" .. tostring(extra) .. "]") or ""))
    end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")", got == want)
end

-- ===========================================================================
-- struct.lua (iryont/lua-struct, MIT)
-- ===========================================================================
do
    local struct = require "struct"
    ok("struct: loads", type(struct) == "table" or type(struct) == "function")

    -- big-endian u16 roundtrip
    local packed = struct.pack(">H", 0x1234)
    eq("struct: pack >H length", #packed, 2)
    eq("struct: pack >H byte0", packed:byte(1), 0x12)
    eq("struct: pack >H byte1", packed:byte(2), 0x34)
    eq("struct: unpack >H", struct.unpack(">H", packed), 0x1234)

    -- little-endian h (i16, negative)
    local li = struct.pack("<h", -2)
    eq("struct: pack <h length", #li, 2)
    eq("struct: unpack <h", struct.unpack("<h", li), -2)

    -- mixed multi-field: u8 + u16be + u32le
    local m = struct.pack(">B H <I", 0xAA, 0x1234, 0xDEADBEEF)
    eq("struct: mixed pack length", #m, 1 + 2 + 4)
    local a, b, c = struct.unpack(">B H <I", m)
    eq("struct: mixed unpack B", a, 0xAA)
    eq("struct: mixed unpack H", b, 0x1234)
    eq("struct: mixed unpack I", c, 0xDEADBEEF)

    -- zero-terminated string ('s' appends NUL)
    local zs = struct.pack("s", "hello")
    eq("struct: 's' length", #zs, 6)
    eq("struct: 's' unpack", struct.unpack("s", zs), "hello")

    -- fixed-width string, space-padded ('c<n>')
    local cs = struct.pack("c16", "hello")
    eq("struct: c16 length", #cs, 16)
    eq("struct: c16 unpack", struct.unpack("c16", cs), "hello" .. string.rep(" ", 11))

    -- Modbus RTU frame layout: addr + func + start-reg + qty (all BE u8/u8/u16/u16)
    local frame = struct.pack(">BBHH", 0x01, 0x03, 0x0064, 0x0002)
    eq("struct: modbus frame length", #frame, 6)
    eq("struct: modbus frame hex",
       (frame:gsub(".", function(ch) return ("%02X"):format(ch:byte()) end)),
       "010300640002")

    -- float roundtrip (pure-Lua IEEE754 via frexp/ldexp)
    local f = struct.pack("<f", 3.5)
    eq("struct: float pack length", #f, 4)
    eq("struct: float roundtrip", struct.unpack("<f", f), 3.5)
end

-- ===========================================================================
-- json.lua (rxi/json.lua, MIT)
-- ===========================================================================
do
    local json = require "json"
    ok("json: loads", type(json) == "table")

    -- encode primitives
    eq("json: encode number", json.encode(42), "42")
    eq("json: encode string", json.encode("hi"), '"hi"')
    eq("json: encode bool", json.encode(true), "true")
    eq("json: encode nil", json.encode(nil), "null")

    -- decode primitives
    eq("json: decode number", json.decode("42"), 42)
    eq("json: decode string", json.decode('"hi"'), "hi")
    eq("json: decode bool", json.decode("true"), true)

    -- table roundtrip
    local t = { name = "xcom", port = "COM3", baud = 115200, nested = { a = 1 } }
    local enc = json.encode(t)
    local dec = json.decode(enc)
    eq("json: roundtrip name", dec.name, "xcom")
    eq("json: roundtrip baud", dec.baud, 115200)
    eq("json: roundtrip nested", dec.nested.a, 1)

    -- array
    local arr = json.decode("[1,2,3]")
    eq("json: array len", #arr, 3)
    eq("json: array [2]", arr[2], 2)

    -- CJK roundtrip (raw UTF-8 bytes pass through, no \u escaping needed)
    local cjk = json.decode(json.encode({ label = "中文串口" }))
    eq("json: CJK roundtrip", cjk.label, "中文串口")

    -- escape sequences
    eq("json: escaped quote", json.decode('"a\\"b"'), 'a"b')
    eq("json: escaped newline", json.decode('"a\\nb"'), "a\nb")
end

-- ===========================================================================
-- CRC family
--   crc32.lua      (davidm/lua-digest-crc32lua, MIT — vendored verbatim)
--   crc16_ccitt.lua(clarkli86 ported bit32->bit, Apache-2.0)
--   crc16_modbus.lua / crc8.lua (self-contained table-driven)
-- All expected values are the standard "123456789" check values.
-- ===========================================================================
do
    local CRC = require "crc32"
    ok("crc32: loads", type(CRC) == "table" and type(CRC.crc32) == "function")
    -- BitOp returns signed 32-bit; normalize via % 2^32 (per module docs)
    eq("crc32: standard vector", CRC.crc32("123456789") % 2^32, 0xCBF43926)
    eq("crc32: 'test' vector", CRC.crc32("test") % 2^32, 0xD87F7E0C)
    -- streaming: crc32('st', crc32('te')) == crc32('test')
    eq("crc32: streaming", CRC.crc32("st", CRC.crc32("te")) % 2^32, 0xD87F7E0C)
end

do
    local m = require "crc16_ccitt"
    ok("crc16_ccitt: loads", type(m) == "table")
    eq("crc16_ccitt: standard vector", m.crc16_ccitt("123456789"), 0x29B1)
    eq("crc16_ccitt: empty", m.crc16_ccitt(""), 0xFFFF)
end

do
    local m = require "crc16_modbus"
    ok("crc16_modbus: loads", type(m) == "table")
    eq("crc16_modbus: standard vector", m.crc16_modbus("123456789"), 0x4B37)
    eq("crc16_modbus: empty", m.crc16_modbus(""), 0xFFFF)
    -- wire bytes are little-endian (lo, hi)
    local b = m.crc16_modbus_bytes("123456789")
    eq("crc16_modbus: bytes len", #b, 2)
    eq("crc16_modbus: lo byte", b:byte(1), 0x37)
    eq("crc16_modbus: hi byte", b:byte(2), 0x4B)
end

do
    local m = require "crc8"
    ok("crc8: loads", type(m) == "table")
    eq("crc8: standard vector", m.crc8("123456789"), 0xF4)
    eq("crc8: empty", m.crc8(""), 0x00)
end

print(string.format("---- protocol-libs smoke: %d passed, %d failed ----",
                    passed, failed))
if failed > 0 then os.exit(1) end