# wave-gui 参考调研

> 路径：`D:\workspace\SSCOM_lua\ref\wave-gui\`
> 仓库：<https://github.com/ggerganov/wave-gui>
> 调研日期：2026-09-05

## 1. 项目概览

wave-gui 是 gerganov 写的「声波数据传输」实验性 GUI：**C++ + SDL2 + GLFW3 + FFTW + Dear ImGui**，整个工程（不含 imgui 子模块）约 **2157 行**（`main/*.cpp/*.h` + `src/cg_*.cpp/*.h`）。它的特点是「极简可用」——主窗口三个面板（Controls / Waveform + Spectrum / Output），用 `PlotLines` + `PlotHistogram` 直接画 PCM 波形、FFT 频谱和匹配数据段标记，没有自定义 shader、没有 dock、没有复杂状态机。

**对 xcom_lua 的价值**——**最小可用的 ImGui 数据可视化范例**：
- 提供了「一个 ring buffer + 一组 lambda 数据源 + ImGui 原生 `PlotHistogram`」的完整范式，可直接照搬到 `core/waveform.lua` 的 Phase 4 改造。
- 颜色分层（`PushStyleColor(ImGuiCol_FrameBg, ...)`）+ `PlotHistogram` lambda 的「条件返回 0 来画范围高亮」是雷达瀑布图思想的简化版。
- main loop 是**「`while(true) { update; render; swapBuffers; }` + emscripten_set_main_loop_arg** 双路——桌面/WebAssembly 同一份代码；咱 xcom_lua 不需要 WASM，但「主循环骨架」值得抄。

**栈对应**：

| wave-gui | xcom_lua 对应 |
|---|---|
| `main/app.cpp` 主循环（update/render） | `xcom_lua/ui/window.lua` `run_message_loop` |
| `main/ui.cpp` ImGui 渲染 | `xcom_imgui_bridge.cpp` ReceiveContent/TransmitContent |
| `src/cg_ring_buffer.h` 有锁环形缓冲 | `core/waveform.lua` `ring_push/ring_iter`（无锁 Lua 实现） |
| `main/ui.cpp` `PlotHistogram` 包裹 | 咱没有 PlotHistogram，只用 GDI 折线 |

## 2. 核心实现

### 2.1 PlotHistogram + lambda 数据源 = 「条件高亮」

**文件**：`main/ui.cpp`
**关键函数**：`UI::renderWindowInput`（行 366-462）+ 主路径 `PlotHistogram` lambda（行 396-403）

```cpp
// main/ui.cpp:388-424
if (data->sampleSpectrum != nullptr) {
    auto wSize = ImGui::GetContentRegionAvail();
    wSize.y *= 0.5;
    static float yScale = 1.0f;
    auto posSave = ImGui::GetCursorScreenPos();

    ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
    ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(0.0f, 1.0f, 0.0f, 0.4f));
    ImGui::PlotHistogram("##plotDataRange",
                         [](void *data, int i) -> float {
                             if (data == nullptr ||
                                 i*::g_inp->getHzPerFrame() < ::g_inp->freqStart_hz ||
                                 i*::g_inp->getHzPerFrame() > ::g_inp->freqStart_hz + ::g_inp->nDataBitsPerTx*::g_inp->freqDelta_hz) return 0.0f;
                             return 1.0f;
                         },
                         data->sampleSpectrum->data(), data->samplesPerFrame/2, 0, "\nGreen: Data, Red: Checksum", 0.5f, 1.0f, wSize);
    ImGui::PopStyleColor(2);

    ImGui::SetCursorScreenPos(posSave);  // ← 关键：回到原位
    ImGui::PushStyleColor(ImGuiCol_FrameBg, ImVec4(0.0f, 0.0f, 0.0f, 0.0f));
    ImGui::PushStyleColor(ImGuiCol_PlotHistogram, ImVec4(1.0f, 0.0f, 0.0f, 0.4f));
    ImGui::PlotHistogram("##plotDataRange",
                         [](void *data, int i) -> float {
                             if (... freqCheck_hz 范围 ...) return 0.0f;
                             return 1.0f;
                         },
                         data->sampleSpectrum->data(), data->samplesPerFrame/2, 0, NULL, 0.5f, 1.0f, wSize);
    ImGui::PopStyleColor(2);

    ImGui::SetCursorScreenPos(posSave);  // ← 第二次回到原位
    ImGui::PlotHistogram("##plotSpectrumCurrent", data->sampleSpectrum->data(), data->samplesPerFrame/2, 0,
            (std::string("Current Spectrum, Y max = ") + std::to_string(yScale)).c_str(), 0.0f, yScale, wSize);
}
```

**设计要点**：
- **同一片数据，三次 PlotHistogram 重叠在同一位置**——第一次画「数据频率范围」绿色高亮，第二次画「校验频率范围」红色高亮，第三次画实际频谱。靠 `SetCursorScreenPos(posSave)` 回到上一轮起点（行 406, 419）。**这是给 xcom_lua 波形最直接的启发**：用同一坐标画「信号 + 阈值线 + 触发线 + 包络」四层。
- **lambda 数据源 + 条件返回 0**——避免维护额外的「标记数组」，用 lambda 直接判定当前 x 是否在标记区间。开销是 O(N) 的 lambda 调用，但省内存分配 + GC（Lua 适用）。
- **`PushStyleColor(ImGuiCol_FrameBg, 透明)`** 把图框背景擦掉，让多层 histogram 干净叠加。

### 2.2 「Lambda + 数据源」替代 PlotLines 自定义 shader

**文件**：`main/ui.cpp:553-558`（renderWindowOutput 节）

```cpp
// main/ui.cpp:553-559
if (data->bitAmplitude != nullptr) {
    for (const auto & bAmpl : *data->bitAmplitude) {
        auto wSize = ImGui::GetContentRegionAvail();
        wSize.y = 20;
        ImGui::PlotLines("", bAmpl.data(), data->samplesPerFrame, 0, NULL, -1.0f, 1.0f, wSize);
    }
}
```

**设计要点**：
- **空 label（`""`）**——少画一个标题行，节省垂直空间；tooltip/hover 信息通过其它途径提供。xcom_lua waveform 现在每个 series 都画 `ImGui::Text(series.name)`，可以学习空标签 + 右侧 legend 的紧凑布局。
- **`wSize.y = 20`** 把每个 bit amplitude 行压成 20px 高——密集可视化。
- **`PlotLines` 接 `bAmpl.data()`**——直接裸指针，没 vector 拷贝、没 fmt。

### 2.3 极简主循环

**文件**：`main/main.cpp`
**关键函数**：`main`（行 23-54）+ `update`（行 19-21）

```cpp
// main/main.cpp:17-49
static std::function<bool()> g_update;

void update(void *) {
    g_update();
}

int main(int /*argc*/, char ** argv) {
    CG::Logger::getInstance().configure("data/logger.cfg", "Logger");
    CG_INFO(0, "Capture device name: %s\n", argv[1]);

    App::Parameters params;
    params.windowSizeX = 1200;
    params.windowSizeY = 800;
    params.windowTitle = "Data Transfer Over Sound";
    App app(params);

    g_update = [&]() {
        app.update();
        app.render();
        if (app.shouldTerminate()) return false;
        return true;
    };

#ifdef __EMSCRIPTEN__
    emscripten_set_main_loop_arg(update, NULL, 0, true);
#else
    while (true) { if (g_update() == false) break; }
#endif

    app.terminate();
    return 0;
}
```

```cpp
// main/app.cpp:60-79
void App::update() {
    if (_window->shouldClose()) { _shouldTerminate = true; }
    _window->makeContextActive();
    if (_window->wasWindowSizeChanged()) { _window->updateWindowSize(); }
    _ui->update();
    _core->update();   // ← 后台 Core 线程在这一帧驱动
}

