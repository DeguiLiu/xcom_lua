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

--[[-------------------------------------------------------------------------
writable_path(path, fallback_dir, mkdir) -> path, fell_back

Pick the file the settings are READ from and WRITTEN to.  The MSI installs
per-machine into %ProgramFiles%\XCOM (installer/xcom.wxs), where a standard
user cannot rewrite the config.ini next to the executable - and the client is
manifested, so Windows does NOT redirect the write to VirtualStore.  Every
save then fails and the user sees precisely "it forgot my tick again".

The probe is a real append-open, i.e. the same access a save performs, so an
ACL or a read-only attribute is caught the same way a failed save would be;
the file it may create is the one a save would have created anyway.  When the
install copy cannot be written, BOTH the load and the save move to
`fallback_dir` (the client passes %APPDATA%\XCOM).  Moving only the write
would reload the stale install copy on the next launch and lose the settings
anyway - reading the same path that is written is the whole point.

`mkdir` is injected by the caller so this module stays free of host APIs; it
is consulted only when the fallback file does not exist yet.  Returns the
original path and false when no fallback is available or usable.
------------------------------------------------------------------------]]--
function M.writable_path(path, fallback_dir, mkdir)
    local probe = fs_path.open(path, "ab")
    if probe then
        probe:close()
        return path, false
    end
    if not fallback_dir then
        return path, false
    end
    local alt = fallback_dir .. "/config.ini"
    local alt_probe = fs_path.open(alt, "ab")
    if not alt_probe and mkdir and mkdir(fallback_dir) then
        alt_probe = fs_path.open(alt, "ab")
    end
    if not alt_probe then
        return path, false
    end
    alt_probe:close()
    return alt, true
end

function M.save(path, data)
    local text = M.serialize(data)
    -- Write a sibling file and rename it over the target, never the target
    -- itself: io.open(path, "wb") truncates first, so a process killed (or a
    -- disk that fills) between the truncate and the close leaves the user with
    -- a DESTROYED config -- strictly worse than the change not being saved.
    -- The temp file is a sibling so the rename cannot cross a volume.
    -- fs_path.rename is the atomic replace (MoveFileExW on Windows, rename(2)
    -- elsewhere), so this first rename is the one that normally succeeds.  The
    -- remove+rename below is only the fallback for a host where that call
    -- cannot replace an existing destination; it is destructive (the live
    -- config is gone until the rename lands) and that is exactly why the
    -- atomic path is taken first.
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
