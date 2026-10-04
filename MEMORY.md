# C++17 现代特性与设计模式

本文记录 `SSCOM_lua` 工程中可复用的 C++17 约束、性能原则和设计模式。内容分为两部分：

1. coact 实时核心基线（外部 checkout `../coact`，`windows` 分支）。
2. `xcom_lua/native/xcom_imgui` 桥接层已经采用的 UI 结构。

## C++17 特性

### 编译期分支与类型约束

- 使用 `if constexpr` 根据类型属性选择零运行时开销的实现分支，例如 `pool.hpp` 中依据 `std::is_standard_layout_v<T>` 选择 `offsetof` 或手工布局计算。
- `constexpr` 函数和 `inline constexpr` 变量表达协议常量、无效索引和容量上限，例如 `pool_index_invalid`、`kMaxEventPools`。
- 使用 `enum class` 表达 `TransitionKind`、`AoRunState`、`Signal` 等状态，避免隐式整数转换。
- 使用类型萃取约束 ABI 与存储要求：`std::is_trivially_copyable`、`std::is_nothrow_move_constructible`、`std::is_standard_layout` 配合 `static_assert` 和重载。

### 无锁与内存布局

- 对并发环形队列、对象池的原子字段使用 `std::atomic`；在要求无锁的路径通过 `is_always_lock_free` 和 `static_assert` 固化平台假设。
- 对 freelist 头使用 32 位 tagged-CAS，将 `[tag:16|index:16]` 打包，避免 ABA stale-pop。
- 使用 `alignas(64)` 隔离生产者/消费者竞争字段，降低伪共享；使用 `alignas(16)` 保证描述符和数据块的 SIMD/ABI 对齐。
- 使用 `std::byte` 表示原始存储，避免把字节缓冲误当成字符或对象类型。

### 生命周期、所有权与错误处理

- `Expected` 的类型擦除存储使用 `Storage{std::byte bytes[sizeof(V)]}`、`alignas(alignof(V))`、placement-new 和 `std::launder`；析构只针对当前活动类型，避免未构造对象析构和严格别名违规。
- `std::exchange` 用于句柄转移和清空旧状态，`std::move` 用于回调、字符串和队列元素转移；移动构造、释放和热路径函数尽可能标记 `noexcept`。
- 可能失败的 API 标记 `[[nodiscard]]`，禁止调用方静默丢弃错误；资源包装器提供 `explicit operator bool()`，不允许隐式参与整数运算。
- Windows 句柄、文件流、OpenGL 上下文采用 RAII；失败路径与正常路径共享析构/关闭逻辑。

## 设计模式

### coact 实时核心

- **零开销抽象 / 类模板静态绑定**：`Hsm<Context>` 以模板静态绑定状态转移，保存表指针而不复制上下文，不在热路径执行 `new/delete`。
- **类型擦除 + 虚接口**：`AoBase` 提供最小 vtable，`Ao<Config>` 覆盖 `dispatch` 等操作；AO 使用静态或自动存储期，禁止经基类指针释放。
- **受限单例**：`g_pool_registry` 是唯一允许的可变全局注册表，保存非拥有指针；其它组件不得添加隐式可变单例。
- **策略模式（Policy-based design）**：`policy.hpp` 和 `config.hpp` 通过模板参数注入 core/profile 策略，在编译期决定批量回收、队列和调度行为。
- **对象池 + 引用计数 + ABA 标记**：固定容量池管理事件生命周期，引用计数控制共享所有权，tagged freelist 防止陈旧节点重新入队。
- **缓存行隔离**：队列位置、池头和高水位字段按缓存行对齐，减少多生产者/消费者之间的 cache-line bouncing。

### ImGui 桥接层

- **组件模式**：`PanelScope`、`Section`、`Field`、`Toggle`、`PrimaryAction`、`EmptyState` 统一视觉和生命周期。
- **命令模式（模板化）**：`Command<Action>::Execute()` 在编译期绑定动作类型，按钮只返回 ABI 兼容的动作掩码。
- **装饰器模式**：`StyleDecorator`/`WithRounding` 以 RAII 包装 ImGui style stack，确保异常或提前返回时成对 Pop。
- **动作掩码直返**：`xcom_imgui_draw_console` 累积的 Action 位掩码直接作为 C ABI 返回值交给 Lua 消费（单消费者场景不引入观察者间接层）。
- **描述表驱动**：`ComboSpec`、`ToggleSpec` 与 `std::array` 生成串口配置和发送选项，减少重复控件代码。
- **非拥有切片**：`Slice<T>` 只借用端口列表内存，提供 `constexpr/noexcept` 迭代，不产生临时容器拷贝。
- **策略化布局**：`assets/layout.toml` 提供侧栏宽度、间距、字体内边距和区域高度；解析失败时回退到编译期安全默认值。

## 性能原则（2026-09 内存优化轮）

### 已量化的内存构成（luvjit + ImGui 全栈）

| 层 | 实测 | 说明 |
| --- | --- | --- |
| 纯 LuaJIT + ffi spin 基线 | ~7 MB | `luvjit.exe -e "while true do end"` |
| `require("luv")` + 事件循环主动运行 | +~54 MB | libuv 线程池/堆；主程序从未主动进入，实际不占 |
| Intel HARDWARE DX11 UMD | +~65 MB | 用户态驱动管线 + 着色器缓存，本机实测 |
| **WARP + 单缓冲后全栈稳定值** | **~50 MB private / ~75 MB WS** | 2026-09-03 稳定采样 |

### 已验证的削减手段（按性价比排序）

1. **DX11 HARDWARE → WARP**（`D3D_DRIVER_TYPE_WARP` + `D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS`）：稳定私有内存约 50 MB，代价是每帧 45-60 ms CPU。串口控制台的 UI 复杂度完全够用。
2. **交换链 2 缓冲 FLIP_DISCARD → 1 缓冲 DISCARD**：flip 模型强制一个全尺寸 staging buffer，本 UI 不需要。
3. **帧率按因分级**（`window.lua`）：WARP 帧是纯 CPU 开销。交互 16 ms / 数据到达 100 ms / 空闲心跳 500 ms / 最小化跳帧；空闲 CPU 73% → 10%。`request_frame(interval)` 由"改了屏幕内容的代码"调用拉早下一帧，高频系统消息（NCHITTEST/PAINT/TIMER）不得触发，否则节流失效。
4. **核心固定池按波特率定容**（`xcom_config.hpp`）：`kRxBlockCount=128`（512 KiB）、`kDisplayBatchCount=32`（512 KiB）。921600 波特 ≈ 90 KiB/s，10 ms drain 节奏下余量为秒级。容量必须是 2 的幂（SpscRing 掩码）。
5. **无效手段（已实测否决）**：字体 atlas 裁剪（OversampleH=1 + Latin/ASCII 字符集 + 缩字号）只省 <1 MB，视觉损失明显，已回退；去 luv 省约 1 MB，不值得架构回归。

### 接收显示窗口（可配置）

- **配置项**：`config.ini` 的 `[display] receive_window_bytes`，默认 65536，Lua 与 C++ 两侧统一 clamp 到 **16 KiB..1 MiB**（`imgui_bridge.clamp_receive_window` 与 `xcom_imgui_set_receive_window` 的 `kWindowMin/kWindowMax` 必须保持一致）。
- **贯通链**：config.ini → `main.lua` → `cfg.receive_window_bytes` → bridge `M.new`（clamp 后经新 ABI `xcom_imgui_set_receive_window` 推入 DLL）→ C++ 侧 `ImGuiRuntime::receive_limit_`（运行时成员，设置时立即重裁尾部 + 重扫行偏移）；Lua 侧 `Window._receive_window` 驱动 chunk 裁剪。
- **回写契约**：`_save_config` 持久化 clamp 后的**有效值**——手改 config.ini 后跑一次程序，非法值会被规整为合法值写回。测试/预览脚本若硬编码 cfg 绕过该配置，退出时会用默认值**回写覆盖**手改配置（stress_warp_ui.lua 已改为读真实配置，新增此类脚本时必须警惕）。
- **下限/上限依据**：< 16 KiB 可视日志饥饿；> 1 MiB 时 `set_receive_text` 的 O(n) 行偏移重扫超出 WARP 帧预算。
- **裁剪实现（性能要点）**：`_append_imgui_receive` 用**游标**淘汰整块（`table.remove(chunks,1)` 的 O(n) 搬移改为 O(1) 前进），flush 时从游标 concat + 至多一次 `:sub(-window)` 尾部裁剪。整块淘汰仅在"淘汰后剩余仍超窗"时发生——否则超大中部批次由 flush 尾裁保住真实最后 N 字节（旧实现的整块丢弃会丢块内上下文）。
- 与 `max_display_bytes` 的区别：后者是 core 侧 ABI 字段但当前无消费者（`xcom_set_options` 只消费 hex_view/timestamp/pause_display），属遗留无效配置；显示窗口的真实上限由本配置控制，完整数据留存依赖 auto-save 日志。

