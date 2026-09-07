--[[--------------------------------------------------------------------------
core/serial_sim.lua - hardware-free serial DATA simulator (Lua-side pump).

Purpose: this dev machine has no real COM ports.  xcom_core.dll, however,
already supports hardware-free sessions: a port name matching the C-side
is_virtual_port rule (xcom_abi.cpp: exact "VIRTUAL" or the "TEST" prefix)
opens an in-process session whose owner_open skips the Win32 backend, and
xcom_test_inject_rx (core/xcom_ffi.lua, `test_inject_rx`) feeds bytes into
the REAL rx_ingress -> display pipeline.  This module pumps generated
traffic through that seam so every downstream UI feature (hex view,
timestamps, pause, charset, auto-save, script hooks, ImPlot scope, the
send_file flow) can be exercised without hardware.

It never touches the display path itself: bytes go in at the same entry
point the serial callback uses (tests/stress_fullband.lua is the reference
pattern) and come back out through Window:poll_display().

Design notes:
  * available() auto-activates only when xcom.list_ports() returns an EMPTY
    list (registry-only enumeration -> machines with real ports keep
    bit-identical behaviour; window.lua gates every call site on that flag).
  * start() arms a 20 ms luv timer; each tick converts rate*dt into a byte
    budget, slices the active generator's stream, and injects.  A failed
    inject (port not OPEN yet / rx pool full -> XCOM_ERR_NOT_OPEN/ERR_IO)
    parks the bytes in an ordered pending ring (capped; oldest dropped on
    overflow with a counted total) that drains first on the next tick.
  * stop-before-rearm discipline mirrors window.lua's uv timers; stop()
    always :stop() + :close()s the handle so nothing leaks.
  * The "echo" and "at-modem" profiles are TX-driven: window.lua's
    core_send funnels payload bytes through tx_observe(), which queues the
    loopback / modem reply into the pending RX ring.
  * Modbus frames use struct + crc16_modbus when the vendored libs are
    present (xcom_lua/libs/protocol, docs/lua-libs-value... section 5);
    they fall back to equivalent pure-Lua implementations otherwise, so the
    generator works even on a libs-less checkout (the fallback CRC is
    verified against the standard check value 0x4B37).
  * GB2312 traffic is produced by encoding UTF-8 templates through
    core/charset.utf8_to_cp (cp936).  Off Windows the one-shot converter
    degrades to passthrough (UTF-8 bytes) — still a valid DBCS-free stream.
------------------------------------------------------------------------]]--

local charset = require("charset")

-- Vendored protocol libs (optional — see header note).  A failed require
-- degrades to the built-in implementations below, never an error.
local have_struct, struct = pcall(require, "struct")
if not have_struct then struct = nil end
local have_crc, crc_modbus = pcall(require, "crc16_modbus")
if not (have_crc and crc_modbus and crc_modbus.crc16_modbus) then crc_modbus = nil end

local bit = require("bit")
local bxor = bit.bxor
local band = bit.band
local rshift = bit.rshift

local M = {}
M.__index = M

local DEFAULT_TICK_MS = 20
local DEFAULT_RATE = 1024        -- bytes/s
local DEFAULT_PROFILE = "text"
local PENDING_MAX_BYTES = 256 * 1024
local INJECT_CHUNK_MAX = 4096    -- kRxBlockBytes: one core Rx block per call
local MAX_BURST_BYTES = 65536    -- per-tick generation cap (stall guard)
local AT_LINE_MAX = 256          -- cap the AT command reassembly buffer
local PROFILE_NAMES = { "text", "gb2312", "hexbin", "modbus", "at-modem",
                        "wave", "echo" }
M.PROFILES = PROFILE_NAMES

-- The C-side rule (xcom_abi.cpp is_virtual_port): exact "VIRTUAL" or the
-- "TEST" prefix.  Keep in sync; ports() below only emits names that match.
local function is_sim_port_name(name)
    if type(name) ~= "string" then return false end
    return name == "VIRTUAL" or name:sub(1, 4) == "TEST"
