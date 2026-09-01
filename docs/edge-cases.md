# XCOM 异常 / 边界场景审计（edge-cases）

> 生成：2026-08-31 ｜ 性质：**只读审计**，不修改任何产品源码
> 范围：`xcom_core/`、`xcom_client/`、`xcom_py/coact/`、`third_party/CSerialPort/` 均只读。
> 优先级定义：**P0** = 未处理且会导致崩溃/挂死/数据错误；**P1** = 语义错误/数据丢失；**P2** = 体验问题。
> 结论纵览：共 29 项。**P0：1 项**（热插拔/中途拔线故障完全未接线，且读线程在拔线后空转）。**P1：6 项**。**P2：5 项**。已健壮处理：17 项。

---

## 1. 串口生命周期

### 1.1 打开不存在的端口（如 COM99）

| 项 | 内容 |
| --- | --- |
| 期望 | 返回 `XCOM_ERR_IO`，进入 FAULT 状态，error ring 留详细 Win32/驱动消息 |
| 现状 | 已处理。`xcom_abi.cpp` `xcom_open` 现 FAULT/CLOSED 即返回 `XCOM_ERR_IO`（`xcom_abi.cpp:61-65,184-186`）；真实开失败在 `sink_owner_open` 中 `sp->open()` 失败 → `errors.push(cerr,1,msg)` + `port_state=FAULT`（`xcom_core.cpp:695-712`）。FakeDll 对未知端口同样 `XCOM_ERR_IO` + error ring（`fake_dll.py:143-145`）。COM99 fail-open 路径已存在且闭环。 |
| 测试覆盖 | ✅ FakeDll `_op_open` 未知端口回调（`fake_dll.py:143`）；e2e 对无硬件时开失败兜底（`tests/e2e_loopback.py:149-154`）。 |
| 缺的测试 | ⚠️ 真实 DLL 对真实 COM99 的端到端断言（当前 e2e 在无硬件时「graceful skip」，不是硬断言 FAULT + error msg 无 ASCII 损坏）。 |
| 风险 | 低。错误 message 可能含 locale/多字节，Python `_on_core_error` 用 `errors="replace"` 解码（`main_window.py:597`），不会崩。 |
| 优先级 | P2（已处理，仅缺断言） |

### 1.2 端口被占用（busy）

| 项 | 内容 |
| --- | --- |
| 期望 | 打开被拒，返回 IO 错误，error ring 记录，端口枚举的 `busy` 位反映占用 |
| 现状 | 部分。真实侧 `sp->open()` 在 `ERROR_ACCESS_DENIED` 时 `CSerialPort::getLastError()` 得 `ErrorAccessDenied`（`SerialPortWinBase.cpp:239`），经 `sink_owner_open` 进 error ring（`xcom_core.cpp:707`）。但 `xcom_list_ports` 把 `busy` 恒置 0（`xcom_core.cpp:1056`）——枚举不读 CSerialPort 的占用信息，UI 的 `(busy)` 标记永远不生效。FakeDll 有 busy 语义（`fake_dll.py:146-148,157-159`），但产品真实侧缺失。 |
| 测试覆盖 | ✅ FakeDll busy 路径（`fake_dll.py:146`）。 |
| 缺的测试 | ⚠️ 真实被占用端口的开失败断言；`busy` 位真实值。 |
| 风险 | 中。打开被正确拒绝，但 UI 无法预先提示占用。数据安全无虞（拒绝正确）。 |
| 优先级 | P2 |

### 1.3 无权限 / 驱动错误 → 错误码与 message 是否保留

| 项 | 内容 |
| --- | --- |
| 期望 | 打开失败时错误码与 message 保留到 error ring |
| 现状 | **已处理**。`sink_owner_open` 失败分支把 `getLastError()`/`getLastErrorMsg()` 存入 error ring（`xcom_core.cpp:697-710, source=1`），FakeDll 同理（`fake_dll.py:144,147`）。调用侧 `xcom_take_error` 逐条弹出（`xcom_abi.cpp:441-471`），`xcom_open` 返回值统一压成 `XCOM_ERR_IO`（`xcom_abi.cpp:64`）。 |
| 测试覆盖 | ✅ FakeDll error-ring 弹出；e2e 开失败兜底。 |
| 缺的测试 | ⚠️ 真实驱动错误码 → ring 内容的往返验证。 |
| 风险 | 低。语义正确。 |
| 优先级 | P2 |

### 1.4 热插拔 / 中途拔线 → SIG_FAULT（**已知 TODO**）

**这是全审计唯一的 P0。**

