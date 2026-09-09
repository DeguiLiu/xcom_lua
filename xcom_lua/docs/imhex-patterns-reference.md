# ImHex 代码模式参考（面向 xcom_imgui_bridge.cpp + Lua 被动驱动）

> 研究对象：`D:\workspace\SSCOM_lua\ref\ImHex`（ImHex 1.39.0.WIP，Dear ImGui 1.93 + ImPlot 1.1 + GLFW/OpenGL3）。
> 面向本项目四个待实现功能：接收日志关键词高亮、Lua Script Console 浮窗、ImPlot 示波器、HEX 数据视图增强。
> 本文档所有 ImHex 行号均于 2026-09-04 用 Read/Grep 逐条核实（文件路径以 `ref/ImHex/` 为根缩写）。
> 本项目侧行号引用自 `docs/imgui-patterns-reference.md` 已核实内容（bridge.cpp 约 1790 行）。

---

## 0. ImHex 架构速览

### 0.1 目录结构（只列与本研究相关的）

| 目录 | 内容 | 与本项目关系 |
|---|---|---|
| `main/gui/source/window/window.cpp` | GLFW 主循环、dockspace、帧调度、ImPlot/ImNodes context 创建 | 参考帧循环与节流 |
| `main/gui/source/init/splash_window.cpp` | 启动窗、字体初始加载 | 字体初始化参考 |
| `lib/libimhex/include/hex/ui/view.hpp` + `source/ui/view.cpp` | View 基类与 6 个子类 | 窗口组织模式 |
| `lib/libimhex/include/hex/ui/popup.hpp` | Popup<T> 模板 | 弹窗栈 |
| `lib/libimhex/include/hex/api/event_manager.hpp` | EventManager 模板事件总线 | 事件失效通知 |
| `lib/libimhex/source/api/imhex_api.cpp` | 高亮/选区/字体等全局 API | 高亮注册 API |
| `lib/libimhex/include/hex/ui/imgui_imhex_extensions.h` | ImGui 扩展控件（TextFormatted 系列等） | 直接可抄的小工具 |
| `plugins/ui/` | **HexEditor 控件**（非 View，可复用组件）+ **TextEditor 控件** | 本研究重点 |
| `plugins/builtin/source/content/views/` | 20 个 View（hex_editor/pattern_editor/logs/find/highlight_rules 等） | 各功能实现 |
| `plugins/fonts/` | 字体角色注册 + merge 字体加载 | CJK/图标字体 |
| `plugins/windows/source/views/view_tty_console.cpp` | 串口 TTY 控制台（Win32） | **与本项目同域** |
| `plugins/visualizers/source/content/pl_visualizers/` | ImPlot 波形可视化器 | 示波器参考 |

### 0.2 核心类关系

```
Window (main, 拥有 GLFW 窗口与主循环)
 └─ 每帧 Window::frame() 逆序遍历 ContentRegistry::Views::impl::getEntries()
     └─ View (抽象基类, lib view.hpp:20)
         ├─ View::Window    普通可停靠窗口 (view.hpp:148)
         │   ├─ View::Floating  浮窗, +NoDocking (view.hpp:185)
         │   └─ View::Scrolling 允许窗口滚动 (view.hpp:197)
         ├─ View::Special   不建窗口, 自绘内容 (view.hpp:175, 用于 command palette)
         ├─ View::Modal     BeginPopupModal (view.hpp:211)
         └─ View::FullScreen
View 组合可复用控件（非 View 子类）:
     hex::ui::HexEditor   (plugins/ui, 十六进制网格, 值对象可拷贝)
     hex::ui::TextEditor  (plugins/ui, 代码编辑器, 内部 Lines 持有全部状态)
全局服务: EventManager(事件) / ImHexApi::HexEditor(高亮+选区) / ImHexApi::Fonts(字体角色) / TaskManager(doLater 延迟到主线程执行)
```

关键点：**HexEditor/TextEditor 是"控件"（组合），View 是"窗口"（继承）**。ImHex 自己也把重渲染逻辑放在控件层而不是 View 层——这对单文件 bridge 是最对路的分层。

---

## 1. 十六进制视图实现（HEX 视图 + 关键词高亮的直接参考）

### 1.1 高效渲染大量行：手算可见行区间，不用 ListClipper

`plugins/ui/source/ui/hex_editor.cpp` `drawEditor()`：

- 可见行数：`m_visibleRowCount = size.y / CharacterSize.y;`（hex_editor.cpp:930-931，`CharacterSize = ImGui::CalcTextSize("0")` 795 行）
- 行循环（hex_editor.cpp:938）：
  ```cpp
  for (ImS64 displayY = m_scrollPosition; displayY < (m_scrollPosition + m_visibleRowCount + 5)
       && displayY < numRows && numRows != 0; displayY++) {
  ```
  多画 5 行冗余缓冲。滚动位置 `m_scrollPosition` 是**行号**（不是像素），完全自管理。
