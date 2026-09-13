# XCOM Serial Tool

[简体中文](README_zh.md)

XCOM is a Windows serial debugging tool: a native C++17 core (`xcom_core`) plus a
LuaJIT + Dear ImGui client (`xcom_lua`) with async text/HEX I/O, timestamps,
auto-send, a Lua script system, a scope plot, and a D3D11/WARP renderer.

## Topology

```mermaid
flowchart LR
  classDef proc fill:#E8F0FE,stroke:#2E5AAC,color:#111,stroke-width:1.5px
  classDef dll fill:#FDE9D9,stroke:#C55A11,color:#111
  classDef th fill:#E2F0D9,stroke:#548235,color:#111

  EXE["xcom.exe<br/>launcher"]:::proc -->|"hidden console"| LJ["luvjit.exe<br/>LuaJIT UI thread<br/>Win32 loop + libuv"]:::proc
  LJ -->|"versioned C ABI<br/>xcom.h v1.5"| CORE["xcom_core.dll<br/>C++17 + coact"]:::dll
  LJ -->|"fixed C exports<br/>int buffers"| IMG["xcom_imgui.dll<br/>ImGui + ImPlot / D3D11"]:::dll
  CORE --> D["coact Dispatcher"]:::th
  CORE --> W["SessionWriter"]:::th
  CORE --> R["serial read"]:::th
  R <-->|"OVERLAPPED"| COM[("COM port")]
  W -->|"OVERLAPPED"| COM
  D -->|"Rx pool -> DisplayLane"| LJ
```

## Dependencies

```mermaid
flowchart LR
  classDef lua fill:#D6E4FF,stroke:#2E5AAC,color:#111
  classDef cpp fill:#FDE9D9,stroke:#C55A11,color:#111
  classDef ext fill:#F2F2F2,stroke:#7F7F7F,color:#111

  MAIN["main.lua"]:::lua --> UI["ui/*.lua"]:::lua
  MAIN --> CORE["core/*.lua"]:::lua
  UI --> BR["imgui_bridge.lua"]:::lua --> IMGDLL["xcom_imgui.dll"]:::cpp
  CORE --> FFI["xcom_ffi.lua"]:::lua --> COREDLL["xcom_core.dll"]:::cpp
  IMGDLL --> VEND["imgui + implot"]:::ext
  COREDLL --> COACT["coact framework<br/>AO / HSM / bounded queues"]:::cpp
  CORE --> LIBS["libs/<br/>vendored pure-Lua"]:::ext
```

- `xcom_core/` — versioned C ABI DLL and Win32 OVERLAPPED serial backend;
  coact is the sole business event runtime (AO / HSM / bounded queues / fixed pools).
- `xcom_lua/` — production client: pure-Lua `ui/` + `core/`, the `xcom_imgui`
  bridge DLL and the `xcom_ffi` ABI binding.
- `xcom_lua/native/launcher/` — Win32 `xcom.exe` with a hidden console.
- `docs/` — architecture, design summary, performance and coding conventions.

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

## Run

```powershell
cd xcom_lua
runtime\luvjit.exe main.lua    # source checkout
runtime\xcom.exe               # packaged launcher (main.ljbc, no console)
```

`xcom.exe` prefers `main.ljbc` and falls back to `main.lua`; set `XCOM_CORE_DLL`
to point at a specific `xcom_core.dll`.

Design docs: `docs/architecture.md` (architecture) and
`docs/design-summary.md` (design summary). For a narrative overview of the
LuaJIT + C++ split and the plugin model, see `docs/technical-overview.md`.
