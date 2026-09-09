# 接收区文本选择与高亮：操作流程与实现原理

本文回答一个具体问题：**在接收区（Receive 面板）用鼠标选中文字后，为什么选中的行能被高亮？整个操作流程和实现方式是什么？**

所有结论均来自真实代码，核心实现位于
`xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp` 的 `ReceiveContent` 函数
（约 635–833 行），辅以 `xcom_core/src/ao/xcom_ao.cpp` 的文本归一化。

---

## 一、用户操作流程

1. **打开串口，数据到达。** Lua 主循环（`ui/window.lua` `_flush_imgui_receive` →
   `imgui:set_receive_text`，约 1124–1128 行）把 core 侧格式化后的接收文本经 FFI
   推入 DLL：`xcom_imgui_set_receive_text()`（bridge 约 1639–1677 行）把文本存入
   `receive_text_`，并**一次性重扫**出各行起始字节偏移表 `receive_line_offsets_`。
2. **鼠标在接收区按下左键**（面板内任意一行上或行间隙）。此帧
   `sel_drag_start` 成立（约 684–691 行）：锚点置为 `kSelDragging`，选区
   `[begin, end)` 清零，`receive_sel_drag_hit_` 置 `false`——即"按下即清空旧选区、进入拖拽态"。
3. **按住左键拖动。** 每帧在行渲染循环里做命中测试（约 770–788 行）：鼠标当前所在行
   被判定后，把鼠标 x 坐标换算成该内的字节偏移 `at`。首次命中记录
   `receive_sel_drag_origin_`（拖拽起点），之后每帧令
   `begin = min(origin, at)`、`end = max(origin, at)`。选区随拖拽实时增长，
   跨行时中间整行全部纳入。
4. **高亮实时出现。** 每一帧渲染时，凡与 `[begin, end)` 相交的行，都在文字**底下**
   （先画色块再提交 `TextUnformatted`）画一块 `ImGuiCol_TextSelectedBg` 色矩形
   （约 746–765 行）——这就是看到的高亮。选到行尾时色块自动铺满该行剩余整行宽度。
5. **松开左键。** 约 792–798 行：锚点复位为 `kNoSelAnchor`，选区 `[begin, end)`
   **持久保留**（若从未命中过任何行，即纯点击空白，则清零）。高亮停止跟随鼠标，
   直到下一次按下。
6. **右键弹出菜单**（约 809–831 行）：
   - `Copy selection`：仅在有选区时可用，`receive_text_.substr(begin, end-begin)`
     → `ImGui::SetClipboardText`；
   - `Copy all`：复制整个接收缓冲；
   - `Clear log`：置 `ActionClear`，Lua 侧调 `set_receive_text("")`
     （`window.lua` 约 1847 行）清空文本。
7. **清除选区的方式：** 没有独立的"取消"操作——下一次在接收区按下左键即隐式清空
   （第 2 步的清零逻辑）；点击行外空白处（从未命中任何行）松开后选区也会归零。
   滚动、跟随新数据都不会清除已有高亮。

---

## 二、实现原理（分层）

### 2.1 数据结构：以"字节偏移"为唯一坐标

- `receive_text_`（std::string，约 113 行）：接收区尾部文本（默认 64 KiB 滚动窗口，
  `receive_limit_` 约 139 行）。
- `receive_line_offsets_`（std::vector\<size_t\>，约 135 行）：**每行起始字节偏移**
  的升序表（含偏移 0）。由 `xcom_imgui_set_receive_text` 在每次文本变更时重建
  （约 1661–1672 行）：`offsets.push_back(0)` 后循环
  `std::memchr(scan, '\n', ...)`，每找到一个 `'\n'` 记录其后的位置。之所以只需
  找 `'\n'`，是因为 core 侧 `format_payload`（`xcom_core/src/ao/xcom_ao.cpp`
  约 77 行起，CRLF 处理在约 180–186 行）已把 `CRLF`/孤立 `CR` 归一化成单个 `LF`，
  并剥除 ANSI 控制序列，文本视图拿到的行终止符**只有 `'\n'`**。