### 接收渲染热路径（2026-09-04 性能优化轮）

满带宽（921600 波特）+ 实时渲染全程 CPU ~70% → **~33%**。全链路各环节的复杂度预算与手段：

| 环节 | 频率 | 手段 | 反模式（曾踩） |
| --- | --- | --- | --- |
| core 文本格式化 | 每接收块 | `format_payload<false>` 单遍 CRLF→LF 归一 | `memcpy` 原样拷贝把 `\r` 留给显示层 |
| 行偏移扫描（`set_receive_text`） | 每次 flush（≤100/s） | **`std::memchr` SIMD 跳扫** + `reserve(n/32+2)` 一次到位 | 逐字节循环（慢 4-16×）；clear 后 push_back 几何扩容（64 KiB 尾 ~2k 行 = 11 次 realloc/次） |
| 窗口收缩重索引 | 配置变更 | 后缀不变性：旧 offsets 减删除量（`lower_bound`+线性平移） | 全量重扫 |
| 渲染（`ReceiveContent`） | 每帧 | `ImGuiListClipper` O(可视行)；官方 `ShowExampleAppLog` 模式 | `InputTextMultiline`（stb_textedit 全量重排 + 只认 `\n` + 光标/滚动状态竞争） |
| 选择命中/背景 | 拖拽帧 | **等宽字体 O(1) 数学**：一次测量 64 个 'M' 均摊字形宽，`count × glyph_w` | 每字节一次 `CalcTextSize`（O(line²)）；每选中行两次整段测量 |
| 滚动跟随 | 每帧 | 帧首 `GetScrollY()>=GetScrollMaxY()` 判定脱开/重挂 + 帧尾写"尽可能靠下"的滚动目标（`SetScrollY` 大值，由下一次 Begin 用**本轮强制的**内容高度 clamp）；按住左键时冻结 | ① 旧实现 `SetScrollHereY(1.0f)` 写**具体位置**：写入与生效隔一帧，而尾窗是**帧外**追加的，于是贴底位置永远差一个批次（最新行进不了可视区）；② 子窗口的滚动条在 `Begin()` 内（body 之前）写目标、下一次 `Begin` 才生效，帧尾的 pin 会把箭头/拖动输入原地覆盖 → 贴底时滚动条"点不动" |
| Lua 接收裁剪 | 每次 drain | 游标淘汰整块 O(1) | `table.remove(chunks,1)` O(n) 搬移 |

要点与约束：

- **等宽 O(1) 数学的前提是 mono 字体**：字形宽测量用 `CalcTextSize(64×'M')/64` 而非 1.93 内部 `ImFontBaked` API（baked-font 结构是 1.93 WIP 的过渡接口，勿依赖）。ASCII 日志字节 1:1 映射字形；非 ASCII 用 '?' 近似，选择命中足够。
- **行命中测试用 `GetItemRectMin/Max`**（每行提交后的真实矩形），不要手算 scroll 偏移——`GetCursorScreenPos` 与滚动的语义极易算错。
- **接收区工具栏不得进滚动子窗**：作为日志内容会被滚走；用 `SetCursorScreenPos` 钉屏幕空间更糟——屏幕坐标不随滚动平移，行的内容空间偏移变成 `f(Scroll.y)`，内容高度随滚动增长、滚动上限自我放大（探针实测 190 行日志到 7 万 px），尾部永远够不到。现结构：工具栏是监控列的一行（该窗口 `NoScrollbar|NoScrollWithMouse`，不滚动），日志子窗只装行。
- **DLP：git 写出的工作区源码是密文**（头 `%TSD-Header-###%`，PowerShell 读到的是密文、`.NET` 写回的是明文）。后果是 `git checkout/merge/switch` 之后 **MSVC 编译必挂**：`C2018 未知字符 0x..` + `C1004 意外的文件尾`，看着像源码损坏。编译前先解密受影响文件：`python D:\DLP_Tools\dlp_decrypt_all.py <路径>`（或用 `git show HEAD:<path> | .NET WriteAllBytes` 直写，等价 `dlpctl.ps1` 的 git-blob 路线）。第 5 轮记的"源码永不走 bash 重定向写"是同一现象的早期版本。
- **CRLF 归一只在 core 显示路径**（`format_payload<false>`）：hex 视图与 auto-save 日志（同源 display 缓冲）分别保持字节忠实/随归一；行偏移扫描因此可以只找 `\n`（孤立 `\r` 已在上游归一，历史分支已删）。
- **`reserve` 时机**：热路径 vector 反复 clear+push_back 必须配 reserve；估算粒度无需精确（`n/32+2` 对 32 字节平均行宽，过估 2× 无害）。
- Lua 侧同源优化见"接收显示窗口"节的游标裁剪；GC 按 ≥128 KiB 堆增量触发（勿按"有无输入"，输入密集会饿死收集器、持续流量会过度步进）。

### 绘图代码效率规范（2026-09-04 绘图审查轮）

对全部 13 个绘图函数（Header/WindowButton/IconButton/Toggle/Section/Field/EmptyState/ReceiveToolbar/ReceiveContent/TransmitContent/ConnectionContent/Footer/GridComboField）审计后的结论与规则：

**已固化的正确模式（新绘图代码必须沿用）：**

- **图标/按钮/徽章一律 `draw_list` 直绘**（AddRectFilled/AddLine/AddCircleFilled/AddText），不走 ImGui 控件 + 文本布局；`WindowButton`/`IconButton`/`Toggle` 是范本。
- **文本用 `string_view` + `%.*s` / `TextUnformatted`**，零拷贝零临时 string；唯一例外是剪贴板/选中复制（`substr` 构造临时是必要的）。
- **style/child 栈全部 RAII**（`ScopedAction`），任何早退/异常路径都不会泄漏栈项。
- **描述表驱动**（`ComboSpec`/`ToggleSpec` + `std::array` + `RenderToggles` 模板），控件循环零重复代码。
- **Footer 计数用 `sprintf_s` 栈缓冲**（`char[48]`），不构造 std::string。

**每帧文本测量规则（本轮核心产出）：**

- **固定字面量的宽度是常量**——`CalcTextSize("XCOM")`、ONLINE/OFFLINE 徽章、Footer 的 "Ready"/"Open a port" 这类每帧重测纯属浪费（字形查找循环）。缓存模式：函数级 `static`，**以 `ImFont*` 指针为 key**——bridge 重启会 `DestroyContext` 重建字体对象，指针变化即失效重测。字面量两态的用 `float cache[2]` 按状态索引。
- **动态文本（RX/TX 计数）**：字符串变化才重测宽度（`strcmp` 比字形循环便宜几个量级）；格式化本身每帧照做（数字常变）。
- **指针缓存悬垂陷阱**：`ComboSpec` 存调用方 `int*`——**禁止**做函数级 static 缓存（Lua bridge 重建传入新地址，旧指针悬垂）。类似地，任何含调用方指针的描述表都只能每帧栈构造（5 个 40 字节结构体的代价可忽略，注释已记录在 `draw_console`）。

**有意不做的（记录决策）：**

- `ReceiveToolbar` 的 4 行单列 `BeginTable` 比纯 cursor 定位重，但重构影响布局，风险收益比不划算——除非未来证明它是瓶颈。
- `EmptyState` 的 `CalcTextSize` 仅空态冷路径执行，不缓存。

本轮收益量级诚实说明：单帧 ~5-10 μs（省固定文本测量），价值在规则固化与陷阱记录，不在数字。

### 测量方法论（防再踩坑）

- **纯 spin 探针会高估**：`require("luv")` 的 54 MB 开销只在 libuv 事件循环主动运行时存在；主程序路径的 `uv.run("nowait")` 立即返回，从不进入。判断某依赖的内存代价必须**在实际宿主程序**里量（A/B 两个 EXE 跑同一 main.lua）。
- **初始化中途数据会低估**：DX11 初始化期间读到的 8.6 MB 是假象；稳定值要等初始化完成后多测几次（间隔几秒取一致值）。
- **Private Bytes 反映驱动提交内存**，Working Set 受页面共享影响；评估"进程占用"以 Private 为准。
- **WARP 下 BitBlt 跨进程截屏返回全黑**，用 `PrintWindow(hwnd, hdc, 2)`（PW_RENDERFULLCONTENT）替代；窗口必须先 `ShowWindow(5)`。
- **空闲 CPU 用 GetProcessTimes 差分**（3 s 窗口），比任务管理器瞬时值客观。

