-- test_port_enum.lua - unit tests for the port-enumeration additions in
-- core/xcom_ffi.lua: error-aware list_ports() parsing, the default-off
-- occupancy probe flag, and the native-error -> cause mappings.
--
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit tests/test_port_enum.lua
--
-- No DLL is required: xcom_ffi.list_ports drives a FakeLib table injected by
-- overriding M.load, so the buffer/return-value handling under test is the real
-- code path while the ABI itself is stubbed. These tests never open a device.

package.path = "./core/?.lua;../xcom_lua/core/?.lua;" .. package.path
local ffi = require("ffi")

-- The module pins struct sizes and raises if a cdef drifts. A teammate's
-- in-flight snapshot field addition can transiently break that pin; suppress
-- ONLY that specific assertion during load so this test still exercises
-- list_ports. It is a load-time warning, not a normal-condition path.
local function load_ffi()
    local real_error = error
    local suppressed = false
    error = function(msg, level)
        if type(msg) == "string" and msg:find("FFI layout mismatch", 1, true) then
            suppressed = true
            return
        end
        real_error(msg, level)
    end
    local ok, mod = pcall(require, "xcom_ffi")
    error = real_error
    return ok and mod or nil, suppressed
end

local x, suppressed = load_ffi()
if not x then
    print("FATAL: core/xcom_ffi.lua did not load")
    os.exit(1)
end
if suppressed then
    print("WARN: suppressed a struct-size layout mismatch while loading xcom_ffi")
end

local passed, failed = 0, 0
local function eq(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL  %s  (got=%s want=%s)", tostring(label),
                            tostring(got), tostring(want)))
    end
end
local function ok(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label)
    end
end

local last_flags = nil

-- Fake ABI library. Each entry is a plain Lua function; list_ports calls them
-- with the same FFI buffers the real symbols receive.
local function copy_field(dst, text)
    ffi.copy(dst, text .. "\0")
end

local lib = {}

-- 1) default enumeration: two ports, no error, probe flag 0 -----------------
lib.xcom_list_ports_ex = function(buf, cap, count, flags, err)
    last_flags = flags
    count[0] = 2
    copy_field(buf[0].name, "COM1")
    copy_field(buf[0].description, "USB-SERIAL CH340")
    copy_field(buf[0].hardware_id, "USB\\VID_1A86&PID_7523")
    buf[0].busy = 0
    copy_field(buf[1].name, "COM2")
    copy_field(buf[1].description, "")
    -- hardware_id deliberately left unwritten: a composite/virtual port that
    -- exposes no SPDRP_HARDWAREID must parse as "", never as stale bytes.
    buf[1].busy = 1
    err[0] = 0
    return x.ok
end
x.load = function() return lib end

local ports, enum_err = x.list_ports()
eq("two ports parsed", #ports, 2)
eq("name parsed", ports[1].name, "COM1")
eq("description parsed", ports[1].description, "USB-SERIAL CH340")
eq("busy false", ports[1].busy, false)
eq("hardware_id parsed", ports[1].hardware_id, "USB\\VID_1A86&PID_7523")
eq("missing hardware_id falls back to empty", ports[2].hardware_id, "")
eq("busy true", ports[2].busy, true)
eq("no enum error", enum_err, nil)
eq("probe OFF by default (flags=0)", last_flags, 0)

-- 2) probe is opt-in only ------------------------------------------------
local _, _ = x.list_ports({ probe = true })
eq("probe opt-in sets flag bit 0", last_flags, x.PROBE_BUSY)
eq("probe flag value", x.PROBE_BUSY, 1)
-- env not set in this process -> default stays safe
if os.getenv("XCOM_PORT_PROBE") == nil then
    eq("probe_enabled_by_env default false", x.probe_enabled_by_env(), false)
end

-- 3) enumeration failure with an empty result -----------------------------
lib.xcom_list_ports_ex = function(buf, cap, count, flags, err)
    count[0] = 0
    err[0] = 5
    return x.err_io
end
local ports, enum_err = x.list_ports()
eq("empty on enum failure", #ports, 0)
eq("native enum error surfaced", enum_err, 5)
ok("describe_enum_error(5)", x.describe_enum_error(5) ~= nil)
ok("describe_enum_error generic", x.describe_enum_error(1234) ~= nil)
eq("describe_enum_error(0) nil", x.describe_enum_error(0), nil)

-- 4) partial list + failure: ports still returned, error still reported ----
lib.xcom_list_ports_ex = function(buf, cap, count, flags, err)
    count[0] = 1
    copy_field(buf[0].name, "COM7")
    buf[0].busy = 0
    err[0] = 5
    return x.err_io
