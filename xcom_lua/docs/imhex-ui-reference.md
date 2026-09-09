# ImHex UI 设计参考（面向 xcom_imgui_bridge.cpp 的浅色主题重设计）

> 版本基线：ImHex **1.39.0.WIP**（commit `feb826c14b`，2026-09-04），基于 Dear ImGui **1.92.7 WIP**（docking 分支，含 FreeType 集成）。
> 本地源码：`D:\workspace\SSCOM_lua\ref\ImHex\`（完整 clone，约 95 MB）。ImHex 是 C++20 + GLFW + OpenGL3 的 ImGui 重度定制项目，所有 UI 品质来自两件事：**JSON 主题系统** + **一个 1685 行的 ImGui 扩展控件库**（`imgui_imhex_extensions.cpp`）。
> 对应文件：本项目 `D:\workspace\SSCOM_lua\xcom_lua\native\xcom_imgui\xcom_imgui_bridge.cpp`（约 1790 行，DX11 + Win32，C++17）。
> 下文所有 ImHex 行号以本地 clone 为准（2026-09-04 用 Read/Grep 逐条核实）。

---

## 1. ImHex UI 概览（布局结构）

### 1.1 窗口骨架（自绘标题栏 + 菜单栏 + Dock 空间 + 侧边栏 + 底部状态栏）

ImHex 的主窗口**不是**一个普通 ImGui 窗口，而是多层结构（`main/gui/source/window/window.cpp:380-741`，`frameBegin()`）：

```
┌──────────────────────────────────────────────────────────────┐
│ 自绘标题栏: Logo + 菜单栏(File/Edit/View...) + 居中搜索框    │  ← window_decoration.cpp drawTitleBar/drawMenu
│           + 右侧 min/max/close 自绘按钮                       │
├────┬─────────────────────────────────────────────────────────┤
│侧  │  Dock 空间（ImGui::DockSpace, ID="ImHexMainDock"）      │
│边  │  ┌───────────────────────┬───────────────────────┐      │
│栏  │  │ Hex Editor 视图       │ Data Inspector        │      │
│(垂 │  │ （十六进制+ASCII 网格）│  + Bookmarks 等       │      │
│直  │  ├───────────────────────┴───────────────────────┤      │
│图  │  │ Pattern Data（结构树表格）                      │      │
│标  │  ├───────────────────────────────────────────────┤      │
│条) │  │ Pattern Editor（代码编辑器）/ 其他             │      │
│    │  └───────────────────────────────────────────────┘      │
├────┴─────────────────────────────────────────────────────────┤
│ 底部状态栏: 各 View 注册的 footer item + 竖直分隔线          │  ← drawFooter (window_decoration.cpp:150)
└──────────────────────────────────────────────────────────────┘
```

关键实现点：

- **DockHost 是一个隐藏的宿主窗口**（window.cpp:422-445）：`ImGui::Begin("ImHexDockSpace")` 时 Push `WindowRounding=0 / WindowBorderSize=0 / WindowPadding=0`，铺满 viewport 的 WorkPos，flags = `NoDocking | NoTitleBar | NoCollapse | NoMove | NoResize | NoBringToFrontOnFocus | NoScrollbar | NoScrollWithMouse` + `MenuBar`。每个"View"（面板）是一个普通 ImGui 窗口，由 ImGui 的 DockBuilder 布局系统吸附进这个 dock 空间。
- **默认布局**用 `.hexlyt` 文件持久化（`plugins/builtin/romfs/layouts/default.hexlyt`），就是 ImGui 的 `ImGui::SaveIniSettingsToMemory` 格式加一段 `[Docking][Data]`。2560x1513 参考分辨率下：左侧 847px（上下切：Hex Editor 1140/701 + Inspector 553/701 上下占 80%，Pattern Data 底部 20%），右侧 431px（Pattern Editor + Tools/Hashes 标签组）。
- **侧边栏**（window_decoration.cpp:179-269 `drawSidebar`）：图标按钮列，每项 `FrameRounding=3_scaled`，选中态用 `ImGuiCol_ScrollbarGrab` 做按钮底色、`MenuBarBg` 做常态；点击弹出浮动面板（`Begin("SideBarWindow")`，`WindowBorderSize=1` + 关闭 WindowShadow）。
- **单视图时自动隐藏标签栏**（window.cpp:770-775）：`openViewCount <= 1` 时给 `ImGuiWindowClass.DockNodeFlagsOverrideSet |= ImGuiDockNodeFlags_NoTabBar`——只有一个小面板时不显示 tab 头，视觉更干净。
- **布局可锁定**（`LayoutManager::isLayoutLocked()` 同样进 NoTabBar 分支）。

### 1.2 View 基类（每个面板的统一骨架）

`lib/libimhex/source/ui/view.cpp:189-241`。四种 View 形态：

| 形态 | 绘制方式 | 用途 |
|---|---|---|
| `View::Window`（默认） | `ImGui::Begin(title, &open, NoCollapse)` 进 dock | Hex Editor、Inspector 等主面板 |
| `View::Floating` | `Window::draw(flags | NoDocking)` | 主题管理器等独立小窗 |
| `View::Modal` | `BeginPopupModal` + Esc 关闭 | 各种弹窗 |
| `View::FullScreen` | 直接 `drawContent()`，不建窗口 | 全屏模式 |

标题格式：`fmt::format("{} {}", icon, View::toWindowName(...))` —— **图标字形放在标题最前面**（view.cpp:191），tab 上先看到图标再看到文字。每个 View 有 `getMinSize()`（默认 `scaled({300, 400})`，view.cpp:33-35）。

---

## 2. 可量化的设计参数（浅色主题真实值）

### 2.1 颜色体系（`plugins/builtin/romfs/themes/light.json`，核心子集）

ImHex 的浅色主题以**强调色（accent）驱动**：`"accent": "#4296F9FF"`，JSON 里所有以 `*` 前缀的颜色（如 `"button": "*#4296F966"`）都会在用户换强调色时做 HSV 重映射（theme_manager.cpp:38-57 `applyAccentColor`）。

**表面/结构色（灰阶体系）：**

| 语义 | hex（RRGGBBAA） | 说明 |
|---|---|---|
| `window-background` | `#EFEFEFFF` | 窗口/dock 底色（浅灰） |
| `docking-empty-background` | `#EFEFEFFF` | 无 dock 面板时的底 |
| `menu-bar-background` | `#DBDBDBFF` | 菜单栏（比窗口底深一档） |
| `title-background` / `-active` | `#DBDBDBFF` | 标题栏（同菜单栏） |
| `popup-background` | `#FFFFFFFF` | 弹窗纯白 |
| `frame-background` | `#FFFFFFFF` | 输入框/下拉框底，纯白 |
| `frame-background-hovered` | `*#4296F966` | 输入框 hover，强调色 40% |
| `frame-background-active` | `*#4296F9AA` | 输入框激活，强调色 67% |
| `table-header-background` | `#C6DDF9FF` | 表头，强调色 8% 混白 |
| `table-row-background-alt` | `#4C4C4C16` | 隔行底纹（8.5% 黑） |
| `border` | `#0000004C` | 通用边框（30% 黑，不是灰！） |
| `separator` | `*#6363639E` | 分隔线（62% 灰，62% alpha） |
| `scrollbar-background` | `#F9F9F987` | 滚动条槽 |
| `scrollbar-grab` | `#AFAFAFCC` | 滚动条滑块 |
| `scrollbar-grab-hovered` | `#7C7C7CCC` | hover 加深 |
| `scrollbar-grab-active` | `#7C7C7CFF` | 拖动时最深 |

