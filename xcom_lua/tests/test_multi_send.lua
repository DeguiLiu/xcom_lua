-- test_multi_send.lua - offline audit for the Multi-tab "Send enabled" path
-- (IMGUI_ACTION.send_enabled -> Window:_imgui_send_enabled) plus the per-slot
-- send path (Alt+digit / per-row "N" button -> Window:_imgui_send_slot).
--
-- Bug being pinned: clicking "Send enabled" on the Multi tab sends nothing
-- (Single-tab Send works).  The C++ bridge hands Lua a raw char[8*512] slot
-- buffer (multi_text) plus an int[8] enabled mask; Lua's
-- ImGuiBridge:multi_entry(index) reads it back with a bounded cstr().  This
-- test reproduces the exact data flow WITHOUT the DLL: the fake bridge owns
-- REAL ffi buffers with the production capacities, and the REAL Window
-- methods are driven against a recording core_send.
--
-- FINDINGS (systematic audit, see sections A-J):
--   * The primary chain is CORRECT and pinned here: bit 32 dispatches
--     _imgui_send_enabled, slot arithmetic (index*512) matches on both sides,
--     text/enabled read back exactly, CRLF and HEX toggles behave.
--   * A headless ImGui repro (separate, not in this file) also confirmed the
--     C++ Multi tab writes typed text into the Lua buffer and the "Send"
--     button returns ActionSendEnabled (0x20) — so the reported no-send is
--     NOT in this path as the tree stands.
--   * The one real defect found is K/M: a whitespace-only HEX slot makes
--     build_send_payload return "" (a TRUTHY empty string), which passed the
--     `if payload` guard and reached core_send, where empty data is silently
--     dropped — indistinguishable from "clicked and nothing happened".
--     Fixed by guarding `payload ~= ""` in _imgui_send_enabled,
--     _imgui_send_slot and _on_alt_digit.
--
-- Runs on the Linux review host: luv is a Windows binary module, so it is
-- stubbed via package.preload, and win32.lua's DLL load() is patched off
-- (same harness as tests/test_rx_charset_batch.lua).
--
-- Usage: cd xcom_lua && luajit tests/test_multi_send.lua

package.path = "./ui/?.lua;./core/?.lua;" .. package.path

-- uv.now must be patched BEFORE window.lua is required (it captures luv at
-- load time).  new_timer is stubbed too: the sequential Run and auto-cycle
-- paths allocate real libuv timers, which do not exist on this host.  The fake
-- records start(initial, repeat, cb) and exposes fire() so a test can advance
-- the "self-rearming one-shot" by hand (repeat=0 is exactly the bug under test
-- in section U -- a one-shot timer that never re-arms).
local fake_now = 1000000
local fake_timers = {}
local FakeTimer = {}
FakeTimer.__index = FakeTimer
function FakeTimer:start(initial, repeat_ms, cb)
    self.initial, self.repeat_ms, self.cb = initial, repeat_ms, cb
end
function FakeTimer:stop() self.stopped = true end
function FakeTimer:close() self.closed = true end
function FakeTimer:fire()
    local cb = self.cb
    if cb then cb() end
end
local function new_fake_timer()
    local t = setmetatable({}, FakeTimer)
    fake_timers[#fake_timers + 1] = t
    return t
end

package.preload["luv"] = function()
    return { now = function() return fake_now end,
             new_timer = new_fake_timer }
end
local uv = require("luv")
uv.now = function() return fake_now end

-- win32.lua refuses to load its DLLs off Windows; patch load() on the REAL
-- module and stub the lazy handles this pure logic path never touches.
local real_win32 = require("win32")
real_win32.load = function() return true end
real_win32.kernel32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})
-- The legacy send-panel path (on_btn_send_enabled) reads its HEX/CRLF
-- checkboxes through controls.checkbox_checked, which goes to user32.  Without
-- this stub that path aborts on "attempt to index field 'user32'", so R7 could
-- never reach the assertion it exists for.
real_win32.user32 = setmetatable({}, {
    __index = function() return function() return 0 end end,
})

local ffi = require("ffi")
local window_mod = require("window")

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%q want=%q)", label, tostring(got), tostring(want)),
       got == want)
end

-- Production capacities (ui/imgui_bridge.lua).
local MULTI_SLOTS = 8
local MULTI_SLOT_CAPACITY = 512
local SEND_CAPACITY = 4096

-- cstr copy, mirroring imgui_bridge.lua's bounded + NUL-trimmed reader.
local function cstr(buf, capacity)
    local s = ffi.string(buf, capacity)
    local z = s:find("\0", 1, true)
    if z then return s:sub(1, z - 1) end
    return s
end