- 选区状态（约 126–131 行）：
  ```cpp
  std::size_t receive_sel_anchor_ = kNoSelAnchor;  // 哨兵：状态机模式
  std::size_t receive_sel_begin_ = 0;              // 选区起点（字节偏移）
  std::size_t receive_sel_end_ = 0;                // 选区终点（begin <= end）
  std::size_t receive_sel_drag_origin_ = 0;        // 本次拖拽的锚点（首次命中处）
  bool        receive_sel_drag_hit_ = false;       // 本次拖拽是否已命中过行
  ```
  文件级常量（约 87–88 行）：
  ```cpp
  constexpr std::size_t kNoSelAnchor = static_cast<std::size_t>(-1);  // 空闲/无拖拽
  constexpr std::size_t kSelDragging = static_cast<std::size_t>(-2);  // 左键按住，选区随拖拽延伸
  ```
  选区、锚点、行**全部用 `receive_text_` 内的字节偏移表示**，与滚动位置、
  窗口尺寸完全解耦——这是"高亮不随滚动错位"的根本原因。

### 2.2 状态机：按下 → 拖拽 → 释放

```
kNoSelAnchor ──(log_hovered && IsMouseClicked(L))──▶ kSelDragging
   ▲                                                      │
   │        (IsMouseDown(L)==false 时，clipper 循环后)     │
   └──────────────────────────────────────────────────────┘
        命中过行 → [begin,end) 持久保留；否则清零
```

- **按下**（约 684–691 行）：条件 `log_hovered &&
  ImGui::IsMouseClicked(ImGuiMouseButton_Left)`。`log_hovered` 用了
  `ImGuiHoveredFlags_AllowWhenBlockedByActiveItem`（约 676 行），保证已有活动
  控件（如滚动条刚拖完）不吞掉按下事件。触发后写入 `kSelDragging` 并清空
  begin/end/drag_hit——旧选区即刻消失。
- **拖拽中**（约 692–694 行）：`anchor == kSelDragging &&
  ImGui::IsMouseDown(L)`。仅此标志为真时才做逐行命中测试（见 2.3）。
- **释放**（约 792–798 行，位于 clipper 循环之后）：`anchor == kSelDragging`
  且 `!IsMouseDown(L)` → 锚点回 `kNoSelAnchor`；若整个拖拽过程一次都没命中
  行（`drag_hit_ == false`），把 `[begin, end)` 清零。若命中过，选区原样保留，
  后续每帧继续绘制高亮（`has_selection`，约 695 行）。

### 2.3 命中测试：鼠标像素 → 字节偏移

渲染主体是官方 imgui_demo 日志窗模式：一个滚动 child 内
`ImGuiListClipper` 只提交可视行，每行一次 `ImGui::TextUnformatted(line_begin,
line_end)`（约 719–791 行）。行文本切片直接由偏移表算出：
`line_begin = data + offsets[i]`，`line_end = offsets[i+1] - 1`（跳过行尾
`'\n'`；末行到 `size()`）。

`hit_offset_in_row` lambda（约 735–745 行）把像素换算回字节偏移：

```cpp
const auto hit_offset_in_row = [&](const ImVec2& p, const ImVec2& rmin,
                                   const ImVec2& rmax) -> std::size_t {
    if (p.y < rmin.y || p.y >= rmax.y || p.x < rmin.x)
        return static_cast<std::size_t>(-1);          // 不在本行 → 未命中
    const std::size_t col = static_cast<std::size_t>(
        (p.x - rmin.x) / glyph_w + 0.5f);             // 列 = 像素宽 / 字形宽，四舍五入
    return line_off + (col < line_len ? col : line_len);  // 钳到本行长度
};
```

关键点：

- **行矩形来自 `ImGui::GetItemRectMin()/Max()`**（约 771–772 行），即每提交
  一行后向 ImGui 询问该行的权威屏幕矩形——完全不做手算的
  `scroll_y + item_spacing` 数学，滚动、窗口缩放、DPI 变化天然正确。
- **列→偏移是 O(1) 算术**：接收区强制使用等宽字体 `mono_font_`
  （约 700–704 行 PushFont），字形前进宽度 `glyph_w` 在帧首测一次
  （约 716–718 行，见 2.5），鼠标 x 减行起点除以 `glyph_w` 即列号；ASCII
  日志字节与字形 1:1 对应，列号即字节偏移。
- 拖拽时**只有鼠标所在的那一行**能通过 y 区间判断（其余行代价是一次比较），
  所以逐行命中测试在可视行循环里近似 O(1)/帧（约 767–769 行注释）。
- 行内但鼠标在文本起点左侧、或超出行尾的场合：外层补救（约 774–778 行）
  将其钳制为 `line_off`（行首）或 `line_off + line_len`（行尾）。
- 命中后（约 779–787 行）：首帧记 `drag_origin_ = at`，随后每帧
  `begin/end = min/max(origin, at)`——支持向前、向后任意方向拖选。

### 2.4 高亮绘制：逐行画相交色块

