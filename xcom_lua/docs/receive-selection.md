# 接收区文本选择与高亮：操作流程、实现与绝对坐标契约

> 主题：接收区（Receive 面板）鼠标选中文字如何高亮，以及"选区随文本上滚"的绝对坐标重构。
> 合并原 `receive-selection-highlight`（操作流程 + 原理）与 `receive-selection-absolute-coords`
> （绝对坐标修复）两份笔记。实现位于 `native/xcom_imgui/xcom_imgui_bridge.cpp` 的
> `ReceiveContent()`，辅以 `xcom_core/src/ao/xcom_ao.cpp` 的文本归一化。
> bridge 处于活跃开发，行号一律省略，按符号名定位。

## 用户操作流程

1. 打开串口，数据到达。Lua 主循环（`ui/window.lua` 的 `_flush_imgui_receive` /
   `ui/imgui_bridge.lua:set_receive_text`）把 core 侧格式化文本经 FFI 推入
   `xcom_imgui_set_receive_text()`，文本存入 `receive_text_` 并一次性重扫出各行起始偏移
   `receive_line_offsets_`。
2. 鼠标在接收区按下左键：锚点置 `kSelDragging`，选区 `[begin,end)` 清零，`receive_sel_drag_hit_`
   置 false——"按下即清空旧选区、进入拖拽态"。
3. 按住拖动：每帧在行渲染循环做命中测试，把鼠标 x 换算成字节偏移 `at`；首帧记
   `receive_sel_drag_origin_`，之后 `begin=min(origin,at)`、`end=max(origin,at)`，跨行时中间整行纳入。
   **拖到可视区上/下边缘会每帧滚动一行**，否则视图外的行没有被 clipper 提交、没有矩形可命中，
   一次手势永远选不到屏幕之外的文本（`rows_first_top/rows_last_bottom` 是本帧实际提交的行范围）。
3b. 其余三种手势（按点击次数分流，`GetMouseClickedCount`）：
   - **双击**：选中光标下的词。ASCII 词字符 = `A-Za-z0-9_`（连续段整体选中），
     分隔符只选它自己，**非 ASCII 字节整段 UTF-8 序列一起选中**（CJK 一字 3 字节，
     选单字节会复制出非法片段）；尾行被截断的半个序列按 1 字节处理。
     边界规则是纯函数 `receive_selection.hpp`，由 `xcom_core/tests/receive_selection_test.cpp` 在
     Linux 主机上直接跑（手势本身无头跑不了，边界可以）。
   - **三击**：整行。
   - **Shift+单击**：**从现有选区末端延伸**（本控件没有光标与键盘焦点模型，选区尾端就是唯一
     可指的"光标"）：先单击标记一点，再 Shift+单击其上方或下方即向前/向后选中；没有选区时
     退化为一次普通拖拽。这三种手势旧实现都落在"每次按下都当拖拽开始"上——双击会先把选区清零、
     再从第二下起一个零长度拖拽，看起来什么都没发生。
4. 高亮实时出现：与该行相交时，在文字**底下**（先画色块再提交 `TextUnformatted`）画
   `ImGuiCol_TextSelectedBg` 色矩形；选到行尾色块铺满整行宽度。
5. 松开左键：锚点回 `kNoSelAnchor`；命中过则选区持久保留，纯点击空白则清零。
6. 右键菜单：`Copy selection`（`substr` + `SetClipboardText`）、`Copy all`、`Clear log`
   （返回 `ActionClear`，Lua 调 `set_receive_text("")`）。
7. 清除选区没有独立操作：下次按下即隐式清空；滚动/跟随新数据**不会**清除已有高亮。

## 数据结构：以字节偏移为唯一坐标