- 布局用 `ImGui::BeginTable` + `TableSetupColumn(WidthFixed)`（hex_editor.cpp:837、863-895），列宽 = `CharacterSize.x * maxCharsPerCell`（875 行）。`TableSetupScrollFreeze(0, 2)` 冻结表头（839 行）。
- **为什么不用 ListClipper**：等宽字体 + 固定行高下行号可直接由滚动像素换算，`ImGuiListClipper` 的通用步进是多余的。ImHex 只在 TTY 控制台这种"每行一个 string"的场景才用 clipper（见 §5.3）。

### 1.2 滚动条：自绘 ScrollbarEx + 鼠标滚轮

`drawScrollbar()`（hex_editor.cpp:405-450）：因为行循环绕过了 ImGui 自身滚动，需要自己画滚动条：

```cpp
ImGui::ScrollbarEx(bb, ImGui::GetWindowScrollbarID(window, axis), axis,
    &m_scrollPosition.get(),          // 单位: 行
    visibleRowCount, numRows, roundingCorners);   // hex_editor.cpp:420-427
...
if (ImGui::IsWindowHovered()) {
    float scrollMultiplier;   // Ctrl+Shift=10页, Ctrl=1页, 普通=5行 (436-441)
    m_scrollPosition += ImS64(ImGui::GetIO().MouseWheel * -scrollMultiplier);  // 443
}
```

### 1.3 选区与高亮绘制（对我们关键词高亮最有价值）

三层叠加，全用 window draw list：

- **背景色块** `drawBackgroundHighlight()`（hex_editor.cpp:720-727）：
  ```cpp
  auto drawList = ImGui::GetWindowDrawList();
  drawList->PushClipRect(window->Rect().Min, window->Rect().Max, false);
  drawList->AddRectFilled(cellPos, cellPos + cellSize, backgroundColor);
  drawList->PopClipRect();
  ```
- **选区边框** `drawFrame()`（hex_editor.cpp:736-771）：不是填充整块，而是 4 条 1px 线（上下左右各在"选区边界或行边界"时画），视觉像 VS Code 的单元格选框；鼠标下的当前格再叠一层 7.5% 透明填充（752 行）。
- **前景文字色**：`ImGui::PushStyleColor(ImGuiCol_Text, *foregroundColor)` 后再画单元格文本（hex_editor.cpp:1087-1091、1153-1157）。

**每行颜色预计算**（hex_editor.cpp:992-1026）：进入行循环后先把整行的 `(fg,bg)` 查好放进 `cellColors` 向量（935 行声明），列循环只读结果——把"颜色决策"与"绘制"分离，配合下面的缓存避免了每帧每格回调。

### 1.4 字节级着色与高亮缓存

- 全局 API：`ImHexApi::HexEditor::addForegroundHighlight(region, color)` / `addBackgroundHighlight` / 以及 **函数版** `addForegroundHighlightingProvider(fn)`（`lib/libimhex/include/hex/api/imhex_api/hex_editor.hpp:82-160`，实现 `imhex_api.cpp:126-190`）。函数版签名 `optional<color_t>(u64 address, const u8* data, size_t size, bool hasColor)`，返回 nullopt 表示不改。
- **缓存**：ViewHexEditor 持有 `PerProvider<std::map<u64, color_t>> m_foregroundHighlights, m_backgroundHighlights`（`plugins/builtin/include/content/views/view_hex_editor.hpp:120`），回调里先查 map（view_hex_editor.cpp:89-91、154），miss 才跑 provider 链，命中后写回（108-109、176-177）。
- **失效**：注册 `EventHighlightingChanged` 订阅清空缓存（view_hex_editor.cpp:704-711）。规则一变（ViewHighlightRules 里每次编辑表达式就 `EventHighlightingChanged::post()`，view_highlight_rules.cpp:225-228、312-314），缓存整体作废重算。
- **0x00 灰显**（gray-out-zeros）：行内全 0 且无前景色时给 `ImGuiCol_TextDisabled`（hex_editor.cpp:1002-1013）——一行代码的档次提升项。
- **查找结果高亮**：ViewFind 用函数版 provider + 区间树：`m_occurrenceTree->overlapping({start=address,end=address})` 命中则返回半透明高亮色（view_find.cpp:31-44）。区间树适合"命区间集大量重叠"的场景；我们关键词高亮如果只按行/列命中，行级 `map<u64,color_t>` 就够。

### 1.5 对本项目的结论

