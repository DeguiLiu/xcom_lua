--[[--------------------------------------------------------------------------
e2e_config_durability.lua - how long may a tick live in memory only?

Contract under test (ui/window.lua: Window:_mark_config_dirty /
_flush_config_save): a widget interaction marks the config dirty and the write
lands within CONFIG_SAVE_THROTTLE_MS after it, throttled so a burst of
interactions cannot turn into a per-message rewrite.

Why this needs a real event loop: the headless suites drive the save timer with
a fake (tests/test_multi_send.lua AK block), so they pin the SCHEDULING but not
the DURABILITY.  The complaint this exists for -- "I ticked 加回车换行, closed it,
reopened, and it is unticked again" -- is a wall-clock property: the old code
re-armed a 5000 ms quiet period on every interaction, so anything that ended the
process inside that window (a closed console, taskkill, a logoff) took the tick
with it.  Reproduced against a real luv loop before the fix: tick, then exit
1.5 s later, and the file still said false.

Usage (Windows, from xcom_lua/):  runtime/luvjit.exe tests/e2e_config_durability.lua
Exit 0 = every write landed inside the bound.  No DLL and no window are needed:
the object under test is the save scheduler, and the bridge is a buffer stand-in
with the production shape (same as the AK block).
------------------------------------------------------------------------]]--

local ok_luv, uv = pcall(require, "luv")
if not ok_luv or type(uv) ~= "table" or not uv.new_timer then
    print("SKIP  e2e_config_durability: needs luv (run with runtime/luvjit.exe)")
    os.exit(0)
end

package.path = "./core/?.lua;./ui/?.lua;./?.lua;" .. package.path

local ffi = require("ffi")
local config = require("config")
local window = require("window")
local ib = require("imgui_bridge")

local SLOTS = ib.MULTI_SLOTS or 8
local CAP = ib.MULTI_SLOT_CAPACITY or 256
local ROOT = os.getenv("TEMP") or "/tmp"
local DIR = ROOT .. "/xcom_e2e_durability_" .. tostring(os.time())

local passed, failed = 0, 0
local function check(label, condition)
    if condition then
        passed = passed + 1
        print("PASS  " .. label)
    else
        failed = failed + 1
        print("FAIL  " .. label)
    end
    io.stdout:flush()
end

local function mkdir(path)
    local rc = os.execute('mkdir "' .. path .. '"')
    return rc == true or rc == 0
end

assert(mkdir(DIR), "cannot create the scratch directory " .. DIR)
local CFG = DIR .. "/config.ini"

-- A bridge stand-in with the production buffer shapes: _save_config reads the
-- same int[1] a click would have flipped in the DLL.
local function fake_bridge(send_crlf, multi_crlf)
    return setmetatable({
        port = ffi.new("char[?]", 128), send = ffi.new("char[?]", 4096),
        send_crlf = ffi.new("int[1]", send_crlf),
        multi_crlf = ffi.new("int[1]", multi_crlf),
        send_hex = ffi.new("int[1]", 0), multi_hex = ffi.new("int[1]", 0),
        send_period = ffi.new("int[1]", 1000), multi_period = ffi.new("int[1]", 1000),
        multi_gap = ffi.new("int[1]", 100), multi_page = ffi.new("int[1]", 0),
        multi_page_count = ffi.new("int[1]", 1), multi_auto = ffi.new("int[1]", 0),
        auto_save = ffi.new("int[1]", 0), auto_clear = ffi.new("int[1]", 0),
        auto_clear_bytes = ffi.new("int[1]", 0), send_auto = ffi.new("int[1]", 0),
        multi_text = ffi.new("char[?]", SLOTS * CAP),
        multi_enabled = ffi.new("int[?]", SLOTS),
        pages = { { text = {}, enabled = {} } },
        -- on_close ends with imgui:close() -> shutdown export: without a lib
        -- table the D7 shutdown-save path would fault instead of saving.
        lib = { xcom_imgui_shutdown = function() return 1 end },
    }, { __index = ib })
