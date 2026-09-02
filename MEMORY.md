# C++17 现代特性与设计模式

本文记录 `SSCOM_lua` 工程中可复用的 C++17 约束、性能原则和设计模式。内容分为两部分：

1. `xcom_core/framework/coact` 的实时核心基线。
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
| **WARP + 单缓冲后全栈稳定值** | **~23 MB private / ~43 MB WS** | `c90cc28` 之后 |

### 已验证的削减手段（按性价比排序）

1. **DX11 HARDWARE → WARP**（`D3D_DRIVER_TYPE_WARP` + `D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS`）：一个改动省 ~65 MB，代价是每帧 45-60 ms CPU。串口控制台的 UI 复杂度完全够用。
2. **交换链 2 缓冲 FLIP_DISCARD → 1 缓冲 DISCARD**：flip 模型强制一个全尺寸 staging buffer，本 UI 不需要。
3. **帧率按因分级**（`window.lua`）：WARP 帧是纯 CPU 开销。交互 16 ms / 数据到达 100 ms / 空闲心跳 500 ms / 最小化跳帧；空闲 CPU 73% → 10%。`request_frame(interval)` 由"改了屏幕内容的代码"调用拉早下一帧，高频系统消息（NCHITTEST/PAINT/TIMER）不得触发，否则节流失效。
4. **核心固定池按波特率定容**（`xcom_config.hpp`）：`kRxBlockCount=128`（512 KiB）、`kDisplayBatchCount=32`（512 KiB）。921600 波特 ≈ 90 KiB/s，10 ms drain 节奏下余量为秒级。容量必须是 2 的幂（SpscRing 掩码）。
5. **无效手段（已实测否决）**：字体 atlas 裁剪（OversampleH=1 + Latin/ASCII 字符集 + 缩字号）只省 <1 MB，视觉损失明显，已回退；去 luv 省约 1 MB，不值得架构回归。

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

- `xcom_core/framework/coact/include/coact/pool.hpp`
- `xcom_core/framework/coact/include/coact/expected.hpp`
- `xcom_core/framework/coact/include/coact/hsm.hpp`
- `xcom_core/framework/coact/include/coact/ao.hpp`
- `xcom_core/framework/coact/include/coact/policy.hpp`
- `xcom_lua/native/xcom_imgui/xcom_imgui_bridge.cpp`
- `xcom_lua/native/xcom_imgui/layout.toml`
