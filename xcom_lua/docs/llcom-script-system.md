# LLCOM 脚本系统借鉴笔记（llcom-script-system.md）

> 来源：
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\LuaEnv\LuaEnv.cs`（XLua 沙箱 + sysCode 内嵌）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\LuaEnv\LuaRunEnv.cs`（全局上下文）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\LuaEnv\LuaLoader.cs`（Initial + Run）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\DefaultFiles\core_script\head.lua`（启动注入）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\DefaultFiles\core_script\log.lua`（6 级日志）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\DefaultFiles\core_script\sys.lua`（基本空，sys 实际在 LuaEnv.cs 内嵌）
> - `D:\workspace\SSCOM_lua\ref\llcom\llcom\DefaultFiles\user_script_run\*.lua`（5 个示例）
>
> 对照：xcom_lua 的 `D:\workspace\SSCOM_lua\xcom_lua\core\script_engine.lua`（819 行）

## 1. LLCOM 的三类脚本运行时

LLCOM 区分**三种**脚本上下文（这是与 xcom_lua 最大的架构差异）：

### 1.1 长跑沙箱（LuaEnv / user_script_run）

```csharp
// LuaEnv.cs:185-210 — 构造
public LuaEnv(object input = null) {
    lua = new XLua.LuaEnv();
    if (input != null)
        lua.Global.SetInPath("lua", input);
    lock (taskLock) lua.DoString(sysCode);   // ← 把 sys 框架整段注入
    triggerCB = lua.Global.Get<XLua.LuaTable>("sys").Get<XLua.LuaFunction>("tiggerCB");
    lua.Global.SetInPath("@this", this);     // ← 把自己传给 Lua

    // 加上 package.path
    lua.DoString(@"... package.path = ... ;?.lua;core_script/?.lua;user_script_run/requires/?.lua ...");
}
```

特性：
- 单例、跨整个 app 生命周期
- 包含完整 sys 框架（协程、定时器、发布订阅）
- 用户用 `require 'core_script.head'` 启动
- **同时只能跑一个**主脚本（`LuaRunEnv.New(file)` 第 170-201 行），用 `Task.Run` 加载

### 1.2 一次性 send-convert 沙箱（LuaLoader.Run / user_script_send_convert）

```csharp
// LuaLoader.cs:85-136
private static XLua.LuaEnv luaRunner = null;
public static byte[] Run(string file, ArrayList args = null, string path = "user_script_send_convert/") {
    if (luaRunner == null) {
        luaRunner = new XLua.LuaEnv();
        luaRunner.Global.SetInPath("runType", "send");  // ← 关键
        Initial(luaRunner, "send");
    }
    // ... 调用 _G["!once!"]()
}
```

特性：
- **单例 + 全局缓存**（同一个 XLua.LuaEnv 反复用）
- `runType == "send"` 时 `head.lua` 第 55 行 `return` 跳过 log/sys 注册，**禁用定时器和 log 输出**（`LuaApi.md:9` 明确说「发送处理脚本，不可用定时器/任务接口，也不可用 log/print 接口」）
- 用 `luaRunner.Global.GetInPath<string>("!file!")` 传文件名到 Lua（而不是 dofile）
- 加载 `head.lua` 第 67-80 行注册的 `_G["!once!"]` 函数，调用返回 byte[]
- `ClearRun()` 方法 `luaRunner = null` 清空实现「热重载」

### 1.3 一次性 recv-convert 沙箱（user_script_recv_convert）

模式与 send-convert 相同，区别是 `runType = "recv"`（推测，看 `Global.cs` 的引用）。当前 LLCOM 代码里似乎没有专门的 recv-convert 调度入口（搜不到），**疑似此功能被废弃或合并到通用通道**。

## 2. LLCOM 的「通用通道」架构（最值得借鉴的部分）

### 2.1 C# 端注册

```csharp
// LuaApis.cs:96-117
private static Dictionary<string, Func<byte[], XLua.LuaTable, bool>> SendChannels
    = new Dictionary<string, Func<byte[], XLua.LuaTable, bool>>();
public static void SendChannelsRegister(string channel, Func<byte[], XLua.LuaTable, bool> cb)
    => SendChannels[channel] = cb;

public static bool Send(string channel, byte[] data, XLua.LuaTable table) {
    if (SendChannels.ContainsKey(channel))
        return SendChannels[channel](data, table);
    return false;
}

public static void SendChannelsReceived(string channel, object data)
    => LuaRunEnv.ChannelReceived(channel, data);
```

