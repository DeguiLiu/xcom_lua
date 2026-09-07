-- test_script_engine.lua - unit tests for core/script_engine.lua (pure Lua).
-- Usage: runtime\luvjit.exe tests\test_script_engine.lua
-- (lvs runs on any luajit with luv; on CI without luv the file degrades to
--  a syntax check by simply failing require.)

package.path = "./core/?.lua;" .. package.path
local uv = require("luv")
local engine_mod = require("script_engine")

local passed, failed = 0, 0
local function ok(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(label .. " (got=" .. tostring(got) .. " want=" .. tostring(want) .. ")",
        got == want)
end

-- ---- helpers: temp script dir --------------------------------------------
local script_dir = "./_test_scripts"
uv.fs_mkdir(script_dir, 493)

local function write_script(name, text)
    local f = assert(io.open(script_dir .. "/" .. name, "wb"))
    f:write(text)
    f:close()
end

local sent_log = {}
local rules_seen = nil
local engine = engine_mod.new({
    script_dir = script_dir,
    send = function(payload) sent_log[#sent_log + 1] = payload end,
    is_open = function() return true end,
    on_rules_changed = function(rules) rules_seen = rules end,
    auto_reload = false,
})

-- ---- 1) sandbox env: uart / on / filter / highlight / log / sys -----------
write_script("env_probe.lua", [[
_probe_result = function()
    return {
        uart = type(uart) == "table" and type(uart.send) == "function",
        on = type(on) == "table" and type(on.receive) == "function",
        filter = type(filter) == "table" and type(filter.keep) == "function",
        highlight = type(highlight) == "table",
        log = type(log) == "table" and type(log.info) == "function",
        sys = type(sys) == "table" and type(sys.now) == "function",
        name = _SCRIPT,
        no_io = io == nil,
        no_os_execute = os.execute == nil,
        no_g = _G == nil,
        tohex = ("AB"):toHex(),
    }
end
uart_send_probe = function() return uart.send_hex("41 42") end
]])

engine:load_all()
local n_after_env = #engine:script_names()
engine:enable("env_probe.lua", true)
local rec = engine.scripts["env_probe.lua"]
ok("enabled", engine:is_enabled("env_probe.lua"))
local probe = rec.env._probe_result()
ok("env.uart", probe.uart)
ok("env.on", probe.on)
ok("env.filter", probe.filter)
ok("env.highlight", probe.highlight)
ok("env.log", probe.log)
ok("env.sys", probe.sys)
eq("env._SCRIPT", probe.name, "env_probe.lua")
ok("env hides io", probe.no_io)
ok("env hides os.execute", probe.no_os_execute)
ok("env has no _G", probe.no_g)
eq("string.toHex ext", probe.tohex, "4142")
ok("env.uart", probe.uart)
ok("env.on", probe.on)
ok("env.filter", probe.filter)
ok("env.highlight", probe.highlight)
ok("env.log", probe.log)
ok("env.sys", probe.sys)
eq("env._SCRIPT", probe.name, "env_probe.lua")
ok("env hides io", probe.no_io)
ok("env hides os.execute", probe.no_os_execute)
eq("string.toHex ext", probe.tohex, "4142")

-- uart.send_hex path
rec.env.uart_send_probe()
eq("uart.send_hex transmits", #sent_log, 1)
eq("uart.send_hex payload", sent_log[1], "AB")

-- ---- 2) recv hook transform + drop ----------------------------------------
write_script("hook.lua", [[
on.receive(function(text)
    if text:find("SECRET", 1, true) then return nil end
    return text:gsub("bad", "good")
end)
]])
engine:load_all()
ok("scan adds new script", #engine:script_names() == n_after_env + 1)
engine:enable("hook.lua", true)
eq("transform", engine:process_rx("a bad line\n"), "a good line\n")
eq("drop batch", engine:process_rx("top SECRET bottom\n"), nil)
eq("empty after drop", engine:process_rx(""), nil)

-- ---- 3) hook error isolation + 3 strikes -----------------------------------
write_script("boom.lua", [[
on.receive(function(text) error("kaboom") end)
]])
engine:load_all()
engine:enable("boom.lua", true)
-- 3 failures then auto-disable; batch keeps flowing (nil returned by
-- process_rx only when dropped — error path returns original text).
for i = 1, 3 do
    eq("boom pass " .. i .. " survives", engine:process_rx("x\n"), "x\n")
end
ok("boom hook disabled after 3 strikes",
    engine.scripts["boom.lua"].recv_hook == nil)

-- ---- 4) line filter: keep / drop / combined --------------------------------
write_script("lv.lua", [[
filter.drop("DEBUG")
]])
engine:load_all()
engine:enable("lv.lua", true)
eq("drop line", engine:process_rx("[INFO] hi\n[DEBUG] noise\n"), "[INFO] hi\n")

