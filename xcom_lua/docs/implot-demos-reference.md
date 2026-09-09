# ImPlot 官方演示应用集（epezent/implot_demos）参考 —— 示波器面板专项

> 定位：与 `docs/imgui-patterns-reference.md` 第 7 节**互补**。该节回答"v1.1 头文件里有什么 API"，本文回答"**作者本人怎么把它们拼成完整应用**"。所有内容取自 `D:\workspace\SSCOM_lua\ref\implot_demos\`（官方仓库 epezent/implot_demos，最后提交 2023-08-20 `f33219d`，写作时 ImPlot 为 v0.16/v1.0-dev 时代代码）以及 `D:\workspace\SSCOM_lua\ref\implot\`（v1.1 WIP，2026-08-06）与本项目 `third_party\xcom_imgui\implot\` 的比对结果。
>
> **版本警告**：implot_demos 仓库快照（2023）早于 ImPlot v1.0（2026-02 起 SetNext*Style 全删）。仓库里所有 `SetNextLineStyle/SetNextFillStyle` 调用**照抄必炸**，本文每个摘录都附 v1.1 改写法。

---

## 1. 目录内容速览

```
D:\workspace\SSCOM_lua\ref\implot_demos\
├── demos/            8 个单文件应用（每个是一个 main）
│   ├── demo.cpp        20 行：只调 ImPlot::ShowDemoWindow()（即 implot_demo.cpp 内容入口）
│   ├── filter.cpp     254 行：双通道信号 + IIR 滤波器 + 频域图（**最接近示波器**）
│   ├── voice.cpp       82 行：麦克风采集 + 实时波形（**最小实时绘图样板**）
│   ├── spectrogram.cpp 239 行：音频回放 + 实时瀑布图 + 底部频谱（回看/拖动游标标杆）
│   ├── stocks.cpp     396 行：股票 OHLC + 成交量，Tab 分通道、自定义 PlotOHLC、TagY
│   ├── graph.cpp       93 行：表达式绘图仪（PlotLineG 动态生成 + NoInitialFit 手动限域）
│   ├── maps.cpp       381 行：OpenStreetMap 瓦片地图（线程池后台加载 + PlotImage）
│   ├── mandel.cpp     311 行：Mandelbrot（PlotHeatmap + GetPlotLimits 驱动重算）
│   └── perlin.cpp      67 行：热力图 + CanvasOnly 全屏
├── tests/
│   ├── benchmark.cpp  1029 行：PlotLine/Scatter/Bars/Shaded/自写 Inline 渲染的性能横评
│   ├── gpu.cpp        673 行：**自写 GPU 管线** PlotLineGPU + DrawList 顶点直写 PlotLineMinimal
│   └── plot_line_inline.h 280 行：绕过 ImDrawList 公共 API、手写顶点的两版渲染器
├── common/           App 框架（GLFW+glad 封装）、Profiler、Dracula 配色
└── 3rdparty/         kissfft、miniaudio、exprtk、json、nfd 等
```

定性：**不是 demo 片段集，而是 8 个微型完整应用**。每个 `demos/*.cpp` 都是一个 `main()`，继承 `common/App.h` 的三虚函数框架（`Start()` / `Update()` 每帧 / 析构）。作者即 ImPlot 作者 Evan Pezent，代码代表"官方推荐的完整用法"。

`common/App.h:26-37` 的框架（本项目 bridge 的结构同构）：

```cpp
struct App {
    App(std::string title, int w, int h, int argc, char const *argv[]);
    virtual ~App();
    virtual void Start() { }          // 启动前一次性
    virtual void Update() { }         // 每帧
    void Run();                       // 主循环：glfwPollEvents → NewFrame → Update → Render → Present（App.cpp:291-313）
    ImVec4 ClearColor;  GLFWwindow* Window;  std::map<std::string,ImFont*> Fonts;
};
```

`common/App.cpp:97-115`（`StyeColorsApp`）值得抄的样式技巧——自定义配色后调 `ImPlot::StyleColorsAuto()`（v1.1 中 implot.h:1214，本项目浅色主题同款），再逐项覆盖 Plot 颜色：`ImPlotCol_PlotBg`/`PlotBorder` 设透明融入面板、`ImPlotCol_Crosshairs` 用文本色（App.cpp:99-104）、`DigitalBitHeight = 20`（数字信号台阶高度）。第 113-114 行还有一个 `ImPlot::AddColormap("Dracula", Dracula, 10)` —— 多通道彩色波形可以用**自定义 colormap 数组**喂色，不必每通道手写 ImVec4。

---

## 2. 示波器核心模式（按场景，文件+行号）

### 2.1 最小实时波形：voice.cpp（82 行全览）

`demos/voice.cpp` 是"采集线程推数据 + UI 线程画"的最小完整样例，模式与本项目的"Lua push 数据、bridge 画"完全同构：

```cpp
// voice.cpp:11-23 —— 全局双缓冲 + 互斥锁。音频回调（采集线程）写 buffer1，
// UI 线程整块搬到 buffer2 并清空 buffer1。
std::mutex g_mtx;
std::vector<float> g_buffer1;
std::vector<float> g_buffer2;
void data_callback(ma_device* pDevice, void* pOutput, const float* pInput, ma_uint32 frameCount) {
    std::lock_guard<std::mutex> lock(g_mtx);
    for (ma_uint32 i = 0; i < frameCount; ++i)
        g_buffer1.push_back(pInput[i]);      // 生产者只追加
}
```

```cpp
// voice.cpp:49-67 —— Update()：攒够一批再交换（441 样本 @44.1kHz = 10ms 一批），
// 交换是 O(1) 指针搬移而非逐点拷贝；暂停 = 不交换，绘图侧照常画 buffer2。
void Update() {
    static bool pause = false;
    if (ImGui::IsKeyPressed((ImGuiKey)GLFW_KEY_SPACE)) pause = !pause;
    if (!pause && g_buffer1.size() >= 441) {
        std::lock_guard<std::mutex> lock(g_mtx);
        g_buffer2 = g_buffer1;     // 整块接管
        g_buffer1.clear();
    }
    ImGui::Begin("Test");
    if (ImPlot::BeginPlot("Test",ImVec2(-1,-1))) {
        ImPlot::SetNextLineStyle(ImVec4(1,1,0,1));               // ← v1.1 已删！见 §2.9
        ImPlot::PlotLine("Voice",g_buffer2.data(),g_buffer2.size());  // 单数组版：x=0,1,2,...
        ImPlot::EndPlot();
    }
    ImGui::End();
}
```

**对本项目的启示**：bridge 侧的 `xcom_imgui_scope_push` 收到 Lua 数据点后追加进环形缓冲；绘制帧只读缓冲、绝不搬移。voice.cpp 的"pause = 冻结显示但采集继续"正是示波器的 RUN/STOP 语义，实现方式就是**数据交换与绘制解耦**。它还演示了 PlotLine 的单数组重载（x 自动取 0..N-1，implot.h:991 `values` 版）——均匀采样示波器可以用 `xscale=采样间隔` 直接喂 y 数组，省一半内存与搬运。

### 2.2 追尾与回看：spectrogram.cpp 的"播放头 + 滑动窗口"

spectrogram.cpp 虽是瀑布图，但它的**时间轴窗口管理**就是示波器追尾/回看的教科书实现：

```cpp
// spectrogram.cpp:155-167
const double tmin = (m_duration-T)*(m_time/m_duration);   // 窗口起点 = 播放头等比映射
const double tmax = tmin + T;                             // T = 显示窗口时长(10s)
if (ImPlot::BeginPlot("##Plot1",ImVec2(w,h),ImPlotFlags_NoMouseText)) {
    ImPlot::SetupAxes(NULL,NULL,ImPlotAxisFlags_NoTickLabels,ImPlotAxisFlags_Lock);
    ImPlot::SetupAxisLimits(ImAxis_X1,tmin,tmax,ImGuiCond_Always);  // ← 每帧强制 = 追尾
    ...
    if (ImPlot::DragLineX(838492,&m_time,{1,1,1,1},1,ImPlotDragToolFlags_Delayed))
        seek(m_time);                                      // ← 拖播放头 = 回看任意位置
    ImPlot::EndPlot();
}
```

要点：
- **追尾** = `SetupAxisLimits(..., ImGuiCond_Always)` 每帧重设范围（此处 tmin 随 m_time 增长）。
- **回看** = `ImGui::SliderDouble("##Scrub", &m_time, ...)`（:153）或图内 `DragLineX` 把 m_time 拉回过去；轴范围公式自动跟随，**状态只有一个 m_time，不需要单独的 follow 标志**。
- `ImPlotAxisFlags_Lock`（:160）锁 Y 轴防手滑；`ImPlotDragToolFlags_Delayed`（:165）让游标拖动下一帧才生效，避免当帧限域抖动（v1.1 implot.h:241 注释"applying position-constraints"正是此用途）。
- `seek()`（:221-231）把 UI 时间写回数据源（decoder 定位）——"回看位置"与"数据获取位置"联动。

对本项目：示波器面板状态机可以同样收敛为一个 `view_t_`（窗口右端时间）。追尾时 `view_t_ = 最新样本 t`；用户拖动/框选后停止自动推进（`following_ = false`），点"追上"按钮或双击恢复。比维护 scroll offset 简单得多。

### 2.3 双缓冲换帧率：spectrogram.cpp 的频谱条（CanvasOnly 实战）

```cpp
// spectrogram.cpp:179-203 —— 第二个图是 CanvasOnly：
ImPlot::PushStyleVar(ImPlotStyleVar_PlotMinSize,{0,0});       // 允许压到 0 尺寸（被压缩时）
if (ImPlot::BeginPlot("##Plot2",ImVec2(-1,-1),ImPlotFlags_CanvasOnly)) {
    ImPlot::SetupAxes(NULL,NULL,ImPlotAxisFlags_NoDecorations,ImPlotAxisFlags_NoDecorations);
    ImPlot::SetupAxesLimits(0,1,-1,1,ImGuiCond_Always);       // 归一化坐标，数值全在 getter 里算
    ...
    ImPlot::PlotShadedG("##FreqDomain",getter1,this,getter2,nullptr,N_FRQ);
    ImPlot::SetNextLineStyle(ImPlot::SampleColormap(0.8f));   // ← v1.1 已删；见 §2.9
    ImPlot::PlotLine("##TimeDomain",&m_samples[idx],N_FFT,1.0/(N_FFT-1));  // xscale 均匀采样
    ImPlot::EndPlot();
}
```

**PlotShadedG/PlotLineG 的 getter 回调**（implot.h:993/1016，v1.1 仍在）：数据不必先变换成两个数组，getter 里按需算。本项目若要做"原始字节 → 波形值"的即时变换（如十六进制转电压），getter 版可免掉 C++ 侧临时缓冲。`ImPlot::SampleColormap(t)`（implot.h:1300）从 colormap 取色——多通道可让通道 i 取 `SampleColormap(i/通道数)` 自动获得区分色。

### 2.4 多通道 + 图例 + Y 挡位：filter.cpp（示波器直系模板）

filter.cpp 的主图（时域双通道）正是 pic/3.png 风格的最小骨架：

```cpp
// filter.cpp:115-123
if (ImPlot::BeginPlot("##Filter",ImVec2(-1,-1))) {
    ImPlot::SetupAxes("Time [s]","Signal");
    ImPlot::SetupAxesLimits(0,0.5,-2,2);            // Y 固定挡位（-2..+2V）
    ImPlot::SetupLegend(ImPlotLocation_NorthEast);
    ImPlot::PlotLine("x(t)", t, x, N);              // 通道1：输入信号
    ImPlot::PlotLine("y(t)", t, y, N);              // 通道2：滤波输出
    ImPlot::EndPlot();
}
```

- **Y 固定挡位**：`SetupAxesLimits` 不带 cond 参数（默认 `ImPlotCond_Once`，implot.h:892）只在首帧生效，之后用户可自由缩放；若要"锁死挡位"加 `ImGuiCond_Always`（implot.h:868 注释明言 Always 会 lock）。**自动量程**则给 Y 轴加 `ImPlotAxisFlags_AutoFit`（每帧适配数据范围）或 `RangeFit`（仅适配可见 X 窗内的点，见 stocks.cpp:347）。
- **每帧重算信号**（:105-112）：10000 点 sin 合成每帧全量重算——演示级写法；本项目数据由串口侧推，bridge 零重算。
- 频域图演示 `SetupAxisScale(ImAxis_X1, ImPlotScale_Log10)`（:170）与 `PlotInfLines`（:172，画 -3dB 基准横线，v1.1 需 `ImPlotSpec spec; spec.Flags = ImPlotInfLinesFlags_Horizontal;`）。
- **DragLineX 交互改参**（:177-178）：`if (ImPlot::DragLineX(148884,&Fc[0],col)) filt_need_update = true;` —— 拖截止频率线直接改滤波器参数。**id 用随机大数（148884）避免与其它工具冲突**；测量游标 A/B 同理。
- **Annotation**（:176）：`ImPlot::Annotation(Fc[0],-3,col,ImVec2(5,-5),true,"Half-Power Point")` —— 在数据点上挂标注（v1.1 implot.h:1090）。

### 2.5 游标测量 + Tag + Tab 分通道：stocks.cpp

```cpp
// stocks.cpp:364 —— TagY：在 Y 轴边挂数值标签（无格式的 bool 重载只画 marker）
ImPlot::TagY(close_val, data.open[close_idx] < data.close[close_idx] ? bull_col : bear_col);
```

TagX/TagY（implot.h:1094-1101）是"挡位显示"的现成件：当前值/游标值挂在轴边上，一帧一句。配合 DragLine：拖动时 Tag 跟随（benchmark.cpp:798-799 连用：`DragLineY(0,&sixty,col,1,ImPlotDragToolFlags_NoInputs); ImPlot::TagY(sixty,col,"60");` —— `NoInputs` = 只读参考线，不可拖，正好做"挡位刻度线"）。

**Tab 管通道**（stocks.cpp:340-383）：`ImGui::BeginTabBar("TickerTabs")` 每个 ticker 一个 Tab，Tab 里 `BeginSubplots` 上下两图（OHLC + Volume）：

```cpp
// stocks.cpp:344-345
static float ratios[] = {2,1};
if (ImPlot::BeginSubplots("##Stocks",2,1,ImVec2(-1,-1),ImPlotSubplotFlags_LinkCols,ratios)) {
```

`ImPlotSubplotFlags_LinkCols`（implot.h:208）让上下两子图 X 轴联动——示波器"多通道共享时间轴"直接用它；v1.1 签名 `BeginSubplots(title_id, rows, cols, size, flags, row_ratios, col_ratios)`（implot.h:825-831）。

**自定义图元 PlotOHLC**（stocks.cpp:224-255）是**手工 item 渲染**范本（若本项目以后要画示波器触发标记等自定义图元）：

```cpp
// stocks.cpp:227-254（v1.1 等价改写）
ImDrawList* draw_list = ImPlot::GetPlotDrawList();
if (ImPlot::BeginItem(label_id)) {                          // v1.1: BeginItem(label, spec)（implot_internal.h:1336）
    ImPlot::GetCurrentItem()->Color = ImGui::GetColorU32(bullCol);  // 图例图标色
    if (ImPlot::FitThisFrame())                             // 双击 fit 时纳入计算
        for (...) { ImPlot::FitPoint(ImPlotPoint(x,y)); }   // v1.1: implot_internal.h:1420
    for (...) {  // 逐点 PlotToPixels + draw_list->AddRectFilled/AddLine
        draw_list->AddLine(ImPlot::PlotToPixels(x, y_low), ImPlot::PlotToPixels(x, y_high), col, 1);
    }
    ImPlot::EndItem();
}
```

v1.1 全部仍在（`BeginItem` implot_internal.h:1336、`EndItem` :1351、`FitThisFrame` :1401、`FitPoint` :1420、`GetCurrentItem` :1358、`PlotToPixels` implot.h:1117、`PushPlotClipRect` :1342）。这套 API 走的是 implot_internal.h，需要 `#include <implot_internal.h>`。

**鼠标十字读数 + 高亮列**（stocks.cpp:192-222 `TickerTooltip`）——比 ImPlotFlags_Crosshairs 更进一步的自定义悬停：

```cpp
// stocks.cpp:195-219（关键节选）
const bool hovered = span_subplots ? ImPlot::IsSubplotsHovered() : ImPlot::IsPlotHovered();
if (hovered) {
    ImPlotPoint mouse = ImPlot::GetPlotMousePos();          // 图坐标鼠标位置
    float tool_l = ImPlot::PlotToPixels(mouse.x - half_width, mouse.y).x;
    ...
    ImPlot::PushPlotClipRect();
    draw_list->AddRectFilled(..., IM_COL32(128,128,128,64)); // 半透明高亮列
    ImPlot::PopPlotClipRect();
    int idx = BinarySearch(data.time.data(), 0, data.size()-1, mouse.x); // 二分找样本
    if (ImPlot::IsPlotHovered() && idx != -1) {
        ImGui::BeginTooltip();  ... ImGui::EndTooltip();     // 悬停读数框
    }
}
```

对本项目：`IsPlotHovered() + GetPlotMousePos() + PlotToPixels + PushPlotClipRect` 组合可以做出"悬停列高亮 + 最近样本 tooltip"（示波器逐点读数），全部 v1.1 存活（implot.h:1130/1125/1117/1342）。注意 tooltip 画在 `PopPlotClipRect` 之后才不被裁剪。

### 2.6 手动限域 + getter 动态求值：graph.cpp

```cpp
// graph.cpp:68-82
if (ImPlot::BeginPlot("##Plot",0,0,ImVec2(-1,-1),0,ImPlotAxisFlags_NoInitialFit,ImPlotAxisFlags_NoInitialFit)) {
    limits = ImPlot::GetPlotLimits();               // 先读当前可视范围
    if (valid) {
        ImPlot::PlotLineG("##item",
            [](int idx, void* data) {               // getter 按可视范围实时求值
                auto& self = *(ImGraph*)data;
                double x = remap((double)idx, 0.0, 9999.0, self.limits.X.Min, self.limits.X.Max);
                double y = self.expr.eval(x);
                return ImPlotPoint(x,y);
            }, this, 10000);
    }
    ImPlot::EndPlot();
}
```

`ImPlotAxisFlags_NoInitialFit`（implot.h:181）禁止首帧自动 fit——配合"getter 只在当前可视 X 范围内取 10000 个采样点"，是**海量数据按需重采样**的最廉价方案。对本项目回看模式（缓冲 100 万点只画可见段）可直接套：用 `GetPlotLimits()`（implot.h:1127）拿到可视 X 范围，二分定位到缓冲区段，只 Plot 该段。

### 2.7 线程池后台供数：maps.cpp（多窗口/资源管理参考）

maps.cpp 的 TileManager（:115-314）是"**UI 线程请求 → 工作线程下载 → 完成后 UI 消费**"的完整样板：`std::queue + condition_variable + 2 个工作线程`（:236-300），状态机 `Unavailable/Downloading/OnDisk/Loaded`（:89-94），UI 侧 `request_tile`（:156-165）查缓存→查磁盘→入队，帧内只画 `state == Loaded` 的瓦片（:352-363）。对本项目"后台文件回放历史波形"可参考，但示波器主路径（串口实时数据）不需要。

多窗口组织：所有 demo 都是**单 ImGui 窗口铺满 + 窗口内 child/Tab 分区**（无 docking），与本项目 dashboard 结构一致。工具栏都是 `Begin` 后第一行的 `Button/SameLine` 紧凑排列（spectrogram.cpp:140-154：播放/暂停、跳头、跳尾、Scrub 滑条）。

### 2.8 性能：benchmark.cpp / gpu.cpp / plot_line_inline.h

**a) 帧预算实测结论（benchmark.cpp）**：
- 基准平台：`ImPlotFlags_CanvasOnly + ImPlotAxisFlags_NoDecorations`，锁死轴范围 `ImGuiCond_Always`（:672-675）——**纯渲染基准排除了 fit/交互噪声**。
- 变量矩阵（:64-84）：类型 int/float/double/ImVec2/ImPlotPoint × 点数 100-5000/项 × 项数递增到 500 项 × 抗锯齿开关。测量方式：`ScopedProfiler` 计 PlotLine 调用耗时（:49-62）+ 帧时间 + FPS，60 帧一档记录（:559-585）。
- **对抗锯齿的开关操作**（:670）：`GImGui->Style.AntiAliasedLines = GImGui->Style.AntiAliasedLinesUseTex = working_aa;` —— 本项目 WARP 软渲染下若帧率不足，这是第一个该试的开关（v1.93 imgui.h:2466-2467 两字段仍在）。

**b) 数据布局**：`PlotLine(n, &vs[0].x, &vs[0].y, k, 0, 0, sizeof(ImVec2))`（benchmark.cpp:296-297）——**x/y 交错单缓冲 + Stride** 是 v1.0 前的写法；v1.1 中 Stride 并入 ImPlotSpec（`spec.Stride = sizeof(ImVec2)`，implot.h:533），且自动推导：传 `sizeof(T)` 之外的值才需要显式设。x/y 双平面数组（filter.cpp 的 t[]/x[]）与 ImVec2 交错数组（官方 ScrollingBuffer）都常见，交错省一次缓存流。

**c) 绕过公共 API 的极限优化**（plot_line_inline.h / gpu.cpp）——知道存在即可，本项目用不到：
- `PlotLineInline`（plot_line_inline.h:24-99）：`BeginItem` 后手取 `Axes[ImAxis_X1].ScaleToPixel/PixelMin/Range.Min` 直乘坐标，`DrawList.PrimReserve` + 手写 `_VtxWritePtr/_IdxWritePtr`，比公共 PlotLine 少一层 getter 间接；还做了**逐段 cull**（:58-62，`cull_rect.Overlaps` 判矩形可见性 + `PrimUnreserve` 回收）。
- `PlotLineStaged`（:102-177）：先整段坐标变换进静态数组，再统一写顶点。
- `PlotLineGPU`（gpu.cpp:189-215）：`DrawList.AddCallback` 注入 OpenGL 命令，顶点走独立 VBO。**DX11 后端不可用**，且依赖 implot_internal.h 私有结构。

**对本项目的性能结论**（结合 benchmark 的量级：500k 点/帧仍可跑）：
1. 示波器典型规模（2-8 通道 × 2000-10000 点/通道）远在 ImPlot 舒适区，**不需要任何自定义渲染**。
2. 环形缓冲 + `spec.Offset`（implot.h:532，内部 `IndexData` 做 `(offset+idx)%count` 取模环形寻址，implot_items.cpp:509-518，`offset==0&&stride==sizeof(T)` 有免取模快路径 case 3）——**零重排**。
3. 追尾模式锁 `SetupAxesLimits(...,ImGuiCond_Always)`，避免每帧 AutoFit 重扫数据。
4. 帧间隔 16-100ms（WARP）下，瓶颈在 ImGui 全家桶绘制而非 PlotLine；8 通道×万点没问题，必要时关 `Style.AntiAliasedLines`。

### 2.9 v1.0 删掉的 API 与 v1.1 改写对照（照抄 implot_demos 必炸清单）

| implot_demos 旧写法（文件:行） | v1.1 正确写法（本项目 implot.h 行号） |
|---|---|
| `ImPlot::SetNextLineStyle(col)` / `(col, weight)`（graph.cpp:71、spectrogram.cpp:199、voice.cpp:62、benchmark.cpp:207 等） | `ImPlotSpec spec; spec.LineColor = col; spec.LineWeight = w;` 或内联 `ImPlotSpec(ImPlotProp_LineColor, col, ImPlotProp_LineWeight, w)`（517-606，构造/SetProp 重载 538-551） |
| `ImPlot::SetNextFillStyle(col, alpha)`（filter.cpp:173、stocks.cpp:352、spectrogram.cpp:197） | `ImPlotSpec spec(ImPlotProp_FillColor, col, ImPlotProp_FillAlpha, alpha);`（FillColor :521 / FillAlpha :523） |
| `ImPlot::SetNextMarkerStyle(marker, size, fill, weight, outline)`（benchmark.cpp:305） | `spec.Marker/MarkerSize/MarkerFillColor/LineWeight/MarkerLineColor`（:524-529）；`ImPlotSpec(ImPlotProp_Marker, ImPlotMarker_Square, ImPlotProp_MarkerSize, 2)` |
| `PlotLine(n, xs, ys, k, 0, 0, sizeof(ImVec2))` offset/stride 裸参（benchmark.cpp:296-297、gpu.cpp:634） | offset/stride 并入 spec：`ImPlotSpec spec; spec.Offset = o; spec.Stride = sizeof(ImVec2);`（:532-533） |
| `BeginPlot(title, x_label, y_label, size, flags, x_flags, y_flags, ...)` 旧多参（gpu.cpp:459、586） | v1.1 `BeginPlot(title_id, size, flags)` 三参（:769）；轴标签/flags 全走 `SetupAxis/SetupAxes`（:867/:890） |
| `ImPlotFlags_NoChild`（gpu.cpp:459/553/579） | 已删；v1.1 用 `ImPlotFlags_NoFrame`（:168）或默认 |
| `BeginPlot` 第 3 参起的 y2/y3 轴开关（gpu.cpp:586 `"FPS (Hz)"` 尾参） | v1.1 辅助轴：`SetupAxis(ImAxis_Y2, "FPS", ImPlotAxisFlags_Opposite)` 按需启用（benchmark.cpp:753 同款，v1.1 存活） |
| `SetAxis` 旧语义 | v1.1 仍在 `SetAxis(ImAxis)`（:1108），作用"后续 item 画到指定轴" |

v1.1 仍在、可放心用的（本文已核对行号）：`SetupAxes/SetupAxisLimits/SetupAxesLimits/SetupLegend/SetupFinish`（890/869/892/895/901）、`SetupAxisFormat`（873/875）、`SetupAxisTicks`（877/879）、`SetupAxisScale`（881）、`SetupAxisLimitsConstraints`（885）、`SetNextAxesLimits`（934，可绕过 Setup 锁定顺序限制）、`DragLineX/Y/DragPoint/DragRect`（1082/1084/1080/1086）、`TagX/TagY`（1094-1101）、`Annotation`（1089-1090）、`PlotText`（1064）、`PlotLineG/PlotShadedG`（993/1016）、`BeginSubplots`（825）、`PushPlotClipRect/GetPlotDrawList`（1342/1340）、`ColormapScale`（1303）、`SampleColormap/NextColormapColor`（1300/1290）、`GetInputMap`（1323）、`PushStyleVar`（1233-1237）、`StyleColorsAuto`（1214）。

**双击 fit**：内建于 InputMap（implot.h:699-713，`Fit = LMB 双击`），无 API 可调，只可改 `GetInputMap()`。**注意**：`SetupAxisLimits(...,ImGuiCond_Always)` 会永久锁轴，用户双击 fit 无效——追尾模式下"想允许用户双击恢复自动"就不能用 Always，需改用"每帧条件性 SetupAxisLimits(ImGuiCond_None)"或在软件层检测（本项目骨架采用后者，见 §3 注）。

---

## 3. 适配本项目的示波器面板骨架

设计约束（与既有文档第 0/7 节一致）：
- bridge 被动驱动：Lua 每 16/100/500ms 一帧；**数据由 Lua push 进 C++，bridge 只画**（voice.cpp 模式）。
- 状态全挂 `ImGuiRuntime`，禁止函数级 static 缓存 Lua 指针（draw_console 的 ComboSpec 纪律，bridge.cpp:146-151 注释）。
- ImPlot 静态链入 xcom_imgui.dll：CMakeLists.txt `add_library` 追加 `${IMPLOT_ROOT}/implot.cpp、implot_items.cpp`（`native\xcom_imgui\CMakeLists.txt:12-20`），include 目录加 `third_party/xcom_imgui/implot`；`xcom_imgui_init` 在 `ImGui::CreateContext()`（当前约 :2047）后加 `ImPlot::CreateContext()` + `ImPlot::StyleColorsAuto()`，`shutdown_impl()`（当前约 :1912-1918）在 `ImGui::DestroyContext()` 前加 `ImPlot::DestroyContext()`。
- 行号说明：bridge.cpp 处于活跃开发中（本文核查期间 1836→2371 行），**引用一律以符号名定位**。

### 3.1 C++ 侧（追加进 xcom_imgui_bridge.cpp）

```cpp
#include "implot.h"   // 顶部 include 区（windows.h 之后）

// ---- ImGuiRuntime 新增成员（class ImGuiRuntime final 内，约 :96-188） ----
struct ScopeChannel {                      // 官方 ScrollingBuffer 的通道化封装
    static constexpr int kMaxPoints = 20000;   // ~200s @100Hz；WARP 预算内
    float xs[kMaxPoints]{};                     // 时间轴（秒）
    float ys[kMaxPoints]{};                     // 测量值
    int   count = 0;                            // 有效点数（未满 kMaxPoints 时 < kMaxPoints）
    int   offset = 0;                           // 环形写指针（满后指向最老样本）
    bool  visible = true;
    void Push(float t, float v) {               // 供 xcom_imgui_scope_push 调用
        if (count < kMaxPoints) { xs[count] = t; ys[count] = v; ++count; }
        else { xs[offset] = t; ys[offset] = v; offset = (offset + 1) % kMaxPoints; }
    }
};
static_assert(sizeof(ScopeChannel) < 1u << 20, "keep WARP frame budget sane");
ScopeChannel scope_ch_[8]{};        // 8 通道，够用；通道名由 Lua 侧维护
char    scope_names_[8][16]{};      // "CH1".."CH8" 或 Lua 命名
int     scope_channels_ = 0;        // 激活通道数（Lua set 后生效）
double  scope_last_t_ = 0.0;        // 最新样本时间（追尾右端）
float   scope_history_ = 10.0f;     // 追尾窗口宽度（秒）
bool    scope_follow_ = true;       // 追尾 / 回看
double  scope_view_max_ = 0.0;      // 回看模式下的窗口右端
float   scope_y_min_ = -2.0f, scope_y_max_ = 2.0f;   // Y 固定挡位
bool    scope_y_auto_ = false;      // Y 自动量程挡
double  scope_cursor_a_ = 0.0, scope_cursor_b_ = 0.0; // 游标 A/B（图坐标）
bool    scope_cursor_a_on_ = false, scope_cursor_b_on_ = false;
bool    scope_running_ = true;      // RUN/STOP（voice.cpp 的 pause 语义）

// ---- 新导出（追加到文件尾部导出区） ----
extern "C" __declspec(dllexport) void xcom_imgui_scope_configure(
    int channels, const char* const* names) {
    auto& rt = ImGuiRuntime::instance();
    if (!rt.initialized_ || channels <= 0 || channels > 8 || !names) return;
    rt.scope_channels_ = channels;
    for (int i = 0; i < channels; ++i)
        snprintf(rt.scope_names_[i], sizeof(rt.scope_names_[i]),
                 "%s", names[i] ? names[i] : "");
}

extern "C" __declspec(dllexport) void xcom_imgui_scope_push(
    int channel, double t, double v) {
    auto& rt = ImGuiRuntime::instance();
    if (!rt.initialized_ || channel < 0 || channel >= rt.scope_channels_) return;
    if (rt.scope_running_)                       // STOP 时数据照收照弃——
        rt.scope_ch_[channel].Push((float)t, (float)v);  // 与 voice.cpp 不同：直接丢，
    if (t > rt.scope_last_t_) rt.scope_last_t_ = t;      // 无双缓冲必要（Lua 单线程喂点）
}

extern "C" __declspec(dllexport) void xcom_imgui_scope_clear() {
    auto& rt = ImGuiRuntime::instance();
    if (!rt.initialized_) return;
    for (auto& ch : rt.scope_ch_) { ch.count = 0; ch.offset = 0; }
    rt.scope_last_t_ = 0.0; rt.scope_view_max_ = 0.0;
}

// ---- 绘制（namespace ui 内，仿 ReceiveContent；由 draw_console 的 monitor
//      Panel 块内调用，或独立浮窗——仿 ScriptConsole 浮窗模式） ----
[[nodiscard]] int ScopeContent() {
    auto& rt = ImGuiRuntime::instance();
    int actions = 0;
    if (rt.scope_channels_ == 0) return actions;

    // 工具行：RUN/STOP、追尾/回看、窗口宽度、Y 挡位、清屏（spectrogram.cpp:140-154 式）
    if (ImGui::Button(rt.scope_running_ ? "STOP" : "RUN")) rt.scope_running_ = !rt.scope_running_;
    ImGui::SameLine();
    if (ImGui::Button(rt.scope_follow_ ? "Follow" : "Paused")) rt.scope_follow_ = !rt.scope_follow_;
    ImGui::SameLine(); ImGui::SetNextItemWidth(90);
    ImGui::SliderFloat("##hist", &rt.scope_history_, 1.0f, 60.0f, "%.1fs");
    ImGui::SameLine(); ImGui::Checkbox("Y auto", &rt.scope_y_auto_);
    if (!rt.scope_y_auto_) {
        ImGui::SameLine(); ImGui::SetNextItemWidth(70);
        ImGui::DragFloatRange2("##yrange", &rt.scope_y_min_, &rt.scope_y_max_, 0.1f, -1e6f, 1e6f);
    }
    ImGui::SameLine();
    if (ImGui::Button("Clear")) { rt.scope_clear_requested_ = true; actions |= 1 << 29; }

    const float plot_h = ImGui::GetContentRegionAvail().y;
    if (ImPlot::BeginPlot("##scope", ImVec2(-1, plot_h),
                          ImPlotFlags_Crosshairs | ImPlotFlags_NoMenus | ImPlotFlags_NoBoxSelect)) {
        ImPlot::SetupAxes(nullptr, nullptr, ImPlotAxisFlags_NoTickLabels,
                                          ImPlotAxisFlags_NoTickLabels);
        ImPlot::SetupAxisFormat(ImAxis_X1, "%.1fs");     // 或自定义 formatter 打 HH:MM:SS
        ImPlot::SetupLegend(ImPlotLocation_NorthEast, ImPlotLegendFlags_Horizontal);

        // ---- X 轴：追尾 vs 回看（spectrogram.cpp:155-161 模式） ----
        if (rt.scope_follow_) {
            rt.scope_view_max_ = rt.scope_last_t_;
            ImPlot::SetupAxisLimits(ImAxis_X1, rt.scope_view_max_ - rt.scope_history_,
                                    rt.scope_view_max_, ImGuiCond_Always);
        } else {
            // 回看：不传 Always，让用户自由平移/缩放；但需先播种一次范围。
            // 检测"离开回看"的朴素法：跟踪上帧范围，若用户拖动则不覆盖（graph.cpp:69 读回）。
            ImPlotRect lims = ImPlot::GetPlotLimits();
            static double seeded = -1e30;   // OK：double 字面量缓存，非 Lua 指针
            if (seeded != rt.scope_view_max_) {          // 进入回看的第一帧播种
                ImPlot::SetupAxisLimits(ImAxis_X1, rt.scope_view_max_ - rt.scope_history_,
                                        rt.scope_view_max_, ImGuiCond_None);
                seeded = rt.scope_view_max_;
            }
            (void)lims;
        }

        // ---- Y 轴：固定挡位 vs 自动量程（filter.cpp:117 vs stocks.cpp:347） ----
        if (rt.scope_y_auto_)
            ImPlot::SetupAxis(ImAxis_Y1, nullptr, ImPlotAxisFlags_AutoFit);
        else
            ImPlot::SetupAxisLimits(ImAxis_Y1, rt.scope_y_min_, rt.scope_y_max_);

        // ---- 多通道 + 环形缓冲零重排（官方 Demo_RealtimePlots 模式） ----
        for (int i = 0; i < rt.scope_channels_; ++i) {
            const auto& ch = rt.scope_ch_[i];
            if (!ch.visible || ch.count < 2) continue;
            ImPlotSpec spec;
            spec.Offset = ch.offset;            // 环形起点，内部取模（implot_items.cpp:513）
            spec.LineWeight = 1.5f;
            spec.LineColor = ImPlot::SampleColormap(   // colormap 自动分配通道色
                rt.scope_channels_ > 1 ? (float)i / (rt.scope_channels_ - 1) : 0.0f);
            ImPlot::PlotLine(rt.scope_names_[i][0] ? rt.scope_names_[i] : "CH",
                             ch.xs, ch.ys, ch.count, spec);
        }

        // ---- 游标 A/B 测量（filter.cpp:177 DragLineX + stocks.cpp:364 TagX） ----
        if (rt.scope_cursor_a_on_) {
            ImPlot::DragLineX(1, &rt.scope_cursor_a_, ImVec4(1, 0.35f, 0.35f, 1), 1,
                              ImPlotDragToolFlags_NoFit);
            ImPlot::TagX(rt.scope_cursor_a_, ImVec4(1, 0.35f, 0.35f, 1), "A %.3f",
                         rt.scope_cursor_a_);
        }
        if (rt.scope_cursor_b_on_) {
            ImPlot::DragLineX(2, &rt.scope_cursor_b_, ImVec4(0.35f, 0.6f, 1.0f, 1), 1,
                              ImPlotDragToolFlags_NoFit);
            ImPlot::TagX(rt.scope_cursor_b_, ImVec4(0.35f, 0.6f, 1.0f, 1), "B %.3f",
                         rt.scope_cursor_b_);
        }
        if (rt.scope_cursor_a_on_ && rt.scope_cursor_b_on_)
            ImPlot::TagX((rt.scope_cursor_a_ + rt.scope_cursor_b_) * 0.5,
                         ImVec4(0.6f, 0.6f, 0.6f, 1), "dt %.4f",
                         rt.scope_cursor_b_ - rt.scope_cursor_a_);   // A/B 差值即挡位读数

        // ---- 悬停逐点读数（stocks.cpp:195-219 简化版） ----
        if (ImPlot::IsPlotHovered()) {
            ImPlotPoint mp = ImPlot::GetPlotMousePos();
            ImPlot::Annotation(mp.x, mp.y, ImVec4(1, 1, 0, 0.9f), ImVec2(10, -10), true,
                               "%.4f V", mp.y);
        }
        ImPlot::EndPlot();
    }
    return actions;
}
```

接线：`draw_console` 的 `ui::Panel("##monitor_column", ...)` 块内（当前约 :2173-2189），`ReceiveContent(...)` 之后加 `actions |= ui::ScopeContent();`（示波器占据 monitor 列上半区时，把 ReceiveContent 的 child 高度改为 `ImVec2(0, -scope_h)`）。

### 3.2 Lua 侧（ui/imgui_bridge.lua 追加）

```lua
-- ffi.cdef 追加（imgui_bridge.lua:3-36 块内）：
-- void xcom_imgui_scope_configure(int channels, const char* const* names);
-- void xcom_imgui_scope_push(int channel, double t, double v);
-- void xcom_imgui_scope_clear(void);

-- 通道配置（一次）：
function M:scope_configure(names)
    local fn = optional_export("xcom_imgui_scope_configure")
    if not fn or #names == 0 then return end
    local arr = ffi.new("const char*[?]", #names)
    for i, name in ipairs(names) do arr[i - 1] = name end
    fn(#names, arr)
end

-- 数据推送：串口接收回调里解析出数值后（示例：收到 "v=3.14\n" 就推一点）。
-- 关键：帧间隔 100ms ≠ 采样间隔，时间戳必须来自数据/采集时刻（如 uv.now()/1000），
-- 绝不能用 ImGui DeltaTime 累加（idle 500ms 档会欠采样，见 window.lua:1122-1129 注释）。
function M:scope_push(channel, t, v)
    local fn = optional_export("xcom_imgui_scope_push")
    if fn then fn(channel, t, v) end
end
```

数据入口（window.lua 的接收路径）：在 receive chunk 处理处按行正则匹配数值模式，每命中一次调 `self.imgui:scope_push(ch, uv.now() / 1000, value)` 并 `self:request_frame(FRAME_INTERVAL_DATA_MS)` 保持 100ms 绘制节奏。暂停显示时照推不误（C++ 侧 STOP 只影响缓冲写入与追尾推进，天然实现 RUN/STOP）。

### 3.3 与 pic/3.png 的功能对照

| pic/3.png 特征 | 骨架落点 |
|---|---|
| 多通道彩色波形 | 8×ScopeChannel + SampleColormap 通道色 |
| 网格 | 默认 GridLines（浅色主题下 StyleColorsAuto 自动适配） |
| 回看 | scope_follow_ = false + 用户拖动；双击 fit 内建（InputMap.Fit） |
| 游标 A/B 测量 | DragLineX ×2 + TagX 读数 + dt 差值 Tag |
| 挡位显示（如 2V/div） | scope_y_min/max_ + DragFloatRange2；TagY 可加当前值标记 |
| RUN/STOP | scope_running_（voice.cpp pause 模式） |

---

## 4. 与 docs/imgui-patterns-reference.md 的分工

- 该文档第 7 节已有：implot.h API 速查表、ImPlotSpec 结构释义、Demo_RealtimePlots 三要素、flags 初步建议、集成步骤、最小骨架。
- 本文新增（该目录独有发现）：
  1. **voice.cpp 双缓冲 + RUN/STOP 语义**（§2.1）——数据/显示解耦的最小样板；
  2. **spectrogram.cpp 的 view_t 单状态追尾/回看模型**（§2.2）——比"follow 标志 + scroll offset"更简；
  3. **TagX/TagY + NoInputs 参考线 + A/B 差值读数**（§2.5、§3.1）——挡位/游标测量组合拳；
  4. ** stocks.cpp PlotOHLC 自定义图元套路**（BeginItem/FitThisFrame/PlotToPixels，v1.1 行号已核对到 implot_internal.h）——将来画触发线/自定义图元的路径；
  5. **graph.cpp NoInitialFit + 可视范围 getter 重采样**（§2.6）——百万点回看的廉价方案；
  6. **benchmark.cpp 的实测方法学与 AA 开关**（§2.8）——WARP 帧预算吃紧时的第一手段；
  7. **完整的新旧 API 炸点对照表**（§2.9）——implot_demos 源码每处旧调用的 v1.1 改写；
  8. **App.cpp 样式技巧**：StyleColorsAuto 后逐项覆盖、透明 PlotBg/PlotBorder、AddColormap 自定义通道色板、DigitalBitHeight。
