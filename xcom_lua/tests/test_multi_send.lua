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
-- load time).
local fake_now = 1000000
package.preload["luv"] = function()
    return { now = function() return fake_now end }
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
        send_hex = ffi.new("int[1]", 0),
        send_crlf = ffi.new("int[1]", 0),
        pages = { { text = {}, enabled = {} } },
        multi_page = ffi.new("int[1]", 0),
        multi_page_count = ffi.new("int[1]", 1),
    }
    function b:set_slot(index, text)
        local off = index * MULTI_SLOT_CAPACITY
        ffi.fill(self.multi_text + off, MULTI_SLOT_CAPACITY, 0)
        ffi.copy(self.multi_text + off, text, math.min(#text, MULTI_SLOT_CAPACITY - 1))
    end
    function b:send_text() return "" end
    function b:multi_entry(index)
        local off = index * MULTI_SLOT_CAPACITY
        return cstr(self.multi_text + off, MULTI_SLOT_CAPACITY),
            self.multi_enabled[index] ~= 0
    end
    function b:_store_page()
        local page = self.pages[self.multi_page[0] + 1]
        for index = 0, 7 do
            page.text[index + 1] = cstr(self.multi_text + index * MULTI_SLOT_CAPACITY,
                                        MULTI_SLOT_CAPACITY)
            page.enabled[index + 1] = self.multi_enabled[index] ~= 0
        end
    end
    function b:_load_page()
        local page = self.pages[self.multi_page[0] + 1]
        ffi.fill(self.multi_text, MULTI_SLOTS * MULTI_SLOT_CAPACITY, 0)
        for index = 0, 7 do
            local text = page.text[index + 1] or ""
            ffi.copy(self.multi_text + index * MULTI_SLOT_CAPACITY, text,
                     math.min(#text, MULTI_SLOT_CAPACITY - 1))
            self.multi_enabled[index] = page.enabled[index + 1] and 1 or 0
        end
    end
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
-- J) page store/load round-trip preserves text + enabled
-- ===========================================================================
do
    local win = new_fake_window()
    win.imgui:set_slot(0, "page0")
    win.imgui.multi_enabled[0] = 1
    win.imgui.pages[2] = { text = {}, enabled = {} }
    win.imgui.multi_page_count[0] = 2
    win.imgui:_store_page()          -- save page 0
    win.imgui.multi_page[0] = 1
    win.imgui:_load_page()           -- load (empty) page 1
    local p1text, p1en = win.imgui:multi_entry(0)
    eq("J1 page1 text empty", p1text, "")
    ok("J2 page1 slot disabled", p1en == false)
    win.imgui.multi_page[0] = 0
    win.imgui:_load_page()           -- back to page 0
    local p0text, p0en = win.imgui:multi_entry(0)
    eq("J3 page0 text restored", p0text, "page0")
    ok("J4 page0 enabled restored", p0en == true)
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

print(string.format("\n%d passed, %d failed", pass_n, fail_n))
os.exit(fail_n == 0 and 0 or 1)
