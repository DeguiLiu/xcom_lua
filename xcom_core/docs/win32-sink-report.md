# Win32 Sink Report — 平台层收敛

日期: 2026-09-01
范围: 将 `xcom_core.cpp` / `xcom_core.hpp` 中的 Win32 专有词全部下沉到平台层
（`pal_windows` 与 `io/serial_backend_win`）。

## 验收验证结果

| 项 | 状态 | 结果 |
| --- | --- | --- |
| 构建 (Release /O2, Ninja) | 通过 | `xcom_core.dll` 链接成功，`xcom_windows_pal_test.exe` 链接成功 |
| `xcom_smoke_test.exe` | 通过 | `SMOKE TEST PASSED`（全 40 项断言 ok） |
| `xcom_session_churn_test` | 通过 | exit 0，句柄数 warm 433 -> measured 433（零泄漏） |
| `dumpbin /EXPORTS` | 19 个导出不变 | 与基线一致 |
| acceptance grep (`WaitForSingleObject\|CreateEvent\|CreateTimerQueue\|RegEnum\|RegOpenKey\|\bHANDLE\b\|\bDWORD\b`) | 0 命中 | `xcom_core.cpp` 与 `xcom_core.hpp` 均 0 命中 |
| 全量 Win32 词扫描（含 ERROR_SUCCESS/HKEY/PVOID/……） | 0 命中 | 两文件均干净 |

```bash
# 复现 acceptance grep（无输出 == 通过）
grep -nE "WaitForSingleObject|CreateEvent|CreateTimerQueue|RegEnum|RegOpenKey|\bHANDLE\b|\bDWORD\b" \
  src/runtime/xcom_core.cpp src/runtime/xcom_core.hpp
```

## 四要素（新增/提升的封装）

### 1. `foundation/unique_handle.hpp` / `.cpp`（新文件，提升共享）
从 `io/serial_backend_win.hpp` 中把私有 `UniqueHandle`（HANDLE RAII）提升为
`xcom::foundation::UniqueHandle` 供两处共享：
- 移动语义（`std::exchange`）、copy 删除、析构 `CloseHandle`、`get()/reset()`、
  `valid()` 同时把 `nullptr` 和 `INVALID_HANDLE_VALUE` 视为空。
- `serial_backend_win.hpp` 删除其内嵌 `UniqueHandle`，改 `using` 复用共享版本；
  `serial_backend_win.cpp` 中的四组成员改名（`port_` / `read_event_` 等）语义不变。
- **被 `coact::pal::WakeEvent` 复用**。

### 2. `coact::pal::WakeEvent`（`pal_windows.hpp/.cpp` 新增）
- 构造 `CreateEventW`（auto-reset、失败置空 -> `valid()` 为 false）；析构 `CloseHandle`。
- `signal()` = 空安全 `SetEvent`；`wait(ms)` = `WaitForSingleObject`，返回是否 signaled
  （`ms==0` 表示无限等待）。
- 基于 `UniqueHandle` 值成员，move 默认、copy 删除。

### 3. `coact::pal::PeriodicTimer`（`pal_windows.hpp/.cpp` 新增）
- `start(interval_ms, Callback cb)`：`CreateTimerQueue` + `CreateTimerQueueTimer`；
  回调存于对象内 `FixedFunction<void()>`，地址作为 timer context（stop 阻塞保证生命周期）。
- `timer_cb`（`WT_EXECUTEINTIMERTHREAD` 独立线程）只 `(*cb)()`，**不碰任何业务原子**
  —— 原 `autosend_timer_cb` 的 CAS 移入调用方 `autosend_tick`。
- `stop()` = `DeleteTimerQueueTimer(..., INVALID_HANDLE_VALUE)` 阻塞到回调完成；
  `~PeriodicTimer` = `DeleteTimerQueueEx`。`interval_ms==0` 视作取消。

### 4. 端口枚举下沉：`xcom::enumerate_serial_ports`（`io/serial_backend_win.hpp/.cpp`）
- 把 `xcom_core.cpp::list_ports_impl` 里的 `RegOpenKeyExA` / `RegEnumValueA` / `RegCloseKey`
  等 Registry 逻辑整体移入 `io/serial_backend_win`。
- 公共接口为纯 C++：`std::uint32_t enumerate_serial_ports(foundation::FixedVector<PortInfo,64>&)`
  返回发现总数（可超容量，对应 ABI `XCOM_ERR_FULL`）。
- `xcom_list_ports` 直接调它，把结果拷贝进 `XcomPortInfo[]`。

