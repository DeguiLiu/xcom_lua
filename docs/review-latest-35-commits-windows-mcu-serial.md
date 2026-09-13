# xcom_lua 最近 35 次修改技术评审

> 评审对象：Windows PC 通过 USB-UART/COM 口连接 MCU 的串口工具。  
> 评审基线：`git log -35`、逐提交 `git show --stat`/diff、当前工作树源码。  
> 评审时间：2026-09-13。  
> 只读评审：未修改产品代码。

## 结论先行

当前主线已经从“能收发”提升到“异步、可观测、有界、可重连”的工程形态；最值得保留的是 `SessionWriter`、引用计数 RX 双通道、5 态端口 HSM、DCB 回读校验和显式发送拒绝语义。

但当前最新源码仍不能宣称“异常下不丢数据、不静默失败”：

1. **P0：`RxKickGate` 在 coact 拒绝 `RxKick` 后永久置位，接收显示/后续处理会形成数据黑洞。**
2. **P0：coact Windows PAL 启动握手超时后脱离 Dispatcher 线程，XCOM 随即销毁 `CoreState`，存在 UAF。**
3. **P1：工作树已修复 HEAD 中“读完成与 stop 同时到达丢尾数据”的路径，但修复尚未提交；短写续传仍未实现。**
4. **P1：打开阶段 DTR/RTS 的 `EscapeCommFunction` 失败仍被显式忽略，MCU 复位/BOOT 线可能与 UI 认知不一致。**
5. **P1：关闭预算只约束 ABI 轮询，不约束 Dispatcher 内 `SessionWriter`/日志收尾的最长阻塞，关闭期间仍可能长期保持 `CLOSING`。**

本评审区分两种状态：

- `HEAD` 是 `b0994c2`；它代表最近一次已提交修改。
- 当前工作树有 63 个已修改路径，包含若干未提交修复。未提交修复不能视为已交付能力；本报告会明确标注“工作树已修、HEAD 未修”。

## 范围与证据

仓库根及父目录未发现额外 `AGENTS.md`。已执行：

- `git log -35 --format='%H %s'`
- 每个提交的 `git show --stat`，并对串口核心、Lua 状态机、UI/FFI、coact 集成做完整 diff/上下文核对。
- `XCOM_COACT_ROOT=/home/dgliu/workspace/coact tools/check_cpp_syntax.sh`：23 个 C++ TU 通过；这是 g++ + Win32 stub 语法门，不是 MSVC/真实 Win32 验证。
- coact `ctest --test-dir /home/dgliu/workspace/coact/build --output-on-failure`：**54 项中 43 项 Not Run、1 项 Failed**，原因是 CTest 清单仍指向 `/home/dgliu/coact/build/...`，不能据此宣称 coact 测试通过。

未验证范围：真实 Windows MSVC 链接与运行、真实 USB-UART 驱动的 DTR/RTS 脉冲、设备拔插/断电、CTS/RTS 电气行为、真实 COM10+ 设备、真实慢磁盘和真实高负载下的 PAL 启动时序。

## 最近 35 次提交逐项评价

以下“实际效果”以提交 diff 和当前代码交叉核对；文档提交只评价维护影响，不把文档变化误报为运行时修复。