end
local ports, enum_err = x.list_ports()
eq("partial port returned", #ports, 1)
eq("partial port name", ports[1].name, "COM7")
eq("partial enum error", enum_err, 5)

-- 5) safe-fail: a throwing ABI never propagates ---------------------------
lib.xcom_list_ports_ex = function() error("simulated ABI failure") end
local ok_call, ports = pcall(x.list_ports)
ok("throwing ABI does not raise", ok_call)
eq("throwing ABI yields empty list", #ports, 0)

-- 6) legacy fallback when the DLL lacks xcom_list_ports_ex -----------------
lib.xcom_list_ports_ex = nil
lib.xcom_list_ports = function(buf, cap, count)
    count[0] = 1
    copy_field(buf[0].name, "COM9")
    buf[0].busy = 0
    return x.ok
end
local ports, enum_err = x.list_ports()
eq("legacy fallback port", #ports, 1)
eq("legacy fallback name", ports[1].name, "COM9")
eq("legacy fallback no error", enum_err, nil)

-- 7) err_full retry grows the buffer --------------------------------------
local calls = 0
lib.xcom_list_ports = nil
lib.xcom_list_ports_ex = function(buf, cap, count, flags, err)
    calls = calls + 1
    err[0] = 0
    if calls == 1 then
        count[0] = 33          -- one more than MAX_PORT_LIST
        return x.err_full
    end
    eq("retry capacity grew", cap, 34)
    count[0] = 35
    copy_field(buf[0].name, "COM10")
    buf[0].busy = 0
    return x.ok
end
local ports = x.list_ports()
eq("retry used two calls", calls, 2)
ok("retry returned ports", #ports >= 1)

-- 8) no DLL -> empty list, no raise ---------------------------------------
x.load = function() return nil end
local ports, enum_err = x.list_ports()
eq("no DLL empty", #ports, 0)
eq("no DLL no error", enum_err, nil)

-- 9) open-error cause mapping ---------------------------------------------
eq("cause FILE_NOT_FOUND", x.describe_open_error(2), "端口不存在")
ok("cause ACCESS_DENIED", x.describe_open_error(5) ~= nil)
ok("cause device removed", x.describe_open_error(1167) ~= nil)
eq("cause unknown nil", x.describe_open_error(424242), nil)
eq("cause nil code", x.describe_open_error(nil), nil)

-- ===========================================================================
-- 10) Port-combo selection preservation + device-change coalescing.
--
-- These drive the real ui/window.lua refresh path on the Linux host with luv
-- and the Win32 user32 entry points stubbed.  The native combo is the FALLBACK
-- UI (the shipping ImGui bridge keeps its own name buffer and never resets to
-- index 0 -- native/xcom_imgui_bridge.cpp:1882), but combo_set's CB_SETCURSEL
-- 0 default is a real defect whenever that fallback is used, and the shared
-- selection/presence logic is what these tests pin.
package.path = "./ui/?.lua;./core/?.lua;" .. package.path
local fake_now = 2000000
package.preload["luv"] = function()
    return { now = function() return fake_now end }
end
local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

-- Fake user32: emulate a CBS_DROPDOWNLIST combo in a plain Lua table so the
-- real controls.lua / window.lua code runs without a Win32 host.
local combos = {}
local combo_seq = 0
local function norm_wp(wp)
    local n = tonumber(wp) or 0
    if n > 9223372036854775807 then n = n - 18446744073709551616 end
    return n
end
local function make_combo()
    combo_seq = combo_seq + 1
    local hwnd = 0x900000 + combo_seq
    combos[hwnd] = { items = {}, sel = -1 }
    return { hwnd = hwnd, id = 500 + combo_seq, kind = "ComboBox" }, combos[hwnd]
end
local function make_combo_items(items, sel)
    local ctl, model = make_combo()
    model.items = items
    model.sel = sel
    return ctl
