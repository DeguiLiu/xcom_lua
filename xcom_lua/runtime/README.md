# xcom_lua runtime bundle

This directory contains the Windows runtime bundle for the LuaJIT client.
These files are not hand-edited source: they are build outputs or vendored
dependencies. A developer can delete this directory and rebuild them from the
sources documented below.

| File | Provenance |
| --- | --- |
| `luajit.exe`, `lua51.dll` | LuaJIT 2.1, built with MSVC from the **openresty/luajit2** checkout at `../luajit2-2.1-agentzh`. Build with `../luajit2-2.1-agentzh/build_msvc.cmd`. |
| `luvjit.exe`, `luv.dll` | LuaJIT + libuv (luv) runtime, used by the packaged launcher |
| `xcom_imgui.dll` | Generated from `native/xcom_imgui` and vendored Dear ImGui (MSVC) |
| `xcom_core.dll` | Generated from the project `xcom_core` CMake target (MSVC) |
| `xcom.exe` | Small Win32 launcher with an embedded application icon |

## LuaJIT dependency

We depend on **[openresty/luajit2](https://github.com/openresty/luajit2)** —
the OpenResty-maintained LuaJIT 2.1 branch (agentzh). The vendored source
checkout lives at `../luajit2-2.1-agentzh` and is built with MSVC:

```cmd
cd D:\workspace\SSCOM_lua\luajit2-2.1-agentzh
build_msvc.cmd
```

This produces `luajit.exe` and `lua51.dll` and copies them here. The build
uses `/MD` (dynamic Universal CRT), so the resulting `lua51.dll` depends on
`VCRUNTIME140.dll` and the Universal CRT (`api-ms-win-crt-*.dll`). Target
machines need the VS 2015-2022 x64 Redistributable, or the release package
must bundle `vcruntime140.dll` / `msvcp140.dll` alongside the runtime.

Launch `xcom.exe` for the packaged client. It starts `luvjit.exe` from the
same directory with the parent `main.lua`, preserving the existing runtime
layout while giving Explorer and shortcuts a real application icon.

Run the Windows integration check from `xcom_lua` with:
`runtime\\luajit.exe tests\\integration_test.lua`

For a real serial loop, pass an available port (the test injects a receive
frame through the production receive path and then closes the port):
`runtime\\luajit.exe tests\\serial_integration_test.lua COM4`

To verify bytes from another process or a physical peer, use the external
receive check (it does not call the injection seam):
`runtime\\luajit.exe tests\\serial_external_receive_test.lua COM3 5000`

The `help` smoke command includes an LF terminator:
`runtime\\luajit.exe tests\\send_help_test.lua COM3`

The bundle is intentionally isolated from source and build caches. The
launcher prefers a locally built `build/native-release/bin/xcom_core.dll` and
falls back to this directory when no local build is available. `luvjit.exe`
is the launcher runtime; `luajit.exe` is retained as a standalone compatibility
runtime for scripts that expect the standard executable name.

For a release package, generate optional LuaJIT bytecode with:
`powershell -ExecutionPolicy Bypass -File ..\build_bytecode.ps1 -OutputRoot .\bytecode`
The entry point searches `.ljbc` before `.lua`, so development checkouts and
partially packaged bundles continue to work without bytecode files.
