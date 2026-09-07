--[[--------------------------------------------------------------------------
main.lua - entry point for the LuaJIT+Win32 FFI serial client.

Usage (Windows):  luajit.exe main.lua

Sets up the module search path, loads configuration (config.ini alongside),
creates the frameless main window, and runs the message loop.  All ABI and
Win32 calls happen on this single thread (design §3).

On Linux this file is not runnable (no Win32); it is kept minimal so the rest
of the tree can be syntax-checked with `luajit -bl` / a require probe.
------------------------------------------------------------------------]]--

if arg and arg[0] and arg[0]:sub(1, 1) ~= "@" then
    -- Launched as a script; push its own directory onto package.path so
    -- require("core.xxx") / require("ui.xxx") resolve relative to main.lua.
    local dir = arg[0]:match("^(.*)[/\\]")
    if not dir then
        dir = "."  -- bare script name like "main.lua": use the cwd
    end
    package.path = dir .. "/core/?.ljbc;" .. dir .. "/ui/?.ljbc;" ..
                   dir .. "/core/?.lua;" .. dir .. "/ui/?.lua;" .. package.path
    -- Vendored pure-Lua libraries (docs/lua-libs-value-and-recommendations.md
    -- section 5): one injection point here, not per-script path munging.
    -- A-tier only; stdlib-ext (mutates built-ins) is deliberately excluded.
    -- Copies live inside the project (libs/, vendored per-project — the
    -- ../third_party tree is a scratch source, not a runtime dependency).
    package.path = dir .. "/libs/protocol/?.lua;" ..
                   dir .. "/libs/lua51/?.lua;" ..
                   dir .. "/libs/lua51/?/init.lua;" ..
                   dir .. "/libs/lua51/penlight/?.lua;" ..
                   dir .. "/libs/openresty/?.lua;" ..
                   package.path
end

local config = require("config")
local window = require("window")
local w = require("win32")
local xcom = require("xcom_ffi")

-- Resolve Win32 libraries before reading monitor metrics below.  Window.new
-- also calls this defensively, but geometry normalization happens first.
w.load()

-- LuaJIT stays ON by default (docs/lua_coding_guidelines.md §6: a global
-- jit.off() is forbidden — interpreter mode is far slower).  The C-re-entry
-- hazard it used to guard against (``bad callback`` panic when traced Lua is
-- re-entered by Win32/ImGui) is handled at the correct scope instead: every
-- closure C can re-enter — the WndProc FFI callback, the message pump, the
-- ImGui render driver and every luv timer callback — carries its own
-- jit.off(fn[, true]); the recursive flag also switches off statically
-- nested protos so no trace can start on a re-entry path.  FFI calls that do
-- NOT re-enter Lua (xcom core, Win32, ImGui pulls) stay traceable and get the
-- full JIT speedup.  New C callbacks MUST follow the same rule or the panic
-- can return.

local APP_DIR = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local CONFIG_PATH = APP_DIR .. "/config.ini"

-- Load persisted settings (safe defaults on missing/corrupt file).
local cfg_data = config.load(CONFIG_PATH)
-- Window geometry is persisted across sessions, but monitor changes and DPI
-- scaling can leave an old maximized rectangle (for example 2560x1440) that
-- makes the dashboard appear to lose controls.  Clamp it to the current
-- work area and fall back to the compact desktop layout when the saved value
-- is clearly a stale full-screen rectangle.
local screen_w = math.max(640, tonumber(w.user32.GetSystemMetrics(w.SM_CXSCREEN)) or 1280)
local screen_h = math.max(480, tonumber(w.user32.GetSystemMetrics(w.SM_CYSCREEN)) or 720)
local saved_w = tonumber(config.get(cfg_data, "window", "w", 920)) or 920
local saved_h = tonumber(config.get(cfg_data, "window", "h", 650)) or 650
local saved_x = tonumber(config.get(cfg_data, "window", "x", 80)) or 80
local saved_y = tonumber(config.get(cfg_data, "window", "y", 60)) or 60
if saved_w >= screen_w - 8 or saved_h >= screen_h - 8 then
    saved_w, saved_h = math.min(1100, screen_w - 80), math.min(760, screen_h - 100)