end

-- ---------------------------------------------------------------------------
-- CRC-16/Modbus (poly 0x8005 reflected, init 0xFFFF).  Prefers the vendored
-- table-driven lib; the fallback is the canonical bitwise form and MUST
-- satisfy the same check value ("123456789" -> 0x4B37).
-- ---------------------------------------------------------------------------
local function crc16_fallback(s)
    local crc = 0xFFFF
    for i = 1, #s do
        crc = bxor(crc, s:byte(i))
        for _ = 1, 8 do
            if band(crc, 1) == 1 then
                crc = bxor(rshift(crc, 1), 0xA001)
            else
                crc = rshift(crc, 1)
            end
        end
    end
    return crc
end

local crc16 = crc_modbus and crc_modbus.crc16_modbus or crc16_fallback

-- crc16 -> the two wire bytes (low byte first, per Modbus RTU).
local function crc16_wire(s)
    local crc = crc16(s)
    return string.char(band(crc, 0xFF), rshift(crc, 8))
end

-- ---------------------------------------------------------------------------
-- Generators.  A generator is a `unit(state) -> string` producer; the stream
-- helper below slices exact byte budgets out of the concatenated units, so
-- every profile (except the TX-driven at-modem/echo) can service any rate,
-- including mid-frame/mid-line splits (hexbin deliberately exercises those).
-- ---------------------------------------------------------------------------

-- UTF-8 templates for the GB2312 profile; encoded to cp936 per unit.  The
-- ASCII digits stay single-byte inside the encoding, giving a numbered line.
local GB_TEMPLATES = {
    { "串口模拟帧 ", " 中文数据 测试" },
    { "接收显示 ", " 链路层验证" },
    { "模拟设备上报 ", " 状态正常" },
}

