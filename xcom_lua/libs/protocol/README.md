# lua-protocol-libs

Pure-Lua protocol-development libraries for xcom_lua (LuaJIT 2.1). All are
single-file, MIT/Apache licensed (or self-written), and verified by smoke
test with **standard check vectors**.

## Contents

| File | What | Source | License |
|---|---|---|---|
| `struct.lua` | `pack/unpack(">BBHH", ...)` binary frames | [iryont/lua-struct](https://github.com/iryont/lua-struct) v0.9.2 | MIT |
| `json.lua` | JSON encode/decode (UTF-8 native) | [rxi/json.lua](https://github.com/rxi/json.lua) | MIT |
| `crc32.lua` | CRC-32 (IEEE/zlib), streaming API | [davidm/lua-digest-crc32lua](https://github.com/davidm/lua-digest-crc32lua) | MIT (same as Lua) |
| `crc16_ccitt.lua` | CRC-16/CCITT-FALSE (0x1021/0xFFFF) | ported from [clarkli86/crc16_ccitt](https://github.com/clarkli86/crc16_ccitt) | Apache-2.0 |
| `crc16_modbus.lua` | CRC-16/Modbus (0xA001, RTU wire order helper) | self-written (table cross-checked) | — |
| `crc8.lua` | CRC-8/SMBUS (0x07) | self-written | — |

## struct.lua format syntax (NOT Python-style)

```
< / >              endianness switch (default little-endian)
b B h H i I l L    1/2/4/8-byte integers
f d                4/8-byte floats (pure-Lua frexp/ldexp)
s                  zero-terminated string (pack appends NUL)
c<n>               fixed-width string, space-padded
```

Modbus RTU read frame: `struct.pack(">BBHH", 0x01, 0x03, 0x0064, 0x0002)`.

## CRC usage

```lua
local c32   = require "crc32"          -- davidm; BitOp returns signed 32-bit
local v     = c32.crc32("123456789") % 2^32   -- 0xCBF43926
local ccitt = require "crc16_ccitt"    -- ported to LuaJIT bit
ccitt.crc16_ccitt("123456789")         -- 0x29B1
local mod   = require "crc16_modbus"
mod.crc16_modbus("123456789")          -- 0x4B37
mod.crc16_modbus_bytes("...frame...")  -- 2 bytes, lo-first (RTU wire order)
local c8    = require "crc8"
c8.crc8("123456789")                   -- 0xF4
```

### Patches / notes vs upstream

- **crc16_ccitt.lua**: upstream uses Lua 5.2 `bit32.*` — replaced with LuaJIT
  BitOp `bit.*` (`extract`→`band(rshift(..))`, `lshift`+mask). Input changed
  from byte-array table to string. Returns module table (upstream installed
  a global).
- **crc32.lua**: vendored verbatim. Returns **signed** 32-bit under BitOp;
  normalize with `% 2^32` (documented in its header).
- **crc16_modbus.lua / crc8.lua**: written from the algorithm spec because
  the only existing pure-Lua candidates (vic111/crc16_modbus et al.) have no
  license and leak globals (`table = {...}`!). The Modbus reflected table is
  the canonical public-domain constant table.

## Why no "one library with all CRCs" exists

Surveyed 2026-09-05 (GitHub + LuaRocks): every multi-algorithm Lua CRC
library is either a C module (luacrc16, luacrc32 on LuaRocks), Lua-5.3-only
syntax (`~`, `>>`, `&` — user-none/lua-hashings, AleksandrBelous/CRC16_Parametric),
unlicensed, or global-polluting. Hence the 3-way composition above.

## Test

```
cd D:/workspace/SSCOM_lua
./xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_protocol_libs.lua
# ---- protocol-libs smoke: 51 passed, 0 failed ----
```

Includes the four standard check vectors ("123456789"): CRC-32 0xCBF43926,
CRC-16/Modbus 0x4B37, CRC-16/CCITT-FALSE 0x29B1, CRC-8/SMBUS 0xF4.