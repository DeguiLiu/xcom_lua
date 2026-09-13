--[[--------------------------------------------------------------------------
core/receive_copy.lua - pure helpers for the receive-area copy path.

The receive display injects a fixed 15-byte "[HH:MM:SS.mmm] " prefix at the
start of every display segment (ui/window.lua's rx_timestamp_prefix, design
§1 stage ⑥).  A user who copies log text out of the receive area wants the RAW
payload back, so ui/imgui_bridge.lua applies strip_timestamps() to the bytes
the native side queued for copying before it writes the clipboard.

Pure Lua and free of ffi/jit/DLL dependencies, so tests/test_receive_copy.lua
can require it on a Linux host and exercise the real function.

Trade-off (documented, opt-in): the prefix is the tool's own format, so a
device that emits the byte-identical token is indistinguishable from an
injected stamp.  strip_timestamps removes an EXACT match anywhere, which also
catches stamps glued mid-line at a segment boundary where the previous line
had no newline.  That is why the option defaults to off and is an explicit
user choice; a device stamp that is not exactly "[HH:MM:SS.mmm] " (other
widths, no trailing space, plain tags) is left untouched.
------------------------------------------------------------------------]]--

local M = {}

-- Exact prefix shape produced by ui/window.lua rx_timestamp_prefix():
--   "[" HH ":" MM ":" SS "." mmm "] "   (H/M/S two digits, mmm three digits)
-- Every metacharacter is escaped so this can only match the literal form.
local TIMESTAMP_PREFIX_PATTERN = "%[%d%d:%d%d:%d%d%.%d%d%d%] "

--[[--------------------------------------------------------------------------
strip_timestamps(text) -> string | original

Return `text` with every exact "[HH:MM:SS.mmm] " prefix removed.  Nil, empty
and non-string inputs are returned unchanged (defensive; callers hand it a
string).  The result length can only shrink.
------------------------------------------------------------------------]]--
function M.strip_timestamps(text)
    if type(text) ~= "string" or text == "" then
        return text
    end
    -- Parenthesised so only the string (not gsub's match count) is returned.
    return (text:gsub(TIMESTAMP_PREFIX_PATTERN, ""))
end

return M
