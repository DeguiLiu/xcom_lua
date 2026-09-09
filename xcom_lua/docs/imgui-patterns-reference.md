# ImGui / ImPlot 官方示例模式参考（面向 xcom_imgui_bridge.cpp）

> 版本基线：Dear ImGui **1.93.0 WIP**、ImPlot **1.1 WIP**（`IMPLOT_VERSION_NUM 10100`）。
> 本项目源码位置：
> - ImGui 源（bridge 实际编译用）：`D:\workspace\SSCOM_lua\third_party\xcom_imgui\imgui\`（docking 分支工作区，`IMGUI_VERSION_NUM 19294`）
> - **ImGui 官方完整仓库工作区（master，`IMGUI_VERSION_NUM 19295`）：`D:\workspace\SSCOM_lua\ref\imgui\`**（含 examples/、docs/、backends/、misc/；~~此前是空 clone~~，现已完整检出——官方示例与 docs 段落行号以此为准）
> - ImPlot 源：`D:\workspace\SSCOM_lua\third_party\xcom_imgui\implot\`
> - 桥接文件：`D:\workspace\SSCOM_lua\xcom_lua\native\xcom_imgui\xcom_imgui_bridge.cpp`（Phase 4 期间持续增长：2026-09-05 快照 2610 行；下文 bridge.cpp 行号以该快照为准，引用时优先按符号名定位）
>
> 下文所有行号均以这些本地文件为准（2026-09-04/05 已用 Read/Grep 逐条核实）。
>
> **ref 与编译副本的差异须知**：ref\imgui 是 master 分支（19295），third_party 编译副本是 docking 分支（19294）。二者 imgui_demo.cpp 差约 114 行——docking 副本多出 ShowDockingDisabledMessage / ShowExampleAppDockSpace / Docking 段（第三方副本 288-300 行起），因此 **ref 与编译副本的 demo 行号不可互换**：`ExampleAppConsole` ref:9061 / 编译副本:9175；`ExampleAppLog` ref:9449 / 编译副本:9563；`Resize Callback` ref:4027 / 编译副本:4113；`Ctrl+S SetNextItemShortcut` ref:8124 / 编译副本:8210。imgui.h 的 flags/枚举行号同样有漂移（如 Shortcut ref:1103 / 副本:1129）。**本文档统一引用 ref（master）行号**——它对应官方 README/FAQ 所述版本；引用编译副本时单独标注。

---

## 0. 本项目 bridge 与官方示例的结构差异（写新功能前必读）

官方 `ref\imgui\examples\example_win32_directx11\main.cpp`（master，总 286 行）是**自主循环**：消息泵 → NewFrame → UI → Render → Present 全在一个 `while` 里（99-184 行）。bridge 是**被动驱动**：

| 官方示例（main.cpp 行号） | 本项目 bridge（行号，2610 行快照） |
|---|---|
| `ImGui_ImplDX11_NewFrame()` → `ImGui_ImplWin32_NewFrame()` → `ImGui::NewFrame()`（132-134） | 导出函数 `xcom_imgui_new_frame()`（bridge.cpp:2320-2329） |
| `ImGui::ShowDemoWindow()` + 两个 Begin/End 窗口（137-171） | 导出函数 `xcom_imgui_draw_console()`（bridge.cpp:2130），单窗口 `##xcom_dashboard` 铺满 `io.DisplaySize` + `ScriptConsoleContent()` 浮窗（bridge.cpp:2229 调用） |
| `ImGui::Render()` + `RenderDrawData` + `Present`（174-183） | 导出函数 `xcom_imgui_render()`（bridge.cpp:2331-2342），Present(0,0) 无 vsync |
| WndProc 直接转发（263-285） | 导出函数 `xcom_imgui_wndproc()`（bridge.cpp:2347），WM_SIZE 在此处理 |
| 状态是 main.cpp 文件级 static（16-21） | 一切状态在 `ImGuiRuntime` 单例（bridge.cpp:96） |

调用节奏由 Lua 侧 `Window:render_imgui()`（`xcom_lua/ui/window.lua:1164-1212`）控制：
`frame()` → `set_status`/`set_script_log`/`set_receive_text`（脏时）→ `draw()` → action 分发 → `render()`。
帧间隔三档（window.lua:1130-1132）：active 16 ms / data 100 ms / idle 500 ms，按需 `request_frame()` 拉早（window.lua:1134-1141）。

### 0.1 官方示例中对被动驱动架构适用的模式（ref\imgui\examples 精读结论）

**example_win32_directx11\main.cpp（286 行，bridge 的直接参照）**：

- **WM_SIZE 不在 WndProc 里直接 ResizeBuffers，只记录尺寸**（273-274 `g_ResizeWidth = LOWORD(lParam)`），主循环里 `CleanupRenderTarget → ResizeBuffers → CreateRenderTarget` 三步（123-129）。原因：WM_SIZE 在 `DefWindowProc` 的模态 resize 循环内同步到达，此时 swap chain 仍被引用。bridge 的 `xcom_imgui_wndproc`（bridge.cpp:2347-2368）直接在 WndProc 里做这三步并在 resize 期间用 `Present(0,0)` 立即呈现（bridge.cpp:2331-2342 注释）——这是对被动驱动的合理偏离：bridge 没有自主主循环，等不到"下一帧"，模态 resize 期间只有 WndProc 能跑。
- **最小化/遮挡节流**（114-120）：`g_SwapChainOccluded` + `Present(0, DXGI_PRESENT_TEST)` 探测遮挡则 `Sleep(10)` 跳帧；`WM_SIZE` 的 `SIZE_MINIMIZED` 直接 return 0。bridge 对应物是 Lua 侧 `self._minimized` 跳帧（window.lua:1170-1173）。
- **WndProc 转发顺序**（265-266）：`ImGui_ImplWin32_WndProcHandler` 在 **switch 之前**调用，handler 返回非 0 即拦截。Win32 后端 handler 内部处理 WM_MOUSEMOVE/按键/滚轮/WM_CHAR/WM_IME_CHAR/焦点（imgui_impl_win32.cpp:640-831），对 WM_SIZE 不感兴趣所以不拦截——bridge 在转发前先处理 WM_SIZE 是安全的。注意 handler 首行有静默检查 `GetCurrentContext()==nullptr → return 0`（imgui_impl_win32.cpp:629-630），WndProc 在 CreateWindow 期间就会被调用，这是官方要求的容忍。
- **DPI**（33-35, 65-68）：`ImGui_ImplWin32_EnableDpiAwareness()` + `style.ScaleAllSizes(main_scale)` + `style.FontScaleDpi = main_scale`。bridge 用 WARP 固定 96 DPI 桌面未做；若未来支持高 DPI，`style.FontScaleDpi` 是 1.92+ 的正道（FONTS.md:113-115）。
- **清理顺序**（186-193）：`ImGui_ImplDX11_Shutdown → ImGui_ImplWin32_Shutdown → ImGui::DestroyContext → CleanupDeviceD3D`（后端先于 context，context 先于 D3D 对象）。bridge `shutdown_impl()`（bridge.cpp:1656）完全同序，另加 `if (frame_active_) ImGui::EndFrame()` 补未闭合帧。
- **Present(1,0) vsync vs Present(0,0)**（181-182）：官方示例 vsync。bridge 必须 `Present(0,0)`——被动调用方（Lua 定时器）已自带节奏，vsync 会在 Present 里阻塞占住 Lua 线程。

**example_sdl2_directx11\main.cpp（266 行）**——与 win32 版的差异点（其余逐行同构）：

- 事件泵换成 `SDL_PollEvent` + `ImGui_ImplSDL2_ProcessEvent(&event)`（124-127）；**resize 在事件循环内同步三步处理**（132-138），与 win32 版的"延迟到主循环"相反——证明 Cleanup/Resize/Create 三步在两种时机都合法，bridge 在 WndProc 内做同样成立。
- 最小化跳帧用 `SDL_GetWindowFlags & SDL_WINDOW_MINIMIZED → SDL_Delay(10); continue`（140-144）。
- **IME**：SDL_HINT_IME_SHOW_UI（46-48）等价 Win32 后端的 WM_IME_CHAR 路径——CJK 输入不需要额外配置，Win32 后端已内建。

**example_null\main.cpp（44 行）**——最小帧循环骨架，证明被动驱动合法性：

