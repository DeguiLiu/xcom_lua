--[[--------------------------------------------------------------------------
core/xcom_ffi.lua - LuaJIT FFI binding for xcom_core.dll (xcom.h v1.6 ABI).

This module ONLY declares the C ABI and loads the DLL.  It is not callable on
Linux (no xcom_core.dll); use `luajit -bl` for syntax checking and review the
struct layouts against xcom_core/include/xcom/xcom.h on a Windows checkout.

The C ABI is the authoritative cross-language contract between the C++17 core
and every client front-end.  Struct layouts are fixed (explicit _pad fields,
MSVC x64 natural alignment).  LuaJIT FFI applies the same C alignment rules, so
declaring the fields in the same order reproduces the layout exactly.

Concurrency: only the caller thread may enter the ABI.  This client is
single-threaded (Win32 message-loop thread), so all calls are serialised by
construction; no synchronisation is needed here.

Follows the OpenResty/LuaJIT module convention: local-first, self-contained,
returns a table.  Pure declaration + load; each helper keeps a none-shared
local ffi handle.
------------------------------------------------------------------------]]--

local ffi = require("ffi")

local M = {}

-- All of xcom.h's C types in one cdef block.  `XcomPortConfig.port` is a
-- borrowed const char* for the call; the FFI caller must keep the buffer alive
-- for the duration of the call only.
ffi.cdef[[
typedef int32_t XcomStatus;

typedef struct XcomCreateOptions {
    uint32_t struct_size;
    uint32_t flags;
} XcomCreateOptions;

typedef struct XcomPortConfig {
    uint32_t struct_size;
    const char* port;
    uint32_t baud_rate;
    uint8_t data_bits;
    uint8_t stop_bits;
    uint8_t parity;
    uint8_t flow_control;
    uint8_t dtr_enable;
    uint8_t rts_enable;
    uint8_t _pad[2];
} XcomPortConfig;

typedef struct XcomDisplayOptions {
    uint32_t struct_size;
    uint8_t hex_view;
    uint8_t timestamp;
    uint8_t pause_display;
    uint8_t _pad0;
    uint32_t auto_clear_bytes;
    uint32_t max_display_bytes;
} XcomDisplayOptions;

typedef struct XcomSnapshot {
    uint32_t struct_size;
    uint32_t rx_bytes;
    uint32_t tx_bytes;
    uint32_t rx_pool_exhausted_bytes;
    uint32_t tx_rejected;
    uint32_t auto_tick_coalesced;
    uint32_t ui_trimmed_bytes;
    uint32_t save_rejected_bytes;
    uint32_t display_paused_bytes;
    uint32_t callback_count;
    uint32_t generation;
    uint32_t display_pending;
    uint16_t port_state;
    uint8_t _pad[2];
    /* v1.5 ClearCommError line-error counters (appended; must match xcom.h) */
    uint32_t framing_errors;
    uint32_t parity_errors;
    uint32_t overrun_errors;
    uint32_t break_events;
    /* v1.5 loss observability (appended; must match xcom.h) */
    uint32_t rx_sequence;
    uint32_t rx_loss_offset;
    uint32_t rx_backpressure_events;
    /* v1.6 flow-control stall counter (appended; must match xcom.h) */
    uint32_t flow_hold_events;
} XcomSnapshot;

typedef struct XcomError {
    uint32_t struct_size;
    int32_t code;
    uint16_t source;
    uint16_t _pad;
    char message[256];
} XcomError;

typedef struct XcomPortInfo {
    char name[64];
    char description[256];
    uint8_t busy;
    uint8_t _pad[3];
    /* v1.6 stable PnP hardware id (SPDRP_HARDWAREID first string), or "" for a
       port that exposes none. Appended after _pad; must match xcom.h. */
    char hardware_id[96];
} XcomPortInfo;

uint32_t xcom_version(void);
XcomStatus xcom_list_ports(XcomPortInfo* out, uint32_t capacity, uint32_t* count);
XcomStatus xcom_list_ports_ex(XcomPortInfo* out, uint32_t capacity, uint32_t* count,
                              uint32_t flags, int32_t* error);
void* xcom_create(const XcomCreateOptions* options);
XcomStatus xcom_open(void* h, const XcomPortConfig* config);
XcomStatus xcom_open_async(void* h, const XcomPortConfig* config);
XcomStatus xcom_take_open_result(void* h);
XcomStatus xcom_close(void* h, uint32_t timeout_ms);
XcomStatus xcom_send(void* h, const uint8_t* data, uint32_t size, uint32_t flags);
XcomStatus xcom_set_options(void* h, const XcomDisplayOptions* options);
XcomStatus xcom_set_lines(void* h, uint8_t dtr, uint8_t rts);
XcomStatus xcom_set_auto_template(void* h, const uint8_t* data, uint32_t size,
                                  uint32_t interval_ms, uint32_t flags);
XcomStatus xcom_drain_display(void* h, char* output, uint32_t capacity,
                              uint32_t* written);
/* Same batch semantics as xcom_drain_display, but returns the byte count
   directly and back-fills the batch's EARLIEST ingress time (monotonic ms)
   through out_ingress_ms.  Declared so a newer xcom_core.dll is usable; the
   accessor probes for the symbol at call time (an older DLL lacks it) and
   falls back to the legacy drain. */
uint32_t xcom_drain_display_ts(void* h, char* output, uint32_t capacity,
                               uint32_t* out_ingress_ms);
XcomStatus xcom_get_snapshot(void* h, XcomSnapshot* output);
XcomStatus xcom_take_error(void* h, XcomError* output);
XcomStatus xcom_log_open(void* h, const char* utf8_path, uint8_t append);
XcomStatus xcom_log_append(void* h, const uint8_t* data, uint32_t size);
XcomStatus xcom_log_flush(void* h, uint32_t timeout_ms);
XcomStatus xcom_log_close(void* h, uint32_t timeout_ms);
XcomStatus xcom_test_inject_rx(void* h, const uint8_t* data, uint32_t size);
void xcom_destroy(void* h);
]]