**文字色：**

| 语义 | hex | 对 `#EFEFEF` 底对比度 |
|---|---|---|
| `text` | `#000000FF` | 19.7:1 |
| `text-disabled` | `#999999FF` | 2.8:1（仅禁用态） |
| `text-selected-background` | `*#4296F959` | 选区，强调色 35% |
| `input-text-cursor` | `#000000FF` | 纯黑光标 |

**标签页（tab）四态**（浅色主题的 tab 是"淡蓝→亮蓝"渐进）：

| 语义 | hex |
|---|---|
| `tab`（未选中） | `*#C2CBD5ED` |
| `tab-unfocused`（未聚焦窗口的未选中） | `*#EAECEEFB` |
| `tab-active`（选中） | `*#97B9E1FF` |
| `tab-unfocused-active` | `*#BDD1E9FF` |
| `tab-hovered` | `*#4296F9CC`（强调色 80%） |
| `tab-active-overline` | `*#4296F9FF`（选中 tab 顶部 1px 线） |

**ImHex 自定义语义色**（`imhex` 节，挂 `ImGuiExt::GetCustomColorU32()`）：

| 语义 | hex | 用途 |
|---|---|---|
| `toolbar-red` | `#E74C3CFF` | 危险/停止/错误（logger-error 同色） |
| `toolbar-green` | `#388B42FF` | 运行/成功（logger-debug 同色） |
| `toolbar-yellow` | `#F1C40FFF` | 警告（logger-warning 同色） |
| `toolbar-blue` | `#06539BFF` | 信息/选中（logger-info 同色） |
| `toolbar-purple` | `#672A78FF` | 致命错误（logger-fatal 同色） |
| `toolbar-brown` | `#DBB377FF` | 特殊 |
| `toolbar-gray` | `#191919FF` | 浅色主题下的中性图标 |
| `desc-button` / hover / active | `#E6E6E6` / `#D2D2D2` / `#BEBEBE` | 大按钮（欢迎页）三态 |
| `highlight` | `#299770FF` | 通用高亮 |
| `pattern-selected` | `#06539BFF` | Pattern 选中 |

注意：**日志五级色 == 工具栏五色**是同一组（debug=green, info=blue, warning=yellow, error=red, fatal=purple），ImHex 把语义色收敛成一套复用。

### 2.2 样式几何参数（styles 节，浅/深主题完全相同）

| 参数 | 值（px, @1x） | 对比本项目 bridge 现状 |
|---|---|---|
| `window-padding` | `[8, 8]` | bridge: `[0,0]`（紧凑布局） |
| `window-rounding` | `0.0` | bridge: `0`（一致） |
| `window-border-size` | `1.0` | bridge: `0` |
| `child-rounding` | `0.0` | bridge: `0` |
| `child-border-size` | `1.0` | bridge: `1` |
| `popup-rounding` | `0.0` | bridge: `6`（ImHex 反而更方） |
| `popup-border-size` | `1.0` | — |
| `frame-padding` | `[4, 3]` | bridge: `[8, 4]`（bridge 更宽松） |
| `frame-rounding` | `0.0` | bridge: `5` |
| `frame-border-size` | `0.0` | bridge: `1` |
| `item-spacing` | `[8, 4]` | bridge: `[7, 4]`（接近） |
| `item-inner-spacing` | `[4, 4]` | bridge: `[6, 4]` |
| `cell-padding` | `[4, 2]` | — |
| `indent-spacing` | `21.0` | — |
| `scrollbar-size` | `10.0` | bridge: `12` |
| `scrollbar-rounding` | `9.0` | 滚动条几乎全圆（bridge: `4`） |
| `grab-min-size` | `12.0` | — |
| `tab-rounding` | `5.0` | **tab 有 5px 圆角**（bridge: `0`） |
| `tab-bar-border-size` | `1.0` | tab 栏底部 1px 分隔 |
| `tab-bar-overline-size` | `1.0` | 选中 tab 顶部 1px 强调线 |
| `docking-separator-size` | `2.0` | dock 分隔条 2px |
| `separator-size` | `1.0` | — |
| `disabled-alpha` | `0.6` | — |
| `window-shadow-size` | `100.0` | 悬浮窗投影半径 100px（新版 ImGui 内建 shadow） |

