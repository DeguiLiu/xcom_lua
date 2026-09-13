# 设计：串口状态机异常用例矩阵

## 结论

目标不是「迁移表合法」，而是**在每一种异常下工具仍然能够工作、并且显示与实际一致**。
下面把 C++ 迁移表、跨层竞态、显示管线三层逐格列清，每格给出判定与要求。

**已确认由本会话改造引入的两个缺陷（已在修）**
- **F1** `OPENING × OpenDone(失败)` 落 FAULT（该边无守卫）→ 同代 FAULT 被镜像解读为「活动会话故障」→ 进入 8 s 重连，失败原因被覆盖。「打开失败」与「会话故障」被 `FAULT` 一个状态重载。
- **F2**（已修）关闭超时时 Lua 看门狗曾无条件强制 FAULT，而核心仍在 CLOSING → 随后打开被 BUSY 拒绝，可在 FAULT↔CLOSING 间振荡；现仅当核心已离开 CLOSING 时才 `force_fault`（`xcom_lua/ui/window.lua:3079-3081`）。

**三处靠闩锁补偿、必须显式文档化才能验证的格子**（不是缺陷，但读代码看不出对）
- `OPENING × Close`、`CLOSED × Close`、以及「Open 后立刻 Close 被优先级重排」三格，**都没有迁移边**，
  全部依赖 `cancel_open` 闩锁在 owner_open 完成时改走 `OPENING --Cancel--> CLOSING`。

**四条原待决均已定论**（见 §4）：`CLOSING × Fault` 改落 `CLOSED`；`CLOSED × Fault` 删除
该边、仅记诊断；`last_open_result` 不加尝试代（竞态经核实不可达）；`generation` 回绕不在
C++ 侧（相等比较），`<` 比较只存在于 Lua 镜像，本会话不改。

---

## 一、C++ 迁移矩阵（状态 × 事件，含非法对）

图例：**✓** 有边且正确 ｜ **L** 无变、靠 `cancel_open` 闩锁补偿 ｜ **A** ABI 前置检查拦截，事件不会到达 ｜ **D** 丢弃（正确）。原 **X**（缺陷/待决）格已全部定论，见 §4。

| | Open | Close | Fault | OpenDone | CloseDone | Cancel |
| --- | --- | --- | --- | --- | --- | --- |
| **CLOSED** | ✓→OPENING<br/>`kOwnerOpen` | **L**<br/>ABI 无 pending 时直接 OK；有 pending 时置闩锁 | **D**<br/>丢弃：无会话不发布 FAULT，仅记诊断（§4.2） | D 陈旧 | D 陈旧 | D 陈旧 |
| **OPENING** | **A**<br/>ABI 返回 BUSY | **L**<br/>闩锁→Cancel→CLOSING | ✓→FAULT<br/>打开中器件消失 | ✓成功→OPEN<br/>✓失败→CLOSED（F1 已修） | D 陈旧 | ✓→CLOSING<br/>`kCancelClose` |
| **OPEN** | **A**<br/>ABI 返回 BUSY | ✓→CLOSING<br/>`kOwnerClose` | ✓→FAULT | D 陈旧 | D 陈旧 | **A**<br/>ABI 只在 OPENING 置闩锁 |
| **CLOSING** | **A**<br/>ABI 返回 BUSY | ✓重入<br/>幂等（测试断言） | ✓→CLOSED<br/>`kOwnerClose`：关闭意图已达成（§4.1） | D 陈旧 | ✓→CLOSED<br/>`kCloseCommit` | D 陈旧 |
| **FAULT** | ✓→OPENING<br/>病灶边，必须存在 | ✓→CLOSING | D 幂等 | D 陈旧 | D 陈旧 | D 陈旧 |

### 两处「无变」为何是正确的（必须写进代码注释，否则后人无法判定）