-- ABI constants mirrored from xcom.h (must match the C enum values).
M.ok = 0
M.err_param = -1
M.err_not_open = -2
M.err_already_open = -3
M.err_busy = -4
M.err_full = -5
M.err_io = -6
M.err_timeout = -7
M.err_drain_incomplete = -8
M.err_unsupported = -9

M.send_text = 0
M.send_hex = 1
M.send_crlf = 2

M.port_closed = 0
M.port_opening = 1
M.port_open = 2
M.port_closing = 3
M.port_fault = 4

-- Human-readable labels for the port state, matching Python's XCOM_PORT_TEXT
-- (services/core_wrapper.py) exactly, including case.
M.port_text = {
    [0] = "Closed",
    [1] = "Opening",
    [2] = "Open",
    [3] = "Closing",
    [4] = "Fault",
}

-- xcom_list_ports_ex flags (mirror xcom.h XCOM_LIST_PORTS_PROBE_BUSY).
M.PROBE_BUSY = 1

-- Native Win32 error -> Chinese cause, for the open-failure status line. The
-- core pushes the raw Win32 code from CreateFileW/SetCommState into its error
-- ring, so a bare "io error" can be turned into a cause the user can act on.
-- Windows folds "in use" and "permission denied" into ERROR_ACCESS_DENIED (5),
-- so those two cannot be told apart from the code alone.
M.open_error_causes = {
    [2]    = "端口不存在",
    [3]    = "端口不存在",
    [5]    = "端口被其他程序占用或权限不足",
    [31]   = "设备无响应或已断开",
    [32]   = "端口被其他程序占用",
    [110]  = "端口打开失败（可能被占用）",
    [121]  = "设备无响应（操作超时）",
    [995]  = "操作已取消",
    [1167] = "设备已拔出",
    [1168] = "找不到设备",
}

-- Native enumeration status -> Chinese cause (RegOpenKeyExA LSTATUS).
M.enum_error_causes = {
    [5]  = "无法读取串口列表：访问被拒绝",
    [87] = "串口列表读取失败：参数无效",
}

-- describe_open_error(code) -> cause string or nil. Never raises: a nil or
-- unknown code simply yields nil so the caller falls back to the raw message.
function M.describe_open_error(code)
    local n = tonumber(code)
    if not n then
        return nil
    end
    return M.open_error_causes[n]
end

-- describe_enum_error(code) -> human string. Always returns something for a
-- non-zero code so the UI never shows a bare number.
function M.describe_enum_error(code)
    local n = tonumber(code)
    if not n or n == 0 then
        return nil
    end
    return M.enum_error_causes[n] or string.format("串口枚举失败（错误码 %d）", n)
end

