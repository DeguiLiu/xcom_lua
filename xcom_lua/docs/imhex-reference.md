# ImHex 参考调研（ImGui 控件 / 主题 / 代码模式）

> 参考项目：ImHex 1.39.0.WIP（commit `feb826c14b`，2026-09-04），C++20 + GLFW + OpenGL3，
> 基于 Dear ImGui 1.92.7 WIP（docking 分支，含 FreeType）。原参考路径 `ref/ImHex/`（外部 clone，
> 不随本仓库分发）。本文合并原 `imhex-ui-reference`（UI/主题/控件）与 `imhex-patterns-reference`
> （代码模式）两份笔记，面向 `xcom_imgui_bridge.cpp`（DX11 + Win32 + WARP）。
> ImHex 行号来自当时 clone，仅作定位线索；引用以文件名为准。

## 为什么值得看

ImHex 的 UI 品质来自两件事：**JSON 主题系统**（强调色驱动，可导出回 JSON）与 **1685 行的 ImGui
扩展控件库** `imgui_imhex_extensions.cpp`（命名空间 `ImGuiExt`）。它把 HexEditor / TextEditor 做成
可复用**控件**（组合），View 只是**窗口**（继承）——这种"重渲染逻辑下沉到控件层"的分层，对单文件
bridge 最对路。

## 浅色主题的真实参数（可直接抄值）

`plugins/builtin/romfs/themes/light.json`，`#RRGGBBAA`：

| 语义 | 值 | 说明 |
|---|---|---|
| window-background | `#EFEFEF` | 窗口/dock 底 |
| menu-bar/title-background | `#DBDBDB` | 比窗口底深一档 |
| popup / frame-background | `#FFFFFF` | 弹窗/输入框纯白 |
| table-header-background | `#C6DDF9` | 强调色 8% 混白 |
| border | `#0000004C` | 通用边框（30% 黑，不是灰） |
| separator | `#6363639E` | 分隔线 |
| scrollbar-grab / hover / active | `#AFAFAFCC` / `#7C7C7CCC` / `#7C7C7CFF` | |
| text / disabled | `#000000` / `#999999` | |
| text-selected-background | `#4296F959` | 强调色 35% |
| toolbar red/green/yellow/blue/purple | `#E74C3C / #388B42 / #F1C40F / #06539B / #672A78` | **日志五级色复用同一套** |

样式几何：window-padding `8,8`、所有 rounding 为 **0**（直角体系，仅 tab 5px、滚动条 9px）、
tab 顶部 1px 强调线、docking-separator 2px、tooltip 延迟 0.5s、宽度上限 300、光标闪烁周期 1.2s
（亮 0.8）、toast 350px 宽 / 5px 圆角 / 右下 10px。框架 `border #0000004C` 偏硬，bridge 浅色面板
建议取中间值 `#00000026`（15% 黑），不要直接套。

主题系统三点设计：ColorHandler 抽象（任意库注册自己的调色板分节）、自定义色挂 `io.UserData`
（不动 ImGuiCol 枚举）、主题可导出回 JSON（运行时调色闭环）。

## 值得逐个抄的自绘控件（`ImGuiExt::`）

每个控件复刻 ImGui 内部 Button 结构：`GetCurrentWindow → SkipItems 早退 → GetID → ItemSize →
ItemAdd → ButtonBehavior → RenderNavCursor/RenderFrame/RenderTextClipped → 测试钩子`。

| 控件 | 手法要点 |
|---|---|
| `Hyperlink` / `IconHyperlink` | 文字按钮无框化，hover 才画下划线 |
| `DescriptionButton` / `+Progress` | 欢迎页大按钮：图标 PushFont 放大 25%、双行 label/description、底部 5px 进度条 |
| `InfoTooltip` | `IsItemHovered(DelayNormal)` + hover 目标 0.5s 未变才显示，宽上限 300 自动换行 |
| `ToolBarButton` / `IconButton` | 方形工具栏按钮，语义色复用 ScrollbarGrab |
| `DimmedButton` / `DimmedIconToggle` | 弱化按钮族，`FrameBorderSize=1.5`，**用边框色表示开关状态** |
| `ToggleSwitch` | iOS 胶囊拨动开关，约 25 行自绘（`AddRectFilled(size.y/2)` + `AddCircleFilled`） |
| `BeginSubWindow` / `BeginBox` | 可折叠子面板 / 1 列 Table 分组框 |
| `InputTextIcon` / `InputPrefix` / `InputHexadecimal` | 输入框内嵌图标 / 前缀（手绘后透明 InputText 叠上） |
| `BitCheckbox` | 单字符宽 checkbox |
| `ProgressBar` | 负值 = 不定进度动画 |
| `TextOverlay` | 面板中央提示：`AddDrawCmd` 抢绘制顺序 + 不透明底 + 文字 |
| `TextFormattedSelectable` | 只读 InputText 伪装可复制文本（边框/底色全透明） |
| `IsDarkBackground` | 感知亮度决定叠字黑/白，任何"彩色底上写字"都该这么算 |

