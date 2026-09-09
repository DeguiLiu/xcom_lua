# LLCOM Lua API 设计借鉴笔记（llcom-lua-api.md）

> 来源：`D:\workspace\SSCOM_lua\ref\llcom\LuaApi.md`（816 行）+ C# 注册代码 `LuaEnv/LuaLoader.cs:18-82` + `LuaEnv/LuaApis.cs`（120 行）。
> 对照基线：xcom_lua 的 C ABI 头文件 `D:\workspace\SSCOM_lua\xcom_core\include\xcom\xcom.h`（v1.3，370 行）。

## 1. LLCOM 暴露给 Lua 的 API 全表

> 来自 `LuaApi.md` 第 19-243 行（"C#层增加的接口(底层接口)"）+ `LuaLoader.cs:21-32`（注册表）。

### 1.1 通道类（核心 API）

| 函数 | 签名 | 用途 | 注册位置 |
|---|---|---|---|
| `apiSend(channel, data[, table])` | `(string, string\|nil, table?) → bool` | 向通道发数据，`table` 给 mqtt 这种需要复合参数的通道用 | `LuaLoader.cs:35` |
| `apiSetCb(channel, callback)` | `(string, function) → nil` | 订阅通道，**可多次订阅**（多个 callback 同时被调用） | `head.lua:85-91` |
| `apiUnsetCb(channel, callback)` | `(string, function) → bool` | 取消订阅 | `head.lua:93-106` |
| `apiSendUartData(str)` | `(string) → bool` | **旧接口**，仅保留兼容，等价于 `apiSend("uart", str)` | `LuaLoader.cs` 没注册，是 `head.lua:134-136` 包装的别名 |
| `uartReceive(data)` | 全局函数 | **旧接口**，用户声明此函数作为回调 | `head.lua:137-139` 注册到 `uart` 通道 |

### 1.2 工具类

| 函数 | 签名 | 用途 | 注册位置 |
|---|---|---|---|
| `apiGetPath()` | `() → string` | 返回 ProfilePath（应用数据目录） | `LuaLoader.cs:24` |
| `apiUtf8ToHex(str)` | `(string) → string` | UTF-8 → GBK 编码后的 hex 串 | `LuaLoader.cs:21` |
| `apiAscii2Utf8(bytes)` | `(byte[]) → byte[]` | GBK → UTF-8 | `LuaLoader.cs:22` |
| `apiQuickSendList(id)` | `(number) → string\|nil` | 取快捷发送区数据，**返回值首字母 S=string/H=hex** | `LuaLoader.cs:28` + `head.lua:71-81` 二次包装 |
| `apiInputBox(prompt, default, title)` | `(string, string, string?) → bool, string` | 模态输入框 | `LuaLoader.cs:30` |
| `apiPrintLog(log)` | `(string) → nil` | 写到 Lua log 文件 + 触发 PrintLuaLog 事件 | `LuaLoader.cs:26` |
| `apiAddPoint(num, line)` | `(number, number) → nil` | 加点到 ScottPlot 图，line=0..9 | `LuaLoader.cs:32` |
| `apiStartTimer(id, time)` / `apiStopTimer(id)` | send-convert 沙箱专用 | 不带 sys 框架的简单定时器 | `LuaLoader.cs:40-41`（仅 `t != "send"` 时注册） |

### 1.3 sys 框架（合宙 Luat 移植）

> 完整定义在 `LuaEnv.cs:232-544` 的 `sysCode` 字符串内嵌的 Lua 代码 + `DefaultFiles/core_script/sys.lua`（但实际项目里 sys.lua 几乎为空，看 LuaEnv.cs 内嵌字符串才是真）。