-- Active occupancy probing opens every enumerated port, which can drive DTR
-- and reset an auto-reset target board. It is therefore OFF unless the caller
-- explicitly opts in (opts.probe == true) or sets XCOM_PORT_PROBE=1.
function M.probe_enabled_by_env()
    local v = os.getenv("XCOM_PORT_PROBE")
    if not v or v == "" then
        return false
    end
    v = v:lower()
    return v == "1" or v == "true" or v == "on" or v == "yes"
end

-- ABI version this binding is built against.  Keep in step with xcom.h's
-- XCOM_VERSION_MAJOR/MINOR/PATCH: the cdef below already declares the v1.6
-- fields and the size pins assert the v1.6 layout, so a stale value here would
-- make any future capability gate under-report the loaded DLL.
M.version_major = 1
M.version_minor = 6
M.version_patch = 0

-- VERSION: (major << 16) | (minor << 8) | patch, as returned by xcom_version().
function M.packed_version()
    return (M.version_major * 65536) + (M.version_minor * 256) + M.version_patch
end

--[[-------------------------------------------------------------------------
load() -> ffi handle or nil
Load xcom_core.dll, honouring the XCOM_CORE_DLL environment variable override.
Returns nil (does not raise) when the DLL cannot be resolved, so the caller can
show a friendly failure instead of crashing.
------------------------------------------------------------------------]]--
local function find_dll()
    local env = os.getenv("XCOM_CORE_DLL")
    if env and env ~= "" then
        return env
    end
    -- Script-relative default: <dir>/../build/native-release/bin/xcom_core.dll
    local script_dir = debug.getinfo(1, "S").source
    if script_dir and script_dir:sub(1, 1) == "@" then
        script_dir = script_dir:sub(2)
        script_dir = script_dir:gsub("[^\\/]$", function() return script_dir end)
        script_dir = script_dir:match("^(.*)[\\/][^\\/]*$") or script_dir
    end
    if script_dir then
        local candidate = script_dir .. "/../build/native-release/bin/xcom_core.dll"
        local runtime_candidate = script_dir .. "/../runtime/xcom_core.dll"
        local file = io.open(runtime_candidate, "rb")
        if file then
            file:close()
            return runtime_candidate
        end
        return candidate
    end
    return "xcom_core.dll"
end

local lib
local loaded = false
local display_scratch
local display_written
local display_ingress
function M.load()
    if loaded then
        return lib
    end
    local path = find_dll()
    local ok, handle = pcall(ffi.load, path)
    if not ok then
        -- Fall back to plain DLL name (Windows search path).
        local ok2, handle2 = pcall(ffi.load, "xcom_core.dll")
        if not ok2 then
            lib = nil
            loaded = true -- remember failure to avoid repeating cost-free
            return nil
        end
        lib = handle2
    else
        lib = handle
    end
    loaded = true
    return lib
end

-- Binding value or accessor; each getter reads the shared lib lazily so the
-- module may be `require`d on Linux without a DLL present (returns nil).
local function f(t)
    return function(...)
        local l = M.load()
        if not l then
            error("xcom_core.dll not loaded", 2)
        end
        return l[t](...)
    end
end

M.version = f("xcom_version")
M.list_ports_c = f("xcom_list_ports")
M.create_c = f("xcom_create")
M.open_c = f("xcom_open")
M.open_async_c = f("xcom_open_async")
M.take_open_result_c = f("xcom_take_open_result")
M.close_c = f("xcom_close")
M.send_c = f("xcom_send")
M.set_options_c = f("xcom_set_options")
M.set_auto_template_c = f("xcom_set_auto_template")
M.drain_display_c = f("xcom_drain_display")
M.get_snapshot_c = f("xcom_get_snapshot")
M.take_error_c = f("xcom_take_error")
M.log_open_c = f("xcom_log_open")
M.log_append_c = f("xcom_log_append")
M.log_flush_c = f("xcom_log_flush")
M.log_close_c = f("xcom_log_close")
M.test_inject_rx_c = f("xcom_test_inject_rx")
M.destroy_c = f("xcom_destroy")

-- Type constructors (not exposed as `f` above; these build C structs).
local tc = {}
tc.create_options = ffi.typeof("XcomCreateOptions")
tc.port_config = ffi.typeof("XcomPortConfig")
tc.display_options = ffi.typeof("XcomDisplayOptions")
tc.snapshot = ffi.typeof("XcomSnapshot")
tc.error = ffi.typeof("XcomError")
tc.port_info = ffi.typeof("XcomPortInfo")
M.typeof = tc

