# 评审：最近两个提交（`b0994c2`、`16a92ab`）

| 项 | 值 |
| --- | --- |
| 评审对象 | `b0994c2f826a794c85cd7b5850757299ea652d29`、`16a92abf8eedda9bb2ffe810cd71ecd41adefa3e` |
| 评审日期 | 2026-09-13 |
| 后续状态（2026-09-13 工作区） | P0-1 所述 ABI「关闭超时把 `port_state` 写回 OPEN」的回滚已在工作区删除（`xcom_core/src/abi/xcom_abi.cpp:425-428` 现为 "there is no ABI-side rollback write"）；P1-2 的 CLOSING 守卫已加入 `xcom_lua/ui/window.lua:3079-3081`。**另：本报告 §4 第 1 条对「两个调用点共享同一预算」的认定有误，已在原处标注更正** —— `b0994c2` 只改了 `core_close` 的默认形参，两个点击调用点（`_imgui_close`、`on_btn_close`）当时仍显式传 `2000`，显式实参覆盖默认值，故该提交「把点击关闭从 2000 ms 降到 200 ms」的声明目标当时**并未实现**；现已改为走默认值。下文保留对 `b0994c2`/`16a92ab` 当时 HEAD 的历史结论与行号。 |
| 目标场景 | Windows PC 经串口连接 MCU |
| 取证方式 | 只读；所有引用行号由 `git show HEAD:<path>` 导出核对（工作区为脏树，见 §2） |
| 未覆盖 | 外部工具内部实现（无其源码/联网）、`luv` C 源码（仅 `runtime/luv.dll`）、真实串口硬件行为 |

---

## 一、结论

- `b0994c2` 的两处改动**方向正确、单看都合理**，但与 HEAD 的 ABI 关闭语义组合后产生一个可复现的缺陷：点击 Close 时若 teardown 超过 200 ms，`xcom_close` 超时会**把 `port_state` 回滚成 OPEN**，UI 随即在同一 tick 读回「已连接」，发送按钮重新可用；此时的发送返回成功并被写入视图与自动保存日志，而字节被核心静默丢弃（或报成误导性的「队列满」）。
- 根因不在本提交（「乐观写 CLOSING + 超时回滚」是更早的 ABI 设计），但本提交把该路径从**近乎不可达**变成**只要关闭时有在途写就必然出现**。
- `16a92ab` 是纯文档清理，其「两处陈旧项已修正」的论断经逐条核对**成立**；唯一不足是删完后「已发现并保留」清单只剩 1 项，而同类陈旧引用在源码中仍有 7 处。
- 五条最小改进见 §6，均不需要新增抽象层。

## 二、评审范围与未验证边界

- **AGENTS.md**：`find . -iname AGENTS.md` 在仓库全域（含隐藏目录）**0 命中**，本仓库无 AGENTS.md，评审依据为会话级项目约定。
- **工作区是脏树，且与两个提交不同版**：未提交改动 53 个文件 / `+6136 −1215`（另有 111 个文件暂存删除，含 vendored `xcom_core/framework/coact`）。其中 `xcom_lua/ui/window.lua` 相对 HEAD 变化 1634 行、`xcom_core/src/io/serial_backend_win.cpp` `+193/−22`、`xcom_core/src/abi/xcom_abi.cpp` `+194/−62`、`xcom_core/src/ao/xcom_ao.cpp` `+298/−183`。
  - **处理方式**：直接读磁盘文件得到的行号与语义属于工作区版本，**不等于**两个提交。本报告所有行号均以 HEAD 为准；凡工作区独有的能力（tri-state `XCOM_LINE_LEAVE_ALONE`、50 ms 读 tick、DCB 回读校验、`LineApplyResult`、`tx_submit_status.hpp` 等）一律标注为「工作区独有」，不作为 HEAD 事实。
- **子代理使用**：按只读方式跑了能力普查（minimax-worker，`--thinking high`），但其读取的是**工作区**，故其行号未被采用；报告内每条结论均由主模型在 HEAD 上重新取证。
- **无法在本机验证**：PuTTY / Tera Term / RealTerm / CoolTerm 的内部行为（本机无这些仓库，亦未联网复核）；`luv` 的 stdio/reap 语义（`xcom_lua/runtime/luv.dll` 为二进制，无源码）；真实串口硬件行为（无 MSVC、无串口）。§5 中对外部工具的断言来自仓库内**未提交**的 `docs/design-serial-tool-comparison.md`（其自标 `[S]`/`[D]`），属**未独立验证**；本报告仅对「本工具侧」的代码事实负责。