| 项 | 内容 |
| --- | --- |
| 期望 | 设备被拔出 → 进入 FAULT 状态 + error ring + SIG_FAULT，读写路径收束/报错，UI 提示并允许重开 |
| 现状 | **未处理（P0 遗漏）**。证据链：<br>1. XCOM 从未调用 `CSerialPort::connectHotPlugEvent()`——`xcom_core.cpp` 只 `connectReadEvent`（`xcom_core.cpp:692`），全程无 `connectHotPlugEvent`；CSerialPort 自身支持该接口（`SerialPort.cpp:188` / `SerialPortAsyncBase.cpp:121`），但 XCOM 未接线 = 拔线事件根本到不了 XCOM。<br>2. 即便想往 HSM 提 SIG_FAULT，`sink_submit_control` 的 `switch(signal)` 只路由 `SIG_OPEN/SIG_CLOSE/SIG_AUTOSEND/SIG_DIAG`，**对 `SIG_FAULT` 直接 `event_gc` 拒绝**（`xcom_core.cpp:586-589`）——`SIG_FAULT` 转发表于今日是不可达的死代码。<br>3. CSerialPort 读线程在拔线后**空转**：`readThreadFun` 里 `state = waitCommEventNative()`；拔线后 `WaitCommEvent` 失败/DBC 事件非 `EV_RXCHAR` → 返回 -1（`SerialPortWinBase.cpp:642,650,654`），落入空 `else {}`（`SerialPortAsyncBase.cpp:249-251`），既不退出也不报错，循环无限 spin。读回调从此不再触发，XCOM 的 `XcomReadListener::onReadEvent` 收不到新数据 → 永远停留在 `XCOM_PORT_OPEN`，无 FAULT。<br>4. 拔线后写入：`writeData` 有界超时（`setWriteTimeout`）+ `abortPendingWrite` 兜底（`xcom_core.cpp:720,784`），最终写线程 push `"serial write failed"` error（`xcom_core.cpp:833-835`），但**不改 port_state**。 |
| 后果 | UI 永久显示 OPEN、无法感知拔线；注入无法刷新端口列表状态；只能靠用户手动 Close；期间所有写都失败但状态仍为 OPEN。UX 与语义双重错误。 |
| 测试覆盖 | ❌ 无任何测试。 |
| 缺的测试 | 拔线模拟（注入驱动移除/读错误）→ 断言 FAULT + error ring + 读写拒绝。 |
| 优先级 | **P0**。 |
| 备注 | 修复会触碰 `xcom_core/`（产品）与 `third_party/CSerialPort/`（LGPL 补丁），详见「加固建议」。 |

### 1.5 打开过程中关闭（Opening → cancel）

| 项 | 内容 |
| --- | --- |
| 期望 | 打开进行中提关闭：要么等待 open 完成再 close，要么安全取消/拒绝 |
| 现状 | **部分**。`xcom_open` 阻塞到 OPEN/FAULT（最久 ~2s，`xcom_abi.cpp:179-189`）。期间 UI 状态机在 OPENING 时**允许** `intent_close`（`view_model.py:76`）。但 worker 是串行单命令线程：同一 worker 上 open 是阻塞调用，close intent 排在之后，实际会等 open 返回。核心侧：open 中再 open 被 BUSY 拒（`xcom_abi.cpp:156-158`）；无 open 中取消的专门路径（core 只在 open 完成后才接纳 CLOSE，`xcom_ao.cpp S_OPEN/SIG_CLOSE`）。 |
| 测试覆盖 | ⚠️ 状态机单测覆盖 OPENING→CLOSING 意图（`test_view_model.py`）；无 core 级 open-in-flight cancel。 |
| 缺的测试 | open 阻塞在途时 close intent 的最终一致（不弃句柄、无泄漏）。 |
| 风险 | 中低。不会挂死（open 有 2s 上限），但长开超时场景 UX 不佳。 |
| 优先级 | P2 |

### 1.6 关闭过程中打开 / 重复关闭（幂等？）

| 项 | 内容 |
| --- | --- |
| 期望 | 重复关闭幂等返回 OK；关闭中禁止新开 |
| 现状 | **已处理（幂等可验证）**。`xcom_close`：state==CLOSED 直接返回 OK（`xcom_abi.cpp:206-209`）；否则置 CLOSING → `SIG_CLOSE`（critical）→ 阻塞等 CLOSED 最久 2s（`xcom_abi.cpp:210-218`）。关闭中再开：`xcom_open` 检查 OPENING 返回 BUSY，但 **对 CLOSING 无显式检查**——关闭进行中再 open，走到 `port_state==OPENING?`否、`==OPEN?`否，于是会直接提交 SIG_OPEN 并开始等；由于 SerialAo 是单 owner，`SIG_CLOSE` 与 `SIG_OPEN` 在 Dispatcher 串行，最终按到达序执行，状态最终一致但返回语义含糊（可能等到 FAULT/CLOSED 而非 OK）。 |
| 测试覆盖 | ✅ FakeDll close 幂等（`fake_dll.py:155-164`）；⚠️ 无 core 级重复 close 断言。 |
| 缺的测试 | 关闭中 open 的确定性返回码。 |
| 风险 | 中。重复 close 安全；关闭中 open 结果不确定但不会 UAF（owner 串行）。 |
| 优先级 | P1（关闭中 open 的返回语义未定义） |