### 2.2 各通道注册自己的处理器

```csharp
// Uart.cs:65-74 — 串口通道
LuaApis.SendChannelsRegister("uart", (data, _) => {
    if (IsOpen() && data != null) {
        SendData(data);
        return true;
    }
    return false;
});

// Global.cs 的 mqtt/tcp-server/socket-client/netlab/winusb 也类似
```

### 2.3 Lua 端 API

```lua
-- 用户脚本示例（channel-demo.lua:8-11）
apiSetCb("uart", function (data)
    log.info("uart received", data)
end)
local sendResult = apiSend("uart", "ok!")
```

### 2.4 流程图

```
                    ┌──────────────────────────────────┐
                    │ Lua 脚本（长跑沙箱）             │
                    │ apiSetCb("uart", cb1)            │
                    │ apiSetCb("uart", cb2)            │
                    │ apiSend("uart", data)            │
                    └────────────────┬─────────────────┘
                                     │
                                     │ apiSend 实际是 CS.llcom.LuaEnv.LuaApis.Send
                                     ▼
                    ┌──────────────────────────────────┐
                    │ LuaApis.SendChannels["uart"]     │
                    │ = Uart.SendData(...)             │
                    └────────────────┬─────────────────┘
                                     │ 串口收数据时
                                     ▼
                    ┌──────────────────────────────────┐
                    │ Uart.ReadData() (Model/Uart.cs)  │
                    │ LuaApis.SendChannelsReceived(    │
                    │     "uart", bytes)               │
                    └────────────────┬─────────────────┘
                                     │
                                     ▼
                    ┌──────────────────────────────────┐
                    │ LuaRunEnv.ChannelReceived()      │
                    │ → toRun.Add(...)                 │
                    │ → runTigger() 触发 sys.tigger    │
                    └────────────────┬─────────────────┘
                                     │
                                     ▼
                    ┌──────────────────────────────────┐
                    │ tiggerCB(id, type, data)         │
                    │ 遍历 channelCb[type] 所有 cb     │
                    │ 每个 cb(data) 调用               │
                    └──────────────────────────────────┘
```

### 2.5 关键：`head.lua:84-106` Lua 端多订阅实现

```lua
-- 设置回调（每个 channel 一个 cb list）
local channelCb = {}
function apiSetCb(channel, cb)
    if not channelCb[channel] then
        channelCb[channel] = {}
    end
    table.insert(channelCb[channel], cb)   -- ← 追加，不是覆盖
end

-- 取消某个回调（必须传同一个函数引用）
function apiUnsetCb(channel, cb)
    if not channelCb[channel] then return true end
    for i=1,#channelCb[channel] do
        if channelCb[channel][i] == cb then
            table.remove(channelCb[channel], i)
            ...
            return true
        end
    end
end

-- 触发回调
tiggerCB = function (id, type, data)
    local result, info = pcall(function ()
        if id >= 0 then  -- 定时器消息
            sys.tigger(id)
        else  -- 通道消息
            if channelCb[type] then
                for i=1,#channelCb[type] do
                    channelCb[type][i](data)   -- ← 依次调用所有订阅者
                end
            end
        end
    end)
    if not result then
        log.error("task", "run failed\r\n"..apiAscii2Utf8(tostring(info)))
    end
end
```

## 3. xcom_lua 当前的脚本系统（core/script_engine.lua）

### 3.1 架构

```
xcom_lua/scripts/*.lua
        ↓ loadfile + setfenv
core/script_engine.lua（沙箱）
        ↓ 1 Hz poll()
        ↓ 事件触发
core/waveform.lua（波形）
core/charset.lua（编码）
xcom_imgui_bridge.cpp（C ABI 桥）
xcom_core DLL（Win32 串口）
```

### 3.2 关键设计（已实现）

