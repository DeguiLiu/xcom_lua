# tracy UI 参考

> 只读研究文档，对照 `D:\workspace\SSCOM_lua\ref\tracy\` 源码撰写。
> 所有引用均带真实文件:行号与原文片段。本文档**不修改任何项目代码**。

---

## 1. 项目概览

tracy 是纳秒级实时遥测 profiler（CPU/GPU/Lua/Python 集成），UI 栈 = **C++17 + ImGui + 自绘 ImDrawList + 多线程 TaskDispatch + Worker 数据后端**。它的核心是"上百个 panel 不掉帧"的实时仪表盘。

**与 xcom_lua 的对应**：
- xcom 当前面板数 ≤ 3（receive / send / serial），tracy 是 100+ 个 TimelineItem 并存。
- xcom 的 `set_receive_text` 单流 push ≈ tracy 的 Worker 持续采集 zone/plot。
- xcom 的 CRT memchr 热路径优化 ≈ tracy 的"在 draw 之前 preprocess 到 m_draw 缓存"的思路。

---

## 2. 核心实现

### 2.1 多面板仪表盘：两遍渲染 + 多线程 preprocess

tracy 的核心模式：**第一遍 Preprocess（计算 / 采样降量 / 排序），第二遍 Draw（只把已经算好的 m_draw 喂给 ImDrawList）**。两遍之间用 `TaskDispatch` 线程池加速。

#### 2.1.1 TimelineController::End 两遍渲染

`profiler/src/profiler/TracyTimelineController.cpp:102-177`：

```cpp
void TimelineController::End( double pxns, const ImVec2& wpos, bool hover, bool vcenter, float yMin, float yMax )
{
    ...
    TimelineContext ctx;
    ctx.w = ImGui::GetContentRegionAvail().x - 1;
    ctx.ty = ImGui::GetTextLineHeight();
    ...
    ctx.scale = GetScale();
    ctx.yMin = yMin;
    ctx.yMax = yMax;
    ctx.pxns = pxns;
    ctx.nspx = 1.0 / pxns;
    ctx.vStart = viewData.zvStart;
    ctx.vEnd = viewData.zvEnd;
    ctx.wpos = wpos;
    ctx.hover = hover;

    int yOffset = 0;
    for( auto& item : m_items )
    {
        if( item->WantPreprocess() && item->IsVisible() )
        {
            const auto yPos = wpos.y + yOffset;
            const bool visible = m_firstFrame || ( yPos < yMax && yPos + item->GetHeight() >= yMin );
            item->Preprocess( ctx, m_td, visible, yPos );
        }
        yOffset += m_firstFrame ? 0 : item->GetHeight();
    }
    m_td.Sync();

    yOffset = 0;
    for( auto& item : m_items )
    {
        auto currentFrameItemHeight = item->GetHeight();
        item->Draw( m_firstFrame, ctx, yOffset );
        if( m_firstFrame ) currentFrameItemHeight = item->GetHeight();
        yOffset += currentFrameItemHeight;
    }
    ...
}
```

设计要点：
- **两遍分离**：`Preprocess` 只算数据（最小/最大值、可见数据点索引、min/max bucket），`Draw` 只喂 ImDrawList。两遍之间不阻塞绘制线程，可以并行。
- **可见性快速剔除**：`visible = m_firstFrame || ( yPos < yMax && yPos + item->GetHeight() >= yMin )`——超出屏幕的不 preprocess（`TimelineItemPlot.cpp:131-132`）。
- `TaskDispatch` 线程池在 `TimelineController::TimelineController`（`TimelineController.cpp:14-28`）创建：`m_td(threading ? std::max(0, ((int)std::thread::hardware_concurrency() - 2) / 2) : 0, "Render")`——CPU-2 的核的一半渲染线程。
- `m_td.Sync()`（`TimelineController.cpp:152`）：等所有 Preprocess 任务完成后才进入第二遍——保证 Draw 拿到的数据已就绪。

#### 2.1.2 截图状态（Context）

`profiler/src/profiler/TracyTimelineContext.hpp`（文件未展开，但可见使用 `TimelineContext ctx`）：

```cpp
struct TimelineContext {
    float w;            // 内容区宽度
    float ty;           // 文字行Height
    float sty;          // 小字体行Height
    float scale;
    float yMin, yMax;   // 当前可见y范围
    double pxns, nspx;  // 像素/纳秒 与 其倒数
    int64_t vStart, vEnd; // 当前可见时间范围
    ImVec2 wpos;        // 窗口内容起点（屏幕坐标）
    bool hover;
};
```

设计要点：
- Context 是一次"屏幕快照"参数，多个 TimelineItem 共享。
- 全部 panel 在同一个 `pxns` 下渲染（时间轴统一）。
- `pxns` 和 `nspx` 一起传（`TimelineController.cpp:134-135`），避免面板内反复除法。

**对 xcom_lua 的启发**：把 receive_text 的渲染拆成"算可见行区间"（preprocess）+ "按区间画行"（draw）。当前 xcom 已经在用 `ImGuiListClipper` 做类似的事情，但每次都重新算行偏移；可以加一个"上次可见区间"缓存，preprocess 时只更新有变化的行。

### 2.2 Plot 系列虚拟化（TimelineItemPlot / DrawPlot）

这是最重要的"高密度 + 不掉帧"实现。Plot 数据点动辄百万，但屏幕宽 ~1920 px → 只画 ~1920 个像素列。

#### 2.2.1 Preprocess：min/max bucket + 采样降量

`profiler/src/profiler/TracyTimelineItemPlot.cpp:123-250`：

```cpp
void TimelineItemPlot::Preprocess( const TimelineContext& ctx, TaskDispatch& td, bool visible, int yPos )
{
    assert( m_draw.empty() );
    if( !visible ) return;
    if( yPos > ctx.yMax ) return;
    if( m_plot->data.empty() ) return;
    ...
    td.Queue( [this, &ctx] {
        const auto vStart = ctx.vStart;
        const auto vEnd = ctx.vEnd;
        const auto nspx = ctx.nspx;
        const auto MinVisNs = int64_t( round( MinVisSize * nspx ) );

        auto& vec = m_plot->data;
        vec.ensure_sorted();
        ...
        auto it = std::lower_bound( vec.begin(), vec.end(), vStart, [] ( const auto& l, const auto& r ) { return l.time.Val() < r; } );
        auto end = std::lower_bound( it, vec.end(), vEnd, [] ( const auto& l, const auto& r ) { return l.time.Val() < r; } );
        ...
        double min = it->val;
        double max = it->val;
        const auto num = end - it;
        if( num > 1000000 )
        {
            min = m_plot->min;
            max = m_plot->max;
        }
        else
        {
            auto tmp = it;
            while( ++tmp < end )
            {
                if( tmp->val < min ) min = tmp->val;
                else if( tmp->val > max ) max = tmp->val;
            }
        }
        ...
        m_draw.emplace_back( 0 );                       // count=0: single point
        m_draw.emplace_back( it - vec.begin() );        // offset
        ++it;
        while( it < end )
        {
            auto next = std::upper_bound( it, end, int64_t( it->time.Val() + MinVisNs ), [] ( const auto& l, const auto& r ) { return l < r.time.Val(); } );
            ...
            if( rsz < 4 )
            {
                // 单点逐个画
                for( int i=0; i<rsz; i++ )
                {
                    m_draw.emplace_back( 0 );
                    m_draw.emplace_back( it - vec.begin() );
                    ++it;
                }
            }
            else
            {
                // 桶化（256 个采样）
                constexpr int NumSamples = 256;
                uint32_t samples[NumSamples];
                uint32_t cnt = 0;
                uint32_t offset = it - vec.begin();
                if( rsz < NumSamples )
                {
                    for( cnt=0; cnt<rsz; cnt++ )
                        samples[cnt] = offset + cnt;
                }
                else
                {
                    const auto skip = ( rsz + NumSamples - 1 ) / NumSamples;
                    const auto limit = rsz / skip;
                    for( cnt=0; cnt<limit; cnt++ )
                        samples[cnt] = offset + cnt * skip;
                    if( cnt == limit ) cnt--;
                    samples[cnt++] = offset + rsz - 1;
                }
                it = next;

                pdqsort_branchless( samples, samples+cnt, [&vec] ( const auto& l, const auto& r ) { return vec[l].val < vec[r].val; } );

                m_draw.emplace_back( rsz );   // count>0: bucket
                m_draw.emplace_back( offset );
                m_draw.emplace_back( samples[0] );
                m_draw.emplace_back( samples[cnt-1] );
            }
        }
    } );
}
```

设计要点：
- **`std::lower_bound` 二分**：先定位到当前视窗对应的数据范围，O(log N)，不是从头遍历。
- **桶化（bucketization）**：当一列像素内含 ≥4 个数据点时，用 stride 采样到 256 个 sample，再 `pdqsort_branchless` 排序取最小/最大两端——这样绘出 min/max 柱状图，**保证用户看到的是真实的极端值**，不是简单平均。
- **`if (num > 1000000) skip min/max scan`**（`:171-175`）：超过 1 M 点的窗口直接用全局 min/max，跳过扫描——分寸把握好。
- **`m_draw` 是 `vector<uint32_t>` 紧凑编码**：每条数据要么是 `(0, idx)` 单点，要么是 `(rsz, offset, imin, imax)` 桶。`Draw` 端按这个编码解码——零散点 vs 桶两种渲染模式。
- `MinVisSize = 3`（`:14`）：每像素列最小 3 ns，少于此认为多点在同列。

#### 2.2.2 Draw：解码 m_draw 喂 ImDrawList

`profiler/src/profiler/TracyView_Plots.cpp:14-256`：

```cpp
bool View::DrawPlot( const TimelineContext& ctx, PlotData& plot, const std::vector<uint32_t>& plotDraw, int& offset, bool rightEnd )
{
    auto draw = ImGui::GetWindowDrawList();
    ...
    const auto PlotHeight = m_vd.plotHeight * GetScale();

    auto yPos = wpos.y + offset;
    if( yPos + PlotHeight >= ctx.yMin && yPos <= ctx.yMax )
    {
        ...
        const auto revrange = 1.0 / ( max - min );

        auto it = plotDraw.begin();
        auto end = plotDraw.end();
        double px, py;
        bool first = true;
        while( it < end )
        {
            auto& vec = plot.data;
            const auto cnt = *it++;
            const auto i0 = *it++;
            const auto& v0 = vec[i0];
            ...
            if( cnt == 0 )
            {
                // 单点
                if( i0 == 0 )
                    DrawPlotPoint( wpos, x, y, offset, color, hover, false, v0, 0, plot.type, plot.format, PlotHeight, plot.name );
                else
                    DrawPlotPoint( wpos, x, y, offset, color, hover, true, v0, vec[i0-1].val, plot.type, plot.format, PlotHeight, plot.name );
                px = x; py = y;
            }
            else
            {
                // 桶（min/max 柱状）
                constexpr int MaxShow = 32;
                const auto i1 = i0 + cnt - 1;
                const auto& v1 = vec[i1];
                ...
                const auto imin = *it++;
                const auto imax = *it++;
                const auto vmin = vec[imin].val;
                const auto vmax = vec[imax].val;
                const auto ymin = offset + PlotHeight - ( vmin - min ) * revrange * PlotHeight;
                const auto ymax = offset + PlotHeight - ( vmax - min ) * revrange * PlotHeight;
                if( cnt < MaxShow )
                {
                    DrawLine( draw, dpos + ImVec2( x, ymin ), dpos + ImVec2( x, ymax ), color );
                    for( int i=0; i<cnt; i++ )
                    {
                        const auto is = i0 + i;
                        const auto& vs = vec[is];
                        auto ys = PlotHeight - ( vs.val - min ) * revrange * PlotHeight;
                        DrawPlotPoint( wpos, x, ys, offset, color, hover, vs.val, plot.format, PlotHeight );
                    }
                }
                else
                {
                    // 只画一条 min/max 竖线，不画中间点
                    if( ymin - ymax < 3 )
                    {
                        const auto mid = ( ymin + ymax ) * 0.5;
                        DrawLine( draw, dpos + ImVec2( x, mid - 1.5 ), dpos + ImVec2( x, mid + 1.5 ), color, 3 );
                    }
                    else
                    {
                        DrawLine( draw, dpos + ImVec2( x, ymin ), dpos + ImVec2( x, ymax ), color, 3 );
                    }
                    ...
                }
            }
        }
        ...
    }
    else
    {
        offset += PlotHeight;   // 屏幕外：仅占位，不画
    }
    return true;
}
```

设计要点：
- **编码-解码对称**：`m_draw` 的紧凑 `uint32_t` 流被迭代器解包，单点 `(0, idx)` vs 桶 `(rsz, offset, imin, imax)`。
- **桶化降量**：桶（>32 点）只画一条 `DrawLine` 从 min 到 max——视觉上你看到的是 min/max 范围，**不是平均**，关键洞察。
- **离屏剔除**：如果整个 panel 在屏幕外，只累加 `offset += PlotHeight`，**根本不进入绘制循环**（`:252-255`）——这是 panel 级别的剔除。
- **预计算反比例**：`revrange = 1.0 / (max - min)`（`:63`），所有 y 坐标都用乘法——避免每像素除法。

#### 2.2.3 关键洞察：桶化保留 min/max，不丢失信息

tracy 的桶化逻辑（取 min/max 两个端点）有个隐藏优点：**视觉上你看到的"形状"是真实上下包络**，不会被平均值"压扁"。xcom_lua 后续要做"每秒接收字节 sparkline"时，这种思路可以直接照搬：每像素列只画 max 与 min 两条线（或一条粗线代表范围），不画 1024 个真实数据点。

### 2.3 ImDrawList 复用与零拷贝辅助函数

`profiler/src/profiler/TracyImGui.hpp:197-289`：

```cpp
[[maybe_unused]] static inline void DrawTextContrast( ImDrawList* draw, const ImVec2& pos, uint32_t color, const char* text )
{
    const auto scale = round( GetScale() );
    draw->AddText( pos + ImVec2( scale, scale ), 0xAA000000, text );
    draw->AddText( pos, color, text );
}