### 1.7 关闭后 xcom_send / xcom_set_auto_template → XCOM_ERR_NOT_OPEN？

| 项 | 内容 |
| --- | --- |
| 期望 | 非 OPEN 时 send 拒绝为 NOT_OPEN |
| 现状 | **已处理**。`xcom_send` 检查 `port_state != OPEN → XCOM_ERR_NOT_OPEN`（`xcom_abi.cpp:251-253`）。`xcom_set_auto_template` **不检查 OPEN**（`xcom_abi.cpp:319` 起只查 handle/interval/size）——这符合「打开前配置模板」的合理用法；但自动发送本身在非 OPEN 时不触发（`xcom_core.cpp:857-860` 定时器门 + `xcom_ao.hpp:154` HSM 门），互锁成立。 |
| 测试覆盖 | ✅ `test_core_worker.py:72-78` send-rejected-when-closed；✅ 自动发送「打开前禁止」设计（STATUS.md v1.2）。 |
| 缺的测试 | 关闭后 set_auto_template 仍可配置但不触发的端到端断言。 |
| 风险 | 低。 |
| 优先级 | P2 |

### 1.8 destroy 时端口仍 OPEN → 是否先 close？有界后台清理？

| 项 | 内容 |
| --- | --- |
| 期望 | `xcom_destroy` 在端口残留 OPEN 时安全关闭，不泄漏、不阻塞 UI |
| 现状 | **已处理，但注释与实现不符**。`xcom_handle_destroy` → `state->shutdown()`（`xcom_core.cpp:1010-1020`），`shutdown()` 同步做：停自动发送 timer → `runtime.stop()`（join Dispatcher）→ `abortPendingWrite` → writer `stop_and_join` + drain → `close_admission` + `CSerialPort::close()`（join 读线程）+ delete（`xcom_core.cpp:484-534`）。**是同步阻塞调用，没有后台线程**——`xcom.h:250` 注释写「bounded background cleanup」，但实际 `xcom_destroy` 全程阻塞调用线程（UI 经由 worker 调用，故 GUI 不卡，但 worker 阻塞、app 退出被拖住）。 |
| 测试覆盖 | ✅ e2e close→destroy（`tests/e2e_loopback.py:220-224`）。 |
| 缺的测试 | 端口残留 OPEN 直接 destroy 的用例（当前 close 总先行）；destroy 阻塞时长的门禁。 |
| 风险 | 中。功能正确但同步阻塞与文档声明不符；退出可能被写 join/close 拖住（有 ±2s 上限）。 |
| 优先级 | P1（文档契约与实现不符 + worker 阻塞窗口） |

### 1.9 close 超时（write 在途 / 写线程 join）→ XCOM_ERR_TIMEOUT 后状态一致性

| 项 | 内容 |
| --- | --- |
| 期望 | close 超时返回 TIMEOUT，且线程资源不被悬空、句柄不被半释放 |
| 现状 | **已处理，有残留风险**。`xcom_close` 2s 轮询后返回 `XCOM_ERR_TIMEOUT`（`xcom_abi.cpp:212-219`）。写线程 join 是**有界**的：`abortPendingWrite`→`stop_and_join`（`xcom_core.cpp:782-787`），依赖 `CancelIoEx` 使在途 `writeData` 快速返回（`SerialPortWinBase.cpp:543-550`；`writeData` 的 `GetOverlappedResult(...,FALSE)` 读到 `ERROR_OPERATION_ABORTED` 即返回）。**残留风险**：若 `writeData` 卡在 `m_mutexWrite` 上（另一个线程正持写锁）或 abort 竞态错过，`join` 可能突破 2s；`xcom_close` 超时返回 TIMEOUT 后 `serial_port` 已在 `sink_owner_close` 内被 `delete`（`xcom_core.cpp:808-809`），若调用方在 TIMEOUT 后复用它（update/open）会踩已删指针——端口状态此时实际是 CLOSED，后续 API 会正确拒绝，但**「TIMEOUT 但底层已 close」语义不清**。 |
| 测试覆盖 | ❌ 无 close 超时 / 慢写线程中断的测试。 |
| 缺的测试 | 写线程在途时 close 的 TIMEOUT → 资源全部回收 → 状态接地为 CLOSED；abort 竞态窗口。 |
| 风险 | 高。若 abort 竞态失败，join 无上限硬阻塞（写线程永不退出 → `xcom_destroy`/close 挂死）。写侧有 `setWriteTimeout` 兜底但 abort 与超时重叠窗口未验证。 |
| 优先级 | **P1** |

---

## 2. 数据面