-- Fake bridge: REAL ffi buffers so the slot arithmetic under test is the same
-- one the DLL writes into.  Methods mirror imgui_bridge.lua exactly.
local function new_fake_bridge()
    local b = {
        multi_text = ffi.new("char[?]", MULTI_SLOTS * MULTI_SLOT_CAPACITY),
        multi_enabled = ffi.new("int[?]", MULTI_SLOTS),
        multi_hex = ffi.new("int[1]", 0),
        multi_crlf = ffi.new("int[1]", 0),
        multi_gap = ffi.new("int[1]", 100),
        multi_auto = ffi.new("int[1]", 0),
        multi_period = ffi.new("int[1]", 100),
        send = ffi.new("char[?]", SEND_CAPACITY),
        send_hex = ffi.new("int[1]", 0),
        send_crlf = ffi.new("int[1]", 0),
        send_auto = ffi.new("int[1]", 0),
        send_period = ffi.new("int[1]", 1000),
        pages = { { text = {}, enabled = {} } },
        multi_page = ffi.new("int[1]", 0),
        multi_page_count = ffi.new("int[1]", 1),
    }
    function b:set_slot(index, text)
        local off = index * MULTI_SLOT_CAPACITY
        ffi.fill(self.multi_text + off, MULTI_SLOT_CAPACITY, 0)
        ffi.copy(self.multi_text + off, text, math.min(#text, MULTI_SLOT_CAPACITY - 1))
    end
    function b:set_send(text)
        ffi.fill(self.send, SEND_CAPACITY, 0)
        ffi.copy(self.send, text, math.min(#text, SEND_CAPACITY - 1))
    end
    function b:send_text() return cstr(self.send, SEND_CAPACITY) end
    function b:set_status(text) self.last_status = text end
    function b:multi_entry(index)
        local off = index * MULTI_SLOT_CAPACITY
        return cstr(self.multi_text + off, MULTI_SLOT_CAPACITY),
            self.multi_enabled[index] ~= 0
    end
    -- NOTE: page store/load deliberately NOT reimplemented here.  The J section
    -- binds the REAL ui/imgui_bridge.lua methods onto a fake state table, so a
    -- copy of production logic in this test (which the audit showed could be
    -- deleted from production without failing anything) does not exist to go
    -- stale.  See new_page_bridge below.
    return b
end

local function new_fake_window()
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
    win.imgui = new_fake_bridge()
    win.core = true
    win.sent = {}
    function win:core_send(data_bytes, _flags)
        self.sent[#self.sent + 1] = data_bytes
        return true, nil
    end
    return win
end

-- ===========================================================================
-- A) action-bit wiring: bit 32 dispatches _imgui_send_enabled
-- ===========================================================================
do
    local win = new_fake_window()
    local called = 0
    function win:_imgui_send_enabled() called = called + 1 end
    win:_dispatch_imgui_actions(32)   -- IMGUI_ACTION.send_enabled
    eq("A1 bit32 reaches _imgui_send_enabled", called, 1)
    win:_dispatch_imgui_actions(8)    -- IMGUI_ACTION.send (single) must NOT
    eq("A2 bit8 does not call multi send", called, 1)
end

-- ===========================================================================
-- B) enabled + text -> sends that text
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "AT")
    win.imgui.multi_enabled[0] = 1
    win:_imgui_send_enabled()
    eq("B1 sends exactly one payload", #win.sent, 1)
    eq("B2 payload is the slot text", win.sent[1], "AT")
end

-- ===========================================================================
-- C) enabled + EMPTY text -> nothing (no empty payload)
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui.multi_enabled[0] = 1           -- enabled, but no text typed
    win:_imgui_send_enabled()
    eq("C1 empty enabled slot sends nothing", #win.sent, 0)
end

-- ===========================================================================
-- D) disabled + text -> nothing
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "AT")
    win.imgui.multi_enabled[0] = 0
    win:_imgui_send_enabled()
    eq("D1 disabled slot sends nothing", #win.sent, 0)
end

-- ===========================================================================
-- E) CRLF toggle
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(1, "PING")
    win.imgui.multi_enabled[1] = 1
    win.imgui.multi_crlf[0] = 1
    win:_imgui_send_enabled()
    eq("E1 crlf on appends CRLF", win.sent[1], "PING\r\n")
end

-- ===========================================================================
-- F) HEX toggle
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(2, "41 42 43")
    win.imgui.multi_enabled[2] = 1
    win.imgui.multi_hex[0] = 1
    win:_imgui_send_enabled()
    eq("F1 hex decodes the slot", win.sent[1], "ABC")
end

-- ===========================================================================
-- G) per-slot send addresses the right slot
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "zero")
    win.imgui:set_slot(5, "five")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_enabled[5] = 1
    win:_imgui_send_slot(5)
    eq("G1 slot 5 sends its own text", win.sent[1], "five")
    eq("G2 only one payload", #win.sent, 1)
end

-- ===========================================================================
-- G2) the per-row button does NOT require the enable tick
--     The enable toggle is the BULK selector ("发送" walks the ticked rows);
--     gating the per-row button on it made the button look dead on any
--     unticked row.  The bulk gate itself stays pinned by test D above -- this
--     block only covers the per-row path (and Alt+digit, which shares it).
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(2, "unticked-row")
    win.imgui.multi_enabled[2] = 0            -- deliberately NOT ticked
    win:_imgui_send_slot(2)
    eq("G2.1 unticked row still sends via the per-row button",
       win.sent[1], "unticked-row")
    eq("G2.2 exactly one payload", #win.sent, 1)
end

do
    local win = new_fake_window()
    win.imgui.multi_enabled[4] = 0            -- unticked AND empty
    win:_imgui_send_slot(4)
    eq("G2.3 unticked empty row sends nothing", #win.sent, 0)
end

-- ===========================================================================
-- H) Alt+digit fires the same slot as the row button
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(3, "alt3")
    win.imgui.multi_enabled[3] = 1
    local consumed = win:_on_alt_digit(0x33)  -- '3'
    ok("H1 alt digit consumed", consumed == true)
    eq("H2 alt3 sent slot 3", win.sent[1], "alt3")
end

-- ===========================================================================
-- I) slot 7 boundary (last slot) is reachable
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(7, "last")
    win.imgui.multi_enabled[7] = 1
    win:_imgui_send_enabled()
    eq("I1 slot 7 text readable + sent", win.sent[1], "last")
end

-- ===========================================================================
-- J) page store/load round-trip preserves text + enabled -- driven through the
--    REAL ui/imgui_bridge.lua methods.  A fake state table carries the same
--    ffi buffers M.new allocates; change_page/_store_page/_load_page/multi_entry
--    resolve to the production module via __index.  Deleting or breaking any of
--    them in production now fails here.  (Before: this section asserted a
--    line-for-line copy of those functions stored on the test's own fake, so
--    removing the production originals broke nothing -- the audit deleted all
--    three and the suite still reported 132 passed.)
-- ===========================================================================
do
    local ib = require("imgui_bridge")
    local has_pages = type(ib._store_page) == "function" and
        type(ib._load_page) == "function" and type(ib.change_page) == "function"
    -- Guarded so a DELETED production method is a clean FAIL below rather than a
    -- crash that aborts the remaining assertions.
    ok("J0 production page store/load/change_page exist", has_pages)
    local function new_page_bridge()
        return setmetatable({
            multi_text = ffi.new("char[?]", MULTI_SLOTS * MULTI_SLOT_CAPACITY),
            multi_enabled = ffi.new("int[?]", MULTI_SLOTS),
            multi_page = ffi.new("int[1]", 0),
            multi_page_count = ffi.new("int[1]", 2),
            pages = { { text = {}, enabled = {} }, { text = {}, enabled = {} } },
        }, { __index = ib })
    end
    if has_pages then
        local b = new_page_bridge()
        ffi.copy(b.multi_text, "page0", 5)   -- slot 0 of page 0 holds "page0"
        b.multi_enabled[0] = 1
        b:change_page(1)                      -- store page 0, load empty page 1
        local p1text, p1en = b:multi_entry(0)
        eq("J1 page1 text empty", p1text, "")
        ok("J2 page1 slot disabled", p1en == false)
        b:change_page(-1)                     -- store page 1, load page 0 back
        local p0text, p0en = b:multi_entry(0)
        eq("J3 page0 text restored", p0text, "page0")
        ok("J4 page0 enabled restored", p0en == true)
    end
end

