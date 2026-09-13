--[[--------------------------------------------------------------------------
core/charset.lua - display-side charset conversion (ASCII/UTF-8 passthrough,
GB2312/BIG5/SHIFT-JIS -> UTF-8, UTF-16LE -> UTF-8).

Design notes:
  * The core's text formatter passes every byte >= 0x20 through untouched, so
    UTF-8 arrives intact and needs no work; GBK/BIG5/SJIS bytes also arrive
    intact but must be RECODED before display (the ImGui font decodes UTF-8);
    UTF-16 arrives as 16-bit units.
  * Conversion runs on the display path only — the auto-save log keeps the
    raw bytes (window.lua appends the RAW batch before this stage).
  * Two-pass MultiByteToWideChar/WideCharToMultiByte through grown-only FFI
    scratch buffers (the pattern xcom_ffi.drain_display uses), so a steady
    stream reuses allocations.
  * Statefulness across batches: a DBCS lead byte cut at a batch boundary
    would decode as '?' — hold a suspicious trailing byte back (best effort;
    64 KiB batches make the split case rare).  UTF-16 keeps odd bytes and
    lone surrogates pending until the pair arrives.

Windows-only (kernel32); every entry point is a no-op passthrough when the
code page is nil (ASCII / UTF-8) or when Win32 is unavailable.
------------------------------------------------------------------------]]--

local ffi = require("ffi")

local M = {}

-- Own cdef for the two kernel32 converters (win32.lua also declares them;
-- duplicate declarations of the same signature are legal in LuaJIT cdef).
ffi.cdef[[
int MultiByteToWideChar(unsigned int codePage, unsigned long flags,
                        const char* src, int srcLen,
                        unsigned short* dst, int dstLen);
int WideCharToMultiByte(unsigned int codePage, unsigned long flags,
                        const unsigned short* src, int srcLen,
                        char* dst, int dstLen, const char* defChar,
                        int* usedDefChar);
]]-- Code page per charset name.  Lua tables cannot store nil values, so the
-- two passthrough charsets use `false` (present in the table, converts to a
-- nil code page) — `convert` treats cp==false and nil identically.
local CP_TABLE = {
    ASCII = false,
    ["UTF-8"] = false,
    GB2312 = 936,
    GBK = 936,
    BIG5 = 950,
    ["SHIFT-JIS"] = 932,
    ["SHIFT_JIS"] = 932,
    UTF16 = "utf16",
    ["UTF-16"] = "utf16",
    ["UTF-16LE"] = "utf16",
}
M.CP = {
    -- Legacy view kept for tests/inspection: passthrough names map to nil.
    ASCII = nil, ["UTF-8"] = nil,
    GB2312 = 936, GBK = 936, BIG5 = 950,
    ["SHIFT-JIS"] = 932, ["SHIFT_JIS"] = 932,
    UTF16 = "utf16", ["UTF-16"] = "utf16", ["UTF-16LE"] = "utf16",
}

local CP_UTF8 = 65001
local MB_ERR_INVALID_CHARS = 0x00000008

local kernel32 = (function()
    -- Resolved lazily and defensively: this module is required from main
    -- paths that also run on non-Windows hosts (syntax checks / unit tests).
    if package.config:sub(1, 1) ~= "\\" then return nil end
    local ok, k = pcall(ffi.load, "kernel32")
    return ok and k or nil
end)()

-- Grown-only scratch buffers (bytes in -> wide -> utf8 out).
local scratch = { wide = nil, wide_n = 0, utf8 = nil, utf8_n = 0 }

local function ensure_wide(n)
    if scratch.wide_n < n then
        scratch.wide_n = n
        scratch.wide = ffi.new("uint16_t[?]", n)
    end
    return scratch.wide
end

local function ensure_utf8(n)
    if scratch.utf8_n < n then
        scratch.utf8_n = n
        scratch.utf8 = ffi.new("char[?]", n)
    end
    return scratch.utf8
end

-- ---------------------------------------------------------------------------
-- Module state: selected charset + pending bytes
-- ---------------------------------------------------------------------------