| 提交 | 目的与实际效果 | 评价 |
| --- | --- | --- |
| `b0994c2` | UI 关闭等待从 2 s 降到 200 ms；新增异步 shell 路径。 | 方向正确，降低点击关闭卡顿；但关闭返回值和后端长收尾仍需统一语义。 |
| `16a92ab` | 删除设计文档状态行和历史记录。 | 可读性提升；删除历史上下文后，审计文档必须保留当前未验证边界。 |
| `9b8bc89` | 重建架构、性能、编码规约等文档，删除旧资料。 | 当前架构更清晰；删除 `STATUS`/旧边界审计降低了回归追踪能力，需保留一份持续更新的风险台账。 |
| `30ba294` | `ShellExecuteW` 打开目录；复用 Lua snapshot scratch。 | UI 非阻塞和降低 GC 正确；`ShellExecuteW` 仍可能受 DDE/网络路径影响，当前只应接受目录场景。 |
| `487ad06` | 修复 VIRTUAL 端口共享 setup 路径，确保 writer/callback 正常启动。 | 修复了测试端口“看似 OPEN、实际不能发”的契约问题。 |
| `89da3b7` | 允许 `FAULT -> OPEN`，规范 `OPEN -> OPEN`。 | 关键状态机修复，避免用户点 Open 无动作。 |
| `a50045a` | 补齐端口 HSM、意图拒绝与回滚。 | 认可；将“意图未落地”变成可见拒绝，降低 UI 假状态。 |
| `24adc37` | 增加可选端口占用探测。 | 默认关闭避免枚举触发 DTR/复位，取舍正确；开启后仍需实机验证驱动行为。 |
| `257ff96` | 重连宽限从 3 s 调到 8 s，覆盖 ROM 重枚举。 | 贴合 MCU 现实；不能解决同描述多设备身份歧义。当前工作树已增加故障前端口集合过滤。 |
| `866f919` | 增加 `CLOSING` 看门狗。 | 认可；当前代码避免在核心仍 `CLOSING` 时错误强制 `FAULT`。 |
| `21a8d85` | 让状态常量和重连路径可达。 | 解决 Lua 镜像中“比较恒为 false”的静默失败。 |
| `e166a8a` | vendor ImPlot，前端可从新 clone 构建。 | 依赖闭合正确；CI 由报告缺口变成实际构建门。 |
| `7322a40` | 为脚本 hook 增加指令预算。 | 直接保护 UI 心跳和串口排空；预算超限必须继续保留错误可见性。 |
| `99f2264` | CI 让 CMake 选择 runner 的 MSVC toolset。 | 降低 runner 版本耦合；仍不替代真实硬件测试。 |
| `037d9c2` | 取消读时等待最多 1.5 s，避免 wedged driver 使 close 永挂。 | 根因修复比 close 外层探针有效；但 HEAD 仍有同时置位丢尾数据缺陷，见 P1。 |
| `8867991` | 打包窗口图标。 | 与串口可靠性无关，功能性完成。 |
| `03a6a90` | 删除无法改变结果的 close 探针，承认真实限制。 | 设计诚实；历史上曾保留无界 join，后续 `037d9c2` 才收口。 |
| `b8675d0` | GitHub Actions、C++ stub 语法门和测试。 | 认可；但 stub 只能抓编译错误，不能证明 Win32 生命周期。 |
| `ff7dffa` | 发布发送/接收转换脚本库。 | 扩展性好；脚本必须受发送互斥和预算约束。 |
| `3179795` | 脚本描述、热加载、插件页和状态 footer。 | 可用性提升；热加载失败、文件句柄、插件回调仍应纳入故障注入。 |
| `764d1bb` | Scope 从 header chip 改为脚本拥有。 | 所有权更单一；换页/关闭期间的波形资源生命周期仍需实机回归。 |
| `0e988d7` | 重连宽限窗口和缺失 HSM 迁移。 | 关键可靠性主线；重连身份不能只依赖 description。 |
| `3a5a89a` | 修接收乱码、多行发送静默、陈旧状态。 | 业务反馈闭环较好；仍有跨块 CRLF 状态缺口。 |
| `9f8bf3a` | `ClearCommError` 四类线错误计数。 | 明显优于 PuTTY/Tera Term 的可观测性；需确保 UI 文案区分“驱动丢失”和“显示积压”。 |
| `db85f87` | DTR/RTS 三态、实时线控、DCB/ABI 扩展。 | 设计方向正确；打开阶段冗余 pin 写失败仍被忽略。 |
| `9c5cfb3` | fault 释放串口句柄，写失败升级故障。 | 解决拔线后句柄占用和 OPEN 假象；故障信号本身仍依赖 coact 接纳。 |
| `36ec30f` | Scope `apiAddPoint` 与面板修复。 | 非串口核心；需防止脚本绘图占用 UI 预算。 |
| `a26d3d1` | ImGui 增量接收窗口，Lua 不再重建全尾窗。 | 性能收益明确；不能把显示优化误当成采集保真，HEX 才是字节保真路径。 |
| `e769372` | 关闭 WndProc 可达回调 JIT，修 bad callback 崩溃。 | 重要稳定性修复；应继续保留点击/模态压力测试。 |
| `6a1912e` | LuaJIT + ImGui 首版、固定池和内存/性能基础。 | 建立当前产品骨架；后续改动较多，需避免二次所有权。 |
| `896bca2` | 修接收截断和块边界时间戳。 | 修复真实显示错误；当前 C++ CRLF 仍只在同块内合并。 |
| `7b94268` | 记录绘图效率审计。 | 过程记录，不改变运行时。 |
| `c976cc4` | 缓存固定文本测量。 | 降低 ImGui 常量测量开销；不应套用到中文/变宽字体命中测试。 |
| `9661413` | 记录接收热路径优化轮次。 | 过程记录；价值在于保留性能基线。 |
| `9386af8` | 接收热路径 C++17/memchr 优化。 | 吞吐收益明确；固定 glyph 宽度会使中文/混排选择命中偏移，属 P2 退化。 |