-- ===========================================================================
-- K) whitespace-only HEX slot: build_send_payload returns "" (truthy).  The
--    send funnel must NOT hand an empty payload to core_send — an empty send
--    is silently discarded there, which reads to the user as "no reaction".
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "   ")      -- whitespace only
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_hex[0] = 1          -- HEX mode strips whitespace -> ""
    win:_imgui_send_enabled()
    eq("K1 whitespace-only HEX sends nothing", #win.sent, 0)
end

-- ===========================================================================
-- L) empty TEXT slot with CRLF on must not emit a bare newline
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "")           -- no text
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_crlf[0] = 1         -- CRLF on: build_send_payload("")="\r\n"
    win:_imgui_send_enabled()
    eq("L1 empty text + CRLF sends nothing", #win.sent, 0)
end

-- ===========================================================================
-- M) Alt+digit on a whitespace-only HEX slot also sends nothing
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(4, "  ")
    win.imgui.multi_enabled[4] = 1
    win.imgui.multi_hex[0] = 1
    ok("M1 alt4 consumed", win:_on_alt_digit(0x34) == true)
    eq("M2 whitespace-only HEX sends nothing", #win.sent, 0)
end

-- ===========================================================================
-- N) Baud preservation: a persisted NON-PRESET baud must not snap to 115200.
--    Pure resolver + the serial_config fallback used when the DLL has no
--    set_baud_extra cdata (or its "more" section is hidden).
-- ===========================================================================
do
    local ib = require("imgui_bridge")
    local idx, cust = ib.resolve_baud(250000, 0)
    eq("N1 non-preset baud parks on 115200 slot", idx, 7)
    eq("N2 non-preset baud carried as custom", cust, 250000)
    local idx2, cust2 = ib.resolve_baud(9600, 0)
    eq("N3 preset baud index", idx2, 3)
    eq("N4 preset baud no custom", cust2, 0)
    local _, cust3 = ib.resolve_baud(115200, 250000)
    eq("N5 explicit custom wins over preset", cust3, 250000)
    local _, cust4 = ib.resolve_baud(4000000, 0)
    eq("N6 out-of-range non-preset rejected", cust4, 0)
    local _, cust5 = ib.resolve_baud(250000, 500000)
    eq("N7 explicit custom preserved for non-preset", cust5, 500000)

    local fake = {
        baud = { [0] = 7 }, data_bits = { [0] = 3 }, stop_bits = { [0] = 0 },
        parity = { [0] = 0 }, flow = { [0] = 0 }, dtr = { [0] = 1 }, rts = { [0] = 0 },
        dtr_open = { [0] = 0 }, rts_open = { [0] = 0 },
        _baud_override = 250000,
    }
    eq("N8 serial_config returns preserved non-preset", ib.serial_config(fake), 250000)
    fake.baud_custom = { [0] = 0 }
    eq("N9 zero cdata falls back to override", ib.serial_config(fake), 250000)
    fake.baud_custom[0] = 500000
    eq("N10 live cdata custom wins", ib.serial_config(fake), 500000)
    fake.baud_custom[0] = 100
    eq("N11 cdata below floor ignored -> override", ib.serial_config(fake), 250000)

    -- serial_config now also carries the open-time tri-state LAST (0/1/2).
    -- The third state must survive the read-back instead of collapsing to 1,
    -- while the runtime dtr/rts toggles in the same record stay boolean.
    fake.dtr_open = { [0] = 2 }
    fake.rts_open = { [0] = 1 }
    local _, _, _, _, _, dtr, rts, dtr_open, rts_open = ib.serial_config(fake)
    eq("N12 open-time dtr LEAVE_ALONE read back", dtr_open, 2)
    eq("N13 open-time rts assert read back", rts_open, 1)
    eq("N14 runtime dtr stays boolean", dtr, true)
end

-- ===========================================================================
-- O) Drop/trim/pause status is routed to the ImGui status path (legacy
--    labels[3] is hidden under the dashboard, so a paused user saw nothing).
-- ===========================================================================
do
    local xcom = require("xcom_ffi")
    local win = new_fake_window()
    local snap = {
        port_state = 0, generation = 0, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 1, ui_trimmed_bytes = 5,
        save_rejected_bytes = 0, overrun_errors = 0, rx_backpressure_events = 0,
        framing_errors = 0, parity_errors = 0, break_events = 0,
        display_paused_bytes = 0, rx_loss_offset = 0, rx_sequence = 0,
    }
    local saved_gs, saved_te = xcom.get_snapshot, xcom.take_error
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end
    -- Isolate the status routing: the change-driven re-render touches native
    -- controls this headless fake does not own; the legacy status bar is a set
    -- of control handles (win32 stubbed, so set_text is a no-op here).
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end
    win:poll_status()
    rw.user32 = saved_user32
    xcom.get_snapshot, xcom.take_error = saved_gs, saved_te
    eq("O1 drop/trim status routed to ImGui path",
       win._status_dirty, "drops: 1  trim: 5  pause: 0")
end

-- ===========================================================================
-- P) Storage-stall banner attributes backpressure to the STORAGE side.  A
--    stalled write thread / dead disk fills the file lane; the old wording
--    ("host not draining") named the wrong cause.  Drive the real poll_status
--    twice so the per-session base is established and one episode is new.
-- ===========================================================================
do
    local xcom = require("xcom_ffi")
    local win = new_fake_window()
    local snap = {
        port_state = 0, generation = 0, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0, rx_backpressure_events = 0,
        framing_errors = 0, parity_errors = 0, break_events = 0,
        display_paused_bytes = 0, rx_loss_offset = 0, rx_sequence = 0,
    }
    local saved_gs, saved_te = xcom.get_snapshot, xcom.take_error
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end
    win:poll_status()                       -- base snapshot (0 episodes)
    snap.rx_backpressure_events = 1         -- one new storage-stall episode
    win:poll_status()
    rw.user32 = saved_user32
    xcom.get_snapshot, xcom.take_error = saved_gs, saved_te
    local banner = win._status_dirty
    ok("P1 stall banner names the storage side",
       banner ~= nil and banner:find("storage", 1, true) ~= nil)
    ok("P2 stall banner drops the false host-drain claim",
       banner ~= nil and banner:find("host not draining", 1, true) == nil)
    ok("P3 stall banner keeps the episode count",
       banner ~= nil and banner:find("x1", 1, true) ~= nil)
end