```cpp
ImGui_ImplNullPlatform_NewFrame();
ImGui_ImplNullRender_NewFrame();
ImGui::NewFrame();
/* UI */
ImGui::Render();
```
（22-36 行，循环 20 次后 Shutdown）。官方自己就支持"无消息泵、外部驱动逐帧"——NewFrame/Render 之间没有对消息循环的隐式依赖。bridge 的 `frame()`/`draw()`/`render()` 三导出拆分即此骨架加上真实后端。

**帧节奏（被动驱动的关键约束）**：
- `io.DeltaTime` 由 `ImGui_ImplWin32_NewFrame` 内部用平台时间计算，帧间隔 16-500 ms 波动时自动正确——不需要也不应该手动喂。
- 官方 demo 靠 `ImGui::GetTime()`/DeltaTime 累加的动画（如 implot_demo.cpp:1027 的 0.02 s 采样节流）在 idle 500 ms 档下欠采样；示波器数据应由 Lua/串口侧驱动追加，bridge 只画。

**写新功能的直接推论：**
1. 新 UI 元素的状态（文本、开关、浮点）一律挂进 `ImGuiRuntime` 成员，**不能**用函数级 `static` 缓存指向 Lua 传入指针的东西——bridge.cpp:2154-2157 已有先例注释（ComboSpec 的 int* 地址每次 draw 可能不同，缓存即悬垂）。
2. 16-100 ms 的帧间隔意味着 `ImGui::Shortcut()`/`SetNextItemShortcut()` 依赖路由系统，帧率低时按键事件仍可靠（Win32 后端把字符事件排队到下一帧），但 `IsKeyPressed` 轮询跨帧丢键风险高——优先用 Shortcut 系。
3. Lua 侧已有的 optional_export 探测机制（imgui_bridge.lua:46-49）保证新增导出对旧 DLL 优雅降级——Phase 4 的 `set_baud_extra`/`set_highlight_rules`/`set_scripts`/`set_script_log` 等导出全部走这条路。

---

## 1. Log / 子窗口滚动日志模式（接收区、脚本控制台日志区都用）

（行号统一为 **ref\imgui\imgui_demo.cpp** = master 19295；编译副本对应段见文头对照表。）

### 1.1 官方 ExampleAppLog（大缓冲 + clipper）

源：`imgui_demo.cpp:9449-9570`（`ExampleAppLog` 结构）、入口 `ShowExampleAppLog` 9573-9601。

要点（行号）：
- **追加式缓冲 + 行偏移索引**：`AddLog` 用 `ImGuiTextBuffer::appendfv` 追加，边追加边记录 `LineOffsets`（9469-9479）；`Clear()` 重置为 `{0}`（9462-9467）。
  - 本项目接收区已是同构实现：`xcom_imgui_set_receive_text`（bridge.cpp:2265 起）用 `std::memchr` 扫 `\n` 建 `receive_line_offsets_`（bridge.cpp:2295）。
- **按钮行**：Options(popup)/Clear/Copy + `Filter.Draw("Filter", -100.0f)`，负宽度=右对齐占满（9497-9504）。
- **滚动子窗口**：`BeginChild("scrolling", ImVec2(0,0), ImGuiChildFlags_None, ImGuiWindowFlags_HorizontalScrollbar)`（9508）。
- **过滤激活时禁用 clipper**（无随机访问），全量循环 `Filter.PassFilter(line_start, line_end)`（9518-9531）；未过滤时 `ImGuiListClipper` 只画可见行（9547-9558）。行尾取法惯用式：`line_end = (line_no+1 < Size) ? buf + LineOffsets[line_no+1] - 1 : buf_end`（9554，`-1` 吃掉 `\n`）。
- **贴底跟随**（9564-9565）：
  ```cpp
  if (AutoScroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY())
      ImGui::SetScrollHereY(1.0f);
  ```
  用户一旦上滚离开底部就不再强制贴底——本项目 `receive_follow_tail_`（bridge.cpp:125）即此语义，且在帧首**先**取 `was_at_bottom` 再渲染（bridge.cpp:810-812），语义更准。
- **同窗口多次 Begin/End 追加内容**（ShowExampleAppLog 9573-9601）：先 `Begin("Example: Log")` 画调试按钮再 `End()`，`log.Draw()` 内部再次 `Begin()` 同名窗口追加——官方明言"multiple calls to Begin()/End() are appending to the same window"（9577-9579 注释）。脚本控制台浮窗若要"工具条由一处画、日志由另一处画"可用此特性。

### 1.2 官方 ExampleAppConsole（逐行着色 + REPL 输入框）

源：`imgui_demo.cpp:9061-9411`（struct）、入口 `ShowExampleAppConsole` 9413-9417。这是脚本控制台浮窗的**直接模板**（bridge 已照此落地，见 1.4）：

- 逐行 `Items[]` + 按前缀着色（9217-9226）：
  ```cpp
  ImVec4 color; bool has_color = false;
  if (strstr(item, "[error]")) { color = ImVec4(1.0f, 0.4f, 0.4f, 1.0f); has_color = true; }
  else if (strncmp(item, "# ", 2) == 0) { color = ImVec4(1.0f, 0.8f, 0.6f, 1.0f); has_color = true; }
  if (has_color) ImGui::PushStyleColor(ImGuiCol_Text, color);
  ImGui::TextUnformatted(item);
  if (has_color) ImGui::PopStyleColor();
  ```
- **底部输入框前预留 footer**（9172-9175）：
  ```cpp
  ImGuiStyle& style = ImGui::GetStyle();
  const float footer_height_to_reserve = style.SeparatorSize + style.ItemSpacing.y + ImGui::GetFrameHeightWithSpacing();
  ImGui::BeginChild("ScrollingRegion", ImVec2(0, -footer_height_to_reserve), ImGuiChildFlags_NavFlattened, ImGuiWindowFlags_HorizontalScrollbar);
  ```
  `ImVec2(0, -x)` 负高度 = "占满除底部 x 像素外的区域"（imgui.h:457-460 尺寸语义三档注释）。
- 输入框 flags：`EnterReturnsTrue | EscapeClearsAll | CallbackCompletion | CallbackHistory`（9243）；回车执行后 `SetKeyboardFocusHere(-1)` 夺回焦点（9256-9257），`SetItemDefaultFocus()`（9255）管窗口首次出现时聚焦。
- Tab 补全 / 上下历史通过 `ImGuiInputTextCallbackData` 的 `DeleteChars/InsertChars` 改缓冲（9316-9407）；历史去重（新命令先删旧同项再 push_back，9268-9276）。
- 官方自注：几千行以上需自行 clipper（9183-9206 的长注释，明确"items must be evenly spaced + cheap random access"两个 clipper 前提）；本项目日志区已有 line_offsets 索引，直接套 receive 区的 clipper 画法即可。
- **Options 按钮的快捷键提示**（9165-9167）：`SetNextItemShortcut(ImGuiMod_Ctrl | ImGuiKey_O, ImGuiInputFlags_Tooltip)`——按钮自动显示"Ctrl+O"角标，免费获得 UI 一致性。

### 1.3 CollapsingHeader

源：`imgui_demo.cpp:1163-1187`（`DemoWindowWidgetsCollapsingHeaders`）。
- `ImGui::CollapsingHeader("Header", ImGuiTreeNodeFlags_None)`（1169）
- 带关闭按钮变体：`CollapsingHeader("Header with a close button", &closable_group)`（1175）——`bool*` 传出关闭事件（imgui.h:767-768 双签名）。

### 1.4 bridge 已落地的对应实现（Phase 4 现状核对）

- **脚本日志面板** `ScriptConsoleContent()`（bridge.cpp:1554 起）：
  - 日志 clipper + `[ERROR]/[WARN ]/[INFO ]` 前缀着色用 `ImGui::TextColored`（bridge.cpp:1667-1692），follow-tail 在帧首取 `was_bottom`（bridge.cpp:1693-1698）——1.1/1.2 两个模板的合体。
  - footer 预留公式扩展为 `SeparatorSize + ItemSpacing.y + GetTextLineHeightWithSpacing() * 2`（日志面板 + REPL 两行，bridge.cpp:1595-1598）。
  - REPL：`InputText("##repl", buf, sizeof, EnterReturnsTrue | EscapeClearsAll)` + 提交后 `SetKeyboardFocusHere(-1)`（bridge.cpp:1703-1715），命令经 `xcom_imgui_script_take_command` 导出被 Lua 拉走（bridge.cpp:2534）。