| 函数 | 用途 |
|---|---|
| `sys.wait(ms)` | 当前协程延时 |
| `sys.waitUntil(id, ms)` | 等消息或超时 |
| `sys.waitUntilExt(id, ms)` | 同上但超时返回 false |
| `sys.taskInit(fun, ...)` | 创建协程任务，返回 coroutine |
| `sys.timerStart(fnc, ms, ...)` | 单次定时器 |
| `sys.timerLoopStart(fnc, ms, ...)` | 循环定时器 |
| `sys.timerStop(val, ...)` | 停定时器 |
| `sys.timerStopAll(fnc)` | 停所有同回调的定时器 |
| `sys.timerIsActive(val, ...)` | 查定时器是否运行 |
| `sys.subscribe(id, callback)` | 订阅消息 |
| `sys.unsubscribe(id, callback)` | 取消订阅 |
| `sys.publish(...)` | 发布消息到内部队列 |
| `sys.tigger(param)` | 内部使用，外部触发协程恢复 |

### 1.4 log 框架

> 来自 `DefaultFiles/core_script/log.lua`，**6 级**与 xcom_lua 完全一致：

```lua
LOGLEVEL_TRACE = 0x01  -- T
LOGLEVEL_DEBUG = 0x02  -- D
LOGLEVEL_INFO  = 0x03  -- I
LOGLEVEL_WARN  = 0x04  -- W
LOGLEVEL_ERROR = 0x05  -- E
LOGLEVEL_FATAL = 0x06  -- F

log.trace/debug/info/warn/error/fatal(tag, ...)
```

输出格式 `[I]-[tag] log content`（参见 `log.lua:20` `PREFIX_FMT = "[%s]-[%s]"`）。

### 1.5 string 库扩展

> 来自 `DefaultFiles/core_script/strings.lua`，**6 个**：

| 函数 | 用途 | xcom_lua 现状 |
|---|---|---|
| `string.toHex(str, separator="")` | 字符串 → "313233" 大写 hex | **已实现** `script_engine.lua:85-90` |
| `string.fromHex(hex)` | hex → 字符串，自动过滤分隔符 | **已实现** `script_engine.lua:92-98` |
| `string.toValue(str)` | "123" → `\1\2\3`（十进制数 → 字节串） | **未实现** |
| `string.utf8Len(str)` | UTF-8 字符数（不是字节数） | **已实现** `script_engine.lua:116-120` |
| `string.formatNumberThousands(num)` | 1000 → "1,000" 千位分隔 | **未实现** |
| `string.split(str, delimiter)` | 按分隔符拆 | **已实现** `script_engine.lua:100-114` |
| `string.urlEncode(str)` | URL 编码 | **未实现** |

xcom_lua **覆盖率 4/7 = 57%**。差的 3 个里 `toValue` 是低优先级，`formatNumberThousands` 和 `urlEncode` 中优先级（如果做 HTTP 调试就有用）。

## 2. xcom_lua 当前 ABI（xcom.h v1.3）

> 完整列表见 `xcom_core/include/xcom/xcom.h`，主要分类：

### 2.1 句柄与配置
- `xcom_version() → uint32_t`
- `xcom_list_ports(XcomPortInfo*, uint32_t, uint32_t*) → status, count`
- `xcom_create(XcomCreateOptions*) → XcomHandle`
- `xcom_open(XcomHandle, XcomPortConfig*) → status`
- `xcom_open_async + xcom_take_open_result`（v1.3 新增）

### 2.2 I/O
- `xcom_close(h, timeout_ms)`
- `xcom_send(h, data, size, flags)` — **同步复制 + 队列-返回**
- `xcom_drain_display(h, char*, capacity, *written)` — 拉取下一个已格式化的显示批
- `xcom_get_snapshot(h, XcomSnapshot*)` — 状态/计数器
- `xcom_take_error(h, XcomError*)` — 出错环形队列取一条

### 2.3 显示/自动发送
- `xcom_set_options(h, XcomDisplayOptions*)`
- `xcom_set_auto_template(h, data, size, interval_ms, flags)`

### 2.4 文件 I/O
- `xcom_log_open/append/flush/close`
- `xcom_file_submit_atomic + xcom_file_take_completion`
- `xcom_file_stream_begin/append_borrowed/commit/abort`

### 2.5 测试
- `xcom_test_inject_rx(h, data, size)` — 测试 seam