## 实施边界

- `coact` 的无锁池、ABA 标记和缓存行对齐只用于事件/队列等并发核心；ImGui 窗口线程是单线程消息循环，不为 UI 强行引入原子或对象池。
- C ABI 的动作位、缓冲区布局和函数签名属于稳定接口；内部可使用强类型枚举和模板，但导出边界必须显式转换并保持数值兼容。
- 新增抽象必须证明能减少拷贝、分支或生命周期错误；避免为了展示设计模式而增加运行时分配和隐藏全局状态。
- **接收链路复杂度预算**（满带宽基线，见"接收渲染热路径"表）：每 flush 的行扫描、每帧的渲染、每拖拽帧的命中测试都不得引入超线性环节——新代码若在 64 KiB 尾部上做整段 `CalcTextSize`/逐字节循环/几何扩容即违规。改 `receive_*` 系列代码时先读该表的反模式列。

## 模式速查表

| 模式 | 当前实现 | 使用约束 |
| --- | --- | --- |
| 命令（Command） | `Command<Action>::Execute()` | Invocable 必须返回 `bool`；动作值在 C ABI 边界显式转换。 |
| 装饰器（Decorator） | `StyleDecorator<DrawFn>`、`WithRounding()` | 只包装可调用对象；style push/pop 必须由 RAII 配对。 |
| 动作掩码直返 | `xcom_imgui_draw_console` 返回 Action 位掩码 | 单消费者时优先直接返回；只有多订阅者解耦才引入观察者。 |
| 单例（Singleton） | `ImGuiRuntime::instance()`、coact `g_pool_registry` | 仅允许一个受控可变实例；禁止新增隐式全局状态。 |
| 策略（Policy-based） | coact `policy.hpp` / `config.hpp` | 用模板参数选择策略，避免热路径虚调用。 |
| 零开销抽象 | `Hsm<Context>`、`Slice<T>`、描述表模板 | 优先静态绑定、借用视图和 `constexpr`，不复制上下文。 |
| 类型擦除 | `Expected` 存储、`AoBase` vtable | 明确对象生命周期和所有权，禁止错误释放。 |
| 对象池 | coact 事件池与 tagged freelist | 固定容量、引用计数、ABA tag 必须同时满足。 |

## 相关入口

- `../coact/include/coact/pool.hpp`
- `../coact/include/coact/expected.hpp`
- `../coact/include/coact/hsm.hpp`
- `../coact/include/coact/ao.hpp`
- `../coact/include/coact/policy.hpp`
- `xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp`
- `xcom_lua/native/xcom_imgui/layout.toml`

## 参考与依赖资料索引（third_party/ + ref/）

> 本节是 `third_party/README.md` 与 `ref/README.md` 的要义索引，供后续协同不迷失。

### third_party/README.md —— vendored 依赖地图

- **结构分两半**（README:9-12）：
  - GUI/native（编入 `xcom_imgui.dll`）：`imgui*`、`cimgui*`、`LuaJIT-ImGui`、`xcom_imgui` —— C/C++，LuaJIT 经 FFI 进 DLL。
  - Pure Lua（`require` 直接用）：`openresty-lua`、`lua51-libs`。
- **实际被 CMake 编入 DLL 的是哪一个 ImGui？**：⚠️ README 第 26-31 行描述的「imgui-docking 走 cimgui + LuaJIT-ImGui」**与实际不符 / 过时**。实测 `xcom_lua/native/xcom_imgui/CMakeLists.txt:7` `IMGUI_ROOT=third_party/xcom_imgui/imgui`，编译的是 **Dear ImGui 1.93.0 WIP 直连**（`imgui.cpp/_draw/_tables/_widgets + imgui_impl_win32 + imgui_impl_dx11`），不走 cimgui。`third_party/xcom_imgui/` 现有 `imgui/ + cimgui/ + implot/ + LICENSE.txt`。**改字体/主题/绘图 API 参考这个 1.93 WIP 源码树，勿照 LICENSE 里旧 docking 版。**
- `xcom_imgui/` 是项目自有层（README:69-78）——本项目直接就地编辑的 UI 桥。
- `openresty-lua`：A 级可用（`jit/*`、`resty/lrucache`、`resty/iconv` 已 patch）；`resty/md5,sha,aes` 需 OpenSSL FFI（B 级）；已配 `libiconv-2.dll` 于 runtime（改 `xcom_client/runtime`？注意本项目挂在 `xcom_lua/runtime/` 下）。测试 `tests/test_openresty_lua.lua`、`tests/test_iconv.lua`。
- `lua51-libs`：**禁 `stdlib-ext/*`（污染全局）**则用 Penlight `pl.stringx/tablex/utils`。测试 `tests/test_lua51-libs.lua`。
- 缺 `.dll` 引用（lfs/luasocket/lpeg）需自行 FFI 或打包 LuaJIT 2.1 ABI 版（README:189-192）。

### ref/ —— 项目本地参考源码 + 依赖副本

`ref/README.md` 把 40+ 项按可参考性分为 6 梯队。**总原则：先读速查表区（第 283-305 行）选项目，再看各梯队注释。** 参考文档产出在 `xcom_lua/docs/`（多为本轮 agent 成果）：

- **直接对标**：`llcom/`（README 说 Lua+ImGui —— **纠错**：实为 WPF+C#/XLua，非 ImGui，只可借鉴架构/API 思想）、`SCOMMV23/`（SSCOM V2.3 原始 VC++）。
- **核心 vendored**：`imgui/`、`implot/+implot_demos/`、`luajitImGui/`、`imgui-filedialog/`、`ImHex/`。
- **UI 参考**：`edgedepth-terminal/`（60 FPS 多面板 ImGui，最像咱接收区；`docs/imhex-reference.md`、`docs/imgui-implot-reference.md`、`docs/ui-reference-tools.md` 已整）、`SDRPlusPlus/`、`amodemGUI/`（⚠️只含 Linux 二进制无源码，价值低）、`uscope/`、`tracy/`（性能基准）。
- 参考用法：新增参照项目时用 `curl tarball`（README:311-317 缓存 zip 于 `ref/zip`，可清理）。
- **陷阱**：`AXIOM-Remote` 默认分支 `dev`；`cycloid/furnace` tarball 含 symlink 会被 Windows 跳过；大项目体积多为图标/资源而非源码。

> 记录时点（2026-09-05）：`ref/` 已含 3 位 agent 产出的多份参考笔记；2026-09 已按主题合并为
> `xcom_lua/docs/{llcom-reference,imhex-reference,imgui-implot-reference,ui-reference-tools}.md`。

### 本轮（第 3 轮，Lua 脚本系统）更新

- **ImPlot v1.1 WIP 已克隆**至 `third_party/xcom_imgui/implot/`（git clone master，与 ImGui 1.93 WIP 同代）。API 要点：v1.0 起删除 `SetNextLineStyle` 系，改用 `ImPlotSpec{LineColor, Offset, Stride...}`（implot.h:517-606）；`BeginPlot(title_id, size, flags)`（:769）；`PlotLine(label, xs, ys, count, spec)`（:992）；`DragLineX/TagX/Annotation`（:1082-1090）。集成路径见 `docs/imgui-implot-reference.md`（bridge.cpp 追加骨架 + Lua 推送封装，时间戳必须用 `uv.now()` 而非 DeltaTime 累加——被动 16-100ms 帧率下会欠采样）。
- **agent 研究文档已合并归档**（`xcom_lua/docs/`）：`imgui-implot-reference.md`（官方 examples/demo + ImPlot v1.1 + implot_demos 模式；含"DX11 后端支持 RendererHasTextures 动态字体"发现）、`imhex-reference.md`（主题 JSON + ImGuiExt 控件库 + 代码模式，采纳：三层绘制高亮/颜色缓存失效/TextFormattedSelectable；不采纳：8000 行自绘 TextEditor、View 注册树）、`ui-reference-tools.md`（edgedepth/SDRPlusPlus/tracy/uscope/wave-gui/amodemGUI/ImGuiFontStudio/WaveEdit 综合；含 CJK ranges 补 Japanese+假名段、WaveEdit 自适应网格/2 的幂缩放吸附）。
- **CJK 字体现状**：bridge.cpp 已用 `GetGlyphRangesChineseSimplifiedCommon` + `GetGlyphRangesJapanese` + 假名段（0x3040-0x30FF）+ msyh.ttc MergeMode；P1 缺口（SJIS 假名流）已补齐。
- **charset 转码双保险**：`core/charset.lua`（FFI 直调 MultiByteToWideChar，支持跨批 DBCS 位置感知挂起 + UTF-16 代理对）为主；`xcom_lua/libs/openresty/lualib/resty/iconv.lua`（已 patch，runtime 有 libiconv-2.dll）为备选（跨平台/更多编码时切换）。

