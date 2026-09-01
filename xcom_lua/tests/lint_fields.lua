-- lint_fields.lua - static lint for the Win32 layer, runnable on Linux.
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/lint_fields.lua
--
-- Catches two bug classes that `luajit -bl` and the pure-Lua unit tests both
-- miss, and that only surface as a crash or a silently-wrong Win32 call on
-- Windows:
--
--   1. Undefined global reads (GGET on a name that is not a known builtin).
--      A `local function f` referenced above its definition line compiles to a
--      global read, so the call site sees nil.
--   2. Missing constant-table fields.  `w.em.EM_FOO` where M.em has no EM_FOO
--      yields nil, which then goes into SendMessageA as message 0.
--
-- ui/win32.lua defers ffi.load() into M.load(), so the module can be required
-- on Linux and its constant tables introspected directly.

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

local LUAJIT = arg[-1] or "luajit"
local FILES = {
    "main.lua",
    "core/ansi.lua", "core/config.lua", "core/view_model.lua", "core/xcom_ffi.lua",
    "ui/win32.lua", "ui/controls.lua", "ui/window.lua",
    "ui/connection_panel.lua", "ui/receive_view.lua",
    "ui/send_panel.lua", "ui/status_bar.lua",
}

-- Names legitimately read from _G by this codebase.
local BUILTINS = {}
for name in ([[require setmetatable getmetatable type tostring tonumber pairs ipairs
table string math os io error pcall xpcall select print assert unpack rawget rawset
rawequal rawlen next package arg _G collectgarbage jit debug coroutine bit newproxy
load loadstring loadfile dofile module setfenv getfenv]]):gmatch("%S+") do
    BUILTINS[name] = true
end

local failures = 0
local function fail(fmt, ...)
    failures = failures + 1
    print(string.format("FAIL  " .. fmt, ...))
end

local function read_file(path)
    local fh = io.open(path, "r")
    if not fh then
        return nil
    end
    local text = fh:read("*a")
    fh:close()
    return text
end

-- --------------------------------------------------------------------------
-- Check 1: undefined global reads, via the GGET opcodes in the bytecode dump.
-- --------------------------------------------------------------------------
local function check_globals(path)
    local pipe = io.popen(string.format("%q -bl %q 2>/dev/null", LUAJIT, path))
    if not pipe then
        return
    end
    local dump = pipe:read("*a")
    pipe:close()
    local seen = {}
    for name in dump:gmatch('GGET%s+%d+%s+%d+%s*;%s*"([^"]+)"') do
        if not BUILTINS[name] and not seen[name] then
            seen[name] = true
            fail("%s reads undefined global %q (forward reference or typo?)", path, name)
        end
    end
end

-- --------------------------------------------------------------------------
-- Check 2: references into the `w` (ui/win32) module resolve.
--
-- Two shapes are checked:
--   * `w.<tbl>.<FIELD>`  -- when `w[tbl]` is an ordinary table (constant map),
--     every FIELD must exist in it.  Lazy submodule handles (w.user32 etc.,
--     assigned only inside M.load()) are skipped since they are nil on Linux.
--   * `w.<name>`         -- a module-level field (w.utf8_to_utf16,
--     w.comdlg32, ...) must be assigned via `M.<name> =` or `function M.<name>`.
-- --------------------------------------------------------------------------
local function check_win32_fields()
    local ok, w = pcall(require, "win32")
    if not ok then
        fail("cannot require ui/win32.lua: %s", tostring(w))
        return
    end

    -- Every `M.<name>` assignment (covers lazy handles set in M.load(), plus
    -- constants, plus `function M.<name>`).
    local win32_src = read_file("ui/win32.lua") or ""
    local mnames = {}
    for name in win32_src:gmatch("M%.([%a_][%w_]*)%s*=") do
        mnames[name] = true
    end
    for name in win32_src:gmatch("function%s+M%.([%a_][%w_]*)") do
        mnames[name] = true
    end

    for _, path in ipairs(FILES) do
        local text = read_file(path)
        if not text then
            goto continue
        end

        -- Two-level: w.<tbl>.<field>.  Flag only when the table is a real,
        -- loaded constant map (a lazy DLL handle is nil on Linux and skipped).
        for tbl, field in text:gmatch("[^%w_]w%.([%a_][%w_]*)%.([%a_][%w_]*)") do
            local holder = w[tbl]
            if type(holder) == "table" and holder[field] == nil then
                fail("%s references w.%s.%s which ui/win32.lua does not define",
                     path, tbl, field)
            end
        end

        -- Single-level: w.<name>.  A <name> followed by `.` is a table access
        -- (the two-level case above) and is not reported here.  Otherwise it is
        -- a direct module field and must appear as an `M.<name>` assignment.
        for name, after in text:gmatch("[^%w_]w%.([%a_][%w_]*)()(.)") do
            if after ~= "." and not mnames[name] then
                fail("%s references w.%s which ui/win32.lua does not define",
                     path, name)
            end
        end
        ::continue::
    end
end

for _, path in ipairs(FILES) do
    check_globals(path)
end
check_win32_fields()

if failures == 0 then
    print("lint_fields: clean (" .. #FILES .. " files)")
else
    print(string.format("lint_fields: %d problem(s)", failures))
    os.exit(1)
end