- **接收区高亮**（bridge.cpp:919-1040 附近）：每行收集 ≤64 个 `HitSpan{offset,length,rule}`；bg 规则 `draw->AddRectFilled(pos + px, +line_h, color, 2.0f)` 画底块（bridge.cpp:969-972），text 规则把行拆成着色 run 用 `draw->AddText(pos, col, seg, seg_end)` 直绘（bridge.cpp:1005/1021）。纯 ASCII 行用预量 glyph_w 免 CalcTextSize，非 ASCII 回退 CalcTextSize。与 1.2 的 PushStyleColor 整行式不同——关键词高亮必须**行内分段**，官方 demo 无此现成段落，此实现即自定义 draw-list 段（见 5.2 节裁剪要点）。

### 适配 bridge 的最小骨架（通用滚动日志，clipper 版）

```cpp
// ImGuiRuntime 成员（bridge.cpp:96 class 内）：
//   std::string log_{}; std::vector<std::size_t> log_lines_{1, 0}; bool log_follow_ = true;
// 导出 set_xxx_log(text, len)：assign + memchr('\n') 建 log_lines_（仿 bridge.cpp:2265）。
void DrawLog(ImGuiRuntime& rt, const char* child_id) {
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(4, 1));
    if (ImGui::BeginChild(child_id, ImVec2(0, 0), ImGuiChildFlags_None,
                          ImGuiWindowFlags_HorizontalScrollbar)) {
        const bool was_bottom = ImGui::GetScrollY() >= ImGui::GetScrollMaxY();
        const char* data = rt.log_.data();
        ImGuiListClipper clipper;
        clipper.Begin((int)rt.log_lines_.size());
        while (clipper.Step())
            for (int i = clipper.DisplayStart; i < clipper.DisplayEnd; i++) {
                const std::size_t b = rt.log_lines_[i];
                const std::size_t e = (i + 1 < (int)rt.log_lines_.size())
                    ? rt.log_lines_[i + 1] - 1 : rt.log_.size();  // -1 吃 \n（官方 9554 式）
                ImGui::TextUnformatted(data + b, data + e);
            }
        clipper.End();
        if (rt.log_follow_ && was_bottom) ImGui::SetScrollHereY(1.0f);
    }
    ImGui::EndChild();
    ImGui::PopStyleVar();
}
```

---

## 2. InputTextMultiline 代码编辑器（脚本编辑器 + Ctrl+S）

### 2.1 官方 demo 写法（ref\imgui\imgui_demo.cpp）

- 基本版：`imgui_demo.cpp:3891-3920`（"Multi-line Text Input" TreeNode）：
  ```cpp
  static ImGuiInputTextFlags flags = ImGuiInputTextFlags_AllowTabInput;
  ImGui::InputTextMultiline("##source", text, IM_COUNTOF(text),
                            ImVec2(-FLT_MIN, ImGui::GetTextLineHeight() * 16), flags);
  ```
  （3918 行）。尺寸惯用式：**宽 `-FLT_MIN`（占满）、高 `N 行 × GetTextLineHeight()`**。
  - demo 同段展示的 flag 开关：`_ReadOnly`、`_WordWrap`（Beta，3914 行 HelpMarker 明示）、`_AllowTabInput`（3916 行 HelpMarker：开此 flag 时 Tab 不再参与 widget 间导航）、`_CtrlEnterForNewLine`（3917）。
- 动态缓冲版（Resize Callback）：`imgui_demo.cpp:4027-4071`：
  ```cpp
  static int MyResizeCallback(ImGuiInputTextCallbackData* data) {
      if (data->EventFlag == ImGuiInputTextFlags_CallbackResize) {
          ImVector<char>* my_str = (ImVector<char>*)data->UserData;
          IM_ASSERT(my_str->begin() == data->Buf);
          my_str->resize(data->BufSize);      // 注意 data->BufSize == BufTextLen + 1
          data->Buf = my_str->begin();        // 必须回写新指针
      }
      return 0;
  }
  ImGui::InputTextMultiline(label, my_str->begin(), (size_t)my_str->size(), size,
                            flags | ImGuiInputTextFlags_CallbackResize, MyResizeCallback, my_str);
  ```
  （4038-4048 回调、4052-4056 包装函数）。**bridge 的脚本编辑器应当用 std::string + 这个回调**，容量不必预估。
- **官方 std::string 参考实现**（可直接照抄的版本）：`ref\imgui\misc\cpp\imgui_stdlib.cpp:39-58` 的 `InputTextCallback`：
  ```cpp
  std::string* str = user_data->Str;
  IM_ASSERT(data->Buf == str->c_str());
  str->resize(data->BufTextLen);      // 注意：stdlib 用 BufTextLen（长度），demo 用 BufSize（容量）
  data->Buf = (char*)str->c_str();
  ```
  以及 72-82 行的 `InputTextMultiline(std::string*)` 包装：传 `str->capacity() + 1` 作 buf_size。**std::string 场景 `resize(BufTextLen)` + `capacity()+1` 是官方口径**（dangling 容量由回调链保证）；demo 的 ImVector 版 `resize(BufSize)` 是容量对齐。另外 stdlib 的 `ChainCallback` 机制（51-56 行）允许用户回调与 resize 回调共存——若编辑器还要接 CallbackCompletion（Tab 补全），照抄这个链式结构。
- 双精度提示：`data->BufSize` 语义在 imgui.h:1313（"You will be provided a new BufSize in the callback and NEED to honor it"）。

### 2.2 v1.93 关键签名与 flags（ref\imgui\imgui.h）

- 签名（imgui.h:728）：`bool InputTextMultiline(const char* label, char* buf, size_t buf_size, const ImVec2& size = ImVec2(0,0), ImGuiInputTextFlags flags = 0, ImGuiInputTextCallback callback = NULL, void* user_data = NULL);`
  - **buf_size 是 `size_t`（1.90 起由 int 改来）**；size 是 `const ImVec2&`（旧教程里传裸 `float w, float h` 的写法已不存在）。
- 相关 flags 行号（ref imgui.h）：`AllowTabInput`(1289)、`EnterReturnsTrue`(1290)、`EscapeClearsAll`(1291)、`CtrlEnterForNewLine`(1292)、`ReadOnly`(1295)、`NoHorizontalScroll`(1301)、`ElideLeft`(1306，仅单行)、`CallbackCompletion`(1309)、`CallbackHistory`(1310)、`CallbackResize`(1313)、`WordWrap`(1323)。
- Tab 键处理：**编辑器场景直接给 `_AllowTabInput`**（Tab 输入 `\t` 字符，不再参与 widget 间 Tab 导航——demo 3916 行 HelpMarker 明言此副作用）。若编辑器处于只读态想恢复 Tab 导航，切掉该 flag 即可。
- 只读切换：同一 buf，帧间按 `rt.script_readonly_` 增删 `_ReadOnly` flag 即可，不需要两个控件。

### 2.3 Ctrl+S 轮询（v1.93 正道是 Shortcut，不是 IsKeyDown）

- `ImGui::Shortcut(ImGuiKeyChord, flags)`（imgui.h:1103）、`SetNextItemShortcut`（imgui.h:1104）。
- demo 示例（ref）：`imgui_demo.cpp:8122-8125`（Ctrl+S 绑到 Button + Tooltip 角标）、`8131-8182`（Shortcut 路由演示整段）、`10628-10630`（文档 demo 的 Save 按钮 + Ctrl+S 角标）、`8998`（菜单项 `MenuItem("Save", "Ctrl+S")`——菜单里快捷键只是显示文本，路由要另接）。
- 路由 flags（imgui.h:1712-1732）：默认 `_RouteFocused`(1721，焦点窗口栈、最深聚焦窗口优先)；全局快捷键用 `_RouteGlobal`(1722)；`_RouteAlways`(1723) = 不注册路由直接轮询键。优先级链在 1718 行注释：`RouteGlobal+OverActive >> RouteActive or RouteFocused >> RouteGlobal+OverFocused >> RouteFocused >> RouteGlobal`。
- demo 8138-8182 段演示了父子窗口同 chord 的竞争归属（WindowA / ChildE / PopupF），结论：**Shortcut 系统顺序无关、最深聚焦窗口优先**——脚本浮窗里 Ctrl+S 只在浮窗聚焦时生效，天然正确。
- **bridge 落地核对**：`ScriptConsoleContent()` 内 `ImGui::Shortcut(ImGuiMod_Ctrl | ImGuiKey_S)`（bridge.cpp:1590-1593）即默认 RouteFocused——浮窗聚焦才触发，dashboard 聚焦时 Ctrl+S 不误触。