## 3. LLCOM ↔ xcom_lua ABI 对照

| LLCOM Lua API | xcom_lua C ABI | 说明 |
|---|---|---|
| `apiSend("uart", data)` | `xcom_send(h, data, size, 0)` | LLCOM 是 Lua 函数，xcom_lua 是 C ABI。LLCOM 走 channel 名 dispatch，xcom_lua 写死 `XcomHandle`。 |
| `apiSetCb("uart", cb)` | FFI 回调到 `core/script_engine.lua` 的 `record.recv_hook` | LLCOM 一个 channel 可挂多 cb；xcom_lua 每个脚本只能有一个 recv_hook |
| **无 `apiListPorts()`** | `xcom_list_ports(out, cap, *count)` | xcom_lua 提供，LLCOM 用 `System.IO.Ports.SerialPort.GetPortNames()` 在 C# 层完成 |
| **无 `xcom_get_snapshot` 等价** | `xcom_get_snapshot()` 返回 rx/tx/queue/port_state 等 13 个计数器 | LLCOM 通过 `Tools.Global.setting.ReceivedCount/SentCount` 两个计数，无完整 snapshot |
| `apiAddPoint(num, line)` | **无对应** | xcom_lua 的 `core/waveform.lua` 直接 GDI 绘制，Lua 脚本**不能**通过 ABI 推数据。 |
| `apiInputBox(...)` | **无对应** | xcom_lua ImGui 弹窗是 Lua-side `imgui.lua` 直接 `OpenPopup`，不走 C ABI |
| `apiQuickSendList(id)` | **无对应** | xcom_lua 的「多发送条目」是 Lua-side 状态，不在 ABI 中 |
| `apiUtf8ToHex / apiAscii2Utf8` | **无对应** | xcom_lua 通过 `core/charset.lua` `cs.utf8_to_cp / cs.cp_to_utf8` |
| `apiGetPath()` | **无对应** | xcom_lua 的 `runtime` 目录是启动时确定的常量 |
| `apiStartTimer / apiStopTimer` (send 沙箱) | **无对应** | xcom_lua 的 send-convert 钩子是同步的，不需要定时器 |
| `sys.wait / taskInit / timerLoopStart / publish / subscribe` | **无对应** | xcom_lua `core/script_engine.lua` 自己实现了 `sys.timer_start/loop_start/stop`（基于 luv），但**没有 publish/subscribe 事件总线** |
| `log.trace/debug/info/warn/error/fatal` | **无对应** | xcom_lua `script_engine.lua:322-327` 实现了同名同 6 级 API |

## 4. xcom_lua 应该「加」的 API

按借鉴优先级排序：

### 高优先级（解决 xcom_lua 当前痛点）

1. **`apiAddPoint(num, line)` → ABI** —— 让 Lua 脚本能把任意数据推送到波形图（多线）。当前 xcom_lua `core/waveform.lua` 是 GDI 内部绘制，Lua 脚本只能订阅 data feed，**不能自定义曲线**。LLCOM 的 PlotPage 允许 10 线 1000 点任意来源。
   **实施方案**：`xcom.h` 加 `xcom_plot_push(handle, line, value)` 或在 Lua 端建一个 Lua-side plot ring buffer。

2. **`sys.publish / sys.subscribe / sys.waitUntil` 事件总线** —— xcom_lua 当前多脚本之间无法通信（详见 `llcom-script-system.md`）。LLCOM `head.lua:108-125` `tiggerCB` + `channelCb` + `sys.publish/waitUntil` 是成熟模式。
   **实施方案**：`script_engine.lua` 加 `M:publish(event, ...)` / `M:subscribe(event, fn)` / `M:wait(event, ms)`，内部用 coroutine resume + queue。

3. **`apiQuickSendList(id)` 返回值带 hex 标记** —— LLCOM 用首字母 `S`/`H` 区分。xcom_lua 的多发送条目目前是纯 string 列表，缺 hex/string 自动判别。
   **实施方案**：Lua-side `quick_send` 表每项 `{ text, hex = bool }`，`apiQuickSendList(id)` 返回 `{ text = ..., hex = ... }`。