- **采纳**：drawList + PushClipRect 画背景块；每行预计算颜色向量；`map<offset,color>` 高亮缓存 + "规则变更事件 → 清缓存"；灰显 0x00；行号滚动模型（HEX 视图行高恒定，比接收区文本行更规整，手算区间比 clipper 更直接）。
- **采纳**（变体）：我们不搞 ViewHexEditor 的 provider 注册表——bridge 单文件直接在 `ImGuiRuntime` 里放 `std::unordered_map<u32, ImU32>`（字节偏移→色）由 Lua `set_hex_highlights()` 整表替换即可，替换时置 dirty 标志，语义等同 EventHighlightingChanged。
- **不采纳**：`PerProvider<>`（我们没有多 provider 概念）；Insert 模式编辑、折叠区域（CollapsedRegion，hex_editor.cpp:116-148 一大套）、minimap（452-547，ChannelsSplit 2 通道 + 每行 read + AddRectFilled）——都是文件编辑器特有负担；`ScrollbarEx` 自绘滚动条对我们过重，HEX 视图可以继续用 `BeginChild` 自带滚动 + 行号换算。

---

## 2. 内嵌文本编辑器（Lua Script Console 的参考）

### 2.1 是什么：完全自绘，不是 InputTextMultiline

ImHex 的编辑器在 `plugins/ui/include/ui/text_editor.hpp`（1112 行声明）+ `source/ui/text_editor/{editor,render,highlighter,navigate,code_folder,support,utf8}.cpp`（合计约 8000 行），源自 BalazsJako/ImGuiColorTextEdit 的大改版。**核心数据结构**（text_editor.hpp:441-446）：

```cpp
class Line {
    std::string m_chars;    // utf-8 文本
    std::string m_colors;   // 每字节一个 PaletteIndex（调色板下标）
    std::string m_flags;    // 每字节一个 flag 位（注释/预处理/...）
    bool m_colorized = false;   // 行级脏标记
};
```

三根平行字符串——着色结果与文本同长，渲染时按"同色 run"切段输出。这是它高效的关键：着色是**离线增量**的，渲染只是顺序扫描。

### 2.2 语法高亮：LanguageDefinition + tokenize 回调

`LanguageDefinition`（text_editor.hpp:525-551）：keywords 集合、identifiers map、`m_tokenize` 回调（逐 token 返回 PaletteIndex）、正则兜底列表、注释串。**现成的 Lua 定义**在 `plugins/ui/source/ui/text_editor/highlighter.cpp:985-1047`：keywords（and/break/do/.../while）、约 150 个内置标识符、注释 `--[[ ]]` / `--`（1035-1037 行）。

增量着色 `Lines::colorizeRange()`（highlighter.cpp:104-224）：只处理 `m_colorized == false` 的行，跑 tokenize 回调，keyword/identifier 命中改写 `m_colors`（149-161 行的核心分支），完毕置 `line.m_colorized = true`。**行级脏标记 = 编辑只重着色改动行**。

### 2.3 渲染：手算可见行 + 横向裁剪

`TextEditor::render()`（render.cpp:300-380）：`BeginChild("##lineNumbers")` 占位（315-325）+ `BeginChild(title)` 正文（342 行）+ `ImGui::Scrollbar(ImGuiAxis_Y/X)` 手动补滚动条（361-370）。

`renderText()`（render.cpp:1159-1279）：`while (std::floor(row) <= std::floor(maxDisplayedRow))` 行循环（1210 行），行内 `drawColoredText()`（1281-1338）做**横向裁剪**：由 `scrollX / charAdvance.x` 换算出头/尾列（1296-1323），只输出可见列；同色 run 用 `colors.find_first_not_of(color, i)` 切段（1329 行）。

行号背景与分隔线（`Line::print`，render.cpp:42-56）：drawList 画 MenuBarBg 色矩形 + Border 色竖线，再输出行号文本。

### 2.4 控制台日志 = 只读 TextEditor + 专用"语言定义"

这是最巧的模式（`view_pattern_editor.cpp:333-368`）：定义 `ConsoleLog` 语言，其 tokenize 回调**只看行首前缀**：

```cpp
langDef.m_tokenize = [](begin, end, outBegin, outEnd, paletteIndex) {
    std::string_view inView(inBegin, inEnd);
    if (inView.starts_with("D: "))  paletteIndex = PaletteIndex::DefaultText;
    else if (inView.starts_with("W: ")) paletteIndex = PaletteIndex::WarningText;
    else if (inView.starts_with("E: ")) paletteIndex = PaletteIndex::ErrorText;
    ...
};
```

日志等级着色被降维成"每行一个 token 的语法高亮"，行号/选择/查找全部白拿。

日志增量更新 `drawConsole()`（view_pattern_editor.cpp:1143-1157）：比较 `m_console->size()` 与已渲染行数，只 `appendLine` 差量，不清空重建（编辑器内部 dirty 标记只重着色新行）。

### 2.5 对本项目的结论