1. **`CLOSED × Close`**：`xcom_close` 在 `port_state == CLOSED` 且 `last_open_result != BUSY` 时**直接返回 OK**，
   不提交信号 → 事件根本不会到达 AO。这是幂等，不是缺失。**但**若存在 pending open（`last_open_result == BUSY`），
   ABI 置 `cancel_open = 1` 并提交 Close；该信号在 CLOSED 态被丢弃，而闩锁在 Open 完成时生效。
2. **`OPENING × Close` 与优先级重排**：Close 以 `critical=true` 提交，Open 以普通 High 提交，
   同分区内 Close 可能被**先**服务。此时状态是 CLOSED → Close 被丢弃（见上），但闩锁已置位 →
   随后 Open 执行 `owner_open`（CreateFile **会成功**）→ 完成时见闩锁 → 走 Cancel → CLOSING → CLOSED。
   **用户最后意图（关闭）胜出，收敛正确。** 代价是「真的开了一次又立刻关」，但对设备是安全的
   （DTR 会脉冲一次），必须在此记录这个副作用。

## 二、跨层异常用例（每格：工具是否仍工作 / 显示是否正常）

| # | 异常 | 现状 | 要求 |
| --- | --- | --- | --- |
| 1 | 打开失败（错口/占用/拒绝）（F1） | 已修：失败落 CLOSED，不进 8 s 重连，原因由 `last_open_result` 承载 | 不进入宽限窗；显示真实失败原因；可从 CLOSED 重开 |
| 2 | 关闭超时 + 看门狗（F2） | 已修：核心仍为 CLOSING 时不 `force_fault`，显示「正在关闭」 | 保持 |
| 3 | Open/Close 被优先级重排 | 靠闩锁收敛（§1.2） | 保持；host 测试已加（`serial_transition_test`）+ 注释 |
| 4 | 器件拔出（活动会话） | 读线程回调 → FAULT → 宽限窗 → 重连 | 拔插后同一 COM 口重开不得 ACCESS_DENIED；故障时立即释放句柄 |
| 5 | USB 重枚举导致端口号变化 | 宽限窗内按原端口重开 | 端口不存在时应提示用户，不得静默失败或无限重试 |
| 6 | 写故障（TX）且 critical 预留也拒绝 | 直接 store FAULT（I1 例外）→ **AO 本地状态与发布视图不一致** | 必须有对账规则：AO 在下一次迁移前以发布视图为准，或该分支同时更新 AO 本地状态 |
| 7 | 陈旧的 OpenDone 满足新的打开尝试 | 经核实不可达：OpenDone/CloseDone 从无异步信号提交，`queue_open` 以 BUSY 拒绝第二次打开（§4.3） | 不加尝试代；ABI 的「单次在途」不变式已足够 |
| 8 | `generation` 回绕（uint32） | C++ 侧全部是相等比较（`!=`/`==`，无 `<`）；`<` 仅见于 Lua 镜像 `view_model.lua` | Lua 侧决定是否改回绕安全比较；C++ 无需改（§4.4） |
| 9 | 模态对话框（另存/打开） | 已修：`OFN_ENABLEHOOK` 泵 | 保持；挂住 30 s 不丢数据 |
| 10 | 脚本死循环 / 抛错 | 有执行预算；但批失败会静默从视口消失 | 非静默（计数 + 提示），且不得整批消失 |
| 11 | 磁盘卡死 / U 盘拔出 | 已落地：文件通道反压 + ErrorRing 停滞/恢复 | 保持；`save_rejected_bytes` 对 RX 恒 0 |
| 12 | 未开日志时池满 | 已落地：计入 `save_rejected_bytes` 并报 DATA LOSS | 保持；积压 ≠ 丢失的标签一致 |
| 13 | 关闭时仍有在飞接收段 | 已落地：`acquire_lease` + `close_append_admission` | 保持；关闭后残留必须计数 |
| 14 | 显示批次跨会话滞留 | 修复中：`DisplayLane::reset()` | 重连不得显示上一会话字节；关闭时环满不得让显示永久死掉 |
| 15 | 设备从不发 `\n` | 管线有 4 KiB 上限强制 flush（实现中） | 必须有上限，否则数据被永久扣住 |
| 16 | 看门狗误报（线程慢 ≠ 卡死） | 心跳实现中 | 阈值须宽松；写线程「慢」**不得**报警（存活 ≠ 有进展） |
| 17 | 关闭过程中器件消失（CLOSING×Fault） | 曾落 FAULT：`xcom_close` 轮询 CLOSED 直到超时 → 报「关闭失败」，而句柄已释放、实际已关 | 落 CLOSED；设备消失记入 error ring（§4.1） |
| 18 | 无会话时收到 Fault（CLOSED×Fault） | 曾发布 FAULT：镜像按「活动会话故障」进入重连窗 | 保持 CLOSED，仅记诊断；FAULT 严格表示活动会话故障（§4.2） |

