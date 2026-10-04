-- test_send_history.lua - the send box's command-history policy.
--
-- "历史命令要能记住" has two halves: the widget must walk the list (ImGui
-- history callback, needs the DLL) and the POLICY must survive a restart.  The
-- policy is what is pinned here, including the cases a hand-edited config file
-- can produce, because a history that loses the newest command or replays a
-- blank line is indistinguishable from the feature being broken.
--
-- Usage: cd xcom_lua && luajit tests/test_send_history.lua
-- SPDX-License-Identifier: MIT

package.path = "./core/?.lua;" .. package.path

local history = require("send_history")
local config = require("config")

local pass_n, fail_n = 0, 0
local function eq(label, got, want)
    if got == want then
        pass_n = pass_n + 1
        print("PASS  " .. label)
    else
        fail_n = fail_n + 1
        print(string.format("FAIL  %s (got=%s want=%s)", label, tostring(got),
                            tostring(want)))
    end
end
local function joined(list)
    return table.concat(list or {}, "|")
end
local function check(label, condition)
    if condition then
        pass_n = pass_n + 1
        print("PASS  " .. label)
    else
        fail_n = fail_n + 1
        print("FAIL  " .. label)
    end
end

-- A) newest first, and a fresh list is not shared with the input.
do
    local first = history.push({}, "AT")
    local second = history.push(first, "AT+RST")
    eq("A1 newest command is entry 1", second[1], "AT+RST")
    eq("A2 the older command follows", second[2], "AT")
    eq("A3 the input list was not mutated", joined(first), "AT")
    eq("A4 a nil input is accepted", joined(history.push(nil, "AT")), "AT")
end