## 三、两个提交的目的与实际效果

| 提交 | 声明目的 | 实际效果（已核对） |
| --- | --- | --- |
| `b0994c2` story-perf(dm) | 新增非阻塞 spawn；把 UI 线程的同步关闭等待从 2000 ms 降到 200 ms；声称「客户端已无 `os.execute`」 | 新增 `spawn_async`（**全仓 0 调用方**）；`core_close` 与重连 reset 的等待预算改为共享常量 `CLOSE_WAIT_MS = 200`；「无 `os.execute`」在 `xcom_lua/ui`、`xcom_lua/core` **成立**（仅 `libs/`、`tests/` 有，属第三方与测试） |
| `16a92ab` story-docs(dm) | 删文档状态行与历史说明；「`xcom.h` 注释」「`xcom_ffi.lua` 版本常量」两处已修正故删除相应条目 | 纯文档，4 文件 `+5/−16`；两条论断**均成立**（见 §4） |

`b0994c2` 只改了 2 个 Lua 文件，未触碰任何 C++ 核心、测试或文档——这是 §5 中 P0/P1 的直接成因。

## 四、认可的设计或修复

1. **关闭等待收敛为具名常量并给出理由**：`xcom_lua/ui/window.lua:1188`（`local CLOSE_WAIT_MS = 200`）把原先散在两处的魔数统一。
   - **更正（2026-09-13）**：本条原写「两个调用点共享同一预算（`window.lua:1198`、`window.lua:2794`），与提交声明一致」，**该认定有误**。`1188`/`1198` 是常量的**定义**与它在 `core_close` 内的**默认形参**，`2794` 是重连路径；**两个点击调用点**（`_imgui_close`、`on_btn_close`）当时都仍显式传 `2000`。Lua 中显式实参优先于默认形参，因此点击关闭的实际预算仍是 2000 ms，提交声明的「降到 200 ms」并未生效——本次已把两个调用点改为不传参，走 `CLOSE_WAIT_MS` 默认值。教训：核对「常量被采纳」时不能只看定义与默认值，必须找到**每一个实际调用点**确认它没有覆盖默认。
2. **不阻塞消息泵的动机正确**：`xcom_close` 是同步等待（`xcom_core/src/abi/xcom_abi.cpp:365-378` 的 20 ms 轮询循环），点击路径上确实等于冻结窗口。
3. **`spawn_async` 的参数契约正确、注释准确**：`xcom_lua/ui/win32.lua:757-760` 说明 argv 是列表而非命令行（无 shell 转义面）；实现中 `args` 以表传入 `uv.spawn`（`778`、`781-782`），失败返回 `nil, err`（`789-790`），并在 `792` `unref()` 以免子进程独自吊住事件循环。
4. **文档提交的两处论断成立**：`xcom_core/include/xcom/xcom.h:1-58` 现为「LuaJIT client（`xcom_lua/core/xcom_ffi.lua` via LuaJIT FFI）」，全文无 PySide6/ctypes；`xcom_lua/core/xcom_ffi.lua:2` 与 `:223-231` 现为 v1.5 / `version_minor = 5`。改动**无悬挂锚点**：全仓 grep `结论与定位`、`文档状态` 0 命中，也无文档引用被删的表格行。
5. **复审中确认的既有设计（非本两提交引入）**：COM10+ 与独占打开（`serial_backend_win.cpp:131-137`：`\\.\` 前缀补齐 + `dwShareMode = 0` + `FILE_FLAG_OVERLAPPED`）；占用探测默认关闭且有 DTR 复位风险的书面理由（`xcom_ffi.lua:365-376`）；零字节完成不误投（`serial_backend_win.cpp:412-417`）；线错误四类分计（`serial_backend_win.cpp:516` 附近）。

## 五、不足之处

### P0-1 关闭超时把 `port_state` 回滚成 OPEN，导致「UI 显示已连接 → 发送假成功 → 字节静默丢弃」

```mermaid
flowchart LR
  A["点击 Close<br/>xcom.close(core, 200)"] --> B["ABI 乐观写 CLOSING<br/>xcom_abi.cpp:359"]
  B --> C["AO 执行 owner_close<br/>含在途 TX 的 200 ms 排水"]
  C --> D["200 ms 预算到期<br/>ABI 回滚 port_state = OPEN<br/>xcom_abi.cpp:382-383"]
  D --> E["同一 tick 内 poll_status<br/>window.lua:1199"]
  E --> F["UI HSM: CLOSING → OPEN<br/>view_model.lua:275-282"]
  F --> G["send_enabled = true<br/>view_model.lua:324/332"]
  G --> H["xcom_send 返回 OK<br/>并 _echo_tx 写入视图与日志"]
  H --> I["描述符代际已过期<br/>AO 静默丢弃<br/>xcom_ao.cpp:452-465"]