local current_name = "ASCII"
local current_cp = nil       -- number code page, "utf16", or nil
local pending = ""           -- bytes held back from the previous batch
-- DBCS lead-byte ranges for the supported pages (lead + trail = 2 bytes).
--   936/950 (GBK/BIG5): lead 0x81..0xFE
--   932 (SJIS): lead 0x81..0x9F and 0xE0..0xEF (0xA0..0xDF is single-byte
--   half-width katakana, 0xF0..0xFF reserved)
local DBCS_LEAD = {
    [936] = { 0x81, 0xFE },
    [950] = { 0x81, 0xFE },
    [932] = { 0x81, 0x9F },
}
local SJIS_LEAD2 = { 0xE0, 0xEF }

local function dbcs_lead_byte(b, cp)
    local range = DBCS_LEAD[cp]
    if not range then return false end
    if b >= range[1] and b <= range[2] then
        return true
    end
    if cp == 932 and b >= SJIS_LEAD2[1] and b <= SJIS_LEAD2[2] then
        return true
    end
    return false
end
M._dbcs_lead_byte = dbcs_lead_byte  -- test hook

function M.set(name)
    if name == nil or name == "" then
        current_name = "ASCII"
        current_cp = nil
        pending = ""
        return true
    end
    -- Distinguish "known passthrough" (ASCII/UTF-8 -> false) from an
    -- unknown name by checking the KEY set.
    local cp = CP_TABLE[name]
    if cp == nil then
        return false  -- unknown name: keep the previous setting
    end
    current_name = name
    if cp == false then
        current_cp = nil        -- passthrough (ASCII / UTF-8)
    else
        current_cp = cp
    end
    pending = ""
    return true
end

function M.name()
    return current_name
end

function M.reset()
    pending = ""
end

-- ---------------------------------------------------------------------------
-- UTF-16LE -> UTF-8 (surrogate-aware)
-- ---------------------------------------------------------------------------

local function utf16_to_utf8(text)
    -- Hold back an odd trailing byte; hold back a lone high surrogate so it
    -- can pair with the next batch's low surrogate.
    local data = pending .. text
    pending = ""
    local n = #data
    if n % 2 == 1 then
        pending = data:sub(-1)
        data = data:sub(1, n - 1)
        n = n - 1
    end
    -- Scan for a trailing unpaired high surrogate (0xD800..0xDBFF at the
    -- very end without its low half in this batch).
    if n >= 2 then
        local w1 = data:byte(n - 1) + data:byte(n) * 256
        if w1 >= 0xD800 and w1 <= 0xDBFF then
            pending = data:sub(n - 1) .. pending
            data = data:sub(1, n - 2)
        end
    end
    if #data == 0 then return nil end
    local units = #data / 2
    local wide = ffi.cast("const uint16_t*", ffi.cast("const char*", data))
    local needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide, units,
        nil, 0, nil, nil)
    if needed <= 0 then return data end  -- undecodable: show raw
    local buf = ensure_utf8(needed + 1)
    local written = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide, units,
        buf, needed, nil, nil)
    if written <= 0 then return data end
    return ffi.string(buf, written)
end

-- ---------------------------------------------------------------------------
-- DBCS code page -> UTF-8
-- ---------------------------------------------------------------------------

-- Position-aware scan: walk the DBCS stream from the start (each lead byte
-- consumes its trail byte) and report whether the FINAL byte sits in a lead
-- position — i.e. its trail byte has not arrived in this batch.  A numeric
-- check alone misfires: 0xD0 in "D6 D0" is a trail byte that also happens to
-- be inside the lead range.
local function ends_with_dangling_lead(data, cp)
    local i = 1
    local n = #data
    while i <= n do
        local b = data:byte(i)
        if dbcs_lead_byte(b, cp) then
            if i == n then return true end   -- lead without its trail
            i = i + 2                        -- skip lead + trail
        else
            i = i + 1
        end
    end
    return false
end
M._ends_with_dangling_lead = ends_with_dangling_lead  -- test hook

local function dbcs_to_utf8(text)
    local cp = current_cp
    local data = pending .. text
    pending = ""
    -- Hold a trailing DBCS lead byte whose trail byte has not arrived yet
    -- (position-aware; see ends_with_dangling_lead).  A single-byte batch
    -- that is itself a lead byte counts as dangling too.
    if #data >= 1 and ends_with_dangling_lead(data, cp) then
        pending = data:sub(-1)
        data = data:sub(1, #data - 1)
    end
    if #data == 0 then return nil end
    local needed = kernel32.MultiByteToWideChar(cp, 0, data, #data, nil, 0)
    if needed <= 0 then return data end
    local wide = ensure_wide(needed + 1)
    local wide_written = kernel32.MultiByteToWideChar(cp, 0, data, #data,
        wide, needed)
    if wide_written <= 0 then return data end
    local out_needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide,
        wide_written, nil, 0, nil, nil)
    if out_needed <= 0 then return data end
    local buf = ensure_utf8(out_needed + 1)
    local written = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide,
        wide_written, buf, out_needed, nil, nil)
    if written <= 0 then return data end
    return ffi.string(buf, written)
