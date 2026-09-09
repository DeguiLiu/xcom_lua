# ref/ 三仓库研究：ImGuiFontStudio / uscope / WaveEdit

> 2026-09-05。只读研究，对应本仓库三个具体物：
> ① `native/xcom_imgui/xcom_imgui_bridge.cpp` 的字体加载（heading_font_/mono_font_ + 新加 CJK merge，bridge.cpp:2057-2111）；
> ② `core/waveform.lua` GDI 示波器弹窗（65536 点环形缓冲回看）；
> ③ Phase 4 计划的 ImPlot 示波器面板。
> 所有行号均经 Read/Grep 验证（ref 仓库快照 + 本仓库当前工作区）。

---

## 1. ref/ImGuiFontStudio — 字体子集/合并/预览工具（aiekick，C++/ImGui）

### 1.1 是什么

图标/字体工作台：打开任意 ttf/otf，勾选 glyph 子集，产出 ①合并后的 TTF ②Base85 压缩的 C/C++/C# 内嵌源码 ③`ICON_MIN/ICON_MAX` + 每个 glyph 的 `\uXXXX` 宏头文件 ④glyph 卡片 PNG。OpenGL3/Vulkan 双后端，FreeType 与 stb 双光栅器可切换。对我们而言它是"ImGui 里怎么组织多字体加载/预览/范围生成"的最全样例。

### 1.2 核心文件 + 行号

| 主题 | 位置 | 要点 |
|---|---|---|
| 每字体独立 Atlas | `src/Project/FontInfos.h:57`（`ImFontAtlas m_ImFontAtlas` 成员） | 每个打开的字体一个**独立 atlas**（非全局 io.Fonts），互不干扰 |
| 字体加载 | `src/Project/FontInfos.cpp:93-211`（`LoadFont`） | 全范围 `0x0020-0xFFFF`（:109-114）加载；atlas 关闭鼠标光标/内置线条（:119-121）；FreeType 走 `ImGuiFreeType::BuildFontAtlas`、stb 走 `atlas.Build()`（:147-154） |
| 运行时重建 | `src/Project/FontInfos.cpp:551-557` | 任何光栅参数（字号/oversample/padding/FreeType 标志）变动 → 置 `needFontReGen` → 整字体重开（Clear + AddFontFromFileTTF + Build + 重建纹理）。**没有增量重建，永远全量** |
| 纹理上传 | `src/Project/FontInfos.cpp:737-754`（`CreateFontTexture`） | `GetTexDataAsRGBA32` → 后端纹理 → `atlas.TexID` 赋值，手动管理而非后端 CreateDeviceObjects |
| 字体-键复用 | `src/Panes/ParamsPane.cpp:487-525`（`OpenFont`） | 按文件名在 `ProjectFile::m_Fonts` map 里复用 `FontInfos`，避免重复加载 |
| TTF 级合并 | `src/Generator/FontGenerator.cpp:264-297`（`MergeCharacterMaps`）、`:300-341`（`AssembleFont`）、`:347-424` | 用 Google sfntly 在 **glyf/loca/cmap/hmtx 表级**把多字体拼成一个新 TTF；glyph 重编号 + bbox 重算。重量级（离线工具），与运行时 MergeMode 无关 |
| 范围生成 | `src/Generator/HeaderGenerator.cpp:122-141`（ICON_MIN/MAX）、`:143-158`（`#define X u8"\uXXXX"`） | 输出的是"选定 codepoint 集的 min/max"，供使用方 `static const ImWchar ranges[] = {MIN, MAX, 0}` 加载 |
| Base85 内嵌 | `src/Generator/Compress.cpp:44-198` | `stb_compress` + Base85；buffer ≥ 65536 时转 byte[] 形式（:81，编译器字符串长度限制）——同 imgui `binary_to_compressed_c` |
| glyph 网格自适应 | `src/Project/GlyphInfos.cpp:37-103`（`CalcGlyphsCountAndSize`） | 两种策略：固定格宽算列数 / 固定列数算格宽，编辑模式单独算行高 |
| 单 glyph 绘制 | `src/Project/GlyphInfos.cpp:955-1091`（`DrawGlyphButton`）、`:1093-1135`（`RenderGlyph`） | 自绘按钮 + `PushTextureID → PrimReserve → PrimRectUV` 直绘 glyph 四边形；带 zoom 等比适配（:1107-1121） |
| 多字体混排预览 | `src/Panes/FontPreviewPane.cpp:364-481`（`DrawMixedFontResult`） | 一行文字里逐字符切字体：`font->RenderChar` + 按各自 Ascent 修正基线（:432-435），offsetX 累加 AdvanceX。**这是"同一段文本多 fallback 字体"的参考实现** |
| 官方合并用法 | `README.md:106-137` | `MergeMode=true` + `PixelSnapH=true` + ranges 数组——与我们 bridge.cpp 的做法同构 |

