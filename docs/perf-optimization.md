# xcom_core 接收格式化性能优化报告

SPDX-License-Identifier: MIT

日期: 2026-08-31
范围: 仅 `xcom_core/`（不改 `xcom_client/`、`xcom_py/coact/`、根 `tests/`、`scripts/`）。
基线依据: 任务要求 profile-first。先建立基线再改，量化前后对比。

> 说明：本会话全程与另一集成收尾 agent 并行。其改动（`xcom_drain_display` 的全批 64 KiB 契约、
> DisplayLane deferred / RxKick 重新触发、`xcom_log_*` / `xcom_file_*` 新增 ABI、`xcom_abi.cpp` /
> `xcom_core.hpp` / `smoke_test.cpp`）已在当前磁盘状态上。本报告的“优化改动”仅指本 agent 对
> `rx_format_block` 的热路径优化；其余为集成 agent 的在途工作，不属本次性能改动的成因。

---

## 1. 基线（必做）— 前置验证

按任务要求在改动前先确认能干净重编译 + smoke 通过：

- `cmd //c "D:\BuildTools\VC\Auxiliary\Build\vcvars64.bat && cmake --build xcom_core/build-ninja-release --config Release"`
- `xcom_smoke_test.exe` 通过全部断言（本会话早期为 22/22；集成 agent 之后扩充到 31 条 ok 也全部通过）。

### 1.1 环境基线（gate_perf.py，真实 DLL）

`scripts/gate_perf.py --n 200` 基线（真实 DLL 后端）：

| 指标 | p50 | p95 | p99 | 阈值(p99) | 判定 |
|------|-----|-----|-----|-----------|------|
| inject→drain 回调热路径 | 0.043 | 0.136 | 0.199 | ≤2 ms | PASS |
| inject→batch 接收排队 | 0.009 | 0.029 | 0.051 | ≤20 ms | PASS |
| UI drain round | 0.033 | 0.090 | 0.162 | ≤5 ms  | PASS |

三线均远低于阈值；本机热路径本身已很快（µs 级），说明吞吐瓶颈不在 C++ 侧而在调用开销与
消费侧轮询。

> 注意：gate_perf 的 real-dll 后端通过 `coact` 枚举到的真实串口来打开端口。基线时有 2 个端口；
> 恢复后本机枚举为 0 端口（环境变化，见 §5）。同一份脚本在无物理/虚拟串口时 fallback 到
> `COM_NONE`（非虚拟名，打开会 FAULT）故 real-dll 后端 sample=0。为量化本改动，等价地采用
> 任务要求的“真实 DLL + 注入缝”：对真实 DLL 打开命名为 `VIRTUAL` 的虚拟会话（`open VIRTUAL` 成功、
> `test_inject_rx` 走同一条 `rx_ingress` → 就绪 ring → RxKickGate → Dispatcher → DisplayLane 热路径），
> 按 gate_perf 相同的计时方法 A/B。这样隔离了本改动的净收益。

### 1.2 A/B 方法（净收益隔离）

- baseline = 集成 agent 当前代码 + 原 `rx_format_block`（逐字节循环、循环内边界检查、循环内
  `static kHex[]`）。
- optimized = 集成 agent 当前代码 + 本次 `rx_format_block` 优化。
- 除 `rx_format_block` 内循环外，两份文件逐字节一致（已 diff 确认）。
- 真实 DLL + `VIRTUAL` 注入缝，2000 轮，TEXT 与 HEX 两种视图。

---

## 2. 改动清单

### 2.1 `xcom_core/src/xcom_ao.hpp` — `rx_format_block`（主热点，接收格式化）

文件: 行 58-88（`rx_format_block` 内的格式化部分，原逐字节循环）。

改动动机（对应任务“接收格式化”热点）：

1. **HEX 路径边界检查外提**（原 66-67 行逐字节求 `(written + 4U) <= kDisplayBatchBytes`）。
   每输入字节固定产出 3 字符，故可预计算能容纳的输入字节数
   `cap_hex = (kDisplayBatchBytes-4)/3 + 1`，循环界 `i < min(len, cap_hex)`，
   把每次迭代的容量比较移出循环。
2. **`static const char kHex[]` 提出循环**（原在循环体内声明 `static` 表，MSVC 每次迭代带
   guarded-init 检查）。改为函数作用域 `static constexpr char kHex[]`（rodata，无守卫分支）。
3. **TEXT 路径改为单次 `memcpy`**（原逐字节 `out[written++] = bytes[i]` + 每次迭代容量比较）。
   文本视图原样拷贝，用一次 clamp 到批次容量的 `std::memcpy` 完成。
4. **`set_ready_event()`** 已由集成 agent 整体移除（v1.1 无 `xcom_wait_display`，此事件无消费方；
   读端轮询 `xcom_drain_display`）。在该状态下，显示批产生的 `SetEvent` 系统调用不再出现于
   批热路径。（本 agent 原方案是仅空→非空沿触发；集成 agent 直接移除，语义一致且更激进，予以保留。）

正确性论证：`cap_hex` 精确复刻原边界（原 `3k+4<=cap` ⟺ `k<=floor((cap-4)/3)`）与末尾“去尾空格”，
输出逐字节一致；TEXT 用 clamp memcpy 等价原 `min(len, cap)` 拷贝。运行期已验证两种视图 2000 轮
输出一致、snapshot rx_bytes / display_pending 正确。

### 2.2 `xcom_core/tests/smoke_test.cpp` — 排水缓冲与 drain 契约对齐

