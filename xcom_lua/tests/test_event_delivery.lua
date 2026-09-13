-- Device-change SAFE POINTS: the branches ui/test_port_enum.lua cannot reach.
--
-- test_port_enum.lua always installs a _device_change_timer and REPLACES
-- _refresh_ports_after_change with a counter, so two real branches stay
-- uncovered there:
--   (a) the fallback taken when no timer exists  (window.lua:946-950)
--   (b) the real bail inside _refresh_ports_after_change when a session is
--       live -- the rule that a device change must never disturb an open port
-- This file pins exactly those, plus the invariant that the WndProc itself
-- never enumerates.
--
-- Design: docs/design-event-delivery.md (R2, R4).
-- Usage: cd xcom_lua && luajit tests/test_event_delivery.lua

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

local fake_now = 1000000
local uv_run_calls = 0
local uv_stub = {
    now = function() return fake_now end,
    run = function() uv_run_calls = uv_run_calls + 1 end,
    backend_timeout = function() return 100 end,
}
package.preload["luv"] = function() return uv_stub end
require("luv")

local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

-- Enumeration is the device I/O we must be able to count.
local enum_calls = 0
local ENUM_RESULT = { { name = "COM3", description = "USB Serial" } }
local xcom_stub = {
    ok = 0, err_busy = 4,
    port_closed = 0, port_opening = 1, port_open = 2,
    port_closing = 3, port_fault = 4,
    port_text = {},
    list_ports = function() enum_calls = enum_calls + 1; return ENUM_RESULT, nil end,
    close = function() return 0 end,
    open_async = function() return 0 end,
    take_open_result = function() return 0 end,
}
setmetatable(xcom_stub, {
    __index = function() return function() return 0 end end,
})
package.preload["xcom_ffi"] = function() return xcom_stub end

local window_mod = require("window")
local view_model = require("view_model")

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

-- The gate only reads ui_state().super_state and recovering(), so a two-method
-- stub pins the RULE without depending on view_model's transition API.
local function vm_stub(super_state, recovering)
    return {
        ui_state = function() return { super_state = super_state } end,
        recovering = function() return recovering end,
    }
end

local OFFLINE = view_model.SUPER_OFFLINE

local function new_win(super_state, recovering)
    local cfg = {
        window = { x = 0, y = 0, w = 920, h = 650 },
        port = "COM3", baud_rate = 115200, data_bits = 8, stop_bits = 0,
        parity = 0, flow_control = 0, dtr_enable = false, rts_enable = false,
        receive_hex = false, timestamp = false, pause_display = false,
        auto_clear_bytes = 0, max_display_bytes = 2 * 1024 * 1024,
        auto_save = false, save_path = "", always_on_top = false,
        send_hex = false, send_crlf = false, autosend_period_ms = 0,
        quick_pages = { { text = {}, enabled = {} } },
        quick = { text = {}, enabled = {} },
        script_enabled = {}, script_auto_reload = false,
        script_autorun_console = false, baud_custom = 0, multi_gap_ms = 100,
        charset = "ASCII", frame_gap_ms = 0, tx_echo = false,
    }
    local win = window_mod.new(cfg, { [""] = {} }, "_test.ini")
    win.conn = nil
    win.core = true
    win.vm = vm_stub(super_state, recovering)
    win.request_frame = function() end
    win._device_change_timer = nil            -- force the fallback branch
    win._device_change_timer_callback = nil
    enum_calls = 0
    return win
end

-- ===========================================================================
-- A) No timer available: the change must still be serviced -- deferred to the
--    pump, and NOT enumerated inside the WndProc
-- ===========================================================================
do
    local win = new_win(OFFLINE, false)
    local applied = 0
    win._apply_ports = function() applied = applied + 1 end

    win:_on_device_nodes_changed()
    eq("A1 the WndProc did not enumerate", enum_calls, 0)
    eq("A2 nothing applied yet either", applied, 0)

    ok("A3 a pump is available", type(win._pump_events) == "function")
    if type(win._pump_events) == "function" then
        win:_pump_events()
        eq("A4 the deferred refresh enumerated once", enum_calls, 1)
        eq("A5 ...and applied the result once", applied, 1)
    end
end

-- ===========================================================================
-- B) The fallback is COALESCED by the same gate as the timer path: a burst
--    yields one refresh, and a later burst yields exactly one more
-- ===========================================================================
do
    local win = new_win(OFFLINE, false)
    local applied = 0
    win._apply_ports = function() applied = applied + 1 end

    win:_on_device_nodes_changed()
    win:_on_device_nodes_changed()
    win:_on_device_nodes_changed()
    win:_pump_events()
    eq("B1 a burst with no timer refreshes once", applied, 1)

    -- Past the debounce window a new burst must be accepted again.  Read the
    -- constant off the INSTANCE: require("window") returns the module table M,
    -- not the Window class, so window_mod.DEVICE_CHANGE_DEBOUNCE_MS is nil.
    fake_now = fake_now + win.DEVICE_CHANGE_DEBOUNCE_MS + 1
    win:_on_device_nodes_changed()
    win:_pump_events()
    eq("B2 the next burst refreshes again", applied, 2)
end

-- ===========================================================================
-- C) A LIVE session must not be disturbed -- the rule behind
--    "不要影响正常的打开关闭操作"
-- ===========================================================================
do
    local win = new_win("online", false)
    local applied = 0
    win._apply_ports = function() applied = applied + 1 end

    win:_refresh_ports_after_change()
    eq("C1 live session: no enumeration", enum_calls, 0)
    eq("C2 live session: list untouched", applied, 0)

    -- Mid-transition (opening/closing/reconnecting) is not OFFLINE either.
    win.vm = vm_stub("transitional", false)
    win:_refresh_ports_after_change()
    eq("C3 transitional: no enumeration", enum_calls, 0)

    -- Recovering counts as busy even while it reports offline.
    win.vm = vm_stub(OFFLINE, true)
    win:_refresh_ports_after_change()
    eq("C4 recovering: no enumeration", enum_calls, 0)

    -- Idle again: the refresh must actually happen, or the list never updates.
    win.vm = vm_stub(OFFLINE, false)
    win:_refresh_ports_after_change()
    eq("C5 idle: enumeration happens", enum_calls, 1)
    eq("C6 idle: result applied", applied, 1)
end

-- ===========================================================================
-- D) A live session must not be disturbed through the WNDPROC path either
-- ===========================================================================
do
    local win = new_win("online", false)
    local applied = 0
    win._apply_ports = function() applied = applied + 1 end

    win:_on_device_nodes_changed()
    win:_pump_events()
    eq("D1 live session survives a device-change burst", enum_calls, 0)
    eq("D2 ...with the list untouched", applied, 0)
end

print(string.format("test_event_delivery: %d passed, %d failed",
                    pass_n, fail_n))
if fail_n > 0 then os.exit(1) end