### 1.3 对 bridge.cpp 字体加载的可采纳模式

**（a）我们已做的 = 正解。** bridge.cpp:2094-2111 的 `GetGlyphRangesChineseSimplifiedCommon` + `MergeMode` + msyh/simsun 回退，与 ImGuiFontStudio README:106-137 教的官方合并模式一致；builder 是栈变量、ranges 存 Runtime，也符合 atlas 生命周期要求。

**（b）运行时切换 GB2312/BIG5/SJIS 显示：merge 常用字表基本够，但有缺口。** 关键事实（`ref/imgui/imgui_draw.cpp`）：

- `GetGlyphRangesChineseSimplifiedCommon`（imgui_draw.cpp:4963-4969）：2500 常用简体字 + Basic Latin，覆盖 97.97% 简中用法。**不含假名、不含繁体**。
- `GetGlyphRangesChineseFull`（imgui_draw.cpp:4937-4951）：`0x4E00-0x9FAF` 全 CJK 表意 + CJK 符号/假名 `0x3000-0x30FF` + 全角 `0xFF00-0xFFEF`——GB2312/BIG5/SJIS 汉字**全兜住**，但约 2 万 glyph，WARP 软渲染 atlas 会明显变大、首帧 build 变慢。
- `GetGlyphRangesJapanese`（imgui_draw.cpp:5031-5052）：2999 个汉字（Joyo+Jinmeiyo）+ 无假名段（假名在 ChineseFull 的 0x30xx 段；SimplifiedCommon 不含）。

结论：**多表 AddRanges 合并**是最小代价方案——`ImFontGlyphRangesBuilder` 依次 `AddRanges(GetGlyphRangesChineseSimplifiedCommon())` + `AddRanges(GetGlyphRangesJapanese())` + 补 `0x3040-0x30FF`（假名）+ 繁体常用段。我们的字符集转换在 core/charset.lua 里已完成（GB2312/BIG5/SJIS → UTF-8），字体侧只需要 Unicode 覆盖，不需要理解源编码——这是本项目架构的先天优势，ImGuiFontStudio 的 sfntly 表级合并完全用不上。

**（c）不采纳：动态 glyph 按需加载。** ImGuiFontStudio 全库没有运行时按需加 glyph 的模式（它按需的方式是"重新打开整个字体"）。ImGui 1.93 也没有公开的运行时 atlas 增量 API（只能整 atlas rebuild）。我们被动驱动 16-100ms 一帧，rebuild 会造成可感知卡顿——维持"启动时一次 build 常用字表"策略。

**（d）可选采纳：多 fallback 字体混排。** 若将来 mono 字体要混入第二个 CJK fallback（而非 merge），FontPreviewPane.cpp:364-481 的逐字符 `RenderChar` + Ascent 修正是实现样板；但 merge 模式下不需要。

**（e）可选采纳：`atlas.Flags |= NoMouseCursors|NoBakedLines`**（FontInfos.cpp:119-121）。我们 WARP 软渲染下这两项能省一点 atlas 面积/构建时间；需确认不依赖 ImGui 内置软件光标。

---

## 2. ref/uscope — Linux 原生代码图形调试器（jcalabro，Zig）

### 2.1 是什么（重要：不是示波器）

