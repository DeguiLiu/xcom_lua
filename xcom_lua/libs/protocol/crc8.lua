-- crc8.lua - CRC-8/SMBUS (poly 0x07, init 0x00, no reflection, no xorout).
-- The most common hardware CRC-8. Table-driven, self-contained.
-- Standard test vector: crc8("123456789") == 0xF4

local bit = require("bit")
local bxor = bit.bxor
local rshift = bit.rshift

local _M = {}

-- lazily built table (256 entries)
local TABLE

local function build_table()
    TABLE = {}
    for i = 0, 255 do
        local crc = i
        for _ = 1, 8 do
            if crc >= 0x80 then
                crc = bxor(crc * 2, 0x07)
            else
                crc = crc * 2
            end
            -- keep 8 bits: crc*2 can reach 0x1FE before the xor
            if crc > 0xFF then crc = crc - 0x100 end
        end
        TABLE[i + 1] = crc
    end
end

--- Compute CRC-8/SMBUS over a string.
-- @param s input string (raw bytes)
-- @return 8-bit CRC value (crc8("123456789") == 0xF4)
function _M.crc8(s)
    if not TABLE then build_table() end
    local crc = 0x00
    for i = 1, #s do
        crc = TABLE[bit.band(bxor(crc, s:byte(i)), 0xFF) + 1]
    end
    return crc
end

return _M