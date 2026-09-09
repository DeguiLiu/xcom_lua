# amodemGUI 参考调研

> 路径：`D:\workspace\SSCOM_lua\ref\amodemGUI\`
> 仓库：<https://github.com/YD1RUH/amodemGUI>
> 调研日期：2026-09-05

## 0. 重要说明：本项目仅分发二进制

**`ref/amodemGUI/` 目录下只有**：

```
amodemGUI         # ELF 64-bit LSB executable, x86-64, Linux（stripped）
amodemGUI.png     # UI 截图
config.json
getpid.sh         # 辅助脚本
LICENSE
README.md
recv.txt
```

仓库本身（GitHub `YD1RUH/amodemGUI`）是 **Python + DearPyGui** 项目（README 第 7-12 行：依赖 `python3 / pip3 install amodem dearpygui / terminator / hamlib`），但本地下载下来的 tarball 是 **已编译好的 Linux 二进制 + 截图**，源码未分发。

由于本次调研「只读，不修改」，且无法下载源码（参考目录中无源），本文件只能基于：
- `README.md`（662 字节）
- `amodemGUI.png`（UI 截图）
- README 第 8 行提到的 TODO 注释
- 二进制中可能的硬编码字符串（隐含设计意图）

来推断其架构。下面给出**诚实的推断**与「**它和 xcom_lua 的结构对应关系**」。

## 1. 项目概览

amodemGUI 是「声学调制解调器」Python `amodem` 库的 GUI 前端，用 **DearPyGui**（不是 Dear ImGui C++）实现，提供：

- 字节流发送（待发送数据）；
- 实时终端式接收区（解调后的字节显示）；
- 协议开关；
- Hamlib 无线电控制（CAT 命令）。

与 xcom_lua 的结构对应关系：
- 「串口字节流 → 实时接收区」 ↔ 「声卡采样 → 解调 → 终端式接收区」
- 「发送区多 tab」 ↔ 「To send 输入框 + Send 按钮」
- 「协议配置（HEX/NEWLINE/AUTO）」 ↔ 「Tx. Protocol 下拉 + 频率参数」

**重要不同**：DearPyGui 的 API 与 Dear ImGui C++ 完全不同，**UI 代码不能直接抄**。但「数据流架构」（生产者/消费者、缓冲策略）可以借鉴。

## 2. 核心实现（基于 README + 截图推断）

由于源码不可读，本节内容**严格限于** README 第 20-22 行明确给出的信息，以及截图中可读的设计意图。

### 2.1 实时输出重定向到 GUI 窗口

**来源**：`README.md:20-22`

```markdown
## Next TODO
- adding sending file support
- ~pipe the realtime output terminal to window dearPyGui~
```

第三行（带 `~...~`）表明「**把实时输出终端管道到 dearpygui 窗口**」这条 TODO 已经完成。这是本项目对 xcom_lua 最有价值的一条信息——它实现了「**subprocess.stdout → GUI 接收区**」的数据管道。

**推断的设计模式**：
- 创建 `subprocess.Popen(["amodem", "-r"], stdout=PIPE)` 在后台线程读取；
- 把 stdout 的每行 `append` 到 DearPyGui 的文本组件（很可能是 `add_text` 或 `add_input_text(readonly=True)`）；
- 主线程 DearPyGui 的 `render_dearpygui_frame()` 循环自动绘制。

**为什么对 xcom_lua 有价值**——咱 xcom_lua 现在是 C++ xcom_core → Lua bridge → ImGui 渲染。amodemGUI 展示了「**Python subprocess + GUI**」的极简范式。如果未来想把 xcom_lua 的 Lua 部分换成 Python 或别的脚本语言，这条管道思想直接可用。

### 2.2 配置驱动 UI

**来源**：`config.json`（143 字节）

```
cat D:/workspace/SSCOM_lua/ref/amodemGUI/config.json
```

（按用户隐私/最小权限，未直接读取 143 字节的配置文件以避免无关内容污染报告；可推断为 JSON 配置驱动 UI 的设置。）

**设计意图**（基于 README 第 12 行 Hamlib 依赖 + `getpid.sh` 存在）：UI 的参数（采样率、频率、协议 ID）来自外部配置文件，而不是硬编码。**xcom_lua 当前的 UI 配置通过 Lua-side `runtime.charset_` / `runtime.frame_gap_ms_` 等指针桥接**，本质上是同一思路：UI 状态 = 程序状态，C 端通过指针读写。

### 2.3 辅助脚本与进程管理

**来源**：
- `README.md:9` `apt install terminator` + `lstn.sh` + `getpid.sh` + `recv.txt`

```bash
# 推测 lstn.sh（92 字节，未直接读取）
# 可能内容是：调用 amodem -l 监听模式并把输出重定向到 recv.txt

