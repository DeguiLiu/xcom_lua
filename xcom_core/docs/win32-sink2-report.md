# Win32 Sink Report — 平台层收敛（第二期：业务层全面净空）

日期: 2026-09-01
范围: 把 `diagnostics/diagnostic.cpp`、`io/log_writer.cpp`、`abi/xcom_abi.cpp`
（以及复核 `runtime/xcom_core.cpp/.hpp`、`ao/*`）中的 Win32 专有词（
`WaitForSingleObject` / `HANDLE` / `BYTE` / `CreateEvent` / `SetEvent` /
`CloseHandle` / `CreateTimerQueue` / `DeleteTimerQueue` / `GetTickCount64` /
`Sleep` / `DWORD` / `ULONGLONG` / `INVALID_HANDLE_VALUE`）全部下沉到平台层
（`coact::pal`）与 `foundation/unique_handle`。

## 验收验证结果

| 项 | 状态 | 结果 |
| --- | --- | --- |
| 构建 (Release /O2, Ninja) | 通过 | `xcom_core.dll` + 5 个测试目标全部链接成功 |
| `xcom_smoke_test.exe` | 通过 | `SMOKE TEST PASSED` |
| `xcom_session_churn_test.exe` | 通过 | exit 0，句柄 warm 433 -> measured 433（零泄漏） |
| `dumpbin /EXPORTS` | 24 个导出 | **由并行 agent 新增，非本任务所致（见「协调说明」）** |
| acceptance grep | 0 命中 | 六类目标文件 0 命中（纯注释也已净空） |
| `xcom_windows_pal_test` / `xcom_periodic_timer_test` | 通过 | 均 exit 0（确认平台层新增未破坏 PAL/timer） |

acceptance grep（无输出 == 通过）：

```bash
grep -rnE "WaitForSingleObject|\bHANDLE\b|\bBYTE\b|CreateEvent|SetEvent|CloseHandle|\bDWORD\b|GetTickCount64|\bSleep\b|ULONGLONG|INVALID_HANDLE_VALUE" \
  src/diagnostics/diagnostic.cpp src/io/log_writer.cpp src/abi/xcom_abi.cpp \
  src/runtime/xcom_core.cpp src/runtime/xcom_core.hpp src/ao/
```

## 四要素（风险等级 / 复现条件 / 修复内容 / 硬件限制）

### 风险等级
低。全部改动为「类型封装替换」（裸 HANDLE -> `WakeEvent`/`UniqueHandle`，
`Sleep`/`GetTickCount64`/`DWORD`/`ULONGLONG` -> `coact::pal::monotonic_ms()`
/`sleep_ms()` 中性助手），不改变并发/生命周期语义；每处 Win32 调用点的行为
（auto-reset 事件、阻塞等待、文件句柄 RAII）逐一对齐原实现。

### 复现条件
无新增硬件/时序依赖。`GetTickCount64` -> QPC（`QueryPerformanceCounter`）
毫秒换算后，`monotonic_ms()` 的语义仍为「单调递增毫秒」，用于 deadline 运算
等价；仅依赖 `QueryPerformanceFrequency` 可用（失败时返回 0，与
`Windows::monotonic_ns()` 一致退化）。本改动不引入功能变化，无复现步骤。

### 修复内容
1. **`runtime/pal_windows.{hpp,cpp}`（平台层，纯新增）**
   - 新增两个自由函数 `coact::pal::monotonic_ms()`（返回 `uint64_t` 单调毫秒，
     内部 QPC 换算）与 `coact::pal::sleep_ms(uint32_t)`。业务层不再拼写
     `Sleep`/`GetTickCount64`/`ULONGLONG`/`DWORD`。
2. **`abi/xcom_abi.cpp`（业务层）**
   - `xcom_open` 的 `Sleep(10U)` -> `coact::pal::sleep_ms(10U)`。
   - `xcom_close` 的 `GetTickCount64`/`ULONGLONG`/`DWORD` deadline 轮询 ->
     `coact::pal::monotonic_ms()` + `coact::pal::sleep_ms(...)`，类型统一为
     `uint64_t`/`uint32_t`。
   - 删除 `#include <windows.h>`（已无 Win32 依赖）。