## 认可的设计与修复

### 1. Windows 串口配置与 COM10+

- `serial_backend_win.cpp:159-169` 对端口名统一补 `\\.\`，`COM10+` 路径不会被 Win32 短名规则截断。
- `serial_backend_win.cpp:67-95` 在 `CreateFileW` 前校验波特率、数据位/停止位组合、校验位、流控和 DTR/RTS 三态；非法配置不会先开句柄、不会先触发复位线。
- `serial_backend_win.cpp:392-463` 在 `SetCommState` 后回读 DCB，能拒绝驱动静默取整的波特率和非法 1.5 stop/8 data 组合。这比“控件值显示成功”更可信。

### 2. 异步 I/O 与发送隔离

- `serial_backend_win.cpp:167-197` 使用 OVERLAPPED 读写和独立事件句柄；`xcom_core.cpp:147-317` 的 `SessionWriter` 将可能阻塞的写从 coact Dispatcher 移出。
- `xcom_abi.cpp:435-493` 采用同步复制、异步写结果；池满返回 `XCOM_ERR_FULL`，Breaker 拒绝返回 `XCOM_ERR_BUSY`，不再把调度器拒绝误报成容量耗尽。
- `xcom_lua/ui/window.lua:2465-2500` 多行发送只有 `core_send` 成功才计数，并显示失败槽位；发送、自动发送、文件发送互斥，避免任务之间互相吞数据。

### 3. 接收保真、背压和诊断

- `xcom_core/src/foundation/rx_block_lane.hpp:9-48` 以引用计数块扇出显示和文件通道，文件通道保留 96 块，显示慢不会夺走文件保留区。
- `xcom_core/src/runtime/xcom_core.cpp:1282-1420` 将文件通道阻塞、显示积压、无 owner 丢失分开计数；不能保存的尾部写入 `save_rejected_bytes`，避免“统计正常但文件缺字节”。
- `serial_backend_win.cpp:644-680` 和 `xcom_core.cpp:1423-1483` 将 frame/parity/overrun/break 分开统计；这在异常定位上明显优于 PuTTY/Tera Term 的默认行为。

### 4. 生命周期和 UI 状态

- `xcom_core/src/ao/xcom_ao.cpp:490-532` 明确 5 态迁移；`FAULT -> OPEN`、`OPENING -> CANCEL -> CLOSING`、`CLOSING -> CLOSED` 均有显式路径。
- `xcom_lua/core/view_model.lua:249-339` 使用 generation 防陈旧状态覆盖；`xcom_lua/ui/window.lua:3375-3412` 对 fault/reconnect 做独立策略，不把 UI 的 `RECONNECTING` 冒充核心物理状态。
- `xcom_lua/ui/window.lua:1533-1588` 走 `open_async`，键盘路径也检查端口存在性，不会因刷新列表把打开目标静默改成索引 0。

## 不足与风险（按优先级）

### P0-1：`RxKickGate` 被拒后永久置位，当前工作树仍未修

证据：

- `xcom_core/src/runtime/xcom_core.hpp:751-755` 的 `submit_rx_kick()` 返回 `void`，调用者拿不到 coact 结果。
- `xcom_core/src/runtime/xcom_core.cpp:620-633` 提交 `EventQos{critical=true}` 后完全丢弃 `SubmitResult`。
- `xcom_core/src/runtime/xcom_core.cpp:1411-1413` 先 `try_arm()` 置闩，再提交 `RxKick`。
- `xcom_core/src/ao/xcom_ao.cpp:301-305` 只有真正执行 `rx_kick_action` 后才 `disarm()`。
- 同一问题还存在于 `xcom_core/src/abi/xcom_abi.cpp:522-523`（恢复显示）和 `:718-720`（时间戳 drain 完成后重投）。

复现条件：让 coact High 分区/Dispatcher 阻塞导致 `RxKick` 被 `RejectedFull`，然后继续注入或接收数据。`XcomCoactConfig` 的 16 个 critical reserve 只限制 ordinary（`xcom_core/src/runtime/xcom_config.hpp:17-22`）；critical 事件仍可填满 32 槽，coact `coordinator.hpp:230-241` 会返回拒绝而不会自动重试。

后果：`display_ready` 有数据但 Dispatcher 不再被唤醒；显示停滞，池最终耗尽。无日志时后续接收进入 `save_rejected_bytes`，形成真实数据丢失。现有 `xcom_core/tests/smoke_test.cpp` 只覆盖正常重投，没有 staging 满载拒绝回归。

最小改进：让 `submit_rx_kick()` 返回 `bool/SubmitDisposition`；提交失败立即清 gate，并保留一次有界重投或独立 wake。所有三个调用点统一走该封装，再补 High-critical 满载测试。

### P0-2：coact Windows PAL 启动握手超时后 UAF

证据：

- `/home/dgliu/workspace/coact/src/core/pal_windows.cpp:206-237` 等待 `started_event_` 1 s 超时后 `CloseHandle`、清 `thread_valid_`，但注释明确线程仍“left to finish under OS”。
- `/home/dgliu/workspace/coact/include/coact/runtime.hpp:142-155` 把该失败返回给 Runtime，`started_` 保持 false。
- `xcom_core/src/abi/xcom_abi.cpp:168-177` 随后销毁失败 boot 的 handle/CoreState。
- `xcom_core/src/runtime/xcom_core.cpp:553-568` 因 `started == false` 跳过 `runtime.stop()`，无法 join 脱离线程。

复现条件：Windows 调度器/调试器/系统资源压力使 Dispatcher 超过 1 s 才进入入口。未在真实 Windows 重现，但代码所有权链已闭合证明风险。

后果：线程继续访问已销毁 `Windows` PAL、Dispatcher、Runtime 和 CoreState，可能崩溃或写坏固定槽位；这是发布阻断级生命周期缺陷。

最小改进：启动握手超时必须发 stop、继续持有线程句柄并 join；或者在 join 完成前不得销毁 CoreState。禁止把仍运行的 Dispatcher detach 后释放 owner。同时将 `wake_event_` 创建失败纳入 `start_dispatcher` 失败条件；当前 `pal_windows.cpp:164-177` 对空 wake handle 只是返回/忽略。

### P1-1：HEAD 的 stop/read 同时置位路径丢失已完成尾数据

`HEAD` 的 `xcom_core/src/io/serial_backend_win.cpp:579-580` 先判断 `stop_requested_`，只要 stop event 与 read event 同时置位就直接返回，不调用 `GetOverlappedResult`。复现：MCU 最后一批字节完成后用户立即 Close，读完成事件与 stop event 同时可见；已完成的 `received` 从未进入 `on_read_`。

当前工作树在 `:592-632` 已改为先 `GetOverlappedResult`、先交付 partial bytes，再报告 fault；这是正确方向，但仍未提交，不能视为 HEAD 能力。修复必须补“read event + stop event 同时置位”的回归测试。

### P1-2：打开阶段 DTR/RTS 写失败仍静默

当前 `serial_backend_win.cpp:477-487` 明确把 `set_dtr/set_rts` 返回值丢弃。虽然 `SetCommState` 已回读，但冗余 pin IOCTL 失败时：

- MCU 可能没有按 UI 请求解除 NRST/BOOT；
- UI 仍显示打开成功；
- 设备可能处于错误启动模式，用户会把“串口无响应”误判为波特率或固件问题。

这是用户明确要求的“不误导、不静默失败”违例。最小改进是：对非 `LeaveAlone` 的 pin 写失败返回具体 Win32 错误并让 open 进入失败；若产品决定允许“DCB 已成功但 pin replay 失败”继续，也必须把它作为可见 warning 和 snapshot/error ring 事件，而不是忽略。

另一个必须写进用户契约的边界是 `LeaveAlone`：`serial_backend_win.cpp:459-475` 仍以 `*_CONTROL_DISABLE` 写入 DCB；Windows/USB-UART 驱动可能在 `CreateFileW` 或 `SetCommState` 时改变线电平。当前代码注释承认这一点，但 UI 只显示“Leave alone”，没有告诉 MCU 用户“无法保证完全不复位”。这不是可由 Lua 文案掩盖的硬件事实，应在打开前明确警告并列入实机示波器验收。

此外，实时线控从 ABI/UI 线程直接调用 `EscapeCommFunction`（`xcom_core/src/runtime/xcom_core.cpp:1018-1034`），而关闭/故障可在 Dispatcher/读线程并发重置句柄；`is_open()` 与真正 pin 写之间没有 generation/close gate。拔线或点击 Close 与 250 ms 线控轮询交错时，结果可能针对已关闭或已复用的 HANDLE。最小方案是把线控请求串行化到 SerialAo，或加 session generation 门。

### P1-3：短写被当成失败，未续传已写前缀

当前工作树 `serial_backend_win.cpp:264-267`（同步 `WriteFile`）和 `:289-300`（OVERLAPPED 完成）在 `written != size` 时直接返回失败。`SessionWriter` 随后释放整个 TxBlock；如果 Win32/USB 桥已写出前缀但只返回短写，剩余尾部永远不会发送，MCU 收到半帧，UI 只看到异步写失败。

触发短写需要特定驱动/过滤器或异常注入，普通 COM 驱动未在本机复现；但代码路径确定没有续传。最小方案是保存 offset，循环 `WriteFile`/OVERLAPPED 直到完整 payload，只有完整成功才释放；取消时记录“已写 N/总长”而不是笼统 IO failure。

### P1-4：关闭预算没有覆盖 Dispatcher 内的长收尾

`xcom_core/src/abi/xcom_abi.cpp:411-428` 的 `timeout_ms` 只限制调用方轮询；`xcom_core/src/runtime/xcom_core.cpp:890-910` 将单次串口写超时按波特率计算并上限 60 s，`sink_owner_close` 会在 `:935-938` 先 `stop_and_join()` writer，再继续关闭后端。

复现条件：低波特率、CTS/XOFF 持续暂停、写线程或日志 writer 正在重试，用户点击 Close。ABI 可在 200 ms 返回 `TIMEOUT`，但 Dispatcher 仍可能在 CLOSING 内等待更长时间；之后 Open/Close/故障事件只能排队，UI 仍显示过渡态。

最小改进：为 close 设计明确的“用户返回预算”和“核心最终收尾预算”两个状态；超时返回必须包含 `CLOSING`/仍在收尾的明确原因，并禁止在核心仍占句柄时给出“可重新打开”的暗示。不要在 UI 侧用看门狗伪造物理 CLOSED。

### P1-5：关闭顺序仍有尾部接收数据丢失窗口

当前 `xcom_lua/ui/window.lua:1295-1305` 的 `_final_drain()` 先排显示、再关闭日志、最后才 `xcom.close()`。这段窗口内串口仍是 OPEN；新到字节可能进入 raw/display lane，但日志 writer 已先关闭，随后 `xcom_core/src/ao/xcom_ao.cpp:561-567` 的 session reset 会释放未排显示块，而 UI 已停止继续 drain。

复现条件：MCU 持续输出，Alt+F4 进入 final drain/log close 与 `xcom.close` 之间，恰好收到一批字节。结果可能既未显示也未落盘，且关闭路径没有将这批字节计入 loss ledger。最小方案是先关闭接收/提交 Close，再做最终显示与日志 drain；若必须先 drain，则 close 后必须二次 drain 并显式计数。

### P1-6：文本视图跨块 CRLF 仍会生成错误空行

当前 `xcom_core/src/ao/xcom_ao.cpp:144-159` 只在同一格式化块内把 `\r\n` 合并；没有 pending-CR 状态。复现输入分成两次：第一块 `"abc\\r"`，第二块 `"\\nnext"`。结果是第一块输出 LF，第二块再输出 LF，文本出现空行；时间戳/按行脚本也可能被错误触发。

HEX 路径仍是字节保真；该问题只影响文本显示、日志显示和行级脚本语义，但用户会误以为 MCU 发送了空行。最小改进：保存一个跨块 `pending_cr`，下一块首字节为 LF 时吞掉，否则先输出单独 LF；补拆分点测试。

### P1-7：打开失败把正 Win32 错误码冒充 `XcomStatus`

当前工作树 `xcom_core/src/abi/xcom_abi.cpp:78-85` 将 `ERROR_ACCESS_DENIED=5`、`ERROR_FILE_NOT_FOUND=2` 等正数直接转为 `XcomStatus`。但 ABI 枚举约定只有 `0` 或负的 `XCOM_ERR_*`；调用方若按 `rc >= 0` 判成功，会把“端口不存在/被占用”当作成功，且破坏 C ABI 兼容语义。

最小方案：`xcom_open`/`xcom_take_open_result` 始终返回 `XCOM_ERR_IO`、`XCOM_ERR_PARAM` 等负值，原生 Win32 code 只放 `XcomError.code`；Lua 继续从 error ring 翻译用户可行动原因。

### P1-8：无日志时接收池满仍继续读并丢真实字节

`xcom_core/src/runtime/xcom_core.cpp:1340-1346` 在无日志 owner、显示 lane 无空间时把尾部计入 `unowned_drop` 后继续从驱动读取。计数和提示是正确的，但这仍是数据丢失；不能同时宣称“串口数据不丢”。

最小方案二选一：无日志时保留有限 raw lane，或在可见 `DATA LOSS` 后停止继续读、让 RTS/CTS/用户动作恢复；不要把“已计数”当作“未丢失”。

### P1-9：故障信号被 coact 拒绝时只发布 FAULT，不释放句柄

`xcom_core/src/runtime/xcom_core.cpp:780-800` 在 `Signal::Fault` 提交失败时直接 `port_state.store(FAULT)`，但没有调用 `owner_close`。设备拔出后若用户不立即点 Close，旧句柄可能继续独占 COM 口，其他工具无法打开；这是“状态已 fault、资源仍占用”的分裂。

最小方案是保留一个 critical fault pending，或在拒绝分支执行有序、幂等的 `owner_close` fallback，并补“控制池满 + 设备移除”的测试。

同一兜底还有状态分裂风险：`serial_fault_callback`/writer 在 `xcom_core.cpp:796-800`、`:1004-1008` 直接写发布态 `FAULT`，但 Dispatcher-owned `SerialCtx::state` 仍可能是 `OPEN`。随后 `queue_open` 接受 `FAULT`（`xcom_abi.cpp:244-246`），而 `serial_transition(ctx, Open)` 读取本地 `OPEN` 没有对应边，重开意图可能再次被静默丢弃。最小方案是让兜底同时产生可消费的 AO reset/fault 事件，或在 direct-store 后禁止 Open 直到 AO 状态重新同步；不能只修原子发布视图。

### P1-10：日志 `WriteFile` 无法被 close 预算打断

`xcom_core/src/io/log_writer.cpp:414-473`（原始 RX）和 `:501-539`（普通文件写）使用同步 `WriteFile`；`LogWriter::shutdown` 在 `:1108-1129` 进入 stopping 后仍无条件 join。网络重定向路径、坏盘或驱动卡死时，线程可能卡在单次 `WriteFile`，心跳只能报告“线程还活着”，不能打断它；close/destroy 可能无限等待。

该条件未在本机 Windows 实机复现，但代码路径明确违反“关闭有限延迟”的目标。最小方案是使用可取消 OVERLAPPED 文件写，或让 UI/句柄生命周期与日志线程解耦；在此之前至少把“日志 writer 卡在单次 WriteFile”列为未验证发布阻断项。

### P2-1：中文/混排接收选择命中退化

`9386af8` 将 ImGui 选择命中从逐字测量改为固定 `glyph_w`。串口文本经过 charset 转换后可能含中文、全角和 ANSI 清理结果；固定字宽会使鼠标列与字节偏移不一致。性能优化应只用于明确等宽 ASCII/HEX，或保留变宽测量缓存。

### P2-2：版本与依赖验证仍不闭环

- `xcom_core/framework/README.md:3-10` 说明 coact 是外部 checkout；CI pin 是好事，但本地 coact CTest 清单仍引用不存在的 `/home/dgliu/coact/build`。
- 当前已知验证仅有 23 TU stub 语法通过；没有真实 MSVC、DLL 链接、真实 COM 读写证据。
- `9b8bc89`/`16a92ab` 删除旧状态与边界资料后，维护者更难发现“已修/未验证”的区别；建议保留简短风险清单，而不是恢复旧文档堆积。

### P2-3：TX 回显与日志不是同一成功语义

`xcom_lua/ui/window.lua:1705-1739` 的 TX echo 会再次调用 `xcom.log_append`，但忽略返回值。磁盘慢或日志队列满时，界面可能显示 `TX:` 而日志没有对应记录；这不影响串口线上字节，却会误导“导出日志完整”的用户。最小方案是检查返回值、递增独立计数并在状态栏提示，或统一把 TX echo 交给 LogWriter 的有序队列。

### P2-4：可选占用探测漏掉部分 Win32 sharing 错误

`serial_backend_win.cpp:128-133` 只把 `ERROR_ACCESS_DENIED` 判为 busy，没有把 `ERROR_SHARING_VIOLATION (32)` 纳入。某些过滤器/驱动返回 32 时，启用探测的列表仍显示可用，用户点击打开才失败；默认 probe 关闭，因此不影响正常打开路径。

## 与其他 Windows 串口工具对比

证据等级以仓库 `docs/design-serial-tool-comparison.md` 为准：PuTTY/Tera Term 有源码对照；RealTerm/CoolTerm 多为官方文档或行为资料，不能把“未记载”当成“不存在”。

| 能力 | xcom_lua 当前判断 | PuTTY | Tera Term | RealTerm/CoolTerm | 结论 |
| --- | --- | --- | --- | --- | --- |
| COM10+ | `\\.\COM10` 前缀，代码明确处理 | 手输端口 | 支持 | 通常支持 | 本工具不落后 |
| 端口独占/占用可见 | 默认不探测，避免打开触发 DTR；可 opt-in | 打开失败后报错 | 打开失败/状态能力有限 | 依工具而定 | 取舍合理，但应把 opt-in 风险写进 UI |
| 热插拔/重连 | `WM_DEVICECHANGE` + 轮询 + 8 s 宽限；当前工作树按故障前端口集合过滤 | 串口无完整状态机，I/O 错误关闭 | 有设备事件状态机，但 I/O 错误 UI 反馈弱 | CoolTerm 文档有掉线关闭/重连能力 | xcom 设计更完整；真实 Windows 仍未验证 |
| 8N1/波特率/校验/停止位 | DCB 写入后回读，拒绝驱动静默取整 | 常规配置 | 常规配置 | 常规配置 | xcom 在“拒绝假成功”上领先 |
| RTS/CTS、DTR/RTS | 流控时 RTS 归驱动；三态 LeaveAlone；但打开 pin replay 失败仍静默 | 基本线控 | 线控/协议路径较成熟 | RealTerm 对握手按钮有禁用先例 | xcom 语义更细，仍需 P1 收口错误报告 |
| 异步读写/UI 阻塞 | OVERLAPPED 读 + `SessionWriter` 写 | 读写子线程，UI 隔离 | 旧路径存在 UI 写等待/假成功风险 | CoolTerm 有独立发送线程 | xcom 方向正确 |
| partial/零字节/断开 | 工作树先交付 partial；HEAD 同时 stop 仍丢尾；零字节以 50 ms tick 避免 busy loop | I/O 错误关闭会话 | 某些错误不通知 UI | RealTerm 有错误灯/提示资料 | xcom 需提交尾数据修复并补实机测试 |
| 二进制/Hex/换行 | HEX 保真；文本会 CRLF/ANSI/C0 规范化 | 终端文本为主 | 文本/传输路径较多 | RealTerm/CoolTerm 二进制能力较强 | 必须把“文本非保真、HEX 保真”持续写在 UI/文档 |
| 时间戳/日志 | Lua 按 ingress/gap 做时间戳；文件通道有独立反压与 loss ledger | 日志能力成熟但语义不同 | 有日志/传输记录 | CoolTerm 日志能力成熟 | xcom 的数据账本更强，但 close/磁盘失败要有最终状态 |
| TX 队列/取消/重连冲突 | 有界队列，FULL/BUSY 区分；单发/自动/文件互斥 | TX backlog 偏无界 | 有界发送缓冲、历史上有截断/假成功路径 | RealTerm/CoolTerm 有传输取消/节流选项 | xcom 不应复制“满即截断”行为；可借鉴可取消进度显示 |

## 最小改进方案（不直接改代码）

1. **先修 `RxKick` 提交契约**：统一所有 `submit_rx_kick()` 调用，提交失败立即清 gate；增加 High-critical 满载、恢复显示、timestamp drain 三条回归测试。
2. **修 coact Windows PAL 启动失败生命周期**：握手超时必须 stop + join；wake/started 任一句柄创建失败都让 boot 失败且无脱离线程；修正 coact CTest 生成路径后再宣称通过。
3. **提交并验证读尾数据修复**：保留工作树的 `GetOverlappedResult` 优先策略，加入 stop/read 同时置位、partial read、零字节、拔线错误用例。
4. **关闭 DTR/RTS 与关闭收尾错误**：pin replay 失败进入可见错误；明确 `TIMEOUT` 时仍处于 CLOSING 的 UI/ABI 契约，避免用户误以为端口已释放。
5. **补文本边界与真实 Windows 验收**：跨块 CRLF/pending-CR、中文选择命中、COM10+、独占占用、DTR/RTS 复位、CTS/XOFF、拔插/断电、慢磁盘各至少一条可复现测试。

## 当前推荐验收门

- `xcom_core`：MSVC Release + CTest；coact 外部 checkout 使用 CI pin，不能使用旧绝对构建路径。
- 串口实机：COM3/COM10+ 各一端，8N1/奇偶/1.5/2 stop、RTS/CTS、XON/XOFF、DTR/RTS 连接 NRST/BOOT。
- 故障序列：接收洪峰 → staging 满；最后一批数据后立即 Close；拔线/断电；低波特率 CTS 持续低；日志目录不可写/磁盘慢；关闭中重新 Open。
- 每条验收同时断言：UI 状态、核心 `port_state`、错误码/错误环、RX/TX 计数、文件字节数、句柄是否释放。