"为什么选中后整行（甚至跨多行）都会高亮"的答案在约 746–765 行。绘制时机在
**该行 `TextUnformatted` 提交之前**，因此色块垫在字形之下：

```cpp
if (has_selection || sel_dragging) {
    const std::size_t sel_b = runtime.receive_sel_begin_;
    const std::size_t sel_e = runtime.receive_sel_end_;
    if (sel_e > sel_b && line_off < sel_e &&            // 本行起点在选区结束之前
        line_off + line_len > sel_b) {                  // 本行终点在选区起点之后
        const std::size_t from = sel_b > line_off ? sel_b - line_off : 0U;
        const std::size_t to   = sel_e < line_off + line_len ? sel_e - line_off : line_len;
        const float px    = static_cast<float>(from) * glyph_w;
        const float width = static_cast<float>(to - from) * glyph_w;
        const ImVec2 rmin = ImGui::GetCursorScreenPos();
        draw->AddRectFilled(rmin,
                            ImVec2(rmin.x + (to == line_len ? text_width : px + width),
                                   rmin.y + line_h),
                            sel_color);
    }
}
```

- `line_off < sel_e && line_off + line_len > sel_b` 是标准的**区间相交判定**：
  凡与 `[sel_b, sel_e)` 相交的行都进入绘制分支——一次跨行拖选中，首行画
  `[from, 行尾]`、尾行画 `[0, to]`、中间所有行 `[from=0, to=line_len]` 整行覆盖，
  于是视觉上"选中的行"逐行全部点亮。
- 色块几何完全由字节差乘 `glyph_w` 得到（等宽保证与字形严格对齐），
  高度取 `line_h`，起点取 `GetCursorScreenPos()`（`ItemSpacing` 已被压为 0，
  约 705 行，色块无间隙地接成整行）。
- **行尾铺满**：`to == line_len` 时矩形宽度改用 `text_width`（内容区可用宽度，
  约 709 行）而不是 `px + width`，选中到行尾时高亮延伸到面板右缘，符合
  原生编辑器的选区观感。
- 颜色取 `ImGui::GetColorU32(ImGuiCol_TextSelectedBg)`（约 707 行），与 ImGui
  内建选区色一致，随主题变化。

由于选区是持久数据（字节偏移），高亮与拖拽是否进行中无关——释放鼠标后
`has_selection` 仍为真，每帧继续走同一分支重画，直到被新按下清零。

### 2.5 剪贴板

约 812–831 行。右键（`IsWindowHovered() && IsMouseClicked(R)`）打开
`##receive_context` popup：

- `Copy selection`（enabled 条件 `has_sel`）：
  `receive_text_.substr(sel_begin_, sel_end_ - sel_begin_)` →
  `ImGui::SetClipboardText(sel.c_str())`。选区本身就是文本的一个连续字节区间，
  复制无需任何重组。
- `Copy all`：整个 `receive_text_`。
- `Clear log`：返回 `Action::ActionClear` 位给 Lua，由
  `window.lua` 走 `set_receive_text("")` 路径清空（同时该函数把偏移表重置为
  `assign(1, 0)`，约 1645 行）。

---

## 三、关键设计决策与性能约束

1. **为什么不用 `InputTextMultiline`？**
   代码注释（约 656–662 行）记录了历史：早期的 InputTextMultiline 视口有两大
   问题——其内部 stb_textedit 排版引擎只把 `'\n'` 当换行，游离的 `'\r'` 会渲染成
   控制字形、破坏行高（这正是 core 侧如今在 `format_payload` 里做 CRLF→LF 归一化的
   原因，`xcom_ao.cpp` 约 108–110 行注释）；更关键的是它自带光标/滚动状态，与
   本项目的"贴底跟随"逻辑互相打架。改为 **ImGuiListClipper + 每行一次
   TextUnformatted** 的官方日志窗模式后，渲染是纯只读、无内部编辑状态，选择
   逻辑得以完全自建、完全可控；渲染代价也从 O(全文 64 KiB) 降到 O(可视行)。

2. **为什么命中测试用 `GetItemRectMin/Max` 而不是手算滚动？**
   行矩理由 ImGui 在提交时确定，包含当前 `ScrollY`、窗口位置、ItemSpacing 等全部
   因素，是权威值。手算 `鼠标y - 窗口y + scroll_y` 需要对每一帧的裁剪范围、样式变量
   建模，任何样式/DPI/滚动条细节变化都会让选区错位。询问 rect 让行命中在三行代码内
   做到与滚动/缩放无关的正确性（约 670–673 行注释）。