end

local BASE_CFG = { window = { x = 80, y = 60, w = 920, h = 650 },
                   quick_pages = { { text = {}, enabled = {} } } }

-- Window:start() builds the timer this way; without a window/DLL that is the
-- one piece of wiring the harness has to reproduce.
local function make_window(send_crlf, multi_crlf)
    local data = config.load(CFG)
    local win = window.new(BASE_CFG, data, CFG)
    win.imgui = fake_bridge(send_crlf, multi_crlf)
    win._config_save_timer = uv.new_timer()
    win._config_save_callback = function()
        local ok, err = pcall(win._flush_config_save, win)
        if not ok then io.stderr:write("[uv config] " .. tostring(err) .. "\n") end
    end
    return win
end

-- Run the REAL loop for a while.  uv.stop() unwinds the current uv.run().
local function run_for(ms)
    local stop = uv.new_timer()
    stop:start(ms, 0, function() stop:stop() uv.stop() end)
    uv.run()
end

local function disk_crlf()
    local d = config.load(CFG)
    return config.get(d, "send", "crlf", false),
           config.get(d, "multipage", "crlf", false)
end

local function seed()
    local d = {}
    config.set(d, "send", "crlf", false)
    config.set(d, "multipage", "crlf", false)
    config.set(d, "multipage", "page_count", 1)
    assert(config.save(CFG, d), "cannot seed " .. CFG)
end

-- ===========================================================================
-- D1) The click reaches the disk inside the throttle window, with a real loop.
-- ===========================================================================
seed()
local win = make_window(0, 0)
local saves = 0
-- Count the writes without replacing the behaviour under test: the class
-- method is reached through the instance metatable (the module table does not
-- export the class).
local real_save = getmetatable(win)._save_config
win._save_config = function(self)
    saves = saves + 1
    return real_save(self)
end
local s0, m0 = disk_crlf()
check("D1 the seed is OFF on disk", s0 == false and m0 == false)
win.imgui.send_crlf[0] = 1              -- exactly what the C++ Toggle flips
win.imgui.multi_crlf[0] = 1
win:_dispatch_imgui_actions(128)        -- ActionSyncSettings
run_for(1200)
local s1, m1 = disk_crlf()
check("D2 both ticks are on disk ~1 window after the click",
      s1 == true and m1 == true)
check("D3 exactly one write covered the burst", saves == 1)

-- ===========================================================================
-- D4) The pre-fix repro: an abrupt end 1.5 s after the click.  The old 5 s
--     quiet period lost the tick here (measured); the throttle has written it
--     by then, so the next launch must come back ticked.
-- ===========================================================================
local s2, m2 = disk_crlf()
check("D4 a hard exit 1.5 s after the click would still find the tick",
      s2 == true and m2 == true)

-- ===========================================================================
-- D5) A burst must still coalesce (one write per window, not per message) AND
--     the newest value must be the one that lands -- the property the old
--     re-arm-every-time behaviour did not have.
-- ===========================================================================
saves = 0
for index = 1, 20 do
    win.imgui.send_crlf[0] = index % 2     -- 20 interactions in a few ms
    win:_mark_config_dirty()
end
win.imgui.send_crlf[0] = 1                 -- the value the user is left with
win:_mark_config_dirty()
run_for(1200)
local s3 = disk_crlf()
check("D5 the burst survives a hard exit 1.2 s later", s3 == true)
check("D6 the burst coalesced into at most one write per window", saves <= 3)

-- ===========================================================================
-- D7) on_close is still the last write: a toggle flipped and closed
--     immediately (well inside the window) must be persisted by the shutdown
--     save, not dropped because the timer never fired.
-- ===========================================================================
win.imgui.multi_crlf[0] = 0
win:_mark_config_dirty()
win:on_close()
local s4, m4 = disk_crlf()
check("D7 the shutdown save writes the newest state",
      s4 == true and m4 == false)

os.execute('rmdir /s /q "' .. DIR .. '"')
print(string.format("\nconfig durability: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
