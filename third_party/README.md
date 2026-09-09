# `third_party/` — Vendored dependencies for xcom_lua

All third-party code that xcom_lua consumes without going through a package
manager lives here. The tree is intentionally flat (one directory per upstream
project) so each subtree can be diffed, updated, or replaced in isolation.

Two halves, distinguished by whether LuaJIT is involved at runtime:

| Half | Subdirs | LuaJIT? |
|---|---|---|
| **GUI / native bridge** (built into `xcom_imgui.dll`) | `imgui*`, `cimgui*`, `LuaJIT-ImGui`, `xcom_imgui` | C/C++; LuaJIT accesses via FFI into the resulting DLL. |
| **Pure Lua / LuaJIT libraries** (consumed directly via `require`) | `openresty-lua`, `lua51-libs` | Pure Lua + FFI; loaded by LuaJIT at runtime. |

`*.zip` files at the top level (`imgui.zip`, `imgui_1929.zip`, `cimgui.zip`)
are the **source archives** that the matching `_extract` directories were
unpacked from. They are kept as-is so a future re-extraction is reproducible
without re-downloading.

---

## Tree summary

| Path | Purpose | Language | Built into | LuaJIT consumable? |
|---|---|---|---|---|
| `imgui.zip` | Source archive of Dear ImGui `docking` branch (older) | C++ | archive only | n/a |
| `imgui_extract/imgui-docking/` | Dear ImGui `docking` source (extracted from `imgui.zip`) | C++ | `xcom_imgui.dll` (via `cimgui`) | via `xcom_imgui` binding |
| `imgui_1929.zip` | Source archive of Dear ImGui **v1.92.9** | C++ | archive only | n/a |
| `imgui_1929_extract/` | Dear ImGui v1.92.9 extracted | C++ | not built yet (kept for future upgrade) | via future binding |
| `cimgui.zip` | Source archive of `cimgui` (C wrapper over ImGui) | C | archive only | n/a |
| `cimgui_extract/cimgui-docking_inter/` | cimgui extracted (docking variant) | C | `xcom_imgui.dll` | via `xcom_imgui` |
| `LuaJIT-ImGui/` | Lua-side binding generator + Lua sources that call into cimgui | Lua + generator | consumed by `xcom_lua` | yes |
| `xcom_imgui/` | Project-owned ImGui bridge: cimgui glue + Lua FFI shim + implot | C + Lua + (build glue) | produces `xcom_imgui.dll` | yes (FFI into the DLL) |
| `openresty-lua/` | Patched subset of `openresty-1.29.2.1-win64` lua/lualib | Lua + FFI | — | **yes (LuaJIT only)** |
| `lua51-libs/` | Pure-Lua libraries from `D:\develop\Lua\5.1` (LfW) | Lua | — | **yes (LuaJIT only)** |

---

## 1. `imgui*`, `cimgui*` — Dear ImGui C++ source

The Dear ImGui immediate-mode GUI library. Used in xcom_lua via `xcom_imgui`.

| Subdir | Version / Branch | Notes |
|---|---|---|
| `imgui_extract/imgui-docking/` | docking branch (slightly older) | Currently the one compiled into `xcom_imgui.dll`. |
| `imgui_1929_extract/` | v1.92.9 | Newer release; extracted but **not yet wired in**. |
| `cimgui_extract/cimgui-docking_inter/` | docking variant of cimgui | The C interface that `LuaJIT-ImGui` and `xcom_imgui` bind to. |

License: **MIT** (Dear ImGui, Omar Cornut; cimgui, see its README).

Not directly loaded by LuaJIT — these are compiled into `xcom_imgui.dll` and
exposed to Lua via FFI.

## 2. `LuaJIT-ImGui/`

Lua-side scaffolding for calling ImGui from LuaJIT. Originally by Victor Bombí
(2017-2019), MIT license. Contains:

- `lua/` — Lua modules exposing ImGui draw calls
- `cimgui/`, `cimguizmo/`, `cimplot/`, `cimnodes/`, `cimCTE/` — vendored C
  source for the additional widgets (plot, gizmo, node editor, ...). Most of
  these are **not used by xcom_lua** — kept in case a future feature needs
  them.
- `build/`, `examples/`, `extras/` — upstream generator tooling, not consumed
  at runtime.

LuaJIT consumable: **yes**, but xcom_lua uses its own `xcom_imgui` binding
layer (see below) rather than calling `LuaJIT-ImGui`'s Lua modules directly.