### 本轮（第 4 轮：1.png 控件深抠 ×5 + UI 观感对齐核心决策）
> 视觉基准 = `pic/1.png`（1802×1291 串口浅色工具），Read 看 PNG=Unsupported，全部用 PIL 逐像素。五份像素 doc 齐（`xcom_lua/docs/`）：`1png-control-buttons.md`(A) / `1png-input-select.md`(B) / `1png-icons.md`(C) / `1png-separators-status-font.md`(D) / `1png-sendzone.md`(E)。
- **D/E/A 主体是负性结论**（1.png 无实心钮/大圆角卡/ONLINE-OFFLINE pill/圆点徽章/✓ 复选/底部发送坞-编辑器-分页-Loop-实底 SEND），都需按"克制+中文文案+ms"自设重建，勿抄外形。像素规格与校验锚见 `xcom_lua/docs/1png-*.md` 五份。
- **已落地的核心改动（bridge.cpp）**：`PrimaryAction`(Open/Run)/`DangerAction`(Close) 从实心蓝/红改**白底 #FEFEFE outline**（Open 深字 #1B1B1B、Close 红字 #C00500；淡边=全局 FrameBorderSize=1 + ImGuiCol_Border #D5D5D5@0.9）。`SendAction` 保实心蓝。v9 像素 diff 证侧栏 Open 实心蓝 slab 被清、`#005A98` 1391→952。
- **本版本桥的像素级判定**（#16，可不做/勿盲做）：
  - E F3（ms/秒）：bridge 两个周期 InputInt(`##send_period`:1212 / `##multi_period`:1316, 后缀都 ms)本就是**内部一致的整数 ms**，无功能 bug；把 Multi"定时"改成秒会**破坏 ms 语义**（回归）。不改。
  - B④(47px 行距)：1.png 配置是**左宽列 label 上叠竖排组合**（x241..399 159px 一行）；桥配置是**右窄栏 #EDEDED ~179px 两列 label+combo 横排表**（`##serial_grid` :1404 2col）——**不是同一几何**，硬套 47px 只会在挤侧栏加空白。不改。
  - B②下拉箭头灰/B③DTR-RTS chip：xcom 用 `Toggle()`(:1441, 28×kToggle 自绘) 与 ImGui 默认箭头，属 xcom 自设；1.png 的 33px 墩/灰三角为参考，不盲换。
- **接线/字体/文档约束**：桥编的是 ImGui 1.93 WIP（`third_party/xcom_imgui/imgui`, CMakeLists IMGUI_ROOT, 非 cimgui/README docking）。画线 `AddLine(p1,p2,col,th)` 无 cap flags（手绘圆端用 `AddCircleFilled`）。正文16±、强调 #004270、发丝 #EDEDED。

### 本轮（第 5 轮：全 UI 中文本地化 × 最小 CJK 字形 × 无头验证基建，2026-09-05 晚）
> 承接第 4 轮 1.png 观感收口。本轮把"中文桌面工具"真正落地（此前 label 走英文兜底），并首次建成无头 UI 验证链；行号有漂移时以函数名 + 近似行号为准。锚点均在 `xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp`（下称 bridge）。
- **全 UI 中文本地化**：`struct Lang`（bridge:100，`for_each_text`:180）+ 两张 constexpr 表 `kLangZh`（:222）/`kLangEn`（:260）；`lang()`（:461）按 `ui_lang_zh_` 选表。活动语言在 `load_layout_config` 从 `assets/layout.toml` 的 `[ui] language = "zh"|"en"` 解析（:2594，缺省 zh，贴 pic/1.png 中文基准；扫描器把 `[layout]/[font]/[ui]` 三节并入单遍，section 号路由）。**第 2 轮补**：header 副标题（`subtitle` "串口助手" :244）、右键菜单（`##receive_context` :1500）、脚本控制台（`scripts_title` "脚本控制台" :239）、scope 标签（`scope_title` "波形"）。audit 发现 20 处 label 未过表→全部接线，无残留硬编码。
- **最小 CJK 字形烘焙（关键决策）**：不再用 stock `GetGlyphRangesChineseSimplifiedCommon`——~3700 字形 × 4 个尺寸撑爆 WARP 软光栅 atlas 预算，且**静默不画**（整帧丢字无报错，见 :2823-2826 注释；mono 字体下方同源文档）。改由 `Lang::for_each_text` **从活动 label 集反推字形**：`ImFontGlyphRangesBuilder::AddText`（:2831，栈构造，8KB bitmap 禁 static）+ `"0123456789"` → `ui_glyph_ranges_`（Runtime 成员持指针，atlas 存的是裸指针须比 builder 活得久，:414）。`merge_ui_glyphs`（:2840）以 `MergeMode` 把 `msyh.ttc`（正文）/`msyhbd.ttc`（粗体标题）/`simsun.ttc`（回退）并进 **body 13/15/17**（`kBodySizes` :2859，15px 为默认面）+ **heading 16**（:2876）。~120 字形量级，atlas 安全。
- **CRTP `NonCopyable<Derived>` tag base**（bridge:592，protected ctor/dtor + 非虚 + 删拷贝）：`PanelScope`（:601）/`ScopedHeadingFont`（:650）/`ScopedAction`（:666）三处私有继承——§5.9 三个同形 RAII 门槛已达，值得抽基类；析构非虚杜绝 slicing，Move 仍隐式删除（derived 声明了 dtor）。`Lang` **定义点 static_assert**（§5.4）：`is_standard_layout_v && is_trivially_copyable_v`（:216）+ `parity_items/flow_items/serial_field_labels` 尺寸与 Lua `PARITY_ITEMS/FLOW_ITEMS` 锁死（:217-219）。`Action` 位掩码只在 constexpr 辅助里窄化到 `std::uint32_t`（`action_mask`:509 / `send_slot_action`:525），导出 ABI 仍 `int`（`Command<Action>::Execute` 返回 int :532，数值兼容）。
- **Header/Footer 两处观感修复**：① 状态文字与 Set/Scope/Lua chip 簇重叠——chip 簇起点为 `button_group_start - 144`，故引入锚点 `kChipClusterLeft=144.0f`（bridge:997），状态文字定位到整簇左侧（旧 `-12` 偏移会把字压到 Scope/Lua 上 :998）。② Footer 顶部 1px 分隔线：`AddLine` 在 .5 偏移把 #8C8C8C 抗锯齿混进 #FEFEFE 带 ≈ #C5C5C5（超出 verify ±20 契约）→ 改 `AddRectFilled` 整数高一行单扫描线绘出真实 #8C8C8C（:1886-1890），对应 `verify_v10.py` **check #8 `footer_rule_8c8c8c`**。
- **图标位置**：`UtilityIcon` 的 path/save/clear 三枚从 **180px 侧栏**（窗边被裁，:1164 注释）移到**接收区顶部工具栏右对齐**（`ReceiveToolbar` :1024/1171-1180，用户选定，合 UartAssist/SSCOM 惯例）。"更多"高级带 `constexpr bool kMoreSectionEnabled=false`（:1757，`if constexpr` 编译期关，代码按用户要求保留待复启）；DTR/RTS 两个 modem Toggle 上移到「打开」按钮正下方（:1729-1734）。
- **`send_file.lua` 真实泄漏修复**：`step()` 完成分支（:79-88）与 port-closed 分支（:94-100）此前只 `state.timer=nil` 而未 `sys.timer_stop` → 已 fired 的一次性 uv handle 仍被引擎 `timers` 数组强引用（仅 `timer_destroy` 摘除），死 handle 常驻到进程退出。两分支补 `sys.timer_stop` 后再置 nil（与 `schedule()` 自续前回收旧句柄同理）。`tests/test_send_file_caps.lua` 重写为 **23/23 PASS**：覆盖 32MB stat-first 上限（`script_engine.lua:380` `file_read`：`FILE_READ_MAX=32*1024*1024`(:76)，`>32MiB` 直接返回 nil、`fs_open` 从不调用；`==32MiB` 放行）。
- **Scope Lua 包装**：`ui/imgui_bridge.lua` 的 `M:set_scope_visible`(:240)/`M:scope_clear`(:290)/`M:scope_configure`(:300) 薄封装对应 C 导出（`optional_export` 兜缺失符号）+ `scripts/scope_demo.lua`。脚本经 `env.wave`（script_engine.lua 注入）触达 scope，沿用 wave_demo 推数据模式。
- **无头验证基建（本轮核心可复用产出）**：**合成鼠标点击到不了 ImGui Win32 后端**（实证：3 次点击产生 3 张逐字节相同的 BitBlt 帧）→ 弃"注入点击"路线，改 env 钩子：`Window:_smoke_env_hooks`（`ui/window.lua:1420`，仅 `XCOM_SMOKE_SETTINGS=1`/`XCOM_SMOKE_SCOPE=1` 时镜像 header chip 开窗，正常运行严格 no-op）+ `scripts/smoke_ui.lua` 灌数据。截屏走 `PrintWindow(hwnd,hdc,PW_RENDERFULLCONTENT)`（WARP 跨进程 BitBlt 全黑，见"测量方法论"）。**时序**：首帧完整渲染约在启动后 **2.4 s**，早于此截到黑帧——截屏前必须等。
- **串口模拟器（in flight）**：`core/serial_sim.lua` 把字节喂进 core 的 **VIRTUAL/TEST\* 进程内虚拟口**（`xcom_core/src/abi/xcom_abi.cpp:is_virtual_port` :40，规则=精确 "VIRTUAL" 或 "TEST" 前缀；Lua 侧同名规则 :74），经 `xcom.test_inject_rx`（`core/xcom_ffi.lua` 的 `test_inject_rx`）注入 → **真实显示管线全跑通**。文档化 non-goal：不碰 COM 注册表枚举、不模拟 DCB。
- **验证状态**：v15 干净 dashboard `verify_v10.py` **8/8 PASS**；v23 开着"设置"窗截图，实证中文渲染（含第 2 轮 subtitle/右键菜单/脚本控制台/scope 标签）。本轮快照编号 **v12–v23**。
- **本轮踩坑固化**：① bash 重定向进 cmd 子进程会被吞（改用 `powershell -Command "cmd /c ..."` + `iconv ... -f GBK`）；② Grep/Read 显示吞掉 `\r`（纯显示假象，文件本身完好）；③ DLL 实读的是 **`runtime/assets/layout.toml`**，改了 `assets/` 必须同步过去；④ DLP：源码永不走 bash 重定向写（见全局 CLAUDE.md）。

