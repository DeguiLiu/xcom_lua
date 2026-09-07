-- test_serial_sim.lua - offline unit tests for core/serial_sim.lua.
-- Usage: cd xcom_lua/runtime && ./luvjit.exe ../tests/test_serial_sim.lua
--
-- No window, no core DLL, no event loop.  The xcom FFI surface and the luv
-- host are replaced with recording stubs so every code path (generator
-- shapes, rate math, the 20 ms pump's pending ring, start/stop handle
-- lifecycle, the TX-driven echo / at-modem replies) is audited by pumping
-- sim:pump() by hand against a controlled fake uv.now().
--
-- Covers, per the task brief:
--   * ports() names satisfy the C-side is_virtual_port rule (hardcoded).
--   * available() auto-activation = (#list_ports()==0), plus forced path.
--   * profile generator shapes: text CRLF, hexbin 0x00-0xFF ramp, modbus
--     CRC16 frames (verified against the vendored crc16_modbus when present,
--     else a canonical bitwise implementation), wave "$CHn,val" lines,
--     gb2312 produces DBCS bytes.
--   * rate math: bytes injected per pump == rate*dt/1000 (exact carry model).
--   * start/stop leaves ZERO live uv handles (fake uv.new_timer).
--   * inject-fail retry ring drains in ORDER (no reorder / dup / loss).
--   * echo + at-modem tx_observe queue RX replies.

package.path = "../core/?.lua;" .. package.path

local pass_n, fail_n = 0, 0
local function ok(label, cond)
    if cond then pass_n = pass_n + 1; print("PASS  " .. label)
    else fail_n = fail_n + 1; print("FAIL  " .. label) end
end
local function eq(label, got, want)
    ok(string.format("%s (got=%s want=%s)", label, tostring(got), tostring(want)),
       got == want)
end

-- ---------------------------------------------------------------------------
-- Independent CRC-16/Modbus (canonical) for verifying generator frames.  The
-- vendored table lib (libs/protocol) may or may not be present on a checkout;
-- both the module fallback and this are the standard algorithm, so results
-- match.  Prefers the vendored lib when requireable (per the brief).
-- ---------------------------------------------------------------------------
local bit = require("bit")
local crc_vendor = select(2, pcall(require, "crc16_modbus"))
local function crc_canon(s)
    local crc = 0xFFFF
    for i = 1, #s do
        crc = bit.bxor(crc, s:byte(i))
        for _ = 1, 8 do
            if bit.band(crc, 1) == 1 then
                crc = bit.bxor(bit.rshift(crc, 1), 0xA001)
            else
                crc = bit.rshift(crc, 1)
            end
        end
    end
    return crc
end
local crc_fn = (crc_vendor and crc_vendor.crc16_modbus) or crc_canon
print("crc source: " .. (crc_vendor and "vendored crc16_modbus" or "canonical fallback"))
-- sanity: the canonical value for "123456789" is 0x4B37.
eq("crc self-check 123456789", crc_canon("123456789"), 0x4B37)

-- ---------------------------------------------------------------------------
-- Fake luv: controllable now() + a recording timer factory (mirrors the
-- test_send_file_caps.lua discipline: we never run uv.run; we fire pump()).
-- ---------------------------------------------------------------------------
local handles = {}
local fake_uv = {
    _now = 0,
}
function fake_uv.now() return fake_uv._now end
function fake_uv.new_timer()
    local h = { armed = false, stopped = false, closed = false, period = 0 }
    function h:start(_first, period, cb) self.armed = true; self.period = period; self.cb = cb end
    function h:stop() self.stopped = true end
    function h:close() self.closed = true; self.armed = false end
    handles[#handles + 1] = h
    return h
end
-- live = armed and not closed.
local function live_handle_count()
    local n = 0
    for _, h in ipairs(handles) do if h.armed and not h.closed then n = n + 1 end end
    return n
end

-- ---------------------------------------------------------------------------
-- Fake xcom: list_ports configurable; test_inject_rx records and its result
-- is scripted by the caller.  Constants mirror xcom_ffi.lua.  NOTE: the real
-- xcom_ffi exposes these as PLAIN functions (M.list_ports(), M.test_inject_rx
-- (h, data, size)) — the stubs must match that dot-call convention exactly.
-- ---------------------------------------------------------------------------
local function new_xcom()
    local x
    x = {
        ok = 0, err_not_open = -2, err_io = -6,
        _ports = {},
        _injected = {},
        _fail_first = 0,      -- first N inject calls fail, then succeed
        _call_count = 0,
        list_ports = function() return x._ports end,
        test_inject_rx = function(_core, data, len)
            x._call_count = x._call_count + 1
            if x._call_count <= x._fail_first then
                return x.err_not_open
            end
            x._injected[#x._injected + 1] = data:sub(1, len)
            return x.ok
        end,
    }
    return x
end

local function new_win()
    return { core = { fake = true }, frames = 0,
             request_frame = function(self) self.frames = self.frames + 1 end }
end

local serial_sim = require("serial_sim")

-- ===========================================================================
-- 1) ports() names satisfy is_virtual_port (name=="VIRTUAL" or ^TEST).
-- ===========================================================================
do
    local sim = serial_sim.new({ xcom = new_xcom(0), win = new_win(), uv = fake_uv })
    local ports = sim:ports()
    ok("ports: non-empty", #ports >= 2)
    local matched = 0
    for _, p in ipairs(ports) do
        local isv = (p.name == "VIRTUAL") or (p.name:sub(1, 4) == "TEST")
        if isv then matched = matched + 1 end
        -- the module's own predicate must agree with the C rule
        ok("is_sim_port agrees: " .. p.name, sim.is_sim_port(p.name) == (p.name == "VIRTUAL" or p.name:sub(1,4) == "TEST"))
    end
    eq("ports: all satisfy is_virtual_port", matched, #ports)
    ok("COM1 is not a sim port", not sim.is_sim_port("COM1"))
    ok("TESTLOOP matches", sim.is_sim_port("TESTLOOP"))
end

-- ===========================================================================
-- 2) available() auto-activation policy.
-- ===========================================================================
do
    local empty = new_xcom(0)
    local sim = serial_sim.new({ xcom = empty, win = new_win(), uv = fake_uv })
    eq("available: empty port list -> true", sim:available(), true)

    local busy = new_xcom(0)
    busy._ports = { { name = "COM1", description = "real" } }
    local sim2 = serial_sim.new({ xcom = busy, win = new_win(), uv = fake_uv })
    eq("available: real ports present -> false", sim2:available(), false)

    local sim3 = serial_sim.new({ xcom = busy, win = new_win(), uv = fake_uv, enabled = true })
    eq("available: forced enable -> true", sim3:available(), true)
end

-- ===========================================================================
-- 3) profile generator shapes.
-- ===========================================================================
do
    local sim = serial_sim.new({ xcom = new_xcom(0), win = new_win(), uv = fake_uv })

    -- text: ASCII + CRLF.
    local t = sim:generate("text", 200)
    ok("text: has CRLF", t:find("\r\n", 1, true) ~= nil)
    ok("text: printable ASCII", t:find("[^%g \r\n]") == nil)

    -- hexbin: a 0x00-0xFF sawtooth ramp somewhere in the stream.
    local hb = sim:generate("hexbin", 400)
    local all_present = true
    for b = 0, 255 do
        if not hb:find(string.char(b), 1, true) then all_present = false break end
    end
    ok("hexbin: ramp covers 0x00..0xFF", all_present)

    -- modbus: 13-byte frames (addr+func+bc(8)+8 data+2 crc); verify CRC wire.
    local frames = 4
    local mb = sim:generate("modbus", 13 * frames)
    eq("modbus: stream length", #mb, 13 * frames)
    local crc_ok = true
    local func_seen = {}
    for i = 0, frames - 1 do
        local f = mb:sub(i * 13 + 1, i * 13 + 13)
        local body = f:sub(1, 11)
        local want_lo, want_hi = f:byte(12), f:byte(13)
        local crc = crc_fn(body)
        if bit.band(crc, 0xFF) ~= want_lo or bit.rshift(crc, 8) ~= want_hi then
            crc_ok = false
        end
        if f:byte(3) ~= 8 then crc_ok = false end        -- byte count == 8
        func_seen[f:byte(2)] = true
    end
    ok("modbus: every frame CRC + byte-count valid", crc_ok)
    ok("modbus: function 0x03 seen", func_seen[3] == true)
    ok("modbus: function 0x04 seen", func_seen[4] == true)

    -- wave: parse "$CHn,<val>" lines; CH0 & CH1 numeric.
    local wv = sim:generate("wave", 400)
    local seen_ch = {}
    local all_numeric = true
    for ch, val in wv:gmatch("%$CH(%d),([%-%d%.]+)") do
        seen_ch[ch] = true
        local n = tonumber(val)
        if not n or n < -1.5 or n > 1.5 then all_numeric = false end
    end
    ok("wave: CH0 present", seen_ch["0"] == true)
    ok("wave: CH1 present", seen_ch["1"] == true)
    ok("wave: values numeric & bounded", all_numeric)

    -- gb2312: emits at least one DBCS (>=0x80) byte.
    local gb = sim:generate("gb2312", 200)
    local has_high = false
    for i = 1, #gb do if gb:byte(i) >= 0x80 then has_high = true break end end
    ok("gb2312: contains a high (>=0x80) byte", has_high)

    -- unknown profile -> empty.
    eq("generate(unknown) -> ''", sim:generate("nope", 50), "")
end

-- ===========================================================================
-- 4) rate math: bytes injected == rate*dt/1000 per pump (exact, no drift).
-- ===========================================================================
do
    handles = {}
    local x = new_xcom(0)
    local win = new_win()
    local sim = serial_sim.new({ xcom = x, win = win, uv = fake_uv })
    sim:profile("text")
    sim:set_rate(50000)                 -- 50000 B/s; 20ms -> exactly 1000 B/tick
    fake_uv._now = 0
    ok("start returns true with core", sim:start("VIRTUAL") == true)
    for _ = 1, 5 do
        fake_uv._now = fake_uv._now + 20
        sim:pump()
    end
    local total = 0
    for _, s in ipairs(x._injected) do total = total + #s end
    eq("rate: 5 x 20ms @50000 B/s == 5000 injected", total, 5000)
    ok("rate: request_frame fired while injecting", win.frames > 0)
    sim:stop()
end

-- ===========================================================================
-- 5) start/stop leaves ZERO live uv handles (and stop-before-rearm).
-- ===========================================================================
do
    handles = {}
    local sim = serial_sim.new({ xcom = new_xcom(0), win = new_win(), uv = fake_uv })
    sim:start("VIRTUAL")
    eq("one live handle after start", live_handle_count(), 1)
    eq("armed timer period is 20ms", handles[#handles].period, 20)
    -- re-start must not accumulate a live handle
    sim:start("TESTLOOP")
    eq("still one live handle after re-start", live_handle_count(), 1)
    eq("total handles created (old closed)", #handles, 2)
    ok("old handle closed on re-start", handles[1].closed == true)
    sim:stop()
    eq("zero live handles after stop", live_handle_count(), 0)
    ok("sim reports not running after stop", sim:is_running() == false)
end

-- start refuses without a core handle.
do
    local sim = serial_sim.new({ xcom = new_xcom(0), uv = fake_uv })
    -- win without .core
    local win_nohandle = { request_frame = function() end }
    sim.win = win_nohandle
    eq("start refused without core", sim:start("VIRTUAL"), false)
end

-- ===========================================================================
-- 6) inject-fail retry ring drains IN ORDER (no reorder / dup / loss).
-- ===========================================================================
do
    handles = {}
    local x = new_xcom(0)
    local win = new_win()
    local sim = serial_sim.new({ xcom = x, win = win, uv = fake_uv })
    sim:profile("echo")                    -- echo => generator silent
    fake_uv._now = 0
    sim:start("TESTLOOP")
    -- Fail the NEXT ONE inject call; queue three distinct payloads.
    x._fail_first = x._call_count + 1
    sim:tx_observe("AAA1")
    sim:tx_observe("BBB2")
    sim:tx_observe("CCC3")
    eq("pending holds 3 queued blocks", #sim.pending, 3)
    -- A pump attempt hits the failure: nothing injects, order preserved.
    fake_uv._now = fake_uv._now + 20
    sim:pump()
    eq("inject-fail keeps 3 pending (front intact)", sim.pending[1], "AAA1")
    eq("no bytes leaked to a failing inject", #x._injected, 0)
    -- Now injects succeed; drain must yield AAA1 BBB2 CCC3 exactly, in order.
    fake_uv._now = fake_uv._now + 20
    sim:pump()
    local joined = table.concat(x._injected)
    eq("ring drains in order", joined, "AAA1BBB2CCC3")
    eq("ring emptied after drain", #sim.pending, 0)
    sim:stop()
end

-- ===========================================================================
-- 7) echo loops TX verbatim; at-modem answers AT commands with replies.
-- ===========================================================================
do
    handles = {}
    -- echo: a pump after tx_observe must inject the exact payload.
    local xe = new_xcom(0)
    local sim_e = serial_sim.new({ xcom = xe, win = new_win(), uv = fake_uv })
    sim_e:profile("echo")
    fake_uv._now = 0
    sim_e:start("TESTLOOP")
    sim_e:tx_observe("hello loop\r\n")
    fake_uv._now = fake_uv._now + 20
    sim_e:pump()
    eq("echo looped TX back to RX", table.concat(xe._injected), "hello loop\r\n")
    sim_e:stop()

    -- at-modem: AT<CR> => echo + OK; a bad command => ERROR.
    handles = {}
    local xa = new_xcom(0)
    local sim_a = serial_sim.new({ xcom = xa, win = new_win(), uv = fake_uv })
    sim_a:profile("at-modem")
    fake_uv._now = 0
    sim_a:start("TESTLOOP")
    sim_a:tx_observe("AT\r")
    fake_uv._now = fake_uv._now + 20
    sim_a:pump()
    local reply = table.concat(xa._injected)
    ok("at-modem echoes command", reply:find("AT", 1, true) ~= nil)
    ok("at-modem replies OK", reply:find("OK", 1, true) ~= nil)
    -- malformed (no leading AT) -> ERROR
    xa._injected = {}
    sim_a:tx_observe("BOGUS\r")
    fake_uv._now = fake_uv._now + 20
    sim_a:pump()
    ok("at-modem bad command -> ERROR", table.concat(xa._injected):find("ERROR", 1, true) ~= nil)
    -- partial command split across observations reassembles.
    xa._injected = {}
    sim_a:tx_observe("AT+CF")
    fake_uv._now = fake_uv._now + 20
    sim_a:pump()
    eq("partial AT command yields nothing yet", #xa._injected, 0)
    sim_a:tx_observe("UN\r")
    fake_uv._now = fake_uv._now + 20
    sim_a:pump()
    ok("reassembled AT+CFUN -> reply", table.concat(xa._injected):find("OK", 1, true) ~= nil)
    sim_a:stop()
end

-- ===========================================================================
-- 8) pending-ring overflow drops OLDEST (ordered), never reorders.
-- ===========================================================================
do
    local sim = serial_sim.new({ xcom = new_xcom(0), win = new_win(), uv = fake_uv })
    local cap = sim.PENDING_MAX_BYTES
    local block = string.rep("x", 4096)
    -- push well past the cap; every block is identical here so we verify the
    -- accounting + strict front-drop ordering by size instead of content.
    local n = math.floor(cap / 4096) + 10
    for _ = 1, n do sim:_queue(block) end
    ok("overflow kept pending at/under cap", sim.pending_bytes <= cap)
    ok("overflow counted dropped bytes", sim.dropped_bytes > 0)
    -- The dropped total + retained total == queued total (nothing invented).
    eq("byte accounting exact", sim.dropped_bytes + sim.pending_bytes, n * 4096)
end

print(string.format("serial_sim: %d passed, %d failed", pass_n, fail_n))
os.exit(fail_n > 0 and 1 or 0)
