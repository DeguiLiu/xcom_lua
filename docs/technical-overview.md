# XCOM 技术白皮书

> 面向评估与二次开发的读者。本文说明 XCOM 为什么把 UI 与业务逻辑放在
> LuaJIT，把串口与时序放在 C++17，以及这个分工带来了什么。
>
> 配套阅读：`docs/architecture.md`（架构）、`docs/design-summary.md`（概要设计）、
> `docs/performance.md`（性能与可靠性）、`xcom_lua/docs/lua-libs-value-and-recommendations.md`（依赖取舍）。

## 1. 一句话

XCOM 是一个 Windows 串口调试工具，由 **LuaJIT 前端 + C++17 核心**两个进程内
DLL 组成：全部 UI 与业务逻辑是 Lua，串口 I/O 与事件运行时是 C++，两者通过
**版本化 C ABI** 与 **固定签名导出** 通信。

## 2. 为什么是 LuaJIT + C++，而不是纯 C++ 或 Electron

串口工具的痛点不在"能不能收发"，而在**改动成本**：换一种时间戳格式、加一个
自定义协议解析、给某一类报文上色，这类需求在纯 C++ 工具里意味着改代码、
重新编译、重新分发。XCOM 把这条路径压到"改一个 `.lua` 文件"。

| 关注点 | 放在哪 | 理由 |
| --- | --- | --- |
| 串口 I/O、超时、重连时序 | C++（`xcom_core.dll`） | 需要 OVERLAPPED、固定内存池、确定性时序，且必须不被 GC 打断 |
| UI 布局、状态机、配置、脚本引擎 | LuaJIT（`xcom_lua/`） | 改动频繁、迭代快，且 LuaJIT 的速度足以胜任 |
| ImGui 绘制、D3D11 交换链 | C++（`xcom_imgui.dll`） | 每帧调用，且要直接管 GPU 资源 |

三层的关键约束是**没有一层做两件事**：Lua 不直接碰 Win32 串口 API，也不持有
任何 ImGui 对象；DLL 不做业务决策。这让每层都能单独测试和替换。

**LuaJIT 的关键作用**不只是"用脚本写"，而是它让这套分层**不付出性能代价**：

- **FFI 直调**。Lua 通过 LuaJIT FFI 直接调用 C ABI，不经过绑定层、不做参数
  封送，等价于 C 调用。结构体布局由 `ffi.sizeof` 在加载时钉扎校验，两侧
  对不齐会**当场报错**而不是静默读错内存。
- **JIT + 零重建接收路径**。接收批次由 Lua 整批交给 DLL 追加进 ImGui 缓冲，
  不在 Lua 里逐字节拼字符串、不重建显示文本。这是持续高速接收不掉帧的前提。
- **单线程 UI 模型成立**。主线程是 Win32 消息循环 + libuv，所有状态都是纯
  Lua 表，天然串行、不需要锁。锁的开销被整体消除，而不是被优化。

代价是明确的：**Lua 侧的慢代码会直接表现为 UI 卡顿**（它和消息循环同线程）。
XCOM 因此把重活都推给了 C++——接收不逐字节进 Lua，绘制不经过 Lua。

## 3. 分层与职责边界

```
xcom.exe ──spawn(隐藏控制台)──▶ luvjit.exe ──FFI(版本化 C ABI)──▶ xcom_core.dll
   Win32 启动器                    LuaJIT 主线程                     C++17 + coact
                                   │                                 └─ Win32 OVERLAPPED 串口
                                   └──FFI(固定签名, int 缓冲)──▶ xcom_imgui.dll
                                                                   ImGui + ImPlot + D3D11
```

| 层 | 位置 | 明确不做 |
| --- | --- | --- |
| 启动器 | `native/launcher/` | 不含任何业务逻辑 |
| Lua 应用 | `main.lua`、`ui/`、`core/` | 不直接做阻塞串口 I/O、不直接调 ImGui API |
| 渲染桥 | `native/xcom_imgui/` | 不做串口业务、不持有权威应用状态 |
| 核心 | `xcom_core/` | 不做 UI、不做策略决策 |

`core/` 下是可以脱离 Windows 单测的纯逻辑（`view_model`、`charset`、`config`、
`waveform`、`ansi`），这也是分层带来的直接好处：状态机与编码转换能在 Linux
上跑测试。

## 4. 两个 DLL 的契约差异