**核心审美结论：ImHex 是"直角体系"** —— 窗口/子窗/输入框/弹窗的 rounding 全是 0，只有 tab（5px）、滚动条（9px 全圆）是圆的；配合 1px 边框 + `#0000004C` 半透明黑边框 + 表头淡蓝 + tab 顶部强调线构成"工程工具感"。它**不是**圆角卡片风格。局部圆角只出现在代码里手绘的元素：Toast（`5_scaled`，window.cpp:648）、侧边栏按钮（`3_scaled`，window_decoration.cpp:200）、SubWindow（`5.0F`，imgui_imhex_extensions.cpp:1455）、ToggleSwitch（`size.y/2` 全圆胶囊）。

### 2.3 字体方案

- **默认 UI 字体：JetBrains Mono**（`plugins/fonts/romfs/fonts/JetBrainsMono.ttf`），全部 UI 都用等宽字体（font_loader.cpp:83-84）。这是 ImHex "工程感"的重要来源。
- 三种注册字体角色（fonts.cpp:8-19）：`Default()`（UI）、`HexEditor()`（十六进制区）、`CodeEditor()`（代码编辑器），每种同时构建 regular/bold/italic 三个 ImFont 变体（FreeType 的 `ImGuiFreeTypeLoaderFlags_Bold/Oblique`，font_loader.cpp:108-112）。
- **FreeType 渲染**（font_loader.cpp:24-48）：`OversampleH=3, OversampleV=2`；抗锯齿可选 None（`Monochrome|MonoHinting` 像素完美模式，此时 `PixelSnapH=true, Oversample=1,1` 且字号取 13px 的整数倍缩放，font_loader.cpp:57-81）/ Grayscale / LCD 子像素。
- 字体三种"变体"通过 `fonts::Default().pushBold(0.8)` 这类调用按需切换（imhex_api.cpp:1178-1216，`push(size)` 负值=LegacySize×DPI，正值=相对 FontSizeBase 的倍数）。

### 2.4 DPI 缩放

所有几何量用字面量后缀 `_scaled`（`10_scaled`）或 `scaled(ImVec2(...))`（scaling.hpp/cpp:7-21，实现就是 `value * ImHexApi::System::getGlobalScale()`）。主题 JSON 里的 style 值在加载时按 `needsScaling` 标志统一乘 global scale（theme_manager.cpp:249-259）。**没有一处手写 `* dpi` 散落在绘制代码里。**

---

## 3. 自定义 ImGui 控件的技术手法（文件 + 函数名）

全部集中在 `lib/libimhex/source/ui/imgui_imhex_extensions.cpp`（1685 行）+ `include/hex/ui/imgui_imhex_extensions.h`，命名空间 `ImGuiExt`。每个控件的标准写法是复刻 ImGui 内部 Button 的结构：

```cpp
// imgui_imhex_extensions.cpp:887-928  IconButton 为例
ImGuiWindow *window = GetCurrentWindow();
if (window->SkipItems) return false;          // 1. 早退
const ImGuiID id = window->GetID(symbol);     // 2. 稳定 ID
ImVec2 size = CalcItemSize(...);              // 3. 布局
const ImRect bb(pos, pos + size);
ItemSize(size, style.FramePadding.y);         // 4. 注册布局
if (!ItemAdd(bb, id)) return false;
bool hovered, held;
bool pressed = ButtonBehavior(bb, id, &hovered, &held);  // 5. 交互（hover/press 全部语义免费拿到）
// 6. 手绘
RenderNavCursor(bb, id);
RenderFrame(bb.Min, bb.Max, col, true, style.FrameRounding);
RenderTextClipped(...);
IMGUI_TEST_ENGINE_ITEM_INFO(id, label, ...);  // 7. 测试引擎钩子
return pressed;
```

值得逐个抄的控件：