- **不采纳**：整体移植 TextEditor（约 8000 行 + 依赖 pattern language 的 Token 类型，text_editor.hpp:211-213）。我们脚本编辑器是"多行可编辑文本框 + 语法着色"，不需要代码折叠/断点/delimiter 匹配（text_editor.hpp:273-306 的 CodeFold 全家桶）。
- **采纳（数据结构思想）**：平行字符串 `chars/colors` + 行级 dirty + 增量着色。如果我们后续做"接收区着色"，把每行缓存一份 `std::string color_runs`（或 `vector<(col,len,color)>`）远比每帧重扫正则便宜。
- **采纳**：Lua 关键字/内置名清单可直接抄 highlighter.cpp:989-1016（LuaJIT 5.1 语法子集，含 bit 库名——注意其中混入了 Lua 5.2/5.3 的 `goto` 没有、`bit32` 有，需删补）。
- **采纳**：日志等级前缀 → 行首着色的降维思路。XCOM 的 Script Console 日志区可以直接用 `[E]/[W]/[I]` 前缀 + 行首判断，不需要任何 tokenizer。
- **务实替代**：编辑器本体用 `InputTextMultiline`（bridge 现有能力），着色用 **叠加绘制法**：InputTextMultiline 设透明文字色画在底层负责输入，同位置 draw list 按色段重画文字在顶层——即 `TextFormattedSelectable`（§4.3）思路的编辑版。若这个 hack 不稳，退而求其次：行号列 + 无着色的等宽编辑器，ImHex 式着色列为二期。

---

## 3. 多窗口 / 浮窗管理

### 3.1 窗口类层次与 draw() 模板方法

`View::Window::draw()`（`lib/libimhex/source/ui/view.cpp:189-205`）是模板方法模式：

```cpp
void View::Window::draw(ImGuiWindowFlags extraFlags) {
    if (this->shouldDraw()) {
        const auto title = fmt::format("{} {}", this->getIcon(), View::toWindowName(this->getUnlocalizedName()));
        handleFocusRestoration();
        if (!allowScroll()) extraFlags |= ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse;
        ImGui::SetNextWindowSizeConstraints(this->getMinSize(), this->getMaxSize());
        if (ImGui::Begin(title.c_str(), &this->getWindowOpenState(), ImGuiWindowFlags_NoCollapse | extraFlags | this->getWindowFlags())) {
            this->drawContent();      // 子类只填这个
        }
        ImGui::End();
    }
}
```

浮窗 = 一行（view.cpp:216-218）：`View::Floating::draw(extraFlags) { Window::draw(extraFlags | ImGuiWindowFlags_NoDocking); }`。

**窗口命名**（view.cpp:103-105）：`toWindowName = fmt::format("{}###{}", Lang(unlocalizedName), unlocalizedName.get())` —— 本地化标题 + `###` 稳定 ID，改名/换语言不丢窗口状态。**Script Console 浮窗应照此命名**，如 `"Lua Console###xcom.script_console"`。

**开闭边沿检测** `trackViewState()`（view.cpp:79-89）：`m_prevWindowOpen != m_windowOpen` 时触发 `onOpen()/onClose()` + justOpened 标志（供 focus/dock 逻辑用，view.hpp:104-108）。

### 3.2 注册与主循环

- 注册：`ContentRegistry::Views::add<ViewHexEditor>()`（`lib/.../content_registry/views.hpp:33-36`，模板 + `std::map<name, unique_ptr<View>>`），集中在 `plugins/builtin/source/content/views.cpp:27-46` 一次性 add 20 个。
- 每帧：`Window::frame()`（`main/gui/source/window/window.cpp:743-845`）逆序遍历（753 行 `| std::views::reverse`），对每个 view 依次 `drawAlwaysVisibleContent()`（不依赖窗口开）→ `trackViewState()` → `shouldProcess()` 过滤 → `view->draw()`。
- **日志窗是浮窗**：`ViewLogs::ViewLogs() : View::Floating("hex.builtin.view.logs.name"...)`（view_logs.cpp:10）。

### 3.3 布局持久化

- ImGui ini 之外，`LayoutManager`（`lib/.../include/hex/api/layout_manager.hpp:13-100`）把 dock 布局存成 ini 风格文本，提供 `registerLoadCallback/registerStoreCallback` 让任意组件往布局文件里塞自定义行——window.cpp:115-124 就是解析 `MainWindowSize=%d,%d` 回调 glfwSetWindowSize。
- 处理时机：`Window::frameEnd()` 末尾、**下一帧开始前**（window.cpp:930-933 注释明言 "needs to be done before a new frame is started, otherwise ImGui won't handle docking correctly"）。

### 3.4 对本项目的结论

- **采纳**：`###` 稳定 ID 命名（浮窗换标题不丢位置）；`SetNextWindowSizeConstraints(min,max)` + `Begin(...,&open,NoCollapse)` 的浮窗骨架；"always-visible 内容"（如浮窗未开时仍要处理的全局快捷键/REPL 输入队列）与窗口本体分离的概念——对应我们 bridge 的 action 分发不必在浮窗 draw 内做。
- **不采纳**：View 继承树与 ContentRegistry（我们是单文件 bridge + Lua 驱动，一个 `bool console_open` 成员即可）；`handleFocusRestoration()`（view.cpp:121-186，深挖 `g.WindowsFocusOrder`/`NavLastChildNavWindow` 的内部结构，ImGui 升级即碎，ImHex 自己为此打了多个补丁）；DockBuilderDockWindow 自动停靠（window.cpp:816-822）；LayoutManager 的整套布局文件。

