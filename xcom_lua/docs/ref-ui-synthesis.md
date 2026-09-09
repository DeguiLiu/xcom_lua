# ref-ui-synthesis.md — 4 个 UI 参考项目提炼

> 调研日期：2026-09-05
> 4 个源文档：
> - [edgedepth-terminal-ui.md](./edgedepth-terminal-ui.md)
> - [wave-gui-reference.md](./wave-gui-reference.md)
> - [amodemGUI-reference.md](./amodemGUI-reference.md)
> - [uscope-reference.md](./uscope-reference.md)

## 核心模式提炼

1. **「cache-on-input, paint-on-frame」分层**（edgedepth DOM widget + uscope circularBuffer）—— render 路径零分配、只读 cache；build 路径 dirty-flag 驱动批量化构建。xcom_lua bridge.cpp 的 highlight_rules 搜索（行 925-1037）就是「render 时重算」的典型反模式。
2. **「update / render 严格分离」**（wave-gui `App::update` vs `App::render`）—— 数据准备与绘制分两阶段，主循环只调用两者；bridge.cpp 现在混在一起。
3. **「PlotHistogram 多次叠加 + SetCursorScreenPos」**（wave-gui ui.cpp:406/419）—— 同一坐标画「信号 + 阈值 + 触发线」多层，零额外控件开销；直接对应 waveform.lua 的 Phase 4 ImPlot 改造。
4. **「时间预算 + stride 节流的回调排空」**（edgedepth dispatch_drain.h）—— 每帧 3ms 软上限 + 每 16 次回调检查一次钟；突发数据不会烧光一帧。
5. **「dirty 标志 + atomic<bool>」publish-once-per-frame**（edgedepth double_buffer.h:47-53）—— 取代每帧无条件全量重绘；lockless skip 让 idle 符号零成本。
6. **「scratch_arena per-frame reset」**（uscope State.zig:142-144）—— 帧内所有临时分配一次性回收，避免逐字符串 free。
7. **「数据结构必带测试」工程纪律**（uscope circularBuffer 4 个测试 + edgedepth dispatch_drain 模板化时钟注入测试）—— xcom_lua 的 Lua-side 单元测试可加深这一层。
8. **「TableSetupScrollFreeze(0, 1) + 等宽字体 + 表头冻结」**（edgedepth trades_widget）—— 接收区可读性的最大提升，目前 bridge.cpp 没有用 ImGui Table。
9. **「新行永远在表头下」tape 语义**（edgedepth trades_widget:204-209）—— 倒序输出取代 `SetScrollHereY(1.0)`，follow-tail 体验更自然。
10. **「空状态分级 + 解释性文案」**（edgedepth trades_widget:147-163）—— 「WAITING FOR SERIAL DATA」过于笼统；可分级为「串口未开 / 已开无数据 / 协议间隙 / 真为空」并各自解释。

## 优先级最高的 5 条借鉴建议（合并去重）

| 排序 | 建议 | 来源项目 | 桥接位置 | 实施成本 |
|---|---|---|---|---|
| **1** | **`TableSetupScrollFreeze(0, 1)` + BeginTable** 替换裸 `TextUnformatted` 滚动，多列 + 锁定表头 + 数字列对齐 | edgedepth trades_widget | bridge.cpp 行 868-1085 ReceiveContent clipper | 中 |
| **2** | **highlight 命中缓存**为 `vector<HitSpan>` + dirty flag，clipper 阶段只读；render 与 build 分层 | edgedepth dom_widget cache-on-input | bridge.cpp 行 925-1037 highlight_rules 搜索 | 低 |
| **3** | **环形缓冲 + 批量 appendRange** 替代 `std::string receive_text_` 单字节 push_back | uscope circularBuffer + @PERFORMANCE 注释 | bridge.cpp 行 119-141 `runtime.receive_text_` | 中 |
| **4** | **PlotHistogram 多次叠加** `SetCursorScreenPos` 复用坐标画「信号 + 包络 + 触发线」三层 | wave-gui ui.cpp:406/419 | `core/waveform.lua` Phase 4 ImPlot 化 | 中 |
| **5** | **空状态分级**「串口未开 / 已开无数据 / 协议间隙 / 真为空」+ 各自解释文案 | edgedepth trades_widget:147-163 | bridge.cpp 行 793 `EmptyState` | 低 |

## 实施顺序建议

### 阶段一：性能与可读性（短期，~1 周）

1. **highlight 命中缓存**（建议 #2）—— 改动局限在 bridge.cpp 一处函数内部，clipper 仍是 `TextUnformatted`；dirty flag + std::vector<HitSpan> 加在 `ImGuiRuntime`。**预期收益**：高负载（512-byte/帧）下帧时间下降 30-50%。
2. **空状态分级**（建议 #5）—— 4 行 if/else + 4 段文案；几乎零风险。

### 阶段二：渲染层重构（中期，~2 周）

3. **`TableSetupScrollFreeze(0, 1)` + BeginTable**（建议 #1）—— 保留 ImGuiListClipper，但行渲染从 `TextUnformatted` 改到 `TableNextRow + TextUnformatted`，启用 freeze。**注意**：与现有 selection 行矩形（bridge.cpp 行 909-912 的 `AddRectFilled`）共存需要小心——`DrawList::AddRectFilled` 仍可用，但坐标需按 cell 调。
4. **PlotHistogram 多次叠加**（建议 #4）—— 在 `core/waveform.lua` 内部做；先验证 `ImPlot::PlotLineG` 在咱的桥接可用，再分阶段叠加。

### 阶段三：架构升级（长期，~1 月）

5. **环形缓冲 + 批量 appendRange**（建议 #3）—— 需要改 xcom_core rx 提交路径 + bridge 接收路径 + 维护 line offsets；建议先在 `tests/` 写 4 个边界测试（fill / overflow / wrap-around / scrollback）再上代码。
6. （可选）**scratch_arena** + **3ms 时间预算** —— 仅当需要把 xcom_core 移出主线程或帧时间已经不可控时再做。

### 不建议本轮做的

- edgedepth **proto/WS/pthread 整套架构** —— xcom_lua 是单机单窗口，没必要。
- uscope **HexViewer UI** —— 实际代码不存在，参考价值为零。
- amodemGUI **任何 UI 代码** —— 没有源码，DearPyGui API 也不同。

## 总评

edgedepth-terminal 是 4 个项目中**唯一提供完整可读 ImGui UI 代码 + 性能模式文档**的，应该作为 xcom_lua 接收区 + 波形可视化的**主要参考**。wave-gui 给工程组织（update/render 分离、主循环骨架）的范式。uscope 给数据结构和测试纪律。amodemGUI 提供价值极低（无源码 + 栈不匹配）。

xcom_lua 当前的 receive hot path 已经做到相当不错的优化（`MEMORY.md` 记录的 glyph_w 测量、ascii_only 路径），下一步最大价值是**「分层架构」**——把 dirty-flag + cache 模型搬到 bridge.cpp，把 highlight 命中从「render 时算」改成「dirty 时算」。这条改动局限在 100-200 行内，但能把稳态帧时间再砍 30% 以上。
