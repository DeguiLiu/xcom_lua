# XCOM Serial Tool

[简体中文](README_zh.md)

XCOM is a Windows serial debugging tool with a native C++17 core (`xcom_core`)
and a LuaJIT + ImGui desktop client (`xcom_lua`). It provides asynchronous
text/HEX receive and send, timestamps, auto-send, ten editable quick-send
entries, serial parameter control, bounded receive-log saving, a script/plugin
system, and a hardware-first D3D11 renderer with a WARP software fallback.

## Architecture

- `xcom_core/` — versioned C ABI DLL and the Win32 OVERLAPPED serial backend.
- `xcom_core/framework/coact/` — project-owned AO, HSM, bounded-queue and
  fixed-pool framework; the sole business event runtime.
- `xcom_lua/` — the production client. A LuaJIT front-end drives the ImGui
  dashboard through a `xcom_imgui` bridge DLL (`native/xcom_imgui`), a thin
  `xcom_ffi` FFI binding to `xcom_core`, and a `ui/` + `core/` split of pure-Lua
  application modules.
- `xcom_lua/native/launcher/` — a small Win32 `xcom.exe` that spawns `luvjit.exe`
  with a hidden console and closes itself when the client exits.
- `luajit2-2.1-agentzh/` — vendored LuaJIT 2.1 source (the
  [openresty/luajit2](https://github.com/openresty/luajit2) branch), built with
  MSVC into the client runtime (`xcom_lua/runtime/luajit.exe` + `lua51.dll`)
  via `build_msvc.cmd`.
- `xcom_client/` — legacy PySide6 client (superseded by `xcom_lua`); kept for
  reference. Its `CoreWorker` was the only ctypes caller.
- `docs/` — design, ABI, implementation and status documents.

`WinSerialBackend` is the only production COM path. It uses one read thread,
fixed-capacity data lanes, a static coact `RxKick` wakeup, and HSM-owned port
state. File writing is asynchronous and bounded, so it cannot block reception.

## Prerequisites

### LuaJIT client (`xcom_lua`)

- Windows x64.
- A LuaJIT runtime in `xcom_lua/runtime/`: `luvjit.exe` (with libuv) plus the
  `lua51.dll`/`luv.dll` companions. See `xcom_lua/runtime/README.md` for
  provenance.
- To rebuild the ImGui bridge: MSVC x64 Developer PowerShell, CMake 3.21+ and
  Ninja.

### Native core (`xcom_core`)

- MSVC x64 Developer PowerShell, CMake 3.21+ and Ninja.

## Build

**ImGui bridge DLL** (from an MSVC Developer PowerShell):

```powershell
cd xcom_lua\native\xcom_imgui
build_imgui.cmd
```

This compiles `xcom_imgui.dll` and copies it into `xcom_lua/runtime/`.

**Native core DLL** (`xcom_core.dll`) configures with its own CMake preset; the
runtime bundle in `xcom_lua/runtime/` carries a copy for the LuaJIT client.

## Bytecode

Application modules are shipped as LuaJIT bytecode (`.ljbc`) so the release
bundle does not expose editable source. `require` prefers `.ljbc` over `.lua`.

Rebuild bytecode after changing any `main.lua` or `core/*.lua` / `ui/*.lua`:

```powershell
powershell -ExecutionPolicy Bypass -File build_bytecode.ps1
# incremental: only recompile modules whose source changed
powershell -ExecutionPolicy Bypass -File build_bytecode.ps1 -Incremental
```

`scripts/` and `libs/` are deliberately **not** byte-compiled: `scripts/` stays
editable user code and `libs/` is vendored third-party Lua.

## Run

```powershell
cd xcom_lua
runtime\luvjit.exe main.lua          # source checkout
runtime\xcom.exe                      # packaged launcher (main.ljbc, no console)
```

`xcom.exe` prefers `main.ljbc` and falls back to `main.lua`. Set `XCOM_CORE_DLL`
to point at a specific `xcom_core.dll`.

## Release package

```powershell
cd xcom_lua
powershell -ExecutionPolicy Bypass -File build_release.ps1 -Version 1.4.0
```

Produces `dist/xcom-release-v1.4.0.zip`. The package ships app modules as
`.ljbc` only (no `.lua`), keeps `libs/` and `scripts/` verbatim, and includes
`runtime/` (exes, DLLs and `assets/` with `layout.toml` + fonts).

## Tests

From `xcom_lua`:

```powershell
runtime\luvjit.exe tests\test_script_engine.lua
runtime\luvjit.exe tests\test_send_file_caps.lua
runtime\luvjit.exe tests\stress_warp_ui.lua 30 90   # 30 s @ ~90 KiB/s
```

See `xcom_lua/tests/` for the full suite and `docs/` for the design documents.