```

- **复现条件（确定触发，非概率）**：关闭时存在在途写。`abort_pending_write` 单独就会消耗 200 ms 排水宽限（`serial_backend_win.cpp:271-291`、`serial_backend_win.hpp:29-36`），而写超时按块长换算：115200 下约 2.8 s、9600 下约 34 s（`xcom_core.cpp:861-877`）。因此「发送未结束时点 Close」必然超过 200 ms 预算。此时 `xcom_close` 在 `xcom_abi.cpp:382` 写回 OPEN 并返回 `XCOM_ERR_TIMEOUT`（`383`）。
- **潜在后果**：
  1. `core_close` 紧接着的 `self:poll_status()`（`window.lua:1198-1199`）读到 OPEN，HSM 由 CLOSING 翻回 OPEN（`view_model.lua:275-282` 无代际/顺序校验），窗口在核心仍在 teardown 的这段时间显示「已连接」；
  2. `send_enabled` 恢复（`view_model.lua:324,332`），而 `core_send` 只拦 `recovering()`、不复查端口（`window.lua:1214-1219`），`xcom_send` 因 `port_state == OPEN` 通过检查并返回 `XCOM_OK`（`xcom_abi.cpp:415-440`）；
  3. UI 随即 `_echo_tx`（`window.lua:1245`）把载荷回显到视图**和自动保存日志**；
  4. 该写的代际在 `xcom_abi.cpp:432-434` 固化，关闭提交会推进代际，`send_user_action` 判定 `stale` 后**既不计数也不报错**直接释放（`xcom_ao.cpp:452-465`）；若落在提交之前，则报 `XCOM_ERR_FULL, "serial write queue full"`（`xcom_ao.cpp:466-473`），把「会话正在拆除」说成「队列满」。
- **证据**：`xcom_abi.cpp:334-388`、`396-445`；`xcom_ao.cpp:452-473`；`view_model.lua:85-87`（CLOSING 时 open/close 均被拒，故 200 ms 内用户既不能重开也不能重关）、`275-282`、`324-332`；`window.lua:1198-1199`、`1245`；`serial_backend_win.cpp:271-291`；`xcom_core.cpp:879-895`。
- **为何是本提交放大**：2000 ms 预算与后端上界（200 + 200 + 1500 ms ≈ 1.9 s，`serial_backend_win.cpp:24`、`:250`）本就是配套的（`serial_backend_win.hpp:34` 明写 "Keep this well under the 2000 ms ABI close budget"），故改动前该回滚分支几乎不可达；改成 200 ms 后它成为常态。
- **同时受影响的还有三处不变量描述**，本提交均未同步：`serial_backend_win.hpp:29-36`、`docs/performance.md:174`（「关闭 SLO 的 2 s … `xcom_ffi.close` 默认 timeout 2000 ms」）、`xcom_core/tests/tx_diag_test.cpp:7,74`。当前同时存在三种预算：200（`window.lua:1198/2794`）、2000（`window.lua:982` 退出路径）、2000（`xcom_ffi.lua:517-518` FFI 默认）。

### P1-1 `xcom.close` 返回值在两处被丢弃，超时对用户不可见

- **复现**：任一次超时关闭（同上）。**后果**：`core_close`（`window.lua:1198`）与重连 reset（`window.lua:2794`）都不检查 `XCOM_ERR_TIMEOUT`；注释（`window.lua:1182-1187`）称「没确认的 teardown 由 CLOSING 看门狗兜住」，但该看门狗只在 HSM 侧，且其行为见 P1-2。**证据**：`window.lua:1190-1200`、`2788-2795`；`xcom_abi.cpp:383`。

### P1-2 CLOSING 看门狗在核心确实仍 CLOSING 时强制 FAULT

- **复现**：核心 teardown 超过 5 s（`CLOSING_TIMEOUT_MS = 5000`，`window.lua:1625`）。可达路径：`stop_and_join()` 的 `thread_.join()` 无超时上界（`xcom_core.cpp:297-309`），落盘慢/卡住即可超过 5 s。**后果**：UI 镜像被强判 FAULT 而核心仍是 CLOSING，随后一次 Open 会读到核心 CLOSING 并被拒（`xcom_abi.cpp:344-346` 的 CLOSED 幂等判断不覆盖 CLOSING；HSM 表内 CLOSING 无 Open 边），用户看到的是「开不起来」而非「正在关闭」。**证据**：`window.lua:2387-2406`（`2398` 无条件 `force_fault`）。工作区已加入 `port_state ~= xcom.port_closing` 守卫并在注释中记录该振荡现象（属未提交改动，仅作旁证）。

### P2

1. **`spawn_async` 是零调用方的推测性 API**：全仓仅 `xcom_lua/ui/win32.lua:769` 一处定义，无调用、无测试；实际唯一的非阻塞 shell 打开走既有 `ShellExecuteW`（`win32.lua:625-626`、`749-775`）。CI 的 Lua 套件按设计排除需要 luv 的用例（`.github/workflows/ci.yml:55-60`），故它在本机与 CI 都不会被执行。与项目约定「最小实现」「禁止过度设计」相悖。
2. **`spawn_async` 的 luv 契约细节无法在本机验证**：`win32.lua:780` 用 `{ nil, nil, nil }`（长度 0 的表）作为默认 stdio；`792` 的 `unref()` 配合 `788` 可能为 nil 的 `on_exit`。luv 无源码（仅 `runtime/luv.dll`），提交说明称已核对 luv 的 `process.c`，本次无法复现该核对，故仅作未验证标注，不主张缺陷。
3. **HEAD 的 RTS/DTR 是静默失效**（非本两提交引入）：`set_rts` 在 RTS/CTS 流控下直接 `return`（`serial_backend_win.cpp:319-328`），`set_rts`/`set_dtr` 均为 `void` 且 `EscapeCommFunction` 返回值被丢弃（`327`、`333`）；开启时也无条件下发 `SETDTR/CLRDTR`（`380-383`）。故「勾选 RTS 但引脚未动」在 HEAD 表现为成功。ABI 侧 `dtr_enable/rts_enable` 在 HEAD 只接受 0/1（`xcom.h:115-116`），客户端也只做布尔映射（`xcom_ffi.lua:436-437`、`457-458`）——**HEAD 无任何路径能表达「不改动该线路」**。
4. **HEAD 无 DCB 回读校验**：`SetCommState` 成功即信任（`serial_backend_win.cpp:371-374`），不支持的非标波特率被 USB 桥静默取整时无法察觉（工作区已补回读比对，属未提交）。
5. **文档提交删得对但删得不全**：`docs/architecture.md` 的「已发现并保留」清单现只剩 CMake 与 ABI 版本命名空间一项，而同类 Python 时代陈旧引用在 HEAD 仍有 7 处：`xcom_abi.cpp:5`（"CoreWorker QThread"）、`xcom_abi.cpp:642`、`xcom_core.hpp:248,398,561`、`xcom_ao.hpp:38`、`log_writer.cpp:179`，另有 `xcom_lua/core/config.lua:6` 提到「PySide6 config.toml / 两个前端」。清单只剩一项易让人误判陈旧描述已清完。

## 六、与 PuTTY / Tera Term / RealTerm / CoolTerm 的差距

**本工具已具备**（HEAD 证据，避免低估）：COM10+ 与独占打开（`serial_backend_win.cpp:131-137`）；OVERLAPPED 异步读写 + 独立读线程与写线程（`serial_backend_win.cpp:134-137`、`xcom_core.cpp:297-309`）；partial/零字节/`ERROR_IO_PENDING`/`ERROR_OPERATION_ABORTED` 处理（`serial_backend_win.cpp:404-418`、`:437-443`）；8N1 与 5/6/7/8 数据位、None/Odd/Even/Mark/Space 校验、1/1.5/2 停止位（`serial_backend_win.cpp:355-370`）；RTS/CTS 与 XON/XOFF（`:362-370`）；线错误分类与 COMSTAT hold 归因（`serial_backend_win.hpp:42-66`）；注册表枚举 + `WM_DEVICECHANGE` + ~1 s 兜底（`window.lua:842-850`、`970-978`）；RX 原始字节落盘与显示侧时间戳分属不同级（`xcom.h:346-360`、`docs/design-rx-display-pipeline.md:45`）。

**缺失或退化**（本工具侧以代码为据；外部工具侧标注为未独立验证）

| # | 差距 | 本工具证据 | 对照工具（未独立验证） |
| --- | --- | --- | --- |
| 1 | 无法「不改动 DTR/RTS」，打开必然驱动引脚 | `serial_backend_win.cpp:380-383`、`xcom.h:115-116` | RealTerm / CoolTerm 提供保持与「复位设备」按钮 `[D]` |
| 2 | 无自动复位／进 ROM 时序、无 1200 bps touch | 仅手动勾选且只在 OPEN 时下发，`window.lua:2410-2430` | Arduino IDE / esptool |
| 3 | 波特率只能取自固定列表（18 值），无自定义输入 | `connection_panel.lua:13-17` | PuTTY / Tera Term / RealTerm / CoolTerm 均可输入任意值 |
| 4 | UI 允许必然失败的线格式组合（8 数据位 + 1.5 停止位） | `connection_panel.lua:19` 与后端校验冲突 | 其他工具通常在 8 位数据下禁用该选项 |
| 5 | 时间戳粒度退化：仅「新段首行 + 间隔阈值」打一个戳 | `docs/design-rx-display-pipeline.md:45`、`74-87` | 各工具均提供逐行时间戳开关 |
| 6 | 日志无格式模式（HEX/纯文本/是否含合成 TX 行） | `xcom.h:346-350`、`window.lua:1533-1581` | RealTerm / CoolTerm 有显式捕获格式 `[D]` |
| 7 | 发送节流只有固定 gap；在途 `WriteFile` 不可抢占 | 无逐字符/逐行延迟；仅排水宽限 | Tera Term 发送为可暂停/可中止的增量式 `[S]`（见 `docs/design-serial-tool-comparison.md` §6） |
| 8 | 重枚举按描述匹配而非稳定 ID，同型号多设备会切错/找不回 | `window.lua:2689-2741` | 该项目文档亦自列为落后项 |

补充：RX 原始字节与 Lua 侧合成 TX 行是两个生产者，严格交错顺序无保证（`window.lua:1538-1545` 自述为已知债务 A1）。

## 七、最小改进方案（不改代码，避免过度设计）

1. **解耦关闭预算与 ABI 回滚**：让 `xcom_close` 的超时路径不再把 `port_state` 写回一个可写状态。最小改动：删除「乐观写 CLOSING + 超时回滚」这对操作，交由 AO 自己发布状态（工作区已有同向改动，可直接复用）；若保留回滚，则回滚目标不得是 OPEN。随后同步三处不变量描述：`serial_backend_win.hpp:29-36`、`docs/performance.md:174`、`xcom_core/tests/tx_diag_test.cpp:74`。
2. **让被丢弃的发送可见**：`xcom_ao.cpp:452-465` 的 stale 分支至少并入 `metrics.tx_rejected` 并推一条错误；`_echo_tx` 的回显与实际入队绑定，避免日志声称已发送。
3. **关闭路径不静默**：`window.lua:1198`、`:2794` 检查 `xcom.close` 返回值，超时给一条状态提示；并给 `window.lua:2398` 的 `force_fault` 加上「核心已非 CLOSING」前提（工作区已实现）。
4. **处置 `spawn_async`**：删除，或落到一个真实调用方 + 一个 Windows 侧用例；在其被使用前不必保留公开面。
5. **补齐两处「必失败/必复位」的用户可见性**：给 DTR/RTS 增加「不改动」一档（需 ABI 与 FFI 同时放开到 0/1/2），并在 UI 上禁止或解释「8 数据位 + 1.5 停止位」组合。

## 八、优先修复清单

| 序 | 项 | 级别 |
| --- | --- | --- |
| 1 | 关闭超时回滚成 OPEN → 发送假成功且字节静默丢弃（P0-1） | P0 |
| 2 | stale 发送丢弃无计数无报错、`_echo_tx` 仍写入日志 | P1 |
| 3 | CLOSING 看门狗在核心仍 CLOSING 时强判 FAULT；`xcom.close` 返回值被丢弃（P1-1/P1-2） | P1 |
| 4 | `spawn_async` 零调用方：删除或补调用方与用例（P2-1） | P2 |
| 5 | DTR/RTS 无「不改动」路径；1.5 停止位可选组合（P2-3、§6 第 1、4 项） | P2 |

