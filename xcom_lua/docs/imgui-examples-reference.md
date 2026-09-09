# ImGui 官方 examples 研究参考（面向 xcom_imgui_bridge.cpp UI 重设计）

> 研究对象：`D:\workspace\SSCOM_lua\ref\imgui\`（官方 Dear ImGui 完整仓库，`IMGUI_VERSION "1.93.0 WIP"`，`IMGUI_VERSION_NUM 19295`，见 `imgui.h:32-33`）。
> 对照项目：`D:\workspace\SSCOM_lua\xcom_lua\native\xcom_imgui\xcom_imgui_bridge.cpp`（全文 1790 行；下文简称 **bridge.cpp**），实际编译用的 ImGui 副本在 `D:\workspace\SSCOM_lua\third_party\xcom_imgui\imgui\`（`IMGUI_VERSION_NUM 19294`，同为 1.93.0 WIP，仅落后 1 个内部修订号）。
> 注：早前 `docs/imgui-patterns-reference.md` 记载 `ref\imgui\` 是空 clone——现已不是，本次研究全部基于其工作区文件，行号已逐条用 Read/Grep 核实（2026-09-04）。
> 帧节奏背景（Lua 侧）：`xcom_lua/ui/window.lua:1130-1132` 定义 16 ms（交互）/ 100 ms（数据）/ 500 ms（空闲）三档帧间隔；`render_imgui()` 在 `window.lua:1164-1212`。

---

## 1. examples/ 目录总览（清单与适用场景）

官方 examples = "standalone applications showcasing integration with platforms/graphics api"（`examples/README.txt:7`），全部使用 `backends/` 里的标准后端。对 xcom_lua 有参考价值的分层如下：

### 1.1 直接对口（Win32 原生 + D3D）

| 示例 | 后端组合 | 对我们的价值 |
|---|---|---|
| **example_win32_directx11/** | `imgui_impl_win32.cpp` + `imgui_impl_dx11.cpp` | **最高**。与我们 bridge 完全同栈（Win32 + DX11 + WARP），主循环/WndProc/清屏/交换链是标准答案，见第 2 节 |
| example_win32_directx12/ | win32 + dx12 | 中。其主循环比 DX11 版多两处健壮性处理（`IsIconic` 判断、tearing 支持），值得抄思路 |
| example_win32_directx9 / directx10 | win32 + dx9/dx10 | 低。DX9 的 fixed-pipeline 渲染路径对我们无意义 |
| example_win32_opengl3 / vulkan | win32 + gl3/vulkan | 低。仅平台侧（win32）相同 |

### 1.2 渲染循环模式参考

| 示例 | 价值点 |
|---|---|
| **example_null/** | **帧生命周期最小骨架**（headless 无窗口），见第 3.1 节 |
| example_glfw_opengl3/ | vsync 开关（`glfwSwapInterval(1)`，main.cpp:76）+ 最小化节流（main.cpp:141-145）的跨平台写法 |
| example_sdl3_directx11/ | SDL 平台 + DX11 渲染的组合，resize 在主循环做（`g_pSwapChain->ResizeBuffers(0,0,0,...)`，main.cpp:128） |

### 1.3 其余（与本项目无关，仅备查）

- GLFW 系：glfw_opengl2（官方自评"一星，不推荐"）、glfw_opengl3（现代 GL，支持 Emscripten）、glfw_metal、glfw_vulkan、glfw_wgpu。
- SDL2/SDL3 系：各 8-9 个变体（metal/metal4/opengl2/opengl3/sdlrenderer/sdlgpu/vulkan/wgpu/directx11）。
- Apple 系：apple_metal / apple_metal4 / apple_opengl2 / apple_opengl3（main.mm）。
- 特殊平台：android_opengl3、glut_opengl2、qnx_opengl3、qnx_vulkan。
- `libs/`：第三方构建依赖（emscripten、glfw、usynergy 源码快照），非文档。
- `imgui_examples.sln`：VS 解决方案；`examples/README.txt`：总入口说明（Backends vs Examples 的定义 + "看 ShowDemoWindow 学 API" 的指引）。
- 各 example 目录下的 README.md（共 13 个，见 Glob 结果）基本都是 **构建说明**（CMake/Makefile/Emscripten），无渲染循环内容；唯一例外是 `example_glfw_wgpu/README.md` 有 Dawn/WGPU 版本矩阵，与本项目无关。

---

## 2. example_win32_directx11/main.cpp 详解（标准答案）

全文 286 行，是官方与我们后端组合完全一致的参考实现。

### 2.1 初始化顺序（main.cpp:31-95）

```
34   ImGui_ImplWin32_EnableDpiAwareness();                     // DPI 感知（进 Win32 后端动态加载 API，见下）
35   main_scale = ImGui_ImplWin32_GetDpiScaleForMonitor(...);   // 主显示器缩放
38-40 RegisterClassExW + CreateWindowW（尺寸乘 main_scale）
43   CreateDeviceD3D(hwnd)                                     // 先建设备/交换链
55-59 IMGUI_CHECKVERSION() → CreateContext() → io.ConfigFlags |= NavEnableKeyboard | NavEnableGamepad
62   ImGui::StyleColorsDark();                                 // 63 行注释着 StyleColorsLight()
66-68 style.ScaleAllSizes(main_scale); style.FontScaleDpi = main_scale;   // 烘焙缩放
71-72 ImGui_ImplWin32_Init(hwnd); ImGui_ImplDX11_Init(device, context);   // 先平台后渲染器
74-90 字体加载（注释形态，见第 4.4 节）
95   clear_color = ImVec4(0.45f, 0.55f, 0.60f, 1.00f);
```

要点：
- **DPI 感知必须在建窗口之前做**（main.cpp:34，注释明言 "Make process DPI aware"）。`ImGui_ImplWin32_EnableDpiAwareness()` 的实现（`backends/imgui_impl_win32.cpp:893-915`）优先 `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)`（Win10 1703+），降级 `SetProcessDpiAwareness`（Win8.1+）、`SetProcessDPIAware`；全部动态 GetProcAddress，不引入 SDK 版本依赖（头文件注释 `imgui_impl_win32.h:38-46`）。
- **ScaleAllSizes 是"烘焙"语义**：main.cpp:67 注释明言改缩放需重置 Style 再调一次（1.93 仍无动态 style 缩放，FAQ.md:796-808）。

### 2.2 渲染主循环（main.cpp:99-184）

```
103-110  while (PeekMessage(PM_REMOVE)) { TranslateMessage; DispatchMessage; WM_QUIT → done; }   // 非阻塞消息泵
114-120  if (g_SwapChainOccluded && Present(0, DXGI_PRESENT_TEST) == DXGI_STATUS_OCCLUDED)
             { ::Sleep(10); continue; }        // 最小化/被遮挡时 100 FPS 空转等待