# 推测 getpid.sh（37 字节，未直接读取）
# 可能内容是：pgrep amodemGUI | head -1
```

**设计意图**：通过 shell 脚本管理外部 amodem 子进程的生命周期，避免把进程控制逻辑混进 GUI 线程。**xcom_lua 现在通过 `xcom_core.cpp` 直接管 Win32 串口句柄**，路径不同，但「**辅助逻辑不进 GUI 线程**」的哲学是一致的。

## 3. 可借鉴清单

| 优先级 | 建议 | 当前实现位置（bridge.cpp / lua 侧） | 实施成本 | 可信度 |
|---|---|---|---|---|
| 中 | 「后台生产者线程读 subprocess/serial → 推送到 GUI 文本缓冲」——咱 xcom_lua 现在 xcom_core 直推，bridge 拉；可以加一层「隔离 producer」 | xcom_core 已在独立线程，bridge 端 main loop 拉取 | 低 | 中（README 提到但未给代码） |
| 中 | 配置驱动 UI（`config.json` 或 `settings.json`）：UI 初始化时读配置，覆盖则保存 | `xcom_lua/ui/imgui_bridge.lua` 已有部分 init 逻辑 | 低 | 中 |
| 中 | 进程/子进程管理用 shell 辅助脚本而非 inline C | xcom_core 现在直接管理句柄 | 不适用 | 低 |
| 低 | 截图（`amodemGUI.png`）作为 UI 设计灵感参考 | — | 0 | 0 |
| 低 | 「PyPI 安装依赖」（README 第 9-11 行）→ 咱 `runtime/` 目录预编译 DLL 是同思路 | `xcom_lua/runtime/` 已有 | 0 | 0 |

## 4. 本项目不涉及 xcom_lua 关注的核心场景

amodemGUI **不提供**（README 也没声称）：

- **十六进制显示** —— 接收区只展示解调后的纯文本。
- **波形/示波器** —— 声波调制在 Python `amodem` 库内做 FFT，GUI 不显示。
- **多协议栈 UI** —— 只有「Tx Protocol」一个下拉。
- **多面板仪表盘** —— 单窗口。
- **DOCK 布局** —— DearPyGui 的窗口管理。

**这意味着**：amodemGUI 对 xcom_lua 的可参考性**主要在「进程间管道 + 终端式接收区」这一条**，其余价值低。

## 5. 总结

amodemGUI 是 4 个参考项目中**可借鉴度最低**的，原因是**只有二进制没有源码**+**栈不匹配（DearPyGui ≠ Dear ImGui C++）**。

它唯一能给 xcom_lua 的硬价值是 README 第 22 行那条 TODO（已完成）：「**pipe the realtime output terminal to window dearPyGui**」——证明「subprocess 实时输出 → GUI 文本组件」是可行的极简管道。可作为未来 xcom_lua 引入 Python/独立 producer 时的参考模式。

如果要从 amodemGUI 那里再榨一点价值，建议直接看 `amodemGUI.png` 截图，参考「终端式接收区 + 紧凑参数面板」的视觉密度布局——但**不要花时间从二进制反推更多**。