end

-- ---------------------------------------------------------------------------
-- Public entry: convert one drained batch.  Returns the converted string
-- (same reference when passthrough), or nil when everything is pending.
-- ---------------------------------------------------------------------------

function M.convert(text)
    if not text or #text == 0 then return text end
    if current_cp == nil or not kernel32 then
        return text
    end
    if current_cp == "utf16" then
        return utf16_to_utf8(text)
    end
    return dbcs_to_utf8(text)
end

-- One-shot converters for scripts (stateless; do NOT touch `pending`).
-- utf8_to_cp("中文", 936) -> GB2312 bytes; cp_to_utf8 is the inverse.
function M.utf8_to_cp(text, cp)
    if not text or #text == 0 or not kernel32 then return text end
    local needed = kernel32.MultiByteToWideChar(CP_UTF8, 0, text, #text, nil, 0)
    if needed <= 0 then return text end
    local wide = ensure_wide(needed + 1)
    local wide_written = kernel32.MultiByteToWideChar(CP_UTF8, 0, text, #text,
        wide, needed)
    if wide_written <= 0 then return text end
    local out_needed = kernel32.WideCharToMultiByte(cp, 0, wide, wide_written,
        nil, 0, nil, nil)
    if out_needed <= 0 then return text end
    local buf = ensure_utf8(out_needed + 1)
    local written = kernel32.WideCharToMultiByte(cp, 0, wide, wide_written,
        buf, out_needed, nil, nil)
    if written <= 0 then return text end
    return ffi.string(buf, written)
end

function M.cp_to_utf8(text, cp)
    if not text or #text == 0 or not kernel32 then return text end
    local needed = kernel32.MultiByteToWideChar(cp, 0, text, #text, nil, 0)
    if needed <= 0 then return text end
    local wide = ensure_wide(needed + 1)
    local wide_written = kernel32.MultiByteToWideChar(cp, 0, text, #text,
        wide, needed)
    if wide_written <= 0 then return text end
    local out_needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide,
        wide_written, nil, 0, nil, nil)
    if out_needed <= 0 then return text end
    local buf = ensure_utf8(out_needed + 1)
    local written = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide,
        wide_written, buf, out_needed, nil, nil)
    if written <= 0 then return text end
    return ffi.string(buf, written)
end

-- Flush any held-back bytes as a final partial conversion (close path).
function M.flush()
    if pending == "" then return nil end
    local held = pending
    pending = ""
    -- Decode the orphan bytes as-is (best effort; typically a torn frame).
    -- The dangling-lead hold is bypassed by converting through a one-shot
    -- direct call — an orphan lead decodes to the CP default char, which is
    -- the honest representation of a torn byte at stream end.
    if current_cp == nil then return held end
    if not kernel32 then return held end
    if current_cp == "utf16" then
        -- utf16_to_utf8() re-arms `pending` for an odd trailing byte or a lone
        -- high surrogate; at flush there is no next batch to pair with, so it
        -- must not survive.  Without this reset a reconnect boundary would
        -- still leak the orphan into the next session's first bytes, defeating
        -- the whole point of flushing.
        local out = utf16_to_utf8(held)
        pending = ""
        return out or held
    end
    local cp = current_cp
    local needed = kernel32.MultiByteToWideChar(cp, 0, held, #held, nil, 0)
    if needed <= 0 then return held end
    local wide = ensure_wide(needed + 1)
    local wide_written = kernel32.MultiByteToWideChar(cp, 0, held, #held,
        wide, needed)
    if wide_written <= 0 then return held end
    local out_needed = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide,
        wide_written, nil, 0, nil, nil)
    if out_needed <= 0 then return held end
    local buf = ensure_utf8(out_needed + 1)
    local written = kernel32.WideCharToMultiByte(CP_UTF8, 0, wide,
        wide_written, buf, out_needed, nil, nil)
    if written <= 0 then return held end
    return ffi.string(buf, written)
end

return M