### 本轮（第 6 轮：模拟器 E2E 打通 × 接收区拖选绝对坐标重构，2026-09-05 深夜）
- **串口模拟器完工（第 5 轮 in-flight 项收口）**：`core/serial_sim.lua`（profiles text/gb2312/hexbin/modbus/at-modem/wave/echo；20ms uv pump + pending ring + `tx_observe` 回环/AT 响应）+ `scripts/sim_control.lua` 插件页 + `tests/test_serial_sim.lua` **47/47 PASS**。window.lua 接线以 `_sim_active`（`xcom.list_ports()` 为空才激活）门控——有硬件的机器行为逐位不变。E2E 冒烟：`XCOM_SMOKE_OPEN=1 XCOM_SMOKE_SIM_PROFILE=text|wave` 程序化打开 VIRTUAL 口，stderr 确认 `[sim] pump armed`，text profile 日志区实测渲染 **109 行**数据（`pic/sel_v41.png`），wave 喂 Scope。headless probe 独立证实注入→drain 字节精确（37B 进 39B 计）。
- **全量回归（agent）**：**零真实回归**。12 个逻辑测试全绿；6 个串口测试缺 COM 属环境性 SKIP；4 个库测试仅因 `third_party → xcom_lua/libs` 迁移未完成（libs/ 空、未跟踪），镜像正确树后 78/43/51/9 全绿。**待办**：完成 libs/ vendoring 或回退测试路径改动。
- **接收区拖选 BUG 重构（用户报告：选区钉死在屏幕同一行，不随文本上滚）**：根因 = `receive_sel_begin_/end_` 存**窗口相对字节**，而 Lua `_flush_imgui_receive` 每次把整个 64KiB 滑窗换血推给 `xcom_imgui_set_receive_text`——偏移随窗口漂移，选中内容被顶出后偏移"移情"到新内容上，高亮就永远罩在顶部固定几行。修法 = **绝对 lifetime 坐标**：Runtime 新增 `receive_base_`（`receive_text_[0]` 在全流中的绝对偏移，bridge:370）；selection begin/end/drag-origin 全部存绝对字节；渲染时 `line_off` 与 `[sel_b, sel_e)` 比较前先减 base（ReceiveContent 的 `base` 局部量），拖拽命中把窗口偏移 `+ base` 还原为绝对；右键"复制选中"把绝对区间 clamp 回窗口再 substr；`xcom_imgui_set_receive_base(size_t)` 新导出（Lua 在每次 `set_receive_text` 前推 total-#tail）；空缓冲/清空/关闭路径重置 base+选区。旧 DLL 缺符号时 Lua 侧 `optional_export` 探测失败则退化为原窗口相对行为，不崩。
- **拖拽体验细节**：拖选中冻结贴底跟随（`if (runtime.receive_follow_tail_ && !sel_dragging) SetScrollHereY`）——按住左键时新数据不再把文本从鼠标下抽走；松开后选区随流上滚直至滑出窗口（符合"选中的区域应该在上面，或者已经看不到了"）。与 `xcom_lua/docs/receive-selection.md` 的"capture 中暂停跟随"原则一致。
- **v23-vs-1.png 十项视觉差距（agent 像素审计，留作下轮 restyle 输入，按影响排序）**：①头部 chip→无边框图标 ②侧栏位置/底色（右#EEEEF0 vs 参考左白+1px #EFEFEF ③缺 3px #005A9E 工作/发送区分隔线 ④页脚顶线+琥珀计数+链接应 #004275 ⑤头分隔线 #C6C6C6→#EDEDED ⑥Logo 实心块→轮廓字形 ⑦内部 hairline 偏重 ⑧工具条字形应 #1B1B1B ⑨离线状态移页脚（可选）⑩发送按钮箭头→#FFFFFF。多数为 bridge palette 一行改色。
- **验证状态**：DLL 已部署 runtime/（22:07 版含 base 重构 + 拖拽冻结）；应用以 `XCOM_SMOKE_OPEN=1 XCOM_SMOKE_SIM_PROFILE=text` 运行中（PID 38836）。**注意**：WARP 下 PrintWindow 可能截到纯黑帧（DX11 呈现线程空闲时不重绘），需先 `SetWindowPos` 挪 2px 逼一次真实帧再截（snap.py 已含 ShowWindow+SetForeground，但挪窗技巧未固化进脚本——待办）。
- **本轮快照**：v30–v41（含 `pic/sel_v41.png` = text 流 109 行取证）。

