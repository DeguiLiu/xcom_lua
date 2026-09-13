local ffi = require("ffi")
local bit = require("bit")
local xcom_ffi = require("xcom_ffi")
-- Pure timestamp-stripping helper for the receive-area copy path (see the
-- module header).  Requireable without the DLL, so its unit test runs
-- headless on Linux.
local receive_copy = require("receive_copy")

ffi.cdef[[
int xcom_imgui_init(void* hwnd);
void xcom_imgui_set_ports(const char* const* names, int count);
int xcom_imgui_new_frame(void);
int xcom_imgui_render(void);
void xcom_imgui_set_receive_text(const char* text, size_t length);
void xcom_imgui_receive_append(const char* delta, size_t length);
size_t xcom_imgui_get_receive_text(char* out, size_t capacity, size_t* base_out);
void xcom_imgui_set_receive_window(size_t bytes);
void xcom_imgui_set_receive_base(size_t absolute_offset);
/* Receive-area copy path: the native side queues the bytes the user asked to
 * copy (Ctrl+C / context menu) instead of touching the clipboard, so this Lua
 * layer owns the optional timestamp strip before the clipboard write. */
void xcom_imgui_set_copy_strip(int* enabled);
size_t xcom_imgui_take_receive_copy(char* out, size_t capacity);
void xcom_imgui_set_clipboard_text(const char* text, size_t length);
void xcom_imgui_set_status(const char* text);
int xcom_imgui_wndproc(void* hwnd, unsigned int msg, uintptr_t wparam, intptr_t lparam);
int xcom_imgui_draw_console(char* port, size_t port_capacity, int connected,
  int rx_bytes, int tx_bytes, int* baud, int* data_bits, int* stop_bits,
  int* parity, int* flow, int* dtr, int* rts, int* receive_hex,
  int* timestamp, int* pause_display, int* auto_clear, int* auto_clear_bytes,
  char* send_text, size_t send_capacity, int* send_hex, int* send_crlf,
  int* send_auto, int* send_period,
  char* multi_text, size_t multi_slot_capacity, int* multi_enabled,
  int* multi_hex, int* multi_crlf, int* multi_page, int* multi_page_count,
  int* multi_auto, int* multi_period, int* auto_save,
  const char* receive_text, size_t receive_length);
void xcom_imgui_shutdown(void);

/* ---- feature extensions (Phase 4; each is symbol-probed at load time so
 * an older DLL without them degrades gracefully — see optional_export) ---- */
void xcom_imgui_set_baud_extra(int* custom_baud);
/* Open-time modem-line tri-state (XCOM_LINE_*: 0/1/2).  The two Lua-owned
 * int buffers are registered once; the native serial grid edits them in
 * place.  Symbol-probed like the rest, so an older DLL keeps the persisted
 * values with no UI to change them. */
void xcom_imgui_set_open_lines(int* dtr_open, int* rts_open);
void xcom_imgui_set_multi_extra(int* gap_ms);
void xcom_imgui_set_charset(int* index);
void xcom_imgui_set_frame_gap(int* enabled, int* ms);
void xcom_imgui_set_highlight_rules(const char* packed, int count);
void xcom_imgui_set_scripts(const char* names_packed, int* enabled, int count);
void xcom_imgui_set_script_labels(const char* labels_packed);
void xcom_imgui_set_script_descs(const char* descs_packed, int count);
void xcom_imgui_set_script_log(const char* text, size_t length);
void xcom_imgui_set_scripts_visible(int visible);
int xcom_imgui_take_script_events(int* events, int capacity);
int xcom_imgui_script_take_command(char* out, int capacity);
void xcom_imgui_script_load_editor(const char* path, const char* text, size_t length);
void xcom_imgui_script_select(int index);
int xcom_imgui_script_take_editor_save(char* out_path, int path_cap,
                                       char* out_text, int text_cap);
int xcom_imgui_scope_push(int channel, double x, double y);
void xcom_imgui_scope_clear(void);
void xcom_imgui_scope_configure(int channel, int visible);
void xcom_imgui_scope_set_visible(int visible);
void xcom_imgui_set_settings_visible(int visible);
void xcom_imgui_set_plugin_page(const char* id, const char* title,
                                const char* spec);
int xcom_imgui_take_plugin_events(char* out, int capacity);
]]