### 适配 bridge 的最小骨架（编辑器 + Ctrl+S + 只读切换）

```cpp
// ImGuiRuntime 成员：std::string script_buf_{1, '\0'};（bridge.cpp:179 script_edit_buf_ 同型）
static int ScriptResizeCb(ImGuiInputTextCallbackData* d) {
    auto* s = (std::string*)d->UserData;
    if (d->EventFlag == ImGuiInputTextFlags_CallbackResize) {
        s->resize(d->BufSize);
        d->Buf = s->data();
    }
    return 0;
}
// 浮窗内（见第 4 节）：
ImGuiInputTextFlags f = ImGuiInputTextFlags_AllowTabInput | ImGuiInputTextFlags_CallbackResize;
if (rt.script_readonly_) f |= ImGuiInputTextFlags_ReadOnly;
ImGui::InputTextMultiline("##script", rt.script_buf_.data(), rt.script_buf_.size(),
                          ImVec2(-FLT_MIN, -ImGui::GetTextLineHeightWithSpacing() * 2),
                          f, ScriptResizeCb, &rt.script_buf_);
// Ctrl+S：浮窗聚焦时才触发（RouteFocused 默认）
if (ImGui::Shortcut(ImGuiMod_Ctrl | ImGuiKey_S))
    actions |= Action::ActionScriptSave;   // 由 Lua 侧落盘
```

**bridge 现状**（Phase 4 已实现，核对）：`ScriptEditorResize`（bridge.cpp:1545-1553）+ `InputTextMultiline("##script_edit", buf.data(), buf.size(), ImVec2(-FLT_MIN, -GetTextLineHeightWithSpacing()), AllowTabInput|CallbackResize, ...)`（bridge.cpp:1642-1648），变更置 `script_edit_dirty_`（标题旁 `*` 指示，bridge.cpp:1586 用 `TextColored`）；Ctrl+S 经事件队列 `(ScriptEvent::Edit<<8)|0x40` 报给 Lua（bridge.cpp:1590-1593）。编辑缓冲 `script_edit_buf_{1,'\0'}` 挂 Runtime（bridge.cpp:179）。

---

## 3. Combo / InputInt 变体（Custom 波特入口）

（demo 行号统一 ref；bridge 行号 = 2610 行快照。）

### 3.1 Combo（imgui_demo.cpp:1395-1486）

| 变体 | 行号 | 适用 |
|---|---|---|
| `BeginCombo`/`EndCombo` + `Selectable` | 1428-1441 | 全自定义（本项目波特下拉已用此式） |
| 内嵌过滤框的 Combo | 1445-1463 | 波特列表长时搜索 |
| 一行式 `\0` 分隔串 | 1473 | 编译期小集合 |
| 数组式 `const char**` | 1478 | 略 |
| 函数取值式 | 1482 | C 字符串数组在非连续存储时 |

选中项回显模式（1430-1439）：`Selectable(items[n], is_selected)` + `if (is_selected) SetItemDefaultFocus();`（打开时滚动+聚焦到当前项）。
内嵌过滤的三个细节（1447-1462）：`IsWindowAppearing()` 时 `SetKeyboardFocusHere()` + `filter.Clear()`（弹层首次打开自动聚焦过滤框）；`SetNextItemShortcut(ImGuiMod_Ctrl | ImGuiKey_F, ImGuiInputFlags_Tooltip)`（1453）；`filter.Draw("##Filter", -FLT_MIN)` 占满宽（1454）。

**Custom 波特的做法**：在 `BeginCombo` 弹层列表末尾加一个 `InputInt` 行（官方 demo 无现成段落，但 BeginCombo 内可放任意 widget，1445-1462 的过滤框即证明）；或主界面直接 `Combo` + 旁边独立 `InputInt("##baud_custom", &baud, 0, 0)`。

### 3.2 InputInt（imgui.h:734）

`bool InputInt(const char* label, int* v, int step = 1, int step_fast = 100, ImGuiInputTextFlags flags = 0);`
- **隐藏步进按钮**：传 `step=0, step_fast=0`（demo 无专门段落；本项目已在用：bridge.cpp:679 `InputInt("##clear_bytes", auto_clear_bytes, 0, 0)`、bridge.cpp:1150 同式）。
- 返回 true = 值变，随后按 Action 位上报 Lua。bridge 现有模式：
  ```cpp
  if (ImGui::InputInt("##send_period", send_period, 0, 0)) actions |= Action::ActionSyncSettings;  // bridge.cpp:1150
  ```
- **bridge 落地核对**（Custom 波特已实现，bridge.cpp:1354-1366）：
  ```cpp
  if (ImGuiRuntime::instance().baud_custom_ != nullptr) {   // Lua-owned int[1]，经 set_baud_extra 注册（bridge.cpp:2388）
      ImGui::TextUnformatted("CUSTOM"); ImGui::SameLine(0.0f, 6.0f);
      ImGui::SetNextItemWidth(-1.0f);
      if (ImGui::InputInt("##baud_custom", ImGuiRuntime::instance().baud_custom_, 0, 0))
          actions |= Action::ActionSyncSettings;
  }
  ```
  Lua 侧 `serial_config()`（imgui_bridge.lua:222-236）规则：`baud_custom > 0` 时覆盖预设组合框，clamp 到 300..3000000；0 = 用预设。int* 存储走 `xcom_imgui_set_baud_extra(int*)` 导出（bridge.cpp:2388-2390），指针归 Lua 所有——与 ComboSpec 同一条"不缓存调用方指针所属权"纪律（bridge.cpp:144-151 的 Phase 4 LUA-OWNED 注释 + draw_console 的 ComboSpec NOTE 2154-2157）。

---

## 4. 第二个 Begin 窗口（脚本控制台浮窗）与主 dashboard 同帧绘制

官方最简模板就是 example main.cpp 的 "Another Window"（`ref\imgui\examples\example_win32_directx11\main.cpp:164-171`）：

```cpp
if (show_another_window)
{
    ImGui::Begin("Another Window", &show_another_window);  // bool* 给关闭按钮
    ImGui::Text("Hello from another window!");
    if (ImGui::Button("Close Me")) show_another_window = false;
    ImGui::End();
}
```

关键事实：
- **任意多个 Begin/End 可在同帧并列**；窗口 Z 序按 Begin 顺序，后画的在上（浮在 dashboard 上即把浮窗 Begin 放在 dashboard End 之后）。
- 传 `bool*`（`Begin` 第二参）即获得标题栏 X 按钮；不传则没有 X。Begin 返回 false（折叠/裁剪）时**仍必须 End**（imgui.h:441-445 明文，Begin/End 与 BeginChild/EndChild 是"唯二"不遵循 BeginMenu/EndMenu 契约的历史例外）。
- 首次尺寸惯用 `ImGui::SetNextWindowSize(ImVec2(w,h), ImGuiCond_FirstUseEver)`（console demo ref:9121、log demo ref:9580、layout demo ref:9610 同式）；位置同理（ref:415-416 是 demo 主窗口的 FirstUseEver pos+size）。
- 窗口 ID 含 `###` 后缀可保改名后状态连续（doc demo ref:10600-10604 `"%s###doc%d"`）。
- 浮窗内用 `ImGuiWindowFlags_NoDocking`（本项目未开 docking，可不加）。

### 适配 bridge 的最小骨架（已在 Phase 4 落地，核对）

```cpp
// ImGuiRuntime：bool scripts_visible_ = false;（bridge.cpp:167，由 xcom_imgui_set_scripts_visible 驱动）
// xcom_imgui_draw_console() 的 ImGui::End(); /* dashboard */ 之后：
actions |= ui::ScriptConsoleContent();   // bridge.cpp:2229
// ScriptConsoleContent()（bridge.cpp:1554-1726）：
ImGui::SetNextWindowSize(ImVec2(640, 480), ImGuiCond_FirstUseEver);
ImGui::SetNextWindowPos(ImVec2(140, 120), ImGuiCond_FirstUseEver);
bool open = true;
if (ImGui::Begin("Script Console###scripts", &open)) { /* 工具条/列表/编辑器/日志/REPL */ }
ImGui::End();   // Begin 返回 false（折叠）时也必须 End
if (!open) { actions |= Action::ActionToggleScripts; runtime.scripts_visible_ = false; }  // X 关闭回报 Lua
```