3. **为什么等宽字体 + O(1) 列换算？**
   `pixel → column` 若是比例字体需要逐字形测量，选中一行的列位置就得对行内前缀
   `CalcTextSize`——一次拖拽帧内成本为 O(行长) 次文本测量、跨多行即 O(line²)
   （约 710–715 行注释明确指出这是当年拖拽掉帧的元凶）。接收区本就为对齐 HEX/计数
   强制 `mono_font_`，字形前进恒定，列号 = `(mouse_x - row_x) / glyph_w` 一次除法。

4. **为什么字形宽要 64 个 `'M'` 均摊，而不是直接查 1.93 的 ImFontBaked 内部 API？**
   本项目 vendor 的是 Dear ImGui 1.93.0 WIP（`native/xcom_imgui/README.md` 第 9
   行），该代字体管线引入 `ImFontBaked`，取"单一字形前进宽"要触及未定型的内部结构、
   且需自行处理字号/DPI 烘焙档位。`CalcTextSize(64×'M').x / 64`（约 716–718 行）
   只用公开 API：均摊把任何字距/边界舍入误差除以 64，得到的 `glyph_w` 已含当前
   字号缩放，稳定、免维护、且每帧只测一次。

5. **行扫描/偏移表的复杂度控制。**
   偏移表在 `xcom_imgui_set_receive_text` 里每次文本变更重建一次（O(n) 尾扫，
   满带宽约 100 次/s）：`memchr` 借 CRT 的 SIMD 扫描在新行间跳跃，且先
   `reserve(len/32 + 2)` 一次到位，消掉 64 KiB 尾（约 2k 行）带来的 ~11 次几何
   扩容（约 1653–1663 行注释）。窗口收缩（`set_receive_window`）时保留的是旧文本
   后缀，旧偏移只需整体减去被擦除前缀长度即可复用，免重扫（约 1621–1636 行）。
   选区字节偏移指向 `receive_text_` 内部——滚动窗口截断前缀会让旧选区偏移失效，
   设计上以"下次按下即清零"覆盖该场景（不做悬空选区的补偿，简单且符合用户直觉）。

6. **绘制顺序即层级。** 色块在 `TextUnformatted` 之前画、且直接向
   `GetWindowDrawList()` 提交，因此高亮永远在字形之下，无需透明混合技巧。

---

## 四、代码位置速查表

| 内容 | 位置 |
| --- | --- |
| 选区哨兵常量 `kNoSelAnchor` / `kSelDragging` | `xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp:87-88` |
| 选区状态字段（anchor/begin/end/drag_origin/drag_hit） | `xcom_imgui_bridge.cpp:126-131` |
| 行偏移表字段 `receive_line_offsets_` | `xcom_imgui_bridge.cpp:135` |
| `ReceiveContent` 函数总体 | `xcom_imgui_bridge.cpp:635-833` |
| 弃用 InputTextMultiline 的注释 / 日志窗模式说明 | `xcom_imgui_bridge.cpp:656-662` |
| 按下开始拖拽（状态机入口） | `xcom_imgui_bridge.cpp:684-691` |
| 拖拽中标志 `sel_dragging` / `has_selection` | `xcom_imgui_bridge.cpp:692-695` |
| 等宽字体 PushFont | `xcom_imgui_bridge.cpp:700-704` |
| 64×'M' 均摊 `glyph_w` | `xcom_imgui_bridge.cpp:716-718` |
| Clipper 行渲染主循环 | `xcom_imgui_bridge.cpp:719-791` |
| `hit_offset_in_row` lambda（行命中 + 列换算） | `xcom_imgui_bridge.cpp:735-745` |
| 选区背景 `AddRectFilled`（相交判定 / 行尾铺满） | `xcom_imgui_bridge.cpp:746-765` |
| 拖拽命中与 begin/end 更新 | `xcom_imgui_bridge.cpp:767-788` |
| 释放后选区持久化 | `xcom_imgui_bridge.cpp:792-798` |
| 右键菜单 Copy selection / Copy all / Clear log | `xcom_imgui_bridge.cpp:809-831` |
| `xcom_imgui_set_receive_text` + memchr 行扫描 | `xcom_imgui_bridge.cpp:1639-1677` |
| CRLF→LF 归一化（`format_payload`） | `xcom_core/src/ao/xcom_ao.cpp:77,108-110,180-186` |
| Lua 推送接收文本 | `xcom_lua/ui/window.lua:1124-1128`；`xcom_lua/ui/imgui_bridge.lua:115-118` |