void App::render() const {
    _window->render();
    _ui->render();
    _window->swapBuffers();
}
```

**设计要点**：
- **`g_update` 是 `std::function<bool()>`**——返回 false 表示终止；emscripten 与 native 两路都调它。极简的「主循环抽象」。
- **`update` 和 `render` 严格分离**：`App::update` 拉数据 + UI 输入；`App::render` 只读状态画图。这是 wave-gui 给的最大启发——咱 xcom_lua 现在 ReceiveContent 把 update（绘制 selection + 计算 highlight）和 render 混在一起，可以借鉴这种 split。
- **`Core` 是独立类**——业务逻辑（FFT、调制解调）与 UI 解耦；bridge.cpp 把 xcom_core 当 lib 调用已经做到了，但要确保 UI 侧代码里没有「跑业务」的语句。

### 2.4 有锁 ring buffer（数据生产者-消费者）

**文件**：`src/cg_ring_buffer.h`（行 14-84）

```cpp
// src/cg_ring_buffer.h:37-49
bool push(const TData& item) {
    std::unique_lock<std::mutex> lock(mutex_);
    if (size_ == BufferSize) {
        return false;          // ← 满了直接拒绝，不覆盖
    }
    std::size_t idx = (head_ + size_);
    if (idx >= BufferSize) idx -= BufferSize;
    buffer_[idx] = item;
    ++size_;
    lock.unlock();
    cv_.notify_one();
    return true;
}