-- B) a repeat MOVES to the head (most-recently-used first), as COMTool's
--    sendHistoryFindDelete + insert(0) does: alternating between two commands
--    must not grow the list one duplicate per send.
do
    local list = history.push({}, "AT")
    list = history.push(list, "AT")
    eq("B1 re-sending the newest command keeps one entry", #list, 1)
    list = history.push(list, "AT+GMR")
    list = history.push(list, "AT")
    eq("B2 an older repeat moves to the head (A B A -> A B)", joined(list), "AT|AT+GMR")
    eq("B3 alternating stays two entries (A B A B A B)",
       #history.push(history.push(history.push(list, "AT+GMR"), "AT"), "AT+GMR"), 2)
    eq("B4 and the head is the last one used",
       history.push(list, "AT+GMR")[1], "AT+GMR")
end

-- C) blank lines are not commands.
do
    local list = history.push({}, "AT")
    eq("C1 empty text is dropped", #history.push(list, ""), 1)
    eq("C2 whitespace-only text is dropped", #history.push(list, "   "), 1)
    eq("C3 a newline-only text is dropped", #history.push(list, "\n"), 1)
    eq("C4 nil text is dropped", #history.push(list, nil), 1)
    -- ...but a command that merely HAS whitespace is kept verbatim, because a
    -- device may need the trailing space.
    eq("C5 surrounding whitespace inside a command is preserved",
       history.push({}, "AT ")[1], "AT ")
end

-- D) the cap drops the OLDEST entries and never grows past it.
do
    local list = {}
    for index = 1, 10 do
        list = history.push(list, "cmd" .. index, 3)
    end
    eq("D1 capped to the newest three", joined(list), "cmd10|cmd9|cmd8")
    eq("D2 a non-positive cap falls back to the default, not to unbounded",
       #history.push({}, "AT", 0), 1)
    local wide = {}
    for index = 1, history.DEFAULT_MAX + 5 do
        wide = history.push(wide, "c" .. index)
    end
    eq("D3 the default cap holds", #wide, history.DEFAULT_MAX)
    eq("D4 and the newest survives the cap", wide[1],
       "c" .. tostring(history.DEFAULT_MAX + 5))
end

-- E) multi-line commands (the send box is a multiline editor) are one entry.
do
    local block = "AT+CGDCONT=1\nAT+CGACT=1\n"
    local list = history.push({}, block)
    eq("E1 a multi-line command is a single entry", #list, 1)
    eq("E2 and is stored verbatim", list[1], block)
    eq("E3 it is not treated as blank", #history.push({}, block), 1)
end

-- F) sanitize: what a config file is allowed to produce.
do
    eq("F1 missing history yields an empty list",
       joined(history.sanitize(nil)), "")
    eq("F2 non-string entries are dropped",
       joined(history.sanitize({ "AT", 42, true, "AT+GMR" })), "AT|AT+GMR")
    eq("F3 blanks are dropped, order kept",
       joined(history.sanitize({ "AT", "", "  ", "AT+GMR" })), "AT|AT+GMR")
    eq("F4 the cap applies", #history.sanitize({ "a", "b", "c" }, 2), 2)
    eq("F5 the newest entries are the ones kept",
       joined(history.sanitize({ "a", "b", "c" }, 2)), "a|b")
    eq("F6 an empty entry inside a valid list does not shift the rest",
       history.sanitize({ "AT", "" })[1], "AT")
    eq("F7 a hand-edited duplicate collapses (first occurrence wins)",
       joined(history.sanitize({ "AT", "AT+GMR", "AT" })), "AT|AT+GMR")
end

-- G) 重启后要能找回 ("历史命令要能记住").  The file round trip is written with the
--    same key naming window.lua uses and read back with the same logic main.lua
--    uses, so a rename on one side fails here rather than silently emptying the
--    list on the next launch.  The multi-line case is the point of the escaping
--    added to core/config.lua: an embedded newline would otherwise end the line
--    early and hand the reader a corrupted value.
do
    local path = os.tmpname()
    local list = history.push(
        history.push({}, "AT+RST"),
        "AT+CGDCONT=1\nAT+CGACT=1")
    eq("G0 fixture is newest-first", list[1], "AT+CGDCONT=1\nAT+CGACT=1")

    local data = { [""] = {} }
    config.set(data, "send", "history_count", #list)
    for index = 1, #list do
        config.set(data, "send", "history." .. (index - 1), list[index])
    end
    eq("G1 save ok", config.save(path, data), true)

    local stored = config.load(path)
    local back = {}
    local count = tonumber(config.get(stored, "send", "history_count", 0)) or 0
    for index = 0, count - 1 do
        local text = config.get(stored, "send", "history." .. index, nil)
        if type(text) == "string" and text ~= "" then
            back[#back + 1] = text
        end
    end
    eq("G2 the count survived", count, 2)
    eq("G3 the newest command came back first", back[1], "AT+CGDCONT=1\nAT+CGACT=1")
    eq("G4 the older command came back verbatim", back[2], "AT+RST")
    eq("G5 the restored list is what the widget is seeded with",
       table.concat(history.sanitize(back), "|"),
       "AT+CGDCONT=1\nAT+CGACT=1|AT+RST")

    -- The count is the bound: keys a LONGER previous session left behind must
    -- not resurrect themselves.
    local stale = config.load(path)
    config.set(stale, "send", "history.7", "GHOST")
    config.set(stale, "send", "history_count", 2)
    config.save(path, stale)
    local reread = config.load(path)
    local ghosts = 0
    local bound = tonumber(config.get(reread, "send", "history_count", 0)) or 0
    for index = 0, bound - 1 do
        if config.get(reread, "send", "history." .. index, "") == "GHOST" then
            ghosts = ghosts + 1
        end
    end
    eq("G6 a stale higher key is ignored", ghosts, 0)
    os.remove(path)

    -- Key-name drift guard, both sides of the contract.
    local function read(path_name)
        local handle = io.open(path_name, "rb")
        local text = handle and handle:read("*a")
        if handle then handle:close() end
        return text
    end
    local writer = read("ui/window.lua")
    local reader = read("main.lua")
    check("G7 window.lua is readable for the drift guard", writer ~= nil)
    check("G8 main.lua is readable for the drift guard", reader ~= nil)
    for _, token in ipairs({
        [[config.set(data, "send", "history_count"]],
        [["send", "history." .. (index - 1)]],
    }) do
        check("G9 writer mentions " .. token,
              writer ~= nil and writer:find(token, 1, true) ~= nil)
    end
    for _, token in ipairs({
        [[config.get(cfg_data, "send", "history_count"]],
        [["send", "history." .. index]],
    }) do
        check("G10 reader mentions " .. token,
              reader ~= nil and reader:find(token, 1, true) ~= nil)
    end
end

print(string.format("\nsend_history: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
