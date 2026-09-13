-- Stimulated sustained RX at 115200 8N1 against the real MCU.
--
-- The peer is an RT-Thread msh shell on an IR-camera SoC and is silent until
-- spoken to (a 60 s listen-only run received 0 bytes - measured), so traffic is
-- driven by repeating `help`, whose reply is ~15 KB.  Loss is judged two ways:
--   * the receive LOG lane (xcom.h: the lossless lane) must contain one
--     terminating "msh />" prompt per command issued, so no reply was truncated;
--   * every core loss/error counter must stay at zero.
--
-- Usage (from xcom_lua/):  runtime\luajit.exe ..\..\hw\rx_stimulated_115200.lua [port] [count] [logpath]
package.path = "./core/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[uint64_t GetTickCount64(void); void Sleep(uint32_t);]]
local x = require("xcom_ffi")

local port  = arg[1] or "COM37"
local count = tonumber(arg[2]) or 20
local logp  = arg[3] or "D:/workspace/e2e2/logs/rx_stimulated.bin"
local BAUD  = 115200

local function ms() return tonumber(ffi.C.GetTickCount64()) end

local h = x.create()
assert(h, "xcom_create failed")
print(string.format("log_open -> %d (%s)", tonumber(x.log_open(h, logp, false)), logp))
print(string.format("open_async(%s) -> %d", port, tonumber(x.open_async(h, port, BAUD, 8, 0, 0, 0, nil, nil))))
local opened = false
for _ = 1, 40 do
    local s = x.get_snapshot(h)
    if s and s.port_state == x.port_open then opened = true break end
    ffi.C.Sleep(50)
end
if not opened then print("open FAILED"); x.destroy(h); os.exit(1) end
print("port_state -> OPEN")

-- Let any boot-time chatter settle before the measured window.
local t = ms()
while ms() - t < 1000 do x.drain_display(h, 65536); ffi.C.Sleep(50) end

-- get_snapshot hands back a REUSED module-level table (documented ownership
-- contract), so deltas must be taken from copied scalars, not from a second
-- reference to the same table.
local function grab()
    local s = x.get_snapshot(h)
    if not s then return nil end
    return { rx_bytes = s.rx_bytes, tx_bytes = s.tx_bytes }
end

local first = grab()
local t0 = ms()
local sent = 0
for i = 1, count do
    local src = tonumber(x.send(h, "help\n", 0))
    if src ~= 0 then
        print(string.format("  send %d failed: %d", i, src))
        local s = x.get_snapshot(h)
        print(string.format("  at failure: port_state=%d rx_bytes=%d tx_bytes=%d display_pending=%d",
                            s.port_state, s.rx_bytes, s.tx_bytes, s.display_pending))
        local e = x.take_error(h)
        print(string.format("  error ring: %s",
                            e and string.format("code=%d source=%d message=%q", e.code, e.source, e.message)
                              or "empty"))
        break
    end
    sent = sent + 1
    -- Wait for this reply to finish: a prompt appears only at the end of it.
    local seen_prompt = false
    local w = ms()
    while ms() - w < 15000 do
        local st, text = x.drain_display(h, 65536)
        if st == 0 and text and text:find("msh />", 1, true) then seen_prompt = true break end
        ffi.C.Sleep(25)
    end
    if not seen_prompt then print(string.format("  command %d: no terminating prompt within 15 s", i)) end
end
local elapsed = ms() - t0

local last = x.get_snapshot(h)
local last_rx = last.rx_bytes
local fc = tonumber(x.log_flush(h, 5000))
local cc = tonumber(x.log_close(h, 5000))
x.close(h, 2000)
x.destroy(h)

local f = assert(io.open(logp, "rb"))
local got = f:read("*a")
f:close()

local _, prompts = got:gsub("msh />", "")
local _, headers = got:gsub("RT%-Thread shell commands", "")
local rx_delta = last_rx - first.rx_bytes
local seconds = elapsed / 1000

print(string.format("commands sent       = %d", sent))
print(string.format("elapsed             = %d ms (%.1f s)", elapsed, seconds))
print(string.format("rx_bytes delta      = %d  (%.2f KB/s average; 11.5 KB/s = 100%% of 115200 8N1)",
                    rx_delta, rx_delta / 1024 / seconds))
print(string.format("log file on disk    = %d bytes", #got))
print(string.format("prompts in capture  = %d (need >= %d, one per reply)", prompts, sent))
print(string.format("help headers seen   = %d", headers))
print(string.format("log_flush=%d log_close=%d", fc, cc))
print("---- loss / error counters ----")
print(string.format("rx_sequence=%d rx_loss_offset=%d rx_backpressure_events=%d rx_pool_exhausted_bytes=%d",
                    last.rx_sequence, last.rx_loss_offset, last.rx_backpressure_events,
                    last.rx_pool_exhausted_bytes))
print(string.format("tx_rejected=%d save_rejected_bytes=%d flow_hold_events=%d display_pending=%d",
                    last.tx_rejected, last.save_rejected_bytes, last.flow_hold_events,
                    last.display_pending))
print(string.format("line errors: framing=%d parity=%d overrun=%d break=%d",
                    last.framing_errors, last.parity_errors, last.overrun_errors, last.break_events))

local clean = (prompts >= sent
               and last.rx_loss_offset == 0 and last.rx_backpressure_events == 0
               and last.rx_pool_exhausted_bytes == 0 and last.save_rejected_bytes == 0
               and last.framing_errors == 0 and last.parity_errors == 0
               and last.overrun_errors == 0 and last.break_events == 0)
print("RESULT: " .. (clean and "COMPLETE - every reply arrived, all counters zero"
                          or "INCOMPLETE - see counters above"))
os.exit(clean and 0 or 1)