| | `xcom_core.dll` | `xcom_imgui.dll` |
| --- | --- | --- |
| 契约 | **版本化 C ABI**（`xcom.h` v1.5） | **固定签名 + 符号探测** |
| 结构 | 显式 `_pad` 固定布局 | 控件缓冲以 `int*` 就地读写 |
| 演进 | 主版本变更、结构尺寸钉扎 | 新增导出即可，缺失符号降级 |

核心必须版本化，因为它是数据正确性的权威：结构体字段错位会导致静默错误，
所以 `xcom_ffi.lua` 在模块加载时用 `ffi.sizeof` 逐个校验，不匹配就拒绝启动。

渲染桥则相反——它是"扩展式"的：新增一个面板只需加一个导出，老版本 Lua
遇到不认识的符号会优雅降级而不是崩溃。这让前端和渲染 DLL 可以错版本运行。

## 5. 并发模型：无锁热数据面

设计上区分**无锁热数据面**与**可休眠控制面**：

- 热面（接收、显示）不取 mutex、不等条件变量、不做文件 I/O。coact 的固定
  块池与引用计数保证了 1 Mbps 连续接收不产生事件池分配、不做引用计数修改。
- 控制面（打开/关闭、手动发送、保存）才允许使用 OS 等待原语。

`SerialAo` 是 COM 生命周期与配置的唯一 owner；`SessionWriter` 是唯一可能
阻塞写串口的线程。UI 线程不调用 HANDLE 等待原语，因此不会被串口阻塞。

接收路径上，数据保持**原始字节**逐级传递，时间戳在合并行时插入，避免在行
中途注入——这是"显示与保存必须一致"这条要求的实现方式。

## 6. Lua 插件：工具能力的延长线

XCOM 的脚本系统不是"宏"，而是产品的**主要扩展面**。`scripts/` 下每个 `.lua`
在独立环境（`setfenv`）中加载，注入一组命名空间：

| 命名空间 | 能力 |
| --- | --- |
| `uart` | `send` / `send_hex` / `is_open` —— 收发串口 |
| `on` | `receive` / `send` / `md` —— 注册钩子 |
| `filter` | `keep` / `drop` / `clear` —— 决定哪些数据进显示 |
| `log` | `info` / `warn` / `trace` —— 写入脚本日志面板 |
| `wave` | `push` —— 推数据到示波器 |
| `sys` | `timer_start` / `timer_loop_start` / `now` / `file_*` / `sim` —— 定时器与文件 |

一个能用的插件就是几行：

```lua
on.receive(function(text)
    if text:match("^AT\r?\n?$") then
        sys.timer_start(10, function() uart.send("OK\r\n") end)
    end
    return text
end)
```

**插件优先的设计选择**体现在几处：

- **热重载**。`fs_event` 200ms 去抖 + mtime 轮询兜底；改脚本无需重启，
  重载失败保留旧状态。
- **故障隔离**。每次钩子调用走 `pcall` 并带指令预算；单脚本连续失败 3 次
  自动禁用，不拖垮宿主。启用状态在 DLL 侧渲染，事件回传 Lua。
- **API 面向串口而非面向 UI**。插件拿到的是 `uart`/`on`/`filter`，不需要知道
  ImGui 或窗口的存在。同一份插件在打包版与源码版行为一致。

需要说明的是：脚本**不是安全沙箱**，是**故障隔离**。同进程信任模型下，它
保证的是"写错脚本不会让工具崩"，而不是"恶意脚本无法作恶"。

## 7. 工程化约束

- **打包一致性**。`build_release.ps1` 内置门禁：`xcom.exe` 版本号必须等于
  包名、DLL 新鲜度、CRT 闭包（`dumpbin` 验证所有 vcruntime/msvcp 导入都被
  收录）。这些门禁来自真实事故——版本号曾在二进制与包名之间漂移过。
- **字节码分发**。发布包只含 `.ljbc`（不含 `.lua`），`require` 优先字节码。
  但源码树里**不提交**字节码：它会在 `package.path` 中遮蔽当前源码。
- **两种分发形态**。绿色版 zip（解压即用）与 MSI 安装包（Program Files +
  快捷方式），两者内容一致，由同一份 staged 目录产出。

## 8. 适用边界

XCOM 适合：协议调试、报文分析、需要现场改脚本而不想重编译的场景。

不适合：需要多实例高并发串口的服务端场景（UI 是单线程模型）；需要脚本
安全隔离的多租户场景（同进程信任模型）。