- `receive_text_`（std::string）：接收区尾部文本（滚动窗口，`receive_limit_`）。
- `receive_line_offsets_`（`std::vector<size_t>`）：每行起始字节偏移升序表。
  在 `xcom_imgui_set_receive_text` 每次变更时重建：`push_back(0)` 后 `std::memchr` 扫 `\n`，
  记录每个 `\n` 之后的位置。只找 `\n` 是因为 core 侧 `format_payload` 已把 CRLF/孤立 CR 归一成 LF。
  重建先 `reserve(len/32+2)` 消掉几何扩容。
- 选区状态：`receive_sel_anchor_`（`kNoSelAnchor` 空闲 / `kSelDragging` 拖拽中）、
  `receive_sel_begin_`、`receive_sel_end_`、`receive_sel_drag_origin_`、`receive_sel_drag_hit_`。

## 状态机与命中测试

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Dragging: log_hovered 且单击（清空旧选区）
    Dragging --> Dragging: 逐行命中，begin/end = min/max(origin, at)
    Dragging --> Dragging: 鼠标越过可视区边缘 → 每帧滚动一行并继续延伸
    Dragging --> Idle: 松开左键（命中过则保留选区，否则清零）
    Idle --> Word: 双击（词边界 = 上述规则）
    Idle --> Line: 三击（整行）
    Idle --> Extended: Shift+单击（以旧选区尾端为锚，一次性延伸）
```

- 按下条件 `log_hovered && IsMouseClicked(Left)`；`log_hovered` 用
  `ImGuiHoveredFlags_AllowWhenBlockedByActiveItem`，避免滚动条等活动控件吞掉按下。
- 命中测试 `hit_offset_in_row`：行矩形取 `ImGui::GetItemRectMin/Max()`（权威值，含 ScrollY/
  ItemSpacing/DPI，不手算滚动）；列 = `(p.x-rmin.x)/glyph_w + 0.5`，钳到行长。
  **只用等宽 `mono_font_` + 帧首测一次 `glyph_w`**（`CalcTextSize(64×'M').x/64` 均摊误差），
  像素→列 O(1)；比例字体需逐字形测量会退化成 O(line²)。
- 拖拽时只有鼠标所在行通过 y 区间判断，逐行测试近似 O(1)/帧。

## 高亮绘制

同时满足 `line_off < sel_e && line_off+line_len > sel_b`（区间相交）的行进入绘制。首行画
`[from,行尾]`、尾行画 `[0,to]`、中间行整行覆盖。几何由字节差乘 `glyph_w` 得到，高 `line_h`，
起点 `GetCursorScreenPos()`（ItemSpacing 已压 0）。行尾铺满时宽度改用 `text_width`。
色块在 `TextUnformatted` 之前提交，故永远在字形之下。

## 绝对坐标契约（滑窗不丢选区）

**症状**：持续来数据时拖选，高亮钉死在屏幕同一批行，被选文字从下面流走。
**根因**：旧实现选区存"`receive_text_` 内第 N 字节"（窗口相对）。Lua 每次 flush 整块换血窗口，
"第 N 字节"指向完全不同的内容，旧偏移"移情"到窗口头部新行。

**修法**：选区改用**绝对（lifetime）字节坐标**：

- C++ 新增成员 `receive_base_`：`receive_text_[0]` 在整条接收流中的绝对偏移；
  `receive_sel_begin_/end_/drag_origin_` 一律存绝对字节。
- 渲染时取局部 `base = receive_base_`；高亮求交前把绝对区间映射回窗口
  （`sel_b = max(sel_begin-base,0)`，被裁掉的部分即"已滚出窗口"，不再画）；
  拖拽命中得到的窗口偏移 `+base` 还原为绝对值入状态。
- 右键"复制选中"：绝对区间先 clamp 到 `[base, base+len)` 再 `substr`——只复制仍在窗口内的部分；
  已滚出字节不在显示缓冲，无法恢复（数据无损由 auto-save 日志保证，是既定契约）。
- 归零路径：空缓冲早退、`set_receive_text(NULL/0)`、`on_btn_clear` 同步重置 `receive_base_` 与选区三元组；
  `set_receive_window` 缩窗 erase 分支 `base += erase_n`。
- 新导出 `xcom_imgui_set_receive_base(size_t)`，Lua 在每次 `xcom_imgui_set_receive_text` 之前调用。
  Lua 侧 `window.lua` 维护 `_imgui_receive_total`（lifetime 显示字节计数），
  `imgui_bridge.lua:set_receive_text(text, base)` 里 `base = total - #tail`，经
  `optional_export` 探测后先推；**旧 DLL 缺该符号时自动退化**为 base=0（等价历史行为，不崩）。

