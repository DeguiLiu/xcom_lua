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

## Runtime assets

The bridge resolves its assets **relative to the DLL**, i.e. from
`xcom_lua/runtime/assets/`. The POST_BUILD rules in this directory's
`CMakeLists.txt` refresh them, so a build is what keeps the running copy in
step with the sources:

| Asset | Source of truth | Notes |
| --- | --- | --- |
| `layout.toml` | `native/xcom_imgui/layout.toml` | layout metrics, `[ui] language`, `[font] show_chinese_in_receive`, `[colors]` text colours (read at startup) |
| `fonts/SimHeiCJK.ttf` | `xcom_lua/assets/fonts/SimHeiCJK.ttf` | bundled CJK subset, ~1.1 MB: GB2312 symbols + level-1 hanzi + CJK/fullwidth punctuation. Regenerate with `python3 tools/build_cjk_subset.py` (it subsets the SimHei that ships with Windows and refuses to write when existing glyph outlines would change); never edit it by hand |
| `fonts/SiemensSlab*.ttf` | `XCOM_REFERENCE_FONTS_DIR` | Latin body/heading faces |

## Keeping the committed DLL in step

`xcom_lua/runtime/xcom_imgui.dll` and `xcom_core.dll` are committed artifacts,
and the Lua layer is written to degrade silently when the DLL behind it is
older (that is what `optional_export` / `optional_symbol` do). A source change
whose rebuild never happened therefore looks like "the feature does nothing",
which has shipped twice.

`tools/check_dll_exports.sh` catches it from the source side: it reads the PE
export tables with `objdump` and fails when a function the Lua cdefs declare is
missing from the committed binary. It runs in CI and needs no Windows host.

A Linux host cannot produce the shipping artifact (MSVC Release + LTCG is what
the committed DLLs are built with), but it *can* build a verification copy:
install `g++-mingw-w64-x86-64`, point CMake at it with a toolchain file, and
build. The bridge and the core both compile and link this way -- the only
non-default knobs are `-D_WIN32_WINNT=0x0A00` (`CancelIoEx`,
`CancelSynchronousIo` and the Dwm* APIs are hidden behind that macro, which
mingw defaults below) and linking `dwmapi` for `imgui_impl_win32.cpp` (see the
note in `CMakeLists.txt`). The result is a DLL with no non-system dependency
(`KERNEL32`, `msvcrt`, `d3d11`, `dwmapi`, `GDI32`, `SHELL32`, `USER32`) and the
same export set -- useful to confirm a fix compiles and links before a Windows
rebuild, but **not** to ship: the mingw binaries are roughly an order of
magnitude larger (the static C++ runtime and no LTCG).

The DXGI swap chain uses the Windows 10 flip-discard path and a single-threaded
device. The core release build keeps its fixed receive/display pools bounded;
copying an older core DLL can otherwise add tens of megabytes of committed data.

Dear ImGui is distributed under the MIT License. Its source remains vendored
in `third_party/xcom_imgui/imgui/`; retain its upstream copyright and license
notices when updating it.
The unused cimgui source remains in `cimgui/` with its own upstream license.