| 控件（ImGuiExt::） | 行号 | 手法要点 |
|---|---|---|
| `Hyperlink` / `IconHyperlink` | 336-403 | 文字按钮无框化：只 hover 时 `AddLine` 画下划线；用 `ImGuiCol_ButtonHovered/ButtonActive` 当文字色 |
| `DescriptionButton` | 438-495 | 欢迎页大按钮：图标用 `PushFont(GImGui->Font, FontSizeBase*1.25)` 临时放大 25%；label 用 ButtonActive 色、description 用 Text 色，两行排布 |
| `DescriptionButtonProgress` | 497-558 | 底部 5px 进度条叠加（`RenderFrame` 三层） |
| `HelpHover` | 560-582 | `(?)` 小按钮 + tooltip；把三种 Button 色全 Push 成透明实现"无边框按钮" |
| `InfoTooltip` | 643-686 | **tooltip 延迟 0.5s 出现**（`IsItemHovered(ImGuiHoveredFlags_DelayNormal)` + hover 目标未变判断）；宽度上限 300_scaled 自动换行 |
| `ToolBarButton` | 839-885 | 方形工具栏按钮：尺寸= `MenuBarHeight`；hover/active 用 **ScrollbarGrabHovered/Active** 色（语义复用） |
| `IconButton` | 887-928 | 通用图标按钮（见上面骨架代码） |
| `DimmedButton` / `DimmedIconButton` / `DimmedIconToggle` | 1314-1417 | "弱化按钮"族：Push `DescButton` 三态色 + **`FrameBorderSize=1.5_scaled` 边框**；toggle 选中态 Push `ImGuiCol_Border = ButtonActive` 让边框变强调色——**用边框颜色表示开关状态** |
| `ToggleSwitch` | 1535-1584 | iOS 风格拨动开关：`AddRectFilled(..., size.y/2)` 胶囊底 + `AddCircleFilled` 圆钮，on 时圆钮在右。**约 25 行即可自绘** |
| `BeginSubWindow` / `EndSubWindow` | 1451-1491 | 带标题栏可折叠的子面板：`BeginChild(ChildRounding=5)` + 内嵌 MenuBar + `TreeNodeEx(OpenOnArrow)` 当折叠箭头 |
| `BeginBox` / `EndBox` | 1434-1449 | 用 1 列 Table 的 `BordersOuter` 画分组框，`CellPadding=scaled(5,5)` |
| `InputTextIcon` / `InputTextIconHint` | 1203-1233 | **输入框左侧图标**：先 `InputTextEx` 占位（宽度减去 icon 宽），再在左端 `RenderFrame` 画小方块 + 图标字形 |
| `InputPrefix` / `InputHexadecimal` | 1039-1113 | 输入框内嵌前缀（"0x"）：手绘前缀背景，`InputText` Push 透明 FrameBg 叠上去 |
| `BeginWrappingTabBar` / `WrappingTabItem` | 943-1037 | **自动换行的标签栏**：手动 `TabItemCalcSize` + `TabItemBackground` 绘制，宽度不够换行；选中项画 overline |
| `BitCheckbox` | 1272-1312 | 单字符宽 checkbox（显示 "0"/"1"） |
| `ProgressBar` | 1139-1180 | 支持**负值 = 不定进度动画**（`RenderRectFilledInRangeH`） |
| `TextOverlay` | 1419-1432 | 面板中央提示文字：`AddDrawCmd` 抢绘制顺序 → `AddRectFilled(WindowBg|0xFF000000)` 不透明底 → `AddText` |
| `TextFormattedSelectable` | 头文件 214-231 | 只读可复制文本：把 `InputText(ReadOnly|NoHorizontalScroll)` 的边框/底色全部 Push 成透明 |
| `IsDarkBackground` | 1640-1651 | 感知亮度 `(r*299+g*587+b*114)/1000 < 128` 判断背景明暗，决定叠字用黑还是白——**任何"彩色底上写字"都该这么算** |
| `TextUnformattedCentered` | 1182-1201 | 居中换行文本：`CalcWordWrapPosition` 手动折行后 `ImPlot::AddTextCentered` |

### 3.1 Hex Editor 视图的绘制（`plugins/ui/source/ui/hex_editor.cpp`，1600+ 行）

接收区/数据网格的参考。核心 `drawEditor`（793 行起）：

- **整个十六进制区是一个 ImGui Table**：`PushStyleVar(CellPadding, ImVec2(0.5, 0))` 后 `BeginTable("##hex", byteColumnCount, SizingFixedFit|NoKeepColumnsVisible)`（836-838）。列宽全部 `WidthFixed` 精确到 `CharacterSize.x * maxChars + 6 + byteCellPadding`（875 行）——**等宽字体 + 固定列宽保证网格对齐**。
- 每行是 `TableNextRow`，每字节一格 `TableNextColumn`；单元格定位用 `getCellPosition()` = `GetCursorScreenPos() - GetStyle().CellPadding`（218-220）。
- **选区/高亮直接在 DrawList 画**，先于文字：`drawBackgroundHighlight`（720-727）`AddRectFilled(cellPos, cellPos+cellSize, color)`，外面套 `PushClipRect(window->Rect())` 防溢出。选区框 `drawFrame`（736-771）只在选区边缘画 4 条 1px 线（`AddLine`），不填中间。
- **光标闪烁**：`std::fmod(m_cursorBlinkTimer, 1.20F) <= 0.80F`（750 行）——1.2s 周期亮 0.8s。
- **minimap 滚动条**（481-547）：`drawList->ChannelsSplit(2)` 双通道，通道 1 放真正的 `ImGui::ScrollbarEx`（内部 API！），通道 0 按每行字节内容画彩色带。
- **编辑态**：双击进入，在单元格内原地渲染一个 `InputText`（`drawCell` 551-695），输满自动跳到下一格。
- **零值置灰**：`m_grayOutZero` 开启时全 0 单元格用 `ImGuiCol_TextDisabled` 渲染（1002-1013）——数据区可读性的廉价大招。
- 悬停检测不用 ImGui item：`ImGui::IsMouseHoveringRect(cellStartPos, cellStartPos+cellSize) && IsWindowHovered()`（1082 行）。

### 3.2 Pattern Data viewer（`plugins/ui/source/ui/pattern_drawer.cpp`，1566 行）

结构树表格的标准答案：

