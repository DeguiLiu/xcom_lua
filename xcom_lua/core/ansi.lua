--[[--------------------------------------------------------------------------
core/ansi.lua - streaming ANSI/SGR parser (pure Lua, unit-testable).

Behaviour mirrors xcom_client/widgets/ansi.py exactly:
  * ESC[ <params> m  (SGR) consumed and mapped to fg/bg/bold.
  * Other CSI terminators (cursor move A/B/C/D, erase K, ...) are parsed but
    stripped from the visible stream (the console never animates the cursor).
  * A trailing incomplete escape is held in `residue` and prepended to the next
    feed(), so a sequence split across two display batches still renders.
  * Extended 38/48 colours and unknown codes are ignored best-effort.

Segment output: { text=, fg=0xRRGGBB|nil, bg=0xRRGGBB|nil, bold=bool }.

Palette: the light COMTool-style table from ansi.py `_LIGHT`, with hex values
converted to 0xRRGGBB integers for direct use as a GDI/RICHEDIT colour.
------------------------------------------------------------------------]]--

local M = {}

-- hex string "#RRGGBB" -> integer 0xRRGGBB
local function to_rgb(hex)
    local r = tonumber(hex:sub(2, 3), 16)
    local g = tonumber(hex:sub(4, 5), 16)
    local b = tonumber(hex:sub(6, 7), 16)
    return (r * 256 + g) * 256 + b
end

local function tbl_rgb(t)
    local out = {}
    for i, h in ipairs(t) do
        out[i] = to_rgb(h)
    end
    return out
end

-- light ANSI palette (default fg for the light view background)
local LIGHT = {
    fg_std  = tbl_rgb({"#263238","#A64242","#1F6B5B","#8A6200",
                       "#356D9E","#705B97","#006C6C","#687780"}),
    fg_brt  = tbl_rgb({"#52636D","#BD5555","#2B806D","#9B7200",
                       "#477FAF","#806AA6","#007F7F","#84929A"}),
    bg_std  = tbl_rgb({"#EEF2F3","#F7E6E5","#E5F0EC","#F5EEDA",
                       "#E5EDF5","#EEE9F5","#E0F1F1","#EFF1F2"}),
    bg_brt  = tbl_rgb({"#E2E8EA","#F1D4D2","#D5E8E0","#EFE3C1",
                       "#D4E1EF","#E2DAEF","#CBE8E7","#E2E6E8"}),
    fg_default = to_rgb("#263238"),
}
M.LIGHT = LIGHT

local function fg_color(code, pal)
    local brg = code >= 90 and pal.fg_brt or pal.fg_std
    local idx = ((code >= 90 and code - 90) or (code - 30)) % 8
    return brg[idx + 1]
end

local function bg_color(code, pal)
    local brg = code >= 100 and pal.bg_brt or pal.bg_std
    local idx = ((code >= 100 and code - 100) or (code - 40)) % 8
    return brg[idx + 1]
end

local CSI_TERM_MIN, CSI_TERM_MAX = string.byte("@"), string.byte("~")

--[[-------------------------------------------------------------------------
_parse_params(param) -> list of int
Match Python: empty -> [0]; split on ';' and ':' ; strip non-digit chars; empty
part -> 0.
------------------------------------------------------------------------]]--
local function parse_params(param)
    if not param or param == "" then
        return { 0 }
    end
    -- Split on ';' (treating ':' as alias), preserving empty segments -> 0.
    -- A plain gmatch("[^;]*") would emit a spurious trailing empty match for a
    -- string that is itself ";"-free plus one (e.g. "31" -> {"31",""}), which
    -- would then be read as a reset (SGR 0).  Hand-roll the split instead.
    local sfind = string.find
    local ssub = string.sub
    local smatch = string.match
    local tonumber_ = tonumber
    local out = {}
    local normalized = param:gsub(":", ";")
    local pos = 1
    while true do
        local next_semi = sfind(normalized, ";", pos, true)
        local part
        if next_semi then
            part = ssub(normalized, pos, next_semi - 1)
            pos = next_semi + 1
        else
            part = ssub(normalized, pos)
        end
        local digits = smatch(part, "%d+")
        out[#out + 1] = digits and tonumber_(digits) or 0
        if not next_semi then
            break
        end
    end
    return out
end

local function apply_sgr(params, fg, bg, bold, pal)
    local f, b, w = fg, bg, bold
    for _, p in ipairs(params) do
        if p == 0 then
            f, b, w = nil, nil, false
        elseif p == 1 then
            w = true
        elseif p == 22 then
            w = false
        elseif p == 39 then
            f = nil
        elseif p == 49 then
            b = nil
        elseif (p >= 30 and p <= 37) or (p >= 90 and p <= 97) then
            f = fg_color(p, pal)
        elseif (p >= 40 and p <= 47) or (p >= 100 and p <= 107) then
            b = bg_color(p, pal)
        end
        -- extended 38/48 and anything else ignored best-effort
    end
    return f, b, w
end

--[[-------------------------------------------------------------------------
AnsiParser with cross-batch residue state.
------------------------------------------------------------------------]]--
local AnsiParser = {}
AnsiParser.__index = AnsiParser

function AnsiParser.new()
    local self = setmetatable({ residue = "" }, AnsiParser)
    return self
end

-- Match a complete CSI at buf[i] (buf[i]=ESC, buf[i+1]='[').
-- Returns (final_index, terminator_byte) if complete, else nil.  The caller
-- compares the terminator against 109 ('m') — returning the byte avoids
-- re-slicing a one-char string for every scanned parameter byte.
local function match_csi(buf, i)
    local n = #buf
    local j = i + 2
    local sbyte = string.byte  -- hot loop: hoist the method lookup
    while j < n do  -- Lua 1-indexed; j runs over bytes after '['
        local b = sbyte(buf, j)
        if b < 0x20 or b == 0x7f then
            return nil  -- raw C0 inside parameters -> malformed
        end
        if b >= CSI_TERM_MIN and b <= CSI_TERM_MAX then
            return j, b
        end
        j = j + 1
    end
    return nil
end

-- feed(text) -> list of {text, fg, bg, bold} segments
function AnsiParser:feed(text, palette)
    local pal = palette or LIGHT
    local buf = self.residue .. (text or "")
    self.residue = ""
    if buf == "" then
        return {}
    end

    -- Cache string methods as locals: feed() runs on every display batch (up
    -- to 64 KiB each 10 ms) in interpreted mode, so each `buf:sub`/`buf:byte`
    -- here is a metamethod lookup + call unless hoisted to an upvalue.
    local sbyte = string.byte
    local ssub = string.sub

    local fg, bg, bold = nil, nil, false
    local segments = {}
    local start, i = 1, 1
    local n = #buf

    while i <= n do
        local ch = sbyte(buf, i)
        if ch ~= 27 then  -- ESC
            i = i + 1
        else
            -- buf[i] is ESC
            if i == n then
                -- lone trailing ESC -> residue for next batch, don't emit yet
                if start < i then
                    segments[#segments + 1] = { text = ssub(buf, start, i - 1), fg = fg, bg = bg, bold = bold }
                end
                self.residue = "\27"
                start = n + 1
                break
            end
            if sbyte(buf, i + 1) ~= 91 then  -- '['
                -- ESC not followed by '[' (and not at end): stray/literal ESC
                i = i + 1
            else
                -- CSI: ESC '[' ...
                local idx, term = match_csi(buf, i)
                if idx == nil then
                    -- incomplete CSI at end of input -> carry forward
                    if start < i then
                        segments[#segments + 1] = { text = ssub(buf, start, i - 1), fg = fg, bg = bg, bold = bold }
                    end
                    self.residue = ssub(buf, i)
                    start = n + 1
                    break
                end
                if start < i then
                    segments[#segments + 1] = { text = ssub(buf, start, i - 1), fg = fg, bg = bg, bold = bold }
                end
                if term == 109 then  -- 'm' = SGR
                    local param_s = ssub(buf, i + 2, idx - 1)
                    local params = parse_params(param_s)
                    fg, bg, bold = apply_sgr(params, fg, bg, bold, pal)
                end
                i = idx + 1
                start = i
            end
        end
    end

    if start <= n then
        segments[#segments + 1] = { text = ssub(buf, start), fg = fg, bg = bg, bold = bold }
    end
    return segments
end

function AnsiParser:reset()
    self.residue = ""
end

M.AnsiParser = AnsiParser

-- Convenience: feed one text chunk with residue state and return flat text
-- (all segments concatenated) — used by plain views that don't want colours.
function M.strip(text, parser)
    local p = parser or AnsiParser.new()
    local parts = {}
    for _, seg in ipairs(p:feed(text)) do
        parts[#parts + 1] = seg.text
    end
    return table.concat(parts)
end

return M