---

## 4. 日志控制台与 REPL

### 4.1 ViewLogs：等级过滤 + 逐行着色（77 行实现）

`plugins/builtin/source/content/views/view_logs.cpp` 全文仅 77 行：

- 等级过滤：`ImGui::Combo("log_level", &m_logLevel, "DEBUG\0INFO\0WARNING\0ERROR\0FATAL\0")`（46 行）+ `shouldDisplay()` 前缀比较（30-43 行）。
- 逐行着色：`getColor(level)` 返回自定义调色板色（16-28 行），`ImGui::PushStyleColor(ImGuiCol_Text, ...)` + `TextUnformatted`（65-67 行）。
- 布局：`BeginTable(2 cols, Borders|RowBg|ScrollY)` + `TableSetupScrollFreeze(0,1)` 冻结表头（48-53 行），`logs | std::views::reverse` 最新在上（56 行）。
- 缺点（我们的教训）：**没有 clipper**，日志几千行会卡；TTY 控制台（下节）用了 clipper，照那个写。

### 4.2 TTY 串口控制台：与本项目同域的完整样板

`plugins/windows/source/views/view_tty_console.cpp`（Win32 串口）：

- **接收线程 + 互斥锁**：`std::jthread` 收字节（382-409 行），`addByte` lambda 加 `m_receiveBufferMutex`（390 行）：可打印字符追加、`\n` 开新行、`\r` 忽略、**不可打印显示 `<XX>`**（394-402 行）——正是我们 HEX/ASCII 混排的参考。
- **渲染用 ListClipper**（246-255 行）：
  ```cpp
  ImGuiListClipper clipper;
  clipper.Begin(m_receiveLines.size(), ImGui::GetTextLineHeight());
  while (clipper.Step()) {
      std::scoped_lock lock(m_receiveBufferMutex);
      for (int i = clipper.DisplayStart + 1; i < clipper.DisplayEnd; i++)
          ImGui::TextUnformatted(m_receiveLines[i].c_str());
      if (m_shouldAutoScroll && ImGui::GetScrollY() >= ImGui::GetScrollMaxY())
          ImGui::SetScrollHereY(0.0F);
  }
  ```
- **REPL 输入行**（280-292 行）：`ImGui::InputText("##transmit", buf, ImGuiInputTextFlags_EnterReturnsTrue)` 回车即发，随后 `buf.clear()` + `ImGui::SetKeyboardFocusHere(0)` 保持焦点；旁边按钮发送时用 `SetKeyboardFocusHere(-1)`（291 行）。工具行：清空按钮 + autoscroll 图标开关（265-275 行）。
- 波特率/数据位/停止位/校验全是 `BeginCombo` + `Selectable` 循环（73-108 行）。

### 4.3 可选中文本小技巧（接收区/日志区均可直接抄）

`ImGuiExt::TextFormattedSelectable`（`lib/libimhex/include/hex/ui/imgui_imhex_extensions.h:214-231`）：把只读文本画成**无边框无背景的 InputText**，天然获得选择/复制：

```cpp
ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2());
ImGui::PushStyleVar(ImGuiStyleVar_FrameBorderSize, 0.0F);
ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4());
ImGui::PushItemWidth(ImGui::CalcTextSize(text).x + FramePadding.x * 2);
ImGui::InputText("##", buf, len+1, ImGuiInputTextFlags_ReadOnly | ImGuiInputTextFlags_NoHorizontalScroll);
```

多行版 `TextFormattedWrappedSelectable`（260-291 行）：先按 `CalcTextSize("M").x` 手动折行再走 InputTextMultiline 同款技巧。ImHex 的地址列、页脚统计都用它（hex_editor.cpp:981、1579）。

### 4.4 Command Palette（浮层输入 + 结果列表）

`view_command_palette.cpp:15-100`：`View::Special`（不建窗口）+ `drawAlwaysVisibleContent()` 里 `BeginPopup`；输入框 `InputText` 变更时才重算结果（70-72 行），`SetItemDefaultFocus`（78 行）、`GetInputTextState(...)->Stb` 直改光标（81-89 行，imgui_internal 侵入式，**不建议学**）。对我们价值有限，REPL 用 TTY 模式即可。

### 4.5 对本项目的结论