## 三、显示层异常（与「显示是否正常」直接对应）

- **半行**：脚本必须收到整行；跨批续行不得重复打戳（本会话已修一处手工缺陷）。
- **管道关闭**：上限强制 flush 后，残缺帧按帧结束处理并显示。
- **字符集切换**：跨批保留的半个多字节字符不得回退为原始字节（否则视口出现乱码）。
- **时间戳**：仅新段首行一个戳；管道的最后一级，因此不污染落盘、不与用户脚本争所有权。
- **丢失可见性**：真实丢失（`overrun + save_rejected`）才报 DATA LOSS；纯显示积压不报，
  但必须在次级信息里以正确措辞呈现（当前仍叫 "drops"，属措辞缺陷）。
- **状态一致性**：显示的状态必须来自核心的发布视图 + 镜像的权威契约；任何「核心仍在 CLOSING
  而 UI 显示 FAULT」都是显示与实际不一致（F2）。

## 四、已决（原「待验证/待决」）

1. **`CLOSING × Fault` 落 `CLOSED`（已改，`kSerialEdges`）**。
   核实：`xcom_close`（`xcom_abi.cpp` 的 `do { ... } while` 轮询块）确实轮询
   `port_state == XCOM_PORT_CLOSED` 直到 `timeout_ms`。器件在关闭过程中消失时，句柄已由
   `kOwnerClose` 释放、关闭意图已达成；若落 `FAULT`，轮询永远等不到 `CLOSED` → 返回
   `TIMEOUT` → 用户看到「关闭失败」，而实际关闭已完成 → **显示与实际不一致**。
   故该边改为 `S_CLOSING --Fault--> S_CLOSED`，仍保留 `publish_first = true`：先发布
   `CLOSED`，否则 owner_close 阻塞期间轮询仍可能先超时。`serial_do_fault` 照旧把
   「设备消失」写入 error ring 并 emit `kFault` diag。
   **可达性**：正常关闭的 `kClose`/`kCloseDone` 在同一个 `serial_do_close` action 内原子完成，
   不暴露窗口；`CLOSING` 只在 **cancel-close 待派发窗口**（打开被取消 → `kCancel` 进 CLOSING →
   它提交的 Close 信号尚未被 Dispatcher 消费）对其它事件可见。该窗口内设备拔出即命中此格。
   **副作用**：该边不经过 `kCloseCommit`，故 generation 不在此推进、display 不在此 reset；
   下一次 `kOpenCommit` 会推进 generation 并 `reset_display_at_commit`，跨会话字节仍被丢弃。
2. **`CLOSED × Fault` 不发布 FAULT（已改：删除该边，仅记诊断）**。
   本仓库已在 F1 确立原则：失败从未建立会话 → 不发布 FAULT；FAULT 保留给**活动会话**故障。
   无会话时发布 FAULT 会让 Lua 镜像按「活动会话故障」进入 8 s 重连窗。已删除
   `{S_CLOSED, kFault, → S_FAULT}` 边；`serial_do_fault` 仍在 `state != S_FAULT` 时写 error ring
   + emit `kFault` diag，只是不再移动状态。
   核实依赖：全仓（含 `xcom_core/tests/`）没有任何地方依赖「CLOSED 收到 Fault 会转 FAULT」；
   镜像侧本就以 `enter_reconnecting` 的「必须已离开 OFFLINE」守卫兜底，删除该边只是让核心不再
   发布一个需要镜像兜底的假状态。