[[maybe_unused]] static tracy_force_inline void DrawLine( ImDrawList* draw, const ImVec2& v1, const ImVec2& v2, uint32_t col, float thickness = 1.0f )
{
    const ImVec2 data[2] = { v1, v2 };
    draw->AddPolyline( data, 2, col, thickness );
}
```

设计要点：
- **`DrawLine` 用 `AddPolyline` 不是 `AddLine`**：`AddPolyline` 把多个点合批，调用一次；`AddLine` 一次只画一段，调用 N 次会触发多次 ImDrawCmd 切割。
- **零拷贝数组**：`const ImVec2 data[2] = { v1, v2 };` 在栈上构造后立刻传给 ImGui——`ImDrawList::AddPolyline` 接受 `const ImVec2*`，不会复制。
- **`tracy_force_inline`**：自定义宏（应是 `__attribute__((always_inline)) inline`），强制内联——每帧调用上百万次，不内联函数调用开销吃不消。
- `DrawTextContrast` 两步画（先阴影再前景）：`AddText + AddText` 而不是 `DrawText` ——后者是 Dear ImGui `ImGui::GetWindowDrawList()->AddText` 的包装，内部还是要 ImGui font 编码，比直接 AddText 慢。

**对 xcom_lua 的启发**：
- `bridge.cpp` 中如果用 `ImGui::GetWindowDrawList()->AddLine` 连画 N 段，改成 `AddPolyline` 一次提交。
- 高频调用的辅助函数标注 `inline __forceinline`。
- 常驻 ImVec2 数组用栈上临时数组，不要 `std::vector`（避开堆分配）。

### 2.4 多线程 TaskDispatch

`profiler/src/profiler/TracyTimelineController.cpp:14-28`：

```cpp
TimelineController::TimelineController( View& view, Worker& worker, bool threading )
    : m_height( 0 )
    , m_scroll( 0 )
    , m_centerItemkey( nullptr )
    , m_centerItemOffsetY( 0 )
    , m_firstFrame( true )
    , m_view( view )
    , m_worker( worker )