- **采纳**：TTY 控制台整套结构（收线程→行缓冲→clipper 渲染→autoscroll→EnterReturnsTrue REPL 输入框）几乎可以逐条映射到 Lua Script Console 的日志区 + 输入区；`<XX>` 不可打印字节显示法直接用于 HEX 视图 ASCII 列。
- **采纳**：`TextFormattedSelectable` 单行版——接收区/日志区的"可复制数值"（如状态栏统计、HEX 选中区间显示）低成本专业化。
- **采纳**：等级前缀着色（ViewLogs getColor + Combo 过滤）用于脚本控制台日志过滤；但循环要套 ListClipper（ViewLogs 没套是它的坑）。
- **不采纳**：直改 STB 光标状态（81-89 行）；`log::impl::getLogEntries()` 全局日志环（我们 Lua 侧 print 重定向自己有）。

---

## 5. 绘图 / 波形（ImPlot 示波器参考）

ImPlot context 在主程序创建（window.cpp:1323-1324）。三个层次的用法：

### 5.1 最简：line_plot 可视化器（`plugins/visualizers/source/content/pl_visualizers/line_plot.cpp:12-28`）

```cpp
if (ImPlot::BeginPlot("##plot", ImVec2(400, 250), ImPlotFlags_CanvasOnly)) {
    ImPlot::SetupAxes("X", "Y", ImPlotAxisFlags_AutoFit, ImPlotAxisFlags_AutoFit);
    ImPlot::PlotLine("##line", values.data(), values.size());
    ImPlot::EndPlot();
}
```

### 5.2 数字信号时序图（digital_signal.cpp:60-96）——最接近示波器需求

- 轴锁定：`SetupAxisLimitsConstraints(X, 0, lastPoint.x)`（61 行）、Y 轴 `-0.1~1.1` 锁死 + `SetupAxisFormat(Y,"")` 隐藏刻度（63-65 行）。
- **getter 回调绘制**（90-92 行）：`ImPlot::PlotLineG(name, [](int idx, void*){ return dataPoints[idx/2].points[idx%2]; }, nullptr, count*2)`——数据不复制、不要求连续数组，适合我们的环形缓冲多通道波形。
- 波形下着色 + 标注：`ImPlot::PlotToPixels()` 换算坐标后 `ImPlot::PushPlotClipRect(); ImPlot::GetPlotDrawList()->AddRectFilled(...)`（77-86 行），文字用 `ImPlot::Annotation(x, y, color, {}, false, "%s", label)`（73-74 行）。**游标/区域标注就用 PlotToPixels + GetPlotDrawList 这条路**，不必等 ImPlot 内建 drag 工具。
- `PushStyleVar(ImPlotStyleVar_LineWeight, 2_scaled)` 控制线宽（89 行）。

### 5.3 串口信号示意图（view_tty_console.cpp:137-230）

`ImPlotFlags_NoFrame | ImPlotFlags_CanvasOnly` 嵌入表格单元格（137-139 行）；`PlotStairs` 画阶跃信号（214 行）；分隔线用两点 `PlotLine`（223-225 行）+ `Annotation` 上下交错标注（220 行）。

### 5.4 对本项目的结论

- **采纳**：`PlotLineG` getter 回调喂环形缓冲（示波器多通道回看的核心：无需每次渲染拷贝/翻转数组）；`PlotToPixels + GetPlotDrawList + PushPlotClipRect` 画游标线/选中区/通道标签；`SetupAxisLimitsConstraints` 限制回看范围；`CanvasOnly + NoFrame` 嵌入既有布局。
- **采纳（帧驱动注意）**：ImHex 所有波形数据在数据侧生成、绘图侧纯查询（digital_signal.cpp:28-58 的 shouldReset 重建 dataPoints）。对应我们：波形点由 Lua 串口回调追加进 bridge 侧环形缓冲，`draw` 只读——与 `docs/imgui-patterns-reference.md` §0 的"示波器数据由 Lua/串口侧驱动追加，bridge 只负责画"结论一致。
- **不采纳**：ImHex 的 `shouldReset` + static vector 模式（line_plot.cpp:13 的 `static std::vector<float> values` 是 demo 级写法，多实例即错）；后处理 shader（window.cpp:951+，OpenGL 专属，我们是 DX11）。

---

## 6. 字体 / 国际化 / CJK

### 6.1 字体角色制（named font roles）

- 注册三个角色：`ImHexApi::Fonts::Font("hex.fonts.font.default"/"hex_editor"/"code_editor")`（`plugins/fonts/source/fonts.cpp:8-25`）。
- **按区域切换字体**：`fonts::HexEditor().push(0.5); ...字体内容...; fonts::HexEditor().pop();`——hex_editor.cpp:860-862（折叠按钮用 0.5 倍小字号）、1674-1676（整个编辑器网格）；view_pattern_editor.cpp:526/547（CodeEditor 字体包住编辑器）。`Font::push(size)` 最终就是 `ImGui::PushFont(font, size)`（`lib/.../source/api/imhex_api.cpp:1190-1211`，size<=0 时取 LegacySize×GlobalScale 并 PixelSnapH 时取整）。
- 字体加载：FreeType loader + `OversampleH=3, OversampleV=2`（`plugins/fonts/source/font_loader.cpp:24-29`）。