uscope = "microscope"，**Linux 原生代码图形调试器**（README.md:9），Zig 编写，含 DWARF/ELF 解析、ptrace 控制、C/Zig/Odin/C3 变量可视化。README.md:19 明确：UI 正在整体重写为 Web 版，旧原生 UI 已删（只剩 `old-ui` tag）；当前树内 `GUIType` 直接指向测试用 `TestGUI`（`src/gui/State.zig:31-34`）。**树内没有任何波形/图表绘制代码**（全库 grep chart/plot/graph/waveform/downsample 无 GUI 命中）。

它的价值在**数据管线架构**：子进程 stdout 高频捕获 → 线程安全队列 → GUI 线程限帧消费 → 有界环形缓冲展示。这正是我们 waveform.lua 从串口收数到回看所走的同构问题域。

### 2.2 核心文件 + 行号

| 主题 | 位置 | 要点 |
|---|---|---|
| 环形缓冲 | `src/circularBuffer.zig:5-57` | 泛型 `CircularBuffer(T)`；`append`(:34-50) 写满后推进 read_ndx 覆盖最旧；`get(ndx)`(:52-55) 逻辑索引随机访问。默认容量仅 8 KB（`settings.zig:101` `output_bytes = 1024*8`） |
| 线程安全队列 | `src/queue.zig:15-96` | Mutex+Condition；`put`(:65-72) 头插、`get`(:76-86) 超时等待、`getOrNull`(:89-94) 非阻塞；队列超时 10ms（`debugger/debugger.zig:210`） |
| 捕获线程 | `src/debugger/debugger.zig:708-749`（`captureOutput`） | stdout/stderr 各一线程（:655-673 spawn），512 字节块读 pipe → 拷贝到响应队列分配器 → 投递 `ReceivedTextOutputResponse` |
| 作者自评的坑 | `src/debugger/debugger.zig:751-759` | 注释直言：**用通用响应队列传高频输出是错的**（泄漏 + 高流量），应重构——验证了我们"波形数据不走通用消息队列、直接进专用环形缓冲"的选择 |
| GUI 每帧行为 | `src/gui/State.zig:138-160`（`update`） | `state_updated` 脏标记触发才 `scratch_arena.reset(.free_all)` 重建快照；否则只排水响应 |
| 每帧排水预算 | `src/gui/State.zig:169-224`（`handleDebuggerResponses`） | **每 tick 最多处理 512 条消息**（:174-175），多余的留到下一帧——防单帧被数据洪峰卡死 |
| 输出消费 | `src/gui/State.zig:189-197` | 收到 text_output 持锁逐字节 append 进 subordinate_output 环形缓冲（:53-54 定义 + Mutex） |
| 脏标记拉取 | `src/debugger/proto.zig:76-86`（`StateUpdatedResponse` 注释） | 后端只发"有更新"信号，GUI 主动 `GetStateRequest` 拉全量快照——推信号/拉数据分离 |
| 帧率控制 | `src/test/simulator.zig:28-29`（MaxFPS=60/FrameMicros）、`:286-295`（`frameRateLimit`） | 帧预算用尽则 sleep 差值——与我们 16-100ms 被动帧同思路，帧逻辑与真实时间解耦 |
| 设置 | `src/settings.zig:99-117` | 输出容量、follow_output（自动跟随最新输出，可全局/项目覆盖）——对应我们 waveform.lua 的 `follow` |

### 2.3 对 waveform.lua / ImPlot 面板的可采纳模式

**（a）采纳：每帧排水预算（512 条/tick）。** waveform.lua 目前 push 直接写环形缓冲（Lua 侧单线程无此问题），但 Phase 4 ImPlot 面板若走"DLL 侧收数 → Lua 每帧取"的路径，应加"每帧最多取 N 字节/N 点，余量下帧"的预算，参照 State.zig:174。对应我们串口高速率的现实场景这是必要的。

**（b）采纳：脏标记 + 拉取分离。** 数据生产方只置 dirty 标志，渲染帧自己决定拉多少（proto.zig:76-86 的模式注释）。我们 waveform.lua 已有 `dirty` 字段（waveform.lua:416），方向一致；ImPlot 面板沿用即可。