local M = {}
local ok, lib = pcall(ffi.load, "xcom_imgui")
M.available = ok and lib or nil

-- An export added after the DLL this process loaded was built resolves to a
-- nil field here (pcall-wrapped: indexing a missing cdata symbol errors).
-- Every Phase-4 feature call site goes through this probe so an old DLL
-- simply hides the feature instead of crashing the app.
local function optional_export(name)
    local probe_ok, fn = pcall(function() return lib[name] end)
    return probe_ok and fn or nil
end

M.optional_export = optional_export

-- Charset dropdown items; index contract shared with the C++ combo.
M.CHARSET_ITEMS = { "ASCII", "UTF-8", "GB2312", "BIG5", "SHIFT-JIS", "UTF-16" }

local PORT_CAPACITY = 128
local SEND_CAPACITY = 4096
-- Cached once at load: per-call os.getenv on the 10 ms drain / render path is
-- wasteful, and the debug flag never changes during a session.
local _DEBUG = os.getenv("XCOM_DEBUG") == "1"
local MULTI_SLOTS = 8
local MULTI_SLOT_CAPACITY = 512
-- Receive-tail window.  Default matches the historical fixed 64 KiB view;
-- the effective value is per-instance (see M.new) because it is configurable
-- via [display] receive_window_bytes in config.ini.
local DEFAULT_RECEIVE_CAPACITY = 64 * 1024
-- Hard floor/ceiling shared with the native side (xcom_imgui_set_receive_window
-- clamps to the same range): below 16 KiB the log viewport starves; above
-- 1 MiB the per-frame line-offset rescan and the ImGui text cost grow past
-- the WARP frame budget.
local RECEIVE_WINDOW_MIN = 16 * 1024
local RECEIVE_WINDOW_MAX = 1024 * 1024

local function int1(value)
    return ffi.new("int[1]", value or 0)
end

local function bool1(value)
    return int1(value and 1 or 0)
end

local BAUD = { 1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200,
    230400, 460800, 921600, 1000000, 2000000, 3000000 }

local function index_of(values, value, fallback)
    for index, candidate in ipairs(values) do
        if candidate == value then return index - 1 end
    end
    return fallback or 0
end

-- Resolve a persisted (baud_rate, baud_custom) pair into
--   (combo_index, custom_override)
-- A saved NON-PRESET baud (250000/500000/74880/1500000, ...) must never snap to
-- the nearest preset: the old `index_of(BAUD, cfg.baud_rate, 7)` fallback
-- silently rewrote such a value to 115200 on the next open/save, corrupting
-- the config for MCUs that need it.  Instead the non-preset value is carried as
-- the custom override (which serial_config returns even when the native "more"
-- section is hidden) while the combo parks on the 115200 slot as a stable
-- display fallback.  An explicit non-zero baud_custom always wins, matching the
-- native contract ("a non-zero Custom value overrides the preset combo").
-- Exported (pure) so it is unit-testable on Linux without the DLL.
function M.resolve_baud(baud_rate, baud_custom)
    local custom = math.floor(tonumber(baud_custom) or 0)
    if custom < 300 or custom > 3000000 then
        custom = 0
    end
    local index = index_of(BAUD, baud_rate, -1)
    if index < 0 then
        index = index_of(BAUD, 115200, 7)
        if custom == 0 then
            local saved = math.floor(tonumber(baud_rate) or 0)
            if saved >= 300 and saved <= 3000000 then
                custom = saved
            end
        end
    end
    return index, custom
end

-- Clamp a configured receive-window size to the shared Lua/native range.
-- Exported so window.lua can normalize the config value once and push the
-- SAME number into its chunk trimming and this bridge.
function M.clamp_receive_window(bytes)
    local n = math.floor(tonumber(bytes) or DEFAULT_RECEIVE_CAPACITY)
    if n < RECEIVE_WINDOW_MIN then n = RECEIVE_WINDOW_MIN end
    if n > RECEIVE_WINDOW_MAX then n = RECEIVE_WINDOW_MAX end
    return n
end