### 6.2 CJK：merge Unifont，不指定 GlyphRanges

`font_loader.cpp:96-105`：主字体加载后，`config.MergeMode = true` 逐个 merge 附加字体（含 `unifont.otf`，`fonts.cpp:31`，offset (0,0)、字号倍率 0.75）。**没有调用任何 GetGlyphRangesChinese***——ImGui 1.93 已把 GlyphRanges 系列标记 obsolete（`lib/third_party/imgui/imgui/source/imgui.cpp:526`），FreeType 动态字形加载让 merge 全量字体成为可行做法。图标字体（Codicons/Tabler，字号倍率 0.95/1.10、GlyphOffset 微调 y=-2.5/-1.5，fonts.cpp:28-30）与 CJK 同机制。

### 6.3 i18n：编译期哈希 + JSON

- `operator""_lang` consteval 编译期哈希键（`lib/.../include/hex/api/localization_manager.hpp:160-163`），运行期 `Lang::get()` 查当前语言表；未命中回退 en_US（`localization_manager.cpp:63-77` 的 findBestLanguageMatch）。
- 语言文件为扁平 JSON：`plugins/builtin/romfs/lang/zh_CN.json`（"hex.builtin.xxx": "中文"），languages.json 列出全部语言与 fallback 链。
- 窗口标题本地化靠 `###` 双段命名（§3.1）不丢 ID。

### 6.4 对本项目的结论

- **采纳**：字体角色制——bridge 里接收区/HEX 视图/编辑器三处对等宽字形要求不同，可在 `ImGuiRuntime` 存 2~3 个 `ImFont*`，draw 时 PushFont/PopFont 包裹区域（成本是两行，收益是 UI 档次）。
- **采纳**：图标字体 merge 进默认字体（Tabler/Codicons 式，一次 merge 全窗口可用图标按钮 `DimmedIconButton`，`imgui_imhex_extensions.h:322`）——比到处贴纹理便宜得多。
- **参考**：CJK 用"merge 一款覆盖广的中文字体 + ImGui 1.93 动态字形"，**不要**再用 `GetGlyphRangesChineseSimplifiedCommon()`（已废弃）；若我们沿用 stb 光栅化（非 FreeType）则仍需 GlyphRangesBuilder 显式范围，两条路都通，取决于 bridge 现状。
- **不采纳**：`_lang` consteval 哈希 i18n 框架（Lua 侧天然有表驱动字符串，C++ 层再做一套纯增熵）；zh_CN JSON 翻译工作流。

---

## 7. 其他顺带发现（与四个功能间接相关）

- **帧内容比对跳过渲染**（window.cpp:860-905）：`frameEnd` 里逐 viewport 比较 `VtxBuffer` 字节（先比总长再 memcmp，注释明言"直接 memcmp 比 hash 快约 60 倍"），无变化则跳过 `RenderDrawData + SwapBuffers`。对 XCOM 的启发：**idle 500ms 档下，如果 draw data 未变，Lua 侧可以直接不调用 `render()`**——比 ImHex 在 C++ 里 memcmp 更简单，帧调度层（window.lua:1073-1075 三档帧间隔）已具备判断条件。
- **空闲帧率**（window.cpp:233-378）：IdleFPS=5、`glfwWaitEventsTimeout` 事件驱动唤醒、鼠标按下/修饰键按下即解锁全速（308-331 行）。我们的 active/data/idle 三档同思想，无需改动。
- **崩溃看门狗**（window.cpp:196-231）：逐帧 try/catch，连抛 10 次异常 abort，否则 `ImGui::EndFrame()` 强制复位。bridge 的 draw 是 Lua 调进来的 C++，包一层同款防御性 EndFrame 可防 ImGui 断言卡死进程。
- **TaskManager::doLater / doLaterOnce**（高亮 API 全靠它投递失效事件，imhex_api.cpp:135 等）：跨线程操作一律排队到主帧执行。对应我们：串口线程只写缓冲置 dirty，draw 帧消费——已是既定架构，ImHex 佐证了这是正解。
- **BeginSubWindow**（`imgui_imhex_extensions.cpp:1451-1491`）：child window + 菜单栏标题 + TreeNode 折叠按钮，约 40 行实现"带标题可折叠面板"，Script Console 的"列表/编辑器/日志"三段面板可用。

---

## 8. 采纳清单

### 建议采纳（按投入产出排序）