**（c）已隐式采纳：高频数据不进通用队列。** debugger.zig:751-759 的作者自评是反面教材背书——我们的专用 ring（waveform.lua:97-111）是对的，不要改成经消息队列中转。

**（d）不采纳：Zig 全套架构/线程模型。** 我们 LuaJIT 单线程 + uvc 定时器（waveform.lua REPAINT_MS=33，:53）已是帧率无关的实现；uscope 的三线程（serve/captureStdout/captureStderr）在 Windows+LuaJIT 下没有对应收益。

**（e）警示：默认 8 KB 环形缓冲偏小。** uscope 只展示程序 stdout 尾部所以够；我们 65536 点/系列（waveform.lua:49）的回看定位不同，不要照抄它的容量哲学。

---

## 3. ref/WaveEdit — 波表编辑器（Synthesis Technology，SDL+OpenGL+旧版 ImGui）

### 3.1 是什么

E352/E370 Eurorack 波表模块的 bank 编辑器（Andrew Belt，VCV Rack 作者）。数据模型**很小**：每波 256 点（`WaveEdit.hpp:123 WAVE_LEN=256`）、bank 64 波（:181），不存在"大波形回看"问题——所以**没有 LOD/多级细节/分段缓存**。它的价值在：①手写 ImGui 自定义控件范式 ②自适应网格 ③等比缩放/吸附 ④固定尺寸重采样预览 ⑤瀑布图分层绘制。

### 3.2 核心文件 + 行号

| 主题 | 位置 | 要点 |
|---|---|---|
| 自适应网格 | `src/widgets.cpp:9-40`（`drawGrid`） | skip 取 2 的幂直到格距 ≥ 22px（:13-18）；**层级线宽**：每 64 格 3px / 每 8 格 2px / 其余 1px（:23-30） |
| 自定义控件范式 | `src/widgets.cpp:83-155`（`editorBehavior`） | 手写 ImGui 控件：`IsHovered→SetHoveredID→SetActiveID→FocusWindow`，释放 `ClearActiveID`；鼠标坐标 `rescalef` 映射到数据域，`MouseDelta` 做增量编辑 |
| 波形绘制 | `src/widgets.cpp:158-217`（`renderWave`） | lines + points + `PushClipRect`；固定映射 `rescalef(i,0,len, min,max)` |
| 直方图（谐波） | `src/widgets.cpp:220-262`（`renderHistogram`） | 主 bars + ghost bars 双层 |
| 瀑布图分层 | `src/widgets.cpp:451-541`（`renderWaterfall`） | 两遍画 64 条折线：预效果层用 **FrameBg 背景色**（:504-516，制造遮挡错觉），后效果层彩色 + 活动行加粗 `1+4*(1-|b-z|)`（:529） |
| Ctrl 拖拽块移动 | `src/widgets.cpp:374-400` | 拖动开始快照整 bank 到 static，拖动中按 offset 重放——防中间态闪烁 |
| **固定尺寸预览** | `src/import.cpp:89-92` | 载入任意长音频后**一次性重采样到固定 16384 点** `audioPreview`；此后预览渲染只画这个定长数组，与源长度无关 |
| 视窗重切片 | `src/import.cpp:105-166`（`computeImport`） | zoom/offset/trim 变化时按 ratio 对源数据重采样出目标段，边界 clamp 链（:115-131） |
| 缩放吸附 | `src/import.cpp:240-252` | "Snap to Power of 2"：`zoom = 2^round(log2(zoom))`；另有 Zoom Fit（:35-37 `zoomFit`） |
| 轻量 FFT | `src/math.cpp:7-31` | pffft 实数 FFT，`len>=4096` 才配 work buffer |
| 重采样 | `src/math.cpp:34-45`、`src/audio.cpp:26-80` | libsamplerate `SRC_SINC_FASTEST`；audio 线程是**拉取式回调**——按 outLen 精确生成 |
| 时间合并撤销 | `src/history.cpp:10-24` | 0.2s 内的连续编辑合并为一条历史 |
| 最小化不渲染 | `src/main.cpp:120-126` | `SDL_WINDOW_SHOWN && !MINIMIZED` 才 `uiRender()` |