122-129  if (g_ResizeWidth != 0 && g_ResizeHeight != 0)          // 延迟到主循环的 resize
             { CleanupRenderTarget(); ResizeBuffers(0,w,h,fmt,0); CreateRenderTarget(); }
132-134  ImGui_ImplDX11_NewFrame(); ImGui_ImplWin32_NewFrame(); ImGui::NewFrame();   // 先渲染器、再平台
136-171  UI 提交（ShowDemoWindow / 两个 Begin-End 窗口）
174      ImGui::Render();
175      clear_color_with_alpha = { c.x*c.w, c.y*c.w, c.z*c.w, c.w };   // ★ 预乘 alpha
176      OMSetRenderTargets(1, &g_mainRenderTargetView, nullptr);
177      ClearRenderTargetView(g_mainRenderTargetView, clear_color_with_alpha);
178      ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
181      Present(1, 0);                          // vsync；182 行注释 Present(0,0) 无 vsync
183      g_SwapChainOccluded = (hr == DXGI_STATUS_OCCLUDED);
```

三个容易被忽略的细节：
1. **清屏色预乘 alpha**（main.cpp:175）：DX11 交换链默认 premultiplied 混合，清屏时 RGB 要乘以 A。我们 `kClearColor`（bridge.cpp:1441）alpha=1，预乘是恒等变换，无实际影响，但写新清屏色时记得这个约定。
2. **遮挡检测 + Sleep(10)**（main.cpp:114-120）：最小化/被别的窗口完全遮挡时用 `DXGI_PRESENT_TEST` 探测，不渲染不呈现，10 ms 轮询。DX12 版更强（`example_win32_directx12/main.cpp:210-214`）：`(g_SwapChainOccluded && Present(TEST)==OCCLUDED) || ::IsIconic(hwnd)` 也直接跳过；GLFW 版等价物是 `glfwGetWindowAttrib(GLFW_ICONIFIED)`（`example_glfw_opengl3/main.cpp:141-145`）。
3. **Resize 延迟处理**：WM_SIZE 只排队尺寸（main.cpp:270-275），真正的 `ResizeBuffers` 在主循环做（123-129），避免在消息回调里碰 GPU 状态。

### 2.3 WndProc（main.cpp:263-285）

```cpp
265   if (ImGui_ImplWin32_WndProcHandler(hWnd, msg, wParam, lParam))
266       return true;                                  // ★ ImGui 处理器最先调用
270-275 case WM_SIZE:  SIZE_MINIMIZED 直接 return 0；否则只记录 g_ResizeWidth/Height（排队）
276-279 case WM_SYSCOMMAND: (wParam & 0xfff0) == SC_KEYMENU → return 0;   // 禁掉 ALT 系统菜单
280-282 case WM_DESTROY: PostQuitMessage(0);
284   return ::DefWindowProcW(...);
```

- **处理器顺序**：官方先喂 `ImGui_ImplWin32_WndProcHandler` 再走自己的 switch（main.cpp:265-266）。FAQ.md:187 强调"输入永远先给 ImGui"（`io.WantCaptureMouse/Keyboard` 只决定是否喂给自己的应用，不是是否喂给 ImGui）。
- **SC_KEYMENU 过滤**：防止按 ALT 弹出系统菜单破坏自绘标题栏的用户体验。

### 2.4 设备创建（main.cpp:200-232）

```
204-218 DXGI_SWAP_CHAIN_DESC：BufferCount=2、R8G8B8A8_UNORM、DISCARD、ALLOW_MODE_SWITCH、SampleDesc.Count=1
203    注释：更优是 DXGI_SWAP_EFFECT_FLIP_DISCARD（见官方 issue #8979）
220-226 D3D11CreateDeviceAndSwapChain(HARDWARE, FL 11_0/10_0) → 失败回退 D3D_DRIVER_TYPE_WARP
225    注释："Try high-performance WARP software driver if hardware is not available."
```

官方是"硬件优先、WARP 兜底"；我们是反过来的（bridge.cpp:1502-1504 直接 `D3D_DRIVER_TYPE_WARP` + `SINGLETHREADED | PREVENT_INTERNAL_THREADING_OPTIMIZATIONS`），这是刻意选择（WARP 软渲染行为可预期、避免驱动差异），但官方的 2 缓冲 + FLIP 建议仍然适用（见第 7 节建议 3）。

### 2.5 与 bridge 的逐项对照表

| 环节 | 官方 main.cpp | bridge.cpp | 差异评注 |
|---|---|---|---|
| 驱动模型 | 自主 `while(!done)` 循环（99-184） | 被动导出函数，Lua 侧 `render_imgui()` 驱动（window.lua:1164） | 架构差异，无对错；帧节奏在 Lua 层做（16/100/500 ms） |
| Init 顺序 | CreateContext → 风格 → 字体 → Win32_Init → DX11_Init（55-72） | 同序（bridge.cpp:1515-1565：CreateContext/StyleColorsLight/字体/apply_style/Win32_Init/DX11_Init） | 一致 |
| NewFrame 顺序 | DX11_NewFrame → Win32_NewFrame → NewFrame（132-134） | 同（bridge.cpp:1741-1743） | 一致（渲染器先、平台后） |
| Render | Render → 预乘清屏 → OMSet → Clear → RenderDrawData → Present（174-183） | 同，但 Present(0,0)（bridge.cpp:1752-1759） | 我们的 Present(0) 配合 Lua 帧间隔 + 交互期即时呈现（1756-1759 注释），合理 |
| 最小化/遮挡 | Present(TEST) + Sleep(10)（114-120） | C 侧无；Lua 侧 `_minimized` 时跳帧（window.lua:1170-1173） | 分层实现，等价；但"被其他窗口遮挡"未覆盖（见建议 2） |
| Resize | WM_SIZE 排队 → 主循环 ResizeBuffers（270-275, 123-129） | WM_SIZE 里立即 ResizeBuffers（bridge.cpp:1768-1781） | 我们是刻意的（被动帧模型下等待下一帧会拉长残影，1756-1759 有注释）；正确性上 `frame_active_` 期间释放 RTV 也安全（render() 有空指针守卫 1751） |
| WndProc | ImGui 处理器最先（265-266）；过滤 SC_KEYMENU（276-279） | 自己的 WM_SIZE/WM_EXITSIZEMOVE 先做，处理器最后（bridge.cpp:1768-1785）；不过滤 SC_KEYMENU | 输入类消息我们全部透传给处理器，语义上与官方一致（WM_SIZE 不被 ImGui 处理器消费）；SC_KEYMENU 可补 |
| Shutdown | DX11_Shutdown → Win32_Shutdown → DestroyContext（187-189） | 同序 + `frame_active_` 时先 EndFrame（bridge.cpp:1384-1387） | 我们多一层防御，正确 |
| 交换链 | BufferCount=2（206） | BufferCount=1（bridge.cpp:1489） | 见建议 3 |
| DPI | EnableDpiAwareness + ScaleAllSizes + FontScaleDpi（34-35, 66-68） | **无任何 DPI 处理** | 见建议 1（最重要差距） |

---

## 3. 帧生命周期与节流模式

### 3.1 example_null：最小帧骨架（main.cpp 全文 43 行）

```
19-20  ImGui_ImplNullPlatform_Init(); ImGui_ImplNullRender_Init();
22-36  for (n = 0; n < 20; n++) {
25-27     ImGui_ImplNullPlatform_NewFrame(); ImGui_ImplNullRender_NewFrame(); ImGui::NewFrame();
30-33     UI 提交（Text/SliderFloat/ShowDemoWindow）
35        ImGui::Render();
       }
