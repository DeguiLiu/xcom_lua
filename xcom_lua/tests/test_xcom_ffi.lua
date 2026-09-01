-- test_xcom_ffi.lua - unit tests for core/xcom_ffi.lua (pure Lua, run with luajit)
-- Usage: /home/dgliu/.local/openresty/luajit/bin/luajit test_xcom_ffi.lua
--
-- Covers everything in xcom_ffi that does NOT require the Windows DLL:
-- struct-size layout assertions (run at require time), version packing,
-- constants, port-state text, and the pure HEX encode/decode + payload
-- builders that mirror Python bytes.fromhex / build_send_payload.
-- Any ABI call that actually touches a DLL stays on Windows (no DLL in Linux).

package.path = "./core/?.lua;/home/dgliu/SSCOM/xcom_lua/core/?.lua;" .. package.path
local x = require("xcom_ffi")

local passed, failed = 0, 0
local function eq(label, got, want)
    if got == want then
        passed = passed + 1
    else
        failed = failed + 1
        print(string.format("FAIL  %s  (got=%s want=%s)", tostring(label),
                            tostring(got), tostring(want)))
    end
end
local function ok(label, cond)
    if cond then
        passed = passed + 1
    else
        failed = failed + 1
        print("FAIL  " .. label)
    end
end

-- 1) The module loads on Linux (cdef + layout self-check run at require time).
--    require() already succeeded above; assert the size pins are present.
ok("SIZEOF table present", type(x.SIZEOF) == "table")
eq("sizeof snapshot pinned", x.SIZEOF.snapshot, 52)
eq("sizeof portconfig pinned", x.SIZEOF.port_config, 32)
eq("sizeof error pinned", x.SIZEOF.error, 268)
eq("sizeof portinfo pinned", x.SIZEOF.port_info, 324)

-- 2) version packing (v1.2.0 -> 0x010200)
eq("packed version 010200", string.format("%06x", x.packed_version()), "010200")
eq("constant ok", x.ok, 0)
eq("constant full", x.err_full, -5)
eq("port open", x.port_open, 2)
eq("send crlf flag", x.send_crlf, 2)

-- 3) port-state text map (must match Python's XCOM_PORT_TEXT exactly,
--    including case: Closed/Opening/Open/Closing/Fault)
eq("port text closed", x.port_text[0], "Closed")
eq("port text opening", x.port_text[1], "Opening")
eq("port text open", x.port_text[2], "Open")
eq("port text closing", x.port_text[3], "Closing")
eq("port text fault", x.port_text[4], "Fault")

-- 4) HEX decode (mirror bytes.fromhex: whitespace tolerated, even-length)
ok("from_hex basic", x.from_hex("01 0A FF") == "\1\10\255")
ok("from_hex no space", x.from_hex("010AFF") == "\1\10\255")
ok("from_hex tabs/newlines", x.from_hex("01\t0A\nFF") == "\1\10\255")
ok("from_hex empty", x.from_hex("") == "")
ok("from_hex whitespace only", x.from_hex("   \n ") == "")
eq("from_hex odd len -> nil", x.from_hex("0"), nil)
eq("from_hex invalid digit -> nil", x.from_hex("0G"), nil)
eq("from_hex mixed invalid -> nil", x.from_hex("AB CD EZ"), nil)

-- 5) HEX encode (receive hex view "AA BB CC ")
eq("to_hex", x.to_hex("\1\10\255"), "01 0A FF ")
eq("to_hex empty", x.to_hex(""), "")

-- 6) CRLF append
eq("append_crlf", x.append_crlf("hi"), "hi\r\n")

-- 7) build_send_payload: text + optional CRLF; hex pre-encode + optional CRLF;
--    invalid hex returns (nil, err).
local ok1, err1 = x.build_send_payload("hi", false, false)
eq("text payload", ok1, "hi")
eq("text err nil", err1, nil)
local ok2, err2 = x.build_send_payload("hi", false, true)
eq("text+crlf payload", ok2, "hi\r\n")
eq("text+crlf err nil", err2, nil)
local ok3 = x.build_send_payload("01 0A", true, false)
eq("hex payload", ok3, "\1\10")
local ok4 = x.build_send_payload("01 0A", true, true)
eq("hex+crlf payload", ok4, "\1\10\r\n")
local ok5, err5 = x.build_send_payload("012", true, false)
eq("invalid hex payload nil", ok5, nil)
eq("invalid hex err string", type(err5), "string")

-- Python widgets/send_panel.py build_send_payload: in HEX mode, a
-- whitespace-only/empty input short-circuits to (b"", None) BEFORE the CRLF
-- branch, so CRLF is never appended even when requested.
local ok6, err6 = x.build_send_payload("", true, true)
eq("hex empty+crlf payload stays empty", ok6, "")
eq("hex empty+crlf err nil", err6, nil)
local ok7 = x.build_send_payload("   ", true, true)
eq("hex whitespace-only+crlf stays empty", ok7, "")

print(string.format("\nxcom_ffi tests: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