-- Buffers sized to the ABI's fixed arrays.
M.PORT_INFO_CAP = 64           -- XcomPortInfo.name
M.PORT_DESC_CAP = 256          -- XcomPortInfo.description
M.PORT_HWID_CAP = 96           -- XcomPortInfo.hardware_id (v1.6)
M.ERROR_MESSAGE_CAP = 256      -- XcomError.message
M.MAX_PORT_LIST = 32           -- we enumerate at most this many ports per call

--[[-------------------------------------------------------------------------
create() -> XcomHandle or nil, err
Create the core instance.  Returns nil on failure without raising.
------------------------------------------------------------------------]]--
function M.create()
    local l = M.load()
    if not l then
        return nil, "xcom_core.dll not loaded"
    end
    local opts = tc.create_options()
    opts.struct_size = ffi.sizeof(tc.create_options)
    opts.flags = 0
    local h = l.xcom_create(opts)
    if h == nil then
        return nil, "xcom_create failed (another handle may be active)"
    end
    return h
end

--[[-------------------------------------------------------------------------
list_ports(opts) -> list of {name=, description=, busy=, hardware_id=}, native_error
Enumeration helper.  Calls the ABI with a bounded buffer; on insufficient
capacity it retries once with a larger buffer sized by the returned count.

Each entry carries `hardware_id` (v1.6): the bridge's stable PnP identity, or ""
when the port exposes none (composite/virtual ports) or an older 1.5 DLL wrote
only the legacy fields. Callers use it as the reconnect key and fall back to
`description` matching when it is empty.

Returns a second value, `native_error`, when the core could not read the
registry port list (nil on success or on the legacy path). A DLL/symbol/ABI
problem never raises and never breaks the caller: the worst case degrades to
an empty list, exactly as before this change.

opts.probe == true (or XCOM_PORT_PROBE=1) requests an exclusive-open occupancy
probe. It is OFF by default because opening a port can drive DTR and reset an
auto-reset target board; see xcom_ffi.M.probe_enabled_by_env.
------------------------------------------------------------------------]]--
function M.list_ports(opts)
    local l = M.load()
    if not l then
        return {}
    end
    local probe = (type(opts) == "table" and opts.probe == true) or
                  M.probe_enabled_by_env()
    local flags = probe and M.PROBE_BUSY or 0
    local cap = M.MAX_PORT_LIST
    local count = ffi.new("uint32_t[1]")
    local native = ffi.new("int32_t[1]")
    -- Prefer the error-aware entry point when the loaded DLL exports it; fall
    -- back to the legacy symbol so an older xcom_core.dll keeps working.
    local list_ex = l.xcom_list_ports_ex
    local function call(c, buf)
        if list_ex then
            return list_ex(buf, c, count, flags, native)
        end
        return l.xcom_list_ports(buf, c, count)
    end
    local ok, arr, rc = pcall(function()
        local a = ffi.new("XcomPortInfo[?]", cap)
        local r = call(cap, a)
        if r == M.err_full then
            cap = count[0] + 1
            local a2 = ffi.new("XcomPortInfo[?]", cap)
            r = call(cap, a2)
            a = a2
        end
        return a, r
    end)
    if not ok then
        return {}
    end
    -- A reported native error is surfaced even alongside a partial port list.
    local enum_error = nil
    if list_ex and native[0] ~= 0 then
        enum_error = native[0]
    end
    if rc ~= M.ok and rc ~= M.err_full and rc ~= M.err_io then
        return {}, enum_error
    end
    local n = math.min(count[0], cap)
    local ports = {}
    for i = 0, n - 1 do
        ports[#ports + 1] = {
            name = ffi.string(arr[i].name),
            description = ffi.string(arr[i].description),
            busy = arr[i].busy ~= 0,
            -- v1.6 stable identity; "" when the DLL/PnP path has none, so the
            -- caller can fall back to description matching.
            hardware_id = ffi.string(arr[i].hardware_id),
        }
    end
    return ports, enum_error
end

