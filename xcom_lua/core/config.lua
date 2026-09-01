--[[--------------------------------------------------------------------------
core/config.lua - minimal INI-style (key=value, [section]) settings persistence.

Pure Lua, no Win32/LuaJIT.jit dependency, so it runs unit-testable on the Linux
luajit binary.  Mirrors the persisted field set of xcom_client/services/settings.py
(PySide6 config.toml) so behaviour stays consistent across the two front-ends,
but writes a flat `config.ini` beside the scripts instead of TOML.

Supported value types: numbers, booleans, strings.  Comment lines start with
';' or '#'.  Section headers are `[name]`.  Unknown keys are preserved on round
trip but ignored by the typed getters.
------------------------------------------------------------------------]]--

local M = {}

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Parse one scalar literal: true/false/yes/no/on/off -> boolean, integer or
-- float -> number (with sign), otherwise keep as string.  Numbers use Lua's
-- tonumber so we accept plain decimal integers and simple floats.
local function parse_value(raw)
    local v = trim(raw)
    if v == "" then
        return nil
    end
    local low = v:lower()
    if low == "true" or low == "yes" or low == "on" then
        return true
    end
    if low == "false" or low == "no" or low == "off" then
        return false
    end
    -- A config value may be a number only if it looks like one (optimistic
    -- scan, then tonumber; we do not want to coerce "COM3" into 3).
    if v:match("^[+-]?%d+$") or v:match("^[+-]?%d*%.?%d+$") then
        local n = tonumber(v)
        if n then
            return n
        end
    end
    return v
end

-- Serialize a value back to a string.  Strings are written raw (no quotes) in
-- this minimal format; meaning is preserved because parse_value only converts
-- numeric/boolean tokens.
local function dump_value(v)
    if type(v) == "boolean" then
        return v and "true" or "false"
    end
    if type(v) == "number" then
        return tostring(v)
    end
    return tostring(v)
end

local function is_ignored(line)
    local trimmed = line:gsub("^%s+", "")
    return trimmed == "" or trimmed:sub(1, 1) == ";" or trimmed:sub(1, 1) == "#"
end

--[[-------------------------------------------------------------------------
parse(s) -> table

Read an INI text and return a nested table `data[section][key] = value`.
The default section (keys before any [section]) is stored under data[""].
Duplicate keys in the same section overwrite the earlier value (last wins).
------------------------------------------------------------------------]]--
function M.parse(s)
    local data = {}
    local section = ""
    local function ensure_section()
        if data[section] == nil then
            data[section] = {}
        end
        return data[section]
    end
    for line in (s .. "\n"):gmatch("(.-)\n") do
        if not is_ignored(line) then
            local leading = line:gsub("^%s*", "")
            local header = leading:match("^%[(.-)%]")
            if header then
                section = trim(header)
            else
                local eq = line:find("=")
                local key
                local rest
                if eq then
                    key = trim(line:sub(1, eq - 1))
                    rest = line:sub(eq + 1)
                else
                    -- bare key line (no '='); treat as present with nil value.
                    key = trim(line)
                    rest = ""
                end
                if key ~= "" then
                    ensure_section()[key] = parse_value(rest)
                end
            end
        end
    end
    return data
end

--[[-------------------------------------------------------------------------
serialize(data) -> string

Emit `data` back to INI text.  Sections iterate in a stable order: "" first,
then remaining sections in insertion order.  Keys iterate in insertion order.
------------------------------------------------------------------------]]--
function M.serialize(data)
    local parts = {}
    local sections = {}
    if data[""] then
        sections[#sections + 1] = ""
    end
    for k in pairs(data) do
        if k ~= "" then
            sections[#sections + 1] = k
        end
    end
    -- determinism: default section first, then lexicographic
    table.sort(sections)
    local function emit_section(name, tbl)
        if name ~= "" then
            parts[#parts + 1] = string.format("[%s]", name)
        end
        for k, v in pairs(tbl) do
            if type(k) == "string" and type(v) ~= "table" and type(v) ~= "nil" then
                parts[#parts + 1] = string.format("%s = %s", k, dump_value(v))
            end
        end
    end
    for _, name in ipairs(sections) do
        emit_section(name, data[name])
        parts[#parts + 1] = ""
    end
    return table.concat(parts, "\n")
end

--[[-------------------------------------------------------------------------
load(path) -> table
save(path, data) -> boolean ok

File helpers wrapping parse/serialize.  load returns an empty config
(data with a "" section) when the file is missing or unreadable; it never
raises.  save returns false and does not raise on I/O error.
------------------------------------------------------------------------]]--
function M.load(path)
    local f, err = io.open(path, "rb")
    if not f then
        return { [""] = {} }
    end
    local content = f:read("*a")
    f:close()
    return M.parse(content or "")
end

function M.save(path, data)
    local text = M.serialize(data)
    local f, err = io.open(path, "wb")
    if not f then
        return false
    end
    f:write(text)
    f:close()
    return true
end

--[[-------------------------------------------------------------------------
Fluent typed accessors over a parsed blob.  Example:

    local cfg = config.load(path)
    config.get(cfg, "window", "w", 920)
    config.set(cfg, "window", "w", 940)
----------------------------------------------------------------------------]]
function M.get(data, section, key, default)
    local t = data[section]
    if t == nil then
        return default
    end
    local v = t[key]
    if v == nil then
        return default
    end
    return v
end

function M.set(data, section, key, value)
    if data[section] == nil then
        data[section] = {}
    end
    data[section][key] = value
end

--[[-------------------------------------------------------------------------
convention helpers for the multi-send page entries.  xcom_client models an
optional list of pages, each a list of up to 8 entries {text, enabled}.
We flatten to section `[multipage]` with keys `entry.{page}.{index}.text` /
`entry.{page}.{index}.enabled`.  These helpers read/write that flat space.
------------------------------------------------------------------------]]--
function M.get_multi_entry(data, page, index, key, default)
    return M.get(data, "multipage", string.format("entry.%d.%d.%s", page, index, key), default)
end

function M.set_multi_entry(data, page, index, key, value)
    M.set(data, "multipage", string.format("entry.%d.%d.%s", page, index, key), value)
end

M.MAX_MULTI_ENTRIES = 8
M.MAX_MULTI_PAGES = 50

return M