local GENERATORS = {
    text = function(st)
        st.n = st.n + 1
        return string.format(
            "[%06d] SIM text frame: the quick brown fox 0123456789 ABCDEF\r\n",
            st.n)
    end,
    gb2312 = function(st)
        st.n = st.n + 1
        local tpl = GB_TEMPLATES[(st.n % #GB_TEMPLATES) + 1]
        local line = tpl[1] .. string.format("%06d", st.n) .. tpl[2] .. "\r\n"
        return charset.utf8_to_cp(line, 936)
    end,
    -- 0x00-0xFF sawtooth ramp blocks wrapped in a short ASCII header; the
    -- stream slicing deliberately lets the budget cut a block mid-line.
    hexbin = function(st)
        st.n = st.n + 1
        local ramp = {}
        for b = 0, 255 do ramp[#ramp + 1] = string.char(b) end
        return "BIN " .. string.format("%04d", st.n % 10000) .. ":" ..
            table.concat(ramp) .. "\r\n"
    end,
    -- Real Modbus RTU responses, alternating 0x03 (holding) / 0x04 (input)
    -- with 4 registers (8 data bytes) and a CRC16 over addr..data.
    modbus = function(st)
        st.n = st.n + 1
        local slave = (st.n % 247) + 1
        local func = (st.n % 2 == 0) and 4 or 3
        local data = {}
        for k = 1, 8 do
            data[k] = (st.n * 37 + k * 11) % 256
        end
        local head, body
        if struct then
            head = struct.pack(">BBB", slave, func, 8)
            body = struct.pack(">BBBBBBBB", data[1], data[2], data[3],
                data[4], data[5], data[6], data[7], data[8])
        else
            head = string.char(slave, func, 8)
            body = string.char(data[1], data[2], data[3], data[4],
                data[5], data[6], data[7], data[8])
        end
        local frame = head .. body
        return frame .. crc16_wire(frame)
    end,
    -- ImPlot scope protocol (scripts/wave_demo.lua parses "$CHn,<val>").
    wave = function(st)
        st.n = st.n + 1
        local sine = math.sin(st.n * 0.05)
        local saw = (st.n % 100) / 50 - 1
        return string.format("$CH0,%.4f\r\n$CH1,%.4f\r\n", sine, saw)
    end,
    -- TX-driven profiles emit nothing on their own tick; responses arrive
    -- exclusively through tx_observe().
    ["at-modem"] = nil,
    echo = nil,
}

-- Extract the next complete AT command line from the reassembly buffer and
-- build the modem response for it (echoed + OK, ERROR when malformed).
local function at_respond(sim, line)
    local cmd = line:match("^%s*(.-)%s*$") or ""
    if cmd == "" then return "" end
    local upper = cmd:upper()
    if upper:sub(1, 2) ~= "AT" then
        return "\r\nERROR\r\n"
    end
    -- ATE0 disables command echo until ATE1 returns; ATE0 itself replies
    -- with OK silently (no echo), like a real modem.
    if upper == "ATE0" then
        sim._at_echo = false
        return "\r\nOK\r\n"
    end
    if upper == "ATE1" then
        sim._at_echo = true
        return "\r\nOK\r\n"
    end
    local reply
    if upper == "ATH" or upper == "ATH1" then
        reply = "\r\nNO CARRIER\r\n"
    elseif upper:sub(1, 3) == "ATD" then
        reply = "\r\nCONNECT 9600\r\n"
    elseif upper == "AT" or upper == "ATZ" or upper == "ATI" or
        upper:match("^AT%+C%w+$") then
        reply = "\r\nOK\r\n"
    elseif upper:match("^AT[%w%+%=%,%-%s]+$") then
        reply = "\r\nOK\r\n"
    else
        reply = "\r\nERROR\r\n"
    end
    if sim._at_echo then return cmd .. "\r\n" .. reply end
    return reply
end

-- ---------------------------------------------------------------------------
-- Construction / policy
-- ---------------------------------------------------------------------------

--- new(opts) -> sim
--- opts = { xcom = ffi table, win = window, uv = luv, log = fn(tag,msg),
---          enabled = force-availability bool }
function M.new(opts)
    opts = opts or {}
    local self = setmetatable({
        xcom = opts.xcom,
        win = opts.win,
        uv = opts.uv,
        log = opts.log,
        forced = opts.enabled and true or false,
        tick_ms = DEFAULT_TICK_MS,
        rate = DEFAULT_RATE,
        profile_name = DEFAULT_PROFILE,
        port = nil,
        running = false,
        timer = nil,
        timer_cb = nil,      -- strong ref so the FFI closure stays alive
        last_now = 0,        -- uv.now() at the previous tick
        acc = 0.0,           -- fractional byte-budget carry (bytes)
        gen_state = { n = 0, carry = "" },
        pending = {},        -- ordered ring of not-yet-injected strings
        pending_bytes = 0,
        dropped_bytes = 0,   -- lost to the pending cap (overflow)
        injected_bytes = 0,  -- lifetime total (diagnostics / tests)
        at_buf = "",         -- AT command line reassembly
        _at_echo = true,
    }, M)
    if not self.uv then
        local ok, luv = pcall(require, "luv")
        if ok then self.uv = luv end
    end
    if not self.log then
        self.log = function(_, msg) io.stderr:write("[serial_sim] " .. msg .. "\n") end
    end
    return self
end

--- available() -> bool: auto-activation policy.  True when explicitly forced
--- or when the registry enumeration sees NO hardware ports at all.  Cached.
function M:available()
    if self.forced then return true end
    if self._available == nil then
        local ok, list = pcall(function() return self.xcom.list_ports() end)
        self._available = (ok and type(list) == "table" and #list == 0)
            and true or false
    end
    return self._available
end

--- ports() -> extra entries to append to the window's port list.
--- Both names satisfy is_virtual_port (see the rule at the top of this file).
function M:ports()
    return {
        { name = "VIRTUAL", description = "SIM 虚拟串口", busy = false },
        { name = "TESTLOOP", description = "SIM 回环", busy = false },
    }
end

M.is_sim_port = is_sim_port_name

function M:is_running()
    return self.running
end

function M:profile(name)
    if name == nil then return self.profile_name end
    for _, p in ipairs(PROFILE_NAMES) do
        if p == name then
            self.profile_name = name
            self.gen_state = { n = 0, carry = "" }
            return true
        end
    end
    return false
end

function M:set_rate(bytes_per_sec)
    local bps = tonumber(bytes_per_sec)
    if not bps then return false end
    self.rate = math.max(1, math.min(1048576, bps))
    return true
end

function M:get_rate()
    return self.rate
end

-- ---------------------------------------------------------------------------
-- Pump lifecycle
-- ---------------------------------------------------------------------------

--- start(port_name): (re)arm the 20 ms pump.  stop-before-rearm, so a second
--- start never leaves the previous uv handle live.
function M:start(port_name)
    self:stop()
    if type(port_name) == "string" and port_name ~= "" then
        self.port = port_name
    end
    if not (self.win and self.win.core) then
        self.log("sim", "start refused: core handle not present")
        return false
    end
    self.acc = 0.0
    self.gen_state = { n = 0, carry = "" }
    self.at_buf = ""
    self._at_echo = true
    self.last_now = self.uv.now()

    local timer = self.uv.new_timer()
    local cb = function()
        local ok, err = pcall(self.pump, self)
        if not ok then self.log("sim", "pump: " .. tostring(err)) end
    end
    if jit and jit.off then jit.off(cb, true) end
    self.timer = timer
    self.timer_cb = cb
    timer:start(self.tick_ms, self.tick_ms, cb)
    self.running = true
    self.log("sim", "pump armed: port=" .. tostring(self.port or "-") ..
        " profile=" .. self.profile_name .. " rate=" .. tostring(self.rate) .. " B/s")
    return true
end

--- stop(): disarm + release the uv handle (no leaked live timers).
function M:stop()
    self.running = false
    if self.timer then
        pcall(function() self.timer:stop() end)
        pcall(function() self.timer:close() end)
        self.timer = nil
        self.timer_cb = nil
    end
    self.pending = {}
    self.pending_bytes = 0
    return true
end

-- ---------------------------------------------------------------------------
-- Internals: pending ring, generator stream, injection drain
-- ---------------------------------------------------------------------------

function M:_queue(data)
    if type(data) ~= "string" or #data == 0 then return end
    local pending = self.pending
    pending[#pending + 1] = data
    self.pending_bytes = self.pending_bytes + #data
    -- Ordered cap: overflow drops the OLDEST block (never a reorder).
    while self.pending_bytes > PENDING_MAX_BYTES and #pending > 1 do
        local old = table.remove(pending, 1)
        self.pending_bytes = self.pending_bytes - #old
        self.dropped_bytes = self.dropped_bytes + #old
    end
    if self.dropped_bytes > 0 and self.dropped_logged ~= self.dropped_bytes then
        self.dropped_logged = self.dropped_bytes
        self.log("sim", "pending overflow, dropped " .. self.dropped_bytes)
    end
end

-- Slice exactly `want` bytes off the active profile's byte stream (units are
-- whole records; the budget may cut one mid-line — that is intentional).
-- Returns "" for the TX-driven profiles.
function M:_stream(want)
    local unit = GENERATORS[self.profile_name]
    if not unit or want <= 0 then return "" end
    local st = self.gen_state
    local carry = st.carry
    local guard = 0
    while #carry < want do
        carry = carry .. unit(st)
        guard = guard + 1
        if guard > 100000 then break end   -- pathological unit starvation
    end
    local out = carry:sub(1, want)
    st.carry = carry:sub(want + 1)
    return out
end

--- generate(profile, n): pure helper for tests and previews — returns the
--- first n bytes of that profile's stream from a fresh state, no side
--- effects on the running pump.
function M:generate(profile, n)
    local unit = GENERATORS[profile]
    if not unit then return "" end
    n = math.max(0, n or 0)
    local st = { n = 0 }
    local carry = ""
    local guard = 0
    while #carry < n do
        carry = carry .. unit(st)
        guard = guard + 1
        if guard > 100000 then break end
    end
    return carry:sub(1, n)
end

function M:_inject(core, data)
    if #data == 0 then return true end
    local ok, rc = pcall(self.xcom.test_inject_rx, core, data, #data)
    if not ok then return false end
    return tonumber(rc) == (self.xcom.ok or 0)
end

-- One pump tick: rate*elapsed -> bytes -> inject (pending ring first).
function M:pump()
    if not self.running then return end
    local uv = self.uv
    local now = uv.now()
    local dt = now - self.last_now
    if dt < 0 then dt = 0 end
    self.last_now = now

    local budget = self.acc + self.rate * dt / 1000.0
    local want = math.floor(budget)
    self.acc = budget - want
    -- Bound a single tick's burst so a long UI stall (huge dt) cannot make
    -- the generator build a megabyte string in one shot.  Anything beyond the
    -- cap simply carries into the next tick via `acc`.
    if want > MAX_BURST_BYTES then
        self.acc = self.acc + (want - MAX_BURST_BYTES)
        want = MAX_BURST_BYTES
    end
    if want > 0 then
        local out = self:_stream(want)
        if out ~= "" then self:_queue(out) end
    end

    local core = self.win and self.win.core
    local injected = 0
    if core then
        local pending = self.pending
        while #pending > 0 do
            local head = pending[1]
            -- Split at one core Rx block so a fat tick cannot fail wholesale.
            local piece = head
            if #piece > INJECT_CHUNK_MAX then piece = head:sub(1, INJECT_CHUNK_MAX) end
            if not self:_inject(core, piece) then break end
            self.injected_bytes = self.injected_bytes + #piece
            injected = injected + #piece
            if #piece == #head then
                table.remove(pending, 1)
            else
                pending[1] = head:sub(#piece + 1)
            end
        end
    end
    if injected > 0 then
        if self.win and self.win.request_frame then
            pcall(self.win.request_frame, self.win, 16)
        end
    end
    return injected
end

--- tx_observe(payload): window.lua core_send hook (only called while the sim
--- owns the session).  echo loops TX straight back; at-modem answers AT
--- command lines.  Other profiles ignore TX.
function M:tx_observe(payload)
    if not self.running then return end
    if type(payload) ~= "string" or #payload == 0 then return end
    local prof = self.profile_name
    if prof == "echo" then
        self:_queue(payload)
    elseif prof == "at-modem" then
        local buf = self.at_buf .. payload
        if #buf > AT_LINE_MAX * 8 then buf = buf:sub(-AT_LINE_MAX * 4) end
        for line in buf:gmatch("([^\r\n]*)[\r\n]") do
            local reply = at_respond(self, line)
            if reply ~= "" then self:_queue(reply) end
        end
        -- Keep the unterminated tail for the next observation.
        self.at_buf = buf:match("[^\r\n]*$") or ""
        if #self.at_buf > AT_LINE_MAX then self.at_buf = self.at_buf:sub(-AT_LINE_MAX) end
    else
        return
    end
    -- Pull a frame so a queued loopback surfaces promptly.
    if self.win and self.win.request_frame then
        pcall(self.win.request_frame, self.win, 16)
    end
end

M._crc16_modbus = crc16          -- test hook
M._GENERATORS = GENERATORS       -- test hook
M.PENDING_MAX_BYTES = PENDING_MAX_BYTES
M.TICK_MS = DEFAULT_TICK_MS

return M
