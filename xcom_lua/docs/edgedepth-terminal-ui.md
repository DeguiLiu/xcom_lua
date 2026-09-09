# edgedepth-terminal 参考调研

> 路径：`D:\workspace\SSCOM_lua\ref\edgedepth-terminal\`
> 仓库：<https://github.com/edgedepthhq/edgedepth-terminal>
> 调研日期：2026-09-05

## 1. 项目概览

edgedepth-terminal 是订单流交易终端的**开源参考实现**（商业产品的开源版），技术栈 **C++20 + Dear ImGui + ImPlot + SDL3 + WebGL2**，编译到 WebAssembly 在浏览器内运行，60 FPS 多面板仪表盘。它处理「实时高吞吐数据流 → DOM tape + ImPlot 图表」的链路，与 xcom_lua 的「串口字节流 → 实时接收面板」场景在「数据连续到达 + 多面板共享同一份状态」这一点上**几乎同构**，是 4 个参考项目中最直接对标的一个。

**栈对应关系**：

| edgedepth-terminal | xcom_lua 对应位置 |
|---|---|
| `src/ui/*.cpp` widgets（DOM/trades/orderbook/chart） | `native/xcom_imgui/xcom_imgui_bridge.cpp` ReceiveContent/TransmitContent |
| `src/core/orderbook_manager.h` 双缓冲 OrderbookManager | `runtime.receive_text_` + `receive_line_offsets_` |
| `src/core/dispatch_drain.h` 3 ms 时间预算的回调队列 | xcom_lua bridge 现在每帧无条件渲染，无预算 |
| `src/ui/trades_widget.cpp` tape（最像 xcom_lua 接收区） | ReceiveContent 行渲染 |
| `src/ui/dom_widget.cpp` 滚动 + 选中高亮 + cache | ReceiveContent clipper + sel |
| `src/ui/custom_implot.cpp` ImPlot 包裹 | `core/waveform.lua` GDI 示波器（Phase 4 计划 ImPlot 化） |

## 2. 核心实现

### 2.1 「tape」模式 = 滚动只追加 + 表头冻结 + 方向着色

**文件**：`src/ui/trades_widget.cpp`
**关键函数**：`TradesWidget::render_table`（行 165-214）+ `render_trade_row`（行 216-248）

```cpp
// src/ui/trades_widget.cpp:165-214
// .tape-* - mono numerics, hairline-free dense rows, micro-label header
ImGui::PushFont(Theme::Fonts::mono_sm());
const float row_h = 18.0f;
const float pad_y = std::max(0.0f, (row_h - ImGui::GetFontSize()) * 0.5f);
ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(8.0f, pad_y));

const ImGuiTableFlags flags = ImGuiTableFlags_ScrollY;
if (!ImGui::BeginTable("TradesTable", 3, flags)) { ... }

ImGui::TableSetupColumn("PRICE", ImGuiTableColumnFlags_WidthStretch, 1.0f);
ImGui::TableSetupColumn("QTY",   ImGuiTableColumnFlags_WidthStretch, 1.0f);
ImGui::TableSetupColumn("TIME",  ImGuiTableColumnFlags_WidthFixed, 72.0f);
ImGui::TableSetupScrollFreeze(0, 1);  // 冻结表头行
// ... 行渲染（最 newest 在最上）
```

**设计要点**：
- **新数据永远在最上面**——不滚动而是倒序输出（行 204-209：`for (size_t i = 0; i < display_count; ++i) idx = (trade_count_ - 1 - i) % MAX_TRADES;`），完美匹配「follow-tail」语义：用户视角里最新行直接出现在表头下，不依赖 ScrollHereY。
- **`TableSetupScrollFreeze(0, 1)`**——这是 xcom_lua ReceiveContent 没有的关键能力：滚动行时表头固定，使密集数据流可读性提升一个量级。
- **`mono_sm()` 字体 + CellPadding 8×pad_y**——视觉密度（18 px 行高）和专业感来自这两个细节：等宽字体保证列对齐，按行高反推 padding 让字距行距都收得紧。
- **格式化在 insert 时一次性 snprintf**（行 61-64），运行期渲染零字符串分配。

### 2.2 「cache-on-input, paint-on-frame」模型（DOM widget 的关键性能模式）

**文件**：`src/ui/dom_widget.cpp`
**关键函数**：`DOMWidget::update`（行 147-194）+ `DOMWidget::build_row_models`（行 235-310）

```cpp
// src/ui/dom_widget.cpp:176-193
// Rebuild the row models ONLY when an input actually changed - the book
// read-buffer moves at server cadence, not at render FPS.
if (ob->timestamp_ms != cache_ob_ts_ ||
    ob->last_update_id != cache_ob_uid_ ||
    trade_accumulator_.revision() != cache_acc_rev_ ||
    ladder_center_ != cache_center_ ||
    scroll_offset_ != cache_scroll_ ||
    group_mult_ != cache_group_ ||
    display_usd_ != cache_usd_ ||
    show_trade_columns_ != cache_trade_cols_) {
    cache_ob_ts_      = ob->timestamp_ms;
    cache_ob_uid_     = ob->last_update_id;
    // ... 8 个 cache_* 字段全部保存
    build_row_models(*ob);  // ← 真正干活的格式化 + 查询
}
// render_ladder() 每帧都跑，但只读 cache，无格式化、无 lookup
```

```cpp
// src/core/double_buffer.h:47-53
// A clean buffer is skipped WITHOUT taking the lock, so an idle symbol never
// contends with the data thread.
bool publish() {
    if (!dirty.load(std::memory_order_relaxed)) return false;
    std::lock_guard<std::mutex> lock(write_mutex);
    read_buf = write_buf;
    dirty.store(false, std::memory_order_relaxed);
    return true;
}
```

**设计要点**：
- **dirty 标志 + 单原子 std::atomic<bool>**——只在源真变化时执行昂贵的格式化/查询；稳态零成本；锁只在 dirty 时短促持有。
- **publish() 在每帧开头跑一次**（不是指针交换，是 copy）——`orderbook_manager.cpp` 注释说得很清楚（行 35-40）：拷贝 1000-level orderbook ~50us，换来的是「widget 在整帧内看到一致的快照」，避免了 WS 回调下一帧才到来却影响当前帧渲染的撕裂问题。
- 这跟咱 `MEMORY.md` 里 receive hot path 优化是**同一思想的不同切面**：xcom_lua 优化的是「行渲染的 glyph_w 测量、ascii_only 路径」；edgedepth 优化的是「模型构建 vs 模型绘制分层」。可以同时借鉴。

### 2.3 时间预算的回调排空（DispatchQueue 模式）

**文件**：`src/core/dispatch_drain.h`
**关键函数**：`dispatch_drain::run`（行 47-78）+ `DataThread::drain_dispatches`（`src/core/data_thread.cpp:84-103`）

```cpp
// src/core/dispatch_drain.h:34-78
inline constexpr std::size_t kBudgetCheckStride = 16;

template <typename Item, typename Refill, typename Execute, typename NowMs>
std::size_t run(std::vector<Item>& carry, std::size_t& carry_pos, double budget_ms,
                Refill&& refill, Execute&& execute, NowMs&& now_ms) {
    if (carry_pos >= carry.size()) {
        carry.clear(); carry_pos = 0;
        refill(carry);          // ← 上一批跑完才补货，保证顺序
    }
    if (carry_pos >= carry.size()) { carry.clear(); carry_pos = 0; return 0; }

    const double t0 = now_ms();
    std::size_t executed = 0;
    while (carry_pos < carry.size()) {
        execute(carry[carry_pos++]);
        ++executed;
        if (budget_ms > 0.0 && (executed % kBudgetCheckStride) == 0) {
            if (now_ms() - t0 >= budget_ms) break;  // ← 每 16 次检查一次钟，省 syscall
        }
    }
    if (carry_pos >= carry.size()) { carry.clear(); carry_pos = 0; }
    return executed;
}
```

```cpp
// src/core/data_thread.cpp:84-99 (caller)
const size_t executed = dispatch_drain::run(
    carry_, carry_pos_, budget_ms,
    [this](std::vector<PendingDispatch>& out) { dispatches_.drain(out); ... },
    [&stream_mgr](PendingDispatch& d) { d.execute(stream_mgr); },
    [] { return std::chrono::duration<double, std::milli>(
                std::chrono::steady_clock::now().time_since_epoch()).count(); });
```

**设计要点**：
- **每帧 3 ms 预算**：架构文档 `ARCHITECTURE.md:95` 说「the main thread drains callbacks in order with a 3 ms per-frame budget, carrying any remainder into later frames」——突发数据到来时 widget 不会一帧里烧光 CPU，剩下的下一帧接着跑。
- **carry/cursor 持久状态 + 重填规则「跑完才补」**：保序；如果半路预算耗尽，下一帧从上次中断处精确继续。
- **`kBudgetCheckStride = 16`**：时钟调用比回调本身贵，所以每 16 个回调才查一次——既保证至少跑一批，又保证不超出预算过多（注释「overshoots by up to one stride」）。
- **时钟参数化**：模板 `NowMs` 注入到测试里（`tests/native/dispatch_drain_test.cpp`），这是它值得抄的核心工程做法。

### 2.4（附）空状态占位 — 「不要假装数据来了」

**文件**：`src/ui/trades_widget.cpp:133-163`

```cpp
// src/ui/trades_widget.cpp:133-163
if (trade_count_ == 0 &&
    StreamPresence::instance().absent(static_cast<uint32_t>(Terminal::Stream::Trades))) {
    const float ww = ImGui::GetContentRegionAvail().x;
    const float pad = 10.0f;
    ImGui::PushFont(Theme::Fonts::label());
    ImGui::PushStyleColor(ImGuiCol_Text, Theme::Tokens::TX3);
    ImGui::SetCursorPosPos(ImVec2(ImGui::GetCursorPosX() + pad, ImGui::GetCursorPosY() + pad));
    ImGui::PushTextWrapPos(ImGui::GetCursorPosX() + ww - pad * 2.0f);
    ImGui::TextUnformatted(
        "No trades received. The feed is connected but its trade stream has "
        "not delivered anything, which some networks block. The tape is "
        "waiting, not broken.");
    ...
    return;
}
```

**设计要点**——明确区分「未就绪」与「真的空」两种状态，并给出**解释性文案**（不是 "Loading..."）。咱 xcom_lua ReceiveContent 行 793-798 已经有 `EmptyState("WAITING FOR SERIAL DATA", {})`，可以借鉴文案的「为什么没数据 + 这不是 bug」思路做更精细的分级（串口未打开 / 已打开无数据 / 协议帧间隙 / 真的为空）。

## 3. 可借鉴清单

| 优先级 | 建议 | 当前实现位置（bridge.cpp） | 实施成本 |
|---|---|---|---|
| **高** | `TableSetupScrollFreeze(0, 1)` 冻结表头行 + 用 `BeginTable` 替代裸 `TextUnformatted` 滚动（多列 + 锁定列宽） | 行 868-1085（clipper + TextUnformatted） | 中：需重构，但表格 API 与现 clipper 兼容，可逐步切换 |
| **高** | 「dirty 标志 + 缓存模型」分层：高频数据进入 bridge 时只更新一个 `rx_dirty_` 标志 + timestamp，render 路径只读不重算；批量格式化（snprintf）一次性写好缓存行 | 行 119-141（receive_text_/line_offsets_）已经是文本缓存，但 **每帧都重算 highlight_rules_ 的 search**（行 925-1037） | 低：把 highlight 的命中结果缓存为 `std::vector<HitSpan>` 按 dirty flag 重算，clipper 可见行直接读 cache |
| **高** | 时间预算（3 ms）+ stride 节流的渲染回调——bridge 里加 `ImGui::GetTime()` 双阈值，超过则当帧提前 return，下次帧补 | 无；当前每帧无上限渲染 | 中：需要把「render 部分」切片为「先渲染 N 行 + 提交 + 下一帧接续」 |
| 高 | 「新行永远在表头下」tape 语义（倒序输出）+ 真正的 follow-tail 替代 `SetScrollHereY(1.0)` | 行 1099-1101（`SetScrollHereY(1.0f)`） | 中：要改的就是把渲染顺序反转 + follow 用「视图自然在表头下」判定 |
| 中 | dirty publish 模型（atomic<bool> + 单 mutex，pull 而不是 push）替代每帧无条件 swap_buffers | 行 868-869 `clipper.Begin` 每帧无条件 | 低：注入 `runtime.receive_dirty_` 已有（行 794/1103） |
| 中 | 「格式化在 insert 时一次性完成」—— xcom_core 写入 `receive_text_` 时，如果 enabled 就同时维护一个 `receive_lines_cached_ : vector<LineModel { text, byte_len, ts_pos, ... }>` | 行 119-141（text + offsets） | 中：要改 xcom_core 的 rx 提交路径，可能跨进程边界 |
| 中 | 空状态分四级：串口未开 / 已开无数据 / 协议间隙 / 真的有数据为空，分别给不同文案 | 行 793（单一 "WAITING FOR SERIAL DATA"） | 低：4 行 if/else |
| 中 | 「行高固定 + 自适应字距」——`row_h` 单独常数，`pad_y = max(0, (row_h - fontSize)/2)` | 行 857（隐式 line_h = GetTextLineHeight()） | 低 |
| 中 | `mono_sm()` 数字专用小号等宽 + label 小号无衬线 + ui 主体的三字体分层 | 行 843-845（仅 mono 与 default） | 低 |
| 中 | 多列 + 锁定宽度（如 HEX 切换时显示 `AA BB CC | "ABC"`，列对齐 + 选中范围按字节而不是字符） | 行 1041-1046（Dummy 占位） | 高：要重新设计行模型（每个字节占 3 列 + 颜色） |
| 低 | `seg_group` 自定义组合按钮（Active = ELEV 填色，hover 也提亮）替代原生 Tab/单选 | ReceiveToolbar 的 `Toggle`（行 664-720） | 中：自定义控件代码 ~30 行 |
| 低 | `depth_cell_text` 阴影字（`AddText(..., IM_COL32(0,0,0,170), txt)`）在亮背景上加 1 px 阴影——line-tinting 视觉技巧 | ReceiveContent timestamp 已经是单一颜色（行 1059） | 低 |
| 低 | 渲染状态用 `FrameScope`（PROFILE_BEGIN/END 宏）——便于 PROJ 真上线时定位瓶颈 | 无 | 低：仅诊断；不影响逻辑 |
| 低 | 「行数据格式化的 row-model cache」 + 「frame-independent frame skipping」（cache_hit 时一帧 skip 整个 widget） | 无 | 中：需在 bridge 加 widget-level cache 命中标志 |

## 4. 总结

edgedepth-terminal 给 xcom_lua 的最大价值是**「分层架构图」**：把 render 路径与 model 构建路径明确分开，前端是**只读、零分配**的纯绘制，后端是 dirty-flag 驱动的批量化构建。具体到咱 bridge.cpp，行 925-1037 的 highlight_rules 处理是**第一个可以落地的分层目标**——把 search 结果缓存为 `vector<HitSpan>`，用 dirty flag 失效，clipper 阶段只读。