end
saved_w = math.max(920, math.min(saved_w, screen_w))
saved_h = math.max(650, math.min(saved_h, screen_h))
saved_x = math.max(0, math.min(saved_x, screen_w - saved_w))
saved_y = math.max(0, math.min(saved_y, screen_h - saved_h))
local cfg = {
    window = {
        x = saved_x,
        y = saved_y,
        w = saved_w,
        h = saved_h,
    },
    port = config.get(cfg_data, "port", "name", ""),
    baud_rate = config.get(cfg_data, "serial", "baud_rate", 115200),
    data_bits = config.get(cfg_data, "serial", "data_bits", 8),
    stop_bits = config.get(cfg_data, "serial", "stop_bits", 0),
    parity = config.get(cfg_data, "serial", "parity", 0),
    flow_control = config.get(cfg_data, "serial", "flow_control", 0),
    dtr_enable = config.get(cfg_data, "serial", "dtr_enable", false),
    rts_enable = config.get(cfg_data, "serial", "rts_enable", false),
    receive_hex = config.get(cfg_data, "send", "receive_hex", false),
    timestamp = config.get(cfg_data, "display", "timestamp", false),
    pause_display = config.get(cfg_data, "display", "pause_display", false),
    auto_clear_bytes = config.get(cfg_data, "display", "auto_clear_bytes", 0),
    max_display_bytes = config.get(cfg_data, "display", "max_display_bytes", 2 * 1024 * 1024),
    auto_save = config.get(cfg_data, "display", "auto_save", false),
    save_path = config.get(cfg_data, "display", "save_path", ""),
    always_on_top = config.get(cfg_data, "display", "always_on_top", false),
    receive_window_bytes = config.get(cfg_data, "display", "receive_window_bytes", 65536),
    send_hex = config.get(cfg_data, "send", "hex", false),
    send_crlf = config.get(cfg_data, "send", "crlf", false),
    autosend_period_ms = config.get(cfg_data, "send", "autosend_period_ms", 0),
    -- Script engine settings ([script] section).
    script_enabled = (function()
        local raw = config.get(cfg_data, "script", "enabled", "")
        local names = {}
        for name in tostring(raw):gmatch("[^,%s]+") do
            names[#names + 1] = name
        end
        return names
    end)(),
    script_auto_reload = config.get(cfg_data, "script", "auto_reload", false),
    script_autorun_console = config.get(cfg_data, "script", "autorun_console", false),
    -- Feature-extension settings (consumed once the Phase 4/5 widgets ship;
    -- kept in cfg from day one so config round-trips preserve them).
    baud_custom = config.get(cfg_data, "serial", "baud_custom", 0),
    multi_gap_ms = config.get(cfg_data, "send", "multi_gap_ms", 100),
    charset = config.get(cfg_data, "display", "charset", "ASCII"),
    frame_gap_ms = config.get(cfg_data, "display", "frame_gap_ms", 0),
    tx_echo = config.get(cfg_data, "display", "tx_echo", true),
}
local page_count = math.max(1, math.min(config.get(cfg_data, "multipage", "page_count", 1), 50))
cfg.quick_pages = {}
for page = 0, page_count - 1 do
    local entries = { text = {}, enabled = {} }
    for index = 0, 7 do
        entries.text[index + 1] = config.get_multi_entry(cfg_data, page, index, "text", "")
        entries.enabled[index + 1] = config.get_multi_entry(cfg_data, page, index, "enabled", false)
    end
    cfg.quick_pages[#cfg.quick_pages + 1] = entries
end
cfg.quick = cfg.quick_pages[1]

-- Windows host guard: bail with a clear message if not on Windows.
if not (w.is_windows and w.is_windows()) then
    io.stderr:write("this client requires a Windows host (Win32 FFI)\n")
    os.exit(2)
end

-- Build and run the window.  It resolves Win32 DLLs and creates the xcom
-- handle on the same thread.
local ok, err, win
ok, win = pcall(window.new, cfg, cfg_data, CONFIG_PATH)
if not ok then
    io.stderr:write("failed to initialise Win32 layer: " .. tostring(win) .. "\n")
    os.exit(2)
end
if not win:init_window() then
    io.stderr:write("failed to create the main window\n")
    os.exit(2)
end
win:start()
return win:run()