39-41  Render_Shutdown → Platform_Shutdown → DestroyContext
```

这是**平台后端 NewFrame → 渲染后端 NewFrame → ImGui::NewFrame → UI → ImGui::Render** 的最纯形态，与 `docs/EXAMPLES.md:20-36` 的"Getting Started"20 行口诀一致。我们的 `xcom_imgui_new_frame()`/`xcom_imgui_render()`（bridge.cpp:1737-1746, 1748-1762）完全符合该骨架，且把 NewFrame/Render 拆成两个导出函数以适配被动驱动——这是对我们架构的正确适配，无需改动。

### 3.2 节流模式汇总（官方三处）

| 示例 | 代码 | 语义 |
|---|---|---|
| win32_dx11 | `Present(0, DXGI_PRESENT_TEST)==OCCLUDED → Sleep(10); continue;`（main.cpp:115-119） | 被**遮挡**（含最小化）时空转 |
| win32_dx12 | 同上 `\|\| ::IsIconic(hwnd)`（main.cpp:210-214） | 显式加最小化判断 |
| glfw_opengl3 | `glfwGetWindowAttrib(GLFW_ICONIFIED) → Sleep(10); continue;`（main.cpp:141-145）；vsync 开关 `glfwSwapInterval(1)`（76） | 最小化节流 + vsync |

官方没有"空闲降帧"（idle throttling）先例——它们要么 vsync 锁 60 FPS 全速跑，要么完全跳过。**我们 window.lua 的三档需求驱动帧间隔（16/100/500 ms + request_frame() 抢帧）比官方模式更精细**，属于本项目已经领先官方示例的地方；缺的只是"遮挡"这一档（见建议 2）。

### 3.3 其他 example 的杂项可借鉴点

- `example_win32_directx11/build_win32.bat:8`：`cl /utf-8`——官方自 2023-05 起所有 VS 工程强制 `/utf-8`（FONTS.md:541 有出处链接）。我们 CMakeLists.txt:31 已有 `/utf-8`，与官方一致。
- `imgui_impl_dx11.cpp`（后端本体，两个 example 共用）：
  - `io.BackendFlags |= ImGuiBackendFlags_RendererHasTextures`（third_party 副本 `imgui_impl_dx11.cpp:669`）——1.92+ 动态字体图集的关键开关，我们编译的副本已带。
  - 2026-04-23 起支持 `DrawCallback_SetSamplerLinear/Nearest`（changelog 第 20-21 行），字体纹理默认 LINEAR 采样（580-590 行建两个 sampler）。
- `docs/EXAMPLES.md:254-273` "About mouse cursor latency"：OS 硬件光标与渲染内容存在平滑度断层；`io.MouseDrawCursor` 仅在拖拽中临时开更佳。与我们接收区拖选（bridge.cpp:691-825）的体验调优相关。

---

## 4. 主题定制推荐做法（颜色 / 圆角 / 间距 / 字体 / DPI）

来源：`docs/FAQ.md`、`docs/FONTS.md`、`docs/README.md`、`imgui.h`、`imgui_demo.cpp`。

### 4.1 总原则

FAQ.md:932-941（"Can you reskin the look of Dear ImGui?"）：
> You can alter the look of the interface to some degree: **changing colors, sizes, padding, rounding, and fonts**. However ... the amount of skinning you can apply is limited.

官方明确定位：可换肤但有限度，`StyleColorsLight()` 的头文件注释（imgui.h:432）是 **"best used with borders and a custom, thicker font"**——浅色主题必须配边框和更粗的字体才好看。这正是我们目前的做法（bridge.cpp:1452-1453 `FrameBorderSize=1 / ChildBorderSize=1` + Siemens Slab 字体），方向正确。

### 4.2 颜色

- **全局一次性**：初始化时改 `ImGui::GetStyle().Colors[]`（NewFrame 之前自由改）。我们 `apply_style()` + 表驱动 `kStyleColors`（bridge.cpp:1443-1462, 1407-1438）就是标准做法，且表驱动比官方 demo 的逐行赋值更可维护。
- **帧内局部**：`imgui.h:540-547` 的铁律——NewFrame 之后只能 `PushStyleColor()/PopStyleColor()`、`PushStyleVar()/PopStyleVar()`（头文件 412 行注释原话 "Always use PushStyleColor(), PushStyleVar() to modify style mid-frame!"）。
- 官方 demo 的局部换色范式（`imgui_demo.cpp:962-964`、5181-5185）：

```cpp
// imgui_demo.cpp:962-964 —— 按钮 hover/active 三态只换亮度
ImGui::PushStyleColor(ImGuiCol_Button,        (ImVec4)ImColor::HSV(i / 7.0f, 0.6f, 0.6f));
ImGui::PushStyleColor(ImGuiCol_ButtonHovered, (ImVec4)ImColor::HSV(i / 7.0f, 0.7f, 0.7f));
ImGui::PushStyleColor(ImGuiCol_ButtonActive,  (ImVec4)ImColor::HSV(i / 7.0f, 0.8f, 0.8f));
... ImGui::Button(...); ...
ImGui::PopStyleColor(3);
```

我们的 `PrimaryAction()/DangerAction()`（bridge.cpp:1091-1113）已采用同一结构（Push 三色 → WithRounding → Button → Pop(3)），符合官方范式。
- 主题原型工具：`ImGui::ShowStyleEditor()` / `ShowStyleSelector()`（imgui_demo.cpp:8508-8536，Dark/Light/Classic 三选一）可嵌入任意窗口实时调色，调好后把数值抄回 `kStyleColors` 表——见建议 8。

### 4.3 圆角 / 间距 / 边框

`ImGuiStyle` 相关字段（imgui.h:2330-2385）与官方惯用值：

| 字段 | 官方 demo 常用值 | 我们现值（bridge.cpp:1443-1461） |
|---|---|---|
| `WindowRounding` / `ChildRounding` | demo 里 ChildRounding 5.0f（imgui_demo.cpp:4571） | 0 / 0 |
| `FrameRounding` | demo 用 3.0f（imgui_demo.cpp:5161） | 5.0f |
| `PopupRounding` | — | 6.0f |
| `TabRounding` | — | 0.0f |
| `ScrollbarRounding` | — | 4.0f |
| `FramePadding` | demo 常 Push (2,1) / (4,3) 做紧凑 | (8, layout.frame_padding_y) |
| `ItemSpacing` | demo 日志区 Push (0,0)（9207、9515 行） | (layout.item_spacing, layout.section_gap) |
| `WindowBorderSize` / `FrameBorderSize` | 0 或 1（imgui.h:2330/2341 注释：**只测过 0 和 1，其他值更耗 CPU/GPU**） | 0 / 1 |

注意 imgui.h:2330 与 2341 的注释：边框厚度"Generally set to 0.0f or 1.0f. (Other values are not well tested and more CPU/GPU costly)"——不要追求 2px 边框。

抗锯齿开关（imgui.h:2388-2392）：`AntiAliasedLines / AntiAliasedFill` 可关换性能（WARP 软渲染下如果未来帧预算紧张，这是官方留的降压阀门）；`AntiAliasedLinesUseTex=true` 要求后端双线性采样（我们的 DX11 后端满足，dx11.cpp:580-590）。

### 4.4 字体加载

官方推荐路径（FONTS.md + example_win32_directx11/main.cpp:74-90 注释）：

```cpp
// 1.92+ 动态字体系统（我们 19294 副本已具备，dx11 后端 669 行开了 RendererHasTextures）
style.FontSizeBase = 20.0f;                 // 基准字号（imgui.h:2322）
style.FontScaleDpi = 2.0f;                  // 全局缩放（imgui.h:2324）
ImFont* f = io.Fonts->AddFontFromFileTTF("font.ttf");   // 1.92 起 size 参数可省（imgui.h:3751）
ImGui::PushFont(nullptr, 42.0f);            // 运行中改字号（imgui.h:533）；PushFont(font) 保持 LegacySize（4148 行 inline）
```

- **Glyph ranges 已是 LEGACY**（imgui.h:3640 注释 "*LEGACY*"；FONTS.md:58 "Since 1.92 ... specifying glyph ranges is unnecessary"；所有 `GetGlyphRangesXXX()` 已标 obsolete，FONTS.md:208）。1.92+ 图集按需增量加载（初始 512x128，动态扩容，FONTS.md:95-104）。
- **多字体合并**：`ImFontConfig::MergeMode`（imgui.h:3634）把图标字体/CJK 字体并进主字体，FONTS.md:179-204 的标准片段。
- **从内存加载**：`AddFontFromMemoryTTF` 默认转移缓冲所有权；自持需 `FontDataOwnedByAtlas=false`（FONTS.md:253-267，且 1.92 起数据须存活到 `RemoveFont()`——1.92.6 才修好该语义，FONTS.md:267）。
- **源码内嵌**：`misc/fonts/binary_to_compressed_c.cpp` 把 ttf 转成 C 数组 + `AddFontFromMemoryCompressedTTF`（FONTS.md:273-288）；Base85 编码省源码体积但二进制大 20%（该工具头部注释 5-9 行）。
- **小字号质量**：stb_truetype 光栅在小字号偏糊，官方建议 `misc/freetype/` + `#define IMGUI_ENABLE_FREETYPE`（FONTS.md:389-397，"It makes a big difference especially at smaller resolutions"）；正确 sRGB 混合也影响字体观感。
- **图集初始尺寸**：已知字体集可设 `TexMinWidth/TexMinHeight` 减少启动期扩容拷贝（FONTS.md:80-89，字段在 imgui.h:3839）。
- **文件名陷阱**：Windows 路径 `\\` 转义 + 工作目录问题（FONTS.md:495-512）——我们用 `module_resource_path()` 基于 DLL 目录解析（bridge.cpp:1214-1267），已经规避。
- **调试工具**：Metrics/Debugger → Fonts 浏览图集；`ImGui::DebugTextEncoding()` 验证 UTF-8（FONTS.md:517-568）。