| 特性 | 位置 | 说明 |
|---|---|---|
| 沙箱 env 构建 | `script_engine.lua:237-368` | `build_env()` 每次 load_script 都重建，Lua-side 函数库严格白名单 |
| 钩子派发 | `:542-596` | `dispatch_receive` 和 `dispatch_send` 顺序遍历所有 enabled 脚本的 hook |
| 3-strikes 自动禁用 | `:556-563, :586-592` | 连续失败 3 次自动清空 hook + log 警告 |
| 行过滤器 | `:646-686` | `apply_line_filter` 按完整行做 keep/drop，未终止行 pending + idle flush |
| 高亮规则 | `:712-728` | `collect_rules` 聚合所有 enabled 脚本的 highlight.rule |
| mtime 热重载 | `:764-777` | `poll()` 1Hz 检查 `record.mtime`，变了就 `load_script(name)` |
| REPL | `:780-817` | `eval_command` 注入第一个 enabled 脚本的 env |
| 6 级 log | `:180, :322-327` | `LEVEL_TAG = {TRACE, DEBUG, INFO, WARN, ERROR, FATAL}` |
| 字符串扩展 | `:85-125` | `string.toHex/fromHex/split/utf8Len`（4 个） |
| sys 定时器 | `:329-340` | `sys.timer_start/loop_start/stop`（基于 luv） |

### 3.3 缺位

| 缺位 | 说明 |
|---|---|
| **多脚本通信** | 没有 `publish/subscribe`/`waitUntil`，脚本 A 和脚本 B 之间无消息总线 |
| **多通道抽象** | `uart.send()` 写死，没有 `apiSend("uart"/"tcp"/"mqtt", data)` |
| **send-convert 沙箱分离** | send hook 在与 run hook **同一个引擎**里，xcom_lua 的 `dispatch_send` 用同一个 `script_engine` 实例。LLCOM 把它们分开（不同 `XLua.LuaEnv` 单例）以禁用定时器 |
| **中文路径 hack** | 无保护，package.path 直接传给 luv |
| **sysCode 内嵌模式** | xcom_lua 的 `sys` 是 Lua 端自己实现的 `env.sys = {...}`，没有「从 C 注入 sys 框架」的通道 |

## 4. 可借鉴的具体实现细节

### 4.1 中文目录保护（高优先级）

**LLCOM `head.lua:38-52`**：

```lua
local oldrequire = require
require = function (s)
    local s = apiUtf8ToHex(s):fromHex()
    return oldrequire(s)
end
local oldloadfile = loadfile
loadfile = function (s)
    local s = apiUtf8ToHex(s):fromHex()
    return oldloadfile(s)
end
local oldioopen = io.open
io.open = function (s, p)
    local s = apiUtf8ToHex(s):fromHex()
    return oldioopen(s, p)
end
```

**思路**：`apiUtf8ToHex(s)` 把 UTF-8 字符串转成 GBK 字节的 hex（用 `BitConverter.ToString(Encoding.GetEncoding("GB2312").GetBytes(input)).Replace("-","")`），`fromHex` 把 hex 转回 GBK 字符串，**绕开 XLua 在中文路径下的 UTF-8/ANSI 转换 bug**。

**xcom_lua 实施建议**：在 `xcom_lua/main.lua` 启动 `script_engine` 之前 monkey-patch：
```lua
-- 伪代码
local gbk_to_utf8 = charset.cp_to_utf8
local utf8_to_gbk = charset.utf8_to_cp
local old_require = require
function require(s) return old_require(gbk_to_utf8(utf8_to_gbk(s), 936)) end
```
**风险**：所有 xcom_lua 的 `require` 都会被包，性能损失可忽略，但调试时不友好。**仅在 Windows + 中文路径下启用**。

### 4.2 三种沙箱分离（中优先级）

**LLCOM 现状**：
- `LuaEnv` 沙箱（user_script_run）：长跑 + sys 框架
- `LuaLoader.Run` 沙箱（user_script_send_convert）：一次性 send-convert，无 sys 框架
- 未来的 recv-convert 沙箱（推测）

**xcom_lua 现状**：所有 hook 共用 `script_engine.M` 的同一个 env（line 145-174），`sys.timer_start` 在 send hook 里也能用。**这意味着 send-convert 脚本可以注册定时器，这违反 LLCOM 的设计原则（一次性脚本不应该有副作用）**。

**xcom_lua 实施建议**：把 `script_engine` 拆成两个：
- `engine_long.lua`：长跑 env，含 `sys`/`log`/`uart`/`wave`/`highlight`
- `engine_send.lua`：一次性 env，只有 `uart`/`string`/`log`/`on.send`/`filter`，无 `sys`

LLCOM 是用 C# 端两个 `XLua.LuaEnv` 实例实现，xcom_lua 用 Lua-side 两套 `env` 表即可。