## 每个封装用途

| 封装 | 原裸露 Win32 | 新用法 |
| --- | --- | --- |
| `UniqueHandle` | serial_backend 私有 HANDLE 成员 | 共享 HANDLE RAII 基元 |
| `WakeEvent` | `RxCapacityWaiter::wake_event_`、`SessionWriter::wake_` 两个裸 HANDLE | 见下「接线」 |
| `PeriodicTimer` | `CoreState::autosend_timer_queue_` / `autosend_timer_` 两个裸 HANDLE | 见下「接线」 |
| `enumerate_serial_ports` | `list_ports_impl` 内 RegOpenKeyEx/RegEnumValue | 见下「接线」 |

## 接线（E 步）状态: 已完成

- `RxCapacityWaiter`：`HANDLE wake_event_` -> `coact::pal::WakeEvent`。
- `SessionWriter`：`HANDLE wake_` -> `coact::pal::WakeEvent`;
  `CreateEventW/ResetEvent/SetEvent/WaitForSingleObject` 全部改为 `wake_` 方法调用。
- `CoreState`：`HANDLE autosend_timer_queue_/autosend_timer_` -> `coact::pal::PeriodicTimer`;
  `shutdown()` / `autosend_set_impl()` 改经 `autosend_timer_.start(interval_ms, cb)` 与
  `.stop()`; 原 `static void CALLBACK autosend_timer_cb` 改为普通静态
  `autosend_tick(CoreCtx*)`（auto-send CAS 保留在回调内，满足「定时器不碰业务原子」）。
- `xcom_list_ports`：`list_ports_impl` 内部 Registry 逻辑删除，改调 `enumerate_serial_ports`。
- `sink_owner_open` / `sink_owner_write` 中 `int32_t error = ERROR_SUCCESS` 的 5 处
  改为 `kSerialSuccess`（`serial_backend_win.hpp` 新增的中性成功哨兵 = 0），彻底去掉
  `ERROR_SUCCESS` 及对 winerror.h 的依赖。
- `CoreCtx::option_lock_(HANDLE)`：上一轮已用三个独立 `std::atomic<uint8_t>`
  （hex_view/timestamp/pause_display）代替，本轮无需再处理。

## 协调说明（并行 agent af4ac4b）

1. 平台层纯新增（`unique_handle`、`WakeEvent`、`PeriodicTimer`、`enumerate_serial_ports`）
   先行完成，不触碰 `xcom_core.cpp` —— 无冲突。
2. 接线安排到最后，且每次改动前重读 `xcom_core.cpp`。期间 af4ac4b 曾把 `pal_windows.cpp`
   的 Dispatcher 线程从 `_beginthreadex` 改为 `std::thread`，并把 `rx_ingress` 返回类型
   从 `bool` 改为 `RxIngressResult` —— 均不影响本任务涉及的字段/函数，我的接线未与其冲突。
3. af4ac4b 新增 `tests/windows_pal_test.cpp` + CMake 目标（直接实例化 `coact::pal::Windows`
   并链接 `xcom_core`）。该目标最初因 PAL 符号未导出而 LNK2019；后续由 af4ac4b 处理使其
   链接成功（最终构建 `[8/8]` 通过）。不属于本任务范围，未改动。
4. `xcom_core.cpp` 最终稳定版在磁盘上（00:50 之后无并行改动再覆盖），已按磁盘版本完成
   接线并构建验证。

## 编码约束落实情况

- 全程未用 `unique_ptr` / `shared_ptr` / `std::function`（回调用 `foundation::FixedFunction`）。
- 值成员复用 `UniqueHandle`；`PeriodicTimer` 的 `Callback` 为 `FixedFunction<void()>` 值成员。
- 指针捕获（`[core]`）入 `FixedFunction` 容量（2×sizeof(void*)）内。
- 定宽类型（`std::uint32_t` / `int32_t`），全部 `noexcept` 得当。

## 遗留/后续（可选）

- 无功能遗留：四要素 + 接线全部完成并构建通过。
- `xcom_core.hpp` 仍保留 `#include <windows.h>`（仅 include，不含任何 Win32 类型/宏用词；
  acceptance grep 不检查该行）。因该头被 7 个 TU 传递包含，保守保留以避免 break；如后续
  想彻底移除可单独重构 include 依赖。
- `ERROR_*` / `BYTE` / `WaitForMultipleObjects` 等 Win32 词仍存在于 `io/serial_backend_win`
  层 —— 这是平台层，按设计允许，不违反「xcom_core 收敛」目标。