### 2.1 单回调 >4096B → 拆块；池/ring 满 → 精确计数不静默截断

| 项 | 内容 |
| --- | --- |
| 期望 | >4096B 拆成多块；池/ring 满时精确计入 exhausted/oversize |
| 现状 | **已处理**。`readData` 循环拆块（`xcom_core.cpp:142-154`）；`rx_ingress` 内再按 kRxBlockBytes 拆（`xcom_core.cpp:931-953`）；剩余字节精确计 `rx_callback_oversize_bytes`+`rx_pool_exhausted_bytes`（`xcom_core.cpp:954-959`），`push_ready` 失败释放 block（`xcom_core.cpp:946-949`）。 |
| 测试覆盖 | ✅ 5 块静态 RxKick smoke（STATUS.md P0）；⚠️ 无 >64 池满的精确计数断言。 |
| 缺的测试 | 注入 >64×4096 触发池满 → exhausted_bytes 恰等于被拒字节数；ready ring 满路径。 |
| 优先级 | P1（池满路径无测试，计数正确性未锁定） |

### 2.2 RxBlockPool / TxBlockPool / DisplayBatch 耗尽 → 各自计数与拒绝语义

| 项 | 内容 |
| --- | --- |
| 期望 | 三池分别计数：`rx_pool_exhausted_bytes` / `tx_rejected` / `ui_trimmed_bytes` |
| 现状 | **已处理**。Rx 池满计 exhausted（`xcom_core.cpp:954-959`）；Tx 池满 `try_alloc`null → `tx_rejected` + `XCOM_ERR_FULL`（`xcom_abi.cpp:258-262`，写线程 ring 满亦然 `xcom_ao.hpp:315-321`）；Display 池满 `try_acquire`false → `ui_trimmed_bytes`（`xcom_ao.hpp:53-56`）。三池语义互不混淆（high-perf §8.6）。 |
| 测试覆盖 | ⚠️ 无专门耗尽测试。 |
| 缺的测试 | 三池各自满的计数与拒绝断言。 |
| 优先级 | P1 |

### 2.3 UTF-8 非法 / 跨块残字节 → U+FFFD + 计数

| 项 | 内容 |
| --- | --- |
| 期望 | 跨块残字节经 carry 续接；非法序列输出 U+FFFD |
| 现状 | **未处理（设计有、实现缺）**。`CoreCtx` 有 `utf8_carry[4]/utf8_carry_len`（`xcom_core.hpp:482-483`），但 `rx_format_block`（`xcom_ao.hpp:41-91`）**从不使用 carry**——文本视图是把原始字节逐字节直写（`xcom_ao.hpp:71-75`），HEX 视图逐字节 hex（`xcom_ao.hpp:59-69`）。**没有任何 UTF-8 解码/U+FFFD/残字节处理的实际逻辑**。上层 `ReceiveView.append_batch` 才 `decode("utf-8","replace")`（`receive_view.py:61`）兜底替换，但那是在 Python/Qt 层，C++ DisplayBatch 里跨块截断的中文会以 `�`（U+FFFD by replacement）呈现——语义上由 Python 层救了，但 `rx_callback_oversize/display` 无 UTF-8 专属计数，且跨块截断的半个多字节字符在 Qt 层以替换符呈现（可接受但非设计所述的「C++ carry」）。 |
| 测试覆盖 | ✅ `receive_view` U+FFFD 替换路径（`receive_view.py:61`）；❌ C++ carry/计数缺失。 |
| 缺的测试 | 跨块 UTF-8 中间字节的显示正确性（现依赖 Python replacement）。 |
| 风险 | 中。显示不崩（Python 兜底），但**设计契约「C++ carry + U+FFFD + 计数」未兑现**；`timestamp` 同理（见 2.5/1.4 关联）。 |
| 优先级 | P1（设计契约未兑现，虽被 Python 兜底） |

### 2.4 HEX 显示 / HEX 发送边界

| 项 | 内容 |
| --- | --- |
| 期望 | v1.1 后 HEX 由 Python 预编码（`bytes.fromhex`），C++ 不解析；空/奇数 nibble/超长/空白均被 Python 拦截 |
| 现状 | **已处理**。`build_send_payload` 对 HEX：去空白 → `bytes.fromhex`（奇数/非法抛 `ValueError` → 返回 err，不发送）（`send_panel.py:35-42`）；空 → `b""`（`send_panel.py:38`）。C++ `xcom_send` 视 flags 为 opaque（`xcom_abi.cpp:235,315,323` 注释），不解析 HEX。超长由 C++ `size>kTxBlockBytes → XCOM_ERR_FULL` 拦截（`xcom_abi.cpp:245-249`）。 |
| 测试覆盖 | ✅ `build_send_payload` 单测（`test_widgets.py`）；✅ 超长 FULL 语义。 |
| 缺的测试 | 空/纯空白 HEX、>4KB HEX 的端到端提示链路（不发送 + tooltip 提示，`send_panel.py:154-156`）。 |
| 风险 | 低。 |
| 优先级 | P2 |