function M.new(hwnd, cfg)
    if not M.available then return nil end
    if M.available.xcom_imgui_init(hwnd) == 0 then return nil end
    local receive_capacity = M.clamp_receive_window(
        cfg and cfg.receive_window_bytes or DEFAULT_RECEIVE_CAPACITY)
    local baud_index, baud_custom_value = M.resolve_baud(cfg.baud_rate, cfg.baud_custom)
    local self = {
        lib = M.available,
        port = ffi.new("char[?]", PORT_CAPACITY),
        send = ffi.new("char[?]", SEND_CAPACITY),
        baud = int1(baud_index),
        data_bits = int1(math.max(0, math.min(3, (cfg.data_bits or 8) - 5))),
        stop_bits = int1(cfg.stop_bits),
        parity = int1(cfg.parity),
        flow = int1(cfg.flow_control),
        dtr = bool1(cfg.dtr_enable),
        rts = bool1(cfg.rts_enable),
        -- Open-time modem-line tri-state (0 = deassert, 1 = assert, 2 = leave
        -- the line alone), a SEPARATE group from the runtime dtr/rts toggles
        -- just above (those stay plain 0/1).  These are the values handed to
        -- XcomPortConfig.dtr_enable/rts_enable at open; the native serial grid
        -- edits them in place once xcom_imgui_set_open_lines is registered.
        -- line_from_ui_index normalises a missing/stale config to LEAVE_ALONE,
        -- so a config-less bridge can never default to driving the pin.
        dtr_open = int1(xcom_ffi.line_from_ui_index(cfg.dtr_open)),
        rts_open = int1(xcom_ffi.line_from_ui_index(cfg.rts_open)),
        receive_hex = bool1(cfg.receive_hex),
        timestamp = bool1(cfg.timestamp),
        pause_display = bool1(cfg.pause_display),
        auto_clear = bool1((cfg.auto_clear_bytes or 0) > 0),
        auto_clear_bytes = int1(cfg.auto_clear_bytes),
        send_hex = bool1(cfg.send_hex),
        send_crlf = bool1(cfg.send_crlf),
        send_auto = int1(),
        send_period = int1(cfg.autosend_period_ms or 1000),
        multi_text = ffi.new("char[?]", MULTI_SLOTS * MULTI_SLOT_CAPACITY),
        multi_enabled = ffi.new("int[?]", MULTI_SLOTS),
        multi_hex = int1(),
        multi_crlf = int1(),
        multi_page = int1(),
        multi_page_count = int1(1),
        multi_auto = int1(),
        multi_period = int1(1000),
        auto_save = bool1(cfg.auto_save),
        pages = { { text = {}, enabled = {} } },
        receive_capacity = receive_capacity,
    }
    -- Phase-4 extension state: registered with the DLL only when the
    -- symbols exist (older DLLs keep working; the features stay hidden).
    local set_baud_extra = optional_export("xcom_imgui_set_baud_extra")
    local set_multi_extra = optional_export("xcom_imgui_set_multi_extra")
    local set_charset = optional_export("xcom_imgui_set_charset")
    local set_frame_gap = optional_export("xcom_imgui_set_frame_gap")
    local set_open_lines = optional_export("xcom_imgui_set_open_lines")
    -- The resolved custom override (see resolve_baud) is ALSO kept Lua-side:
    -- when the DLL has no set_baud_extra export there is no cdata to read back
    -- from, and serial_config must still return the preserved non-preset value.
    self._baud_override = baud_custom_value > 0 and baud_custom_value or nil
    if set_baud_extra then
        self.baud_custom = int1(baud_custom_value)
        set_baud_extra(self.baud_custom)
    end
    if set_multi_extra then
        self.multi_gap = int1(cfg.multi_gap_ms or 100)
        set_multi_extra(self.multi_gap)
    end
    if set_charset then
        self.charset = int1(index_of(M.CHARSET_ITEMS, cfg.charset, 0))
        set_charset(self.charset)
    end
    if set_frame_gap then
        local gap = tonumber(cfg.frame_gap_ms) or 0
        self.frame_gap_enabled = bool1(gap > 0)
        self.frame_gap_ms = int1(gap)
        set_frame_gap(self.frame_gap_enabled, self.frame_gap_ms)
    end
    -- Open-time tri-state buffers (created unconditionally above) are handed
    -- to the native serial grid when that export exists; otherwise the values
    -- still flow to open via serial_config, only the in-panel editors hide.
    if set_open_lines then
        set_open_lines(self.dtr_open, self.rts_open)
    end
    -- "Copy without timestamps" toggle (Lua-owned int, edited by the native
    -- receive context menu).  Registered only when the DLL has the export; an
    -- old DLL hides the menu item and the copy path stays timestamp-inclusive.
    local set_copy_strip = optional_export("xcom_imgui_set_copy_strip")
    if set_copy_strip then
        self.copy_strip_timestamp = bool1(cfg.copy_strip_timestamp)
        set_copy_strip(self.copy_strip_timestamp)
    end
    -- Push the configured window into the native receive buffer so both
    -- sides trim to the same tail size.
    M.available.xcom_imgui_set_receive_window(receive_capacity)
    return setmetatable(self, { __index = M })