--[[-------------------------------------------------------------------------
Open-time modem-line tri-state (mirror xcom.h XCOM_LINE_*).  These describe
what xcom_open()/xcom_open_async() do to DTR/RTS AT OPEN and are distinct from
the runtime set_lines() booleans below: LEAVE_ALONE is only meaningful at open,
where the backend issues no EscapeCommFunction for that line.
------------------------------------------------------------------------]]--
M.line_deassert = 0
M.line_assert = 1
M.line_leave_alone = 2

--[[-------------------------------------------------------------------------
line_tristate(value) -> 0 | 1 | 2
Normalise an open-time line value.  Boolean callers keep the historical
meaning (true -> assert, false/nil -> deassert); a number passes through
unchanged, so XCOM_LINE_LEAVE_ALONE (2) is NOT collapsed to 1 the way the old
`dtr and 1 or 0` did.  Out-of-range numbers pass through too, letting the core
reject them with XCOM_ERR_PARAM instead of silently clamping.
------------------------------------------------------------------------]]--
function M.line_tristate(value)
    if value == true then
        return M.line_assert
    end
    if value == false or value == nil then
        return M.line_deassert
    end
    return value
end

--[[-------------------------------------------------------------------------
Open-time modem-line UI contract, shared by the ImGui combo (native
xcom_imgui_bridge.cpp), the legacy Win32 combo (ui/window.lua) and the tests.
The item order is fixed by the ABI enum, so a combo index IS its XCOM_LINE_*
value: index 0 = deassert, 1 = assert, 2 = leave alone.
------------------------------------------------------------------------]]--
M.OPEN_LINE_ITEMS = { "Deassert", "Assert", "Leave alone" }

--[[-------------------------------------------------------------------------
line_from_ui_index(index) -> 0 | 1 | 2

Normalise a UI combo index (or any persisted value) to a valid XCOM_LINE_*
constant.  A boolean is still accepted (true -> assert, false -> deassert), and
anything missing or out of range falls back to XCOM_LINE_LEAVE_ALONE, the safe
default that does not drive the pin — so a stale config or an unselected combo
can never pulse a target's reset/BOOT line.
------------------------------------------------------------------------]]--
function M.line_from_ui_index(index)
    if index == true then
        return M.line_assert
    end
    if index == false then
        return M.line_deassert
    end
    local value = tonumber(index)
    if value ~= M.line_deassert and value ~= M.line_assert and
       value ~= M.line_leave_alone then
        return M.line_leave_alone
    end
    return value
end

--[[-------------------------------------------------------------------------
open_line_default(value, legacy_value) -> 0 | 1 | 2

Resolve a persisted open-time line setting.  An explicit valid value wins (so a
stored LEAVE_ALONE is never collapsed); otherwise migrate the legacy boolean
(true -> assert, false -> deassert) an older config carried under the runtime
dtr_enable/rts_enable key; otherwise fall back to LEAVE_ALONE, the safe default
that does not drive the pin.  Pure, so main.lua and the tests share it without
the DLL.
------------------------------------------------------------------------]]--
function M.open_line_default(value, legacy_value)
    if value ~= nil then
        return M.line_from_ui_index(value)
    end
    if legacy_value ~= nil then
        return M.line_from_ui_index(legacy_value)
    end
    return M.line_leave_alone
end

--[[-------------------------------------------------------------------------
open(h, port, baud, data_bits, stop_bits, parity, flow, dtr, rts) -> status
Helper that builds the XcomPortConfig and forwards to xcom_open.
`dtr` and `rts` are the open-time tri-state: 0 = deassert, 1 = assert,
2 = leave the line alone.  A boolean is still accepted (true = 1, false = 0)
for backward compatibility; see line_tristate().
------------------------------------------------------------------------]]--
function M.open(h, port, baud, data_bits, stop_bits, parity, flow, dtr, rts)
    local cfg = tc.port_config()
    cfg.struct_size = ffi.sizeof(tc.port_config)
    cfg.port = port
    cfg.baud_rate = baud
    cfg.data_bits = data_bits
    cfg.stop_bits = stop_bits
    cfg.parity = parity
    cfg.flow_control = flow
    cfg.dtr_enable = M.line_tristate(dtr)
    cfg.rts_enable = M.line_tristate(rts)
    return M.open_c(h, cfg)
end