## 3. `xcom_imgui/`

Project-owned ImGui bridge. This is **not** an unmodified upstream — it is the
layer that `xcom_lua` actually depends on. It:

- wraps the cimgui functions the project uses
- provides Lua-callable FFI bindings
- integrates implot for the waveform/spectrum views

Builds into `xcom_lua/runtime/xcom_imgui.dll`, loaded by the runtime at boot.

## 4. `openresty-lua/` — LuaJIT-compatible subset of OpenResty

Patched subset of `openresty-1.29.2.1-win64`. Vendored under a single directory
with its own README explaining what's A-tier (works), B-tier (needs OpenSSL/lib
binding), C-tier (nginx-only, not vendored).

| What | Lua? | FFI? | LuaJIT-compatible? | Status |
|---|---|---|---|---|
| `lua/jit/*.lua` (20 files: `bc`, `bcsave`, `dis_*`, `dump`, `p`, `v`, `vmdef`, `zone`) | pure Lua | — | **yes** | A — usable as-is |
| `lualib/tablepool.lua` | pure Lua | — | **yes** | A — usable as-is |
| `lualib/resty/lrucache.lua` | pure Lua | minor FFI struct | **yes** | A — **patched** to drop `ngx.now`/`ngx.log` |
| `lualib/resty/md5.lua`, `sha*.lua`, `aes.lua`, `random.lua` | pure Lua | yes (OpenSSL EVP cdef) | needs **OpenSSL FFI binding** | B — files present, fails at first call until `libcrypto` is loaded |
| `lualib/resty/iconv.lua` | pure Lua | yes (libiconv cdef) | **yes** (Windows needs libiconv-2.dll alongside `lua51.dll`; load it via `ffi` then `require`) | A — **patched** (1) detect both `iconv_open` + `libiconv_open` symbol sets; (2) don't `iconv_close` the `-1` sentinel (MinGW libiconv segfaults). GPL-3.0; 9 smoke assertions pass |

Test: `xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_openresty_lua.lua`
and `xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_iconv.lua`.

See `openresty-lua/README.md` for full provenance, license, and patches.

## 5. `lua51-libs/` — curated Lua-for-Windows pure-Lua libraries