### 2.5 显示暂停时持续接收 → rx_bytes 增长、display_paused_bytes、RxBlock 归还

| 项 | 内容 |
| --- | --- |
| 期望 | 暂停时 rx_bytes 继续涨、paused 计数涨、RxBlock 立即归还（不缓存） |
| 现状 | **已处理**。`rx_format_block` pause 时 `display_paused_bytes += len` 并直接 return，RxBlock 由上层 `rx_kick_action` 归还（`xcom_ao.hpp:45-49,111`）。 |
| 测试覆盖 | ✅ e2e pause 断言 d5/d6（`e2e_loopback.py:186-216`）；恢复不回放。 |
| 缺的测试 | 无（覆盖良好）。 |
| 优先级 | ✅（无风险） |

---

## 3. 发送

### 3.1 写线程慢/超时 → 有界超时 + CancelIoEx + close 时 abort+join

| 项 | 内容 |
| --- | --- |
| 期望 | 写阻塞不冻结 Dispatcher；close 时 abort+join 有界 |
| 现状 | **已处理（主要路径）**。写移到 SessionWriter 线程（`xcom_core.cpp:197-356`）；`setWriteTimeout` 由 baud 推导有界（`xcom_core.cpp:720,738-754`）；`writeData` 有界等 + `CancelIoEx`（`README.xcom.md` Patch 1 / `SerialPortWinBase.cpp:416-...`）；close `abortPendingWrite`→`stop_and_join`（`xcom_core.cpp:782-787`）。见 1.9 的 abort 竞态残留。 |
| 测试覆盖 | ⚠️ 无真实慢写/死 peer 测试（等硬件）；白盒 gate 通过。 |
| 缺的测试 | 慢写中断 + 写线程 join 超时上限。 |
| 优先级 | P1（与 1.9 同一残留） |

### 3.2 发送到已关闭端口 / 关闭中

| 项 | 内容 |
| --- | --- |
| 期望 | 非 OPEN 拒 NOT_OPEN；关闭中在途块由 generation/state 拒绝 |
| 现状 | **已处理**。`xcom_send` NOT_OPEN 门（`xcom_abi.cpp:251`）；写入 worker 二次校验 generation+OPEN（`xcom_core.cpp:321-323`）；`serial_do_write` stale（generation 不符/非 OPEN）→ release block 不写（`xcom_ao.hpp:305-313`）。 |
| 测试覆盖 | ⚠️ 无关闭中 send 竞态断言。 |
| 缺的测试 | close 与 send 并发 → block 不泄漏、不写入。 |
| 优先级 | P1（stale-release 正确性无并发测试） |

### 3.3 自动发送开前 / 关闭时 → 互锁

| 项 | 内容 |
| --- | --- |
| 期望 | 非 OPEN 不自动发送；关闭时立即停 |
| 现状 | **已处理**。`autosend_set_impl` 关闭时取消 timer（`xcom_core.cpp:771`）；`send_autosend_action` 非 OPEN 清 gate 不写（`xcom_ao.hpp:154-157`）；timer 回调也查 OPEN+size（`xcom_core.cpp:857-863`）；UI `_on_close_clicked` 停自动发送（`main_window.py:438`）。 |
| 测试覆盖 | ✅ 「打开前禁止自动发送」v1.2（STATUS.md）；✅ 自动发送 coalesce（`test_core_worker.py:154-168`）。 |
| 缺的测试 | 无（覆盖良好）。 |
| 优先级 | ✅（无风险） |

### 3.4 自动发送模板大 / 空 / 非法 → set_auto_template 校验

| 项 | 内容 |
| --- | --- |
| 期望 | 超长拒 FULL；空则禁用；非法 HEX 由 Python 拦截 |
| 现状 | **已处理**。`xcom_set_auto_template` `size>kTxBlockBytes → XCOM_ERR_FULL`（`xcom_abi.cpp:333-337`）；`interval_ms==0` 禁用（`xcom_abi.cpp:340,341`）；模板不校验 OPEN（见 1.7）；Python `_set_autosend_enabled` 非法 HEX 阻止（`main_window.py:537-542`）。 |
| 测试覆盖 | ✅ 自动发送大模板/非法链路的 Python 侧（`main_window.py:539`）。 |
| 缺的测试 | >4KB 模板 FULL + AUTO size 超 uint16_t（`autosend_size` 是 uint32 存 kTxBlockBytes 上限，安全）。 |
| 优先级 | P2 |

---

## 4. ABI / 边界

### 4.1 NULL handle / NULL data / struct_size 校验 → 全部导出函数

