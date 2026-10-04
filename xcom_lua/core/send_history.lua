--[[--------------------------------------------------------------------------
core/send_history.lua - the send box's command history, as pure policy.

What the user expects when they ask for "历史命令要能记住": the commands they
typed are still there after a restart, and Up/Down in the send box walks them
back.  The WIDGET half lives in the ImGui bridge (an InputText history
callback); this module owns the policy, so it is headless-testable: what counts
as a duplicate, what gets dropped when the cap is reached, and what a
hand-edited config file is allowed to contain.

Rules, chosen to match how a terminal behaves:
  * the newest command is entry 1 (the list is newest-first, so the widget's
    "up" is index 1 and a fresh push is a cheap prepend);
  * an entry that is already in the list MOVES to the head instead of being
    added again, so A, B, A, B leaves two entries (A then B, most-recently-used
    first).  Alternating between two commands is an ordinary way to drive a
    device, and a list that grows a duplicate per send would push everything
    else out of the cap.  This is also what COMTool does (`sendHistoryFindDelete`
    then `insert(0, ...)` in plugins/dbg.py);
  * empty and whitespace-only entries are rejected: an empty send is not a
    command, and a blank line in the walk would just look like a bug;
  * the cap drops the OLDEST entries, so a long session cannot grow the config
    file without bound.

SPDX-License-Identifier: MIT
------------------------------------------------------------------------]]--

local M = {}

-- Default ring size.  A command line is short, so 64 entries are a few KB of
-- INI at most; large enough to cover a working session, small enough that a
-- hand-edited file stays readable.
M.DEFAULT_MAX = 64

local function is_blank(text)
    return type(text) ~= "string" or text == "" or text:match("^%s*$") ~= nil
end

--[[--------------------------------------------------------------------------
push(list, text[, max]) -> list

Return `list` with `text` as the newest entry.  Never mutates the input, so a
caller can hold the old table across a failed send.  `max` (default
MAX_DEFAULT) caps the result; a non-positive max is treated as the default
rather than as "unbounded".
------------------------------------------------------------------------]]--
function M.push(list, text, max)
    if is_blank(text) then
        local copy = {}
        for index = 1, #(list or {}) do
            copy[#copy + 1] = list[index]
        end
        return copy
    end
    -- Move-to-front: drop every older occurrence, then prepend.  The comparison
    -- walks the list rather than using a keyed set because the list is tiny
    -- (DEFAULT_MAX) and this keeps the module allocation-light.
    local out = { text }
    for index = 1, #(list or {}) do
        local entry = list[index]
        if entry ~= text then
            out[#out + 1] = entry
        end
    end
    local cap = tonumber(max) or M.DEFAULT_MAX
    if cap <= 0 then
        cap = M.DEFAULT_MAX
    end
    while #out > cap do
        table.remove(out)
    end
    return out
end

--[[--------------------------------------------------------------------------
sanitize(list[, max]) -> list

The list a config file is allowed to produce: strings only, blanks dropped,
already-newest-first order preserved, length capped.  A missing list (no
history key yet) yields an empty list, which is also what the widget wants.
------------------------------------------------------------------------]]--
function M.sanitize(list, max)
    local out = {}
    local cap = tonumber(max) or M.DEFAULT_MAX
    if cap <= 0 then
        cap = M.DEFAULT_MAX
    end
    for index = 1, #(list or {}) do
        local text = list[index]
        if not is_blank(text) and #out < cap then
            -- Same move-to-front rule as push(), so a file that was hand-edited
            -- into duplicates reads back as the list the widget would have
            -- produced itself (first occurrence wins: it is the more recent one
            -- in a newest-first file).
            local seen = false
            for _, existing in ipairs(out) do
                if existing == text then
                    seen = true
                    break
                end
            end
            if not seen then
                out[#out + 1] = text
            end
        end
    end
    return out
end

return M