### 3.3 对 65536 点回看 + ImPlot 面板的可采纳模式

**（a）采纳：固定尺寸预览缓冲（最核心）。** WaveEdit import.cpp:89-92 的模式直接回答了"65536 点环怎么便宜地回看"：**回看视图不直接遍历 65536 点**，而是像 waveform.lua 已做的那样按可视窗口二分定位（waveform.lua:127-135 `ring_lower_bound` + :340-353 可视窗遍历）——这已是同一思想的更优实现（WaveEdit 是全局定长降采样，我们是可视窗裁剪，粒度更细）。若 Phase 4 ImPlot 面板出现"全量总览"需求（如 minimap），则采纳 WaveEdit 的定长降采样缓冲（如 4096 点 min/max 摘要）。

**（b）采纳：自适应网格 + 层级线宽。** drawGrid 的"2 的幂步进直到 ≥22px + 64/8/1 三档线宽"（widgets.cpp:9-40）比 waveform.lua 现在的固定 10 列 × 8 行（waveform.lua:290 `COLS, ROWS = 10, 8`）更好：缩放跨度变化大时网格密度自动合理，主刻度线视觉分级。ImPlot 面板可直接抄该算法。

**（c）采纳：缩放吸附 2 的幂 + Zoom Fit。** import.cpp:240-252 的 `2^round(log2(zoom))` 让缩放档位手感稳定；"Fit"一键回全量（:35-37）。waveform.lua 目前只有 10s 固定窗 + 平移（:411 `view_ms=10000`），加 wheel 缩放时应采用此吸附方案，并保证时间轴刻度始终落在"好数"上（与 (b) 联动：吸附后网格步进必为整数倍）。

**（d）采纳：自定义控件范式（Phase 4 ImPlot 面板）。** editorBehavior（widgets.cpp:83-155）是绕开 ImPlot 自带交互、手写拖拽/缩放的完整样板（hover/active ID 管理 + 数据域映射 + MouseDelta 增量）。若 ImPlot 内置 pan/zoom 手感不满足（被动 16-100ms 帧率下可能迟钝），可按此范式在面板上自绘交互层。瀑布图的"背景色预层 + 彩色活动层 + 近邻加粗"（:504-529）也适用于我们多通道重叠时的视觉分离（当前通道加粗，其余淡化）。

**（e）可选采纳：minimap/隐藏时不渲染。** main.cpp:120-126 的最小化跳过渲染，对应 waveform.lua 已有的 visible 才开 repaint timer（:479 注释）；Phase 4 面板同样应仅在可见时重画。

**（f）不采纳：FFT/谐波视图、音频拉取回调。** 我们是串口数据示波器，除非将来做频谱分析，pffft 集成（math.cpp:7-16）暂无必要；libsamplerate 依赖也过重。

**（g）不采纳：时间合并撤销。** history.cpp 的 0.2s 合并对只读波形回看无意义。

---

## 4. 采纳清单

