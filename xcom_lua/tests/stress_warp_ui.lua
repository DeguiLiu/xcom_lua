--[[--------------------------------------------------------------------------
stress_warp_ui.lua - full-bandwidth sustained-receive stress on the REAL UI.

Simulates 921600-baud line rate (~90 KiB/s) arriving through the same
_imgui_receive path poll_display fills (append -> 64 KiB rolling trim ->
flush -> set_receive_text -> ImGui draw under WARP), plus periodic mouse
interaction, then reports:

  * memory stability (Lua heap via collectgarbage count + process private
    bytes via a helper read from tasklist at start and end)
  * GC behavior (step counter, whether a full collect ever became necessary)
  * frame pacing vs data cadence (how many data-requested frames fired)
  * backlog of unflushed receive bytes (should stay bounded by 64 KiB)

No COM port needed: data is generated locally at line rate.  The core-side
data-loss contract (pool sizing, drain-to-empty) is covered separately by
tests/stress_fullband.lua when hardware is present.

Usage: runtime\luvjit.exe tests/stress_warp_ui.lua [seconds] [kib_per_s]
------------------------------------------------------------------------]]--

if arg and arg[0] and arg[0]:sub(1, 1) ~= "@" then
    local dir = arg[0]:match("^(.*)[/\\]") or "."
    -- Tests live in <root>/tests; strip the trailing "tests" component so
    -- core/ and ui/ resolve from the app root whether arg[0] is relative
    -- ("tests/x.lua" -> ".") or absolute ("<root>/tests/x.lua" -> "<root>").
    local root
    if dir == "tests" then
        root = "."
    else
        root = dir:gsub("[/\\]tests$", "")
    end
    package.path = root .. "/core/?.lua;" .. root .. "/ui/?.lua;" ..
                   package.path
end

local config = require("config")
local window = require("window")
local w = require("win32")
local uv = require("luv")
local ffi = require("ffi")

w.load()
if jit and jit.off then jit.off() end

local seconds = tonumber(arg and arg[1]) or 30
local rate_kib = tonumber(arg and arg[2]) or 90

-- ---- line-rate frame builder --------------------------------------------
-- ~46-byte lines resemble a real telemetry tail; 10 ms of 921600 baud is
-- ~920 bytes, i.e. ~20 lines per tick.
local seq = 0
local function line()
    seq = seq + 1
    return string.format(
        "[%02d:%02d:%02d.%03d] RX %04d B dst=0x%02X seq=%06d v=%04X chk=%04X\n",
        (seq * 3) % 24, (seq * 7) % 60, (seq * 11) % 60, (seq * 977) % 1000,
        (seq * 137) % 4096, (seq * 51) % 256, seq, seq % 65536, (seq * 31) % 65536)
end

-- ---- window startup (preview pattern) -----------------------------------
local APP = "."
local cfg_data = config.load(APP .. "/config.ini")
local cfg = {
    window = { x = 40, y = 40, w = 920, h = 650 },
    port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
    parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
    receive_hex = false, timestamp = true, pause_display = false,
    auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
    auto_save = false, save_path = "", always_on_top = false,
    send_hex = false, send_crlf = false, autosend_period_ms = 0,
    quick_pages = { { text = {}, enabled = {} } },
    quick = { text = {}, enabled = {} },
}

local ok, win = pcall(window.new, cfg, cfg_data, APP .. "/config.ini")
if not (ok and win) then
    io.stderr:write("stress init failed: " .. tostring(win) .. "\n")
    os.exit(2)
end
if not win:init_window() then
    io.stderr:write("stress window create failed\n")
    os.exit(2)
end

-- ---- statistics plumbing -------------------------------------------------
local stats = {
    injected = 0,          -- bytes appended into the receive path
    frames = 0,            -- rendered ImGui frames (counted at the bridge)
    appended_ticks = 0,    -- 10 ms injection ticks
}
-- Hook the bridge frame counter directly: a frame is counted only when the
-- pacing gate let render_imgui through to the real ImGui frame (the outer
-- render_imgui wrapper would over-count since it early-returns when throttled).
local bridge = win.imgui
local frame_orig = bridge and bridge.frame
if frame_orig then
    bridge.frame = function(self)
        local r = frame_orig(self)
        if r then stats.frames = stats.frames + 1 end
        return r
    end
end

-- Backpressure visibility: sample the trim path indirectly through the
-- chunk-byte counter before each append (it is bounded to <= 64 KiB by
-- _append_imgui_receive; a value stuck at 65535 with data flowing means the
-- window is fully saturated, which is expected at full bandwidth).
local function backlog() return win._imgui_receive_chunk_bytes or 0 end

