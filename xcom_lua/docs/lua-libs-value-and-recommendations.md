# Lua 库价值评估与推荐(vendored + 候选)

> 面向 xcom_lua(LuaJIT 2.1 + ImGui 串口调试工具)的第三方 Lua 库盘点。
> 所有结论以"LuaJIT 2.1 可直接 require"为第一准则,C 模块一律排除。
> 日期:2026-09-05

## 一、总览:现状一句话

xcom_lua 的脚本系统(LLCOM 兼容 API)目前**只有手写的基础字符串工具**,
第三方库已 vendor 三批并统一放在 `xcom_lua/libs/`；`struct`/`json` 已接入脚本沙箱，其余是"验证可用"的弹药
库,等具体功能需要时再 require。

| 批次 | 位置 | 内容 | 接入状态 |
|---|---|---|---|
| 1 | `xcom_lua/libs/openresty/` | resty.lrucache / resty.iconv / tablepool / jit.* 工具 | ✅ 测试绿,❌ 未使用 |
| 2 | `xcom_lua/libs/lua51/` | Penlight 39 模块 / moses / luaunit / LuaLogging / 30log 等 67 文件 | ✅ 测试绿,❌ 未使用 |
| 3 | `xcom_lua/libs/protocol/` | struct / json / crc32 / crc16_modbus / crc16_ccitt / crc8 | ✅ 全绿,✅ struct+json 已接入脚本沙箱 |

## 二、按能力域评估已 vendor 的库

### 2.1 协议开发域(串口工具核心)——**struct.lua 最有价值**

| 库 | 能力 | 项目场景 | 价值 |
|---|---|---|---|
| **struct.lua**(iryont,MIT) | `pack/unpack(">BBHH",...)` 二进制帧 | Modbus RTU / 自定义协议脚本的帧解析,替代手写 `string.byte` 逐字节拼 | ⭐⭐⭐⭐⭐ 刚需,全仓库此前空白 |
| **json.lua**(rxi,MIT) | encode/decode,UTF-8 原生 | 脚本配置持久化、数据导出、与上位机交换 | ⭐⭐⭐⭐ 此前全仓库无 JSON |
| **CRC 家族**(已落地) | crc32(davidm,MIT) / crc16-modbus(自写) / crc16-ccitt(移植) / crc8(自写) | Modbus CRC16、协议校验——脚本最常见诉求 | ⭐⭐⭐⭐⭐ 已全绿,见下 |

**CRC 落地结论**(2026-09-05 调研 20+ 仓库):GitHub 纯 Lua CRC 生态**没有全家桶**——
多算法库全是 C 模块(luarocks 的 luacrc16/luacrc32)或 Lua 5.3+ 语法(user-none/lua-hashings、
AleksandrBelous/CRC16_Parametric)或无许可证且污染全局(vic111/crc16_modbus,直接
`table = {...}` 覆盖全局 table!)。最终组合:
- `crc32.lua` ← davidm/lua-digest-crc32lua(MIT)原样 vendor,唯一 LuaJIT BitOp 一等支持
- `crc16_ccitt.lua` ← clarkli86(Apache-2.0)bit32→bit 移植
- `crc16_modbus.lua` / `crc8.lua` ← 自写(查表 70 行;vic111 的表是数学常数可参考,代码不可用)
- 四个标准向量全过:"123456789" → 0xCBF43926 / 0x4B37 / 0x29B1 / 0xF4

struct.lua 语法备忘(与 Python struct 不同):
```
< / >          字节序切换(默认小端)
b B h H i I l L   1/2/4/8 字节整数
f d            4/8 字节浮点(纯 Lua frexp 实现)
s              零结尾字符串
c<n>           定长字符串,空格填充
-- Modbus 读保持寄存器帧:
struct.pack(">BBHH", 0x01, 0x03, 0x0064, 0x0002)  --> "\x01\x03\x00\x64\x00\x02"
```

### 2.2 字符串/编码域——大部分已覆盖

| 库 | 能力 | 价值 | 备注 |
|---|---|---|---|
| pl.stringx | startswith/strip/split 等 Python 风格 | ⭐⭐⭐⭐ | 纯工具表,**不改写** string 元表(改写元表的是 `stdlib-ext/string_ext.lua`,见 2.5 危险区);stringx 返回的方法可手动挂到 string 上,由调用方决定 |
| **resty.iconv** | iconv 全家(UTF-8↔GBK/BIG5/任意) | ⭐⭐⭐ | 双补丁后 LuaJIT 可用;但 GPL-3.0 + 需 libiconv-2.dll;显示路径已有 kernel32 方案,iconv 留给脚本可选 |
| script_engine 内置 | toHex/fromHex/split/utf8Len | ⭐⭐⭐⭐ | LLCOM 兼容层自带,**已在使用** |
| charset.lua(项目自研) | DBCS→UTF-8 显示转码 | ⭐⭐⭐⭐⭐ | 核心路径,别动 |

### 2.3 数据结构域——超配

moses(函数式全家桶)+ Penlight(tablex/Map/Set/List/MultiMap/OrderedMap)+
binary_heap + set:串口工具用不到这么多,但零成本放着。真要用时优先
`pl.tablex.deepcopy/merge` 和 `resty.lrucache`(TTL 缓存,如"最近命令"面板)。

### 2.4 工程域——测试/日志可用

- **luaunit**(X11):xcom_lua/tests 已有自写 ok/eq 风格,luaunit 适合更重的断言场景
- **LuaLogging**(MIT):console/file/rolling_file 三个纯 Lua appender;`runtime/xcom_diag.log` 若要结构化日志可用

### 2.5 危险区(标了别用)

