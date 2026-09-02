# xcom_lua runtime bundle

This directory contains the generated/downloaded Windows runtime bundle for
the LuaJIT client. These files are not hand-edited source: they are a
convenience bundle for running a clean checkout on Windows. A developer can
delete this directory and rebuild/download the same components locally.

| File | Provenance |
| --- | --- |
| `luvjit.exe`, `lua51.dll`, `luv.dll` | Downloaded LuaJIT + libuv runtime |
| `xcom_imgui.dll` | Generated from `native/xcom_imgui` and vendored Dear ImGui |
| `xcom_core.dll` | Generated from the project `xcom_core` CMake target |
| `xcom.exe` | Small Win32 launcher with an embedded application icon |

Launch `xcom.exe` for the packaged client. It starts `luvjit.exe` from the
same directory with the parent `main.lua`, preserving the existing runtime
layout while giving Explorer and shortcuts a real application icon.

The bundle is intentionally isolated from source and build caches. The
launcher prefers a locally built `build/native-release/bin/xcom_core.dll` and
falls back to this directory when no local build is available. `luvjit.exe`
is the launcher runtime; `luajit.exe` is retained as a standalone compatibility
runtime for scripts that expect the standard executable name.