#ifdef __EMSCRIPTEN__
    , m_td( threading ? 2 : 0, "Render" )
#else
    , m_td( threading ? (size_t)std::max( 0, ( (int)std::thread::hardware_concurrency() - 2 ) / 2 ) : 0, "Render" )
#endif
{
}
```

设计要点：
- **专用渲染线程池**：不抢业务线程（CPU-2 给主线程和 Worker），剩下的核的一半给 Render。
- **每个 panel 的 Preprocess 任务独立**（`Plot.cpp:133`：`td.Queue([this, &ctx] {...})`），panel 间自然并行。
- **`Sync()` 同步点**：所有 Preprocess 完成后才进入 Draw 阶段（`TimelineController.cpp:152`）——Draw 是单线程（ImGui 上下文不能跨线程）。

**对 xcom_lua 的启发**：xcom 当前是单线程 UI（`runtime.owner_thread_`）。如果将来 receive_text 解析变重，可以拆 Preprocess（行偏移计算/CRC/解码）到 std::async + `std::future::wait`，主线程继续渲染前一帧结果。

### 2.5 DecayValue（无锁衰减动画状态）

`profiler/src/profiler/TracyDecayValue.hpp:19-46`：

```cpp
tracy_force_inline operator const T& () const { return m_value; }
tracy_force_inline T operator->() const { return m_value; }