**贴底跟随（每帧）**：

```cpp
// 帧首判定（同一帧内 Scroll.y 已被上一次 Begin 应用；脱开/重挂靠它）
const bool was_at_bottom = ImGui::GetScrollY() >= ImGui::GetScrollMaxY();
// ... 行提交 ...
// 帧尾：写"尽可能靠下"的目标（不是具体位置），并按住左键时冻结
if (was_at_bottom && !ImGui::IsMouseDown(ImGuiMouseButton_Left))
    ImGui::SetScrollY(kFollowTailTargetY);
```

两条都踩过坑，改动时不要回退：

- **必须写"目标"而不是"位置"**：`SetScrollY` 写的是 target，下一次 `Begin` 才应用并 clamp。
  若按 `SetScrollHereY(1.0f)` 写具体位置，写入时的内容与生效时的内容差一帧；而尾窗是
  **帧外**追加的（Lua 轮询在 render 之外推数据），于是贴底位置永远差"一个批次"——最新行
  根本进不了可视区，滚动条下键也够不到底。写大值让下一次 Begin 用**当轮内容** clamp 才对。
- **内容高度每帧强制**：ImGui 的 `ScrollMax` 来自**上一帧**的 content size
  （`CalcWindowContentSizes` 在 `Begin()` 重置光标之前跑），帧外追加的行不在其中，
  于是可达下界比真实尾部少一个批次。`ReceiveContent` 在创建日志子窗前用
  `SetNextWindowContentSize` 按**行数 × 行高 + 行首偏移**（上一帧量得）强制内容高度，
  让滚动条与跟随 pin 都对齐"这一帧屏幕上的尾部"。
- **按住左键必须冻结**：子窗口的滚动条在 `Begin()` 内（body 之前）写自己的滚动目标，
  下一次 `Begin` 才生效；帧尾的 pin 会把箭头点击/滑块拖动**原地覆盖**，于是贴底时
  滚动条表现为"点不动"。`IsMouseDown` 每帧权威，松开后帧首判定自然重挂跟随，
  不存在 capture 丢失导致永久冻结。
- **工具栏（清空/保存/路径）必须在滚动子窗之外**：放在日志内容里会被滚走；改用
  `SetCursorScreenPos` 钉在屏幕空间则更糟——屏幕坐标不随滚动平移，行的**内容空间**偏移
  就变成 `f(Scroll.y)`：内容高度随滚动增长，滚动上限自我放大（探针实测 190 行日志可达
  7 万 px），行也不再与滚动位置对应，尾部彻底够不到。现结构：工具栏是**监控列**的一行
  （该窗口 `NoScrollbar|NoScrollWithMouse`，永不滚动），日志子窗只装行，几何自洽。

**为什么不用内容前缀匹配**：曾想对比新旧缓冲求丢弃头部字节数，但换行边界处内容可能逐字节相同、
匹配窗口可达 64KiB，热路径不可控，且本质是让 DLL 反向猜 Lua 窗口代数。改为 Lua 显式推 base，
O(1) 零猜测。

## 关键设计决策