| 项 | 内容 |
| --- | --- |
| 期望 | 每个导出函数对 NULL/坏 struct_size 返回安全错误，不崩 |
| 现状 | **已处理（逐个核对）**：<br>- `xcom_create`：options NULL 允许，struct_size/flags 校验（`xcom_abi.cpp:97-104`）。<br>- `xcom_open`：handle PARAM、`port_name_from_config` 校验 cfg/cap/struct_size/port（`xcom_abi.cpp:127-136,42-56`）。<br>- `xcom_close`：handle PARAM（`xcom_abi.cpp:202-204`）。<br>- `xcom_send`：h/data PARAM（`xcom_abi.cpp:239-241`）。<br>- `xcom_set_options`：h/options/struct_size（`xcom_abi.cpp:289-293`）。<br>- `xcom_set_auto_template`：h PARAM、interval+data 约束（`xcom_abi.cpp:327-331`）。<br>- `xcom_drain_display`：h/output/written PARAM（`xcom_abi.cpp:368-370`）。<br>- `xcom_get_snapshot`：h/output/struct_size（`xcom_abi.cpp:403-408`）。<br>- `xcom_take_error`：h/output/struct_size（`xcom_abi.cpp:446-450`）。<br>- `xcom_test_inject_rx`：h/data PARAM（`xcom_abi.cpp:479-481`）。<br>- `xcom_destroy`：accept NULL/废 handle（`xcom_abi.cpp:495-505`）。<br>全部 body 包 `try/catch(...)`，异常不外泄（`xcom_abi.cpp` 各函数 + 文件头注释）。 |
| 测试覆盖 | ✅ ctypes 结构 size 断言（`validate_layout`, `core_wrapper.py:207-223`）；常量对齐（`test_core_wrapper.py:16-21`）。 |
| 缺的测试 | 逐导出函数的 NULL/坏 handle 混沌调用（大部分未逐一单测）。 |
| 优先级 | P2（逻辑已齐，缺回归） |

### 4.2 ctypes 加载失败 / 缺符号 → 清晰错误

| 项 | 内容 |
| --- | --- |
| 期望 | DLL 缺失/符号缺失给出可读错误，UI 提示 |
| 现状 | **已处理**。`XcomCoreError` 覆盖 DLL 加载（`core_wrapper.py:295-298`）与缺符号（`core_wrapper.py:333-338`）；`resolve_dll_path` 支持 `XCOM_CORE_DLL` 覆盖（`core_wrapper.py:226-228`）；worker `create_handle` 捕获 XcomCoreError → `error_occurred` → UI 状态栏（`core_worker.py:228-234`）。 |
| 测试覆盖 | ✅ ✓。 |
| 缺的测试 | 无（清晰）。 |
| 优先级 | ✅ |

### 4.3 double destroy / 未 create 就 open

| 项 | 内容 |
| --- | --- |
| 期望 | destroy 幂等；未 create 的 handle 操作返回 PARAM |
| 现状 | **已处理**。`xcom_destroy` 对 NULL/已删/坏 magic 都安全返回（`xcom_core.cpp:1010-1020`，`xcom_handle_valid` 校验 magic+state 后返回 false，`xcom_core.cpp:1030-1035`）；未 create 时 `xcom_handle_valid` false → 各 API 返回 PARAM。handle magic 0x58434F4D 校验。 |
| 测试覆盖 | ✅ FakeDll double-destroy 幂等（`fake_dll.py:131-134`）。 |
| 缺的测试 | 无（健壮）。 |
| 优先级 | ✅ |

### 4.4 事件池耗尽 / staging 满 → 拒绝计数、RxKick ReservedNormal 不拒

| 项 | 内容 |
| --- | --- |
| 期望 | 控制事件池满拒绝并计数；RxKick 用 ReservedNormal 预留 1 槽所以普通 Normal 满仍能投递 |
| 现状 | **已处理**。`ctl_pool.alloc_with_margin` 空 → 返回 false（`xcom_core.cpp:563-565`），send 路径计 `tx_rejected`（`xcom_abi.cpp:271-274`）；`submit_write` 池空 → false → `tx_rejected`（`xcom_abi.cpp:599-609`，调用方 `xcom_abi.cpp:272-275`）。RxKick 以 `StagingAdmission::ReservedNormal` 提交（`xcom_core.cpp:551-553`），coact `ReservationClaim::NormalReserved` 预留 1 槽（`staging.hpp:513-516`），普通 Normal 满（63）时 RxKick 仍可进（config `kNormalReservedCapacity=1`，`xcom_config.hpp:23`）。 |
| 测试覆盖 | ✅ coact staging 18 例覆盖 claim 回滚/释放（STATUS.md「4 类 coact 测试」）；◀ 缺 XCOM 侧「普通 Normal 63+RxKick」触发断言。 |
| 缺的测试 | XCOM 侧事件池/CtlPool 多次塞满 → 拒绝路径 + 不误报 fatal。 |
| 优先级 | P1（reservation 正确性仅靠 coact 层测试，XCOM 集成未验证） |