-- ===========================================================================
-- Q) No-log loss accounting: bytes dropped with no log open have no
--    authoritative copy, so they are charged to save_rejected_bytes and must
--    surface as DATA LOSS. Display backlog (rx_pool_exhausted_bytes) is NOT
--    loss: an open log still holds those bytes, so it must not raise the
--    banner. This is the distinction Finding 2 asked the UI to make visible.
-- ===========================================================================
do
    local xcom = require("xcom_ffi")
    local rw = require("win32")
    local saved_user32 = rw.user32
    rw.user32 = setmetatable({}, { __index = function() return function() return 0 end end })

    local snap = {
        port_state = 0, generation = 0, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0, rx_backpressure_events = 0,
        framing_errors = 0, parity_errors = 0, break_events = 0,
        display_paused_bytes = 0, rx_loss_offset = 0, rx_sequence = 0,
    }
    local saved_gs, saved_te = xcom.get_snapshot, xcom.take_error
    xcom.get_snapshot = function() return snap end
    xcom.take_error = function() return nil end

    local win = new_fake_window()
    win.status = { labels = { {}, {}, {}, {} } }
    win._render_ui_state = function() end
    win:poll_status()                       -- base snapshot (clean session)
    snap.save_rejected_bytes = 1234         -- 1234 B received but not stored
    win:poll_status()
    local banner = win._loss_banner or win._status_dirty
    ok("Q1 no-log loss raises the DATA LOSS banner",
       banner ~= nil and banner:find("DATA LOSS", 1, true) ~= nil)
    ok("Q2 no-log loss states the exact byte count",
       banner ~= nil and banner:find("1234", 1, true) ~= nil)
    ok("Q3 no-log loss is named, not mislabelled as display backlog",
       banner ~= nil and banner:find("received but not stored", 1, true) ~= nil)

    -- Pure display backlog must not masquerade as loss.
    local win2 = new_fake_window()
    win2.status = { labels = { {}, {}, {}, {} } }
    win2._render_ui_state = function() end
    local snap2 = {}
    for k, v in pairs(snap) do snap2[k] = v end
    snap2.save_rejected_bytes = 0
    snap2.rx_pool_exhausted_bytes = 0
    xcom.get_snapshot = function() return snap2 end
    win2:poll_status()
    snap2.rx_pool_exhausted_bytes = 500      -- backlog an open log still holds
    win2:poll_status()
    ok("Q4 display backlog alone does not raise DATA LOSS",
       win2._loss_banner == nil)

    rw.user32 = saved_user32
    xcom.get_snapshot, xcom.take_error = saved_gs, saved_te
end

