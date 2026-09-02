--[[--------------------------------------------------------------------------
core/xcom_ffi.lua - LuaJIT FFI binding for xcom_core.dll (xcom.h v1.2 ABI).

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
} XcomPortInfo;

uint32_t xcom_version(void);
XcomStatus xcom_list_ports(XcomPortInfo* out, uint32_t capacity, uint32_t* count);
void* xcom_create(const XcomCreateOptions* options);
XcomStatus xcom_open(void* h, const XcomPortConfig* config);
XcomStatus xcom_open_async(void* h, const XcomPortConfig* config);
XcomStatus xcom_take_open_result(void* h);
XcomStatus xcom_close(void* h, uint32_t timeout_ms);
XcomStatus xcom_send(void* h, const uint8_t* data, uint32_t size, uint32_t flags);
XcomStatus xcom_set_options(void* h, const XcomDisplayOptions* options);
XcomStatus xcom_set_auto_template(void* h, const uint8_t* data, uint32_t size,
                                  uint32_t interval_ms, uint32_t flags);
XcomStatus xcom_drain_display(void* h, char* output, uint32_t capacity,
                              uint32_t* written);
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

M.version_major = 1
M.version_minor = 2
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
list_ports() -> list of {name=, description=, busy=}
Enumeration helper.  Calls the ABI with a bounded buffer; on insufficient
capacity it retries once with a larger buffer sized by the returned count.
Returns empty list on any error.
------------------------------------------------------------------------]]--
function M.list_ports()
    local l = M.load()
    if not l then
        return {}
    end
    local cap = M.MAX_PORT_LIST
    local count = ffi.new("uint32_t[1]")
    local buf_ptr
    local function try(c, buf)
        local rc = l.xcom_list_ports(buf, c, count)
        return rc
    end
    -- first attempt with fixed stack-like buffer
    local arr = ffi.new("XcomPortInfo[?]", cap)
    local rc = try(cap, arr)
    if rc == M.err_full then
        -- grow to the needed count (capped)
        cap = count[0] + 1
        local arr2 = ffi.new("XcomPortInfo[?]", cap)
        rc = try(cap, arr2)
        arr = arr2
    end
    if rc ~= M.ok then
        return {}
    end
    local n = math.min(count[0], cap)
    local ports = {}
    for i = 0, n - 1 do
        ports[#ports + 1] = {
            name = ffi.string(arr[i].name),
            description = ffi.string(arr[i].description),
            busy = arr[i].busy ~= 0,
        }
    end
    return ports
end

--[[-------------------------------------------------------------------------
open(h, port, baud, data_bits, stop_bits, parity, flow, dtr, rts) -> status
Helper that builds the XcomPortConfig and forwards to xcom_open.
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
    cfg.dtr_enable = dtr and 1 or 0
    cfg.rts_enable = rts and 1 or 0
    return M.open_c(h, cfg)
end

--[[-------------------------------------------------------------------------
open_async(h, ...) -> status
Same config contract as open(), but queues the open and returns immediately.
XCOM_OK means the request was queued (NOT that the port is open); a non-OK
value is an immediate failure a synchronous open would also have returned.
Poll completion with take_open_result().
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
    cfg.dtr_enable = dtr and 1 or 0
    cfg.rts_enable = rts and 1 or 0
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
get_snapshot(h) -> XcomSnapshot or nil  (assumes caller keeps handle alive)
Returns a fresh Lua table snapshot for the status bar / UI.
------------------------------------------------------------------------]]--
function M.get_snapshot(h)
    local s = tc.snapshot()
    s.struct_size = ffi.sizeof(tc.snapshot)
    if M.get_snapshot_c(h, s) ~= M.ok then
        return nil
    end
    return {
        rx_bytes = s.rx_bytes,
        tx_bytes = s.tx_bytes,
        rx_pool_exhausted_bytes = s.rx_pool_exhausted_bytes,
        tx_rejected = s.tx_rejected,
        auto_tick_coalesced = s.auto_tick_coalesced,
        ui_trimmed_bytes = s.ui_trimmed_bytes,
        save_rejected_bytes = s.save_rejected_bytes,
        display_paused_bytes = s.display_paused_bytes,
        callback_count = s.callback_count,
        generation = s.generation,
        display_pending = s.display_pending,
        port_state = s.port_state,
    }
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
    snapshot         = 52,
    error            = 268,
    port_info        = 324,
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