--[[-------------------------------------------------------------------------
open_async(h, ...) -> status
Same config contract as open(), including the tri-state dtr/rts, but queues
the open and returns immediately.  XCOM_OK means the request was queued (NOT
that the port is open); a non-OK value is an immediate failure a synchronous
open would also have returned.  Poll completion with take_open_result().
------------------------------------------------------------------------]]--
function M.open_async(h, port, baud, data_bits, stop_bits, parity, flow, dtr, rts)
    local cfg = tc.port_config()
    cfg.struct_size = ffi.sizeof(tc.port_config)
    cfg.port = port
    cfg.baud_rate = baud
    cfg.data_bits = data_bits
    cfg.stop_bits = stop_bits
    cfg.parity = parity
    cfg.flow_control = flow
    cfg.dtr_enable = M.line_tristate(dtr)
    cfg.rts_enable = M.line_tristate(rts)
    return M.open_async_c(h, cfg)
end

--[[-------------------------------------------------------------------------
take_open_result(h) -> status
Non-blocking query of an async open. Returns M.ok when OPEN, M.err_busy while
still in progress (poll again on the display timer), or another status for an
open failure (detailed error is in the error ring via take_error()).
------------------------------------------------------------------------]]--
function M.take_open_result(h)
    return M.take_open_result_c(h)
end

--[[-------------------------------------------------------------------------
set_options(h, opts) -> status
opts is a Lua table with keys: hex_view, timestamp, pause_display,
auto_clear_bytes, max_display_bytes (each optional; missing -> 0 / default).
------------------------------------------------------------------------]]--
function M.set_options(h, opts)
    local cfg = tc.display_options()
    cfg.struct_size = ffi.sizeof(tc.display_options)
    cfg.hex_view = (opts.hex_view and 1 or 0)
    cfg.timestamp = (opts.timestamp and 1 or 0)
    cfg.pause_display = (opts.pause_display and 1 or 0)
    cfg.auto_clear_bytes = opts.auto_clear_bytes or 0
    cfg.max_display_bytes = opts.max_display_bytes or (2 * 1024 * 1024)
    return M.set_options_c(h, cfg)
end

--[[-------------------------------------------------------------------------
set_lines(h, dtr, rts) -> status
Live modem-line control (v1.4 ABI).  dtr/rts are booleans, true = asserted
(physical pin active).  Applies immediately with EscapeCommFunction, unlike
the DCB flags which only take effect at open time.  Returns nil (and does
nothing) on a pre-1.4 DLL that lacks the export, so callers degrade quietly.
------------------------------------------------------------------------]]--
function M.set_lines(h, dtr, rts)
    local l = M.load()
    if not l then return nil end
    local fn = l.xcom_set_lines
    if fn == nil then return nil end
    return fn(h, (dtr and 1 or 0), (rts and 1 or 0))
end