end

function M:set_receive_text(text, base)
    text = text or ""
    local n = math.min(#text, (self.receive_capacity or DEFAULT_RECEIVE_CAPACITY) - 1)
    -- Publish where this window sits in the lifetime receive stream BEFORE
    -- pushing (see xcom_imgui_set_receive_base): the native selection is
    -- stored in those absolute coordinates so it travels with its text as
    -- the Lua tail slides.  Older DLLs lack the export and simply keep the
    -- historical window-relative behaviour.
    local push_base = optional_export("xcom_imgui_set_receive_base")
    if push_base then push_base(math.floor(base or 0)) end
    self.lib.xcom_imgui_set_receive_text(text, n)
end

-- Incremental tail push (zero-rebuild path).  The DLL owns the sliding
-- receive window: appending a batch costs O(batch) there, whereas
-- set_receive_text re-copies + re-scans the whole tail on every flush.
-- Returns true when the append path exists (fresh DLL), false on an old one
-- (caller falls back to the full replace).
local append_export = optional_export("xcom_imgui_receive_append")
local get_export = optional_export("xcom_imgui_get_receive_text")
-- Receive copy path exports, probed once (per-frame probing would pcall on the
-- render hot path).  A pre-feature DLL resolves these to nil and the feature
-- hides cleanly.
local take_copy_export = optional_export("xcom_imgui_take_receive_copy")
local set_clipboard_export = optional_export("xcom_imgui_set_clipboard_text")

function M:append_receive(delta)
    if not append_export then return false end
    append_export(delta, #delta)
    return true
end

function M:can_append_receive()
    return append_export ~= nil
end

-- Read back the native tail (for the "save visible" action).  Returns the
-- window text or nil when the export is missing / buffer empty.
function M:get_receive_text()
    if not get_export then return nil end
    local cap = (self.receive_capacity or DEFAULT_RECEIVE_CAPACITY)
    local buf = self._receive_read_buf
    if not buf or self._receive_read_cap ~= cap then
        buf = ffi.new("char[?]", cap)
        self._receive_read_buf = buf
        self._receive_read_cap = cap
    end
    local base_out = self._receive_read_base or ffi.new("size_t[1]")
    self._receive_read_base = base_out
    local n = get_export(buf, cap, base_out)
    if n == 0 then return "", tonumber(base_out[0]) or 0 end
    return ffi.string(buf, tonumber(n) or 0), tonumber(base_out[0]) or 0
end

-- ---------------------------------------------------------------------------
-- Receive copy path (Ctrl+C / context menu)
--
-- The native side does NOT write the clipboard for the receive log any more:
-- Ctrl+C and the context menu queue the requested bytes (xcom_imgui_take_
-- receive_copy) and this layer writes them after applying the optional
-- timestamp strip.  Keeping the strip here (not in C++) means the shipping
-- policy is the pure, headless-tested core/receive_copy.lua function.
-- ---------------------------------------------------------------------------

-- Current "copy without timestamps" state.  False when the DLL lacks the
-- export (feature hidden) or the user left it off.
function M:copy_strip_enabled()
    return self.copy_strip_timestamp ~= nil and self.copy_strip_timestamp[0] ~= 0
end

-- Drain a pending copy request.  Returns the raw text the user asked to copy
-- (selection or retained tail), or nil when none is pending.  The buffer is
-- the receive-window size, so the request always fits one call.
function M:take_receive_copy()
    if not take_copy_export then return nil end
    local cap = self.receive_capacity or DEFAULT_RECEIVE_CAPACITY
    local buf = self._copy_buf
    if not buf or self._copy_buf_cap ~= cap then
        buf = ffi.new("char[?]", cap)
        self._copy_buf = buf
        self._copy_buf_cap = cap
    end
    local n = tonumber(take_copy_export(buf, cap)) or 0
    if n <= 0 then return nil end
    return ffi.string(buf, n)
end

function M:set_clipboard_text(text)
    if not set_clipboard_export then return end
    set_clipboard_export(text or "", #(text or ""))
end

-- Service one pending copy after the native draw: strip when the user opted
-- in, then write the clipboard.  No-op (zero FFI) while no request is queued.
function M:service_receive_copy()
    if not take_copy_export then return end
    local text = self:take_receive_copy()
    if text == nil then return end
    if self:copy_strip_enabled() then
        text = receive_copy.strip_timestamps(text)
    end
    self:set_clipboard_text(text)
end

-- Push highlight rules ({pattern, color, style} tables, color = 0xRRGGBB)
-- to the native renderer as a packed "pattern\0RRGGBB\0style\0" blob.
-- No-op when the DLL predates the export (rules simply don't render).
function M:set_highlight_rules(rules)
    local push = optional_export("xcom_imgui_set_highlight_rules")
    if not push or not rules or #rules == 0 then
        if push then push(nil, 0) end
        return
    end
    local parts = {}
    for _, rule in ipairs(rules) do
        parts[#parts + 1] = tostring(rule.pattern)
        parts[#parts + 1] = string.format("%06X", rule.color or 0xE53935)
        parts[#parts + 1] = rule.style == "bg" and "bg" or "text"
    end
    local packed = table.concat(parts, "\0")
    push(packed, #rules)
end

-- Mirror the script-engine log tail into the Script Console panel.
function M:set_script_log(text)
    local push = optional_export("xcom_imgui_set_script_log")
    if not push then return end
    push(text or "", #text or 0)
end

-- Script list + Lua-owned enable buffer.  names: array of strings.
-- labels (optional): array of DISPLAY strings, index-aligned with names — the
-- @name/@desc label when a script declared one, else the filename.  The DLL
-- keeps `names` as the index key (events carry only the index) and renders
-- `labels`; a pre-labels DLL simply ignores the second export.
-- descs (optional): array of HOVER strings, index-aligned with names — the
-- @desc/@name tooltip, "" meaning "no tooltip".  Rides its own export (same
-- ABI reason as labels) with an explicit count, because an empty entry in the
-- middle is meaningful here and the label parser would stop at it.
-- The bridge keeps `self._script_enabled_buf` alive (Lua-owned int array).
function M:set_scripts(names, labels, descs)
    local push = optional_export("xcom_imgui_set_scripts")
    if not push then return end
    if not names or #names == 0 then
        self._script_enabled_buf = nil
        self._script_names = nil
        self._script_labels = nil
        self._script_descs = nil
        push(nil, nil, 0)
        return
    end
    local enabled = ffi.new("int[?]", #names)
    for i = 1, #names do enabled[i - 1] = 0 end
    self._script_enabled_buf = enabled
    self._script_names = names
    local packed = table.concat(names, "\0")
    push(packed, enabled, #names)
    -- Labels ride a separate export so the set_scripts ABI stays untouched.
    if labels and #labels == #names then
        self._script_labels = labels
        local set_labels = optional_export("xcom_imgui_set_script_labels")
        if set_labels then
            set_labels(table.concat(labels, "\0"))
        end
    end
    -- Tooltips mirror labels, but send the count: descs may contain "".
    if descs and #descs == #names then
        self._script_descs = descs
        local set_descs = optional_export("xcom_imgui_set_script_descs")
        if set_descs then
            set_descs(table.concat(descs, "\0"), #descs)
        end
    end
    return enabled
end

function M:set_scripts_visible(visible)
    local push = optional_export("xcom_imgui_set_scripts_visible")
    if push then push(visible and 1 or 0) end
end

function M:set_settings_visible(visible)
    local push = optional_export("xcom_imgui_set_settings_visible")
    if push then push(visible and 1 or 0) end
end

function M:set_scope_visible(visible)
    local push = optional_export("xcom_imgui_scope_set_visible")
    if push then push(visible and 1 or 0) end
end

-- Declares (or removes, with spec=nil) one settings-window page rendered by
-- the C++ side from the line-oriented spec grammar (see xcom_imgui_bridge.cpp
-- "Plugin spec grammar").  Interactions arrive via take_plugin_events.
function M:set_plugin_page(id, title, spec)
    local push = optional_export("xcom_imgui_set_plugin_page")
    if not push then return end
    push(id, title or id, spec)
end

-- Drains queued plugin events as {page, kind, widget, value} records.
function M:take_plugin_events()
    local take = optional_export("xcom_imgui_take_plugin_events")
    if not take then return nil end
    local buf = self._plugin_event_buf
    if not buf then
        buf = ffi.new("char[?]", 4096)
        self._plugin_event_buf = buf
    end
    local n = tonumber(take(buf, 4096)) or 0
    if n <= 0 then return nil end
    local events = {}
    local raw = ffi.string(buf, n)
    -- Records are "page:kind:wid[:value]".  The page id may contain a colon
    -- ("script.lua:local_id"), but kind/wid/value never do (native-side
    -- contract), so anchor on the known kinds and split the tail twice.
    for record in raw:gmatch("[^%z]+") do
        local page, kind, tail = record:match("^(.-):(check|slider|combo|click):(.+)$")
        if page then
            local widget, value = tail:match("^([^:]+):?(.*)$")
            events[#events + 1] = { page = page, kind = kind, widget = widget,
                value = value ~= "" and value or nil }
        end
    end
    return events
end

-- Scope (ImPlot) data channel: seconds x, value y, 1-based channel.
function M:scope_push(channel, x, y)
    local push = optional_export("xcom_imgui_scope_push")
    if push then return push(channel, x, y) end
end

-- Reset every scope channel's ring buffer (offset/count -> 0, last_x -> 0,
-- has_data -> false).  Thin wrapper over xcom_imgui_scope_clear(void); a no-op
-- on an older DLL that lacks the export.
function M:scope_clear()
    local clear = optional_export("xcom_imgui_scope_clear")
    if clear then clear() end
end

-- Per-channel visibility.  opts = { channel = <1-based int>, visible = <bool> }
-- (channel defaults to 1; visible defaults to true — the C-side ScopeChannel
-- default, so a channel is drawn until a script explicitly hides it).  Thin
-- wrapper over xcom_imgui_scope_configure(channel, visible); out-of-range
-- channels are ignored by the native side, and this is a no-op on an older DLL.
function M:scope_configure(opts)
    local configure = optional_export("xcom_imgui_scope_configure")
    if not configure then return end
    opts = opts or {}
    local channel = tonumber(opts.channel) or 1
    local visible = opts.visible
    if visible == nil then visible = true end
    configure(channel, visible and 1 or 0)
end

-- Toggle the whole scope panel.  Accepts a bool or an int (0/1); the C-side
-- default is hidden (scope_visible_ = false).  There is no header chip any
-- more: window.lua drives this from script activity (waveform.active()), so a
-- script feeding wave.push shows the panel and going quiet hides it.
-- Same export as set_scope_visible, provided under the scope_* name for
-- symmetry with scope_push/scope_clear/scope_configure; a no-op on an older
-- DLL.
function M:scope_set_visible(visible)
    local push = optional_export("xcom_imgui_scope_set_visible")
    if push then push(visible and 1 or 0) end
end

-- Drain queued console events into a plain Lua array of {type, index}.
function M:take_script_events()
    local take = optional_export("xcom_imgui_take_script_events")
    if not take then return nil end
    local buf = self._event_buf
    if not buf then
        buf = ffi.new("int[?]", 16)
        self._event_buf = buf
    end
    local n = tonumber(take(buf, 16)) or 0
    if n <= 0 then return nil end
    local events = {}
    for i = 0, n - 1 do
        local packed = tonumber(buf[i])
        events[#events + 1] = {
            type = bit.rshift(packed, 8),
            index = bit.band(packed, 0xFF),
            flag = bit.band(packed, 0x40) ~= 0,
        }
    end
    return events
end

-- One-line REPL: returns the submitted command, or nil.
function M:take_script_command()
    local take = optional_export("xcom_imgui_script_take_command")
    if not take then return nil end
    local buf = self._command_buf
    if not buf then
        buf = ffi.new("char[?]", 512)
        self._command_buf = buf
    end
    if take(buf, 512) == 0 then return nil end
    return ffi.string(buf)
end

-- Editor content push (Lua -> C++).
function M:script_load_editor(path, text)
    local push = optional_export("xcom_imgui_script_load_editor")
    if not push then return end
    push(path or "", text or "", #text or 0)
end

function M:script_select(index)
    local select = optional_export("xcom_imgui_script_select")
    if select then select(index or -1) end
end

-- Editor save event (C++ -> Lua): returns path, text or nil.
function M:take_editor_save()
    local take = optional_export("xcom_imgui_script_take_editor_save")
    if not take then return nil end
    local path_buf = self._save_path_buf
    local text_buf = self._save_text_buf
    if not path_buf then
        path_buf = ffi.new("char[?]", 512)
        text_buf = ffi.new("char[?]", 65536)
        self._save_path_buf = path_buf
        self._save_text_buf = text_buf
    end
    if take(path_buf, 512, text_buf, 65536) == 0 then return nil end
    return ffi.string(path_buf), ffi.string(text_buf)
end

function M:set_status(text)
    self.lib.xcom_imgui_set_status(text or "")
end

function M:draw(connected, rx_bytes, tx_bytes)
    local actions = self.lib.xcom_imgui_draw_console(
        self.port, PORT_CAPACITY, connected and 1 or 0, rx_bytes or 0, tx_bytes or 0,
        self.baud, self.data_bits, self.stop_bits, self.parity, self.flow, self.dtr, self.rts,
        self.receive_hex, self.timestamp, self.pause_display, self.auto_clear, self.auto_clear_bytes,
        self.send, SEND_CAPACITY, self.send_hex, self.send_crlf, self.send_auto, self.send_period,
        self.multi_text, MULTI_SLOT_CAPACITY, self.multi_enabled, self.multi_hex, self.multi_crlf,
        self.multi_page, self.multi_page_count, self.multi_auto, self.multi_period, self.auto_save,
        nil, 0)
    -- Service a copy the user requested this frame (Ctrl+C / context menu):
    -- drain the native queue, apply the strip policy, write the clipboard.
    self:service_receive_copy()
    return actions
end

-- Read a C string from a fixed ffi char[N] buffer SAFELY: bounded (never
-- scans past the allocation, which is what crashed the app when ImGui left
-- the buffer unterminated at capacity) AND trimmed at the first NUL, because
-- ffi.string(buf, N) with an explicit length returns ALL N bytes including
-- the trailing padding -- sending "help\0\0\0..." to the wire.
local function cstr(buf, capacity)
    local s = ffi.string(buf, capacity)
    local z = s:find("\0", 1, true)
    if z then return s:sub(1, z - 1) end
    return s
end

function M:port_name()
    return cstr(self.port, PORT_CAPACITY)
end

function M:send_text()
    local s = cstr(self.send, SEND_CAPACITY)
    if _DEBUG then
        io.stderr:write(string.format("[dbg] send_text len=%d head=%q\n",
            #s, s:sub(1, 40)))
    end
    return s
end

function M:serial_config()
    -- A non-zero Custom value overrides the preset combo (clamped to the
    -- Win32 DCB-reasonable range; the core passes baud_rate straight through).
    -- Prefer the live DLL buffer (the user may have edited the field) and fall
    -- back to the load-time resolved override so a persisted non-preset baud
    -- survives even on a DLL without the set_baud_extra export.
    local custom = 0
    if self.baud_custom then
        custom = tonumber(self.baud_custom[0]) or 0
    end
    if custom < 300 and self._baud_override then
        custom = self._baud_override
    end
    -- Return the open-time tri-state as the last two values (0/1/2, see
    -- xcom_ffi.line_tristate).  Existing 7-value callers are unaffected:
    -- Lua simply discards extra results they do not name.
    if custom >= 300 then
        custom = math.min(custom, 3000000)
        return custom, self.data_bits[0] + 5,
            self.stop_bits[0], self.parity[0], self.flow[0],
            self.dtr[0] ~= 0, self.rts[0] ~= 0,
            self.dtr_open[0], self.rts_open[0]
    end
    return BAUD[self.baud[0] + 1] or 115200, self.data_bits[0] + 5,
        self.stop_bits[0], self.parity[0], self.flow[0], self.dtr[0] ~= 0, self.rts[0] ~= 0,
        self.dtr_open[0], self.rts_open[0]
end

function M:display_options()
    return self.receive_hex[0] ~= 0, self.timestamp[0] ~= 0,
        self.pause_display[0] ~= 0,
        self.auto_clear[0] ~= 0 and math.max(0, self.auto_clear_bytes[0]) or 0
end

function M:multi_entry(index)
    local offset = index * MULTI_SLOT_CAPACITY
    return cstr(self.multi_text + offset, MULTI_SLOT_CAPACITY),
        self.multi_enabled[index] ~= 0
end

function M:_store_page()
    local page = self.pages[self.multi_page[0] + 1]
    for index = 0, 7 do
        page.text[index + 1] = cstr(self.multi_text + index * MULTI_SLOT_CAPACITY,
                                    MULTI_SLOT_CAPACITY)
        page.enabled[index + 1] = self.multi_enabled[index] ~= 0
    end
end

function M:_load_page()
    local page = self.pages[self.multi_page[0] + 1]
    ffi.fill(self.multi_text, MULTI_SLOTS * MULTI_SLOT_CAPACITY, 0)
    for index = 0, 7 do
        local text = page.text[index + 1] or ""
        ffi.copy(self.multi_text + index * MULTI_SLOT_CAPACITY, text, math.min(#text, MULTI_SLOT_CAPACITY - 1))
        self.multi_enabled[index] = page.enabled[index + 1] and 1 or 0
    end
end

function M:change_page(delta)
    self:_store_page()
    self.multi_page[0] = math.max(0, math.min(self.multi_page_count[0] - 1, self.multi_page[0] + delta))
    self:_load_page()
end

function M:add_page()
    self:_store_page()
    if self.multi_page_count[0] >= 50 then return end
    table.insert(self.pages, { text = {}, enabled = {} })
    self.multi_page_count[0] = #self.pages
    self.multi_page[0] = #self.pages - 1
    self:_load_page()
end

function M:remove_page()
    if self.multi_page_count[0] <= 1 then return end
    self:_store_page()
    table.remove(self.pages, self.multi_page[0] + 1)
    self.multi_page_count[0] = #self.pages
    self.multi_page[0] = math.min(self.multi_page[0], #self.pages - 1)
    self:_load_page()
end

function M:set_pages(pages)
    if type(pages) ~= "table" or #pages == 0 then return end
    self.pages = pages
    self.multi_page_count[0] = #pages
    self.multi_page[0] = 0
    self:_load_page()
end

function M:set_ports(ports)
    if #ports == 0 then
        self.lib.xcom_imgui_set_ports(nil, 0)
        return
    end
    local names = ffi.new("const char *[?]", #ports)
    self._port_names = {}
    for index, port in ipairs(ports) do
        self._port_names[index] = port.name
        names[index - 1] = self._port_names[index]
    end
    self.lib.xcom_imgui_set_ports(names, #ports)
end

function M:wndproc(hwnd, msg, wparam, lparam)
    return self.lib.xcom_imgui_wndproc(hwnd, msg, wparam, lparam) ~= 0
end

function M:frame()
    return self.lib.xcom_imgui_new_frame() ~= 0
end

function M:render()
    return self.lib.xcom_imgui_render() ~= 0
end

function M:close()
    self.lib.xcom_imgui_shutdown()
end

-- The WndProc dispatch tree reaches this module's methods dynamically
-- (self.imgui:port_name() etc.), so per-method jit.off at the call sites in
-- window.lua cannot cover them; pin the whole method table off JIT here (see
-- the bad-callback analysis at the bottom of ui/window.lua).
if jit and jit.off then
    for _, fn in pairs(M) do
        if type(fn) == "function" then pcall(jit.off, fn) end
    end
end

return M