1. **不用 InputTextMultiline**：其 stb_textedit 只把 `\n` 当换行，游离 `\r` 渲染成控制字形破坏行高
   （core 侧 CRLF→LF 归一化的由来）；且自带光标/滚动状态与"贴底跟随"打架。改为
   `ImGuiListClipper + 每行 TextUnformatted` 的官方日志窗模式，渲染代价从 O(全文) 降到 O(可视行)。
2. **命中测试用 GetItemRectMin/Max**，不手算滚动——规避样式/DPI/滚动条细节导致的选区错位。
3. **等宽字体 + O(1) 列换算**是拖拽不掉帧的关键。
4. **偏移表在文本变更时重建一次**（满带宽约 100 次/s），`memchr` SIMD 跳跃扫描 + 一次 reserve。
5. **绘制顺序即层级**：色块先于文字提交，无需透明混合。

## 验证与遗留

- 无头注入探针：VIRTUAL 口 `open_async rc=0` → `test_inject_rx` → `drain_display` 原样吐回，
  `rx_bytes`、`pool_exhausted=0` 正常。
- 在线 E2E：`XCOM_SMOKE_OPEN=1 XCOM_SMOKE_SIM_PROFILE=text` 启动，日志区渲染模拟数据，无报错。
- **拖选交互本身需人工验证一次**（合成鼠标点击无法到达 ImGui Win32 后端）：
  > 注（2026-10-04）：本条作废——手势已由 `tests/e2e_drag_freeze.lua` 进程内自动化证明，见文末「拖选冻结的进程内验证」。
  滚动流中拖选 → 松开 → 高亮应随文本上滚直至不可见；按住拖动期间视图应停住。
- 已补（本轮）：**边缘自动滚动**（拖到可视区上/下边缘每帧滚一行，选区可越过屏幕）、
  **双击选词 / 三击选行**（`receive_selection.hpp` + 主机测试）、**Shift+单击延伸**。
- **自动清空不得吃掉拖拽**：阈值触发时 Lua 会推空串清视图，而空推**按设计**会清掉原生选区
  （显式清空时是对的，捏着鼠标时是错的——bridge 自己的尾部裁剪早就为同一个条件让路）。
  现在 `ui/window.lua` 的清空锚点先问 `xcom_imgui_selection_dragging()`，拖拽中只**推迟**不清：
  累计字节继续增长，松手后的下一次 append 照常越过阈值清空。旧 DLL 无该导出时探测为 nil，
  行为与从前一致。
- 遗留：被截断出窗口的选中内容无法复制（需 Lua 保留退役 chunk 副本，当前按 64KiB 窗口契约不做）；
  没有键盘选区（无光标模型，`Shift+方向键` 需引入焦点/光标状态，尚未做）；长行超出窗口宽度时
  右侧被裁，只能选到行尾（字节偏移换算到行尾是取满的，只是看不到）。
- 快捷键与复制策略：Ctrl+A 全选、Ctrl+C 复制选中已实现（`ReceiveContent` 内经 `ImGui::Shortcut`，
  路由按焦点域判定，输入框持有焦点时不抢占）。复制不再由 C++ 直接写剪贴板，而是把请求入队
  （`QueueReceiveCopy`），由 Lua 侧 `service_receive_copy` 用 `core/receive_copy.lua` 的纯函数
  `strip_timestamps` 按「复制时去除时间戳」开关处理后写剪贴板；该开关默认关闭、经
  `[display] strip_timestamp_on_copy` 持久化。

## 拖选冻结的进程内验证（2026-10-04，自动化）

**结论：合成鼠标能送达 ImGui Win32 后端，"拖选冻结需人工验证"这一条已不成立。**
`tests/e2e_drag_freeze.lua` 把整条手势做成了进程内断言，实测 3/3 轮全绿；反证实验（删掉门控）必红，
说明断言真的在测东西，不是自我安慰。

### 为什么截图不够
按下点没落进接收区、和拖拽完全正常，在截图上是同一个样子（画面不动、高亮还没出现）。
上一轮像素探针正是这样给出假阴性：`interaction=False` 只说明坐标没命中，不能说明功能坏了。
判据必须来自渲染帧内部。