### 本轮（第 7 轮：接收区贴底/滚动条修复的实机验证 × DLL 重编，2026-09-14）
> 承接 `story-fix(dm): reach the receive log's tail and keep its toolbar put`（daded13：bridge 源码已改，但提交信息自认 `runtime/xcom_imgui.dll` **仍需 Windows 重编**）。本轮把 DLL 编出来，并逐条实测用户提的三个行为。行号以符号/函数为准。
- **DLL 重编（本轮关键交付）**：`runtime/xcom_imgui.dll` 之前是**修复前**的二进制（daded13 只改了 bridge.cpp），仓库、MSI、直接跑树都发旧件。按 `xcom_lua/native/xcom_imgui/build_imgui.cmd` 同参数（vcvars64 + `D:\Python314\Scripts` 的 cmake/ninja）重编并部署，签入件 sha256 `64E3AD38…`（先落地的 `C4C61958…` 是应用在跑、copy 静默失败留下的旧实现二进制，见下条踩坑）；修复前件（49ed3c8 源码）留在 `D:\workspace\_xcom_verify\xcom_imgui_prefix_dll_D72E6561.dll` 供 A/B。**注意**：`native/xcom_imgui/build/` 里是旧对象，改完源码要让它重编（mtime 变了即可），别只看 `copy`。
- **三个行为的实测结论（全通过）**：数据源 `XCOM_SIM_FORCE=1 XCOM_SMOKE_OPEN=1 XCOM_SMOKE_SIM_PROFILE=text`（sim 的 20ms pump 在**帧外**注入，正是尾窗增长的真实时序），并把 auto-save 日志当外部基准比对"最新已生成行"。① **持续收数据时最后一行可见**：4/4 采样，日志底行行号落在截图前/后基准之间（样本 3：底行 000299，基准 298→300），且该行完整绘制未被截断。② **贴底时滚动条可动**：滚轮 5 格把滑块 406..429 → 370..391；按住滑块本体上拖 150px → 418..429 → 268..279（按下瞬间滑块转 `ScrollbarGrabActive` 色，证明命中）；在滑块上方轨道按住 = 连续翻页。随后**跟随脱开**：继续来数据 2s，滑块停在 347..366 不动。③ **回到最底重新挂上**：把滑块拖到轨底释放后停在 413..429，之后 3s 持续数据仍钉在底部（最新行 516→565），底行即最新行。
- **A/B 对照（修复前件）**：同样三个探针全部失败——日志区显示 **000001..000025** 而最新已生成 **456**（尾部根本够不到，与 daded13 描述的"内容空间随滚动自我放大"吻合）；同一次 150px 上拖把视图推向**反方向**（滑块 375..386 → 418..429）。
- **滚动条箭头（用户要求补齐，已实现）**：vendored **ImGui 1.93.0 WIP 的 `ScrollbarEx` 已不含 ArrowButton**（`imgui_widgets.cpp` :1031+），style 里也没有箭头尺寸字段可开；`pic/1.png` 参考图同样只有轨道+滑块。用户明确要箭头 → 在 bridge 自绘 `ArrowScrollbar()`（bridge:1294），**不动 vendored ImGui**：接收日志子窗改 `ImGuiWindowFlags_NoScrollbar`（滚轮不受影响，`UpdateMouseWheel` 只拦 `NoScrollWithMouse`），右侧 12px 画 Windows 式竖条（轨道 + ▲/▼ 三角 + 滑块）。**关键设计**：整列只用**一个** `InvisibleButton`，区域（-2/+2 箭头=1 行/步、-1/+1 轨道=1 屏-1 行、0 滑块=绝对 seek）在**激活帧锁存**（同 ImGui `ScrollbarSeekMode`）——每区域各占一个 item 时，翻页把滑块挪到光标下就丢 ActiveId、按住不连发（本轮实测踩到）；连发用 `ImGuiItemFlags_ButtonRepeat`（1.93 取代 `ImGuiButtonFlags_Repeat`，`PushItemFlag` 公开）。另加 `over_scrollbar` 判定，把日志"按下即拖选"挡在条外。**注意这是对 `pic/1.png` 的有意偏离（用户要求）**，后续 restyle 别再把它当差异修掉。
- **箭头实测**：新进程不碰鼠标 → 滑块在轨底且底行=最新行（000321 vs 最新 323）；贴底单击上箭头 → 视图脱开（2.5 s 后底行仍 000325 而最新 374）＝输入不再被 pin 吃掉；按住上箭头 1.5 s 滑块再上移 44px（纯流失只有 ~29px）＝连发在走；按住轨道 1.5 s 滑块跨 190px（≈50 屏）；拖滑块回底 → 钉在 402..418，1.8 s 后仍 403..418（最新 487→517，底行 000515）＝跟随重新挂上；滚轮仍可滚且脱开；日志区拖选后 Ctrl+C 剪贴板拿到 4 行文本，在滑块上拖则剪贴板不变（不误选）。
- **踩坑：应用在跑时 `copy` 部署 DLL 会静默失败**——bridge 改完重编，"runtime 更新"其实没发生，于是**提交/推送进去的是上一条实现的二进制**（源码与产物不一致）。是 `build_release.ps1` 的"runtime 的 imgui DLL 必须不比 build 输出旧"闸门抓出来的（那个闸门别删！）。规矩：改 DLL 前先关应用，且构建脚本里 `copy` 后必须 `if errorlevel 1` 报错，别只看 `BUILD_OK`。
- **贴底重挂的竞态（本轮修掉）**：跟随 latch 比的是**像素**，而接收缓冲按**整行**增长，所以"拖到最底"那一帧的底 ≠ 下一帧的底 → 松开后约 1/3 概率差一行、跟随不重挂（实测复现）。修法：`ArrowScrollbar` 里算出的 scroll 一旦到达 `scroll_max`，就改写成**尾目标** `SetScrollY(kFollowTailTargetY)`（下一次 Begin 用那帧内容 clamp，与 pin 同一套惰性解析）→ 修后 3/3 重挂。
- **修正第 5 轮结论**：当年记的"合成鼠标点击到不了 ImGui Win32 后端"**不成立**——`SetCursorPos` + `mouse_event` + `SetForegroundWindow` 能完整驱动 ImGui（滑块 hover/active 配色、拖拽、滚轮全部有反应）。当时的"3 次点击 3 张相同帧"应是点在无可见副作用的控件上。做 UI 输入测试时：确认 `GetForegroundWindow() == hwnd`，并**按像素图定位命中目标**（本轮有一次按在滑块下方 4px 的"翻页区"，行为完全相反，白排查了半天）。
- **测试基建**：新增 `XCOM_SIM_FORCE=1`（`ui/window.lua` 的 sim 构造把 `enabled` 交给环境变量），让 registry 里只有**幻影 COM 口**（本机 COM3，枚举得到但打不开）的机器也能进 E2E 冒烟路径；不设该变量时策略与原来逐位一致。探针脚本 + 两张取证截图留在 `D:\workspace\_xcom_verify\`。

### 本轮（第 8 轮：勾选项持久化 × 异常识别 × 配色可读性 × DLL 陈旧门禁，2026-10-03）
> 用户诉求四条：记住所有勾选项（尤其多选页）、打开/发送要快、右键菜单去二级、配色再斟酌；外加 MCU 上下电与被占用识别。以下为本轮**评估后的收口修正**（承接前序实现，逐条独立复核）。
- **ABI v1.7（`XcomSnapshot` 追加 `modem_lines`，88B）**：只追加、`struct_size` 前缀兼容，`xcom_get_snapshot` 的“地板”改成 `offsetof(XcomSnapshot, modem_lines)` 并加两条 `static_assert`——v1.8 再追加字段时会**编译失败**，逼着改地板，避免把新字段写进旧调用方的 84B 缓冲。三层 pin 同步（`xcom.h` / `xcom_ffi.lua` SIZEOF=88 / `tools/hw-tests/abi_pins.lua`）。
- **`poll_line_status` 新增 `GetCommModemStatus` 的开销上界**：读线程 50ms tick（`kReadTickTimeoutMs`）× 4KiB 读块 ⇒ 每完成一次 ReadFile 一次 IOCTL，实测**≤25 次/秒**，不是每字节；空闲行不再进 `line_status_ingress`（原实现从不产生全零回调，故行为保持）。
- **“被占用”识别收窄（本轮修正）**：错误环里 `ERROR_ACCESS_DENIED(5)`/`ERROR_SHARING_VIOLATION(32)` 也可能来自**读故障**（source=2），旧判据只比错误码会把上一次打开目标误标。现要求 `source==2` + 码命中 + **`_pending_port` 非空**（打开请求已发出且从未见到 OPEN）；`_pending_port` 在 OPEN 边沿与 `core_close` 清空（此前全文只赋值、从不清除）。
- **MCU 掉电提示的覆盖范围写清**：只在 CTS/DSR/RLSD **实际接线**时有效——3 线（TXD/RXD/GND）是 MCU 最常见接法，桥片会把这几根钉住不动，此时该检测静默，只能靠 RX 静默告警；DSR 单独落下且我方 DTR 未拉高时仍抑制（对端 DSR 可能跟随我方 DTR）。文案由“可能是 MCU 掉电”改为“若该线接到对端电源/握手，可能是 MCU 掉电或复位”。
- **配色可读性（sRGB 相对亮度实测复算，WCAG AA 正文 4.5:1）**：`8C8C8C`3.36→`6A6A6A`5.41（muted）、`F8AA00`1.96→`9C6000`5.14（时间戳，白底上原色连 3:1 都不到）、`E53935`4.23→`C62828`5.62、`FFB300`1.79→`8A6D00`4.92、TabActive 由实心 `005A98`（正文仅 2.39:1）改浅底 `C9E2F5`（12.86:1）+ 1px 上划线。**注释里的比值本轮修正**：`8A8A8A`3.45（非 3.36）、`D5D5D5`1.47（非 1.43）、`7E868E`白钮 3.69（旧 1.38 非 1.35）、`ImGuiCol_Border` 旧值按 alpha 0.9 混白后 1.74（非 1.81）。
- **`[colors]` 生效范围补全**：原先只有 3 个 ImGui 槽 + 2 处绘制点读配置，`layout.toml` 却声称 text_body/text_muted 覆盖“所有标签/正文”。现加 `body_text()/muted_text()` 两个访问器，把 14 处硬引用 `palette::kTextBody/kTextMuted` 全部改为读配置——改 `[colors]` 真的能改全局正文色。
- **性能断言复算**（LuaJIT 2.1 x64）：`text:match(".*()\n")` 无 LF 时 1KiB/3KiB/8KiB = **5/48/327ms**（二次方成立，新实现微秒级）；但**带 LF 的批次新实现略慢**（1638 行 0.013ms vs 0.0025ms，受 4KiB 读块上界约束），注释已按实测改写，不再声称“带 LF 也更快”。`gsub` 4KiB 实测 55µs（原注释 26µs 已更正）。
- **`max_display_bytes` 死键修复**：`main.lua` 读该键但 `window.lua` 写死 2MiB 字面量，配置改了无效；现从 cfg 取值（下限 64KiB）。
- **P0：DLL 陈旧**——`runtime/xcom_core.dll`(9-14) / `xcom_imgui.dll`(9-14) 仍是 v1.6 二进制，本轮所有需新 DLL 的能力（modem 线路、字体偏好、`[colors]`、一级右键菜单、TX 着色、CJK 显示）在用户机上**完全未生效**。新增 `tools/check_dll_exports.sh`（objdump 读 PE 导出表 vs Lua cdef 声明）把它变成**可机检**的失败：当前实测 `xcom_imgui` 缺 `set/get_font_prefs` 两个导出，`xcom_core` 齐备。已接入 CI cpp-syntax job → **重编前 CI 会红**（这正是目的）。
- **纠错：“Linux 无法构建 Windows DLL”不成立**：mingw-w64 交叉编译两枚 DLL 均成功（10/10 TU + 链接），导出符号集与签入件**完全一致**。修了两处真实构建缺陷：`CMakeLists.txt` 缺 `dwmapi`（`imgui_impl_win32.cpp` 只靠 MSVC 的 `#pragma comment(lib)`，任何 GCC/Clang 工具链都会 4 个 undefined），以及 `_WIN32_WINNT` 未固定（mingw 默认低于 0x0600 ⇒ `CancelIoEx`/`CancelSynchronousIo` 不可见）。**但交叉件不用于发布**：尺寸大一个数量级（10.8MB vs 883KB；`-static` + 无 LTCG），且无 Windows 无法验证渲染，故仅作编译/链接/符号级验证。
- **回归**：25 个 portable Lua 套件全绿（multi_send 158→166、port_enum 63→68、log_save_report 39→42）；宿主 C++ 10/10；语法门禁（含 bridge mingw 交叉检查）全 OK；`git diff --check` 干净。