-- ===========================================================================
-- R) Refused sends must be counted as FAILED, not sent.  core_send returns
--    (false, rc) when the port is FAULT / not open; the old loop discarded it
--    and did `sent = sent + 1` unconditionally, so a batch that put nothing on
--    the wire looked successful and suppressed every no-send hint.
-- ===========================================================================
do
    local xcom = require("xcom_ffi")

    local function failing_window()
        local win = new_fake_window()
        win.core_send = function(self, data_bytes, _flags)
            return false, xcom.err_not_open
        end
        return win
    end

    -- R1/R2: every enabled slot refused -> zero sent, explicit failure count.
    local win = failing_window()
    win.imgui:set_slot(0, "A")
    win.imgui:set_slot(1, "B")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_enabled[1] = 1
    win:_imgui_send_enabled()
    eq("R1 refused slots are not counted as sent", #win.sent, 0)
    ok("R2 status reports the refused slot count",
       win._status_dirty ~= nil and
       win._status_dirty:find("2 slot(s) not sent", 1, true) ~= nil)

    -- R3/R4/R5: partial failure reports the refused count, keeps the sent one.
    local ok_n = 0
    local win2 = new_fake_window()
    win2.core_send = function(self, data_bytes, _flags)
        ok_n = ok_n + 1
        if ok_n == 1 then
            self.sent[#self.sent + 1] = data_bytes
            return true, nil
        end
        return false, xcom.err_not_open
    end
    win2.imgui:set_slot(0, "A")
    win2.imgui:set_slot(1, "B")
    win2.imgui.multi_enabled[0] = 1
    win2.imgui.multi_enabled[1] = 1
    win2:_imgui_send_enabled()
    eq("R3 one accepted one refused -> one sent", #win2.sent, 1)
    ok("R4 partial failure reports the refused count",
       win2._status_dirty ~= nil and
       win2._status_dirty:find("1 slot(s) not sent", 1, true) ~= nil)

    -- R5/R6: per-slot send surfaces the refusal and names the slot.
    local win3 = failing_window()
    win3.imgui:set_slot(5, "five")
    win3.imgui.multi_enabled[5] = 1
    win3:_imgui_send_slot(5)
    ok("R5 per-slot refusal is surfaced",
       win3._status_dirty ~= nil and
       win3._status_dirty:find("not sent", 1, true) ~= nil)
    ok("R6 per-slot refusal names the slot",
       win3._status_dirty ~= nil and
       win3._status_dirty:find("slot 6", 1, true) ~= nil)

    -- R7: the legacy "Send enabled" button also counts refusals.
    local win4 = failing_window()
    local entry = { text = "A", enabled = true }
    win4.send = {
        multi = { entries = { entry }, hex = { hwnd = 1 }, crlf = { hwnd = 2 } },
        -- send_panel.lua defines these as sp.entry_enabled(i) / sp.entry_text(i):
        -- ONE parameter, no self.  A (_, i) stub would leave `i` nil and skip
        -- every entry, making this assertion pass vacuously.
        entry_enabled = function(i) return i == 0 end,
        entry_text = function(i) return i == 0 and "A" or "" end,
    }
    win4:on_btn_send_enabled()
    ok("R7 legacy button surfaces the refusal count",
       win4._status_dirty ~= nil and
       win4._status_dirty:find("1 slot(s) not sent", 1, true) ~= nil)
end

-- ===========================================================================
-- S) Live DTR/RTS hot switch (poll_status).  Under RTS/CTS flow control the
--    driver owns RTS, so xcom_set_lines applies DTR FIRST and then ALWAYS
--    reports XCOM_ERR_UNSUPPORTED for the RTS half -- for rts=0 as well as
--    rts=1, and never XCOM_OK (xcom_abi.cpp:552-569).  The code therefore
--    means "DTR applied, RTS not applied", which is a PARTIAL SUCCESS and must
--    not be shown as an error.  The stubs below emulate exactly that contract;
--    an older stub that returned OK for rts=0 would still pass these
--    assertions on text alone, so it must not be restored -- it would stop
--    pinning the difference between the two contracts.
--    The old Lua code also reset the change mirrors to nil on error, re-firing
--    the same failing call + status every 250 ms poll.
-- ===========================================================================
do
    local xcom = require("xcom_ffi")
    local clean_snap = {
        port_state = 0, generation = 0, rx_bytes = 0, tx_bytes = 0,
        rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
        save_rejected_bytes = 0, overrun_errors = 0, rx_backpressure_events = 0,
        framing_errors = 0, parity_errors = 0, break_events = 0,
        display_paused_bytes = 0, rx_loss_offset = 0, rx_sequence = 0,
    }
    local saved_gs, saved_te, saved_sl = xcom.get_snapshot, xcom.take_error, xcom.set_lines

    local function hotswap_window(set_lines)
        local win = new_fake_window()
        win.imgui.dtr = ffi.new("int[1]", 0)
        win.imgui.rts = ffi.new("int[1]", 0)
        win.imgui.flow = ffi.new("int[1]", 0)
        win.status = { labels = { {}, {}, {}, {} } }
        win._render_ui_state = function() end
        -- Pre-seed the steady-state drop/error ledgers so poll_status does not
        -- emit its own informational status line and mask the DTR/RTS one.
        win._last_drops, win._last_trim, win._last_paused = 0, 0, 0
        win._bp_seen = 0
        xcom.get_snapshot = function() return clean_snap end
        xcom.take_error = function() return nil end
        xcom.set_lines = set_lines
        return win
    end

    -- The fake snapshot reports the port CLOSED, so on_snapshot would drop the
    -- HSM out of OPEN after the first poll; re-assert OPEN before each poll so
    -- the live DTR/RTS block under test is actually exercised.
    local function poll(win)
        win.vm.hsm.state = win.vm.STATE_OPEN
        win:poll_status()
    end

    -- S1/S2: HW flow control + RTS box checked.  The Lua side must ask only for
    -- the DTR half (rts=false), so the ABI guard is not tripped and DTR applies;
    -- and it must NOT re-call / re-report on the next poll.
    local calls = {}
    local win = hotswap_window(function(_, dtr, rts)
        calls[#calls + 1] = { dtr = dtr, rts = rts }
        -- New contract: DTR is applied and UNSUPPORTED is returned for the RTS
        -- half whatever the rts value is.  It is never XCOM_OK.
        return xcom.err_unsupported
    end)
    win.imgui.flow[0] = 1
    win.imgui.rts[0] = 1
    win.imgui.dtr[0] = 0
    poll(win)
    eq("S1 HW flow control sends RTS as false (DTR half only)", calls[1].rts, false)
    eq("S1b DTR half still requested", calls[1].dtr, false)
    ok("S2 checked RTS under HW flow is explained",
       win._status_dirty ~= nil and
       win._status_dirty:find("HW flow control", 1, true) ~= nil)
    win._status_dirty = nil
    poll(win)                                   -- unchanged UI, 250 ms later
    eq("S3 unchanged UI is not re-sent", #calls, 1)
    ok("S4 unchanged UI does not re-flash the status", win._status_dirty == nil)

    -- S5: with RTS checked under HW flow, changing only DTR must still reach the
    -- wire (the reported symptom was "DTR checkbox does nothing").
    win.imgui.dtr[0] = 1
    poll(win)
    eq("S5 DTR change under HW flow re-sends", #calls, 2)
    eq("S5b second call carries the new DTR", calls[2].dtr, true)
    eq("S5c and still withholds RTS", calls[2].rts, false)
    -- The call returned XCOM_ERR_UNSUPPORTED, but that is a PARTIAL SUCCESS
    -- ("DTR applied, RTS driver-owned"), not a failure: the change did reach the
    -- wire, so the "not applied" error must not appear.
    ok("S5d the partial success is NOT reported as an error",
       win._status_dirty == nil or
       win._status_dirty:find("not applied", 1, true) == nil)

    -- S5d..S5f: an RTS-only change under HW flow must NOT poke the driver-owned
    -- pin (there is nothing to apply) but must still explain itself once.
    local calls5d = {}
    local win5d = hotswap_window(function(_, dtr, rts)
        calls5d[#calls5d + 1] = { dtr = dtr, rts = rts }
        return xcom.err_unsupported
    end)
    win5d.imgui.flow[0] = 1
    poll(win5d)                                   -- reconcile DTR=0 / RTS=0
    eq("S5d initial reconcile is one call", #calls5d, 1)
    win5d._status_dirty = nil
    win5d.imgui.rts[0] = 1                        -- RTS-only edge, DTR unchanged
    poll(win5d)
    eq("S5e RTS-only edge under HW flow does not call set_lines", #calls5d, 1)
    ok("S5f RTS-only edge under HW flow is explained once",
       win5d._status_dirty ~= nil and
       win5d._status_dirty:find("HW flow control", 1, true) ~= nil)
    win5d._status_dirty = nil
    poll(win5d)
    ok("S5g the explanation is not re-flashed", win5d._status_dirty == nil)

    -- S6: no flow control, RTS toggled -> one call carrying rts=true, no repeat.
    local calls6 = {}
    local win6 = hotswap_window(function(_, dtr, rts)
        calls6[#calls6 + 1] = { dtr = dtr, rts = rts }
        return xcom.ok
    end)
    win6.imgui.rts[0] = 1
    win6.imgui.dtr[0] = 1
    poll(win6)
    eq("S6 no-flow RTS is applied once", #calls6, 1)
    eq("S6b RTS reaches the ABI as true", calls6[1].rts, true)
    poll(win6)
    eq("S6c no repeat without a UI edge", #calls6, 1)

    -- S7/S8: a rejected call is reported once and not retried every poll.
    local calls7 = {}
    local win7 = hotswap_window(function(_, dtr, rts)
        calls7[#calls7 + 1] = { dtr = dtr, rts = rts }
        return xcom.err_unsupported
    end)
    win7.imgui.dtr[0] = 1
    poll(win7)
    ok("S7 rejection is reported",
       win7._status_dirty ~= nil and
       win7._status_dirty:find("not applied", 1, true) ~= nil)
    win7._status_dirty = nil
    poll(win7)
    eq("S8 rejection is not retried every poll", #calls7, 1)
    ok("S8b rejection is not re-flashed every poll", win7._status_dirty == nil)

    xcom.get_snapshot, xcom.take_error, xcom.set_lines = saved_gs, saved_te, saved_sl
end

-- ===========================================================================
-- T) Line errors (frame/parity/overrun/break) must be session-relative and
--    PERSISTENTLY visible, and must not be suppressed by the DATA LOSS banner
--    (different fault: far end / wiring vs driver dropping bytes).  The old
--    code summed the GLOBAL counters, wrote one set_status_deferred that the
--    next status producer overwrote, and skipped the notice entirely while a
--    loss banner was latched.
-- ===========================================================================
do
    local xcom = require("xcom_ffi")
    local saved_gs, saved_te, saved_sl = xcom.get_snapshot, xcom.take_error, xcom.set_lines
    local snap
    local function line_window()
        snap = {
            port_state = 0, generation = 0, rx_bytes = 0, tx_bytes = 0,
            rx_pool_exhausted_bytes = 0, tx_rejected = 0, ui_trimmed_bytes = 0,
            save_rejected_bytes = 0, overrun_errors = 0, rx_backpressure_events = 0,
            framing_errors = 0, parity_errors = 0, break_events = 0,
            display_paused_bytes = 0, rx_loss_offset = 0, rx_sequence = 0,
        }
        local win = new_fake_window()
        win.vm.hsm.state = win.vm.STATE_OPEN
        win.status = { labels = { {}, {}, {}, {} } }
        win._render_ui_state = function() end
        win._last_drops, win._last_trim, win._last_paused = 0, 0, 0
        win._bp_seen = 0
        xcom.get_snapshot = function() return snap end
        xcom.take_error = function() return nil end
        xcom.set_lines = function() return xcom.ok end
        return win
    end

    -- Keep the HSM in OPEN across polls (the fake snapshot is CLOSED, which
    -- on_snapshot would otherwise latch).
    local function poll(win)
        win.vm.hsm.state = win.vm.STATE_OPEN
        win:poll_status()
    end

    -- T1..T4: a parity/frame storm raises the banner and keeps re-pushing it.
    local win = line_window()
    poll(win)                               -- baseline: clean session
    ok("T1 clean session has no line banner", win._line_banner == nil)
    snap.framing_errors = 3
    snap.parity_errors = 5
    poll(win)
    ok("T2 banner names the per-kind counts",
       win._line_banner ~= nil and
       win._line_banner:find("frame 3", 1, true) ~= nil and
       win._line_banner:find("parity 5", 1, true) ~= nil)
    ok("T3 banner reaches the status slot",
       win._status_dirty ~= nil and
       win._status_dirty:find("LINE ERRORS", 1, true) ~= nil)
    win._status_dirty = nil                 -- simulate the frame commit
    poll(win)
    ok("T4 banner is re-pushed every poll (not one-shot)",
       win._status_dirty ~= nil and
       win._status_dirty:find("LINE ERRORS", 1, true) ~= nil)

    -- T5/T6: session-relative - a pre-existing global count is the baseline,
    -- only the delta since this open is shown.
    local win5 = line_window()
    snap.framing_errors = 100               -- already high when the port opened
    poll(win5)                              -- baseline latched
    snap.framing_errors = 103
    poll(win5)
    ok("T5 delta since open is shown",
       win5._line_banner ~= nil and
       win5._line_banner:find("frame 3", 1, true) ~= nil)
    ok("T6 absolute monotonic count is not shown",
       win5._line_banner ~= nil and
       win5._line_banner:find("frame 103", 1, true) == nil)

    -- T7/T8: DATA LOSS must NOT suppress the line breakdown; both are shown.
    local win7 = line_window()
    poll(win7)                              -- baseline (overrun 0)
    snap.overrun_errors = 1                 -- driver loss event...
    snap.parity_errors = 7                  -- ...alongside a parity storm
    poll(win7)
    local shown = win7._status_dirty
    ok("T7 loss + line errors are shown together",
       shown ~= nil and shown:find("DATA LOSS", 1, true) ~= nil and
       shown:find("LINE ERRORS", 1, true) ~= nil)
    ok("T8 neither fault is dropped from the combined banner",
       shown ~= nil and shown:find("overrun", 1, true) ~= nil and
       shown:find("parity 7", 1, true) ~= nil)

    xcom.get_snapshot, xcom.take_error, xcom.set_lines = saved_gs, saved_te, saved_sl
end

-- ===========================================================================
-- U..H) Sequential Run + auto-cycle: the batch-sender defects (gap=0, refused
--    sends swallowed, whitespace/invalid HEX silently skipped, encoding and
--    page read live mid-flight) and the two batch senders running together.
--    These drive the REAL Window methods; the libuv timer is the FakeTimer
--    installed in the luv preload above, advanced by fire().
-- ===========================================================================
local function run_sequence(win)
    win:_imgui_run_sequence()
    local guard = 0
    while win._sequence_timer and guard < 64 do
        guard = guard + 1
        win._sequence_timer:fire()
    end
end

-- U) gap=0: libuv treats repeat=0 as a ONE-SHOT timer, so only the first entry
--    was sent and _sequence_timer stayed non-nil (Run never flipped back).
--    The gap must be clamped so the timer actually repeats.
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "A")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_gap[0] = 0
    win:_imgui_run_sequence()
    local t = win._sequence_timer
    ok("U1 gap=0 still arms a sequence timer", t ~= nil)
    ok("U2 repeat is clamped to a repeating timer (>=1)",
       t ~= nil and t.repeat_ms ~= nil and t.repeat_ms >= 1)
    win:_stop_sequence()
end

-- V) A refused core_send (port FAULT / not open) must abort the sequence with
--    the failing line named; the remaining entries must NOT be attempted, and
--    the run must not end on "sequence done".
do
    local xcom = require("xcom_ffi")
    local win = new_fake_window()
    local n = 0
    win.core_send = function(self, data, _flags)
        n = n + 1
        if n == 1 then
            self.sent[#self.sent + 1] = data
            return true, nil
        end
        return false, xcom.err_not_open
    end
    for i = 0, 2 do
        win.imgui:set_slot(i, string.char(65 + i))   -- "A","B","C"
        win.imgui.multi_enabled[i] = 1
    end
    run_sequence(win)
    eq("V1 refused send aborts after the accepted entry", #win.sent, 1)
    ok("V2 abort names the failing line", win._status_dirty ~= nil and
       win._status_dirty:find("stopped at 2", 1, true) ~= nil)
    ok("V3 abort says the send failed", win._status_dirty ~= nil and
       win._status_dirty:find("send failed", 1, true) ~= nil)
    eq("V4 sequence timer released after abort", win._sequence_timer, nil)
end

-- W) A sequence row that cannot produce a payload (invalid HEX -> nil,
--    whitespace-only HEX -> "") must be skipped AND named, even when other
--    rows did send.
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "41")   -- valid -> "A"
    win.imgui:set_slot(1, "ZZ")   -- invalid HEX
    win.imgui:set_slot(2, "42")   -- valid -> "B"
    for i = 0, 2 do win.imgui.multi_enabled[i] = 1 end
    win.imgui.multi_hex[0] = 1
    run_sequence(win)
    eq("W1 valid rows still send around the invalid one", #win.sent, 2)
    eq("W2 invalid row is skipped, not mis-sent", win.sent[2], "B")
    ok("W3 skipped invalid-HEX row is named", win._status_dirty ~= nil and
       win._status_dirty:find("line 2", 1, true) ~= nil and
       win._status_dirty:find("invalid HEX", 1, true) ~= nil)

    local win2 = new_fake_window()
    win2.imgui:set_slot(0, "   ")  -- whitespace-only HEX -> "" (truthy)
    win2.imgui:set_slot(1, "41")
    win2.imgui.multi_enabled[0] = 1
    win2.imgui.multi_enabled[1] = 1
    win2.imgui.multi_hex[0] = 1
    run_sequence(win2)
    eq("W4 blank HEX row is not sent", #win2.sent, 1)
    ok("W5 blank HEX row is reported", win2._status_dirty ~= nil and
       win2._status_dirty:find("blank HEX", 1, true) ~= nil)
end

-- X) Encoding is snapshotted with the texts: flipping HEX mid-sequence must
--    not make the second half encode differently from the first.
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "41")
    win.imgui:set_slot(1, "42")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_enabled[1] = 1
    win.imgui.multi_hex[0] = 0
    win:_imgui_run_sequence()
    local t = win._sequence_timer
    t:fire()
    win.imgui.multi_hex[0] = 1      -- flip mid-flight
    t:fire()
    eq("X1 first entry uses the start-time encoding", win.sent[1], "41")
    eq("X2 later entry ignores the mid-sequence HEX toggle", win.sent[2], "42")
end

-- Y) Disconnect (fault edge) stops BOTH batch senders and says why.
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "A")
    win.imgui:set_slot(1, "B")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_enabled[1] = 1
    win:_imgui_run_sequence()
    ok("Y0 sequence active before disconnect", win._sequence_timer ~= nil)
    win._multi_timer = uv.new_timer()
    win._multi_timer:start(10, 10, function() end)
    win.connected = true
    win.conn = {}
    win._flush_rx_lines = function() end
    win.vm.ui_state = function()
        return { connected = false, params_enabled = true, open_enabled = true,
                 close_enabled = false, send_enabled = false,
                 autosend_enabled = false }
    end
    win:_render_ui_state()
    eq("Y1 disconnect stops the sequence", win._sequence_timer, nil)
    ok("Y2 disconnect stops the auto-cycle timer",
       win._multi_timer.stopped == true)
    ok("Y3 stop reason is stated", win._status_dirty ~= nil and
       win._status_dirty:find("port closed", 1, true) ~= nil)
end

-- Z) Close edges share one choke point (core_close, reached by _imgui_close
--    and on_btn_close): both batch senders are stopped.
do
    local xcom = require("xcom_ffi")
    local win = new_fake_window()
    win.imgui:set_slot(0, "A")
    win.imgui:set_slot(1, "B")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_enabled[1] = 1
    win:_imgui_run_sequence()
    win._multi_timer = uv.new_timer()
    win._multi_timer:start(10, 10, function() end)
    win.vm.intent_close = function() return true end
    win._render_ui_state = function() end
    win.poll_status = function() end
    local saved_close = xcom.close
    xcom.close = function() end
    win:core_close(2000)
    xcom.close = saved_close
    eq("Z1 close stops the sequence", win._sequence_timer, nil)
    ok("Z2 close stops the auto-cycle timer", win._multi_timer.stopped == true)
end

-- AA) A refused send must reach the VISIBLE status channel, not the hidden
--    legacy Win32 label[3].  core_send with a refusing ABI is the real method.
do
    local xcom = require("xcom_ffi")
    local win = new_fake_window()
    win.core_send = nil                 -- fall back to Window:core_send
    local saved_send = xcom.send
    xcom.send = function() return xcom.err_not_open end
    local okk, rc = win:core_send("AB", xcom.send_text)
    xcom.send = saved_send
    eq("AA1 core_send reports the refusal", okk, false)
    eq("AA2 refusal carries the status code", rc, xcom.err_not_open)
    ok("AA3 refusal reaches the visible ImGui status",
       win.imgui.last_status ~= nil and
       win.imgui.last_status:find("send failed", 1, true) ~= nil)
end

do
    local win = new_fake_window()
    win.imgui:set_send("ZZ")
    win.imgui.send_hex[0] = 1
    win:_imgui_send_single()
    ok("AA4 single invalid HEX is reported", win._status_dirty ~= nil and
       win._status_dirty:find("invalid HEX", 1, true) ~= nil)
    eq("AA5 single invalid HEX sends nothing", #win.sent, 0)
end

-- AB) Static structural pin for the C++ bridge (this host cannot compile it):
--    TransmitContent must take a send-availability flag and gate the send
--    controls on it, and draw_console must pass `connected` down as that flag.
do
    local f = io.open("native/xcom_imgui/xcom_imgui_bridge.cpp", "rb")
    local src = f and f:read("*a")
    if f then f:close() end
    ok("AB1 bridge source is readable for a static check", src ~= nil)
    ok("AB2 TransmitContent takes a send-availability flag",
       src ~= nil and src:find("const bool send_ok)", 1, true) ~= nil)
    ok("AB3 send controls are gated with BeginDisabled(!send_ok)",
       src ~= nil and src:find("BeginDisabled(!send_ok)", 1, true) ~= nil)
    ok("AB4 draw_console passes connected as send availability",
       src ~= nil and
       src:find("multi_auto, multi_period, connected != 0)", 1, true) ~= nil)
end

-- AC) Auto-cycle snapshots the page (texts + encoding) when it starts, like Run,
--    so a page switch mid-cycle cannot change the in-flight batch.
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "OLD")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_auto[0] = 1
    win:_sync_imgui_multi_auto()
    ok("AC0 auto-cycle timer armed", win._multi_timer ~= nil)
    win.imgui:set_slot(0, "NEW")     -- user flips the page mid-cycle
    win.imgui.multi_enabled[0] = 1
    win._multi_timer:fire()          -- one auto-cycle tick
    eq("AC1 auto-cycle sends the start-time page snapshot", win.sent[1], "OLD")
end

do
    local win = new_fake_window()
    win.imgui:set_slot(0, "41")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_hex[0] = 0
    win.imgui.multi_auto[0] = 1
    win:_sync_imgui_multi_auto()
    win.imgui.multi_hex[0] = 1        -- encoding toggle mid-cycle
    win._multi_timer:fire()
    eq("AC2 auto-cycle snapshots the start-time encoding", win.sent[1], "41")
end

-- AD) Batch-vs-batch interlock: the auto-cycle and the sequential Run must
--    never be active at once.  The late starter is REFUSED with a message and
--    the running one is left alone (no silent stop).
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "A")
    win.imgui:set_slot(1, "B")
    win.imgui.multi_enabled[0] = 1
    win.imgui.multi_enabled[1] = 1
    win.imgui.multi_auto[0] = 1
    win:_sync_imgui_multi_auto()
    ok("AD0 auto-cycle active", win._multi_timer ~= nil)
    win:_imgui_run_sequence()
    eq("AD1 Run is refused while auto-cycle runs", win._sequence_timer, nil)
    ok("AD2 refusal names the running auto-cycle", win._status_dirty ~= nil and
       win._status_dirty:find("auto-cycle", 1, true) ~= nil)
    ok("AD3 auto-cycle is not silently stopped",
       win._multi_timer ~= nil and win._multi_timer.stopped ~= true)

    local win2 = new_fake_window()
    win2.imgui:set_slot(0, "A")
    win2.imgui:set_slot(1, "B")
    win2.imgui.multi_enabled[0] = 1
    win2.imgui.multi_enabled[1] = 1
    win2.imgui.multi_gap[0] = 100
    win2:_imgui_run_sequence()
    ok("AD4 sequence active", win2._sequence_timer ~= nil)
    win2.imgui.multi_auto[0] = 1
    win2:_sync_imgui_multi_auto()
    eq("AD5 auto-cycle is refused while sequence runs", win2._multi_timer, nil)
    ok("AD6 refusal names the running sequence", win2._status_dirty ~= nil and
       win2._status_dirty:find("sequence", 1, true) ~= nil)
    eq("AD7 toggle is cleared so the UI shows no start",
       win2.imgui.multi_auto[0], 0)
