--[[--------------------------------------------------------------------------
tests/prof_receive_path.lua - headless stage-profile of the REAL receive path.

Measures the CPU time per drained 64 KiB display batch through the actual core
DLL (xcom_core.dll) so receive/display optimisations target measurement rather
than intuition:

  stage "drain"   : xcom_drain_display(64 KiB) — core text formatting + the
                    FFI->Lua ffi.string copy that lands the batch in Lua.
  stage "append"  : Lua _append_imgui_receive-shaped body (chunk append + the
                    rolling-tail retire cursor walk).
  stage "flush"   : once per frame, _flush_imgui_receive-shaped table.concat
                    of the retained chunks + one tail :sub.

It injects a fixed number of large batches back-to-back (no wall-clock pacing),
so uv.now()/uv.sleep semantics are irrelevant; only uv.hrtime() monotonic ns is
used.  Run with `-j off` for an interpreter baseline.

Usage:
  runtime\luvjit.exe  tests/prof_receive_path.lua [batches] [bytes_per_inject]
  runtime\luvjit.exe -j off tests/prof_receive_path.lua ...
---------------------------------------------------------------------------]]
local script = (arg and arg[0]) or "prof_receive_path.lua"
local dir = script:match("^(.*)[/\\]") or "."
local base = dir:gsub("[\\/]tests$", "")
if dir == "tests" then base = "." end
package.path = base .. "/core/?.lua;" .. base .. "/ui/?.lua;" .. package.path

local uv    = require("luv")
local xcom  = require("xcom_ffi")
assert(xcom.load(), "xcom_core.dll not loadable")

local NBATCH  = tonumber(arg and arg[1]) or 400   -- injects/drains of 64 KiB
local INJ     = tonumber(arg and arg[2]) or (64 * 1024)

-- ---- open hardware-free VIRTUAL -------------------------------------------
local h = assert(xcom.create())
local function open()
    assert(tonumber(xcom.open_async(h, "VIRTUAL", 115200, 8, 0, 0, 0, false, false)) == xcom.ok)
    for _ = 1, 500 do
        local s = xcom.get_snapshot(h)
        if s and s.port_state == xcom.port_open then return end
        uv.sleep(1)
    end
    error("VIRTUAL never opened")
end
open()

-- one 46-byte telemetry-tail line; repeat to INJ
local rline = "t=0000000 temp=24.6  RSS=42.1  tx=OK\n"
local rn = #rline
local function make(byte)
    local parts, n = {}, 0
    while n < byte do parts[#parts + 1] = rline; n = n + rn end
    return table.concat(parts)
end

-- per-batch stage cost
local acc = { drain = 0, append = 0, flush = 0, n = 0 }

-- rolling-tail trim mirrors Window:_append/_flush (chunk array + cursor + sub)
local chunks, chunkbytes, cursor = {}, 0, 1
local WIN = 65535
local function append_batch(text)
    chunks[#chunks + 1] = text
    chunkbytes = chunkbytes + #text
    local cur = cursor
    while cur < #chunks and chunkbytes - #chunks[cur] > WIN do
        chunkbytes = chunkbytes - #chunks[cur]
        cur = cur + 1
    end
    cursor = cur
end
local function flush_buf()
    local count = #chunks - cursor + 1
    local combined
    if count <= 0 then combined = ""
    elseif count == 1 then combined = chunks[cursor]
    else combined = table.concat(chunks, "", cursor) end
    local t = #combined >= WIN and combined:sub(-(WIN - 1)) or combined
    chunks, chunkbytes, cursor = {}, 0, 1
    return #t
end

-- give the drain lane / pool a clean start
xcom.test_inject_rx(h, make(1024), 1024)
uv.sleep(5)
xcom.drain_display(h, 64 * 1024)

-- ---- warm up (let JIT traces form) then measure ---------------------------
local payload = make(INJ)
local inj_ns = 0
local function bench_batch()
    local t0 = uv.hrtime()
    xcom.test_inject_rx(h, payload, #payload)
    inj_ns = inj_ns + (uv.hrtime() - t0)
    for _ = 1, 8 do
        local a = uv.hrtime()
        local rc, text = xcom.drain_display(h, 64 * 1024)
        if rc ~= xcom.ok or not text or #text == 0 then break end
        -- 'text' is already a Lua string (drain_display did the ffi.string copy)
        local done = uv.hrtime()
        acc.drain = acc.drain + (done - a)      -- FFI + ffi.string copy
        local b0 = uv.hrtime()
        append_batch(text)                        -- Lua tail-append path
        acc.append = acc.append + (uv.hrtime() - b0)
        acc.n = acc.n + 1
    end
end

for _ = 1, 60 do bench_batch() end        -- warm-up / trace formation
local warm_n = acc.n

-- snapshot clean counters for the measured window
acc.drain, acc.append, acc.flush, acc.n, inj_ns = 0, 0, 0, 0, 0
for i = 1, NBATCH do
    bench_batch()
    if i % 8 == 0 then
        local f0 = uv.hrtime()
        flush_buf()
        acc.flush = acc.flush + (uv.hrtime() - f0)
    end
end
xcom.destroy(h)

-- ---- report ----------------------------------------------------------------
print("")
print("==== receive-path stage profile ====")
local jstat = (jit and jit.status and tostring(jit.status())) or "n/a (no jit module)"
print(string.format("jit.status    : %s", jstat))
print(string.format("measured      : %d drained batches  (warm-up %d)", acc.n, warm_n))
if acc.n == 0 then print("NO BATCHES DRAINED (injection not reaching display?)"); return end
local total = acc.drain + acc.append + acc.flush
local function row(name, ns)
    print(string.format("  %-14s %10.0f ns/batch    %6.2f%%", name, ns / acc.n, 100 * ns / total))
end
print(string.format("  %-14s %10s", "", ""))
row("drain(ffi)",  acc.drain)
row("append(lua)", acc.append)
row("flush(lua)",  acc.flush)
print(string.format("total per batch= %.2f us   (both-flush ~ %d/%d)  inj total %.2f s-ish",
    total / acc.n / 1000, acc.flush, acc.n, inj_ns / 1e9))
