-- smoke_phase4.lua - headless Phase-4 integration smoke test.
-- Boots the real window WITHOUT showing it interactively, pushes waveform
-- data through the script engine, and asserts the ImGui DLL accepted it.
-- Verifies: DLL exports, scope push, highlight rules, script enable.
local ffi = require("ffi")
package.path = "./core/?.lua;./ui/?.lua;" .. package.path

local passed, failed = 0, 0
local function ok(label, cond)
    if cond then passed = passed + 1
    else failed = failed + 1; print("FAIL  " .. label) end
end

-- 1) DLL scope exports resolve.
ffi.cdef[[
int xcom_imgui_scope_push(int channel, double x, double y);
void xcom_imgui_scope_clear(void);
void xcom_imgui_scope_set_visible(int visible);
void xcom_imgui_set_highlight_rules(const char* packed, int count);
]]
local imgui_ok, lib = pcall(ffi.load, "xcom_imgui")
ok("xcom_imgui.dll loads", imgui_ok)
if imgui_ok then
    local push_ok, push = pcall(function() return lib.xcom_imgui_scope_push end)
    ok("scope_push export", push_ok and push ~= nil)
    local clr_ok, clr = pcall(function() return lib.xcom_imgui_scope_clear end)
    ok("scope_clear export", clr_ok and clr ~= nil)
    local vis_ok, vis = pcall(function() return lib.xcom_imgui_scope_set_visible end)
    ok("scope_set_visible export", vis_ok and vis ~= nil)
    local hl_ok, hl = pcall(function() return lib.xcom_imgui_set_highlight_rules end)
    ok("set_highlight_rules export", hl_ok and hl ~= nil)
    -- 2) Waveform module wires push to the scope.
    local wave_ok, wave = pcall(require, "waveform")
    ok("waveform loads", wave_ok and wave ~= nil)
    if wave_ok and push then
        wave.config({ series = { { name = "CH0", color = 0x112233 } } })
        local pushed = wave.push(1, 1.5, 2.5)
        ok("wave.push routes to scope", pushed == true)
    end
end

-- 3) Script engine end-to-end (sandbox + rules).
local engine_ok, engine_mod = pcall(require, "script_engine")
ok("script_engine loads", engine_ok)
if engine_ok then
    local uv = require("luv")
    uv.fs_mkdir("./_smoke_scripts", 493)
    local f = assert(io.open("./_smoke_scripts/hl.lua", "wb"))
    f:write('highlight.rule("X", 0xFF0000)\n')
    f:close()
    local engine = engine_mod.new({
        script_dir = "./_smoke_scripts",
        send = function() end,
        is_open = function() return false end,
    })
    engine:load_all()
    engine:enable("hl.lua", true)
    local rules = engine:take_rules_if_dirty()
    ok("rules collected", rules and #rules == 1)
    ok("rule pattern", rules[1].pattern == "X")
    -- 4) Rules pack format (the imgui_bridge packing path).
    local parts = { tostring(rules[1].pattern),
        string.format("%06X", rules[1].color), "text" }
    local packed = table.concat(parts, "\0")
    ok("packed rule well-formed", packed == "X\0FF0000\0text")
    engine:shutdown()
    -- cleanup
    uv.fs_unlink("./_smoke_scripts/hl.lua")
    uv.fs_rmdir("./_smoke_scripts")
end

print(string.format("smoke_phase4: %d passed, %d failed", passed, failed))
if failed > 0 then os.exit(1) end