| # | 来源 | 采纳内容 | 落点 | 理由 |
|---|---|---|---|---|
| 1 | ImGuiFontStudio README:106-137 | 维持现有 MergeMode+常用字表方案（已实现） | bridge.cpp:2094-2111 | 与官方/工具链推荐一致，架构已对齐 |
| 2 | imgui_draw.cpp:4937-4952, 5031-5052 | **多表 AddRanges 合并**：SimplifiedCommon + Japanese + 假名段 0x3040-0x30FF（+可选繁体段），一次 build 覆盖 GB2312/BIG5/SJIS | bridge.cpp CJK merge 块 | charset.lua 已统一转 UTF-8，字体只需 Unicode 覆盖；比 ChineseFull（2 万 glyph）省 atlas，比单 SimplifiedCommon 补齐假名/繁体缺口 |
| 3 | FontInfos.cpp:119-121 | `ImFontAtlasFlags_NoMouseCursors \| NoBakedLines` | bridge.cpp atlas flags | WARP 软渲染下省 atlas 面积与构建时间（需确认不用内置软件光标） |
| 4 | uscope State.zig:174 | **每帧排水预算**（最多 N 条/N 点每帧，余量下帧） | Phase 4 ImPlot 面板取数路径 | 防高速率下单帧被数据洪峰卡死；被动 16-100ms 帧预算下的必要保护 |
| 5 | uscope proto.zig:76-86 | 脏标记推信号 / 拉数据分离 | ImPlot 面板（waveform.lua 已有 dirty 雏形 :416） | 渲染帧自主决定拉取量，帧率无关 |
| 6 | WaveEdit widgets.cpp:9-40 | 自适应网格：2 的幂步进 ≥22px + 64/8/1 三档线宽 | waveform.lua 网格 + ImPlot 面板 | 缩放跨度大时刻度密度与视觉分级自动正确，优于固定 10×8 |
| 7 | WaveEdit import.cpp:240-252, 35-37 | wheel 缩放吸附 2 的幂 + Zoom Fit | waveform.lua（加缩放时） | 档位手感稳定；与 #6 联动保证刻度是好数 |
| 8 | WaveEdit widgets.cpp:83-155 | 手写控件范式（hover/active ID + 数据域映射 + MouseDelta） | Phase 4 ImPlot 面板自定义交互 | 被动帧率下 ImPlot 内置交互可能迟钝；此为完整可抄样板 |
| 9 | WaveEdit widgets.cpp:504-529 | 多通道分层：非活动通道淡化、活动/悬停通道加粗 | waveform.lua + ImPlot 面板 | 多通道重叠时的视觉分离，成本一行 |
| 10 | WaveEdit main.cpp:120-126 | 不可见不渲染/不取数 | ImPlot 面板（waveform.lua 已有 :479） | 被动驱动下省 CPU |

| # | 来源 | **不采纳** | 理由 |
|---|---|---|---|
| N1 | ImGuiFontStudio FontGenerator.cpp:264-424 | sfntly 表级 TTF 合并 | 离线工具用途；运行时 MergeMode 已覆盖需求 |
| N2 | ImGuiFontStudio 全库 | 动态 glyph 按需加载 | 它没有此模式；ImGui 1.93 无公开增量 atlas API，rebuild 在 16-100ms 帧预算下会卡顿 |
| N3 | ImGuiFontStudio FontInfos.cpp:551-557 | 运行时全量重建字体的交互模式 | 同 N2；我们字体参数启动后不变 |
| N4 | uscope 全库 | Zig 三线程架构 / 通用队列中转数据流 | 作者自评 debugger.zig:751-759 该路径是坑；LuaJIT 单线程 + 专用 ring 更合适 |
| N5 | uscope settings.zig:101 | 8 KB 小环形缓冲容量哲学 | 它只看 stdout 尾部；我们要 65536 点回看 |
| N6 | WaveEdit math.cpp:7-16, 34-45 | pffft / libsamplerate 集成 | 串口示波器暂无频谱与高质量重采样需求 |
| N7 | WaveEdit history.cpp | 时间合并撤销 | 只读回看，无编辑历史需求 |
| N8 | WaveEdit import.cpp:89-92 的"全局定长降采样"作为主渲染路径 | 全量定长预览 | waveform.lua 的可视窗二分裁剪（:127-135, :340-353）粒度更细、已是更优实现；定长摘要仅在需要 minimap 时局部采用 |

### 后续动作建议（优先级）

1. **P1（字体缺口）**：bridge.cpp CJK merge 补 `AddRanges(GetGlyphRangesJapanese())` + 假名 0x3040-0x30FF（SJIS 假名流现在会显示 ?）。#2。
2. **P2（waveform.lua 交互）**：wheel 缩放（2 的幂吸附）+ 自适应网格替换固定 10×8。#6 #7。
3. **P3（Phase 4 面板）**：取数预算 + 脏标记拉取 + 分层通道渲染 + 不可见跳过。#4 #5 #9 #10；若 ImPlot 交互手感差再上 #8。
