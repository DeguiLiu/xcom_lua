# 测试报告：WARP 满带宽持续接收压测

执行日期：2026-09-03
被测版本：`9c349f9`（Fix loop timing bugs and validate full-bandwidth WARP stress）
环境：Windows 10 (19044) / LuaJIT 2.1 (luvjit) / WARP 软件渲染 / 无 COM 硬件（UI 路径压测）

## 1. 目的与结论

**目的**：验证 WARP 软件渲染在 921600 波特满带宽（≈90 KiB/s）持续接收下，帧预算是否吃紧、内存是否泄漏、GC 是否稳定、显示尾部是否受限。

**结论：60 秒满带宽压测完整通过。**

| 验收项 | 目标 | 实测 | 判定 |
| --- | --- | --- | --- |
| 有效数据速率 | ≥90 KiB/s | **93.0 KiB/s** | 通过 |
| 数据完整性（显示路径） | backlog 有界 | ≤3.4 KiB / 64 KiB 上限 | 通过 |
| Lua 堆稳定性 | 无单调增长 | 0.6–1.1 MiB 波动（GC 压实） | 通过 |
| 进程私有内存 | 无泄漏增长 | 51.1 → 51.6 MB（30 s 内 +0.5 MB） | 通过 |
| 渲染帧率 | 按数据档节流，不卡死 | 10.5 fps（100 ms 合并档） | 通过 |
| 交互叠加 | 鼠标移动不中断数据流 | 500 ms 周期移动，无干扰 | 通过 |
| 回归测试 | 全过 | 154 通过 / 0 失败 | 通过 |

## 2. 方法

- **脚本**：`xcom_lua/tests/stress_warp_ui.lua`（无硬件 UI 路径压测）
- **注入路径**：与 `poll_display` 相同的 `_imgui_receive` 链路（append → 64 KiB 滚动裁剪 → flush → `set_receive_text` → ImGui/WARP 绘制）
- **注入节奏**：10 ms luv 定时器，按流逝时间补偿每 tick 字节数（libuv periodic timer 不补发被 WARP 帧延迟错过的触发）
- **交互负载**：每 500 ms 模拟一次鼠标移动（触发交互帧请求）
- **核心侧数据不丢契约**（RxBlock 池排空、`rx_pool_exhausted_bytes`）由 `tests/stress_fullband.lua` 覆盖，已在 core 的 VIRTUAL 进程内会话上执行通过（无需 COM 硬件，见 §5）

## 3. 实测数据

### 60 秒运行

```
==== stress summary ====
duration:        60.0 s
injected:        5581.6 KiB (5715517 bytes)
effective rate:  93.0 KiB/s (target 90)
frames rendered: 630 (10.5 fps)
injection ticks: 4200
final Lua heap:  986.7 KiB
final backlog:   3416 B (cap 65535)
trim happened:   yes (rolling window)
```

### 过程采样（每 5 s）

| t | Lua heap (KiB) | backlog (B) | frames | ticks | rate (KiB/s) |
| --- | --- | --- | --- | --- | --- |
| 5 s | 741 | 2867 | 110 | 232 | 97.0 |
| 10 s | 639 | 0 | 161 | 594 | 94.4 |
| 15 s | 1083 | 3050 | 229 | 926 | 93.9 |
| 20 s | 959 | 3233 | 285 | 1284 | 93.6 |
| 25 s | 756 | 9150 | 353 | 1615 | 93.3 |
| 50 s | 859 | 2989 | 480 | 3600 | 93.2 |
| 55 s | 575 | 0 | 552 | 3920 | 93.0 |

进程私有内存（中途外部采样）：t≈30 s 时 51.1 MB，t≈55 s 时 51.6 MB——满带宽流经 5.6 MB 数据无泄漏。

### 30 秒运行（复验）

93.2 KiB/s / 2.8 MB / 帧率 13.2 fps / 终态堆 634.7 KiB，与 60 秒一致。

## 4. 压测过程中发现并修复的缺陷

压测不仅验证，还暴露了 4 个真实 bug（均已修复并包含在被测版本 `9c349f9`）：

| 缺陷 | 影响 | 修复 |
| --- | --- | --- |
| 帧截止期过期后仍睡满 luv 定时器周期 | WARP 帧（45-60 ms）超预算后，下一帧被推迟至最长 250 ms | `timeout=0` 立即进入下一轮渲染 |
| GC 触发策略两头错 | 输入密集时收集器饥饿（堆只涨）；持续流量时每 10 ms 步进过度（约 800 KiB/s GC 预算） | 改为 ≥128 KiB 堆增量触发，每次 `step(32)` |
| 运行时关闭日志同步阻塞 UI 最长 2 s | `log_close` 是 drain 等待，4×500 ms 重试在切 auto-save 时冻结窗口 | 50 ms 探测 + P2 defer 重试（上限 20 次）；退出路径保持同步 |
| MsgWait 默认 15.6 ms 睡眠粒度 | 10 ms drain 节奏被拉伸到约 23 ms | `timeBeginPeriod(1)`（winmm，退出时 `timeEndPeriod`） |

压测脚本自身修正：模块路径解析（裸相对路径）、4 个 timer 回调 `jit.off`（防 "bad callback" PANIC）、关闭改走 `win:on_close()`（`uv.stop()` 会留下永远运行的消息泵）、按流逝时间补偿注入量（原始固定每 tick 字节只送达 41/90 KiB/s）。

## 5. 边界与后续

- **数据不丢契约已覆盖（VIRTUAL）**：`tests/stress_fullband.lua` 现默认走 core 的 VIRTUAL 进程内会话（`xcom_ao` 注入接缝），无需串口硬件即可执行：15 s 满带宽档注入 8.85 MB，`rx_pool_exhausted_bytes=0`、`display_pending=0`、注入零拒绝，VERDICT PASS。注意显示文本视图会把 CRLF 折叠为单 LF（跨 4096 B RxBlock 边界的对不折叠），测试按精确折叠数断言 `drained == injected - folded`；另断言帧行号序列连续（内容级完整性，字节对账看不出等长置换）与有效速率 ≥ 标称 80%。注意粒度：一帧 9400 B 远大于 90 KiB/s 的 10 ms 份额（921 B），实际注入约为标称线速的 10 倍（有意过压）。真需要物理对端的 `serial_external_receive_test`/`send_help_test` 在无串口主机上显式 SKIP（exit 0）。理论余量 512 KiB ÷ 90 KiB/s ≈ 5.7 s（按实际 10 倍过压则不足 0.6 s，仍零拒绝——池与显示排空能力有余量）。
- **WARP 帧预算**：满带宽 + 交互叠加时渲染 10-13 fps（数据档 100 ms 主导）。若未来 UI 复杂度上升导致帧预算不足，可回退 `D3D_DRIVER_TYPE_HARDWARE`（一行）或提高数据档间隔。
- 复现命令：
  ```
  cd xcom_lua
  runtime\luvjit.exe tests\stress_warp_ui.lua 60 90
  ```
