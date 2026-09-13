-- Real-hardware open-failure diagnostics, driven through the shipped client API.
-- Usage (from xcom_lua/):  runtime\luajit.exe ..\..\hw\open_diag.lua COM37 COM99
--
-- Answers two questions the C++ suites cannot, because they never touch a
-- physical port and never go through the UI's cause table:
--   * does a port held by another process produce a SPECIFIC cause, or a
--     generic io error?
--   * is the raw Win32 code preserved in the error ring (5 vs 32 vs 2)?
package.path = "./core/?.lua;" .. package.path
local ffi = require("ffi")
ffi.cdef[[void Sleep(uint32_t dwMilliseconds);]]
local x = require("xcom_ffi")

local STATUS = {
    [0]  = "XCOM_OK",              [-1] = "XCOM_ERR_PARAM",
    [-2] = "XCOM_ERR_NOT_OPEN",    [-3] = "XCOM_ERR_ALREADY_OPEN",
    [-4] = "XCOM_ERR_BUSY",        [-5] = "XCOM_ERR_FULL",
    [-6] = "XCOM_ERR_IO",          [-7] = "XCOM_ERR_TIMEOUT",
    [-8] = "XCOM_ERR_DRAIN_INCOMPLETE", [-9] = "XCOM_ERR_UNSUPPORTED",
}
local function sname(s) return STATUS[s] or ("<unknown " .. tostring(s) .. ">") end

local function probe(port)
    print(string.rep("-", 62))
    print(string.format("open %s @115200 8N1 (dtr/rts left alone)", port))
    local h = x.create()
    if not h then print("  xcom_create failed") return end

    -- stop_bits 0 == one stop bit; parity 0 == none; flow 0 == none.
    -- dtr/rts nil -> line_tristate(nil) == 0.  xcom.line_leave_alone is 2.
    local rc = x.open_async(h, port, 115200, 8, 0, 0, 0, nil, nil)
    print(string.format("  open_async       -> %d  %s", rc, sname(rc)))

    -- Same wait loop the shipped integration test uses: success is
    -- snapshot.port_state == OPEN; a terminal (non-busy, non-ok) result from
    -- take_open_result is the failure path.
    local opened, final, polls = false, rc, 0
    for _ = 1, 40 do
        polls = polls + 1
        local snap = x.get_snapshot(h)
        if snap and snap.port_state == x.port_open then opened = true break end
        local st = tonumber(x.take_open_result(h))
        if st ~= x.err_busy and st ~= x.ok then final = st break end
        ffi.C.Sleep(50)
    end
    print(string.format("  take_open_result -> %d  %s   (%d poll%s, ~%d ms)",
                        final, sname(final), polls, polls == 1 and "" or "s", polls * 50))
    print(string.format("  port_state       -> %s", opened and "OPEN (success)" or "not open"))

    if opened then
        x.close(h, 2000)
        x.destroy(h)
        return
    end

    -- Drain the error ring, allowing a short settle: the sink that records the
    -- raw Win32 code publishes it on the owner thread, just after the state
    -- machine reports the terminal result.
    local seen, waited = 0, 0
    repeat
        local err = x.take_error(h)
        if err then
            seen = seen + 1
            print(string.format("  error ring[%d]    -> code=%d source=%s", seen, err.code, tostring(err.source)))
            print(string.format("                      message=%q", err.message))
            print(string.format("  describe_open_error(%d) -> %s", err.code,
                                tostring(x.describe_open_error(err.code))))
        else
            ffi.C.Sleep(50)
            waited = waited + 50
        end
    until seen > 0 or waited >= 1000
    if seen == 0 then
        print(string.format("  error ring       -> EMPTY after %d ms: no raw Win32 code recorded", waited))
        print("  => the UI has only the generic status and cannot name the cause")
    end

    x.close(h, 2000)
    x.destroy(h)
end

local ports = { ... }
if #ports == 0 then ports = { "COM37" } end
for _, p in ipairs(ports) do probe(p) end
print(string.rep("-", 62))

-- The cause table the UI shows; absent here would mean a generic message.
print("cause table entries in use:")
for _, code in ipairs({ 2, 5, 32, 1167, 995 }) do
    print(string.format("  %-5d -> %s", code, tostring(x.describe_open_error(code))))
end
