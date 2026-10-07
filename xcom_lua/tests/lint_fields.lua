-- lint_fields.lua - static lint for the Win32 layer, runnable on Linux.
-- Usage (Linux):  /home/dgliu/.local/openresty/luajit/bin/luajit tests/lint_fields.lua
-- Usage (Windows, cwd = xcom_lua): the GGET half needs an interpreter that can
-- dump bytecode.  The in-tree build has the dumper but resolves jit/*.lua from
-- LUA_PATH, so both must be set (paths from this checkout's root):
--     set XCOM_LUAJIT=<repo>\luajit2-2.1-agentzh\src\luajit.exe
--     set LUA_PATH=<repo>\luajit2-2.1-agentzh\src\?.lua;;
--     runtime\luajit.exe tests\lint_fields.lua
-- Verified 2026-10-07: that pair scans all 20 files (no SKIP).  Unset, it
-- prints SKIP for the GGET half and only the static half runs.
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

-- Bytecode dumper.  XCOM_LUAJIT wins so a Windows developer can point the gate
-- at a stock LuaJIT: the shipped runtime/luvjit.exe is built without jit.bcs
-- and therefore cannot dump bytecode (see dump_supported()).
-- An exported-but-empty XCOM_LUAJIT means "unset" (Lua treats "" as truthy, so
-- `set XCOM_LUAJIT=` would otherwise become the interpreter name and turn the
-- whole scan into "''""' is not recognized" failures).
local LUAJIT = os.getenv("XCOM_LUAJIT")
if LUAJIT == "" then LUAJIT = nil end
LUAJIT = LUAJIT or arg[-1] or "luajit"
-- Quote for io.popen by hand: string.format("%q") escapes backslashes, which
-- cmd.exe cannot resolve, so every Windows path failed the gate while POSIX
-- paths (no backslashes) hid the bug.
local function shq(s)
    return '"' .. s .. '"'
end
local NULL_DEV = package.config:sub(1, 1) == "\\" and "nul" or "/dev/null"

-- io.popen hands the string to `cmd.exe /c` on Windows, and cmd strips the
-- first and last quote of an argument that starts with one -- so the quoted
-- executable path (which is necessary as soon as it contains a space) arrives
-- mangled: 'D:\...\luajit.exe" -bl "main.lua' is not recognized.  Wrapping the
-- whole command once more re-adds the pair cmd removes.  POSIX sh has no such
-- rule and needs the plain form, so the wrap is Windows-only.
local function popen_cmd(exe, args)
    if package.config:sub(1, 1) == "\\" then
        return shq(shq(exe) .. " " .. args)
    end
    return shq(exe) .. " " .. args
end
local FILES = {
    "main.lua",
    "core/ansi.lua", "core/charset.lua", "core/config.lua",
    "core/bmp_writer.lua", "core/fs_path.lua", "core/receive_copy.lua",
    "core/script_engine.lua", "core/serial_sim.lua",
    "core/view_model.lua", "core/waveform.lua", "core/xcom_ffi.lua",
    "ui/connection_panel.lua", "ui/controls.lua", "ui/imgui_bridge.lua",
    "ui/receive_view.lua", "ui/send_panel.lua", "ui/status_bar.lua",
    "ui/win32.lua", "ui/window.lua",
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
    local pipe = io.popen(popen_cmd(LUAJIT,
        "-bl " .. shq(path) .. " 2>" .. NULL_DEV))
    if not pipe then
        fail("%s: could not run %q -bl", path, LUAJIT)
        return
    end
    local dump = pipe:read("*a")
    -- close() mirrors os.execute(): true/"exit"/0 on success, nil/"exit"/N on
    -- failure.  This status MUST be checked.  A file that does not compile
    -- produces an empty dump, which scans as "no undefined globals" -- the gate
    -- would report clean on a module that cannot even load.  main.lua is the
    -- entry point and no test suite requires it, so without this check a syntax
    -- error there reaches a release build that will not start, with CI green.
    local ok, why, code = pipe:close()
    if not (ok == true and (code or 0) == 0) then
        -- The diagnostic was suppressed above; re-run to capture it.
        local err = io.popen(popen_cmd(LUAJIT,
            "-bl " .. shq(path) .. " 2>&1 >" .. NULL_DEV))
        local detail = err and err:read("*a") or ""
        if err then
            err:close()
        end
        fail("%s does not compile (%s %s): %s", path, tostring(why),
             tostring(code), (detail:gsub("%s+$", "")))
        return
    end
    local seen = {}
    for name in dump:gmatch('GGET%s+%d+%s+%d+%s*;%s*"([^"]+)"') do
        if not BUILTINS[name] and not seen[name] then
            seen[name] = true
            fail("%s reads undefined global %q (forward reference or typo?)", path, name)
        end
    end
end

-- --------------------------------------------------------------------------
-- Probe: can this interpreter produce a `luajit -bl` listing at all?  Checked
-- once, on the first listed file.  A stripped driver answers "unknown luaJIT
-- command or jit.* modules not installed", and reading that as "the file does
-- not compile" prints 18 bogus syntax errors on Windows and buries the one
-- real finding -- exactly how a GGET regression reached CI.
--
-- A usable listing announces itself one of two ways: LuaJIT 2.1 prints
-- "-- BYTECODE -- <chunk>" banners, older builds print "main <path:0,0>".
-- Requiring either one alone silently turns the whole GGET scan into a SKIP on
-- the builds that use the other, which is the failure mode this probe exists to
-- prevent; accepting anything that merely is not the driver's marker is just as
-- wrong in the other direction, because a wrong or empty XCOM_LUAJIT makes the
-- shell answer "'""' is not recognized" and that would be read as "this file
-- does not compile" 20 times over.  So the probe wants a positive signature and
-- SKIPs otherwise.
-- --------------------------------------------------------------------------
local dump_ok
local function dump_supported()
    if dump_ok == nil then
        local pipe = io.popen(popen_cmd(LUAJIT,
            "-bl " .. shq(FILES[1]) .. " 2>&1"))
        -- The banner is on the first lines; the older "main <...>" header is
        -- the first non-empty line.
        local first = ""
        local banner = false
        for _ = 1, 8 do
            local line = pipe and pipe:read("*l")
            if not line then break end
            if line ~= "" and first == "" then
                first = line
            end
            if line:find("-- BYTECODE", 1, true) then banner = true end
        end
        if pipe then
            pipe:close()
        end
        dump_ok = banner or first:match("^main%s*<") ~= nil
    end
    return dump_ok
end

-- --------------------------------------------------------------------------
-- Check 1b: file-scope helper assignment that has no `local` in front of it.
--
-- Pure text, so it runs on any interpreter, including the dump-less luvjit.exe.
-- It catches the same defect class as the GGET scan one step earlier: this
-- codebase forward-declares its file-scope helpers (`local a, b,` at the top,
-- bodies assigned near the bottom).  Add a helper at the bottom and forget the
-- top, and every read compiles to GGET -- nil at call time, so the feature
-- silently does nothing -- plus a global in _G that another module can
-- overwrite.  That is precisely how ui/window.lua lost unique_port_by_hwid.
-- --------------------------------------------------------------------------
-- Consumes the line break.  Matching only the body ("([^\r\n]*)") leaves the
-- newline in the subject, so LuaJIT gmatch yields an extra empty string per
-- line: line numbers double, and a wrapped `local a, b,` continuation lands
-- on the empty match and is missed.
local function each_line(text)
    return (text .. "\n"):gmatch("([^\r\n]*)\r?\n")
end

local function local_declared_names(text)
    local lines = {}
    for line in each_line(text) do
        lines[#lines + 1] = line
    end
    local declared, i = {}, 1
    while i <= #lines do
        local line = lines[i]
        local rest = line:match("^local%s+(.-)%s*=") or line:match("^local%s+(.+)$")
        if rest and not line:match("^local%s+function") then
            for name in rest:gmatch("[%a_][%w_]*") do
                declared[name] = true
            end
            while i <= #lines and lines[i]:match(",%s*$") do
                i = i + 1
                for name in (lines[i] or ""):gmatch("[%a_][%w_]*") do
                    declared[name] = true
                end
            end
        end
        i = i + 1
    end
    return declared
end

local function check_file_scope_globals(path)
    local text = read_file(path)
    if not text then
        return
    end
    local declared = local_declared_names(text)
    local lineno = 0
    for line in each_line(text) do
        lineno = lineno + 1
        local name = line:match("^([%a_][%w_]*)%s*=%s*function")
        if name and not declared[name] then
            fail("%s:%d assigns file-scope %q with no `local %s` declaration"
                 .. ": reads of it compile to GGET (nil) and it leaks a global",
                 path, lineno, name, name)
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
    check_file_scope_globals(path)
end
if dump_supported() then
    for _, path in ipairs(FILES) do
        check_globals(path)
    end
else
    print("SKIP  GGET scan: " .. LUAJIT .. " cannot dump bytecode."
          .. "  Point XCOM_LUAJIT at a LuaJIT built with the dumper (its jit/"
          .. " tree, or jit.bcs, must be reachable: a locally built luajit"
          .. " needs LUA_PATH to include <luajit-src>/?.lua and /?/?.lua)."
          .. "  Check 1b above covers the same defect class statically, on any"
          .. " interpreter.")
end
check_win32_fields()

if failures == 0 then
    print("lint_fields: clean (" .. #FILES .. " files)")
else
    print(string.format("lint_fields: %d problem(s)", failures))
    os.exit(1)
end