## 十六进制视图（HEX 展示 + 关键词高亮的直接参考）

`plugins/ui/source/ui/hex_editor.cpp`。核心手法：

- **手算可见行区间**代替 ListClipper：等宽 + 固定行高下行号可由滚动像素换算，多画 5 行冗余。
- **三层叠加**：背景块 `AddRectFilled`（外套 `PushClipRect`）、选区 4 条 1px `AddLine` 边框
  （不填中间，鼠标当前格叠 7.5% 透明填充）、前景文字 `PushStyleColor(Text)`。
- **每行颜色预计算**：进行循环先查好整行 `(fg,bg)` 存 `cellColors`，列循环只读——颜色决策与绘制分离。
- **高亮缓存**：`map<offset,color>`，规则变更事件 `EventHighlightingChanged` 清空缓存；
  函数版 provider 返回 `nullopt` 表示不改色。我们不需要 provider 注册表，bridge 单文件在
  `ImGuiRuntime` 放 `unordered_map<u32,ImU32>`（字节偏移→色），Lua 整表替换时置 dirty 即可。
- **0x00 灰显**：全 0 行给 `ImGuiCol_TextDisabled`（一行代码的档次提升）。

## 内嵌文本编辑器（Lua Script Console 参考）

`plugins/ui/.../text_editor/*`，约 8000 行（源自 BalazsJako/ImGuiColorTextEdit）。核心数据结构
是**三根平行字符串**：`chars` / `colors`（每字节一个调色板下标）/ `flags`，行级 `colorized` 脏标记，
渲染时按"同色 run"切段输出——**着色离线增量，渲染只做顺序扫描**。

不采纳整体移植（代码折叠/断点/delimiter 匹配远超需求）。采纳其**数据结构思想**（平行字符串 +
行级 dirty），以及"日志等级前缀 → 行首着色"的降维：定义一个 tokenize 回调，只看行首 `D: / W: / E:`
前缀映射到调色板，日志等级着色被降维成"每行一个 token 的语法高亮"。

## 浮窗 / 生命周期

- 窗口命名 `fmt::format("{}###{}", 本地化标题, 稳定名)`——换标题/语言不丢窗口状态。
- `View::Window::draw()` 是模板方法：`shouldDraw → SetNextWindowSizeConstraints(min,max) →
  Begin(title,&open,NoCollapse) → drawContent()`；浮窗仅多 `NoDocking`。
- `trackViewState()` 边沿检测 `onOpen/onClose`；"always-visible 内容"与窗口本体分离。
- 帧内容比对跳过渲染：`frameEnd` 逐 viewport memcmp `VtxBuffer`，无变化跳过 Present。
  对 bridge 的启发：idle 500ms 档下 draw data 未变时 Lua 侧可直接不调 `render()`。
- 崩溃看门狗：逐帧 try/catch，连抛 10 次 abort，否则强制 `EndFrame()` 复位。
  bridge draw 导出函数可包同款防御，防 ImGui 断言卡死进程。

## TTY 串口控制台（与本项目同域）

`plugins/windows/source/views/view_tty_console.cpp`（Win32 串口）：

- 接收线程 + 互斥锁，可打印字符追加、`\n` 开新行、`\r` 忽略、**不可打印显示 `<XX>`**
  （正是 HEX/ASCII 混排的参考）。
- 渲染用 `ImGuiListClipper` + 每行 `TextUnformatted`，贴底跟随用
  `if (autoScroll && GetScrollY() >= GetScrollMaxY()) SetScrollHereY(0)`。
- REPL 输入行 `InputText(..., EnterReturnsTrue)` 回车即发，随后 `SetKeyboardFocusHere(0)` 保持焦点。

## ImPlot 用法（示波器参考）