### 4.3 sysCode 注入模式（低优先级，仅风格）

LLCOM `LuaEnv.cs:232-544` 把 sys 框架的完整 Lua 源码**作为 C# 字符串字面量内嵌**在 C# 文件中。好处：单一可执行文件，不需要分发 .lua 文件；坏处：Lua 代码不可热重载、调试时不友好。

xcom_lua 已经用 Lua 文件分发 sys 模块，**不需要改**。但如果未来要做「单一 exe」打包，可以参考这个模式。

### 4.4 ConcurrentBag 任务队列（仅供参考）

LLCOM `LuaRunEnv.cs:21, 58-92`：

```csharp
private static ConcurrentBag<LuaPool> toRun = new ConcurrentBag<LuaPool>();
private static void addTigger(int id, string type = "timer", byte[] data = null) {
    if (isRunning) {
        toRun.Add(new LuaPool { id = id, type = type, data = data });
        runTigger();
    }
}

private static void runTigger() {
    if (!canRun) return;
    lock (lua) {
        try {
            while (toRun.Count > 0) {
                if (tokenSource.IsCancellationRequested) return;
                while (toRun.Count > 0) {
                    try {
                        LuaPool temp;
                        toRun.TryTake(out temp);
                        triggerCB.Call(temp.id, temp.type, temp.data);
                    } catch (Exception le) {
                        LuaApis.PrintLog("回调报错：\r\n" + le.ToString());
                    }
                    if (tokenSource.IsCancellationRequested) return;
                }
            }
        } catch (Exception ex) {
            StopLua(ex.ToString());
        }
    }
}
```

**关键设计**：
- `ConcurrentBag` 无锁并发入队
- `lock(lua)` 串行化 XLua 调用（XLua 不是线程安全的）
- `CancellationTokenSource` 一键停止所有 timer
- 错误隔离：`try { triggerCB.Call(...) } catch { PrintLog }` 防止单个回调炸掉整个循环

xcom_lua 用 luv 异步 timer + coroutine.resume 实现等价功能，但**没用 CancellationToken**——`shutdown()` 是手动遍历 `self.timers` 调 `timer:stop()`。LLCOM 的 CancellationToken 模型更优雅，但 luv 没暴露这个概念，**不值得为这个改架构**。

### 4.5 send/recv 沙箱单例缓存（高优先级）

**LLCOM `LuaLoader.cs:85-136`**：

```csharp
private static XLua.LuaEnv luaRunner = null;
public static byte[] Run(string file, ArrayList args = null, string path = "...") {
    if (luaRunner == null) {
        luaRunner = new XLua.LuaEnv();
        luaRunner.Global.SetInPath("runType", "send");
        Initial(luaRunner, "send");
    }
    lock (luaRunner) {
        var pathIn = Tools.Global.ProfilePath + path + file;
        luaRunner.Global.SetInPath("!file!", pathIn);
        // ...
        XLua.LuaFunction f = null;
        while (f == null)
            f = luaRunner.Global.Get<XLua.LuaFunction>("!once!");
        var lr = f.Call(null, new Type[] { typeof(byte[]) });
        return lr[0] as byte[];
    }
}
```

**关键设计**：
- **单例 XLua.LuaEnv**：每次 send 不重建 VM
- **`_G["!once!"]` 缓存**：把文件 `load()` 结果存到表 `script[file]`，第一次跑就 `loadfile` 一次，后续直接 `script[file]()`。`head.lua:73-79` 实现：
  ```lua
  local script = {}
  _G["!once!"] = function()
      runLimitStart(3)
      if not script[_G["!file!"]] then
          script[_G["!file!"]] = load(CS.System.IO.File.ReadAllText(_G["!file!"]))
      end
      local result = script[_G["!file!"]]()
      runLimitStop()
      return result
  end
  ```
- **`ClearRun()`**：`luaRunner = null` 让下次 Run 重建 VM 实现「全清重载」

**xcom_lua 现状**：`script_engine.lua:382-414` `load_script` 每次都 `loadfile + setfenv + pcall`。如果用户短时间改 1 个文件触发 `enable(name)`，脚本会**重新执行顶层代码**（sys.taskInit 又会跑一遍）。