- `BeginTable("##Patterntable", 9, Borders|Resizable|Sortable|Hideable|Reorderable|RowBg|ScrollY)`（1197 行）+ `TableSetupScrollFreeze(0,1)` 表头冻结。
- 9 列各有 `ImGui::GetID("name")` 的**列 UserID**，排序回调按 UserID 分发（1172-1194）。
- 树节点用 `TreeNodeEx(DrawLinesToNodes | SpanLabelWidth | OpenOnArrow)`（535-541 行），叶子节点加 `Leaf|NoTreePushOnOpen`。
- 选中行高亮：`highlightWhenSelected`（68-98）——重叠选中时文字 Push `PatternSelected` 色；完全选中时 `TableSetBgColor(RowBg0, color|0x30000000)`（19% alpha 叠加）。
- **表格内 hover 减弱**：`PushStyleColor(HeaderHovered, GetColorU32(HeaderHovered, 0.4F))`（1390-1391 行）——表格里行 hover 只用 40% 强度，避免大面积蓝闪。
- 过滤输入框 `InputTextIcon("##Search", ICON_VS_FILTER, ...)`（1304 行），出错时 Push `LoggerError` 色边框（1300-1302）。

### 3.3 Toast 通知（window.cpp:643-681）

右下角堆叠（最多 4 个）：`WindowRounding=5_scaled`、固定宽 `350_scaled`、距边 `10_scaled`，左侧 5px 色条用 `PushClipRect` + `AddRectFilled(min, max, toastColor, 5_scaled)` 实现（色条颜色=日志级别色）。悬停暂停计时（`IsWindowHovered()` 时刷新 `setAppearTime`）。

### 3.4 Banner（窗口顶部横幅，window.cpp:683-740）

宽度=主窗宽-2_scaled、高 `TextLineHeightWithSpacing*1.5`，背景色=banner 色，文字色用 `IsDarkBackground()` 自动黑白（710 行），临时改 `style.WindowShadowOffsetDist=12` 让阴影只向下。

---

## 4. 图标渲染方案（具体做法）

ImHex 用的是**图标字体（icon font）合并进主字体**，不是 SVG 运行时渲染（SVG 仅用于 logo/横幅图，`Texture::fromSVG`，lunasvg 库）。

### 4.1 三套图标字体

`plugins/fonts/romfs/fonts/` 下：

| 字体 | 来源 | 用途 |
|---|---|---|
| `codicons.ttf` | VS Code Codicons | **主力**（`ICON_VS_*`） |
| `tablericons.ttf` | Tabler Icons | 补充（`ICON_TA_*`，十六进制区的 +/- 折叠按钮） |
| `blendericons.ttf` | Blender 图标 | 特定视图 |
| `unifont.otf` | GNU Unifont | 大字符集兜底（CJK 等） |

### 4.2 合并方式（fonts.cpp:27-32 `registerMergeFonts`）

```cpp
ImHexApi::Fonts::registerMergeFont("VS Codicons", romfs::get("fonts/codicons.ttf").span<u8>(),
                                   { .x=+0.0F, .y=-2.5F }, 0.95F);
ImHexApi::Fonts::registerMergeFont("Tabler Icons", romfs::get("fonts/tablericons.ttf").span<u8>(),
                                   { .x=+2.0F, .y=-1.5F }, 1.10F);
```

- **`MergeMode = true`** 追加进每个 UI 字体（font_loader.cpp:96-105），`GlyphOffset` 手工微调每个图标字体的基线（VS Codicons 上移 2.5px，Tabler 右移 2px 上移 1.5px），`fontSizeMultiplier` 校正相对大小（Tabler 放大到 110%）。
- 字体文件经 **libromfs**（构建期把 romfs 目录编成 C++ 数组）内嵌进二进制，运行时零文件依赖。
- 图标通过 `ICON_VS_SAVE` 这样的**宏**引用（`plugins/fonts/include/fonts/vscode_icons.hpp`，由 font-icon header 生成器产出，每个宏是 UTF-8 字节串如 `"\xf3\xb0\x80\x82"`），和文本可以随意拼接：`fmt::format(" {}  {}", ICON_VS_EYE, value)`。
- 合并进主字体意味着图标**与文字同色、同大小、参与任何 Text 渲染**——`TextColored(icon, ...)` 就能给图标上色，`CalcTextSize(icon)` 直接可用。这是图标字体方案相对纹理图集（如 imgui 本身的 io.Fonts->TexUvWhitePixel 方案或 IconFontCppHeaders+纹理）最大的开发体验优势。

### 4.3 图标按钮的着色语义

ImHex 不给图标单独的配色，全部从主题语义色取：`DimmedIconButton(icon, GetStyleColorVec4(ImGuiCol_Text))` 常规、`ToolbarRed/Green` 状态、`TextDisabled` 禁用。窗口关闭按钮特殊处理：hover 时 Push `ButtonActive=0xFF7A70F1`（偏紫的红）、`ButtonHovered=0xFF2311E8`（window_decoration.cpp:323-324）。

---

## 5. 主题系统架构（代码如何组织颜色/样式）

```
themes/light.json ──┐
themes/dark.json  ──┼──> ThemeManager::addTheme(json 字符串)      ← builtin/source/content/themes.cpp:422-435
用户目录 *.json    ──┘          │
                                ▼
                    ThemeManager::changeTheme(name)               ← lib/.../api/theme_manager.cpp:175-285
                                │  1. 递归应用 "base" 基主题（浅色继承自 ImGui 内建 Light）
                                │  2. 对每个 handler（"imgui"/"imhex"/"implot"/"imnodes"/"text-editor"）
                                │     遍历 colors 节，setFunction(colorId, color)
                                │  3. '*' 前缀颜色过 applyAccentColor() HSV 重映射
                                │  4. styles 节乘 DPI scale 后 clamp(min,max) 写回 ImGuiStyle
                                ▼
                    EventThemeChanged::post()  → 各视图重建纹理等
```