### 4.5 DPI（我们最大的空白）

FAQ.md:766-821（"How should I handle DPI in my application?"）完整决策树：
1. `style.FontScaleDpi = scale` 缩字体；`style.ScaleAllSizes(factor)` 缩间距（重算需重置 Style，FAQ.md:803-805）。
2. **尺寸常量要写成 `GetFontSize()/GetFrameHeight()` 的倍数**（FAQ.md:806 原话："avoid using hardcoded constants ... Prefer to express values as multiple of reference values such as `ImGui::GetFontSize()` or `ImGui::GetFrameHeight()`"）。
3. Windows 上**必须**告知系统 DPI 感知，否则窗口被系统位图拉伸、文字发糊（FAQ.md:814-821）；不用 manifest 的话就调 `ImGui_ImplWin32_EnableDpiAwareness()`（imgui_impl_win32.h:44）。
4. 官方 example 的完整示范：main.cpp:34-35 + 66-68（见 2.1 节）。

---

## 5. misc/fonts/ 字体资源盘点

`D:\workspace\SSCOM_lua\ref\imgui\misc\fonts\`（许可证见 FONTS.md:576-613）：

| 文件 | 大小 | 类型/许可证 | 备注 |
|---|---|---|---|
| `binary_to_compressed_c.cpp` | 15.7 KB | 工具源码 | ttf → C 数组内嵌工具（见 4.4） |
| `ProggyClean.ttf` | 41 KB | 等宽位图风 / MIT | 13px 点阵基准字体，源码内嵌版即它 |
| `ProggyTiny.ttf` | 35 KB | 等宽 / MIT | 10px 微缩版（推荐 GlyphOffset.y=+1，FONTS.md:608） |
| `Roboto-Medium.ttf` | 162 KB | 无衬线比例 / Apache 2.0 | 官方示例的"现代 UI"推荐脸 |
| `Cousine-Regular.ttf` | 43 KB | **等宽** / SIL OFL 1.1 | Chrome OS 系等宽，可替代 Consolas 做日志字体且**许可可再分发** |
| `DroidSans.ttf` | 190 KB | 无衬线 / Apache 2.0 | 老牌 UI 字体 |
| `Karla-Regular.ttf` | 16 KB | 无衬线 / SIL OFL 1.1 | 高对比几何无衬线 |

对我们的意义：
- **日志等宽字体**：目前用系统 `consola.ttf` + `cascadiamono.ttf` 兜底（bridge.cpp:1544-1551），依赖目标机装有该字体。`Cousine-Regular.ttf`（SIL OFL，43 KB）可随 DLL 再分发，彻底消除兜底分支。
- 正文字体我们已有品牌字体 Siemens Slab（CMakeLists.txt:36-48 从 `D:/workspace/SSCOM/xcom_client/resources/fonts` 拷入），无需动。
- 官方在 FONTS.md:589-591 明说 misc/fonts 这些文件"如今已非必要，将来可能移除"——选用时自行留档。

---

## 6. 图标方案建议

### 6.1 官方推荐：icon font 合并进主字体

FAQ.md:851-856 + FONTS.md:293-345 是官方唯一背书的图标方案：

```cpp
// FONTS.md:302-313（1.92+ 版本，无需 glyph ranges）
#include "IconsFontAwesome.h"               // juliettef/IconFontCppHeaders 生成的码点宏头
ImGuiIO& io = ImGui::GetIO();
io.Fonts->AddFontDefaultVector();
ImFontConfig config;
config.MergeMode = true;                    // 合并进前一个字体
config.GlyphMinAdvanceX = 13.0f;            // 图标等宽对齐（FONTS.md:337-340）
io.Fonts->AddFontFromFileTTF("fonts/fontawesome-webfont.ttf", 13.0f, &config);

