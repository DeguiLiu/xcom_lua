--[[--------------------------------------------------------------------------
core/config.lua - minimal INI-style (key=value, [section]) settings persistence.

Pure Lua, no Win32/LuaJIT.jit dependency, so it runs unit-testable on the Linux
luajit binary.  Persists the UI settings to a flat `config.ini` beside the
scripts; that file is the single source of truth for the current Lua front-end
(no external client is kept in sync with it).

Supported value types: numbers, booleans, strings.  Comment lines start with
';' or '#'.  Section headers are `[name]`.  Unknown keys are preserved on round
trip but ignored by the typed getters.
------------------------------------------------------------------------]]--

local M = {}

-- config.ini is named in ASCII but the directory holding it is whatever the
-- user installed into (a CJK path is the common case here), so the open and
-- the rename go through the UTF-8 boundary.  fs_path stays pure Lua: the
-- conversion is an optional FFI/kernel32 bridge and a passthrough elsewhere.
local fs_path = require("fs_path")

local function trim(s)
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Unescape a quoted literal: the reverse of escape_string below, applied to
-- the text between the quotes.  An unknown escape keeps the backslash (so a
-- hand-edited Windows path is not mangled).
local function unescape_string(s)
    return (s:gsub("\\(.)", function(c)
        if c == "n" then return "\n" end
        if c == "r" then return "\r" end
        if c == "t" then return "\t" end
        if c == "\\" then return "\\" end
        if c == '"' then return '"' end
        return "\\" .. c
    end))
end

-- Index of the closing quote of a quoted literal starting at s[1] == '"', or
-- nil when the literal is unterminated.  The scan SKIPS the character after a
-- backslash: an escaped quote inside the value ("say \"hi\"") is data, not the
-- terminator, and a plain find() would cut the value at the first escaped one.
local function closing_quote_index(s)
    local index = 2
    while index <= #s do
        local c = s:sub(index, index)
        if c == "\\" then
            index = index + 2
        elseif c == '"' then
            return index
        else
            index = index + 1
        end
    end
    return nil
end

-- Parse one scalar literal: true/false/yes/no/on/off -> boolean, integer or
-- float -> number (with sign), otherwise keep as string.  Numbers use Lua's
-- tonumber so we accept plain decimal integers and simple floats.
--
-- A value wrapped in double quotes is a STRING LITERAL and is taken verbatim
-- (escapes resolved, no trimming, no numeric/boolean coercion).  That form is
-- what makes a command survive a round trip when it carries a newline, a
-- leading/trailing space, or text that would otherwise read back as a number.
-- Bare values keep the historical meaning, so files written before quoted
-- literals existed still load exactly as they did.
local function parse_value(raw)
    local v = trim(raw)
    if v == "" then
        return nil
    end
    if v:sub(1, 1) == '"' then
        local closing = closing_quote_index(v)
        if closing then
            return unescape_string(v:sub(2, closing - 1))
        end
        -- Unterminated quote: fall through to the bare rules rather than
        -- dropping the value, so a hand-edited file still yields something.
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

-- Does this string need the quoted form to read back as itself?
--
-- Bare is the historical format and stays the default, so an ordinary value
-- ("COM3", "115200", a path) keeps the file readable and the diff quiet.  The
-- quoted form is required when the bare form would be re-read as something
-- else:
--   * an embedded newline ends the line early -- the rest of the command would
--     be parsed as new keys, corrupting the file (the send history stores whole
--     multi-line commands, so this is the case that matters);
--   * leading/trailing whitespace is trimmed away by parse_value, and a
--     command that needs a trailing space (or a multi-line block's indent)
--     would come back changed;
--   * a value that looks like a number or a boolean comes back as that type.
local function needs_quotes(s)
    if s == "" then
        return true
    end
    if s ~= trim(s) then
        return true
    end
    if s:find("\n", 1, true) or s:find("\r", 1, true) then
        return true
    end
    if s:find('"', 1, true) or s:find("\\", 1, true) then
        return true
    end
    local low = s:lower()
    if low == "true" or low == "false" or low == "yes" or low == "no" or
       low == "on" or low == "off" then
        return true
    end
    if s:match("^[+-]?%d+$") or s:match("^[+-]?%d*%.?%d+$") then
        return true
    end
    return false
end

local function escape_string(s)
    return (s:gsub("[\\\n\r\t\"]", function(c)
        if c == "\\" then return "\\\\" end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return '\\"'
    end))
end

-- Serialize a value back to a string.  Ordinary strings stay raw (no quotes)
-- in this minimal format; meaning is preserved because parse_value only
-- converts numeric/boolean tokens.  Strings that would not survive that
-- treatment are written as quoted literals -- see needs_quotes.
local function dump_value(v)
    if type(v) == "boolean" then
        return v and "true" or "false"
    end
    if type(v) == "number" then
        return tostring(v)
    end
    local s = tostring(v)
    if not needs_quotes(s) then
        return s
    end
    return '"' .. escape_string(s) .. '"'
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
    local f, err = fs_path.open(path, "rb")
    if not f then
        return { [""] = {} }
    end
    local content = f:read("*a")
    f:close()
    return M.parse(content or "")
end

function M.save(path, data)
    local text = M.serialize(data)
    -- Write a sibling file and rename it over the target, never the target
    -- itself: io.open(path, "wb") truncates first, so a process killed (or a
    -- disk that fills) between the truncate and the close leaves the user with
    -- a DESTROYED config -- strictly worse than the change not being saved.
    -- The temp file is a sibling so the rename cannot cross a volume, and the
    -- rename is attempted FIRST because it is the atomic path everywhere but
    -- Windows (where it refuses an existing destination).
    local tmp = path .. ".tmp"
    local f = fs_path.open(tmp, "wb")
    if not f then
        return false
    end
    local wrote = f:write(text)
    f:close()
    if not wrote then
        -- A partial temp file must not be mistaken for a config later.
        fs_path.remove(tmp)
        return false
    end
    if fs_path.rename(tmp, path) then
        return true
    end
    fs_path.remove(path)
    if fs_path.rename(tmp, path) then
        return true
    end
    -- Both renames failed: the target is gone but the full text is still in
    -- the temp file.  Leave it there (do NOT clean up) so the settings are
    -- recoverable by hand, and report the failure.
    return false
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

--[[-------------------------------------------------------------------------
Device-profile section helpers (see docs/design-device-profiles.md).

`[profile]` holds the stable device `key` and the resolution `mode`
(`auto` | `custom`).  `[profile.custom]` is a flat override table whose keys
may be dotted paths into the profile shape (`reset.mode`, `reset.reenumerates`,
`flow_control`, `silent_warn_ms`, ...).  These are thin wrappers over the same
nested `data[section][key]` layout as the rest of this module, kept here so
callers never spell the section names inline.
------------------------------------------------------------------------]]--
function M.get_profile(data)
    return data["profile"] or {}, data["profile.custom"] or {}
end

function M.set_profile(data, key, mode, custom)
    if data["profile"] == nil then
        data["profile"] = {}
    end
    data["profile"].key = key
    data["profile"].mode = mode
    if custom ~= nil then
        -- copy so the caller keeps ownership of its table
        local flat = {}
        for k, v in pairs(custom) do
            flat[k] = v
        end
        data["profile.custom"] = flat
    end
    return data
end

return M