三个关键设计：

1. **ColorHandler 抽象**（themes.cpp:91-98）：`ThemeManager::addThemeHandler("imgui", {名字→枚举映射}, getter, setter)` —— 任何库（implot/imnodes/自研 TextEditor）都能注册自己的调色板，JSON 用 `"colors": {"implot": {...}, "text-editor": {...}}` 分节。setter 直接写 `ImGui::GetStyle().Colors[id]`。
2. **自定义颜色不走 ImGuiStyle**：`ImHexCustomData` 挂在 `ImGui::GetIO().UserData`（头文件 176-183），`ImGuiExt::GetCustomColorU32(ImGuiCustomCol_Highlight)` 读取（imgui_imhex_extensions.cpp:688-700）。好处是 ImGuiCol 枚举不动、数量不限、alpha 乘法统一处理。
3. **主题即数据**：`ThemeManager::exportCurrentTheme()`（theme_manager.cpp:139-173）能把当前运行时状态导出回 JSON；Theme Manager 视图（view_theme_manager.cpp）提供每个颜色的 ColorEdit4 拾色器 + 每个样式的 SliderFloat（带 min/max）+ hover 时该颜色**闪烁预览**（64-77 行）——调色是实时闭环的。
4. **style handler 带 `needsScaling` 和 min/max clamp**（themes.cpp:295-348）：JSON 值永远进不来危险区间。

**对本项目的映射**：bridge 现在的 `kStyleColors` 表（bridge.cpp:1407-1438）+ `apply_style()`（1443-1462）已经是表驱动雏形，与 ImHex 思路同源；差距在于 ImHex 用 JSON 外置 + `*` 强调色重映射 + UserData 扩展槽位。

---

## 6. 对 xcom_imgui_bridge.cpp 的具体借鉴建议（按性价比排序）

### 建议 1：接收区选区改为"框线 + 半透明叠加"双层的 ImHex 模式

现状（bridge.cpp:762-778）：选中行直接一整块 `AddRectFilled(sel_color)`，选区视觉是"高亮条"。
ImHex 手法（hex_editor.cpp:736-771 `drawFrame`）：**选区边缘画 1px `AddLine` 框 + 光标所在格 7.5% alpha 填充**，中间内容保持原底色。接收区是白底黑字，建议：选中范围仍用现有 `TextSelectedBg` 填充，但**拖拽进行中**改画 1px 边框（颜色 `kAccentTeal`）+ 极低 alpha 填充——拖拽时文字不被盖灰，松手后才定型为实填充。`drawBackgroundHighlight` 的 `PushClipRect(window->Rect())` 防溢出写法也值得照搬（bridge 现在靠 clipper 的行宽截断，窗口边缘拖拽时可能画出界）。

### 建议 2：把"语义色"从三五个常量扩展成 ImHex 式的完整组，并让日志级别与工具栏状态共用

现状：palette 命名空间（bridge.cpp:207-229）有 `kDangerRed` 但没有 info/warn/success 的统一组。
ImHex（light.json `imhex` 节 + `ImGuiCustomCol` 枚举）：`toolbar-red/green/yellow/blue/purple == logger-error/debug/warning/info/fatal` 五色一套两用（`#E74C3C / #388B42 / #F1C40F / #06539B / #672A78`）。串口工具天然需要：连接成功（绿）、断开/错误（红）、缓冲告警（黄）、信息（蓝）。建议在 palette 里加 `kInfo=kAccentTeal(0x005A9E) / kSuccess=0x388B42 / kWarn=0xF1C40F(浅底上加深为0xB36B00，与时间戳同源) / kError=0xC50500` 四个语义色，Footer 的 ONLINE/OFFLINE 徽章、Toast（若做）、错误状态全部从这组取。

### 建议 3：Toggle 控件补齐 hover/active 语义（现在只有 on/off 两态）

现状（bridge.cpp:1069-1089 `Toggle`）：自绘拨动开关只有 enabled/disabled 两个底色，hover 无反馈。
ImHex `ToggleSwitch`（imgui_imhex_extensions.cpp:1535-1580）三行就补上：`held ? ImGuiCol_ButtonActive : hovered ? ImGuiCol_ButtonHovered : *v ? ButtonActive : Button` 选底色。bridge 的 Toggle 用 `InvisibleButton` 已经能拿到 hovered/held（`IsItemHovered()/IsItemActive()`），只需在 `AddRectFilled` 前加一次三目。同时可加 **DimmedIconToggle 式的边框语言**：hover 时给轨道加 1px `kAccentTeal` 半透明描边（`AddRect`），键盘可达性也随之改善。

### 建议 4：图标方案迁移到"图标字体合并"，替换手绘矢量图标

