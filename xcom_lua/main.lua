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
    package.path = dir .. "/core/?.lua;" .. dir .. "/ui/?.lua;" .. package.path
end

local config = require("config")
local window = require("window")
local w = require("win32")
local xcom = require("xcom_ffi")

local APP_DIR = (arg and arg[0] and arg[0]:match("^(.*)[/\\]")) or "."
local CONFIG_PATH = APP_DIR .. "/config.ini"

-- Load persisted settings (safe defaults on missing/corrupt file).
local cfg_data = config.load(CONFIG_PATH)
local cfg = {
    window = {
        x = config.get(cfg_data, "window", "x", 80),
        y = config.get(cfg_data, "window", "y", 60),
        w = config.get(cfg_data, "window", "w", 920),
        h = config.get(cfg_data, "window", "h", 650),
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
    send_hex = config.get(cfg_data, "send", "hex", false),
    send_crlf = config.get(cfg_data, "send", "crlf", false),
    autosend_period_ms = config.get(cfg_data, "send", "autosend_period_ms", 0),
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