end

-- ===========================================================================
-- AE) Script-stream publication: send_file's chunked send marks its record via
--     sys.busy for the WHOLE state.running lifetime (including the gap where
--     its one-shot timer is momentarily stopped between async reads), and the
--     engine surfaces that through any_script_busy().
-- ===========================================================================
do
    local se = require("script_engine")
    local engine = se.new({})
    engine.scripts = {
        ["send_file.lua"] = { enabled = true, busy = false },
        ["other.lua"] = { enabled = true, busy = false },
    }
    eq("AE1 no stream -> not busy", engine:any_script_busy(), false)
    engine:set_script_busy("send_file.lua", true)
    eq("AE2 stream published -> busy", engine:any_script_busy(), true)
    engine:set_script_busy("send_file.lua", false)
    eq("AE3 stream cleared -> not busy", engine:any_script_busy(), false)

    -- A disabled script's stale flag must not latch the interlock shut: the
    -- engine ignores records that are not enabled.
    engine:set_script_busy("send_file.lua", true)
    engine.scripts["send_file.lua"].enabled = false
    eq("AE4 disabled script's flag is ignored", engine:any_script_busy(), false)

    -- Unknown script name is a no-op, not an error.
    engine:set_script_busy("missing.lua", true)
    eq("AE5 unknown script does not crash or latch",
       engine:any_script_busy(), false)