注意：
- 本项目 dashboard 是 `SetNextWindowPos/Size(ImGuiCond_Always)` 铺满的（bridge.cpp:2144-2145），对浮窗**不要**用 `Cond_Always`，否则窗口无法被用户拖动/缩放；`Cond_FirstUseEver` 只定初值。
- 浮窗工具条（New/Open folder/Reload/Clear log）用事件队列 `script_events_`（packed `(type<<8)|index`，bridge.cpp:1564-1593）经 `xcom_imgui_take_script_events` 被 Lua 拉取（bridge.cpp:2517）——比逐按钮加 Action 位更省 ABI 位。

---

## 5. 拖拽分隔条（splitter）与自定义 draw-list 直绘

### 5.1 Splitter

**imgui_demo.cpp / imgui.h 均无公开 Splitter 控件**（检索仅命中 `ImDrawListSplitter`，那是 draw-channel 分层，imgui.h:3277，不是 UI 分隔条）。历史上 splitter 例程在 `imgui_internal.h` 的 `ImGui::SplitterBehavior()`（ref imgui_internal.h:3774，内部 API），1.93 demo 已移除公开演示。

本项目现状：`ui::Panel`（bridge.cpp 内）+ `layout.send_height` 等静态尺寸已满足布局；若确需可拖分隔条，两条路：
1. 官方推荐替代——**`BeginChild(..., ImGuiChildFlags_ResizeX)`**（见 demo ref:9627 `BeginChild("left pane", ImVec2(150,0), ImGuiChildFlags_Borders | ImGuiChildFlags_ResizeX)`；ref:9691 属性编辑器 `ImVec2(300,0), ResizeX|Borders|NavFlattened` 同式）。子窗口自带右缘拖拽条，零代码。flags 语义 imgui.h:1230-1247：`ResizeX`(1<<2) 允许右缘拖拽，`ResizeY`(1<<3) 底缘，`AutoResizeX/Y`(1<<4/5) 内容自适应，`AlwaysAutoResize`(1<<6) 官方明言 NOT RECOMMENDED（禁用粗裁剪优化）。
2. 手写 splitter：`InvisibleButton` + `SetMouseCursor` + 拖拽改 `runtime.layout_.send_height`。不依赖内部头。

**Script Console 的左右分栏**（bridge.cpp:1599-1652）用的是第三种：固定宽 `BeginChild("##script_list", ImVec2(170, 0))` + `SameLine()` + `BeginChild("##script_editor", ImVec2(0,0))`——official layout demo（ref:9624-9663）的"left pane + SameLine + right BeginGroup"同构；若要可拖，把列表 child 换成 `ResizeX` 一行改动。

### 5.2 自定义 draw-list 直绘（关键词高亮底块 / 行内着色的基础）

官方段落 `ShowExampleAppCustomRendering`（ref imgui_demo.cpp:10249-10540+），三个 Tab：

- **Primitives**（10265-10390+）：`ImDrawList* draw_list = ImGui::GetWindowDrawList();`（10270）后随意 Add*。颜色两种给法：`ImU32 col = ImColor(colf);`（10316，ImVec4 转 ImU32）或 `ImGui::GetColorU32(IM_COL32(...))`（10280-10281，自动乘 style.Alpha）。所有坐标是**屏幕坐标**（`GetCursorScreenPos()`，10420 行注释明示"ImDrawList API uses screen coordinates!"）。
- **Canvas 网格**（10419-10488）：InvisibleButton 占位 + `GetCursorScreenPos`/`GetContentRegionAvail` 算画布 + `draw_list->PushClipRect(canvas_p0, canvas_p1, true)` 裁剪绘制 + PopClipRect（10477/10488）。**自定义绘制必须自己 PushClipRect 或确保父窗口已裁剪**，否则 ImDrawList 元素不会被窗口边界裁掉（5352 行 `if (!ImGui::IsItemVisible()) continue;` 的注释明示"Skip rendering as ImDrawList elements are not clipped"）。
- **BG/FG draw lists**（10493-10510）：`GetBackgroundDrawList()` 画在所有窗口之下（10506），`GetForegroundDrawList()` 画在所有窗口之上（10508）。API 定义 imgui.h:1049-1050。
- **Draw Channels**（10515-10540+）：`ChannelsSplit/SetCurrentChannel/Merge` 可让后画的出现在底层——本项目未用，够用即可。

**AddText 两个重载**（imgui_draw.cpp:1736/1763；声明在 imgui.h 的 ImDrawList 段）：
```cpp
draw_list->AddText(ImVec2 pos, ImU32 col, const char* text_begin, const char* text_end);  // 简版：当前字体
draw_list->AddText(ImFont* font, float font_size, ImVec2 pos, ImU32 col,
                   const char* text_begin, const char* text_end,
                   float wrap_width = 0.0f, const ImVec4* cpu_fine_clip_rect = NULL);      // 全参版
```
Text Clipping 段（ref 5320-5383）演示三种裁剪：`ImGui::PushClipRect`（影响 hit-test + 渲染）、`draw_list->PushClipRect`（只影响渲染）、AddText 第 9 参 `cpu_fine_clip_rect`（只影响这一条 AddText，5377 行——官方内部画文字常这样省 draw call）。

**颜色常量**：`IM_COL32(R,G,B,A)`（imgui.h 宏）、`IM_COL32_WHITE`、`ImGui::GetColorU32(ImGuiCol idx)`（imgui.h:562，取主题色并乘 style alpha）。Menu/Colors 段（ref 9019-9030）演示逐色卡画法：`AddRectFilled(p, p+sz, ImGui::GetColorU32((ImGuiCol)i))`。

**bridge 已用直绘的先例**（核对）：接收区时间戳前缀橙色 overdraw `draw->AddText(nullptr, 0.0f, ts_pos, ts_color, begin, begin+15)`（bridge.cpp:1059）——font=nullptr/size=0 表示"用当前字体"，官方 AddText 简版语义；关键词高亮 bg 规则 `AddRectFilled(pos+px, pos+px+pw, color, 2.0f)`（bridge.cpp:969-972）+ 文字 run `AddText(ImVec2(pos.x+pen_x, pos.y), col, seg, seg_end)`（bridge.cpp:1005/1021）。所有绘制发生在 receive Panel 的 child 内，裁剪由 child 自带——无需手动 PushClipRect。

---

## 6. 字体 glyph ranges（中文支持）

### 6.1 v1.93 的重大变化：渲染器支持动态纹理时 ranges 已非必需

- 本项目 DX11 后端**已支持** `ImGuiBackendFlags_RendererHasTextures`（ref `backends\imgui_impl_dx11.cpp:631`，编译副本 `imgui_impl_dx11.cpp:669` 同；Init 时置位、Shutdown 清位 ref:674）。后端动态响应 `ImGuiPlatformIO::Textures[]` 请求（ref:633-637 注册 texture max 尺寸与回调），字体纹理按需增长。
- 官方 FONTS.md（`ref\imgui\docs\FONTS.md`）：
  - 58 行（FAQ 第 3 条）："Since 1.92, with an up to date backend: specifying glyph ranges is unnecessary."
  - 95-104 行（"New! Dynamic Fonts system in 1.92" 段）：icons/Asian 用户不再需要预建 glyphs；`PushFont(nullptr, new_size)` 可随时改字号。
  - 226 行示例直接 `AddFontFromFileTTF("NotoSansCJKjp-Medium.otf")` 不传 ranges。
  - 82-89 行：atlas 初始 512x128，按需增长；已知会用大字体时可设 `TexMinWidth/TexMinHeight`（imgui.h:3839-3840）减少初始增长拷贝。
- **结论：bridge 加中文最简路径 = 直接 `AddFontFromFileTTF("C:\\Windows\\Fonts\\msyh.ttc", ...)` 不传 glyph_ranges**，运行时遇到新字自动扩 atlas（本项目后端成立）。
- 但注意 imgui.h:3789"Since 1.92: specifying glyph ranges is only useful/necessary if your backend doesn't support ImGuiBackendFlags_RendererHasTextures!"——若要**限制内存**（Windows 字体全集 2 万+字形，WARP 软渲染下纹理上传有成本），仍可显式传 ranges。
- **WARP 权衡（本项目实测口径）**：bridge.cpp:2087-2092 注释选择 ChineseSimplifiedCommon（2500 字）而非动态全量——WARP 软渲染下 atlas 增长伴随 alloc+copy（FONTS.md:82），串口日志里的 CJK 流量不可控，预算确定优于性能不确定。