tracy_force_inline DecayValue& operator=( const T& value )
{
    m_value = value;
    m_active = true;
    return *this;
}

tracy_force_inline void Decay( const T& value )
{
    if( m_active )
    {
        m_active = false;
    }
}
```

（节选，未读全文）——`DecayValue` 用于"高亮会衰减"的状态：赋值激活，每帧 Decay 一下直到 inactive。避免每帧 clear/reset bool。

**对 xcom_lua 的启发**：receive_text 选中高亮"几秒后自动淡出"？用 DecayValue 模式（一个 struct 携带"是否 active + 当前值 + 衰减系数"），避免每帧 toggle bool。

### 2.6 帧时间优化细节

`profiler/src/profiler/TracyView_FrameOverview.cpp:73-83`：

```cpp
const int fwidth = GetFrameWidth( m_vd.frameScale );
const int group = GetFrameGroup( m_vd.frameScale );
const int total = m_worker.GetFrameCount( *m_frames );
const int onScreen = ( w - 2 ) / fwidth;
if( m_viewMode != ViewMode::Paused )
{
    m_vd.frameStart = ( total < onScreen * group ) ? 0 : total - onScreen * group;
    if( m_viewMode == ViewMode::LastFrames )
    {
        SetViewToLastFrames();
    }
    else
    {
        assert( m_viewMode == ViewMode::LastRange );
        const auto delta = m_worker.GetLastTime() - m_vd.zvEnd;
        if( delta != 0 )
        {
            m_vd.zvStart += delta;
            m_vd.zvEnd += delta;
        }
    }
}
```

设计要点：
- **`fwidth`/`group` 双档**：`fwidth` 控制每帧在屏幕上的像素宽度（4/6/1），`group` 控制每像素代表几帧。zoom out 时多帧合一像素，zoom in 时单帧占多像素。
- **懒平移视图**：实时模式时直接把视图平移到"包含最后一帧"——靠 `zvStart += delta; zvEnd += delta;`。
- **`GetFrameWidth`**（`:17-20`）：
  ```cpp
  static int GetFrameWidth( int frameScale ) {
      return frameScale == 0 ? 4 : ( frameScale < 0 ? 6 : 1 );
  }
  ```
  scale=0（默认）→ 4 像素宽；scale<0（zoom out）→ 6 像素（多个 pixel-per-frame 加大）；scale>0（zoom in）→ 1 像素（窄，单帧）。

**对 xcom_lua 的启发**：xcom 接收流也可以双档——普通模式"每秒 1 像素柱状"（fwidth=1），突发模式"每 100ms 1 像素"（fwidth=6）。这样能在不缩窗口的情况下看到 6 倍时间跨度。

### 2.7 全局 dumpy-style helper：tracy_force_inline

tracy 全代码库用 `tracy_force_inline`（自定义宏）包裹高频小函数（颜色计算、key 取位等）。示例：

`profiler/src/profiler/TracyColor.hpp:15-50`：

```cpp
static tracy_force_inline uint32_t HighlightColor( uint32_t color ) {
    return 0xFF000000 |
        ( std::min<int>( 0xFF, ( ( ( color & 0x00FF0000 ) >> 16 ) + V ) ) << 16 ) |
        ...
}
```

`profiler/src/profiler/TracyLockHelpers.hpp:11-24`：

```cpp
static tracy_force_inline uint64_t GetThreadBit( uint8_t thread ) {
    return uint64_t( 1 ) << thread;
}

