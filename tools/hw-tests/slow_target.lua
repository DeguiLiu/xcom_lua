-- Receive-log path pointed at a target that never drains, then a bounded
-- shutdown.  Answers the question the Linux CI cannot: when the log sink is
-- stalled, does the writer actually let the process exit, and in how long?
--
-- Usage (from xcom_lua/):  runtime\luajit.exe ..\..\hw\slow_target.lua [pipe]
package.path = "./core/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[uint64_t GetTickCount64(void); void Sleep(uint32_t);]]
local x = require("xcom_ffi")

local function now_ms() return tonumber(ffi.C.GetTickCount64()) end

local path = arg[1] or "\\\\.\\pipe\\xcom_slow"
local close_timeout_ms = tonumber(arg[2]) or 2000
local h = x.create()
assert(h, "xcom_create failed")

local t_start = now_ms()
local rc = tonumber(x.log_open(h, path, false))
print(string.format("log_open(%s) -> %d", path, rc))

-- Push a lot of async receive-log payload at a sink that never reads.  After
-- the pipe buffer (4 KiB) fills, the writer's synchronous write blocks; the
-- question is what happens to close() and to the process.
local chunk = string.rep("A", 65536)
local p = ffi.cast("const uint8_t*", chunk)
local accepted, backpressure = 0, 0
for _ = 1, 512 do                       -- up to 32 MiB
    local r = tonumber(x.log_append(h, p, #chunk))
    if r == x.ok then accepted = accepted + 1 else backpressure = backpressure + 1 end
end
print(string.format("log_append: accepted=%d chunk(s) (%d MiB), non-ok=%d",
                    accepted, accepted * 64 / 1024, backpressure))
print(string.format("  (%.0f ms elapsed while pushing)", now_ms() - t_start))

-- Bounded shutdown.  This is the measurement that matters: a stalled sink must
-- not turn close() into an unbounded join.
local c0 = now_ms()
local crc = tonumber(x.log_close(h, close_timeout_ms))
local cms = now_ms() - c0
print(string.format("log_close(%d) -> %d   measured %.0f ms", close_timeout_ms, crc, cms))

x.destroy(h)
print(string.format("process exit path reached; total wall %.0f ms", now_ms() - t_start))
os.exit(0)
