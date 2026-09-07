-- CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no xorout)
-- Ported for LuaJIT 2.1 from clarkli86/crc16_ccitt (Apache-2.0),
-- https://github.com/clarkli86/crc16_ccitt
-- Original Author: Clark Li <clark.li86@gmail.com>
--
-- Changes vs upstream:
--   * bit32.* (Lua 5.2 stdlib) -> bit.* (LuaJIT BitOp): extract/lshift/bxor
--   * input is a Lua string, not a byte-array table
--   * returns a module table instead of installing a global
-- Standard test vector: crc16_ccitt("123456789") == 0x29B1

local bit = require("bit")
local band, rshift, lshift, bxor = bit.band, bit.rshift, bit.lshift, bit.bxor

local POLY = 0x1021

local _M = {}

local function hash(crc, byte)
    for i = 0, 7 do
        local b = band(rshift(byte, 7 - i), 1)
        local msb = band(rshift(crc, 15), 1)
        crc = band(lshift(crc, 1), 0xFFFF)
        if bxor(b, msb) == 1 then
            crc = bxor(crc, POLY)
        end
    end
    return crc
end

--- Compute CRC-16/CCITT-FALSE over a string.
-- @param s input string (raw bytes)
-- @return 16-bit CRC value
function _M.crc16_ccitt(s)
    local crc = 0xFFFF
    for i = 1, #s do
        crc = hash(crc, s:byte(i))
    end
    return band(crc, 0xFFFF)
end

-- alias matching upstream function name
_M.ccitt_16 = _M.crc16_ccitt

return _M