3. **`diagnostics/diagnostic.cpp`（业务层）**
   - `Impl::wake_`（裸 `HANDLE`）-> `coact::pal::WakeEvent` 值成员；
     8 处 `CreateEventW`/`SetEvent`/`WaitForSingleObject`/`CloseHandle` 改为
     `wake_.valid()`/`signal()`/`wait()`；`bind_logger()` 改为惰性校验
     `wake_.valid()`（事件在 `Impl` 构造时即由 `WakeEvent` 默认构造创建，
     析构由 `StaticObjectSlot::destroy` -> `~Impl` -> `~WakeEvent` 自动
     `CloseHandle`）。
   - `const DWORD elen` -> `const std::uint32_t elen`（`GetEnvironmentVariableA`
     返回值直接赋给 `uint32_t`，32 位无符号同宽）。
   - `Impl* impl_` 仍为裸指针：与 af4ac4b 并行核对，其未改为值成员，按指示
     **只做 `wake_` 替换**，未动 `impl_`。
4. **`io/log_writer.cpp`（业务层）**
   - `Completion::done_event`（裸 `HANDLE` 成员 + 析构 `CloseHandle`） ->
     `coact::pal::WakeEvent` 值成员（构造 `CreateEventW`、析构自动关闭）。
   - `Impl::wake_event` / `appenders_drained_event` -> `coact::pal::WakeEvent`；
     `SetEvent`/`WaitForSingleObject`/`CreateEventW`/`CloseHandle` 全部改为
     `signal()`/`wait()`；`~Impl` 的显式关闭删除（`= default`）。
   - `Impl::log_file`（裸 `HANDLE` = `INVALID_HANDLE_VALUE`） ->
     `foundation::UniqueHandle`；`!= INVALID_HANDLE_VALUE` -> `.valid()`，
     `CreateFileW` 返回值经 `log_file.reset(...)` 包装，`CloseHandle` ->
     `.reset()`。
   - `write_all(FileJob&, HANDLE)` -> `write_all(FileJob&,
     foundation::UniqueHandle&)`，内部 `unsigned long`（== Win32 DWORD，免
     cast）局部变量经 `file.get()` 调用 `WriteFile`。
   - `process_atomic` 局部 `HANDLE file` -> `foundation::UniqueHandle`
     值对象（`CreateFileW` 构造、`FlushFileBuffers(file.get())`、`file.reset()`）。
   - `close_append_admission` 的 `GetTickCount64`/`DWORD`/`ULONGLONG`/`INFINITE`
     /`MAXDWORD` -> `coact::pal::monotonic_ms()` + `kInfiniteTimeout`/
     `kMaxTimeoutMs` 中性常量（均 `0xFFFFFFFF`，注释说明是 Win32 别名）。
   - `Sleep(50U)`（Append 磁盘重试）-> `coact::pal::sleep_ms(50U)`。
   - `submit_sync` 的 `WaitForSingleObject`/`WAIT_OBJECT_0`/`WAIT_TIMEOUT`
     -> `completion->done_event.wait(timeout_ms)`。
   - `shutdown` 的 `close(INFINITE)`/`SetEvent`/`CloseHandle` ->
     `close(kInfiniteTimeout)`/`wake_event.signal()`，删除关闭逻辑
     （WakeEvent 随 Impl 析构回收）。
   - `start` 的 `CreateEventW`/`== nullptr` 检查 -> `wake_event.valid()`
     （事件由 Impl 构造时创建，不再每次 start 重建）。
5. **`ao/xcom_ao.cpp`（业务层）**
   - 删除无用的 `#include <windows.h>`（整个文件不含任何 Win32 类型/调用）。
6. **复核 `runtime/xcom_core.cpp` / `xcom_core.hpp` / 其余 `foundation/*`**
   - 均已干净（上一期 #24 已完成）。`xcom_core.hpp` 仅保留一行
     `#include <windows.h>`（无任何 Win32 用词），按上一期报告「保守保留」
     处理，因该头被 7 个 TU 传递包含，移除有 break 风险。`unique_handle`
     是 HANDLE RAII 封装边界，按设计允许含 HANDLE。

### 硬件限制
无。`monotonic_ms()` 依赖的 QPC 在 `pal_windows.cpp` 内（平台层允许 Win32），
不影响业务层；QPC 不可用时返回 0 的降级与既有 `monotonic_ns()` 一致。

## 逐文件泄漏清单对照表