- `PlotLineG(name, getter, data, count)`：数据不复制、不要求连续数组，适合环形缓冲多通道。
- `digital_signal.cpp`：轴约束 `SetupAxisLimitsConstraints` + `SetupAxisFormat(Y,"")` 隐藏刻度；
  游标/区域标注走 `PlotToPixels + GetPlotDrawList + PushPlotClipRect`，不必等内建 drag 工具。
- 数据侧生成、绘图侧纯查询（回调追加进桥侧环形缓冲，draw 只读）。

## 字体 / CJK / 图标

- **字体角色制**：注册 default / hex_editor / code_editor 三角色，draw 时 `PushFont/PopFont`
  包区域（成本两行，收益是 UI 档次）。bridge 可存 2~3 个 `ImFont*`。
- **CJK：merge 一款覆盖广的中文字体，不指定 GlyphRanges**。ImGui 1.93 的 FreeType 动态字形
  让 `MergeMode` 全量字体可行；`GetGlyphRanges*` 已标 obsolete。
  参考缺口：`GetGlyphRangesChineseSimplifiedCommon`（2500 常用简体 + 基本拉丁，覆盖 97.97%，
  **不含假名、不含繁体**）；`GetGlyphRangesChineseFull`（全 CJK + 假名 + 全角，约 2 万 glyph，
  WARP 下 atlas 变大）；`GetGlyphRangesJapanese`（2999 汉字，无假名段）。**多表 AddRanges 合并**
  是最小代价：SimplifiedCommon + Japanese + 假名 `0x3040-0x30FF`（+可选繁体段）。
  xcom_lua 的 charset.lua 已统一转 UTF-8，字体侧只需 Unicode 覆盖。
- **图标字体 merge**：`AddFontFromMemoryTTF(..., MergeMode=true, GlyphOffset, glyph_ranges)` 并进
  body 字体，`ICON_VS_*` 宏（IconFontCppHeaders 生成）与文字同色同大小；DPI 下 GlyphOffset 微调。

## 采纳清单（按投入产出排序）

| # | 模式 | 用到哪 |
|---|---|---|
| 1 | drawList `AddRectFilled` + `PushClipRect` 画背景块；`PushStyleColor(Text)` 画前景 | 接收区关键词高亮 |
| 2 | 每行预计算颜色向量，绘制期只查表 | 接收区/HEX 高亮热路径 |
| 3 | 高亮缓存 map + 规则变更即整体失效 | Lua 改规则 → 清缓存重算 |
| 4 | TTY 控制台全套（收线程→行缓冲→clipper→autoscroll→EnterReturnsTrue） | Script Console 浮窗 |
| 5 | 等级前缀 → 行着色 + Combo 等级过滤 | 控制台日志着色/过滤 |
| 6 | `PlotLineG` + `PlotToPixels`/`GetPlotDrawList`/`Annotation` | ImPlot 示波器多通道/游标 |
| 7 | 不可打印字节 `<XX>` | HEX 视图 ASCII 列 |
| 8 | `###` 稳定 ID + `SetNextWindowSizeConstraints` 浮窗骨架 | 所有新浮窗 |
| 9 | `TextFormattedSelectable` | 状态栏统计等只读数值 |
| 10 | 灰显 0x00 | HEX 视图 |
| 11 | 行号滚动模型（手算区间 +5 行冗余） | HEX 视图 |
| 12 | 字体角色 PushFont/PopFont + 图标字体 merge | 分区域字体、工具栏图标 |
| 13 | Lua 关键字/内置名清单（删 5.3 专属项） | 脚本编辑器语法高亮 |
| 14 | 平行字符串 chars/colors + 行级 dirty | 接收区着色缓存 |
| 15 | `BeginSubWindow` 折叠面板 | 控制台三段面板 |
| 16 | draw 包 try/catch + 强制 EndFrame | bridge draw 导出 |
| 17 | draw data 未变不渲染 | idle 档节能（可选） |

**明确不采纳**：View 继承树 + ContentRegistry（单文件 bridge 用 `bool open` 即可）；
EventManager 模板事件总线（Lua 侧一个 dirty 标志等价）；`handleFocusRestoration` 深挖 ImGui 私有结构；
LayoutManager 布局文件；TextEditor 整体移植（约 8000 行）；HexEditor 的 Insert/折叠/Minimap/自绘滚动条；
math_eval 高亮表达式引擎；Provider/PerProvider 抽象；编译期哈希 i18n；直改 STB 光标；
drawlist 多通道 minimap；OpenGL 后处理 shader（我们是 DX11）。
