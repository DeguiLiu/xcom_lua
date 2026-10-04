--[[--------------------------------------------------------------------------
e2e_drag_freeze.lua - in-process E2E for the receive-area tail-follow freeze.

Contract under test (ReceiveContent in native/xcom_imgui/xcom_imgui_bridge.cpp):
while the left button is held and the user drags a selection over the receive
log, the view must NOT chase the rows that keep arriving; on release it stays
parked on the selected rows; and once the user scrolls back to the tail the
follow re-arms.

Why this is not a screenshot question: a press that never reached the log and a
held drag that works look identical on screen (nothing moves, nothing is
highlighted yet), which is exactly how the earlier pixel probe produced a false
negative.  So the check reads the render loop's own state through the telemetry
exports -- xcom_imgui_get_receive_rect for the only authoritative press point,
xcom_imgui_get_receive_scroll for the freeze itself ("scroll_y holds while
scroll_max grows"), xcom_imgui_get_receive_selection for a gesture that really
selected bytes, plus xcom_imgui_selection_dragging -- and drives the gesture
with a REAL injected mouse: the ImGui Win32 backend consumes ordinary
WM_MOUSEMOVE / WM_LBUTTONDOWN messages, so SetCursorPos + mouse_event go through
the same state machine a hand does.  Injection cannot choose which window
receives the click, so the driver converts the rect (client to screen),
re-asserts the z-order, and rejects any candidate that fails to enter the drag state.

Usage (Windows, from xcom_lua/):  runtime/luvjit.exe tests/e2e_drag_freeze.lua
Exit 0 = frozen while held, parked on release, follow re-armed on the tail.
Needs the telemetry exports in the loaded DLL; on an older binary the check
reports "rebuild xcom_imgui.dll" instead of asserting on stale state.
------------------------------------------------------------------------]]--

-- No backslash appears in this file on purpose: Windows accepts forward
-- slashes for every path used here, and the one place a native separator shows
-- up (the script name in arg[0]) is normalised instead of pattern-matched.
local BS = string.char(92)
local NL = string.char(10)
local function forward(s) return (s:gsub(BS, "/")) end

if arg and arg[0] and arg[0]:sub(1, 1) ~= "@" then
    local dir = forward(arg[0]):match("^(.*)/") or "."
    local root = dir == "tests" and "." or dir:gsub("/tests$", "")
    package.path = root .. "/core/?.lua;" .. root .. "/ui/?.lua;" .. package.path
end

local config = require("config")
local window = require("window")
local w = require("win32")
local uv = require("luv")
local ffi = require("ffi")

w.load()

local MOUSEEVENTF_LEFTDOWN = 0x0002
local MOUSEEVENTF_LEFTUP   = 0x0004
local MOUSEEVENTF_WHEEL    = 0x0800
local WHEEL_NOTCH          = 120
local SWP_STATIC = 0x0001 + 0x0002 + 0x0010   -- NOSIZE|NOMOVE|NOACTIVATE

-- SetWindowPos wants an HWND in the insert-after slot and win32.lua keeps the
-- pseudo-handles as plain numbers, exactly like always_on_top does in
-- ui/window.lua: cast once here rather than at every call.
local HWND_TOPMOST = ffi.cast("HWND", w.style.HWND_TOPMOST)
local HWND_NOTOPMOST = ffi.cast("HWND", w.style.HWND_NOTOPMOST)

-- Every wait counts timer ticks: the app renders on its own clock, and 25 ms is
-- below the interactive frame interval, so no frame goes unobserved.
local TICK_MS           = 25
local ENGAGE_TIMEOUT    = 20     -- ~0.5 s for the queued WM_LBUTTONDOWN to be
                                 -- dispatched and drawn; see the engage phase
local HOLD_TICKS        = 55     -- ~1.4 s of held drag with the stream running
local RELEASE_TICKS     = 16     -- ~0.4 s parked after release
local WHEEL_TICKS       = 8      -- 96 notches: enough to climb back to the tail
local FOLLOW_TICKS      = 24     -- ~0.6 s of follow once back on the tail
local SETTLE_TIMEOUT    = 400    -- ~10 s
local MIN_SCROLL_RANGE_PX = 600  -- ~30 rows past one viewport: with less range
                                 -- than this the freeze measurement is a couple
                                 -- of rows either way and proves nothing

-- Candidate press points as fractions of the log rect.  The first is the normal
-- case; the rest cover a scaled or partly occluded client area, where the
-- gesture would otherwise be reported as "the freeze is broken" when in fact no
-- click reached the log at all.
local PRESS_POINTS = { {0.30, 0.50}, {0.30, 0.30}, {0.30, 0.70}, {0.50, 0.50} }
local ROW_STEP_PX  = 20          -- one log row at the shipped mono size

-- mouse_event dwData is a DWORD: hand it a negative wheel delta as two's
-- complement instead of letting the FFI conversion reject the minus sign.
local function u32(v)
    if v >= 0 then return v end
    return v + 0x100000000
end

local function emit(line)
    io.stderr:write(line)
    io.stderr:write(NL)
end

-- Scratch ini: closing the window persists config, so never point that at the
-- user's real config.ini.
local ini_path = (os.getenv("TEMP") or ".") .. "/xcom_drag_freeze.ini"
local cfg = {
    window = { x = 40, y = 40, w = 920, h = 650 },
    port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
    parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
    receive_hex = false, timestamp = false, pause_display = false,
    auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
    auto_save = false, save_path = "", always_on_top = false,
    receive_window_bytes = 65536,
    send_hex = false, send_crlf = false, autosend_period_ms = 0,
    quick_pages = { { text = {}, enabled = {} } },
    quick = { text = {}, enabled = {} },
}

local ok, win = pcall(window.new, cfg, config.load(ini_path), ini_path)
if not (ok and win) then
    emit("init failed: " .. tostring(win))
    os.exit(2)
end
if not win:init_window() then
    emit("window create failed")
    os.exit(2)
end
win:start()

-- Open the simulator exactly as Window:_smoke_env_hooks does, through the same
-- core_open the "open" button routes through, then raise the rate: the default
-- 1 KiB/s gives one row per ~70 ms, too slow for a 1.4 s hold to grow the tail
-- by a measurable amount.
win._imgui_port = "VIRTUAL"
win.sim:profile("text")
win.sim:set_rate(8192)
win:core_open()

local ib = win.imgui
local checks = {}
local function check(name, pass, detail)
    checks[#checks + 1] = {
        name = name, pass = pass and true or false, detail = detail or "",
    }
    return pass
end

local st = {
    phase = "settle", ticks = 0, attempt = 0, left = 0, wheel_left = 0,
    raised = false, pressed = false, finished = false,
    rect = nil, press = nil, screen = nil, frame = nil, drag_y = 0,
    y_ref = 0, max_ref = 0,
    press_y = 0, drift_px = 0, engage_ticks = 0,
    hold_samples = 0, hold_dragging = 0, chase_px = 0, grew_px = 0, sel_bytes = 0,
    parked_y = 0, release_move_px = 0,
    on_tail_after_wheel = false, follow_ref = 0, follow_px = 0,
    follow_samples = 0, follow_pinned = 0,
}

local function telemetry()
    local y, max = ib:receive_scroll()
    local sel_b, sel_e = ib:receive_selection()
    return {
        y = y, max = max,
        dragging = ib:selection_dragging(),
        sel = (sel_b ~= nil and sel_e ~= nil) and (sel_e - sel_b) or 0,
    }
end

local timer

local function press_up()
    if st.pressed then
        w.user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
        st.pressed = false
    end
end

local function finish()
    if st.finished then return end
    st.finished = true
    -- Release no matter how we got here: a driver that leaves the button down
    -- hands the next run a frozen log.
    press_up()
    if timer then timer:stop(); timer:close() end
    w.user32.SetWindowPos(win.hwnd, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_STATIC)
    emit("---- receive drag-freeze E2E ----")
    local failed = 0
    for _, c in ipairs(checks) do
        if not c.pass then failed = failed + 1 end
        emit(string.format("%s  %s", c.pass and "PASS" or "FAIL", c.name) ..
             (c.detail == "" and "" or (": " .. c.detail)))
    end
    local pass = failed == 0
    emit(pass and "E2E_DRAG_FREEZE: PASS" or "E2E_DRAG_FREEZE: FAIL")
    win:on_close()
    os.exit(pass and 0 or 1)
end

local function give_up(name, detail)
    check(name, false, detail)
    finish()
end

-- Turn one fractional candidate into a press point.  Two conversions matter and
-- both were measured, not assumed:
--   * The exported rect is in the ImGui space, which for a windowed Win32
--     backend is the CLIENT area (the backend hands ImGui client coordinates),
--     while SetCursorPos speaks physical screen pixels.  On this box the window
--     is a borderless WS_POPUP, so client origin == window origin, but the
--     conversion is done properly rather than relying on that.
--   * WindowFromPoint(POINT) was tried as a "does this point belong to us"
--     pre-check and dropped: POINT is a BY-VALUE FFI argument and LuaJIT refuses
--     it here ('struct cannot be indexed with number'), so the ownership proof
--     comes from what actually happens instead -- if the press does not enter the
--     drag state, the candidate is rejected and the sweep moves on.  That is a
--     stronger check than a hit test anyway: it proves the message reached the
--     log, not merely that the point was over the window.
local function aim(fx, fy)
    st.press = { x = st.rect.x + math.floor(st.rect.w * fx),
                 y = st.rect.y + math.floor(st.rect.h * fy) }
    st.drag_y = st.press.y
    local pt = ffi.new("POINT")
    pt.x = st.press.x
    pt.y = st.press.y
    w.user32.ClientToScreen(win.hwnd, pt)
    st.screen = { x = pt.x, y = pt.y }
    -- Bounds only: the point has to be inside this window's own frame rect.
    -- Anything above that (an overlapping window) shows up as a press that
    -- never enters the drag state.
    local rc = ffi.new("RECT")
    w.user32.GetWindowRect(win.hwnd, rc)
    st.frame = { left = rc.left, top = rc.top, right = rc.right, bottom = rc.bottom }
    return pt.x >= rc.left + 4 and pt.x < rc.right - 4 and
           pt.y >= rc.top + 4 and pt.y < rc.bottom - 4
end

local function step()
    st.ticks = st.ticks + 1

    if st.phase == "settle" then
        if not st.raised then
            -- Topmost for the duration of the gesture, for the same reason.
            w.user32.SetWindowPos(win.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_STATIC)
            st.raised = true
        end
        if not win.connected then return end
        local y, max = ib:receive_scroll()
        if y == nil then
            give_up("telemetry exports present",
                    "xcom_imgui_get_receive_scroll missing: rebuild runtime/xcom_imgui.dll")
            return
        end
        local rx, ry, rw, rh = ib:receive_rect()
        if st.ticks > SETTLE_TIMEOUT then
            give_up("scrollable tail reached the bottom",
                    string.format("y=%d max=%d rect=%dx%d after %d ticks",
                                  y, max, rw or 0, rh or 0, st.ticks))
            return
        end
        -- Preconditions, not the assertion: enough rows to scroll well past one
        -- viewport, and the follow pin sits on the tail.  In steady follow both
        -- numbers are captured inside the same frame after Begin clamped Scroll.y to
        -- that frame's range, so y == max is the expected reading.
        if rw and rw > 200 and rh and rh > 120 and max >= MIN_SCROLL_RANGE_PX and y >= max then
            st.rect = { x = rx, y = ry, w = rw, h = rh }
            check("precondition: scrollable tail pinned at the bottom", true,
                  string.format("y=max=%d, log rect %dx%d at %d,%d", y, rw, rh, rx, ry))
            st.phase = "aim"
        end
        return
    end

    if st.phase == "aim" then
        local point = PRESS_POINTS[st.attempt + 1]
        if point == nil then
            give_up("press reached the receive log",
                    string.format("none of the %d candidate points entered a drag:" ..
                                  " something overlaps the log (window rect %d,%d-%d,%d," ..
                                  " last point screen %d,%d)",
                                  st.attempt, st.frame.left, st.frame.top,
                                  st.frame.right, st.frame.bottom,
                                  st.screen.x, st.screen.y))
            return
        end
        st.attempt = st.attempt + 1
        if not aim(point[1], point[2]) then
            give_up("cursor point belongs to this window",
                    string.format("client %d,%d to screen %d,%d is outside the window" ..
                                  " rect %d,%d-%d,%d: the rect export or its space is wrong",
                                  st.press.x, st.press.y, st.screen.x, st.screen.y,
                                  st.frame.left, st.frame.top, st.frame.right,
                                  st.frame.bottom))
            return
        end
        -- Re-assert the z-order immediately before the press: an injected click
        -- follows the cursor hit test, so a window that came over the log in the
        -- meantime would swallow it (that shows up as a candidate that never
        -- enters the drag state).
        w.user32.SetWindowPos(win.hwnd, HWND_TOPMOST, 0, 0, 0, 0, SWP_STATIC)
        w.user32.SetCursorPos(st.screen.x, st.screen.y)
        -- One tick between the move and the press: WM_MOUSEMOVE has to be queued,
        -- dispatched and drawn, or the button goes down while ImGui still believes
        -- the cursor is wherever the last real move left it.
        st.phase = "press"
        return
    end

    if st.phase == "press" then
        w.user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
        st.pressed = true
        local t = telemetry()
        st.press_y, st.drift_px = t.y, 0
        st.engage_ticks = 0
        st.hold_samples, st.hold_dragging = 0, 0
        st.chase_px, st.grew_px, st.sel_bytes = 0, 0, 0
        st.left = HOLD_TICKS
        st.phase = "engage"
        return
    end

    -- The press is an OS message: it has to be queued, dispatched and drawn
    -- before the render loop can know the button is down, and until then the
    -- follow pin legitimately keeps chasing the tail (measured: one or two
    -- frames, a few rows at 8 KiB/s).  Starting the freeze window at the
    -- injection instead charges that queue latency to the feature, which makes
    -- the check flaky; the window starts when the drag is really in flight.
    if st.phase == "engage" then
        local t = telemetry()
        st.drift_px = math.max(st.drift_px, t.y - st.press_y)
        if t.dragging then
            st.y_ref, st.max_ref = t.y, t.max
            st.phase = "hold"
            return
        end
        st.engage_ticks = st.engage_ticks + 1
        if st.engage_ticks > ENGAGE_TIMEOUT then
            press_up()
            st.phase = "aim"    -- this point never reached the log: try the next
        end
        return
    end

    if st.phase == "hold" then
        local t = telemetry()
        st.hold_samples = st.hold_samples + 1
        if t.dragging then st.hold_dragging = st.hold_dragging + 1 end
        st.chase_px = math.max(st.chase_px, t.y - st.y_ref)
        st.grew_px = math.max(st.grew_px, t.max - st.max_ref)
        st.sel_bytes = math.max(st.sel_bytes, t.sel)
        -- Extend the drag but stay inside the viewport: past the last submitted
        -- row the gesture's OWN edge auto-scroll moves the view, and that is user
        -- intent, not the follow pin chasing the stream.
        if st.hold_samples % 6 == 0 then
            st.drag_y = math.min(st.drag_y + ROW_STEP_PX,
                                 st.rect.y + math.floor(st.rect.h * 0.80))
            w.user32.SetCursorPos(st.screen.x, st.screen.y + (st.drag_y - st.press.y))
        end

        st.left = st.left - 1
        if st.left > 0 then return end
        check("drag engaged from the injected press",
              st.hold_dragging == st.hold_samples,
              string.format("dragging in %d/%d held samples after %d ticks of message" ..
                            " latency (%dpx of legitimate tail chasing before the drag" ..
                            " existed), selection %d B",
                            st.hold_dragging, st.hold_samples, st.engage_ticks,
                            st.drift_px, st.sel_bytes))
        check("view frozen while the selection drag was held", st.chase_px == 0,
              string.format("chased %+dpx (y=%d held while the tail grew +%dpx to %d)",
                            st.chase_px, st.y_ref, st.grew_px, t.max))
        check("rows really arrived during the hold", st.grew_px > 0,
              string.format("scroll range grew by %dpx", st.grew_px))
        check("the gesture selected real bytes", st.sel_bytes > 0,
              string.format("%d bytes selected", st.sel_bytes))
        press_up()
        st.parked_y = telemetry().y
        st.release_move_px = 0
        st.left = RELEASE_TICKS
        st.phase = "release"
        return
    end

    if st.phase == "release" then
        local t = telemetry()
        -- Absolute delta: the release frame also catches up the prefix trim the
        -- drag deferred, and a shrinking content height can pull y down.  Either
        -- direction means the view moved under the selection.
        st.release_move_px = math.max(st.release_move_px, math.abs(t.y - st.parked_y))
        st.left = st.left - 1
        if st.left > 0 then return end
        check("drag state cleared on release", not t.dragging,
              (not t.dragging) and "" or "selection_dragging still reports 1")
        check("stayed parked on the selected rows after release",
              st.release_move_px == 0,
              string.format("moved %dpx (y=%d, tail at %d)",
                            st.release_move_px, st.parked_y, t.max))
        st.wheel_left = WHEEL_TICKS
        st.on_tail_after_wheel = false
        st.phase = "wheel"
        return
    end

    if st.phase == "wheel" then
        -- Back to the newest row the way a user does it: the wheel.
        w.user32.mouse_event(MOUSEEVENTF_WHEEL, 0, 0, u32(-WHEEL_NOTCH * 12), 0)
        local t = telemetry()
        if t.y >= t.max then st.on_tail_after_wheel = true end
        st.wheel_left = st.wheel_left - 1
        if st.wheel_left > 0 then return end
        check("wheel back to the tail re-pinned the view", st.on_tail_after_wheel,
              string.format("y=%d max=%d", t.y, t.max))
        st.follow_ref = telemetry().y
        st.follow_px, st.follow_samples, st.follow_pinned = 0, 0, 0
        st.left = FOLLOW_TICKS
        st.phase = "follow"
        return
    end

    if st.phase == "follow" then
        local t = telemetry()
        st.follow_samples = st.follow_samples + 1
        st.follow_px = math.max(st.follow_px, t.y - st.follow_ref)
        if t.y >= t.max then st.follow_pinned = st.follow_pinned + 1 end
        st.left = st.left - 1
        if st.left > 0 then return end
        check("follow re-armed: the view climbs with the stream", st.follow_px > 0,
              string.format("climbed %dpx", st.follow_px))
        -- The tail TARGET (not a concrete pixel) is what closes the re-attach race
        -- documented at the follow pin: a stale pixel loses it about a third of the
        -- time, so a healthy follow sits on the tail in essentially every sample.
        check("follow stayed on the tail",
              st.follow_samples > 0 and st.follow_pinned / st.follow_samples >= 0.7,
              string.format("on the tail in %d/%d samples",
                            st.follow_pinned, st.follow_samples))
        finish()
        return
    end
end

-- jit.off: entered from an FFI timer callback, the same rule the other timers in
-- this directory follow.
jit.off(step, true)

local function guarded()
    local ok_step, err = pcall(step)
    if not ok_step then
        give_up("driver ran to completion", tostring(err))
    end
end
jit.off(guarded, true)

timer = uv.new_timer()
timer:start(500, TICK_MS, guarded)

return win:run()
