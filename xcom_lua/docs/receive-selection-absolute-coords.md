# 接收区拖选高亮：绝对坐标重构说明

> 日期：2026-09-05 · 涉及：`native/xcom_imgui/xcom_imgui_bridge.cpp`、`ui/imgui_bridge.lua`、
> `ui/window.lua` · 关联文档：`win32-flickerfree-selection-todo.md`（§三-11/12 原则同源）

## 1. 症状（用户报告）

接收区持续来数据时鼠标拖选：

- 选区高亮**钉死在屏幕同一批行**上，被选中的文字从下面流走，高亮罩住的全是新内容；
- 正确行为应是：松开左键后高亮**跟着选中的文字一起上滚**，直到滚出可见区消失；
- 拖拽进行中同样会被"贴底跟随"抽走文本，选不中多行。

## 2. 根因

显示链路是一个**滑动窗口**：

```
core rx pool --10ms drain--> Lua tail (window.lua _flush_imgui_receive, 64 KiB 滑窗)
             --每次 flush 整块替换--> DLL receive_text_ --clipper 逐行渲染--> 屏幕
```

旧实现里选区偏移 `receive_sel_begin_/end_/drag_origin_` 存的是**窗口相对字节**
（"receive_text_ 里第 N 字节"）。而 Lua 每次 flush 都把整个窗口换血：窗口头部随着
新数据丢弃旧字节，窗口内的"第 N 字节"随之**指向完全不同的内容**。于是：

- 选中的行滚出窗口后，旧偏移自动"移情"到窗口头部的新行上；
- 渲染每帧按偏移所在行画高亮 → 高亮永远罩在顶部固定几行，看起来就是"选区不动"。

## 3. 修法：选区改用绝对（lifetime）字节坐标

### 3.1 C++ 侧（bridge.cpp）

- 新增成员 `receive_base_`：`receive_text_[0]` 在整条接收流中的绝对偏移。
- `receive_sel_begin_ / receive_sel_end_ / receive_sel_drag_origin_` 一律改存**绝对字节**；
  语义从"第 N 个显示字节"变为"第 N 个收到的字节"。
- 渲染（`ReceiveContent`）：取局部 `base = receive_base_`；
  - 高亮求交前把绝对区间映射回窗口：`sel_b = max(sel_begin - base, 0)`、`sel_e` 同理
    （被裁掉的部分正是"已滚出窗口"的选中内容，不再画）；
  - 拖拽命中 `hit_offset_in_row` 得到的窗口偏移 `+ base` 还原为绝对值再入状态。
- 右键"复制选中"：绝对区间先 clamp 到 `[base, base+len)` 再 `substr`——只复制仍
  在窗口内的部分，已滚出的字节不在显示缓冲里，无法恢复（数据无损由 auto-save
  日志保证，与显示窗口的取舍是既定契约）。
- 归零路径：空缓冲早退、`set_receive_text(NULL/0)`、`on_btn_clear` 同步重置
  `receive_base_` 与选区三元组；`set_receive_window` 缩窗 erase 分支 `base += erase_n`。
- 新导出 `xcom_imgui_set_receive_base(size_t)`（bridge.cpp:3196），Lua 在每次
  `xcom_imgui_set_receive_text` 之前调用。

### 3.2 Lua 侧

- `window.lua` 维护 `_imgui_receive_total`（lifetime 显示字节计数，
  `_append_imgui_receive` 累加、init/clear 归零）。
- `imgui_bridge.lua:set_receive_text(text, base)`：`base = total - #tail`，经
  `optional_export("xcom_imgui_set_receive_base")` 探测后先行推送。**旧 DLL 缺该符号
  时自动退化**为推送 base 失败 → native 保持 base=0 → 等价于历史窗口相对行为，不崩。

### 3.3 拖拽中的贴底冻结

```cpp
if (runtime.receive_follow_tail_ && !sel_dragging) ImGui::SetScrollHereY(1.0f);
```

按住左键时新数据不再把文本从鼠标底下抽走（否则选区永远够不到第三行以下）；
松开后选区恢复随流上滚直至滑出。`IsMouseDown` 每帧权威，不存在 capture 丢失导致的
永久冻结；与 `win32-flickerfree-selection-todo.md` §三-12"capture 中暂停跟随"一致。

## 4. 为什么不用内容前缀匹配（实现过程中的一个弯路）

曾考虑在 `set_receive_text` 内对比新旧缓冲求"本次丢弃了多少头部字节"。缺陷：

- 换行边界处内容可能逐字节相同，匹配窗口最长可到 64 KiB，热路径预算不可控；
- 本质是让 DLL 反向猜测 Lua 的窗口代数，契约脆弱。

改为 Lua 显式推送 base（谁拥有滑窗谁报告坐标），O(1)、零猜测。memcmp 方案已删除。

## 5. 验证

- `BUILD_OK`，DLL 部署 `runtime/`（2026-09-05 22:07）。
- 无头注入探针：VIRTUAL 口 `open_async rc=0` → `test_inject_rx rc=0` →
  `drain_display` 原样吐回 37 B，`rx_bytes=39`、`pool_exhausted=0`。
- 在线 E2E：`XCOM_SMOKE_OPEN=1 XCOM_SMOKE_SIM_PROFILE=text` 启动，
  日志区渲染 109 行模拟数据（`pic/sel_v41.png`），无脚本/引擎报错。
- 合成鼠标点击无法到达 ImGui Win32 后端（既有实证），拖选交互本身需一次人工验证：
  滚动流中拖选 → 松开 → 高亮应随文本上滚直至不可见；按住拖动期间视图应停住。

## 6. 遗留 / 后续

- 选中范围若被截断出窗口，右键复制只含窗口内部分；如需"复制已滚出的选中内容"，
  需要 Lua 保留被退役 chunk 的副本（当前按 64 KiB 窗口契约不做）。
- 边缘自动滚动（拖到客户区上/下沿逐行滚，todo §四-14）未实现。
- 双击选词 / Ctrl+C 快捷键未实现（当前右键菜单"复制选中"可用）。
