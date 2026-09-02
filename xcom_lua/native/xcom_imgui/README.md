# XCOM ImGui bridge

This is the project-owned, narrow C ABI for LuaJIT over Dear ImGui, using the
Win32 + DirectX 11 backend. The renderer owns a small DXGI swap chain and
recreates its render target on `WM_SIZE`, avoiding the WGL/OpenGL context that
was previously responsible for most of the graphics working-set overhead. It
deliberately does not build the vendored cimgui
sources: their generated API targets Dear ImGui 1.92.9b whereas this bridge
uses the vendored Dear ImGui 1.93.0 WIP sources under
`third_party/xcom_imgui/imgui`.

Build from the workspace root with:

```powershell
cmd /c "call D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat && ninja -C build/xcom-imgui"
Copy-Item build\xcom-imgui\xcom_imgui.dll xcom_lua\runtime\xcom_imgui.dll -Force
```

The packaged runtime should also receive the matching optimized core binary:

```powershell
Copy-Item build\native-release\bin\xcom_core.dll xcom_lua\runtime\xcom_core.dll -Force
```

The DXGI swap chain uses the Windows 10 flip-discard path and a single-threaded
device. The core release build keeps its fixed receive/display pools bounded;
copying an older core DLL can otherwise add tens of megabytes of committed data.

Dear ImGui is distributed under the MIT License. Its source remains vendored
in `third_party/xcom_imgui/imgui/`; retain its upstream copyright and license
notices when updating it.
The unused cimgui source remains in `cimgui/` with its own upstream license.