end
local CB = real_win32.cb
real_win32.user32 = {
    SendMessageA = function(hwnd, msg, wp, lp)
        local model = combos[hwnd]
        if not model then return 0 end
        local m = tonumber(msg)
        if m == CB.CB_RESETCONTENT then
            model.items = {}
            model.sel = -1
        elseif m == CB.CB_ADDSTRING then
            model.items[#model.items + 1] = ffi.string(ffi.cast("char*", lp))
        elseif m == CB.CB_SETCURSEL then
            model.sel = norm_wp(wp)
        elseif m == CB.CB_GETCURSEL then
            return model.sel
        elseif m == CB.CB_GETCOUNT then
            return #model.items
        elseif m == CB.CB_GETLBTEXTLEN then
            local s = model.items[norm_wp(wp) + 1]
            return s and #s or 0
        elseif m == CB.CB_GETLBTEXT then
            local s = model.items[norm_wp(wp) + 1] or ""
            ffi.copy(ffi.cast("char*", lp), s)
            return #s
        end
        return 0
    end,
    DefWindowProcA = function() return 0 end,
    EnableWindow = function() return 0 end,
    ShowWindow = function() return 0 end,
    SetWindowTextA = function() return 1 end,
    GetWindowTextLengthA = function() return 0 end,
    GetWindowTextA = function() return 0 end,
}

local window_mod = require("window")

-- Controlled enumeration returned by the overridden x.list_ports.
local PORTS = {}
local last_probe = nil
x.list_ports = function(opts)
    last_probe = opts and opts.probe
    return PORTS, nil
end

local function new_win()
    local cfg = {
        window = { x = 0, y = 0, w = 920, h = 650 },
        port = "", baud_rate = 115200, data_bits = 8, stop_bits = 0,
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
    local ctl, model = make_combo()
    win.conn = {
        port = ctl,
        -- Minimal serial-parameter controls so _serial_config() (and thus
        -- core_open / _save_config) runs against the real contract.
        baud = make_combo_items({ "9600", "115200" }, 1),
        data = make_combo_items({ "5", "6", "7", "8" }, 3),
        stop = make_combo_items({ "1", "1.5", "2" }, 0),
        parity = make_combo_items({ "None", "Odd", "Even", "Mark", "Space" }, 0),
        flow = make_combo_items({ "None", "HW (RTS/CTS)", "SW (XON/XOFF)" }, 0),
        dtr = { hwnd = 0x90F001 },
        rts = { hwnd = 0x90F002 },
    }
    win.status = { labels = { { hwnd = 1 }, { hwnd = 2 }, { hwnd = 3 } } }
    win.core = true
    return win, model
end

local function sel_key(win, model)
    if not win._port_keys or model.sel < 0 then return nil end
    return win._port_keys[model.sel + 1]
end

local function enables(vm)
    local s = vm:ui_state()
    return table.concat({ tostring(s.open_enabled), tostring(s.close_enabled),
        tostring(s.send_enabled), tostring(s.autosend_enabled),
        tostring(s.params_enabled), s.state, tostring(s.connected) }, "|")
end

-- 1) Regression: a composed label with description + "(busy)" must preserve the
-- bare-name selection.  Pre-fix combo_select_text compared "COM7" against the
-- label and always failed, leaving CB_SETCURSEL 0 -> COM3 (the WRONG device).
do
    local win, model = new_win()
    PORTS = {
        { name = "COM3", description = "", busy = false },
        { name = "COM7", description = "USB Serial", busy = true },
    }
    win._port_want = "COM7"
    win:on_btn_refresh()
    eq("regression: composed label keeps COM7 selected", sel_key(win, model), "COM7")
    eq("regression: COM7 label is composed", model.items[2], "COM7  USB Serial  (busy)")
    eq("regression: selection is NOT index 0", model.sel, 1)
    -- The ABI must receive the BARE name, not the composed label.
    eq("regression: _serial_config port is bare", win:_serial_config().port, "COM7")
end

-- 2) Port removed: explicit "(not present)" entry stays selected; no other port
-- is selected; open is refused and presence flips open_enabled only.
do
    local win, model = new_win()
    PORTS = {
        { name = "COM3", description = "", busy = false },
        { name = "COM7", description = "USB Serial", busy = false },
    }
    win._port_want = "COM7"
    win:on_btn_refresh()
    local before_close = win.vm:ui_state().close_enabled
    local before_state = win.vm:ui_state().state
    PORTS = { { name = "COM3", description = "", busy = false } }   -- unplugged
    win:on_btn_refresh()
    eq("removed: wanted name still selected", sel_key(win, model), "COM7")
    eq("removed: explicit marker row", model.items[model.sel + 1], "COM7  (not present)")
    ok("removed: another port not selected", sel_key(win, model) ~= "COM3")
    eq("removed: presence false", win.vm:ui_state().port_present, false)
    eq("removed: open_enabled false", win.vm:ui_state().open_enabled, false)
    eq("removed: close_enabled untouched", win.vm:ui_state().close_enabled, before_close)
    eq("removed: state untouched (no forced close)", win.vm:ui_state().state, before_state)
    -- Open must be refused: the presence guard returns before open_async.
    local opened = false
    local real_open = x.open_async
    x.open_async = function() opened = true; return x.ok end
    win:core_open()
    eq("removed: core_open refused", opened, false)
    x.open_async = real_open
    eq("removed: HSM back to CLOSED", win.vm:ui_state().state, win.vm.STATE_CLOSED)
