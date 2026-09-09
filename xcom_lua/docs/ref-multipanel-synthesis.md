# 多面板仪表盘重设计 — 参考项目综合分析

> 读完 `SDRPlusPlus/`（实时瀑布 + 多面板 dock）与 `tracy/`（高密度 profiler 仪表盘）后，提炼出 xcom_lua 可抄的核心模式、优先级最高 5 条建议、以及落地顺序。本文档**不修改任何项目代码**。

---

## 一、两个项目共提炼的核心模式

两个项目虽然用途完全不同，但都在追求"多面板 + 实时数据 + 不掉帧"——可总结为 **5 个共通模式**：

### 1. **面板注册表 + 持久化顺序**
- SDRPlusPlus `Menu::registerEntry(name, fn, ctx)`（`menu.cpp:9-21`） + JSON `menuElements` 数组。
- tracy 的 `TimelineController::AddItem<TimelineItemPlot>(v)`（`TracyView_Timeline.cpp:396`）+ 内部 `m_items` vector。
- 共通思路：**面板不是 hardcoded 的 Begin/End，而是注册项；顺序/折叠状态持久化**。

### 2. **两遍渲染：Preprocess + Draw**
- tracy 是教科书：`TimelineController::End`（`TracyTimelineController.cpp:102-177`）先全部 panel 跑 `Preprocess`（多线程 + TaskDispatch），再全部 panel 跑 `Draw`。
- SDRPlusPlus waterfall 的 `updateWaterfallFb()`（`waterfall.cpp:600-631`）→ `updateWaterfallTexture()`（`waterfall.cpp:704-711`）→ `drawWaterfall()`（`waterfall.cpp:208-216`），三阶段：算像素、上传 GPU、ImGui 渲染。
- 共通思路：**重计算从 draw 阶段剥离**。

### 3. **桶化（min/max）降量保留极端信息**
- tracy `Plot::Preprocess`（`TracyTimelineItemPlot.cpp:213-247`）：256 sample 桶化 + pdqsort 取 min/max。
- SDRPlusPlus waterfall `doZoom`（`waterfall.cpp:65-90`）：按像素列取 max。
- 共通思路：**屏幕宽度就是桶数，每桶只画 min/max**——视觉无损、性能大幅提升。

### 4. **脏标志 + 资源懒初始化**
- SDRPlusPlus waterfall：`bool waterfallUpdate`（`waterfall.cpp:234`），pushFFT 后置 true，draw 时若 false 跳过 `glTexImage2D`。
- tracy：`m_firstFrame`（`TracyTimelineController.cpp:39`）控制首帧特判；`m_draw.clear()`（`TracyTimelineItemPlot.cpp:120`）每帧后清缓存。
- 共通思路：**渲染 = 状态机，脏则更新，否则跳过**。

### 5. **GL 纹理单 draw call 渲染**
- SDRPlusPlus waterfall 用 OpenGL 纹理 + `AddImage` 一次画整张瀑布。
- tracy 用 `AddPolyline` 把 N 个连续线段合批（`TracyImGui.hpp:281`）。
- 共通思路：**不要逐像素 AddLine，预生成纹理/合批线段**。

---

## 二、优先级最高的 5 条建议

| 优先级 | 建议 | 当前 xcom_lua 位置 | 实施成本 |
|---|---|---|---|
| **P0** | 引入面板注册表抽象 `xcom_panel_register(name, draw_fn, ctx, open)`，镜像 SDRPlusPlus `Menu` + tracy `TimelineItem` 模式 | `script_engine.lua` 是 Lua 侧注册；C++ 侧暂无 | 中 |
| **P0** | 拆 ReceiveContent 为两遍：preprocess 算可见行区间 + offset 缓存，draw 阶段只解码 | `bridge.cpp:2178-2190` 单遍 | 中 |
| **P1** | 加一个迷你趋势 sparkline（接收字节/秒），用 GL 纹理 + ring buffer memmove + min/max 桶化 | 暂无 | 中 |
| **P1** | `AddPolyline` 替代 `AddLine` 批量绘制；栈 ImVec2 数组零拷贝 | `bridge.cpp:2202-2205` 等 | 低 |
| **P2** | 面板顺序/折叠状态持久化到 config.json（参考 `menuElements`） | 暂无 config | 中 |

---

## 三、实施顺序

按"投入产出比"和"渐进不破坏现有结构"排序：

1. **第一波（性能优化）—— 1 周**
   - `AddPolyline` 替代 `AddLine`（P1 第 4 条）；高风险低。
   - `std::lower_bound` 二分定位 receive 行区间（P1 第 5 条 tracy 借鉴清单）。
   - 给高频 helper 加 `__forceinline`。
   - 验证不破坏现有 `bridge.cpp:2130-2233` 双列布局。

2. **第二波（趋势 sparkline）—— 2 周**
   - 在 monitor_column 顶部加一条 40px 高的 sparkline。
   - 实现 `ring_buffer[2048]` + 每秒采样 memmove 一格。
   - OpenGL 纹理上传 + 单 `AddImage` 渲染（SDRPlusPlus 借鉴）。
   - 调色板 LUT（冷蓝色→热红色，参考 `waterfall.cpp:944-958`）。

3. **第三波（面板注册表）—— 3 周**
   - 新建 `xcom_lua/core/xcom_panel.h`：暴露 `xcom_panel_register` / `xcom_panel_unregister` 给 DLL/插件。
   - C++ 侧镜像 SDRPlusPlus `Menu::registerEntry`：`std::vector<PanelEntry>` 持有 `(name, draw_fn, ctx, open)`。
   - 重构 `bridge.cpp:2175-2218`：monitor/serial/footer 都通过注册表绘制。
   - JSON 持久化 `panels` 数组（折叠状态 + 顺序）。

4. **第四波（多线程 Preprocess）—— 选做**
   - 若第三波后 ReceiveContent 仍然卡顿，参考 tracy `TaskDispatch`（`TracyTimelineController.cpp:25`）拆 Preprocess 到工作线程。
   - 但 xcom 单窗口单面板场景下，第二波做完已经够用，第四波可暂缓。

---

## 四、风险与权衡

- **GL 纹理方案依赖 OpenGL**：当前 xcom_lua 是 Win32 + ImGui（dx11/dx12/wgpu 都可能）；如果切换到无 GL 后端，sparkline 退化为 ImGui::AddPolyline（合批 N 点而非单 draw call），仍可用但略慢。
- **面板注册表抽象会让 Lua 插件能挂任意 UI**——是好事也意味着要小心 Lua sandbox（防止插件在主线程卡住）。
- **JSON 持久化增加配置 schema 复杂度**——但 SDRPlusPlus 用同一套 nlohmann::json 持菜单/列宽/插件实例，加一个面板数组只是 schema 扩展。

---

## 五、相关参考文档

- `D:\workspace\SSCOM_lua\xcom_lua\docs\sdrplusplus-ui-reference.md` — SDRPlusPlus 详解
- `D:\workspace\SSCOM_lua\xcom_lua\docs\tracy-ui-reference.md` — tracy 详解
- `D:\workspace\SSCOM_lua\xcom_lua\docs\imgui-patterns-reference.md` — ImGui 模式速查
- `D:\workspace\SSCOM_lua\xcom_lua\docs\imhex-ui-reference.md` — ImHex 多面板布局借鉴