--[[-------------------------------------------------------------------------
send(h, data_bytes, flags) -> status
data_bytes is a Lua string; synchronous-copy semantics: the DLL copies it and
returns (never retains the caller pointer).
------------------------------------------------------------------------]]--
function M.send(h, data_bytes, flags)
    if type(data_bytes) == "string" and #data_bytes > 0 then
        return M.send_c(h, data_bytes, #data_bytes, flags or 0)
    end
    -- empty or nil payload: send a zero-length buffer
    return M.send_c(h, ffi.cast("const uint8_t*", ""), 0, flags or 0)
end

-- close(h, timeout_ms) -> status
function M.close(h, timeout_ms)
    return M.close_c(h, timeout_ms or 2000)
end

--[[-------------------------------------------------------------------------
set_auto_template(h, data_bytes, interval_ms, flags) -> status
interval_ms == 0 disables auto-send.
------------------------------------------------------------------------]]--
function M.set_auto_template(h, data_bytes, interval_ms, flags)
    local n = data_bytes and #data_bytes or 0
    local ptr
    if n > 0 then
        ptr = ffi.cast("const uint8_t*", data_bytes)
    else
        ptr = ffi.cast("const uint8_t*", "")
    end
    return M.set_auto_template_c(h, ptr, n, interval_ms or 0, flags or 0)
end

--[[-------------------------------------------------------------------------
drain_display(h, capacity) -> (status, text_or_nil)
Write a single display batch into a user buffer up to `capacity` bytes; returns
the UTF-8 string (or nil + status when empty/failed).  Caller may poll until
snapshot.display_pending == 0.
------------------------------------------------------------------------]]--
function M.drain_display(h, capacity)
    local cap = capacity or 65536
    -- Reuse the single-threaded poll buffer.  Allocating a 64 KiB cdata block
    -- every 10 ms creates avoidable allocator/GC churn even when no bytes are
    -- pending; grow only when a caller requests a larger capacity.
    if not display_scratch or display_scratch.capacity < cap then
        display_scratch = { capacity = cap, data = ffi.new("char[?]", cap) }
        display_written = ffi.new("uint32_t[1]")
    end
    local rc = M.drain_display_c(h, display_scratch.data,
                                  display_scratch.capacity, display_written)
    if rc ~= M.ok then
        return rc, nil
    end
    if display_written[0] == 0 then
        return M.ok, nil
    end
    return M.ok, ffi.string(display_scratch.data, display_written[0])
end

--[[-------------------------------------------------------------------------
drain_display_ts(h, capacity) -> (status, text_or_nil, ingress_ms, supported)

Timestamp-aware display drain.  A newer DLL exports xcom_drain_display_ts,
whose return value is the byte count and whose 4th argument receives the
batch's earliest ingress time (monotonic ms).  On an older DLL — or no DLL —
the symbol is absent: fall back to the legacy drain and report supported=false,
so the caller DISABLES gap stamping rather than stamping the wrong clock
(design §3).  A zero-byte batch returns supported=true with no ingress value;
the previous anchor is left untouched, exactly like xcom_drain_display_ts.
------------------------------------------------------------------------]]--
function M.drain_display_ts(h, capacity)
    local l = M.load()
    local fn
    if l then
        -- Symbol lookup on a declared-but-absent export RAISES in LuaJIT, so
        -- probe with pcall instead of a plain nil comparison.
        local ok, sym = pcall(function() return l.xcom_drain_display_ts end)
        if ok then fn = sym end
    end
    if fn == nil then
        local rc, text = M.drain_display(h, capacity)
        return rc, text, nil, false
    end
    local cap = capacity or 65536
    if not display_scratch or display_scratch.capacity < cap then
        display_scratch = { capacity = cap, data = ffi.new("char[?]", cap) }
    end
    if not display_ingress then
        display_ingress = ffi.new("uint32_t[1]")
    end
    local n = fn(h, display_scratch.data, display_scratch.capacity,
                 display_ingress)
    if n == 0 then
        return M.ok, nil, nil, true
    end
    return M.ok, ffi.string(display_scratch.data, n), display_ingress[0], true
end

--[[-------------------------------------------------------------------------
get_snapshot(h) -> XcomSnapshot or nil  (assumes caller keeps handle alive)
Returns a snapshot table for the status bar / UI.

Both the FFI struct AND the returned plain table are module-level scratch
buffers, not per-call allocations: this runs on every 250 ms status poll, and a
fresh ~19-field table per tick fed the GC even when nothing changed.

OWNERSHIP CONTRACT: the returned table is reused by the next get_snapshot call,
so callers must consume it BEFORE the next poll and must NOT retain it.
ViewModel:on_snapshot copies the fields it keeps into its own persistent table
(see view_model.lua), which is what makes the reused buffer safe for the
retain-and-diff consumer.
------------------------------------------------------------------------]]--
local snapshot_scratch = tc.snapshot()
local snapshot_table = {}
function M.get_snapshot(h)
    local s = snapshot_scratch
    s.struct_size = ffi.sizeof(tc.snapshot)
    if M.get_snapshot_c(h, s) ~= M.ok then
        return nil
    end
    local t = snapshot_table
    t.rx_bytes = s.rx_bytes
    t.tx_bytes = s.tx_bytes
    t.rx_pool_exhausted_bytes = s.rx_pool_exhausted_bytes
    t.tx_rejected = s.tx_rejected
    t.auto_tick_coalesced = s.auto_tick_coalesced
    t.ui_trimmed_bytes = s.ui_trimmed_bytes
    t.save_rejected_bytes = s.save_rejected_bytes
    t.display_paused_bytes = s.display_paused_bytes
    t.callback_count = s.callback_count
    t.generation = s.generation
    t.display_pending = s.display_pending
    t.port_state = s.port_state
    t.framing_errors = s.framing_errors
    t.parity_errors = s.parity_errors
    t.overrun_errors = s.overrun_errors
    t.break_events = s.break_events
    t.rx_sequence = s.rx_sequence
    t.rx_loss_offset = s.rx_loss_offset
    t.rx_backpressure_events = s.rx_backpressure_events
    t.flow_hold_events = s.flow_hold_events
    return t
end

--[[-------------------------------------------------------------------------
take_error(h) -> {code=, source=, message=} or nil
Pop one error record from the ring.
------------------------------------------------------------------------]]--
function M.take_error(h)
    local e = tc.error()
    e.struct_size = ffi.sizeof(tc.error)
    local rc = M.take_error_c(h, e)
    if rc ~= M.ok or e.code == 0 then
        return nil
    end
    return {
        code = e.code,
        source = e.source,
        message = ffi.string(e.message),
    }
end

--[[-------------------------------------------------------------------------
log_open(h, utf8_path, append) -> status
Set the ordered receive-log destination (dedicated file writer).
------------------------------------------------------------------------]]--
function M.log_open(h, utf8_path, append)
    append = append ~= false
    return M.log_open_c(h, utf8_path, append and 1 or 0)
end

M.log_append = f("xcom_log_append")
M.log_flush = f("xcom_log_flush")
M.log_close = f("xcom_log_close")
M.test_inject_rx = f("xcom_test_inject_rx")
M.destroy = f("xcom_destroy")

--[[-------------------------------------------------------------------------
Pinned struct sizes (MSVC x64 /Zp8).  Must equal ffi.sizeof of each cdef'd
struct.  A layout drift against the authoritative xcom.h is caught here at
require time, even before a DLL is loaded (Linux-safe).
------------------------------------------------------------------------]]--
local SIZEOF = {
    create_options   = 8,
    port_config      = 32,
    display_options  = 16,
    snapshot         = 84,
    error            = 268,
    port_info        = 420,
}
M.SIZEOF = SIZEOF

-- Struct-name -> expected size; run the assertion once when the module loads.
for type_name, expected in pairs({
    XcomCreateOptions   = SIZEOF.create_options,
    XcomPortConfig      = SIZEOF.port_config,
    XcomDisplayOptions  = SIZEOF.display_options,
    XcomSnapshot        = SIZEOF.snapshot,
    XcomError           = SIZEOF.error,
    XcomPortInfo        = SIZEOF.port_info,
}) do
    local actual = ffi.sizeof(type_name)
    if actual ~= expected then
        error(string.format("xcom FFI layout mismatch for %s: expected %d, got %d",
                            type_name, expected, actual))
    end
end

--[[-------------------------------------------------------------------------
Pure HEX encode/decode (mirror Python bytes.fromhex / the receive hex view).
Operates on raw Lua strings, no DLL required, so they are unit-testable on Linux.
------------------------------------------------------------------------]]--

-- "01 0A FF" / "010AFF" (any whitespace tolerated) -> raw bytes string.
-- Returns nil for odd-length or non-hex-digit input.
function M.from_hex(text)
    local cleaned = (text or ""):gsub("%s+", "")
    if cleaned == "" then
        return ""
    end
    if #cleaned % 2 ~= 0 then
        return nil
    end
    local parts = {}
    for i = 1, #cleaned, 2 do
        local byte = tonumber(cleaned:sub(i, i + 1), 16)
        if byte == nil then
            return nil
        end
        parts[#parts + 1] = string.char(byte)
    end
    return table.concat(parts)
end

-- raw bytes -> "AA BB CC " spaced uppercase hex tokens (receive hex view).
function M.to_hex(data)
    local parts = {}
    for i = 1, #data do
        parts[#parts + 1] = string.format("%02X ", data:byte(i))
    end
    return table.concat(parts)
end

function M.append_crlf(data)
    return data .. "\r\n"
end

-- Send payload encoding, equivalent to Python's build_send_payload
-- (widgets/send_panel.py):
--   HEX mode: whitespace-stripped input; empty -> return "" WITHOUT applying
--   CRLF (Python's early `return b"", None` skips the CRLF branch entirely);
--   invalid hex digits/odd length -> (nil, "invalid hex").
--   TEXT mode: UTF-8 bytes, then optional CRLF appended.
function M.build_send_payload(text, use_hex, add_crlf)
    local data
    if use_hex then
        local cleaned = (text or ""):gsub("%s+", "")
        if cleaned == "" then
            return "", nil  -- mirrors Python's early return; no CRLF applied
        end
        data = M.from_hex(cleaned)
        if data == nil then
            return nil, "invalid hex"
        end
    else
        data = text or ""
    end
    if add_crlf then
        data = M.append_crlf(data)
    end
    return data, nil
end

return M
