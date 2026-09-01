# XCOM ImGui bridge

This is the project-owned, narrow C ABI for LuaJIT over Dear ImGui, using the
Win32 + OpenGL2 backend. It deliberately does not build the vendored cimgui
sources: their generated API targets Dear ImGui 1.92.9b whereas this bridge
uses the vendored Dear ImGui 1.93.0 WIP sources under
`third_party/xcom_imgui/imgui`.

Build from the workspace root with:

```powershell
cmd /c "call D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat && ninja -C build/xcom-imgui"
Copy-Item build\xcom-imgui\xcom_imgui.dll xcom_lua\runtime\xcom_imgui.dll -Force
```

Dear ImGui is distributed under the MIT License. Its source remains vendored
in `third_party/xcom_imgui/imgui/`; retain its upstream copyright and license
notices when updating it.
The unused cimgui source remains in `cimgui/` with its own upstream license.