| 库 | 为什么危险 |
|---|---|
| `lua51-libs/stdlib-ext/*.lua` | require 即**改写 LuaJIT 内置** string/table/math/io/package,污染热路径 |
| `strict.lua` / `strictness.lua` | require 即装 `_G.__index`,后续任何未声明全局读取直接报错——只能放在独立脚本首行 |
| `std.lua` | 依赖未 vendor 的 modules.lua,加载必失败 |
| 用了 Lua 5.2/5.3 专属语法的库 | LuaJIT 2.1 是 5.1 语义(带部分 5.2 扩展):无 `string.pack/unpack`(5.3)、无整数除 `//`(5.3)、无 `goto` 标签语法差异等;见到的库要先过 LuaJIT 语法这一关 |

### luarocks 本地源(D:\develop\Lua\5.1\luarocks.bat)结论

可用,但生态是 2008-2012 年的 Lua 5.1 老库。CRC 相关检索:
- `luacrc16` 1.0-1 —— **C 模块**(crc16.c),排除
- `crc32` 1.1-1 —— **C 模块**(crc32.c + wrap.c),排除
- 已装包 luafilesystem/luasocket/luazip/md5 全是 C,对 LuaJIT 运行时无用

**结论:luarocks 老生态没有可用的纯 Lua CRC;CRC 走 GitHub 纯 Lua 实现路线**(见第四节)。

## 三、缺口分析(按痛感排序,CRC 已补)

1. ~~CRC/校验和~~ ✅ 已落地(四算法全绿)
2. **hexdump 美化**——Top-5 #1,复制即用
3. **base64**——Top-5 #2 的 rbx-hashing base 家族一并补
4. **完整 utf8.\*(5.2 API)**——现在只有 utf8Len;char/codes/offset 缺
5. **Modbus PDU 层**——Top-5 #3,摘抄改写半天的活,主站模拟器的捷径

## 四、候选库调研结论(两路调研已完成)

### 4.1 CRC/校验和家族(已落地)

见 2.1 节——组合式 vendor 完成,crc32+ccitt 取现成,modbus+crc8 自写。

### 4.2 更广的 LuaJIT 适用库(Top-5 候选,全部实测验证)

调研方法:GitHub API + raw 源码验证 + 本项目 `runtime/luajit.exe` 实际加载测试。
环境事实(实测):`bit` 可用、**`bit32` 不可用**、无 `string.pack`、`//` 语法错误。

| # | 库 | 许可 | LuaJIT 实测 | 动作 | 价值 |
|---|---|---|---|---|---|
| 1 | **NexaRift/lua-hexdump** | MIT | ✅ 零改动加载 | 整文件 vendor | hexdump -C 风格,hex 视图是串口工具核心;hook 机制可对接 ImGui |
| 2 | **Dekkonot/rbx-hashing** 的 adler32+base16 | Unlicense | ⚠️ 一行补丁(`bit32=require('bit')`) | 摘 2 个单文件 | Adler-32 全网唯一实测可用纯 Lua;base16 补 hex decode |
| 3 | **kooiot/lua-modbus** + kikito/middleclass | MIT | ⚠️ 摘抄改写(去 string.pack/`~`,配 struct.lua) | PDU/buffer 层摘抄 | Modbus 主站模拟器捷径;buffer.lua 实测可加载 |
| 4 | **Tieske/date** | MIT | ✅ 零改动加载 | vendor `src/date.lua` 单文件 | 时间戳毫秒精度/相对时间,os.date 做不到 |
| 5 | **kikito/inspect.lua** | MIT | ✅ 零改动加载 | vendor 单文件 | 用户脚本调试输出(inspect(frame)),与 serialize 互补 |

**实测通过但暂不取**:compat53(沙箱模式可用,但 string.pack 已有 struct、utf8 可单补)、
luamark(基准测试,Timer 可接 uv.hrtime)、middleclass(与 30log/classlib 重叠,
仅当取 lua-modbus 时才需要)、lua-lockbox 的 util/stream+queue+bit(base64 decode 可从中摘)。

**负面清单**(调研排除,防止将来重复踩坑):
- NMEA-0183:jvermillard/lua-nmea **经纬度字段拿反**(GGA bug),luaGPS 单句返回空;真需要时以其为骨架自行修正+补 XOR 校验
- byteStreamBuffer:5.3 位运算符,**LuaJIT 解析直接失败**,已归档
- COBS/SLIP/AT 解析:全网无维护中的纯 Lua 库;COBS ~40 行、SLIP ~20 行,需要时自写
- LuaJIT FFI 特化方向:无值得 vendor 的独立库,继续走"直接 FFI cdef kernel32/自家 DLL"路线
- CSV:pl.data(已 vendor)覆盖,生态无像样独立库
- luatz 时区:本机时区 os.date 够用,不取

## 五、接入建议(vendor 之外)

库躺在 libs 不会自己有用。建议按"功能拉动"接入:

1. **脚本 API 暴露**:把 struct/json/CRC 挂进 script_engine 的沙箱
   (像 toHex 一样,`uartApi` 或全局),LLCOM 脚本即可 `struct.pack(...)`
   ——`struct`/`json` 已落地,CRC 家族待接
2. **不动主进程**:stdlib-ext 类改写内置的库**永远不进** script_engine
3. **package.path 注入点**:main.lua 启动时把三个 libs 目录加进
   package.path(已对 `libs/protocol/` 落地),而非每个脚本自己拼

## 六、测试入口

```
cd xcom_lua
runtime/luvjit.exe tests/test_protocol_libs.lua    # struct+json+CRC 51/51
runtime/luvjit.exe tests/test_openresty_lua.lua   # 43/43
runtime/luvjit.exe tests/test_iconv.lua           # 9/9
runtime/luvjit.exe tests/test_lua51-libs.lua      # 78/78
```
