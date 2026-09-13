-- Probe the MCU shell on a real port at 115200 8N1.
-- Opens, drains stale RX, sends one command + LF, prints the reply.
-- Usage (from xcom_lua/):  runtime\luajit.exe ..\..\hw\shell_probe.lua COM37 "help" [collect_ms]
package.path = "./core/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[uint64_t GetTickCount64(void); void Sleep(uint32_t);]]
local x = require("xcom_ffi")

local port    = arg[1] or "COM37"
local cmd     = arg[2] or "help"
local collect = tonumber(arg[3]) or 2500

local function ms() return tonumber(ffi.C.GetTickCount64()) end

local h = x.create()
assert(h, "xcom_create failed")
local SNAME = { [0]="XCOM_OK", [-1]="XCOM_ERR_PARAM", [-2]="XCOM_ERR_NOT_OPEN",
                [-3]="XCOM_ERR_ALREADY_OPEN", [-4]="XCOM_ERR_BUSY", [-5]="XCOM_ERR_FULL",
                [-6]="XCOM_ERR_IO", [-7]="XCOM_ERR_TIMEOUT", [-8]="XCOM_ERR_DRAIN_INCOMPLETE",
                [-9]="XCOM_ERR_UNSUPPORTED" }
local function sn(v) return SNAME[v] or ("<" .. tostring(v) .. ">") end

local orc = tonumber(x.open_async(h, port, 115200, 8, 0, 0, 0, nil, nil))
print("open_async -> " .. orc .. " " .. sn(orc))
local opened = false
for _ = 1, 40 do
    local s = x.get_snapshot(h)
    if s and s.port_state == x.port_open then opened = true break end
    ffi.C.Sleep(50)
end
if not opened then
    local e = x.take_error(h)
    print(string.format("open FAILED: port_state=%s err=%s",
                        tostring(x.get_snapshot(h).port_state),
                        e and (e.code .. " " .. e.message) or "none"))
    x.destroy(h)
    os.exit(1)
end
print("port_state -> OPEN (" .. port .. " @115200 8N1)")

-- Drain whatever the previous session left in flight.
local t = ms()
while ms() - t < 800 do x.drain_display(h, 65536); ffi.C.Sleep(50) end
print("stale RX drained")

local line = cmd .. "\n"
print(string.format("TX -> %q", line))
local src = tonumber(x.send(h, line, 0))
print(string.format("send -> %d %s", src, sn(src)))
if src ~= 0 then
    local e = x.take_error(h)
    print("error ring: " .. (e and (e.code .. " " .. e.message) or "none"))
    local s0 = x.get_snapshot(h)
    print(string.format("snapshot: tx_bytes=%d tx_rejected=%d rx_bytes=%d port_state=%d",
                        s0.tx_bytes, s0.tx_rejected, s0.rx_bytes, s0.port_state))
    x.close(h, 2000); x.destroy(h); os.exit(1)
end

local out = {}
local t0 = ms()
while ms() - t0 < collect do
    local st, text = x.drain_display(h, 65536)
    if st == 0 and text and #text > 0 then out[#out + 1] = text end
    ffi.C.Sleep(40)
end

local reply = table.concat(out)
print(string.format("RX <- %d bytes in %d ms", #reply, ms() - t0))
print("---- reply (printable, CR shown as ^M) ----")
print((reply:gsub("\r", "^M")))
print("-------------------------------------------")

local s = x.get_snapshot(h)
print(string.format("snapshot: rx_bytes=%d tx_bytes=%d framing=%d parity=%d overrun=%d break=%d",
                    s.rx_bytes, s.tx_bytes, s.framing_errors, s.parity_errors,
                    s.overrun_errors, s.break_events))
x.close(h, 2000)
x.destroy(h)