3. **`last_open_result` 不加尝试代（前提不成立，不改）**。
   §2 用例 7 的竞态经核实**不可达**，排除过程：
   - `Signal::OpenDone`（=6）/`Signal::CloseDone`（=7）虽在 `xcom_config.hpp` 定义，但全仓
     **从未作为信号提交**；OpenDone/CloseDone 只是 `serial_do_open`/`serial_do_close` 在同一
     SerialAo 线程内对 `serial_transition` 的同步调用，不存在「在途的陈旧 OpenDone」。
   - `serial_do_open` 在 `owner_open` 返回后**同线程、同 action** 立即读刚写入的
     `last_open_result`，不存在跨尝试的写入交错。
   - `queue_open` 以 `last_open_result == XCOM_ERR_BUSY` 拒绝第二次打开，且 state 非
     CLOSED/FAULT 也拒绝 → 任一时刻**至多一个尝试在途**；只有本次 owner 会清掉 BUSY，
     下一次尝试只能在本次结果被消费后才写入 BUSY，故不可能「旧结果满足新尝试」。
   异步 ABI（`xcom_open_async` + `xcom_take_open_result`）没有尝试身份，但调用方若在读取本次
   结果前发起新尝试，属调用方误用（BUSY 哨兵按设计被覆盖），不是核心竞态——ABI 已用 BUSY
   强制「单次在途」不变式。**结论：不为不可达的竞态增加状态。**
4. **`generation` 回绕不改（C++ 无小于比较；风险在 Lua 侧）**。
   核实「小于比较」的实际位置：C++ 侧全部是**相等比较**——`xcom_ao.cpp`（`send_user_action`
   的 `desc->generation != core->generation`）、`xcom_core.cpp`（SessionWriter 的 `j.gen == cur`）、
   `xcom_core.hpp`（`DisplayLane::drain_into` 的 `consumer_desc_.gen != current_generation` /
   `==`），**无任何 `<`**。相等比较在回绕下需恰好绕回同一值（2^32 次 open/close 提交）才误判，
   纯理论。真正的 `<` 比较只在 `xcom_lua/core/view_model.lua`（镜像，行 227/258/287/436），
   属本会话范围外（另有 agent 负责 xcom_lua）。
   且故障**不推进** generation（镜像注释亦确认），重连抖动本身不消耗 generation，只有
   open/close 提交推进。→ 本会话判定**不改**，交由 Lua 侧决定是否改为回绕安全比较；C++ 侧
   无需改动。

## 五、每格要求的测试

- **迁移矩阵**：逐格用例，重点是上表标 **L** 的格子与 §4 决议涉及的格子——每格必须断言最终状态与发布序列；
  遍历全部 30 格断言「无匹配边时不发布」（这是「非法事件不得改变状态」的通用不变量）。
  已落地于 `xcom_core/tests/serial_transition_test.cpp`（host，Win32-free）：遍历全部
  5×6=30 格断言 `SerialCtx::state` + `port_state` 是否发布 + owner 动作调用次数，并覆盖
  `open-cancel → CLOSING`、成功/失败 open、`CLOSED × Close` 无操作、fault 仅诊断等路径。
- **异常用例**：§2 每行一条，用现有注入缝（`xcom_test_inject_rx`、`xcom_test_inject_line_errors`）
  或在纯 Lua 侧模拟；§2 中标注「已落地/修复中」的格子应已有或即将有回归测试。
- **显示**：纯 Lua 断言积压与丢失的措辞分离、半行不调用脚本、时间戳只出现在新段首行。
- **无法本地验证的部分**：真实 MSVC 构建、真实 USB 桥行为、真实磁盘故障——列入任务 #11。