**xcom_lua 实施建议**：在 `script_engine.M` 加 chunk 缓存：
```lua
function M:load_script(name)
    local record = self.scripts[name]
    if not record then return false, ... end
    local chunk = record.cached_chunk
    if not chunk then
        chunk, err = loadfile(record.path)
        if not chunk then ... end
        record.cached_chunk = chunk
    end
    -- 重建 env（每次新建），但 chunk 复用
    record.env = build_env(self, record)
    setfenv(chunk, record.env)
    local ok, run_err = pcall(chunk)
    -- ...
end
```
**关键点**：chunk 缓存可保留模块级 upvalue，但 env 每次新建以保证 hooks 干净。LLCOM 的做法是 chunk 缓存到 Lua 表，env 是全局的 `_G`，**不能简单照搬**——xcom_lua 当前 setfenv 模式已经实现了 env 隔离。

### 4.6 OnlineScriptsPage 列表卡（中优先级，UI 借鉴）

LLCOM `OnlineScriptsPage.xaml:79-122` 的卡片布局（详见 `llcom-ui-layout.md` §4）。可作为 xcom_lua 「脚本启用面板」的视觉模板。

## 5. xcom_lua 当前 hook 模型与 LLCOM 对比

### xcom_lua dispatch_receive

```lua
-- core/script_engine.lua:542-568
function M:dispatch_receive(text)
    for _, name in ipairs(self.order) do
        local record = self.scripts[name]
        if record and record.enabled and record.recv_hook then
            local ok, result = pcall(record.recv_hook, text)
            if ok then
                record.strikes_recv = 0
                if result == nil or result == false then
                    return nil  -- 整批丢弃
                elseif type(result) == "string" then
                    text = result  -- 链式转换
                end
            else
                record.strikes_recv = record.strikes_recv + 1
                -- 3 次后自动禁用
            end
        end
    end
    return text
end
```

**模型**：脚本按 `self.order` 顺序链式处理；返回 `nil`/`false` 整批丢弃；返回 `string` 替换；返回其他真值保留原文本。

### LLCOM channelCb

```lua
-- head.lua:115-119
if channelCb[type] then
    for i=1,#channelCb[type] do
        channelCb[type][i](data)   -- 不取返回值，多 cb 并行调用
    end
end
```

**模型**：**多个 cb 并行**，每个 cb 都可以自由处理 data（没有「链式」概念）；cb 没有返回值协议。

### 差异总结

| 维度 | xcom_lua | LLCOM |
|---|---|---|
| 多 cb 模型 | 链式（前脚本的输出是后脚本的输入） | 并行（每个 cb 独立看原始 data） |
| 返回值协议 | `nil`=drop, `string`=transform | 无（cb 不返回值） |
| 失败处理 | 3-strikes 自动禁用 hook | 整 tiggerCB 用 pcall 包裹，错误只 log 不禁用 |
| 触发时机 | 同步：每次 `process_rx(text)` 时 | 异步：`SendChannelsReceived` → `toRun.Add` → `runTigger` → `triggerCB.Call` |

**借鉴方向**：xcom_lua 可以加 `on.receive.multi` 模式让用户声明「并行多 cb」，但目前**链式模型对单脚本场景足够**。LLCOM 的多 cb 模型是为「多脚本同时订阅同一事件」设计的——xcom_lua 当前每个脚本只有一个 recv_hook，但**多脚本场景下等价行为已由 `dispatch_receive` 的 `for _, name in ipairs(self.order)` 实现**，不需要改。

## 6. 一句话总结

> xcom_lua 的 `core/script_engine.lua`（819 行）已经覆盖 LLCOM 80% 的功能（多脚本、env 沙箱、3-strikes、log 6 级、string 扩展、REPL、mtime 热重载）。
> **缺**的是：
> 1. **多脚本事件总线**（`sys.publish/subscribe/waitUntil`）—— 5-7 个新方法 + 一个小 queue，可加
> 2. **send-convert 沙箱与长跑沙箱的隔离** —— 拆 `M.new` 为两个工厂函数
> 3. **chunk 缓存** —— 加 `record.cached_chunk` 避免 enable 时重跑顶层代码
> 4. **中文路径 hack** —— 在 `main.lua` 加 `require`/`loadfile`/`io.open` monkey-patch
> 5. **`string.formatNumberThousands` + `string.urlEncode`** —— 5 行内可加
>
> **不要借鉴**：C# `XLua.LuaEnv` 单例 + ConcurrentBag 队列 + CancellationToken——这是 C# 栈的细节，LuaJIT + luv 的协程模型已经更简单。
