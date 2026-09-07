# xcom_lua/libs — in-project vendored pure-Lua libraries

This tree is the **runtime-consumed copy** of the curated Lua libraries that
used to be required directly out of `third_party/`. The tests
(`tests/test_lua51-libs.lua`, `tests/test_protocol_libs.lua`,
`tests/test_openresty_lua.lua`, `tests/test_iconv.lua`) resolve their
`package.path` entries against the directories below, so keep the layout
stable.

All files are verbatim `cp` copies of the corresponding `third_party`
subtrees (created 2026-09-05). `third_party/` remains the pristine vendor
snapshot; re-sync from there after any upstream re-port.

## Mapping (third_party/<src> -> libs/<dst>)

| Destination | Source | Contents | License hints |
|---|---|---|---|
| `libs/protocol/` | `third_party/lua-protocol-libs/` | `struct.lua` (iryont/lua-struct, MIT), `json.lua` (rxi/json.lua, MIT), `crc32.lua` (davidm/lua-digest-crc32lua, MIT), `crc16_ccitt.lua` (ported from clarkli86/crc16_ccitt, Apache-2.0), `crc16_modbus.lua` / `crc8.lua` (self-written), `hexdump.lua` | see `protocol/README.md` (copied along) |
| `libs/lua51/` | `third_party/lua51-libs/` | Lua-for-Windows 5.1.5 pure-Lua subset: A-tier top-level files (`30log`, `binary_heap`, `lcs`, `luaunit`, `moses`, `serialize`, `set`, `std`, `strict*`, `strbuf`), `stdlib-ext/` (base/list/object/parser/getopt/*_ext — mutate built-ins, file-present checks only), `penlight/pl/` (MIT), `logging/` + `logging.lua` (LuaLogging, MIT) | per-file headers; summary table in `lua51/README.md` (copied along) |
| `libs/openresty/` | `third_party/openresty-lua/lualib/` | openresty win64 lualib subset: `tablepool.lua`, `resty/lrucache.lua` (patched), `resty/md5|sha*|aes|random.lua` (B-tier: OpenSSL FFI, load-or-fail), `resty/iconv.lua` (patched; needs `libiconv-2.dll` reachable from the runtime dir) | BSD-style (Yichun Zhang) per headers; `resty/iconv.LICENSE` (GPL-3.0, lua-resty-iconv) is copied next to `iconv.lua` |
| `libs/jit-tools/` | `third_party/openresty-lua/lua/jit/` | LuaJIT profiling / disassembler tooling (`jit/p.lua`, `v.lua`, `zone.lua`, `dump.lua`, `bc.lua`, `bcsave.lua`, `vmdef.lua`, `dis_*.lua`) required via `jit.*` in `test_openresty_lua.lua` | MIT (LuaJIT authors), per file headers |

## Usage

Tests are invoked from the repo root (`D:/workspace/SSCOM_lua`):

```
./xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_protocol_libs.lua   # 51 assertions
./xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_openresty_lua.lua   # 43 assertions
./xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_lua51-libs.lua      # 78 assertions
./xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_iconv.lua           #  9 assertions
```

`test_iconv.lua` needs `libiconv-2.dll`; it is found because
`runtime/luvjit.exe` sits next to it (ffi.load search order).

## Rules

- Do not edit files here by hand when `third_party/` is the upstream of
  record — fix the vendor tree and re-copy.
- `logging/socket.lua`, `logging/email.lua`, `logging/sql.lua`,
  `pl/import_into.lua` etc. are carried as-is (B-tier, never deep-executed).