// FONTS.md:327-334 用法：字符串字面量编译期拼接
ImGui::Text("%s among %d items", ICON_FA_SEARCH, count);
ImGui::Button(ICON_FA_SEARCH " Search");
```

资源链（FONTS.md:616-648 Font Links）：
- 码点头文件：https://github.com/juliettef/IconFontCppHeaders（ICON_FA_XXX 宏，C/C++ 直接用）
- 图标字体本体：FontAwesome（fortawesome.github.io/Font-Awesome）、OpenFontIcons、Google Material icons、Kenney icon font（手柄图标）、IcoMoon（自建子集）
- 多字体合并的重叠范围用 `ImFontConfig::GlyphExcludeRanges` 排除（imgui.h:3641；FONTS.md:351-385 有完整示例）

### 6.2 官方也认可的替代：ImDrawList 矢量手绘

FAQ.md:714-745（"How can I display custom shapes?"）+ demo 的 "Custom Rendering" 章：`GetWindowDrawList()` 画线/矩形/圆，`GetBackgroundDrawList()/GetForegroundDrawList()` 画全屏层；配 `InvisibleButton` 做热区、`ImGui::Dummy()` 占位。颜色用 `ImGui::GetColorU32(...)` 让 `style.Alpha` 生效。

### 6.3 对我们的具体建议

**现状**：图标全部手绘（ImDrawList 线条/矩形拼装）：
- 工具栏 4 枚：`IconButton()`（bridge.cpp:373-412，Clear/Save/Path/Refresh，1.8px 描边）
- 标题栏 3 枚：`WindowButton()`（bridge.cpp:414-445，最小化/最大化/关闭）
- 品牌 logo 1 枚：Header 里的示波器图形（bridge.cpp:461-481）
- Toggle 开关 1 种：`Toggle()`（bridge.cpp:1069-1089）

**结论：维持手绘，暂不引入 icon font。** 理由：
1. **量级未到**。官方方案的红利在"几十个图标 + 与文字混排"（如 `ICON_FA_SEARCH " Search"`）。我们只有 9 个图形、且全部是独立控件（不带文字标签），手绘的 `AddLine/AddRect` 十几行就能表达，还天然吃主题色（`GetColorU32` 自动乘 alpha）。
2. **零依赖零授权**。FontAwesome 4 webfont 约 100+ KB；合并进 Siemens Slab 还要处理 GlyphExcludeRanges（Segoe/Slab 与 FA 的 Private Use Area 理论上不重叠，但需验证）。
3. **WARP 下无性能差**。二者最终都是图集纹理三角形，手绘甚至少了字体图集扩容。

**切换触发条件**（满足任一再换 icon font）：
- UI 重设计后图标总数 > 15 枚，或需要在按钮/菜单文字里内联图标（`ICON_FA_PLAY " Run"` 形态）；
- 需要"多色/品牌化"图标（那不是 icon font 强项，考虑彩色 glyph：FreeType + `ImGuiFreeTypeLoaderFlags_LoadColor`，FONTS.md:401-418）；
- 手绘某个图标超过 ~40 行 draw_list 代码（复杂度信号）。

届时路径：FontAwesome TTF 放 `assets/fonts/` → `module_asset_path()` 解析（复用 bridge.cpp:1263-1267）→ MergeMode 并进 SiemensSlabRoman → IconFontCppHeaders 取宏 → `binary_to_compressed_c` 可选内嵌。1.92 动态图集下无需任何 ranges 配置。

---

## 7. 对 xcom_imgui_bridge.cpp 的具体借鉴建议（按优先级）

1. **补 DPI 感知与缩放（最重要）**。
   官方 main.cpp:34-35 + 66-68 的三件套我们一件都没有：`xcom_imgui_init()`（bridge.cpp:1476-1568）里无 `ImGui_ImplWin32_EnableDpiAwareness()`、无 `GetDpiScaleForHwnd`、无 `ScaleAllSizes`；字体硬编码 17/18/16px（1530/1537/1545 行）。在 125%/150% 缩放屏上，宿主 luajit.exe 的 manifest（`luajit.exe.manifest` 仅声明 Common-Controls，无 `<dpiAware>`）会让 Windows 拉伸整个窗口→发糊。
   做法：init 早期调 `ImGui_ImplWin32_EnableDpiAwareness()`（Win32 后端已带，imgui_impl_win32.h:44）；`float scale = ImGui_ImplWin32_GetDpiScaleForHwnd(hwnd)`；`style.FontScaleDpi = scale`（1.92+ 动态字体自动跟随，无需重建字体）；`apply_style()`（bridge.cpp:1443）末尾加 `style.ScaleAllSizes(scale)`——注意 ScaleAllSizes 只管 spacing/padding/thickness，我们 `layout.toml` 的绝对像素值（sidebar_width 等，bridge.cpp:1280-1291）需在 `load_layout_config()` 后手工乘 scale。
   参照：FAQ.md:766-821。

2. **遮挡降帧：`DXGI_PRESENT_TEST` 探测**。
   官方 DX11 main.cpp:114-120 / DX12 main.cpp:210-214。我们 Lua 侧只处理了"最小化"（window.lua:1170-1173），"窗口被完全遮挡"（如拖到另一显示器全屏窗口后面）仍会以既定节奏烧 WARP CPU。在 `xcom_imgui_render()`（bridge.cpp:1748-1762）Present 前后维护 occluded 状态，或导出 `xcom_imgui_is_occluded()` 让 Lua 跳帧即可；DX12 版的 `::IsIconic(hwnd)` 检查也可下沉到 C 侧，替代 Lua 侧对 `_minimized` 的推断。

3. **交换链 BufferCount 1→2，评估 FLIP_DISCARD**。
   官方 main.cpp:206 用 2 缓冲；203 行注释更推荐 `DXGI_SWAP_EFFECT_FLIP_DISCARD`（issue #8979）。我们 bridge.cpp:1489 是 `BufferCount = 1` + `DXGI_SWAP_EFFECT_DISCARD`：单缓冲下 Present 期间 CPU 与 WARP 光栅器可能互等。WARP 场景 2 缓冲通常能减少 Present 阻塞；FLIP 模型在 Win10+ 是现代默认。改动点集中在 `xcom_imgui_init()` 的 `swap_desc`（1488-1497），resize 路径（1773-1774）无需变。改完需回归验证交互期即时 Present（1756-1759 的场景）。

4. **字体 GlyphRanges 约束该拆了（CJK 接收数据）**。
   bridge.cpp:1528 `font_config.GlyphRanges = io.Fonts->GetGlyphRangesDefault()` 把正文字体锁死在 Latin。imgui.h:3640 已标 LEGACY，1.92+ 动态图集下完全不需要；更要命的是**串口助手会收到中文数据**（GBK 设备、UTF-8 协议），Siemens Slab / Consolas 都没有 CJK 字形，接收区会渲染成方块。
   做法（两步）：(a) 删掉 1528 行的 ranges（mono 字体 1544-1551 的 ranges 同删），让 1.92 按需加载能进来的都进来；(b) 给 mono 字体补一个 CJK 来源——Windows 自带 `C:\Windows\Fonts\msyh.ttc`（微软雅黑，随系统分发无授权问题）以 `MergeMode` 并入，或再分发 Noto Sans SC（OFL）。若继续离线依赖系统字体，至少 fallback 链加 `simsun.ttc`。

5. **SC_KEYMENU 过滤，保护自绘标题栏**。
   官方 main.cpp:276-279 在 WndProc 里吞掉 `(wParam & 0xfff0) == SC_KEYMENU`，防止按 ALT 弹系统菜单。我们自绘了最小化/最大化/关闭（bridge.cpp:414-445），但 `xcom_imgui_wndproc()`（1764-1786）没过滤——按住 ALT 时 Windows 可能在客户区顶部弹菜单条或闪烁。一行 case 即可，加在 1768 行的 WM_SIZE 处理旁。

6. **图集初始尺寸预设，减少 WARP 启动抖动**。
   FONTS.md:80-89：已知加载 3 个字体时 `atlas->TexMinWidth/TexMinHeight`（imgui.h:3839）设 1024 可消掉多次 512x128→扩容的 alloc+copy。加在 `xcom_imgui_init()` 建字体前（bridge.cpp:1524 之前），成本两行。

7. **尺寸常量向 `GetFrameHeight()/GetFontSize()` 倍数迁移**。
   FAQ.md:806 的官方建议 + demo 的 footer 预留范式（imgui_demo.cpp:9174 `footer_height_to_reserve = style.SeparatorSize + style.ItemSpacing.y + ImGui::GetFrameHeightWithSpacing()`）。我们大量绝对像素：`kFooterHeight=22 / kControlHeight=26 / kToggleHeight=20`（bridge.cpp:53-55）、`send_height=196`（layout.toml）等。若采纳建议 1 的 DPI 缩放，这些常量也应表达为 `GetFrameHeight()` 的倍数（如 `kControlHeight ≈ GetFrameHeight() + 6`），否则高 DPI 下控件与字体比例失衡。可随重设计逐步做，优先 toolbar/按钮/行高这些"必须裹住文字"的值。

8. **嵌一个调试用的 Style Editor 做主题原型**。
   `ImGui::ShowStyleEditor()`（imgui_demo.cpp:8547 起）可直接放进我们 dashboard 的一个隐藏 Popup/窗口里，实时拖 `kStyleColors` 的每个槽位与 rounding/padding，调完把 ImGuiStyle 导出值抄回 bridge.cpp:1407-1438 的表。比改一次编译一次的循环快一个数量级，且 8573-8575 行顺带会警告字体缩放是否平滑（RendererHasTextures 检查——我们已满足，正好当作自检）。建议做成 config.ini 开关（如 `[debug] style_editor=1`）而非常驻代码路径。

9. **手绘图标维持现状（第 6 节结论的落地）**。
   `IconButton`（bridge.cpp:373-412）的 28x26 热区 + 1.8px 描边已对齐正文视觉重量；重设计时若新增图标，继续走 ImDrawList，超过 15 枚或需图文混排再切 FontAwesome（届时注意 `GlyphExcludeRanges` 与 `GlyphMinAdvanceX`，FONTS.md:337-385）。

10. **清屏色已符合最佳实践，记录约定即可**。
    `kClearColor`（bridge.cpp:1441）= (233,234,236,1) 与 `ImGuiCol_WindowBg`（0xE9EAEC，bridge.cpp:1410）一致，避免了 resize 闪色；官方 main.cpp:175 的预乘约定（RGB×A）在我们 alpha=1 时是恒等。若将来做半透明窗口（`ImGui_ImplWin32_EnableAlphaCompositing`，imgui_impl_win32.h:51），记得同步把清屏改成预乘形式。

---

## 8. 官方资料索引（本地路径）

| 文件 | 内容 |
|---|---|
| `ref\imgui\examples\README.txt` | examples 总说明 |
| `ref\imgui\examples\example_win32_directx11\main.cpp` | 我们的直接参照（286 行） |
| `ref\imgui\examples\example_win32_directx12\main.cpp` | 遮挡/最小化/tearing 的更全处理 |
| `ref\imgui\examples\example_glfw_opengl3\main.cpp` | 跨平台节流/vsync 范式 |
| `ref\imgui\examples\example_null\main.cpp` | 帧生命周期最小骨架（43 行） |
| `ref\imgui\docs\EXAMPLES.md` | 集成 20 行口诀 + 全部示例清单 + 光标延迟说明 |
| `ref\imgui\docs\FAQ.md` | ID 栈 / DPI / 换肤 / 自绘 / 多线程 |
| `ref\imgui\docs\FONTS.md` | 字体/图标/合并/内嵌/UTF-8 全集 |
| `ref\imgui\docs\BACKENDS.md` | 后端职责划分（"优先用标准后端"） |
| `ref\imgui\docs\README.md` | 库定位（"工具向 UI，非终端用户 UI"——与本项目定位吻合） |
| `ref\imgui\misc\fonts\` | 可再分发字体 + 内嵌工具（见第 5 节） |
| `ref\imgui\imgui_demo.cpp` | ExampleAppLog（9449-9570，我们接收区的官方同构）/ StyleEditor（8547+） |

---

*文档生成于 2026-09-04，基于 ref/imgui 工作区（1.93.0 WIP, 19295）与 xcom_imgui_bridge.cpp（当前工作区版本）逐行核对。*