现状（bridge.cpp:373-412 `IconButton`）：四个图标（Clear/Save/Path/Refresh）全部用 `AddLine/AddRect/AddCircle` 手绘，每加一个图标 10+ 行坐标代码，粗细/大小不统一风险高（已注释里能看到 stroke 1.8px 是调出来的）。
ImHex 方案：取 **Codicons（`codicons.ttf`，MIT，VS Code 同款，~400 图标）** 或 Tabler Icons 的 ttf 子集，`AddFontFromMemoryTTF(..., MergeMode=true, GlyphOffset, glyph_ranges=图标区间)` 并进 bridge 的 body 字体（bridge.cpp:1524-1534 处加一段）。`ICON_VS_XXX` 宏从 [font-icon-header 生成器](https://github.com/juliettef/IconFontCppHeaders) 或 font_awesome header 项目直接拷。之后：
- `IconButton` 变成 `ImGuiExt::IconButton` 的等价物（约 30 行，见 3 节骨架），图标即字形，`GetColorU32(ImGuiCol_Text)` 统一着色；
- `CalcTextSize(icon)` 自动得到正确 hit box，不再手调 28x26；
- hover 背景直接 `RenderFrame` + 主题色，无需自配 `0xE0E7E1`。
注意：DPI 下 glyph offset 要按 ImHex 的做法微调一次（fonts.cpp:28-31 的 `{x,y}` 值），16px 字号下 Codicons 建议 `GlyphOffset.y = -1` 左右。

### 建议 5：弹窗/菜单的 tooltip 加 0.5s 延迟 + 300px 宽度自适应

现状：`IconButton` 里 `IsItemHovered()` 立刻 `SetTooltip`（bridge.cpp:410），鼠标扫过工具栏时 tooltip 狂闪。
ImHex `InfoTooltip`（imgui_imhex_extensions.cpp:643-686）：`IsItemHovered(ImGuiHoveredFlags_DelayNormal)` 是 ImGui 1.89+ 内建延迟；ImHex 又加了"hover 目标 0.5s 未变才显示"的第二道闸，且文本超 300_scaled 宽时 `SetNextWindowSizeConstraints(300, FLT_MAX)` 强制换行。bridge 的 ImGui 1.93 直接可用 `ImGuiHoveredFlags_DelayNormal`（也可 `io.ConfigHoverDelayShort`），把 4 个 tooltip 调用点统一走一个 helper。

### 建议 6：Section 标题升级为 `SeparatorText` 风格 + 表头淡蓝底

现状：`Section()`（bridge.cpp:317-333）只有彩色标题文字。
ImHex：`ImGuiExt::Header` 就是对 `SeparatorText` 的封装（imgui_imhex_extensions.cpp:630-634）；表格表头统一 `table-header-background: #C6DDF9FF`（强调色 8% 混白）+ `table-border-strong: #9191A3 / light: #ADADBC` 双层线。bridge 的 SERIAL PROFILE 两列表（bridge.cpp:1046-1056）没有表头；建议给列头加 `TableHeadersRow()` + 把 `ImGuiCol_TableHeaderBg` 设成 `#005A9E` 的 8-10% 混白（约 `#E2ECF4`），与现有 `kAccentTeal` 呼应，`TableBorderStrong/Light` 用 `#B0B4BC / #C8CCD2`。

### 建议 7：表格行 hover 减弱到 40%——接收区/多帧格子的防闪烁手法

ImHex pattern_drawer.cpp:1390-1391：进表格前 `PushStyleColor(ImGuiCol_HeaderHovered, GetColorU32(ImGuiCol_HeaderHovered, 0.4F))`，`HeaderActive` 同理。bridge 的 Multi 发送槽表格（bridge.cpp:914-954）如果后续加行 hover，照此把 hover 强度砍到 40%，大面积蓝色 hover 在浅色主题下非常刺眼。

### 建议 8：用 `IO.UserData` 建 ImHex 式自定义色槽，替代散落的 `rgb(0x...)` 字面量

现状：Footer/Header 里仍有 `rgb(0xE9E0CF)`、`rgb(0xC6ECE8)`、`rgb(0xEAF4F8)` 等一次性字面量（bridge.cpp:465, 1154 等）。
ImHex：`ImHexCustomData{ ImVec4 Colors[ImGuiCustomCol_COUNT]; }` 挂 `io.UserData`，`GetCustomColorU32()` 统一带 alpha 乘法读取。bridge 可定义 8-12 个 `XcomCol` 枚举（StatusOnlineBg/StatusOfflineBg/HeaderIconSurface/Timestamp/...），初始化时填表，绘制代码只出现具名枚举——为将来做主题切换（浅/深）留出全部空间。

### 建议 9：`TextOverlay` 式的"空态提示"改进接收区 EmptyState

现状：`EmptyState`（bridge.cpp:1115-1125）手算居中、`TextDisabled("> ...")`。
ImHex `TextOverlay`（imgui_imhex_extensions.cpp:1419-1432）：`AddDrawCmd()` 保证画在最上层 → 不透明 `WindowBg` 圆角底 + 1px Border + 文字，三段 DrawList 调用 13 行。建议接收区空态改为这个式样（带底色小卡片），"WAITING FOR SERIAL DATA" 加上端口未开的引导文字（ImHex 的 hex editor 无数据时就在正中画 `hex.ui.hex_editor.no_bytes` 提示，hex_editor.cpp:825-827）。

### 建议 10：窗口最小尺寸约束 + 紧凑降级的统一入口

ImHex：`glfwSetWindowSizeLimits(m_window, 480_scaled, 360_scaled, ...)`（window.cpp:299）+ View 的 `SetNextWindowSizeConstraints(min, max)` 全覆盖（view.cpp:198）。
bridge：有 `kCompactThreshold`（760px）做侧栏压缩，但没有 `SetNextWindowSizeConstraints` 下限。若后续把发送区/接收区拆成可停靠面板（长期方向），每个 `Panel` 都应带 min 尺寸约束，防止用户拖到 1px 宽。短期可先给 Win32 侧加 `SetWindowPos` 层面的最小尺寸（Lua 层 WM_GETMINMAXINFO）。

### 建议 11（可选）：接收区加 ImHex 式"数据特征着色"

ImHex 十六进制区两个廉价高招可移植到接收区 HEX 显示模式：**全 00 字节置灰**（`ImGuiCol_TextDisabled`，hex_editor.cpp:1002-1013）和 **ASCII 可打印/不可打印分色**（`AdvancedEncodingASCII #0B365D / Single #971B0E / Multi #786209`，hex_editor.cpp:198-209）。串口调试中 0x00/0xFF 填充段和乱码段一眼可辨。

---

## 7. 不建议照搬的部分（差异点）

1. **OpenGL/GLFW 技术栈**：ImHex 用 `ImGui_ImplOpenGL3` + 多视口 + 自定义 GL 多重采样纹理；bridge 的 DX11 WARP 单窗路径更简单可靠，无需改。
2. **1.92.7 的 `FontSizeBase`/`PushFont(font, size)` 连续字号 API**：bridge 的 ImGui 1.93.0 WIP（`IMGUI_VERSION_NUM 19294`，见 imgui-patterns-reference.md）实际上更新，已有等价 API；但 ImHex 的 `fonts::Default().pushBold(0.8)` 相对字号封装值得借鉴（bridge 现在 `ScopedHeadingFont` 只有两档）。
3. **直角全局风格**：ImHex 全 0 圆角 + 1px 黑边框是"IDE/工程工具"定位；bridge 已选定的圆角体系（FrameRounding 5 / Popup 6）更接近消费级工具，混搭时注意**不要**把 ImHex 的 `border #0000004C`（30% 纯黑）直接套到 bridge 的浅色面板上——bridge 的 `0xDDDDDF` 灰边框 + 白底更柔和。可取的中间值：外框 `#00000026`（15% 黑）。
4. **Dock 系统**：ImHex 重度依赖 ImGui docking；bridge 的固定仪表盘布局（monitor_column + serial_column + footer）对串口工具是更优解，不建议引入 dock。
5. **菜单栏**：ImHex 的完整菜单栏 + 快捷键系统对本工具过重；bridge 的 Header 工具条模式保留。

---

## 8. 快速参数对照表（抄值用）

```
ImHex 浅色主题速查（@1x, ImVec4 归一化前）
──────────────────────────────────────────────
窗口底        #EFEFEF     菜单栏/标题    #DBDBDB
弹窗/输入框   #FFFFFF     表头          #C6DDF9 (蓝8%)
边框          #0000004C   分隔线        #6363639E
文字          #000000     禁用文字      #999999
选区底        #4296F959   强调色        #4296F9 (hover #0F87F9)
tab未选中     #C2CBD5ED   tab选中       #97B9E1  tab顶线 #4296F9
滚动条槽      #F9F9F987   滑块          #AFAFAFCC → hover #7C7CCC → active #7C7C7C
危险红        #E74C3C     成功绿        #388B42   警告黄  #F1C40F
信息蓝        #06539B     致命紫        #672A78

几何
──────────────────────────────────────────────
window-padding 8,8   frame-padding 4,3   item-spacing 8,4
scrollbar 10px / rounding 9   tab-rounding 5   tab-overline 1px
dock-separator 2px   toast 350px 宽 / 5px 圆角 / 右下 10px 边距
tooltip 延迟 0.5s / 最大宽 300   光标闪烁周期 1.2s(亮0.8)
subwindow rounding 5   sidebar 按钮 rounding 3   banner 高 1.5×行高
```

## 9. 源码文件索引（本机路径）

| 文件 | 内容 |
|---|---|
| `ref\ImHex\plugins\builtin\romfs\themes\light.json` | 浅色主题全部颜色/样式真值 |
| `ref\ImHex\plugins\builtin\romfs\themes\dark.json` | 深色主题（对照） |
| `ref\ImHex\plugins\builtin\source\content\themes.cpp` | ColorHandler/StyleHandler 注册表（imgui/imhex/implot/imnodes/text-editor 五组） |
| `ref\ImHex\lib\libimhex\source\api\theme_manager.cpp` | 主题加载/应用/强调色 HSV 重映射/导出 |
| `ref\ImHex\lib\libimhex\include\hex\ui\imgui_imhex_extensions.h` | ImGuiExt 控件库接口 + ImHexCustomData 定义 |
| `ref\ImHex\lib\libimhex\source\ui\imgui_imhex_extensions.cpp` | 全部自绘控件实现（1685 行） |
| `ref\ImHex\plugins\ui\source\ui\hex_editor.cpp` | 十六进制视图（表格网格 + DrawList 高亮 + minimap） |
| `ref\ImHex\plugins\ui\source\ui\pattern_drawer.cpp` | Pattern Data 树表格（9列 + 排序 + 过滤 + 收藏） |
| `ref\ImHex\plugins\builtin\source\content\window_decoration.cpp` | 菜单栏/标题栏/侧边栏/底部状态栏 |
| `ref\ImHex\main\gui\source\window\window.cpp` | 主循环、dock host、Toast/Banner 绘制、弹窗栈 |
| `ref\ImHex\lib\libimhex\source\ui\view.cpp` | View 基类四形态 |
| `ref\ImHex\plugins\fonts\source\fonts.cpp` + `font_loader.cpp` | 图标字体合并 + FreeType 配置 |
| `ref\ImHex\plugins\fonts\include\fonts\vscode_icons.hpp` | ICON_VS_* 宏（图标字形定义） |
| `ref\ImHex\plugins\builtin\romfs\layouts\default.hexlyt` | 默认 dock 布局（含尺寸比例） |