### 三个只读导出（`xcom_imgui_bridge.cpp`）
- `xcom_imgui_get_receive_rect`：接收区子窗口的矩形，唯一权威的按下点。用 layout.toml 在 Lua 里
  反推会落到侧栏、发送框或自绘滚动条列上——三者都会吃掉点击却不进入拖拽，检查于是变成空转。
- `xcom_imgui_get_receive_scroll`：`(scroll_y, scroll_max)`，冻结的判据就是"y 不动而 max 在长"。
  两者在同一次帧尾捕获，Begin 已把 `Scroll.y` 钳到本帧范围，所以稳定跟随时读到的就是 `y == max`。
- `xcom_imgui_get_receive_selection`：选区的绝对字节区间。`selection_dragging()==1` 只证明
  "进入了拖拽态"，命中测试没落到行上时选区仍为空，所以两者都要看。

### 手势怎么送进去
`SetCursorPos` + `mouse_event` 注入的是真 OS 消息，而 ImGui 的 Win32 后端消费的正是
`WM_MOUSEMOVE` / `WM_LBUTTONDOWN`；`Window:dispatch()` 每条消息都先转 `imgui:on_wndproc`，
所以注入走的是和真实鼠标完全相同的状态机。两个坑都实测过：
1. 导出的矩形在 ImGui 空间，也就是**客户区**坐标；`SetCursorPos` 要的是屏幕物理像素，
   中间必须 `ClientToScreen`。漏掉这一步，第一次尝试就点在窗口外的空气上。
2. `WindowFromPoint` 的 POINT 是**按值**形参，本项目的 FFI 层无法表达
   （`'struct' cannot be indexed with 'number'`）。因此"点是否属于本窗口"改由结果证明：
   按下后若在超时内没有进入拖拽态，就判该候选点无效并换下一个——顺带把"落在窗口上但被别的
   控件吃掉"一起筛掉。按下前还会重新置顶一次，因为注入的跟随命中测试走，不跟随我们的意图。

### 实测（`text` profile 8 KiB/s，log 矩形 733x372，窗口 920x650）
| 阶段 | 断言 | 数据（3 轮） |
| --- | --- | --- |
| 前置 | 可滚动且贴底 | y=max=603~678 |
| 按住 55 采样 | 拖拽态持续 | 55/55，选区 504~505 B |
| 按住约 1.4 s | 视图冻结 | chased **+0px**，同期 scroll_max 长了 2730~4605px（约 150~250 行） |
| 松手 16 采样 | 不重新吸底 | moved 0px（尾部已在 4.3k px 之外） |
| 滚轮回底 | 重新吸底 | y=max=4728~4788 |
| 其后 24 采样 | 跟随恢复 | 又跟了 1215~1230px，24/24 都在尾部 |

按下之后那 0~1 个采样（0~135px）的位移是 OS 消息排队延迟：那一刻 DLL 还不知道按键已下，
门控无从生效。驱动把它单独记成"进入拖拽前的合法追视"，不计入失败，也不静默吞掉。

### 反证（敏感性验证）
把 `if (runtime.receive_follow_tail_ && !ImGui::IsMouseDown(ImGuiMouseButton_Left))` 的门控删掉重编：
chased **+2700px**（恰好等于尾部增长量），松手后仍被拖走 780px，选区一路涨到 11844 B，
两条断言同时变红。改回原样后 3/3 轮转绿。

### 运行前提
需要带这三个导出的 `runtime/xcom_imgui.dll`；旧 DLL 上驱动直接报
"rebuild runtime/xcom_imgui.dll"，不会拿陈旧状态凑出一个 PASS。
`tools/check_dll_exports.sh` 负责把 cdef 与已提交二进制之间的这类漂移挡在 CI 里。