---

## 5. UI / 客户端

### 5.1 无端口可选时点打开

| 项 | 内容 |
| --- | --- |
| 期望 | 无选中端口时提示不发送 |
| 现状 | **已处理**。`_on_open_clicked` 空端口 → `"no port selected"`（`main_window.py:409-412`）；空列表 → `"no COM ports detected"`（`main_window.py:587-588`）。 |
| 测试覆盖 | ✅ `test_main_window.py`。 |
| 优先级 | ✅ |

### 5.2 send payload 非法（HEX 奇数/超限）→ 提示不发送

| 项 | 内容 |
| --- | --- |
| 期望 | 非法 HEX 提示、不发送 |
| 现状 | **已处理**。`build_send_payload` 校验 → `send_edit.setToolTip(err)`（`send_panel.py:153-156,170-173`）；>4KB 由 core FULL 拒。注意：HEX 合法但超 4KB 时工具提示为空、core 返回 FULL 只写 worker_message（`core_worker.py:304-305`），UI 无前置提示（UX 小缺口）。 |
| 测试覆盖 | ✅ `build_send_payload` 单测（`test_widgets.py`）。 |
| 缺的测试 | >4KB 前置提示（P2 体验）。 |
| 优先级 | P2 |

### 5.3 TOML 损坏 / 值域越界 → 回退安全默认

| 项 | 内容 |
| --- | --- |
| 期望 | TOML 解析失败/越界回退默认 |
| 现状 | **已处理**。`load` 捕获 `OSError/TOMLDecodeError` → 全默认（`settings.py:178-180`）；`parse_toml` 用 `_clamp_choice`/`_clamp_int` 逐值域校验（`settings.py:102-111,133-164`）。 |
| 测试覆盖 | ✅ `test_settings.py`。 |
| 缺的测试 | 无（覆盖良好）。 |
| 优先级 | ✅ |

### 5.4 保存路径不可写 / 磁盘满 → 后台保存失败提示不阻塞

| 项 | 内容 |
| --- | --- |
| 期望 | 后台写失败提示，不阻塞 GUI |
| 现状 | **已处理**。`_do_save_log` 捕获 OSError → `save_done(False,...)`（`core_worker.py:343-353`）；`_write_autosave` 有 retry + 失败 `autosave_done(False,"...")`（`core_worker.py:370-379`）；都在 worker 线程（不阻塞 GUI）。 |
| 测试覆盖 | ✅ worker 单测。 |
| 缺的测试 | 磁盘满模拟。 |
| 优先级 | P2 |

### 5.5 closeEvent 时 worker 未退出 / app 退出顺序

| 项 | 内容 |
| --- | --- |
| 期望 | 关窗非阻塞：停 timer、提 close+quit intent、不 wait |
| 现状 | **已处理**。`closeEvent` 非阻塞（`main_window.py:626-643`）：停 timer → `request_close(500)` + `request_stop()` → accept；`_on_worker_finished` 在 worker 收尾后 `app.quit()`（`main_window.py:617-624`）。worker `run()` 退出后 best-effort close(500)+destroy（`core_worker.py:254-263`）。 |
| 测试覆盖 | ✅ worker 生命周期单测。 |
| 缺的测试 | 关窗瞬间 worker 阻塞在 open/close 时 app 是否悬挂（5s+）；QT 定时器在 thread 销毁竞态。 |
| 优先级 | P2（退出有 500ms close + worker 阻塞的窗口风险） |

---

## 6. CSerialPort 补丁 + 加固建议

### 6.1 close() 后不再开始新回调（barrier）→ in_callback 确认

| 项 | 内容 |
| --- | --- |
| 期望 | close 后无新回调；`in_callback==0` acquire 确认 |
| 现状 | **已处理**。关闭先 `callback_admission=0`（`xcom_core.cpp:774`），回调先 `in_callback++` 再 acquire 查 admission，被拒则递减（`xcom_core.cpp:125-129`）；close 后 acquire 确认 `in_callback==0`，非零则 push 契约故障（`xcom_core.cpp:801-807`）。 |
| 测试覆盖 | ⚠️ 无真实 close-vs-callback 并发测试（等硬件/gate）。 |
| 缺的测试 | close 与回调并发 → 无新回调开始、in_callback 后落地 0。 |
| 优先级 | P1 |

### 6.2 写超时后的 CancelIoEx 行为 / 端口状态