### 中优先级（增强能力）

4. **`string.formatNumberThousands` + `string.urlEncode`** —— 5 行内可加。
5. **`string.toValue`** —— 把 "12" 转成 `\1\2`，配合 hex 显示做协议解码时有用。
6. **`apiGetPath()`** —— 暴露给脚本做配置持久化。当前 Lua 脚本只能写到 `cwd`，没有受控目录。

### 低优先级（生态功能，暂缓）

7. **`apiInputBox` ABI 化** —— xcom_lua 用 `imgui.lua` 的 `OpenPopup` 即可，不必走 ABI。
8. **多通道（mqtt/tcp-server/winusb）** —— LLCOM 的 `LuaApis.SendChannelsRegister` 模式值得借鉴，但 xcom_lua 目前只有串口，加通道要等 `xcom_core` 支持。短期可以做一个 `channel = "uart"` 的常量化。

## 5. xcom_lua 应该「改」的 API

### 5.1 `xcom_drain_display` 的回调时机
LLCOM 的 `LuaApis.SendChannelsReceived` 是**事件驱动**（收到数据时立即触发回调），xcom_lua 的 `xcom_drain_display` 是**轮询驱动**（调用者每 10ms 拉一次）。事件驱动对多脚本场景延迟更低，但实现更复杂。短期保持轮询，**TODO 标记为改进点**。

### 5.2 `apiSetCb` 支持多订阅者
LLCOM `head.lua:84-91` 把 channel cb 存成 list，**多个 Lua 脚本可同时订阅同一个 channel**：
```lua
apiSetCb("uart",function (data) log.info("a",data) end)
apiSetCb("uart",function (data) log.info("b",data) end)  -- 不覆盖前一个
```
xcom_lua 的 `script_engine.lua:542-568` `dispatch_receive` **就是顺序遍历所有 enabled 脚本**，行为等价（无需改）。但 `on.send` 链是**短路**（任何 hook 返回 `nil` 就 abort），与 LLCOM 的多订阅模型有微妙差异：LLCOM 的多 cb 是**并行**（都跑），xcom_lua 的 `dispatch_send` 是**链式**（后者覆盖前者）。这是有意为之，不一定要改。

### 5.3 `apiUtf8ToHex` 的中文路径 hack
LLCOM `head.lua:25-29` + `:38-52` 把 `require/loadfile/io.open` 都包了一层 UTF-8 → GBK 转码，**解决中文目录下的 Lua 加载崩溃**：
```lua
local oldrequire = require
require = function (s)
    local s = apiUtf8ToHex(s):fromHex()  -- UTF-8 → hex → GBK → 真实路径
    return oldrequire(s)
end
```
**xcom_lua 当前没有这个保护**！如果用户把 xcom_lua 安装到中文路径下，`package.path` 里的中文会直接传到 `uv.fs_open` 触发 Windows ERROR_INVALID_NAME。需要补。

### 5.4 3 态 HEX 显示
LLCOM 的 `Settings.cs:21` `_showHexFormat` 是 0/1/2（混合/只 string/只 hex），对应 DataShowPage 的 `IsThreeState="True"`。xcom_lua 的 `xcom.h:127` `hex_view` 只是 uint8_t 0/1。**应扩展为 `hex_view : 2; show_raw : 1; ...` 位字段或 0/1/2 enum**。

## 6. 一句话总结

> LLCOM 的 Lua API 设计**完全是「Lua-first」的**：C# 端注册一打 `CS.llcom.LuaEnv.LuaApis.Xxx` 静态方法，Lua 端直接当全局函数用，没有显式的 ABI 边界。
> xcom_lua 是「ABI-first」的：C ABI 是边界，Lua 通过 FFI 调 C ABI 包装层。
> 借鉴时**优先抄数据模型**（通道 + 回调 + 多订阅 + sys 框架），**不要抄调用风格**（不要为每个小功能加 C ABI 函数，能在 Lua 层做的放 Lua 层）。