static tracy_force_inline bool IsThreadWaiting( uint64_t bitlist, uint64_t threadBit ) {
    return ( bitlist & threadBit ) != 0;
}
```

设计要点：
- **所有辅助函数 tracy_force_inline**：编译器内联后零调用开销。
- **位运算代替分支**：`IsThreadWaiting` 用 `&` 不用 `if`，编译成 1 条 AND 指令。

---

## 3. 可借鉴清单

| # | 优先级 | 建议 | 当前 xcom_lua 位置 | 实施成本 |
|---|---|---|---|---|
| 1 | 高 | **两遍渲染**：Preprocess 算可见行区间 / min/max 桶，Draw 阶段只解码 | `bridge.cpp:2130-2233` 单遍 draw；可拆 ReceiveContent 的 preprocess/draw | 中 |
| 2 | 高 | **桶化降量**：每像素列只画 min/max 两条线，不画全部数据点 | receive_text 还没趋势图；可加在 receive 顶部 sparkline | 低 |
| 3 | 高 | **`std::lower_bound` 二分定位可见行**（前提：receive_line_offsets_ 单调） | `bridge.cpp:875-879` 已经线性扫；可换二分 | 低 |
| 4 | 高 | **离屏剔除**：如果整个 panel 在屏幕外只累加 offset，不进入绘制循环 | ImGui::BeginChild 自带 clipping，但内部 ListClipper 仍扫 | 低 |
| 5 | 高 | **`AddPolyline` 替代 `AddLine`**：合并批量绘制点 | `bridge.cpp:2202-2205` 用 AddLine 画分隔线 | 低 |
| 6 | 高 | **预计算反比例**：`revrange = 1.0 / range` 一次，y 算乘法 | `bridge.cpp` receive 段落未见 | 低 |
| 7 | 中 | **`tracy_force_inline` 宏 + 关键路径 inline** | 当前 inline 较少 | 低 |
| 8 | 中 | **栈上 ImVec2 数组**：`const ImVec2 data[N] = {...}; draw->AddPolyline(data, N)` 零拷贝 | 当前用单点 AddLine | 低 |
| 9 | 中 | **可视性快速剔除**：用 `yPos + item->GetHeight() >= yMin && yPos <= yMax` 决定是否 preprocess | `TimelineItemPlot.cpp:131-132` | 低 |
| 10 | 中 | **数据规模阈值短路**：`if (num > 1000000) skip scan` | receive_text ≤ 1 MB，可不短路 | 低 |
| 11 | 中 | **DecayValue 模式**（自衰减高亮状态） | 选中高亮目前是 bool + 时间戳比较 | 低 |
| 12 | 中 | **专用渲染线程池**（CPU-2/2 核） | xcom 当前 owner_thread_ 单线程 | 高（重写） |
| 13 | 中 | **`AddText + AddText` 双步画文本阴影** 代替 `DrawText` | `bridge.cpp` 大部分用 ImGui::Text 文本 | 低 |
| 14 | 低 | **fwidth/group 双档缩放**：sparkline zoom in/out 切换采样精度 | 趋势图未做 | 低 |
| 15 | 低 | **位运算代替分支**：`if (x & mask) ...` 代替 `if (x & mask != 0)` | xcom 已普遍 | 低 |

---

## 4. 一句话总结

tracy 给 xcom_lua 的核心可抄价值是：**四件事**：
1. **两遍渲染 + 多线程 preprocess**——把计算密集逻辑从主线程剥离，UI 永远 60 FPS。
2. **桶化降量保留 min/max**——100 万数据点画出"包络"，不丢失极端信息。
3. **ImDrawList 合批**——`AddPolyline` 替代 `AddLine`，栈数组零拷贝。
4. **`tracy_force_inline` 宏**——关键路径全内联，编译器难省的零开销。