| # | 模式 | ImHex 出处 | 用到哪 |
|---|---|---|---|
| 1 | drawList `AddRectFilled` + `PushClipRect` 画背景色块；`PushStyleColor(Text)` 画前景 | hex_editor.cpp:720-727, 1087-1091 | 接收区关键词高亮（背景块 + 彩色文字） |
| 2 | 每行预计算颜色向量，绘制期只查表 | hex_editor.cpp:934-935, 992-1026 | 接收区/HEX 高亮热路径 |
| 3 | 高亮缓存 map + 规则变更即整体失效 | view_hex_editor.cpp:704-711 + view_highlight_rules.cpp:225 | Lua 改关键词规则 → bridge 清缓存重算 |
| 4 | TTY 控制台全套：收线程→行缓冲→ListClipper→autoscroll→`EnterReturnsTrue` 输入框保持焦点 | view_tty_console.cpp:246-292, 382-409 | Lua Script Console 浮窗（日志区+REPL） |
| 5 | 等级前缀 → 行着色 + Combo 等级过滤 | view_pattern_editor.cpp:333-368, view_logs.cpp:16-46 | 控制台日志 ERROR/WARNING/INFO 着色与过滤 |
| 6 | `PlotLineG` getter 回调 + `PlotToPixels`/`GetPlotDrawList`/`Annotation` 画游标标注 | digital_signal.cpp:60-96 | ImPlot 示波器多通道 + 回看游标 |
| 7 | 不可打印字节显示 `<XX>` | view_tty_console.cpp:394-402 | HEX 视图 ASCII 列 |
| 8 | `###` 稳定 ID 命名 + `SetNextWindowSizeConstraints` 浮窗骨架 | view.cpp:103-105, 189-205 | 所有新浮窗 |
| 9 | `TextFormattedSelectable`（只读 InputText 伪装可复制文本） | imgui_imhex_extensions.h:214-231 | 状态栏统计、选中区间显示等只读数值 |
| 10 | 灰显 0x00 / TextDisabled | hex_editor.cpp:1002-1013 | HEX 视图 |
| 11 | 行号滚动模型（固定行高手算可见区间 +5 行冗余） | hex_editor.cpp:930-938 | HEX 视图（等宽网格，比 clipper 更直接） |
| 12 | 字体角色 PushFont/PopFont 包区域 + 图标字体 merge | fonts.cpp:21-32, font_loader.cpp:96-105, imhex_api.cpp:1190-1216 | 接收区/HEX/编辑器分字体，工具栏图标 |
| 13 | Lua 关键字/内置名清单 | highlighter.cpp:985-1047 | 脚本编辑器语法高亮（删 5.3 专属项） |
| 14 | 平行字符串 chars/colors + 行级 dirty 增量着色 | text_editor.hpp:441-446, highlighter.cpp:104-224 | 接收区着色缓存（若做编辑器着色则叠加绘制法） |
| 15 | `BeginSubWindow` 折叠面板 | imgui_imhex_extensions.cpp:1451-1491 | 控制台三段面板 |
| 16 | 崩溃防御：draw 包 try/catch + 强制 EndFrame | window.cpp:196-231 | bridge draw 导出函数 |
| 17 | draw data 未变不渲染（Lua 帧调度层判断） | window.cpp:860-905（思想） | idle 档节能（可选） |

### 明确不采纳

| 模式 | 出处 | 不采纳理由 |
|---|---|---|
| View 继承树 + ContentRegistry::Views 注册表 | view.hpp, views.hpp, views.cpp:27-46 | 单文件 bridge 无多窗口插件需求，`bool open` 成员足够 |
| EventManager 模板事件总线 | event_manager.hpp:16-216 | Lua 天然是事件驱动的宿主，C++ 层加总线纯增熵；一个 dirty 标志即等价 |
| handleFocusRestoration 深挖 ImGui 内部 | view.cpp:121-186 | 依赖 `WindowsFocusOrder`/`NavLastChildNavWindow` 私有结构，ImGui 升级即碎 |
| DockBuilderDockWindow / LayoutManager 布局文件 | window.cpp:816-822, layout_manager.hpp | 无 dockspace；浮窗位置交给 imgui.ini 即可 |
| TextEditor 整体移植（约 8000 行） | plugins/ui/source/ui/text_editor/* | 代码折叠/断点/delimiter 匹配/查找替换远超需求；InputTextMultiline + 叠加着色可达 80% 效果 |
| HexEditor 的 Insert 模式 / 折叠区域 / Minimap / ScrollbarEx 自绘 | hex_editor.cpp:116-547 | 文件编辑器特有；我们 HEX 视图是只读展示 |
| math_eval 高亮规则表达式引擎 | view_highlight_rules.cpp:80-107 | 我们的关键词高亮用 Lua 匹配（find/正则），不需要 C++ 表达式求值器 |
| Provider 抽象 / PerProvider<T> | lib/.../providers/, view_hex_editor.hpp:120 | 无多数据源概念 |
| `operator""_lang` 编译期哈希 i18n | localization_manager.hpp:160-173 | Lua 侧表驱动字符串即可 |
| 直改 STB 光标状态 | view_command_palette.cpp:81-89 | imgui_internal 侵入式 hack |
| 多通道 drawlist ChannelsSplit minimap | hex_editor.cpp:481-546 | 无 minimap 需求 |
| 后处理 shader 渲染 | window.cpp:951+ | OpenGL 专属，我们是 DX11 |
