# SDRPlusPlus UI 参考

> 只读研究文档，对照 `D:\workspace\SSCOM_lua\ref\SDRPlusPlus\` 的源码撰写。
> 所有引用均带真实文件:行号与原文片段。本文档**不修改任何项目代码**。

---

## 1. 项目概览

SDRPlusPlus 是开源跨平台 SDR（软件定义无线电）客户端，栈 = **C++17 + ImGui + OpenGL + 模块化 .so/.dll 插件**。核心 UI 模式：

- **多面板**：左侧 CollapsingHeader 列表 + 中部频谱/瀑布 + 右侧控件柱。
- **瀑布图**：OpenGL 纹理 + ring buffer 滚动 + LUT 调色板 + 鼠标拖拽频段。
- **模块插件**：以 LoadLibraryA/dlopen + dlsym 取 `_INFO_ / _INIT_ / _CREATE_INSTANCE_` 等符号加载。

**与 xcom_lua 的对应**：xcom_lua 当前的"左 receive / send + 180px 右侧 CONNECTION/PROFILE/DISPLAY"双列布局（`xcom_imgui_bridge.cpp:2175-2218`）≈ SDRPlusPlus 早期版本；后续要做"多面板仪表盘重设计"时，可参考 SDRPlusPlus 的瀑布渲染（≈ 加波形/迷你趋势）和插件式菜单注册机制。

---

## 2. 核心实现

### 2.1 三列 ImGui::Columns 框架

`SDRPlusPlus/core/src/gui/main_window.cpp:473-478`：

```cpp
if (showMenu) {
    ImGui::Columns(3, "WindowColumns", false);
    ImGui::SetColumnWidth(0, menuWidth);
    ImGui::SetColumnWidth(1, std::max<int>(winSize.x - menuWidth - (60.0f * style::uiScale), 100.0f * style::uiScale));
    ImGui::SetColumnWidth(2, 60.0f * style::uiScale);
    ImGui::BeginChild("Left Column");
    ...
```

设计要点：
- 三列结构：`menu`（左） / `waterfall`（中） / `waterfallControls`（右）。
- 用户可拖拽中间分隔改变 `menuWidth`，drag 处理在 `main_window.cpp:439-467`，新宽度实时持久化到 JSON。
- 最小宽度 clamp 在 `main_window.cpp:448`：`std::clamp<float>(newWidth, 250, winSize.x - 250)`——保证两列都不被挤垮。
- 当 `showMenu == false`（隐藏菜单）时切换到 `8 + winSize - 60` 的 2 列布局（`:535-538`）。

**对 xcom_lua 的启发**：xcom 当前的 `monitor_column | gap 20 | serial_column` 是固定宽度的两列；如果想做"用户可拖拽 + 三列 + 折叠"，可参考这套 model 化 `Columns` + `BeginChild` + JSON 持久化。

### 2.2 实时瀑布图（waterfall.h/.cpp）

这是最值得抄的核心。`WaterFall` 类（`core/src/gui/widgets/waterfall.h:83-326`）封装一个完整的"FFT ring buffer → 调色板 LUT → GL 纹理 → ImGui::Image"的实时数据流。

#### 2.2.1 OpenGL 纹理上传与脏标记

`core/src/gui/widgets/waterfall.cpp:704-711`：

```cpp
void WaterFall::updateWaterfallTexture() {
    std::lock_guard<std::mutex> lck(texMtx);
    glBindTexture(GL_TEXTURE_2D, textureId);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_MAG_FILTER, GL_LINEAR);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, dataWidth, waterfallHeight, 0, GL_RGBA, GL_UNSIGNED_BYTE, (uint8_t*)waterfallFb);
}
```

设计要点：
- 整个 `waterfallFb` 是 `uint32_t` 数组（HDR 0xAARRGGBB），C++ 侧直接 `clamp → LUT 查表` 写入；只在 dirty 时 `glTexImage2D` 上传一次。
- 通过 `bool waterfallUpdate` 标志（`waterfall.cpp:234`）只在脏时才上传到 GPU；正常帧只 `AddImage` 即可（`waterfall.cpp:208-216`）。
- `pushFFT()` 推入新行时只 `memmove` 一行 + 写新行（`waterfall.cpp:898-905`），不做整张重传。

#### 2.2.2 ring buffer + memmove

`waterfall.cpp:876-887`：

```cpp
float* WaterFall::getFFTBuffer() {
    if (rawFFTs == NULL) { return NULL; }
    buf_mtx.lock();
    if (waterfallVisible) {
        currentFFTLine--;
        fftLines++;
        currentFFTLine = ((currentFFTLine + waterfallHeight) % waterfallHeight);
        fftLines = std::min<float>(fftLines, waterfallHeight);
        return &rawFFTs[currentFFTLine * rawFFTSize];
    }
    return rawFFTs;
}
```

`waterfall.cpp:898`：

```cpp
memmove(&waterfallFb[dataWidth], waterfallFb, dataWidth * (waterfallHeight - 1) * sizeof(uint32_t));
```

设计要点：
- FFT 行索引倒着走（`currentFFTLine--`），新行覆盖在最底/最顶（看语义），整张图通过 `memmove` 平移一帧一行。
- 移位用 `memmove` 不是 `memcpy`——源/目标可能重叠（`waterfall.cpp:898`）。
- 帧索引用 `std::min(fftLines, waterfallHeight)` 钳制，窗口满了就丢弃最老（环形覆盖）。

#### 2.2.3 调色板 LUT 预生成

`waterfall.cpp:944-958`：

```cpp
void WaterFall::updatePallette(float colors[][3], int colorCount) {
    std::lock_guard<std::recursive_mutex> lck(buf_mtx);
    for (int i = 0; i < WATERFALL_RESOLUTION; i++) {
        int lowerId = floorf(((float)i / (float)WATERFALL_RESOLUTION) * colorCount);
        int upperId = ceilf(((float)i / (float)WATERFALL_RESOLUTION) * colorCount);
        ...
        float r = (colors[lowerId][0] * (1.0 - ratio)) + (colors[upperId][0] * (ratio));
        ...
        waterfallPallet[i] = ((uint32_t)255 << 24) | ((uint32_t)b << 16) | ((uint32_t)g << 8) | (uint32_t)r;
    }
    updateWaterfallFb();
}
```

设计要点：
- `WATERFALL_RESOLUTION = 1000000`（`waterfall.h:11`）：把 0..1 量化成 1 M 步颜色。
- 调色板改一次 → 重建 LUT + 重画 waterfallFb；查表 O(1)。
- 颜色文件（`colormaps/*.json`）→ 在 `main_window.cpp:148-159` 启动时扫描加载。

#### 2.2.4 ImGui::AddImage 一行调用渲染

`waterfall.cpp:208-216`：

```cpp
void WaterFall::drawWaterfall() {
    if (waterfallUpdate) {
        waterfallUpdate = false;
        updateWaterfallTexture();
    }
    {
        std::lock_guard<std::mutex> lck(texMtx);
        window->DrawList->AddImage((void*)(intptr_t)textureId, wfMin, wfMax);
    }
    ...
```

设计要点：
- 整个 waterfall 只产生 **1 个 ImGui draw call**（不是每像素一个）。即便纹理内部 600×500 = 30 万像素，UI 线程只下发一次纹理 quad。
- 与之对比，FFT 曲线（`drawFFT()` 162-205）是逐像素 `AddLine`，但 dataWidth = 600，所以只有 ~600 个 draw call，可接受。

**对 xcom_lua 的启发**：
- receive_text 的滚动条 + clipper 已经是"按行切片"，再想加一个迷你趋势（接收速率 sparkline）时，不要逐像素 AddLine，而是预生成一张 OpenGL 纹理 + memmove 一行。
- 调色板 LUT 思路对 Lua 也很友好：在 C++ 侧预生成 `uint32_t palette[256]`，每收到一个字节直接 `fb[i] = palette[v]`。

### 2.3 模块插件加载机制

#### 2.3.1 模块管理器（module.cpp / module.h）

`core/src/module.cpp:5-84`：

```cpp
ModuleManager::Module_t ModuleManager::loadModule(std::string path) {
    Module_t mod;
#ifdef _WIN32
    mod.handle = LoadLibraryA(path.c_str());
    if (mod.handle == NULL) { ... return mod; }
    mod.info = (ModuleInfo_t*)GetProcAddress(mod.handle, "_INFO_");
    mod.init = (void (*)())GetProcAddress(mod.handle, "_INIT_");
    mod.createInstance = (Instance * (*)(std::string)) GetProcAddress(mod.handle, "_CREATE_INSTANCE_");
    mod.deleteInstance = (void (*)(Instance*))GetProcAddress(mod.handle, "_DELETE_INSTANCE_");
    mod.end = (void (*)())GetProcAddress(mod.handle, "_END_");
#else
    mod.handle = dlopen(path.c_str(), RTLD_LAZY | RTLD_LOCAL);
    ...
    mod.info = (ModuleInfo_t*)dlsym(mod.handle, "_INFO_");
    ...
#endif
    if (mod.info == NULL) { flog::error(...); return mod; }
    if (mod.init == NULL) ...
    mod.init();
    modules[mod.info->name] = mod;
    return mod;
}
```

设计要点：
- **符号契约**：`module.h` 定义 5 个固定名字（`_INFO_ / _INIT_ / _CREATE_INSTANCE_ / _DELETE_INSTANCE_ / _END_`），插件作者必须导出全部。
- `_INFO_` 返回静态 `ModuleInfo_t`（含 `name` / `maxInstances` / `description`），不分配、不依赖运行时。
- `_CREATE_INSTANCE_(name)` 在每次实例化时调用一次，分配 `Instance*`。
- 用 `RTLD_LAZY | RTLD_LOCAL`：按需解析 + 不污染全局符号（避免多个插件符号冲突）。

#### 2.3.2 启动扫描 + 持久化

`core/src/gui/main_window.cpp:100-143`：

```cpp
if (std::filesystem::is_directory(modulesDir)) {
    for (const auto& file : std::filesystem::directory_iterator(modulesDir)) {
        std::string path = file.path().generic_string();
        if (file.path().extension().generic_string() != SDRPP_MOD_EXTENTSION) continue;
        if (!file.is_regular_file()) continue;
        core::moduleManager.loadModule(path);
    }
}
// Read module config
core::configManager.acquire();
std::vector<std::string> modules = core::configManager.conf["modules"];
auto modList = core::configManager.conf["moduleInstances"].items();
core::configManager.release();
// Load additional modules specified through config
for (auto const& path : modules) { core::moduleManager.loadModule(path); }
// Create module instances
for (auto const& [name, _module] : modList) {
    core::moduleManager.createInstance(name, _module["module"]);
    if (!_module["enabled"]) core::moduleManager.disableInstance(name);
}
```

设计要点：
- **两层配置**：`modulesDirectory` 扫描目录里的 `.so/.dll` + `modules` 数组（显式路径）。
- **实例持久化**：`moduleInstances[name].{module, enabled}` 保存每个实例的模块名 + 启用状态，下次启动按 JSON 重建。
- `core::moduleManager.doPostInitAll()`（`module.cpp:181-186`）：所有实例化完成后做联动初始化（如交叉订阅）。

#### 2.3.3 插件菜单注册（widgets/menu.cpp）

`core/src/gui/widgets/menu.h:9-49`：

```cpp
class Menu {
public:
    struct MenuItem_t {
        void (*drawHandler)(void* ctx);
        void* ctx;
        ModuleManager::Instance* inst;
    };
    void registerEntry(std::string name, void (*drawHandler)(void* ctx),
                      void* ctx = NULL, ModuleManager::Instance* inst = NULL);
    bool draw(bool updateStates);
    std::vector<MenuOption_t> order;
};
```

`menu.cpp:9-21`：

```cpp
void Menu::registerEntry(std::string name, void (*drawHandler)(void* ctx),
                         void* ctx, ModuleManager::Instance* inst) {
    MenuItem_t item;
    item.drawHandler = drawHandler;
    item.ctx = ctx;
    item.inst = inst;
    items[name] = item;
    if (!isInOrderList(name)) {
        MenuOption_t opt;
        opt.name = name;
        opt.open = true;
        order.push_back(opt);
    }
}
```

设计要点：
- **回调式注册**：每个模块启动时调用 `gui::menu.registerEntry("Name", draw_fn, ctx, &instance)`。
- **顺序持久化**：`order` 是 `vector<MenuOption_t>`（name + open 状态），按用户拖拽顺序保存到 JSON 的 `menuElements` 数组。
- **拖拽重排序**：`menu.cpp:38-209` 是 ~170 行 ImGui 拖拽 + 插入指示线实现；每个 header 的 y 坐标记录在 `headerTops[]`，鼠标坐标比较决定 `insertBefore`。
- **核心思想**：菜单本身没有 UI 控件，只是个**注册表**；具体控件由回调绘制（这样插件和内置菜单共用同一套 CollapsingHeader 渲染）。

**对 xcom_lua 的启发**：
- 当前 xcom 的 `script_engine.lua` 是纯 Lua 脚本（`xcom_lua/core/script_engine.lua`）；Phase 4 计划"DLL 端高亮渲染"恰好就是 SDRPlusPlus 的插件模型。
- 可以设计一套 `xcom_panel_register(name, draw_fn, ctx)` 镜像 `Menu::registerEntry`，让 Lua 侧也能挂载自定义面板进主仪表盘。
- 持久化 `menuElements`（含 `open` 状态）→ 把每个面板的折叠状态写到 config.json，下次启动复原。

### 2.4 事件总线 Event<T>

`SDRPlusPlus/core/src/utils/event.h`（未在本次搜索中读全文，但从 usage 反推）：

`waterfall.h:182`：
```cpp
Event<FFTRedrawArgs> onFFTRedraw;
Event<InputHandlerArgs> onInputProcess;
```

`waterfall.cpp:196`：
```cpp
onFFTRedraw.emit(args);
```

设计要点：
- 瀑布图自己**不处理 VFO 拖拽**，而是通过 `Event<InputHandlerArgs> onInputProcess.emit(args)` 让外面（VFO manager / demod 模块）决定怎么响应。
- 同样 `processInputs()` 是默认实现，外层可以 `inputHandled = true` 跳过（`waterfall.cpp:840-855`）。

**对 xcom_lua 的启发**：xcom 的 receive_text → Lua 回调目前是单向 push；如果以后做"插件能拦截接收事件"，可以提供 `Event` 风格的总线（Lua 侧 `xcom.on_receive.add(function(...) end)`）。

---

## 3. 可借鉴清单

| # | 优先级 | 建议 | 当前 xcom_lua 位置 | 实施成本 |
|---|---|---|---|---|
| 1 | 高 | 用 GL 纹理 + memmove 实现迷你趋势 sparkline，避免逐像素 AddLine | `bridge.cpp:2130-2233` 暂无 mini-chart；可在 monitor_column 顶部加 | 中（需要 OpenGL 子系统） |
| 2 | 高 | `Columns(N, ...)` + BeginChild 三列布局 + 用户拖拽分隔 + JSON 持久化列宽 | `bridge.cpp:2175-2218` 双列 → 三列 | 低 |
| 3 | 高 | 每个面板的"折叠/展开/顺序"持久化（参考 `menuElements` JSON 数组） | 当前每帧都是 hardcoded `Begin/End`；需重构为注册表 | 中 |
| 4 | 中 | 面板注册表抽象：`registerEntry(name, draw_fn, ctx, open)` | `script_engine.lua` 已有 Lua 侧注册，可镜像到 C++ 侧 `xcom_panel.h` | 中 |
| 5 | 中 | 调色板 LUT 预生成（接收字节 → 颜色查找表），避免运行时颜色计算 | receive_text 暂无颜色 LUT | 低 |
| 6 | 中 | Ring buffer memmove + 脏标志：只在数据变化时 `glTexImage2D`，否则只 `AddImage` | receive_text 现在每帧重画 | 中 |
| 7 | 中 | VFO/Event 模式：组件之间通过 `Event<T>` 解耦，外部模块可拦截/修改事件 | xcom_lua 当前 C↔Lua 是直接 ABI，无事件总线 | 中 |
| 8 | 中 | 拖拽分隔宽度 clamp 在 `[250, winSize.x - 250]`，保留最小列宽 | `bridge.cpp:2167-2169` 已 clamp 但只在 compact 模式 | 低 |
| 9 | 中 | OpenGL 资源 lazy 初始化（`init()` 单独调用，不在构造函数里调 OpenGL） | `waterfall.cpp:116-118` 在 init 中 glGenTextures | 低 |
| 10 | 中 | Recursive mutex + 短临界区：FFT push 与 draw 通过 std::lock_guard 同步，但 lock 不跨帧 | 当前 xcom 用 `owner_thread_` 强约束 | 低 |
| 11 | 低 | 鼠标 hover 高亮区域预计算（在 updateAllVFOs 而非 draw 中算坐标） | `waterfall.cpp:1118-1132` 一次性算 wfRectMin/Max，draw 时直接用 | 低 |
| 12 | 低 | 频段选择点击范围用 `ButtonBehavior` 自定义热区而不是纯 hit test | `waterfall.cpp:260-261` ButtonBehavior + ImGuiButtonFlags_PressedOnClick | 低 |
| 13 | 低 | `lockWaterfallControls` 标志让其他窗口（credits）屏蔽下层输入 | `main_window.cpp:436-437` | 低 |
| 14 | 低 | 暗色模式主题存 JSON，运行时切换不用重新编译 | `core/src/gui/theme_manager.*`（未细读） | 中 |
| 15 | 低 | "Debug"折叠面板内置帧时间显示（`Frame time: %.3f ms/frame`） | `main_window.cpp:504-511` | 低 |

---

## 4. 一句话总结

SDRPlusPlus 给 xcom_lua 的核心可抄价值是：**三件事**：
1. **瀑布/趋势图**——OpenGL 纹理 + ring buffer memmove + 脏标志，单 draw call 渲染整张。
2. **面板注册表 + 顺序持久化**——`registerEntry` + JSON `menuElements` 让插件能挂 UI，且刷新不掉顺序。
3. **可拖拽多列布局**——`Columns` + 持久化列宽 + clamp 最小宽度。