TData pop() {
    std::unique_lock<std::mutex> lock(mutex_);
    cv_.wait(lock, [this] {return size_ != 0;});   // ← 没数据时阻塞
    auto position = head_;
    if (++head_ >= BufferSize) head_ -= BufferSize;
    --size_;
    return std::move(buffer_[position]);
}
```

**设计要点**：
- **`cv_.wait(...)` 阻塞 pop**——生产者-消费者模式经典做法；wave-gui Core 线程 push FFT 结果，UI 线程 pop 渲染。xcom_lua 现在 xcom_core → bridge 是**单线程 PumpMessage 轮询**模式（`window.lua`），如果未来要把串口接收移到独立 pthread，这个 ring 就是最小可用样板。
- **满了返回 false 不覆盖**——保护「不丢数据」语义；如果消费者一时没跟上，溢出策略是「丢新」而不是「丢旧」。对调试型串口工具这个语义合适。
- **`push` 后 `lock.unlock(); cv_.notify_one()`**——先释放锁再通知，减少 wake-up contention。

## 3. 可借鉴清单

| 优先级 | 建议 | 当前实现位置（bridge.cpp / waveform.lua） | 实施成本 |
|---|---|---|---|
| **高** | 同一 PlotHistogram 多次叠加 + `SetCursorScreenPos(posSave)` 复用同一坐标画多信号层（信号/阈值/包络/触发线） | `core/waveform.lua` 单一 GDI 折线 | 中：迁移到 ImPlot 后用 `ImPlot::PlotLine` 多层叠加 |
| 高 | lambda 数据源：每点 O(1) 判定决定渲染值，零额外内存 | 无（waveform.lua 是预聚合 points） | 低：ImPlot 可用 `ImPlot::PlotLineG` 或自定义 Getter |
| 高 | `App::update` / `App::render` 严格分离：bridge 当前帧的「拉数据」与「画图」分两步 | `ReceiveContent` 内嵌数据准备 + 绘制（行 778-1127） | 中：需要把 highlight 命中缓存为 phase 1，绘制为 phase 2 |
| 中 | `PushStyleColor(ImGuiCol_FrameBg, 透明)` 让图层叠加干净 | 无 | 低 |
| 中 | 空 label + 右侧 legend 替代每 series 一个标题 | `waveform.lua` M._paint 标题位置（行 380） | 低 |
| 中 | 紧凑行高 `wSize.y = 20` 把多 panel 挤进 1 屏 | ReceiveContent 隐式 `line_h = GetTextLineHeight()` | 低 |
| 中 | `std::function<bool()> g_update` 主循环抽象：update+render+termination check | `window.lua` 的 `run_message_loop` | 低（已有） |
| 中 | Producer-consumer ring + cv，串口 → 渲染分离线程的样板 | 无（waveform.lua 用纯 Lua 表） | 高：仅当 xcom_lua 引入后台 I/O 线程时 |
| 低 | 满了 ring 返回 false 不覆盖：保护「不丢数据」语义 | xcom_core 当前策略需对照 | 低 |
| 低 | `bAmpl.data()` 直接裸指针零拷贝 | waveform.lua 已有 | 无 |
| 低 | ImGuiPlot 用 lambda + 范围条件画「数据段 vs 校验段」双色叠加 | 无 | 低 |
| 低 | `push` 后 `lock.unlock(); notify_one()` 顺序 | 无锁 | 仅当引入多线程时 |
| 低 | 主循环 `update / render / shouldTerminate` 三件事三行函数化 | window.lua 主循环 | 低 |

## 4. 总结

wave-gui 是 4 个项目里**行数最少、结构最干净的**——它给 xcom_lua 的价值不是「抄某个 UI 控件」，而是「**抄一个工程组织的范式**」：
- `update` / `render` 分离；
- `g_update = [&]() { ... return false if terminated; }` 主循环骨架；
- PlotHistogram 多次叠加 + lambda 数据源 = 极简多层可视化。

`core/waveform.lua` 的 Phase 4 改造（计划 ImPlot 内嵌）可以直接照搬 `PlotHistogram` lambda + `SetCursorScreenPos` 模式画「信号 + 包络 + 触发线」三层。