Subset of `D:\develop\Lua\5.1\lua\` (Lua for Windows 5.1.5 installer snapshot).
Filtered for **LuaJIT 2.1 + pure Lua + project-applicable**.

| What | Lua? | FFI? | LuaJIT-compatible? | Status |
|---|---|---|---|---|
| `penlight/pl/*.lua` (39 modules) | pure Lua | — | **yes** | A |
| `logging.lua` + `logging/console.lua`, `file.lua`, `rolling_file.lua` | pure Lua | — | **yes** | A |
| `logging/email.lua`, `socket.lua`, `sql.lua` | pure Lua | — | needs **luasocket / LuaSQL** | B |
| `moses.lua` | pure Lua | — | **yes** | A |
| `luaunit.lua` (v2.0) | pure Lua | — | **yes** | A |
| `binary_heap.lua`, `classlib.lua`, `lcs.lua`, `object.lua`, `parser.lua`, `serialize.lua`, `set.lua`, `std.lua`, `strict.lua`, `strictness.lua`, `30log.lua` | pure Lua | — | **yes** | A |
| `penlight/pl/path.lua`, `pl/dir.lua` | pure Lua | soft-requires `lfs` (LuaFileSystem) | **partial** (load OK, lfs-dependent ops fail) | B |
| `stdlib-ext/string_ext.lua`, `table_ext.lua`, `math_ext.lua`, `io_ext.lua`, `package_ext.lua` | pure Lua | — | **yes, BUT mutates LuaJIT built-ins** | **B — do NOT require in xcom_lua** |
| `base.lua`, `list.lua`, `getopt.lua`, `stdlib-ext/getopt.lua` | pure Lua | — | **yes** | A |

Counts: **67 .lua files**, MIT/X11/permissive across the board, no GPL.

The single biggest warning is `stdlib-ext/*.lua` — every file there mutates a
LuaJIT built-in (`string`, `table`, `math`, `io`, `package`) at require-time.
Requiring any one pollutes the global namespace for the rest of the process
and **can interfere with xcom_lua's hot paths**. Use Penlight's `pl.stringx` /
`pl.tablex` / `pl.utils` instead — they are non-mutating and cover the same
surface.

Test: `xcom_lua/runtime/luvjit.exe xcom_lua/tests/test_lua51-libs.lua`
(also covers each top-level A-tier file).

See `lua51-libs/README.md` for the full per-file classification.

---

## LuaJIT compatibility matrix (at a glance)

| Subtree | Runtime in LuaJIT? | Pure Lua? | Built into LuaJIT already? |
|---|---|---|---|
| `imgui*` / `cimgui*` | indirect (FFI into `xcom_imgui.dll`) | no — C/C++ | n/a |
| `LuaJIT-ImGui/` | yes | mostly Lua | partial (consumed via `xcom_imgui`) |
| `xcom_imgui/` | yes (FFI bridge) | mixed C + Lua | no |
| `openresty-lua/lua/jit/` | **yes** | yes | overlaps with LuaJIT's own bundled `jit.*` — vendored to keep version matched |
| `openresty-lua/lualib/tablepool.lua` | **yes** | yes | no |
| `openresty-lua/lualib/resty/lrucache.lua` | **yes** (patched) | yes | no |
| `openresty-lua/lualib/resty/{md5,sha*,aes}.lua` | partial | yes | no — OpenSSL FFI binding missing |
| `openresty-lua/lualib/resty/iconv.lua` | **yes** (patched) | yes | no — libiconv must be loadable |
| `lua51-libs/penlight/pl/**` | **yes** | yes | no |
| `lua51-libs/logging.lua` + `logging/{console,file,rolling_file}.lua` | **yes** | yes | no |
| `lua51-libs/{moses,luaunit,binary_heap,classlib,lcs,object,parser,serialize,set,std,strict,strictness,30log}.lua` | **yes** | yes | no |
| `lua51-libs/{base,list,getopt}.lua` | **yes** | yes | no |
| `lua51-libs/logging/{email,socket,sql}.lua` | partial | yes | no — needs luasocket / LuaSQL |
| `lua51-libs/stdlib-ext/**` | yes BUT mutates built-ins | yes | **no** — never require in xcom_lua |

---

## How `xcom_lua` consumes these

`xcom_lua/main.lua` (and the per-test files) prepends paths like:

```
third_party/lua51-libs/?.lua
third_party/lua51-libs/?/init.lua
third_party/lua51-libs/penlight/?.lua
third_party/lua51-libs/penlight/?/init.lua
third_party/openresty-lua/lualib/?.lua
third_party/openresty-lua/lua/?.lua
package.path  (the LuaJIT default)
```

so standard names resolve as:

```lua
local utils   = require "pl.utils"        -- Penlight
local stringx = require "pl.stringx"
local tablex  = require "pl.tablex"
local logger  = require "logging"
local lru     = require "resty.lrucache"
local iconv   = require "resty.iconv"
local moses   = require "moses"
```

`xcom_imgui` is reached through `ffi.load("xcom_imgui")` rather than `require`,
because the latter would mean a Lua wrapper module not shipped in this tree —
the FFI binding lives directly inside the C-side Lua bridge.

---

## What is intentionally **not** here

- **`luarocks` / `opm` install paths.** This tree is offline-friendly. To add
  a new dependency, vendor it explicitly with provenance and a smoke test.
- **`.so` / `.dll` libraries from `D:\develop\Lua\5.1`** (lfs.dll, luasocket,
  LuaXML_lib.dll, lpeg.dll, ...). They would either need to be built for
  LuaJIT 2.1 ABI (not Lua 5.1) and dropped into `xcom_lua/runtime/`, or be
  wrapped behind explicit FFI `cdef` calls.
- **LuaJIT 2.1 interpreter itself.** Lives at `luajit2/` (source) and is built
  to `xcom_lua/runtime/luajit.exe` + `lua51.dll`.

---

## Update cadence

| Subtree | Re-sync from | Notes |
|---|---|---|
| `imgui*` | upstream `ocornut/imgui` releases | Keep `imgui.zip` as the canonical archive; re-extract on bump. |
| `cimgui*` | upstream `cimgui/cimgui` | same. |
| `LuaJIT-ImGui/` | upstream `vimfaker/LuaJIT-ImGui` | rarely; the project uses `xcom_imgui/` instead. |
| `xcom_imgui/` | **project-owned** | edit in place; do not sync from upstream. |
| `openresty-lua/` | `D:/workspace/SSCOM_lua/openresty-1.29.2.1-win64/` | See `openresty-lua/README.md` for the diff procedure. |
| `lua51-libs/` | `D:/develop/Lua/5.1/lua/` | See `lua51-libs/README.md` for the A/B/C list to extend. |