### 本轮（第 9 轮：第二轮横向取证 × 配置落盘原子化，2026-10-04）
> 用户问「是否参考了其他串口工具」。如实回答：我执行的几轮**没有**读别人源码；仓库里有一份 09-13 的源码级对照集（PuTTY/Tera Term/COMTool/LLCOM/Serial Studio 等，带 commit 与 `[S]/[D]/[I]` 分级）。本轮补做第二轮取证并据此落地两处修改，全部写入 `docs/design-serial-tool-comparison.md` §十（含取证表与建议）。
- **取证方式**：浅克隆 COMTool `4b1e39e`（与第一轮**同 commit**，故第一轮行号引用可直接复核）、LLCOM `734d716`、Serial Studio `70aeb50`，另取 pyserial `serialwin32.py` 作**能力基线**；逐条给文件:行号。
- **「无先例」升级**：pyserial `serialwin32.py:389-414` 的 `cts/dsr/ri/cd` 就是 `GetCommModemStatus` + `MS_*_ON`（与我们 v1.7 **同一 API 同一组位**），而 COMTool/LLCOM/Serial Studio 全仓对新号 grep **0 命中**——「没有工具做 MCU 掉电线路电平观测」从「没找到」升级为「集合内 4 个有源码的工具能力一行可得、无人使用」。
- **领先项（源码级）**：① 占用归因与标记（COMTool 只弹 `str(e)`，`conn_serial.py:331-340`）；② 枚举节流（COMTool 断线期间 **10 ms 一次全量枚举**，`conn_serial.py:429-431`；我们 500 ms 去抖 + 1 s 兜底）；③ 歧义不猜（Serial Studio 五字段打分取最高分即打开，`SerialPortIdentity.cpp:190`，两台同型号在场时可能选错板子）；④ 字号可配 + 对比度过 WCAG AA（LLCOM 固定 Consolas 10pt）。
- **与 Serial Studio 独立同构**：自动重连只在「设备消失 + 用户显式开启」时静默恢复，其余情形必须报给用户（`UartPolicy.h:shouldAutoReconnect` 注释「drop 不报给用户的唯一情形」）——与我们的 FAULT→宽限窗模型一致，且我们的歧义规则更严。
- **落盘持久化（本轮修改）**：三种极端对照——COMTool `config.json` **版本不匹配即整份丢弃**（`parameters.py:88-101`）、LLCOM **每个属性 setter 整份重写**（含窗口几何，`Settings.cs:60-63`）、我们原先**仅退出时写**（进程被杀即丢）。取中间：`core/config.lua` 的 `M.save` 改**临时文件 + 改名**（原 `io.open(path,"wb")` 先截断，半途崩会毁配置），`window.lua` 新增 `_mark_config_dirty`/`_flush_config_save`（真实交互标脏 + **5 s 去抖**，随消息循环的 uv 定时器，退出前解除）。回归：`test_config` 12)（无 `.tmp` 残留 / 陈旧 `.tmp` 不遮蔽 / 失败不改既有文件）、`test_multi_send` AK1-AK11。
- **对第一轮的核对**：① 加强第 1 条；② **更正半句**——COMTool「定时发送掉线后状态栏刷屏」不成立（`dbg.py:651-656` 在未连接时整段跳过且无 else，是**静默**空转，空转本身成立）；③ 确认「发文件失败不恢复按钮」（`dbg.py:466-477`）与 LLCOM「接收显示无界」（其 `maxLength` 仅 10240 B/包的**收包**上限，`Uart.cs:268`，显示端 `AppendText` 无裁剪）。
- **待决策建议（§十.6）**：断帧加「自动」档 = `2×(bytesize+2+stopbits)/baud`（COMTool `conn_serial.py:272`，成本低）；字号放开为自由值；**身份改用设备实例 ID**（含 USB 序列号，Windows 末段即序列号；Serial Studio 给 serial 单独权重 50）——但 `XcomPortInfo` **无 struct_size**，加字段是断点，需实机；RX 读 tick 50 ms → 5 ms 换低延迟（Serial Studio 走 `MAXDWORD/0/0` + `SetupComm(baud*0.02)`，`UART.cpp:60-79`）。

### 本轮（第 10 轮：接收区选择手势补全 × 自动清空不再吃拖拽，2026-10-04）
> 用户反馈「选中复制有局限：只能选中一行，不能从光标位置往后选」。逐行读代码后确认：**多行拖拽的状态机本身是对的**（往返 min/max、逐行命中、绝对坐标都在），真缺陷是**手势缺失**与**自动清空打断**。
- **旧实现的三个洞**：① 每次按下都当拖拽开始 → **双击先把选区清零再从第二下起一个零长度拖拽**，即双击/三击这两种"文本控件标配手势"等于没有；② 视图外的行没被 clipper 提交、没有矩形可命中 → **一次拖拽永远选不到屏幕之外**（无边缘自动滚动）；③ `自动清空` 阈值触发时 Lua 推空串清视图，而空推**按设计**清掉原生选区 → 捏着鼠标时选区被抹掉（bridge 自己的尾部裁剪早就为同一个条件让路，清空路径漏了）。
- **本轮修改**：`GetMouseClickedCount` 分流手势 —— 双击选词（ASCII 词字符 `A-Za-z0-9_` 连段整体选中；**非 ASCII 整段 UTF-8 序列**，CJK 一字 3 字节不可拆；尾行截断按 1 字节）、三击选行、**Shift+单击从现有选区尾端延伸**（无光标模型下用选区尾当锚，前/后都能选；无选区则退化为普通拖拽）；拖到上/下边缘**每帧滚一行**并继续延伸（`rows_first_top/rows_last_bottom` = 本帧实际提交的行范围）；新增导出 `xcom_imgui_selection_dragging()`，Lua 清空锚点先问它，**拖拽中只推迟不清**（累计字节继续增长，松手后下次 append 照常清）。
- **可测性**：词边界抽成纯头 `xcom_lua/native/xcom_imgui/receive_selection.hpp`（无 ImGui/Win32 依赖），新增主机套件 `xcom_core/tests/receive_selection_test.cpp`（25 项断言：CJK 逐字节探测同一 range、2 字节序列、词/分隔符/下划线、`offset==length` 与越界钳位、空行/空指针、尾截断）→ 已接入 `tools/run_host_cpp_tests.sh`（**11/11 PASS**）。手势本身仍无法无头驱动，需 Windows 实机确认。
- **顺带的性能修正**：`imgui_bridge.lua:set_receive_text` 每帧 `optional_export("xcom_imgui_set_receive_base")`（一次 pcall）→ 改为模块加载期探测一次（该文件自己的规则，其他 copy/append 导出都这么写）。
- **测试**：`test_rx_display_caps` 43（+H1-H9：拖拽中不清、松手后清、旧 DLL 无守卫仍清）；`test_multi_send` 179（+AL1-AL2 退化契约）；25 套件全绿；语法门禁含 bridge 交叉检查全过；`check_dll_exports.sh` 现在会列出 3 个缺失导出（font_prefs ×2 + selection_dragging），**DLL 未重编前 CI 保持红**。