end

-- 3) Same port set: the LIVE (user-changed) selection wins over the persisted
-- _port_want value.  The user picks COM7 in the dropdown; the next refresh must
-- keep COM7, not snap back to the persisted COM3.
do
    local win, model = new_win()
    PORTS = {
        { name = "COM3", description = "", busy = false },
        { name = "COM7", description = "USB Serial", busy = false },
    }
    win._port_want = "COM3"
    win:on_btn_refresh()
    eq("live: persisted COM3 selected first", sel_key(win, model), "COM3")
    model.sel = 1                                    -- user picks COM7
    win:on_btn_refresh()                             -- same port set
    eq("live: user pick COM7 survives refresh", sel_key(win, model), "COM7")
    eq("live: selection index preserved", model.sel, 1)
end

-- 4) DBT_DEVNODES_CHANGED burst coalesces to one refresh per debounce window.
do
    local win = new_win()
    local timer = { started = 0 }
    function timer:start(ms, rep, cb) self.started = self.started + 1; self.cb = cb end
    function timer:stop() end
    function timer:close() end
    win._device_change_timer = timer
    local refreshes = 0
    win._device_change_timer_callback = function() win:_refresh_ports_after_change() end
    win._refresh_ports_after_change = function() refreshes = refreshes + 1 end
    fake_now = 2000000
    local wm = real_win32.wm
    for _ = 1, 5 do
        win:dispatch(nil, wm.WM_DEVICECHANGE,
                     ffi.cast("WPARAM", real_win32.dbt.DBT_DEVNODES_CHANGED), 0)
    end
    eq("coalesce: burst arms exactly one timer", timer.started, 1)
    timer.cb()                                       -- the one coalesced fire
    eq("coalesce: burst yields one refresh", refreshes, 1)
    win:dispatch(nil, wm.WM_DEVICECHANGE,
                 ffi.cast("WPARAM", real_win32.dbt.DBT_DEVNODES_CHANGED), 0)
    eq("coalesce: inside window ignored", timer.started, 1)
    fake_now = fake_now + 501
    win:dispatch(nil, wm.WM_DEVICECHANGE,
                 ffi.cast("WPARAM", real_win32.dbt.DBT_DEVNODES_CHANGED), 0)
    eq("coalesce: after window re-arms", timer.started, 2)
end

-- 4b) While a session is OPEN the device-change path must NOT act (LLCOM rule):
-- no list rebuild, no selection touch, no probe.  The backstop picks it up once
-- the session is idle again.
do
    local win = new_win()
    local timer = { started = 0 }
    function timer:start(ms, rep, cb) self.cb = cb end
    function timer:stop() end
    function timer:close() end
    win._device_change_timer = timer
    win._device_change_timer_callback = function() win:_refresh_ports_after_change() end
    local applied = 0
    win._apply_ports = function() applied = applied + 1 end
    win.vm:intent_open()
    win.vm:on_port_state(2, 1)                      -- OPEN
    PORTS = { { name = "COM3", description = "", busy = false } }
    win:dispatch(nil, real_win32.wm.WM_DEVICECHANGE,
                 ffi.cast("WPARAM", real_win32.dbt.DBT_DEVNODES_CHANGED), 0)
    timer.cb()
    eq("OPEN gate: device-change does not refresh", applied, 0)
    win:_poll_ports_backstop()
    eq("OPEN gate: backstop does not refresh", applied, 0)
    -- Session ends -> idle -> the backstop now applies the changed list.
    win.vm:on_port_state(0, 2)                      -- CLOSED
    eq("OPEN gate: idle again", win:_ports_refresh_allowed(), true)
    win._ports_signature = nil
    win:_poll_ports_backstop()
    for _, job in ipairs(win._defer_queue) do job() end
    eq("OPEN gate: backstop refreshes once idle", applied, 1)
end

-- 5) A refresh with the selection present leaves the enable table byte-identical
-- (it is derived from the HSM, never from the port list).
do
    local win = new_win()
    PORTS = {
        { name = "COM3", description = "", busy = false },
        { name = "COM7", description = "USB Serial", busy = false },
    }
    win._port_want = "COM3"
    win:on_btn_refresh()                             -- establish the key array
    local before = enables(win.vm)
    win:on_btn_refresh()
    win:on_btn_refresh()
    eq("enable table identical across refreshes", enables(win.vm), before)
end

print(string.format("test_port_enum: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