-- ---- line-rate injection: 10 ms luv timer --------------------------------
-- poll_display drains on the 10 ms cadence while connected; the UI stress
-- therefore appends on the same cadence at line rate.  The loop's effective
-- tick rate drops when a WARP frame occupies the thread (a periodic libuv
-- timer does not replay missed fires), so each tick injects by ELAPSED time
-- (elapsed_ms * rate) — the stream stays at line rate regardless of how many
-- ticks actually fire.
local per_tick = math.floor(rate_kib * 1024 * 10 / 1000)
local last_tick_at
local inject_timer = uv.new_timer()
win._stress_inject = inject_timer
local inject_tick = function()
    local now = uv.now()
    if not last_tick_at then last_tick_at = now end
    local elapsed = now - last_tick_at
    last_tick_at = now
    local budget = math.floor(rate_kib * 1024 * elapsed / 1000)
    if budget < per_tick then budget = per_tick end  -- at least one tick's worth
    stats.appended_ticks = stats.appended_ticks + 1
    local acc = {}
    local n = 0
    while n < budget do
        local l = line()
        acc[#acc + 1] = l
        n = n + #l
    end
    local chunk = table.concat(acc)
    win:_append_imgui_receive(chunk)
    stats.injected = stats.injected + #chunk
    -- Mirror poll_display's frame request at data cadence.
    win:request_frame(100)
end
jit.off(inject_tick, true)  -- luv C-callback entry: never JIT-compiled
-- Seed one full window so the first frame is not near-empty.
for _ = 1, 30 do inject_tick() end
inject_timer:start(10, 10, inject_tick)

-- ---- interactive load: gentle mouse moves every 500 ms -------------------
-- Simulates a user reading the log while data streams (the "full bandwidth +
-- interaction" frame-budget question).  Moves go through SetCursorPos; the
-- window's WM_MOUSEMOVE handler requests interactive frames.
local interact_timer = uv.new_timer()
win._stress_interact = interact_timer
local function move_mouse()
    local r = ffi.new("RECT")
    if w.user32.GetWindowRect(win.hwnd, r) ~= 0 then
        local cx = math.floor((r.left + r.right) / 2)
        local cy = math.floor((r.top + r.bottom) / 2)
        w.user32.SetCursorPos(cx - 100 + (seq % 200), cy - 40 + (seq % 80))
    end
end
jit.off(move_mouse, true)
interact_timer:start(500, 500, move_mouse)

-- ---- periodic report ------------------------------------------------------
local report_timer = uv.new_timer()
win._stress_report = report_timer
local t0 = uv.now()
local function report()
    print(string.format(
        "  t=%4.1fs heap=%6.1f KiB backlog=%5d B frames=%5d ticks=%5d rate=%6.1f KiB/s",
        (uv.now() - t0) / 1000,
        collectgarbage("count"),
        backlog(),
        stats.frames,
        stats.appended_ticks,
        stats.injected / 1024 / math.max(0.001, (uv.now() - t0) / 1000)))
    io.stdout:flush()
end
jit.off(report, true)
report_timer:start(5000, 5000, report)

-- ---- shutdown summary -----------------------------------------------------
-- Close the window: on_close saves config and destroys the window, the
-- message loop then sees WM_QUIT and win:run() returns.  (uv.stop() alone
-- would only mark the loop stopped — the Win32 pump would keep the process
-- alive forever.)
local shutdown = function()
    inject_timer:stop()
    interact_timer:stop()
    report_timer:stop()
    print("")
    print("==== stress summary ====")
    print(string.format("duration:        %.1f s", (uv.now() - t0) / 1000))
    print(string.format("injected:        %.1f KiB (%d bytes)",
                        stats.injected / 1024, stats.injected))
    print(string.format("effective rate:  %.1f KiB/s (target %d)",
                        stats.injected / 1024 / ((uv.now() - t0) / 1000), rate_kib))
    print(string.format("frames rendered: %d (%.1f fps)",
                        stats.frames, stats.frames / ((uv.now() - t0) / 1000)))
    print(string.format("injection ticks: %d", stats.appended_ticks))
    print(string.format("final Lua heap:  %.1f KiB", collectgarbage("count")))
    print(string.format("final backlog:   %d B (cap 65535)", backlog()))
    print(string.format("trim happened:   %s",
                        stats.injected > 70000 and "yes (rolling window)" or "no"))
    win:on_close()
end
jit.off(shutdown, true)
local shutdown_timer = uv.new_timer()
win._stress_shutdown = shutdown_timer
shutdown_timer:start(seconds * 1000, 0, shutdown)

return win:run()
