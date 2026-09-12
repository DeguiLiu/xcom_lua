# XCOM Serial Tool

[简体中文](README_zh.md)

XCOM is a Windows serial debugging tool: a native C++17 core (`xcom_core`) plus a
LuaJIT + Dear ImGui client (`xcom_lua`) with async text/HEX I/O, timestamps,
auto-send, a Lua script system, a scope plot, and a D3D11/WARP renderer.

## Topology

```mermaid
flowchart LR
  EXE["xcom.exe launcher"] --> LJ["luvjit.exe<br/>LuaJIT UI thread<br/>Win32 loop + libuv"]
  LJ -->|"versioned C ABI (xcom.h v1.5)"| CORE["xcom_core.dll<br/>C++17 + coact"]
  LJ -->|"fixed C exports, int buffers"| IMG["xcom_imgui.dll<br/>ImGui + ImPlot / D3D11"]
  CORE --> D["coact Dispatcher thread"]
  CORE --> W["SessionWriter thread"]
  CORE --> R["serial read thread"]
  R <--> COM[("COM port")]
  W --> COM
  D -->|"Rx pool -> DisplayLane"| LJ
```

## Dependencies

```mermaid
flowchart LR
  MAIN["main.lua"] --> UI["ui/*.lua"]
  MAIN --> CORE["core/*.lua"]
  UI --> BR["imgui_bridge.lua"] --> IMGDLL["xcom_imgui.dll"]
  CORE --> FFI["xcom_ffi.lua"] --> COREDLL["xcom_core.dll"]
  COREDLL --> COACT["coact framework"]
  IMGDLL --> VEND["third_party: imgui + implot"]
  CORE --> LIBS["libs/ vendored pure-Lua"]
```

- `xcom_core/` — versioned C ABI DLL and Win32 OVERLAPPED serial backend;
  `framework/coact/` is the sole business event runtime (AO/HSM/bounded queues).
- `xcom_lua/` — production client: pure-Lua `ui/` + `core/`, the `xcom_imgui`
  bridge DLL and the `xcom_ffi` ABI binding.
- `xcom_lua/native/launcher/` — Win32 `xcom.exe` with a hidden console.
- `xcom_client/` — legacy PySide6 client, reference only; `docs/` — design docs.

## Prerequisites

- Windows x64; to build: MSVC x64 Developer PowerShell, CMake 3.21+, Ninja.
- Runtime in `xcom_lua/runtime/`: `luvjit.exe` + `lua51.dll`/`luv.dll`
  (provenance in `xcom_lua/runtime/README.md`).

## Build

```powershell
cd xcom_lua\native\xcom_imgui && build_imgui.cmd   # xcom_imgui.dll -> runtime/
cd ..\..                                          # repo root
cmake --preset native-release && cmake --build --preset build-native-release
```

The root build produces `xcom_core.dll` (into `build/native-release/bin`) and the
`xcom.exe` launcher (into `xcom_lua/runtime`). The ImGui bridge has its own
CMakeLists and is not referenced by the root project.

## Bytecode

App modules ship as `.ljbc`; `require` prefers bytecode over `.lua`. Rebuild after
editing `main.lua` / `core/*.lua` / `ui/*.lua` (`scripts/` and `libs/` stay source):

```powershell
cd xcom_lua
powershell -ExecutionPolicy Bypass -File build_bytecode.ps1 -Incremental
```

## Run

```powershell
cd xcom_lua
runtime\luvjit.exe main.lua    # source checkout
runtime\xcom.exe               # packaged launcher (main.ljbc, no console)
```

`xcom.exe` prefers `main.ljbc` and falls back to `main.lua`; set `XCOM_CORE_DLL`
to point at a specific `xcom_core.dll`.

## Release

```powershell
powershell -ExecutionPolicy Bypass -File build_release.ps1 -Version 1.4.0
```

Produces `dist/xcom-release-v1.4.0.zip`: app modules as `.ljbc` only, `libs/` and
`scripts/` verbatim, and `runtime/` with exes, DLLs and `assets/`.

## Tests

```powershell
runtime\luvjit.exe tests\test_script_engine.lua
runtime\luvjit.exe tests\stress_warp_ui.lua 30 90   # 30 s @ ~90 KiB/s
```

CI has four jobs: portable Lua suites, ABI layout pins and a C++ syntax gate on
Linux, plus the MSVC build and `ctest` on Windows. See `xcom_lua/tests/`.