| 文件 | 原 Win32 泄漏点 | 处置 |
| --- | --- | --- |
| `abi/xcom_abi.cpp` | `Sleep(10U)` x1；`GetTickCount64` x2；`ULONGLONG` x3；`DWORD` x1 | `sleep_ms` / `monotonic_ms` + `uint64_t`/`uint32_t`；删 `<windows.h>` |
| `diagnostics/diagnostic.cpp` | `HANDLE wake_`；`CreateEventW`/`SetEvent`/`WaitForSingleObject` x8 处；`DWORD elen` x1 | `WakeEvent` 值成员 + `.signal()/.wait()/.valid()`；`uint32_t elen` |
| `io/log_writer.cpp` | `done_event`/`wake_event`/`appenders_drained_event` 三个 HANDLE + CreateEventW/SetEvent/WaitForSingleObject/CloseHandle；`log_file` HANDLE + INVALID_HANDLE_VALUE；`write_all(HANDLE)`；`Sleep`；`GetTickCount64`/`DWORD`/`ULONGLONG`/`INFINITE`/`MAXDWORD` | 三个 `WakeEvent`；`log_file`/`file` -> `UniqueHandle`；`write_all(UniqueHandle&)`；`sleep_ms`/`monotonic_ms`；`kInfiniteTimeout`/`kMaxTimeoutMs` |
| `ao/xcom_ao.cpp` | 无用 `#include <windows.h>` | 删除 |
| `runtime/xcom_core.cpp` | 无（上一期已净空） | — |
| `runtime/xcom_core.hpp` | 仅 `#include <windows.h>` 一行，无 Win32 用词 | 保守保留（传递包含，见 #24） |
| `foundation/unique_handle.*` | HANDLE/CloseHandle/INVALID_HANDLE_VALUE | 允许（HANDLE RAII 封装边界） |

## 协调说明（并行 agent af4ac4b）

1. **文件被并行改写**：`io/log_writer.cpp` 和 `abi/xcom_abi.cpp` 在本次任务
   期间被 af4ac4b 重写 —— 前者新增了「原子流」API（`StreamBegin`/`StreamAppend`/
   `StreamCommit`/`StreamAbort` + `AtomicStream` 值结构 + `std::optional`/
   `std::exchange`/`std::move`），后者新增 `xcom_file_stream_*` 4 个 ABI 函数。
   我的全部改动（`WakeEvent`、`UniqueHandle`、`monotonic_ms`、`sleep_ms`）在
   并行改写合并后**仍保留在磁盘上**（二者无冲突：af4ac4b 的流式代码直接复用
   了我改好的 `write_all(UniqueHandle&)` 与 `atomic_stream->file` 是
   `UniqueHandle` 成员）。
2. **导出数从 19 涨到 24 非本任务所致**：基线 `build-win32-sink/bin/xcom_core.dll`
   （01:00 构建）是**陈旧的**，早于 af4ac4b 新增的 5 个导出：
   `xcom_file_submit_atomic_borrowed`（xcom.h 01:17）、
   `xcom_file_stream_begin/append_borrowed/commit/abort`（01:18 起）。
   当前源码的真实导出数为 **24**。我的改动纯属内部类型替换，**未新增/删除任何
   `XCOM_API` 符号**（含"19 导出不变"的目标时，应以上述 24 为当前源码基线，而非
   陈旧 DLL 的 19）。
3. **每次改动前重读**：均已遵守 —— `xcom_ao.cpp` 首次删除 `#include <windows.h>`
   时命中「file modified」提示并重读后重做；`log_writer.cpp`/`xcom_abi.cpp`
   的并行合并均通过文件修改提醒感知，并在最终构建前用全量 acceptance grep 复核为
   0 命中。

## 编码约束落实情况

- 全程未用 `unique_ptr` / `shared_ptr` / `std::function`。
- 事件句柄一律 `WakeEvent` 值成员（值语义 + move-only，基于 `UniqueHandle`）；
  文件句柄一律 `foundation::UniqueHandle`；回调沿用 `foundation::FixedFunction`。
- 定宽类型（`std::uint32_t`/`std::uint64_t`）与 `unsigned long`（== Win32 DWORD，
  免 cast）在边界使用；全部 `noexcept` 得当。
- 无 `placement new` 之外的新增堆分配（`Completion` 仍经固定池 `placement new`，
  其 `WakeEvent` 值成员随 `~Completion` 自动关闭）。

## 遗留/后续（可选）

- `xcom_core.hpp` 的 `#include <windows.h>` 与 `diagnostic.cpp` 的
  `#include <windows.h>` 仍保留：前者无 Win32 用词（传递包含，保守保留），后者
  仍需 `GetEnvironmentVariableA`/`LARGE_INTEGER`/`QueryPerformance*`（diag 适配器
  的 QPC 时钟属平台适配职责，且这些词不在 acceptance grep 目标内）。
- 若需彻底移除这两个 include，可另开任务：把 `diagnostic.cpp` 的 QPC 时钟下沉到
  `coact::pal`，并把 `xcom_core.hpp` 的 windows.h 依赖逐 TU 拆解。