### 6.2 GetGlyphRanges* 现状（ref\imgui\imgui.h / imgui_draw.cpp）

- `imgui.h:3791-3804`：GetGlyphRangesGreek/Korean/Japanese/ChineseFull/ChineseSimplifiedCommon/Cyrillic/Thai/Vietnamese 整组包在 `#ifndef IMGUI_DISABLE_OBSOLETE_FUNCTIONS` 里——**仍可用（imconfig.h 未定义该宏即编译），但已标 obsolete**。`GetGlyphRangesDefault()`（3790）不在包内，永不废弃。
- `GetGlyphRangesChineseSimplifiedCommon()`（imgui.h:3800）：Default + Half-Width + 平假名/片假名 + **2500 个常用简体 CJK 表意字**。实现 `imgui_draw.cpp:4963-5029`：函数内 `static ImWchar full_ranges[...]`（5022）惰性构建（`if (!full_ranges[0])` 5023），**返回的指针生命周期 = 进程级 static，安全可长期持有**。字表是 `static const short accumulative_offsets_from_0x4E00[]`（4970-5011）紧凑编码 + `UnpackAccumulativeOffsetsIntoRanges`（4953-4961）解包。
- `GetGlyphRangesChineseFull()`（imgui_draw.cpp:4937-4951）：0x4E00-0x9FAF 全量（4947 行 `0x4e00, 0x9FAF`）~21000 字，atlas 会显著变大（WARP 软渲染下慎用）。
- 规模参考：2500 字表覆盖 1987 年 7 月汉字使用的 **97.97%**（imgui_draw.cpp:4967 原注释）。串口调试场景（中文注释/路径/提示语）足够。

### 6.3 ImFontGlyphRangesBuilder（自定义精确集）

结构定义：`imgui.h:3684-3696`。API：`AddText` / `AddChar` / `AddRanges` / `BuildRanges(ImVector<ImWchar>*)`。位图存储 `ImVector<ImU32> UsedChars`（3686），`Clear()` resize 到 `(IM_UNICODE_CODEPOINT_MAX+1)/8` 字节（3689）——**WCHAR32 关闭时 8KB，开启时 128KB**（imconfig.h 的 IMGUI_USE_WCHAR32 决定）。
官方用法（FONTS.md:429-438，FAQ.md:879-885 同款）：

```cpp
ImVector<ImWchar> ranges;                       // 局部变量！
ImFontGlyphRangesBuilder builder;
builder.AddText("Hello world");
builder.AddChar(0x7262);
builder.AddRanges(io.Fonts->GetGlyphRangesJapanese());
builder.BuildRanges(&ranges);
io.Fonts->AddFontFromFileTTF("myfont.ttf", size_in_pixels, nullptr, ranges.Data);
io.Fonts->Build();   // Build 时 ranges 必须仍存活
```

**生命周期陷阱（重点）：**
1. `AddFont*` 只存**指针**不拷贝数据（imgui.h:3736-3737 Common pitfalls 原注释："you need to make sure that your array persists up until the atlas is build... We only copy the pointer, not the data."）。`BuildRanges` 输出的 `ImVector<ImWchar>` 若是**函数局部变量，函数返回后 ImVector 析构 → 悬垂**；后端在随后任意一次 Build/GetTexData 时读野指针。
2. **static 陷阱**：`static ImVector<ImWchar> ranges;` 放在 `xcom_imgui_init` 里看似安全，但若 `xcom_imgui_shutdown` → `ImGui::DestroyContext()` → 再次 init，static 旧内容仍有效（ImVector 数据在堆上）此路径 OK；真正的坑是 `static ImFontGlyphRangesBuilder builder;`——builder 的位图（8KB/128KB）在 DLL 卸载/重载时与其他 static 顺序耦合。**稳妥做法：ranges 挂 ImGuiRuntime 成员，builder 做栈变量**（每次 init 重建，幂等）。
3. v1.93 新字体系统下 `AddFontFromFileTTF` 的 `size_pixels=0.0f` 可省（imgui.h:3751 默认参数，用 style.FontSizeBase），且 glyph_ranges 传 nullptr = 后端动态按需加载。
4. **MergeMode 下的 ranges 忽略规则**（FONTS.md:351-354）："Since 1.92, with an up to date backend: glyphs ranges are ignored: when loading a glyph, input fonts in the merge list are queried in order. The first font which has the glyph loads it."——即动态纹理后端上 MergeMode+ranges 的 ranges 只是初版预热，后续仍按需查 merge 链。**GlyphExcludeRanges**（FONTS.md:356-367，imgui.h ImFontConfig 段）可反向排除某字体的一段，防双字体重叠。

### 6.4 bridge 已落地的 CJK 实现（Phase 4 核对）

```cpp
// bridge.cpp:2093-2110（xcom_imgui_init 内，mono 字体加载之后）：
if (runtime.font_mono_cjk_) {                       // [font] mono_cjk 开关（layout.toml，默认 true）
    runtime.cjk_ranges_.clear();                    // ImVector<ImWchar> cjk_ranges_ 挂 Runtime（bridge.cpp:185）
    ImFontGlyphRangesBuilder builder;               // 栈上 builder：位图勿 static
    builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());  // 2500 常用字
    builder.BuildRanges(&runtime.cjk_ranges_);      // 输出随 Runtime 存活，覆盖 Build 期
    ImFontConfig merge_config;
    merge_config.MergeMode = true;                  // 并入 mono 字体：Text() 无需 PushFont
    ImFont* merged = io.Fonts->AddFontFromFileTTF(
        "C:\\Windows\\Fonts\\msyh.ttc", 16.0f, &merge_config, runtime.cjk_ranges_.Data);
    if (!merged)
        io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\simsun.ttc", 16.0f, &merge_config,
                                     runtime.cjk_ranges_.Data);  // 失败退 SimSun，再失败静默
}
```
- 只 merge 进 **mono 字体**（收发区）：body/heading 字体（Siemens Slab）不含 CJK，中文出现在日志行时由 mono 的 merge 层兜住——UI 标签本身是英文，不需要 heading CJK。
- **UTF-8 前提**（FAQ.md:888-892）：所有字符串必须 UTF-8；本地代码页（CP936/GBK）字面量**不工作**。bridge 侧字面量全 ASCII，中文只经 Lua 侧（LuaJIT 字符串是字节串，`core/charset.lua` 转 UTF-8 后 push）到达，天然合规。IME 输入：Win32 后端 WM_CHAR/WM_IME_CHAR/WM_IME_COMPOSITION 已内建（imgui_impl_win32.cpp:787-818），REPL 里可直接打中文。
- 备选（零 ranges、吃内存换简单）：`AddFontFromFileTTF("C:\\Windows\\Fonts\\msyh.ttc", 17.0f)` 不传 ranges，靠 DX11 后端动态纹理（本项目后端已支持，见 6.1）——但注意 6.1 的 WARP 权衡，本项目选了显式 ranges。

---

## 7. ImPlot v1.1 WIP（示波器面板）

### 7.1 头文件 API 速查（`third_party\xcom_imgui\implot\implot.h`）