### 本轮（第 11 轮：翻页持久化复核 × 历史命令 × INI 转义，2026-10-04）
> 用户要求「历史命令要能记住」「翻页时之前页面的命令能切回找到」。
- **翻页：复核后确认本来就是对的，并把契约钉死**。`change_page`/`add_page`/`remove_page`/`_save_config` 都先 `_store_page()`（读 DLL 缓冲回 `pages`）再 `_load_page()`；main.lua 的回填是「全部页 × 全部 8 槽」。新增 `test_multi_send` AM1-AM21：会话内前进/后退/边界钳位各页内容与勾选互不污染，**重启**（真 `_save_config` → 真 INI → 按 main.lua 逻辑重建 → `set_pages`）后每页文字与勾选原样回来。**结论：翻页丢命令的旧现象无法在代码中找到成因；若实机仍在丢，先怀疑 DLL 陈旧**（现在缺 4 个导出）。
- **历史命令：从无到有**。COMTool 同 commit 的做法是**可见 ComboBox + 持久化 + move-to-front 去重**（`plugins/dbg.py:101,123,136,370-372,451,685-693`），与本设计一致；差异是它的历史随 `config.json` **版本不匹配整份丢弃**，我们的 `history.N` 是普通 INI 键，升级不丢。**Up/Down 没做**：ImGui 明确断言 `CallbackHistory` 与 `Multiline` 互斥（`imgui_widgets.cpp:4739`，注释「它们都用上/下键」），而发送框是多行编辑器；改为工具栏上的历史下拉（`Lang::history`），选中即写回 `send_text`（打开下拉会失焦，下一帧编辑器自读新缓冲）。
  - 纯策略独立成 `core/send_history.lua`（move-to-front 去重、空/纯空白拒绝、上限 64、`sanitize` 对人工编辑文件的容错）+ `tests/test_send_history.lua` **40 项**（含多行命令、上限丢弃最旧、stale 键不复活、写/读键名漂移守卫 G9/G10）。
  - 接线：`_imgui_send_single` 只在 `core_send` **成功**后 `_remember_send_command`（被拒的发送不进历史；重复不重推、不标脏）；`_init_imgui` 播种；`_save_config` 写 `[send] history_count` + `history.N`；main.lua 读回（count 为上界，防旧键复活）。DLL 侧新增 `xcom_imgui_set_send_history(packed, count)`（NUL 分隔，同 highlight rules 的编组方式）。
- **顺带修掉一类真 bug（INI 不转义）**：`core/config.lua` 过去把字符串**裸写**，而 `parse_value` 会 trim 首尾空白、把 `1234`/`true` 读回成数字/布尔；**含换行的值会把后面几行变成新键，直接损坏配置文件**。现改为「需要时才加引号 + 转义」（`\n \r \t \\ \"`），裸格式保持默认以保证旧文件与 diff 不变；读取侧对引号值原样取用、对裸值沿用历史语义（**向后兼容**）。新增 `test_config` 12)/13)/14)：原子写、带换行/首尾空格/引号/反斜杠/CJK/空串往返、旧的裸格式仍按原义解析、未闭合引号不吞值。**写这套测试时抓到我自己第一版的 bug**：闭合引号扫描没跳过 `\"`，`say "hi"` 被截成 `say \` —— 已改为逐字符跳过转义。
- **测试基线**：Lua **26 套件全绿**（新增 test_send_history 40；config 41→60；multi_send 179→200；tx_echo 23→33；rx_display_caps 43）；宿主 C++ **11/11**；语法门禁 32 OK / 0 FAIL（含 bridge 交叉检查）；`git diff --check` 干净；`check_dll_exports.sh` 预期列出 **4 个缺失导出**（font_prefs ×2、selection_dragging、set_send_history）。

### 本轮（第 12 轮）：拖选冻结给出进程内证明，2026-10-04
> 用户要求：用 `xcom_imgui_selection_dragging` 做"贴底拖选冻结"的断言，不要再靠截图猜。
- **结论：冻结行为成立，且这套断言真的有鉴别力。** `tests/e2e_drag_freeze.lua` 打开真实窗口 + VIRTUAL 模拟器
  （`sim:set_rate(8192)`），注入 `SetCursorPos` + `mouse_event` 真 OS 消息走完手势，再从渲染帧内部读数：
  按住 55 个采样 **chased +0px**，同期 scroll_max 长了 2730~4605px（约 150~250 行到）；松手后 moved 0px（尾部已在
  4.3k px 之外）；滚轮回底后跟随恢复（跟了 1215~1230px，24/24 采样都在尾部）；选区 504~505 B。3/3 轮 PASS。
- **反证（关键，否则 PASS 无意义）**：删掉 `if (receive_follow_tail_ && !ImGui::IsMouseDown(Left))` 的门控重编，
  同一条检查立刻 chased **+2700px**（恰等于尾部增长量）、松手后仍被拖走 780px、选区涨到 11844 B，两条断言同时红。
- **新增 3 个只读导出**（bridge `xcom_imgui_get_receive_rect/_scroll/_selection`，Lua `imgui_bridge.lua:receive_rect/receive_scroll/receive_selection`，
  全部 `optional_export` 探测，旧 DLL 返回 nil 时驱动直接报"rebuild xcom_imgui.dll"而不是拿陈旧值凑 PASS）：
  像素截图无法区分"点击没落进接收区"和"拖拽正常"（两者画面都不动、都还没高亮）——上一轮像素探针的
  `interaction=False` 就是坐标没命中的假阴性。判据必须来自帧内状态。
- **两个坑（实测踩过，写进文档）**：
  1. 导出的矩形在 ImGui 空间 = **客户区**坐标，`SetCursorPos`/屏幕像素要 `ClientToScreen`；漏了就点在窗口外。
  2. `WindowFromPoint` 的 POINT 是**按值**形参，LuaJIT FFI 无法表达（`'struct' cannot be indexed with 'number'`），
     所以"点是否属于本窗口"改由"是否进入拖拽态"证明（4 个候选点扫，未进入就换点），顺带筛掉落在窗口上却被别的控件吃掉的情况；
     按下前还要重新置顶一次——注入的点击跟随命中测试，不跟随我们的意图。
- **按下后 0~1 个采样（0~135px）的追视是消息排队延迟**：那一刻 DLL 还不知道键已下，门控无从生效。驱动把它单列成
  "engage 前的合法位移"（`ENGAGE_TIMEOUT=20`），不计失败也不静默吞掉——早期版本把它算进断言，结果同一条检查一绿一红。
- **纠正历史错误断言**：`ui/window.lua` 的 `_smoke_env_hooks` 头注释与 `scripts/smoke_ui.lua` 都写着"合成鼠标到不了 ImGui 后端"，
  实为错误（后端吃 `WM_MOUSEMOVE`/`WM_LBUTTONDOWN`，`Window:dispatch()` 每条消息先转 `imgui:on_wndproc`）。
  两处改为"用 env 而非点击是为了不依赖窗口位置/DPI/桌面状态"，并指向新的 E2E。`docs/receive-selection.md` 同步作废旧条并补上"拖选冻结的进程内验证"一节。
- **门禁**：MSVC 重编 `xcom_imgui.dll`（894976 B）已入库，`dumpbin` 核对新导出全部存在；Lua 26 套件 **23 OK**（失败的 3 项 = 本机环境项：
  `test_shipped_scripts` 类 Unix 目录列举、`test_rx_charset_batch` 本机有真 DLL、`test_wave_ring` `os.clock` 粒度，与本轮无关）；
  宿主 C++ ctest **11/11**；`lint_fields` clean（18 files）；ABI layout pins OK。