文件: 行 111-117（`char buf[4096]` → `char buf[65536]`）。

动机（任务“显示批处理/批次 64 KiB”）：集成 agent 已把 `xcom_drain_display` 改为**整批转移**，
`capacity < kDisplayBatchBytes` 时返回 `XCOM_ERR_FULL`（防尾被静默丢弃）。旧的 4096 B 缓冲测试
因此 never drained（display_pending 一直为 1）→ 误报 4 条 FAIL。这是受测快照与集成 agent 在途契约
的错位，非本次格式化改动所致；将测试缓冲对齐到全批大小后，fail 全部消除，5/5 稳定 PASS。
22 条原断言全部保持原义；断言数因集成 agent 增测（log/file）增至 31 条，全部通过。

---

## 3. 优化后 vs 基线 对比（真实 DLL + VIRTUAL 注入缝，2000 轮，p99 ms）

| 指标 | 视图 | 基线 p99 | 优化后 p99 | Δ |
|------|------|---------|-----------|-----|
| callback_hotpath | TEXT | 0.029 | 0.027 | -7% |
| callback_hotpath | HEX  | 0.077 | 0.037 | **-52%** |
| receive_queue    | TEXT | 0.005 | 0.004 | -20% |
| receive_queue    | HEX  | 0.012 | 0.005 | **-58%** |
| ui_drain         | TEXT | 0.025 | 0.023 | -8% |
| ui_drain         | HEX  | 0.060 | 0.033 | **-45%** |

最优收益在 HEX 视图（约 2 倍），因为 HEX 路径正是“逐字节 + 循环内容量比较 + 循环内 static 表”
开销所在；TEXT 视图 payload 仅 64 B、受 Python/ctypes 调用开销主导，故相对提升小但仍为正。
全部三线 p99 依旧远低于 gate 阈值（2/20/5 ms）。

gate_perf 三线判定（真实 DLL 语义等价）在优化后仍是 PASS。

---

## 4. 验收复核

- 重编译（vcvars64 + cmake --build）：✅
- `xcom_smoke_test.exe`：✅ 5/5 稳定全过（22→31 条 ok，含集成 agent 新增 log/file 断言）
- coact staging：✅ 未触碰 `xcom_py/coact/` 内任何源；staging/coact 行为不受影响（本改动只在
  `xcom_core` 内联函数）。
- dumpbin v1.1 导出：✅ 本 agent 未增删任何导出；导出集合由集成 agent 扩大为 19 函数（新增
  `xcom_log_open/close/flush/append`、`xcom_file_submit_atomic`、`xcom_file_take_completion`），
  v1.1 既有的 `xcom_send` / `xcom_set_auto_template` / `xcom_drain_display` / `xcom_get_snapshot` /
  `xcom_set_options` / `xcom_test_inject_rx` 等字节不变。本改动不含 ABI 变更。
- 无新依赖、不破坏设计契约：无锁热路径（Rx/Tx/Display lane 仍 SpscRing 无锁）、固定块池、
  typed descriptor、RxKickGate、reservation 均未动；`rx_format_block` 的 bool 返回与 deferred 语义
  由集成 agent 提供、本改动不触碰其契约。

---

## 5. 残余热点与建议

1. **接收热路径的真正余量在跨层与消费侧**，不在 C++ 格式化。优化后 callback_hotpath p99 已达
   ~0.03-0.04 ms，其中大部分是 Python/ctypes 往返与 `xcom_drain_display` 整批拷贝 65536 B。
   若需进一步降延时：让 PyCoreWorker 用更长的 drain（一轮拉出 ≥1 批），并把轮询间隔 10 ms
   与批次大小结合，减少每批的调用次数。
2. **`xcom_drain_display` 现在的 64 KiB 整批契约**对容量做出硬性要求；调用侧须维持 ≥64 KiB
   缓冲，否则 `XCOM_ERR_FULL`。低内存/嵌入式场景可考虑“半批 + 尾部”可分块 drain，但会破坏
   “整批转移、不裁尾”的简洁性，属设计取舍，本次未改。
3. **TEXT 视图未来超大块**（>64 KiB 连续文本）被任一 64 KiB 批次截断并各成一批；若出现
   跨批次连续长行，展示端需自行重组。属既有限制，非本次回归。
4. **HEX 视图进一步批量写**可再降 store 数（例如按 8/16 B 打包成两直写），但收益已接近
   ctypes/驱动往返噪声，收益/复杂度比不高，建议仅在真实串口高波特率下以 profiling 复核后再做。
5. **环境项**：本机串口枚举数在会话前后变化（2→0），故 gate_perf 的 real-dll 后端在无端口时
   需要虚拟名（`VIRTUAL`）才能走真实 DLL 热路径。这不是代码回归，是环境端口可用性差异；
   已在 §1.1 用等价注入缝方法规避。

---

## 6. 结论

本次在保留既有无锁热路径、固定块池、typed descriptor、RxKickGate、reservation 全部契约的前提下，
围绕任务列出的“接收格式化”热点完成 `rx_format_block` 优化：HEX 路径约 2 倍、TEXT 路径小幅
、其余视图一致。真实 DLL 注入缝三线 p99 全部远低于阈值，smoke 全过，ABI 导出未因本改动而变。
`xcom_drain_display` 的 64 KiB 整批契约已由集成 agent 落实；本报告配套把 smoke 测试缓冲对齐到
该契约，消除测试误报并使验证稳定。