| API | 签名 | 行号 |
|---|---|---|
| BeginPlot | `bool BeginPlot(const char* title_id, const ImVec2& size=ImVec2(-1,0), ImPlotFlags flags=0)` | 769 |
| EndPlot | `void EndPlot()` | 773 |
| SetupAxis | `void SetupAxis(ImAxis axis, const char* label=nullptr, ImPlotAxisFlags flags=0)` | 867 |
| SetupAxisLimits | `void SetupAxisLimits(ImAxis axis, double v_min, double v_max, ImPlotCond cond=ImPlotCond_Once)` | 869 |
| SetupAxesLimits | `void SetupAxesLimits(double x_min, double x_max, double y_min, double y_max, ImPlotCond cond=ImPlotCond_Once)` | 892 |
| SetupLegend | `void SetupLegend(ImPlotLocation location, ImPlotLegendFlags flags=0)` | 895 |
| SetupFinish | `void SetupFinish()` | 901 |
| PlotLine(x+y 双数组) | `IMPLOT_TMP void PlotLine(const char* label_id, const T* xs, const T* ys, int count, const ImPlotSpec& spec=ImPlotSpec())` | **992** |
| PlotLine(单数组) | `IMPLOT_TMP void PlotLine(const char* label_id, const T* values, int count, double xscale=1, double xstart=0, const ImPlotSpec& spec=ImPlotSpec())` | 991 |
| PlotLineG | getter 回调版 | 993 |
| GetPlotLimits | `ImPlotRect GetPlotLimits(ImAxis x_axis=IMPLOT_AUTO, ImAxis y_axis=IMPLOT_AUTO)` | 1127 |
| IsPlotHovered | `bool IsPlotHovered()` | 1130 |
| GetPlotMousePos | `ImPlotPoint GetPlotMousePos(...)` | 1125 |
| DragLineX | `bool DragLineX(int id, double* x, const ImVec4& col, float thickness=1, ImPlotDragToolFlags flags=0, bool* out_clicked=nullptr, bool* out_hovered=nullptr, bool* out_held=nullptr)` | 1082 |
| DragLineY | 同型 | 1084 |
| Annotation | `void Annotation(double x, double y, const ImVec4& col, const ImVec2& pix_offset, bool clamp, const char* fmt, ...)` | 1090 |
| TagX/TagY | `void TagX(double x, const ImVec4& col, const char* fmt, ...)` | 1095/1099 |
| CreateContext/DestroyContext | 735/737（须在 ImGui context 创建后/销毁前） | |
| PushStyleColor(ImPlotCol, ImVec4) | 1228 | |
| StyleColorsAuto | `void StyleColorsAuto(ImPlotStyle* dst=nullptr)`（跟 ImGui 风格，本项目浅色主题用它） | 1214 |

**v1.0 起被移除的旧 API（勿照抄网上旧代码）**——implot.h:1396-1402 obsolete 段注释：
`SetNextLineStyle`、`SetNextFillStyle`、`SetNextMarkerStyle`、`SetNextErrorBarStyle` **已在 v1.0 全删**，替代物是 `ImPlotSpec`（构造时传或 `SetProp`）。

**Setup 调用契约**（implot.h:837-864）：Setup 系列必须在 `BeginPlot` 之后、任何 PlotX/工具调用之前；一旦开画 Setup 锁死。`SetupFinish()` 可选。

### 7.2 ImPlotSpec（v1.1 核心结构，implot.h:517-606）

```cpp
struct ImPlotSpec {
    ImVec4 LineColor = IMPLOT_AUTO_COL;   // IMPLOT_AUTO_COL=ImVec4(0,0,0,-1) 走 colormap
    float  LineWeight = 1.0f;
    ImVec4 FillColor = IMPLOT_AUTO_COL;
    float  FillAlpha = 1.0f;
    ImPlotMarker Marker = ImPlotMarker_None;
    float  MarkerSize = 4;
    int    Offset = 0;                    // 环形缓冲起始索引（关键！）
    int    Stride = IMPLOT_AUTO;          // 字节步长； ImVec2 数组传 sizeof(ImVec2)
    ImPlotItemFlags Flags = 0;            // 项级 flags 混在此（v1.1 新设计）
    // ... Marker/颜色数组指针成员略（518-534 全表）
};
```
两种用法（implot.h:500-516 注释 + demo 2422-2446）：
```cpp
// A. 结构体逐字段
ImPlotSpec spec; spec.LineColor = ImVec4(1,1,0,1); spec.LineWeight = 2.0f;
ImPlot::PlotLine("MyLine", xs, ys, 100, spec);
// B. 内联 (ImPlotProp, value) 对，顺序无关
ImPlot::PlotLine("MyLine", xs, ys, 100, {ImPlotProp_LineWeight, 2.0f, ImPlotProp_Flags, ImPlotItemFlags_NoLegend});
```

### 7.3 实时滚动示波器（Demo_RealtimePlots）

源：`implot_demo.cpp:1018-1068`。三要素：

**a) ScrollingBuffer 环形缓冲**（implot_demo.cpp:140-163）：
```cpp
struct ScrollingBuffer {
    int MaxSize;  int Offset;  ImVector<ImVec2> Data;
    void AddPoint(float x, float y) {
        if (Data.size() < MaxSize) Data.push_back(ImVec2(x,y));
        else { Data[Offset] = ImVec2(x,y); Offset = (Offset+1) % MaxSize; }
    }
};
```
**b) 绘制时 Offset+Stride 直读环缓冲**（implot_demo.cpp:1043-1055）：
```cpp
if (ImPlot::BeginPlot("##Scrolling", ImVec2(-1, ImGui::GetTextLineHeight()*10))) {
    ImPlot::SetupAxes(nullptr, nullptr, ImPlotAxisFlags_NoTickLabels, ImPlotAxisFlags_NoTickLabels);
    ImPlot::SetupAxisLimits(ImAxis_X1, t - history, t, ImGuiCond_Always);   // 跟随窗口
    ImPlot::SetupAxisLimits(ImAxis_Y1, 0, 1);                               // 固定 Y
    ImPlotSpec spec;
    spec.Offset = sdata1.Offset;            // 环形起点交给 ImPlot，无需物理重排
    spec.Stride = 2 * sizeof(float);        // ImVec2 连续存储，x/y 交错
    ImPlot::PlotLine("Mouse Y", &sdata2.Data[0].x, &sdata2.Data[0].y, sdata2.Data.size(), spec);
    ImPlot::EndPlot();
}
```
**c) Follow / 回看**：`ImGuiCond_Always` 每帧锁 X 范围 = 追尾（1045）；回看 = 用户拖动/缩放后改用 `GetPlotLimits()` 读回当前范围、不再强制 SetupAxisLimits。双击自动 fit 是内建行为（InputMap.Fit=LMB 双击，implot.h:702）。
另 RollingBuffer（166-179，时间取模折返式）适合"示波器满屏滚动"观感，二选一。

**游标**（DragLineX 做测量游标，implot_demo.cpp:1979-1982）：
```cpp
ImPlot::DragLineX(0, &x1, ImVec4(1,1,1,1), 1, flags);
ImPlot::DragLineY(2, &y1, ImVec4(1,1,1,1), 1, flags);
```
配合 Tag 显示数值（Demo_Tags，2174-2175）：`ImPlot::DragLineY(0,&drag_tag,ImVec4(1,0,0,1),1,ImPlotDragToolFlags_NoFit); ImPlot::TagY(drag_tag, ImVec4(1,0,0,1), "Drag");`
Annotation 标注（Demo_Annotations 2144-2148）：`ImPlot::Annotation(x, y, col, ImVec2(-15,15), clamp, "BL");`

### 7.4 对本项目示波器的 flags 建议（implot.h:160-172）

- `ImPlotFlags_Crosshairs`（1<<8，170 行）：悬停十字光标，串口波形查看体验佳，**建议开**。
- `ImPlotFlags_NoMenus`（1<<4，166 行）：右键默认弹设置菜单，仪表盘场景干扰，**建议开**（或保留做高级调参入口，二选一）。
- `ImPlotFlags_NoBoxSelect`（1<<5）：若开 NoMenus 通常一并关掉框选。
- `ImPlotFlags_CanvasOnly`（171 行组合宏）= NoTitle|NoLegend|NoMenus|NoBoxSelect|NoMouseText——**不适合**，示波器要图例和坐标读数。
- 轴：`ImPlotAxisFlags_NoTickLabels`（demo 1041 同款）省 CPU；`ImPlotAxisFlags_LockMin|LockMax`（193 行）锁死回看手滑。
- 样式：init 后 `ImPlot::StyleColorsAuto()`（implot.h:1214）自动映射 ImGui 浅色主题；逐项微调用 `ImPlot::PushStyleColor(ImPlotCol_PlotBg, ImVec4(...))`（1228）。

### 7.5 集成步骤（bridge 现状 → 示波器；截至 2026-09-05 快照 ImPlot 尚未接入 bridge）

1. `CMakeLists.txt`（`xcom_lua\native\xcom_imgui\CMakeLists.txt:12-20`）的 `add_library` 源列表追加 `${IMPLOT_ROOT}/implot.cpp`、`implot_items.cpp`，并 `target_include_directories` 加 implot 目录；链接无需新库。
2. `xcom_imgui_init`（bridge.cpp:2007 起）在 `ImGui::CreateContext()`（bridge.cpp:2049）后调 `ImPlot::CreateContext()`；`shutdown_impl`（bridge.cpp:1656）在 `ImGui::DestroyContext()` 前调 `ImPlot::DestroyContext()`。ImPlot 静态链入 DLL，无需 `SetImGuiContext`（那是 ImPlot 单独成 DLL 时的需求，implot.h:59/747）。
3. 数据通道：新导出 `xcom_imgui_scope_push(int ch, double t, double v)`（Lua 每 16-100ms 喂点）+ `xcom_imgui_scope_clear()`；缓冲挂 `ImGuiRuntime`（两个通道各一个 `std::vector<ImVec2>` + `int offset`，仿 ScrollingBuffer）。注意 Lua 侧已有 `core/waveform.lua` + `tests/test_wave_ring.lua` 的波形环——数据源在那里，push 只需桥接。
4. 面板绘制：dashboard 的 monitor 列内新增可折叠示波器段（`CollapsingHeader("Scope")`，见 1.3），或独立浮窗（第 4 节模式）。