end

-- ===========================================================================
-- AF) Window interlock: while a script streams (send_file), Run and auto-cycle
--     refuse to start and say so; the file send itself is left alone.  An idle
--     script must not block the batch senders.
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "A")
    win.imgui.multi_enabled[0] = 1
    win.scripts = { any_script_busy = function() return true end }
    win:_imgui_run_sequence()
    eq("AF1 Run refused while a file send streams", win._sequence_timer, nil)
    ok("AF2 refusal names the file send", win._status_dirty ~= nil and
       win._status_dirty:find("file send", 1, true) ~= nil)

    local win2 = new_fake_window()
    win2.imgui:set_slot(0, "A")
    win2.imgui.multi_enabled[0] = 1
    win2.imgui.multi_auto[0] = 1
    win2.scripts = { any_script_busy = function() return true end }
    win2:_sync_imgui_multi_auto()
    eq("AF3 auto-cycle refused while a file send streams",
       win2._multi_timer, nil)
    eq("AF4 toggle is cleared so the UI shows no start",
       win2.imgui.multi_auto[0], 0)
    ok("AF5 refusal names the file send", win2._status_dirty ~= nil and
       win2._status_dirty:find("file send", 1, true) ~= nil)

    -- Not streaming -> batch senders start normally.
    local win3 = new_fake_window()
    win3.imgui:set_slot(0, "A")
    win3.imgui.multi_enabled[0] = 1
    win3.scripts = { any_script_busy = function() return false end }
    win3:_imgui_run_sequence()
    ok("AF6 idle script does not block Run", win3._sequence_timer ~= nil)
    win3:_stop_sequence()

    -- send_file source pins the publication to the real lifecycle.  This host
    -- has no Lua runtime able to load the plugin (it needs ui/sys/uart/log
    -- globals injected by the engine), so the strongest available check is that
    -- busy is set in BOTH entry points (Send + Resume) and cleared only in the
    -- single stop_running choke point.
    local f = io.open("scripts/send_file.lua", "rb")
    local src = f and f:read("*a")
    if f then f:close() end
    ok("AF7 send_file source readable", src ~= nil)
    if src then
        -- Count CALL SITES, not text.  A comment that merely names
        -- sys.busy(true) is not a publication, and this check was in fact
        -- broken by exactly that: an explanatory comment quoting the call
        -- pushed n_true to 3 while the code still had its intended two.
        -- Strip line comments first (send_file.lua has no long strings, so a
        -- per-line strip cannot cut into a literal).
        local code = src:gsub("%-%-[^\n]*", "")
        local _, n_true = code:gsub("sys%.busy%(true%)", "")
        local _, n_false = code:gsub("sys%.busy%(false%)", "")
        eq("AF8 start and resume both publish busy", n_true, 2)
        eq("AF9 stop_running clears busy (single choke point)", n_false, 1)
    end
end

-- ===========================================================================
-- AG) Hidden status label: every ImGui-reachable status producer must route
--     through the visible channel, not the legacy Win32 labels[3].  The
--     autosend-invalid case is the one the previous round missed.
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_send("ZZ")
    win.imgui.send_hex[0] = 1
    win.imgui.send_auto[0] = 1
    win:_sync_imgui_autosend()
    eq("AG1 invalid autosend payload unchecks the toggle",
       win.imgui.send_auto[0], 0)
    ok("AG2 invalid autosend reaches the visible status",
       win.imgui.last_status ~= nil and
       win.imgui.last_status:find("autosend payload invalid", 1, true) ~= nil)
end

print(string.format("\n%d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
