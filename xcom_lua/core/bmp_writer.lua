--[[--------------------------------------------------------------------------
core/bmp_writer.lua - minimal 24-bpp BMP file writer (pure Lua).

Writes the classic uncompressed BITMAPFILEHEADER (14B) + BITMAPINFOHEADER
(40B) + bottom-up BGR rows padded to 4 bytes.  The GDI GetDIBits path in
core/waveform.lua requests TOP-DOWN rows (biHeight = -h), so `save` flips
row order while writing.

Pure Lua (string.bytes only) so it is unit-testable anywhere and reusable
for any pixel source.
------------------------------------------------------------------------]]--

local M = {}

-- Resolved at the TOP of the file on purpose: M.save below tests `ffi` with
-- `if jit and ffi`, and a `local` declared after that function compiles those
-- reads to GGET of the (nonexistent) global, so every save answered
-- "ffi unavailable" -- the wave.snapshot BMP export silently never wrote a
-- file.  tests/lint_fields.lua now scans this file too.
local ffi = require("ffi")
-- Snapshot paths can carry CJK (wave.snapshot(path) is called from a script or
-- a save dialog), so the write goes through the UTF-8 path boundary.
local fs_path = require("fs_path")

local function u16(v)
    return string.char(v % 256, math.floor(v / 256) % 256)
end

local function u32(v)
    v = v % 4294967296
    return string.char(v % 256,
        math.floor(v / 256) % 256,
        math.floor(v / 65536) % 256,
        math.floor(v / 16777216) % 256)
end

-- save(path, width, height, pixels, stride)
--   pixels : cdata uint8_t* (or Lua string via ffi.cast by caller) holding
--            TOP-DOWN rows: row 0 = top of the image, 3 bytes/px BGR order,
--            each row `stride` bytes (>= width*3, padded to 4).
-- Returns ok, err.
function M.save(path, width, height, pixels, stride)
    if jit and ffi then
        return M._save_ffi(path, width, height, pixels, stride)
    end
    return nil, "ffi unavailable"
end

function M._save_ffi(path, width, height, pixels, stride)
    local f, err = fs_path.open(path, "wb")
    if not f then return nil, tostring(err) end

    local data_size = stride * height
    -- BITMAPFILEHEADER: 'BM', size, reserved, reserved, offset-to-bits.
    local header = table.concat({
        "BM",
        u32(14 + 40 + data_size),
        u16(0), u16(0),
        u32(14 + 40),
    })
    -- BITMAPINFOHEADER (biHeight positive => bottom-up file storage).
    local info = table.concat({
        u32(40),          -- biSize
        u32(width),       -- biWidth
        u32(height),      -- biHeight (>0: rows stored bottom-up)
        u16(1),           -- biPlanes
        u16(24),          -- biBitCount
        u32(0),           -- biCompression = BI_RGB
        u32(data_size),   -- biSizeImage
        u32(2835), u32(2835),  -- 72 DPI pelPerMeter
        u32(0), u32(0),   -- colors used / important
    })
    f:write(header)
    f:write(info)
    -- Pixel rows: source is top-down; BMP files are bottom-up, so write the
    -- LAST source row first.  Each row is written with its full STRIDE
    -- (row_bytes + pad), because the format -- and the biSizeImage written
    -- above -- counts stride bytes per row: writing only row_bytes produced a
    -- file shorter than its own header claimed (66 vs 70 bytes at 2x2, the
    -- case where width*3 is not 4-byte aligned), which viewers render as a
    -- mangled bottom row.  The trailing pad bytes are whatever GetDIBits left
    -- there; harmless in the file and keeps this branch-free.
    for row = height - 1, 0, -1 do
        f:write(ffi.string(pixels + row * stride, stride))
    end
    f:close()
    return true
end

-- Pure-Lua row flip + pack for tests (no cdata): rows = array of BGR strings.
-- Returns the full file image as a string.
function M.build_image(width, height, rows_top_down)
    local stride = math.floor((width * 3 + 3) / 4) * 4
    local pad = string.rep("\0", stride - width * 3)
    local data = {}
    for row = height, 1, -1 do
        data[#data + 1] = rows_top_down[row]
        data[#data + 1] = pad
    end
    local pixel_blob = table.concat(data)
    return "BM" ..
        u32(14 + 40 + #pixel_blob) .. u16(0) .. u16(0) .. u32(14 + 40) ..
        u32(40) .. u32(width) .. u32(height) .. u16(1) .. u16(24) ..
        u32(0) .. u32(#pixel_blob) .. u32(2835) .. u32(2835) ..
        u32(0) .. u32(0) ..
        pixel_blob
end

return M