### 最小骨架（示波器面板段）

```cpp
// ImGuiRuntime 新增（bridge.cpp:96 class ImGuiRuntime 类内）：
//   static constexpr int kScopeMax = 2000;
//   ImVec2 scope_data_[2][kScopeMax];  int scope_off_[2] = {0,0};  int scope_count_[2] = {0,0};
//   double scope_t_ = 0.0;  float scope_history_ = 10.0f;
void DrawScope(ImGuiRuntime& rt) {
    if (!ImGui::CollapsingHeader("Scope")) return;
    ImGui::SliderFloat("History", &rt.scope_history_, 1, 30, "%.1f s");
    if (ImPlot::BeginPlot("##scope", ImVec2(-1, ImGui::GetTextLineHeight()*10),
                          ImPlotFlags_Crosshairs | ImPlotFlags_NoMenus)) {
        ImPlot::SetupAxes(nullptr, nullptr, ImPlotAxisFlags_NoTickLabels,
                                          ImPlotAxisFlags_NoTickLabels);
        ImPlot::SetupAxisLimits(ImAxis_X1, rt.scope_t_ - rt.scope_history_, rt.scope_t_,
                                ImGuiCond_Always);      // 追尾；回看分支改不 Always
        ImPlot::SetupAxisLimits(ImAxis_Y1, 0, 5);
        for (int ch = 0; ch < 2; ++ch) {
            ImPlotSpec spec;
            spec.Offset = rt.scope_off_[ch];
            spec.Stride = sizeof(ImVec2);
            char label[8]; sprintf_s(label, "CH%d", ch + 1);
            ImPlot::PlotLine(label, &rt.scope_data_[ch][0].x, &rt.scope_data_[ch][0].y,
                             rt.scope_count_[ch], spec);
        }
        // 测量游标
        ImPlot::DragLineX(1, &rt.scope_cursor_x_, ImVec4(1,1,1,1), 1, ImPlotDragToolFlags_NoFit);
        if (ImPlot::IsPlotHovered()) {
            ImPlotPoint mp = ImPlot::GetPlotMousePos();
            ImPlot::Annotation(mp.x, mp.y, ImVec4(1,1,0,1), ImVec2(10,10), true,
                               "(%.3f, %.3f)", mp.x, mp.y);
        }
        ImPlot::EndPlot();
    }
}
```

---

## 8. v1.93 / v1.1 新旧差异清单（照抄旧教程会踩的坑）

（imgui 行号 = ref\imgui master 19295；implot 行号 = third_party 编译副本。）

| 主题 | 旧版（≤1.89 / ImPlot ≤0.x） | 本项目 v1.93.0 WIP / ImPlot 1.1 WIP | 依据 |
|---|---|---|---|
| PushStyleColor | 部分老代码传 `ImU32` 打包色 | 两个重载并存：`PushStyleColor(ImGuiCol idx, const ImVec4&)`（推荐，imgui.h:541）与 `(ImGuiCol, ImU32)`（imgui.h:540） | imgui.h:540-541 |
| InputTextMultiline size | 老教程 `float w, float h` 两参数 | **单个 `const ImVec2&`**；buf_size 是 `size_t` | imgui.h:728 |
| InputTextMultiline 默认行为 | 无 WordWrap | 有 `ImGuiInputTextFlags_WordWrap`（Beta） | imgui.h:1323 |
| 字体 ranges | 必传 GetGlyphRangesXXX | DX11 后端支持 `RendererHasTextures`（动态纹理）→ **可不传**；GetGlyphRangesXXX 组标 obsolete 但仍可用 | imgui.h:3789-3804、imgui_impl_dx11.cpp(ref):631、FONTS.md:58/95-104/208 |
| 字体 size_pixels | 必传像素大小 | `size_pixels=0.0f` 默认（用 style.FontSizeBase） | imgui.h:3751 |
| PushFont | 单参 `PushFont(font)` | 双参 `PushFont(font, size_base)`；单参版保留为 obsolete inline shim（映射 `font->LegacySize`，imgui.h:533 + 副本:4413）。**勿传 GetFontSize() 结果当字号**（imgui.h:531-532 明言全局缩放因子会叠两次） | imgui.h:517-534 |
| 快捷键 | `IsKeyDown`+mods 轮询 / io.KeyMap | `ImGui::Shortcut(chord, flags)` 路由系统 + `SetNextItemShortcut`（+ `ImGuiInputFlags_Tooltip` 角标） | imgui.h:1103-1104、1712-1732 |
| Escape 清空 | 无 | `ImGuiInputTextFlags_EscapeClearsAll` | imgui.h:1291 |
| BeginChild 第3参 | 旧为 `bool border` | **`ImGuiChildFlags`**（如 `ImGuiChildFlags_NavFlattened`(1241)、`_ResizeX`(1235)）；`Borders == 1 == true` 兼容旧布尔 | imgui.h:450-470、1230-1247 |
| ImPlot 线型 | `SetNextLineStyle(col, weight)` | **v1.0 已删**；用 `ImPlotSpec{...}` 或 `(ImPlotProp, value)` 对 | implot.h:1396-1402 |
| ImPlot item flags | PlotLine 独立 flags 参数 | 并入 `ImPlotSpec::Flags`（可混 `ImPlotItemFlags_*` 与 `ImPlotLineFlags_*`） | implot.h:255、534 |
| ImPlot PushStyleColor | — | `PushStyleColor(ImPlotCol, const ImVec4&)` 与 ImU32 双载 | implot.h:1227-1228 |
| Combo 选中初焦 | — | `Selectable(..., is_selected)` + `SetItemDefaultFocus()` 惯用式 | imgui_demo.cpp(ref):1430-1439 |

---

## 9. 任务对照速查（Phase 4 落地索引）

（ref 行号 = 官方 master 模板；bridge 行号 = 2026-09-05 2610 行快照。）

| 计划功能 | 本文档节 | 官方模板源（ref） | bridge 状态 |
|---|---|---|---|
| 接收区高亮渲染（关键词 着色+底块） | 1.4 + 5.2 | imgui_demo.cpp:9217-9226（整行式）；行内分段是自定义 draw-list（5.2） | **已落地** bridge.cpp:919-1040（HitSpan + AddRectFilled/AddText） |
| 脚本控制台浮窗（列表+编辑器+日志+REPL） | 4 + 2 + 1.2 | main.cpp:164-171、imgui_demo.cpp:9061-9411 | **已落地** bridge.cpp:1554-1726 `ScriptConsoleContent` |
| 编辑器 Tab/resize/Ctrl+S | 2.1-2.3 | imgui_demo.cpp:3891-3920、4027-4071；misc/cpp/imgui_stdlib.cpp:39-58 | **已落地** bridge.cpp:1545-1553（resize 回调）、1590-1593（Ctrl+S）、1642-1648（编辑器） |
| Custom 波特 InputInt | 3.2 | imgui.h:734 | **已落地** bridge.cpp:1354-1366 + 2388 导出 |
| 波特下拉增强（搜索/自定义项） | 3.1 | imgui_demo.cpp:1445-1463 | 可选增强，未做 |
| ImPlot 示波器面板 | 7.1-7.5 | implot_demo.cpp:140-163、1018-1068、1962-1992 | **未接入**（CMake 未加 implot.cpp；数据源 core/waveform.lua 已就绪） |
| 游标/标注 | 7.3 | implot_demo.cpp:1962-1992、2135-2159 | 随示波器 |
| 中文/CJK 字体 | 6.1-6.4 | FONTS.md:56-104、206-238、424-439；imgui_draw.cpp:4937-5029 | **已落地** bridge.cpp:2093-2110（mono MergeMode + msyh/simsun） |
| 可拖分隔条（如需） | 5.1 | imgui_demo.cpp(ref):9627/9691（ChildFlags_ResizeX） | 未做（固定 170px 列表 + SameLine） |