| 项 | 内容 |
| --- | --- |
| 期望 | 写超时弱化/打断在途写，端口状态可恢复 |
| 现状 | **已处理（写侧）**。`writeData` 超时 → `CancelIoEx` 放弃 + 返回失败（`SerialPortWinBase.cpp:416-...`，README Patch 1）；`abortPendingWrite` 跨线程中断（`SerialPortWinBase.cpp:543-550`）。**但端口状态侧未联动**：写失败只 push error ring（`xcom_core.cpp:833-835`），**不触发 FAULT**——与 1.4 同根因（拔线写失败不会让端口进入 FAULT）。 |
| 测试覆盖 | ⚠️ 无。 |
| 缺的测试 | 写失败 → 是否应上 FAULT 的语义决策 + 测试。 |
| 优先级 | P1（与 1.4 关联） |

### 6.3 加固建议（按优先级排序）

> 标注：**产品** = 触碰 `xcom_core/`（改 xcom_core.cpp/hpp/abi/ao）；**LGPL** = 触碰 `third_party/CSerialPort/`；**coact** = 触碰 `xcom_py/coact/`；**客户端** = 触碰 `xcom_client/`。

**P0（必修）**

1. **接线热插拔故障（1.4 / 6.2）**
   - 在 `sink_owner_open` 调用 `sp->connectHotPlugEvent(...)`，拔线监听回调内提 `SIG_FAULT`。
   - 同时修复 `sink_submit_control` 的 `switch`，为 `SIG_FAULT`（及 `SIG_WRITE`）增加路由（`xcom_core.cpp:586-589`），否则 FAULT 转发表死。
   - 修 CSerialPort 读线程拔线空转（`SerialPortAsyncBase.cpp:249-251` 空 `else`）：`state<0` 时应上抛故障而非静默循环。
   - 触碰：**产品** + **LGPL**（读线程）+ 可能 **coact**（无需，仅用现有 staging）。
   - 这是唯一会「挂死/状态永久错误」的遗留。

**P1（语义/数据正确）**

2. **close 超时窗口 + abort 竞态（1.9/3.1）**：验证 `writeData` 卡 `m_mutexWrite` 或 abort 错过时 join 是否仍受 2s 上限；为 worker join 增加硬超时保护，避免 `xcom_destroy`/close 无上限阻塞。触碰 **产品**。
3. **关闭中 open 语义定案（1.6）**：`xcom_open` 显式拒绝 CLOSING（BUSY），并补测试。触碰 **产品**。
4. **UTF-8 carry + U+FFFD + 时间戳在 C++ 兑现（2.3）**：`rx_format_block` 接入 `utf8_carry`，否则设计契约悬空（现只靠 Python replacement 兜底）。触碰 **产品**。
5. **三池耗尽与事件池耗尽测试 + 精确计数（2.1/2.2/4.4）**：补 >64 块池满、三池各自满、CtlPool 满的拒绝/计数断言。触碰 **产品测试**（不改产品如已正确）。
6. **close 与 send/receive 并发闭环测试（3.2/6.1）**：锁死 block 不泄漏、in_callback=0、无新回调。触碰 **产品测试**。

**P2（体验 / 文档对齐）**

7. **`xcom_destroy` 同步阻塞 vs 文档「background cleanup」对齐（1.8）**：改注释，或后台化清理（后者触碰 **产品**，改动面大，先对齐文档）。
8. **port `busy` 位真实填充（1.2）**：`xcom_list_ports` 读占用信息。触碰 **产品**。
9. **>4KB HEX 发送前置 UI 提示（5.2）**。触碰 **客户端**。
10. **残留 OPEN 直接 destroy 测试 + destroy 时长门禁（5.5/1.8）**。触碰 **测试**。

### 6.4 报告：最该先修的 5 条

1. **【P0】热插拔故障完全未接线** —— 拔线后读线程空转、无 FAULT、UI 永久 OPEN（1.4/6.2）。三处配合：`connectHotPlugEvent` + `sink_submit_control` 增加 `SIG_FAULT` 路由 + CSerialPort 读线程 `state<0` 上抛。此条是唯一会造成「挂死/状态永久错误」的缺陷，且跨 LGPL 边界，需优先规划。
2. **【P1】close 写线程 join 无硬超时上限** —— 若 `abortPendingWrite` 竞态错过或写锁被占，`stop_and_join` 可无上限阻塞，`xcom_destroy`/close 挂死（1.9/3.1）。
3. **【P1】关闭中 open 返回语义未定义** —— `xcom_open` 对 CLOSING 无显式门（1.6），可能等至 FAULT/CLOSED 返回而非 BUSY，需定案。
4. **【P1】UTF-8 carry / U+FFFD 在 C++ 层未兑现** —— 设计中声明的跨块解码与计数悬空，仅靠 Python replacement 兜底（2.3）。
5. **【P1】池满/事件池满的精确计数无测试锁定** —— >64 块池满、三池各自满、CtlPool 满的拒绝路径正确性未验证（2.1/2.2/4.4）。

---

> **附录：已覆盖/缺失测试清单已折叠避免文档膨胀，详见 STATUS.md v1.2。**