write_script("keep.lua", [[
filter.keep("ERROR", "WARN")
]])
engine:load_all()
engine:enable("keep.lua", true)
eq("keep only matches",
    engine:process_rx("[INFO] no\n[ERROR] yes\n[WARN] also\n"),
    "[ERROR] yes\n[WARN] also\n")

-- ---- 5) partial line across batches ----------------------------------------
engine.scripts["keep.lua"].env.filter.clear()
engine.scripts["lv.lua"].env.filter.clear()
write_script("part.lua", [[
filter.drop("HIDE")
]])
engine:load_all()
engine:enable("part.lua", true)
-- "halfHIDE" spans two batches; the pending tail must join before deciding.
local r1 = engine:process_rx("begin half")
eq("partial held", r1, nil)  -- nothing complete to show yet
local r2 = engine:process_rx("HIDE end\nnext\n")
eq("joined line dropped, next kept", r2, "next\n")

-- ---- 6) highlight rule aggregation -----------------------------------------
write_script("hl.lua", [[
highlight.rule("ERROR", 0xFF0000)
highlight.rule("bgmark", 0x00FF00, "bg")
]])
engine:load_all()
engine:enable("hl.lua", true)
local rules = engine:take_rules_if_dirty()
ok("rules dirty once", rules ~= nil)
eq("rule count", #rules, 2)
eq("rule1 pattern", rules[1].pattern, "ERROR")
eq("rule1 color", rules[1].color, 0xFF0000)
eq("rule1 style", rules[1].style, "text")
eq("rule2 style", rules[2].style, "bg")
ok("rules clean after take", engine:take_rules_if_dirty() == nil)
-- disabled script's rules excluded (enable toggles re-mark dirty)
engine:enable("hl.lua", false)
rules = engine:take_rules_if_dirty()
eq("disabled rules excluded", rules and #rules or 0, 0)

-- ---- 7) send hook -----------------------------------------------------------
-- (single-script scenarios: a transform script and a drop script, exercised
-- one at a time so script ordering cannot mask semantics)
write_script("snddrop.lua", [[
on.send(function(p) if p == "NO" then return nil end return p end)
]])
engine:load_all()
engine:enable("snddrop.lua", true)
eq("send drop", engine:dispatch_send("NO"), nil)
eq("send pass", engine:dispatch_send("OK"), "OK")
engine:enable("snddrop.lua", false)

write_script("snd.lua", [[
on.send(function(p) return "[" .. p .. "]" end)
]])
engine:load_all()
engine:enable("snd.lua", true)
eq("send transform", engine:dispatch_send("ping"), "[ping]")
engine:enable("snd.lua", false)

-- ---- 8) log ring + REPL -----------------------------------------------------
-- Disable everything else so the REPL host env is unambiguous.
for _, name in ipairs(engine:script_names()) do
    if name ~= "env_probe.lua" then engine:enable(name, false) end
end
engine:enable("env_probe.lua", true)
engine:eval_command("return 1 + 1")
engine:eval_command("repl_marker = 42")   -- top-level assignment lands in env
eq("repl set global", rec.env.repl_marker, 42)
local log_text = engine:log_lines()
ok("log has repl output", log_text:find("repl", 1, true) ~= nil)
engine:eval_command("error('boomcmd')")

-- ---- 9) pending force flush (oversize) --------------------------------------
-- part.lua is the only filter script still enabled above; drop the other
-- scripts first, then push an unterminated line past the 8 KiB bound.
for _, name in ipairs(engine:script_names()) do
    if name ~= "part.lua" then engine:enable(name, false) end
end
engine:enable("part.lua", true)
local huge = string.rep("A", 9000)
local r = engine:process_rx(huge)  -- > 8 KiB pending, no newline
eq("oversize pending flushed as visible line", r, huge)

-- ---- cleanup ---------------------------------------------------------------
local function rm_rf(path)
    local req = uv.fs_scandir(path)
    if not req then return end
    while true do
        local name = uv.fs_scandir_next(req)
        if not name then break end
        uv.fs_unlink(path .. "/" .. name)
    end
    uv.fs_rmdir(path)
end
engine:shutdown()
rm_rf(script_dir)

print(string.format("script_engine: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
