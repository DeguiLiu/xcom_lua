#include <windows.h>
#include <GL/gl.h>
#include <algorithm>
#include <string>
#include <string_view>
#include <functional>
#include <fstream>
#include <cstdlib>
#include <type_traits>
#include <utility>
#include <vector>
#include <array>
#include <cstdint>

#include "imgui.h"
#include "imgui_impl_opengl2.h"
#include "imgui_impl_win32.h"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(
    HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);
extern IMGUI_IMPL_API bool ImGui_ImplWin32_InitForOpenGL(void* hwnd);

namespace {
struct LayoutConfig final {
    static constexpr size_t kFieldCount = 10U;
    static constexpr float kSidebarWidth = 194.0f;
    static constexpr float kCompactThreshold = 760.0f;
    static constexpr float kReceiveHeight = 0.0f;
    static constexpr float kSendHeight = 212.0f;
    static constexpr float kHeaderHeight = 46.0f;
    static constexpr float kPanelGap = 6.0f;
    static constexpr float kWindowPadding = 8.0f;
    static constexpr float kItemSpacing = 7.0f;
    static constexpr float kFramePaddingY = 4.0f;
    static constexpr float kSectionGap = 4.0f;

    float sidebar_width = kSidebarWidth;
    float compact_threshold = kCompactThreshold;
    float receive_height = kReceiveHeight;
    float send_height = kSendHeight;
    float header_height = kHeaderHeight;
    float panel_gap = kPanelGap;
    float window_padding = kWindowPadding;
    float item_spacing = kItemSpacing;
    float frame_padding_y = kFramePaddingY;
    float section_gap = kSectionGap;
};
static_assert(LayoutConfig::kSidebarWidth > 0.0f);
static_assert(LayoutConfig::kSendHeight >= 140.0f);

template <typename T>
class Slice final {
public:
    constexpr Slice(const T* data, size_t size) noexcept : data_(data), size_(size) {}
    constexpr const T* begin() const noexcept { return data_; }
    constexpr const T* end() const noexcept { return size_ == 0 ? data_ : data_ + size_; }
    constexpr size_t size() const noexcept { return size_; }
    constexpr bool empty() const noexcept { return size_ == 0; }
private:
    const T* data_;
    size_t size_;
};

class ActionObserver final {
public:
    using Callback = std::function<void(int)>;
    void subscribe(Callback callback) { observers_.emplace_back(std::move(callback)); }
    void publish(int actions) const {
        if (actions == 0) return;
        for (const auto& observer : observers_) observer(actions);
    }
private:
    std::vector<Callback> observers_;
};

class ImGuiRuntime final {
public:
    static ImGuiRuntime& instance() {
        static ImGuiRuntime runtime;
        return runtime;
    }

    // Plain data members — no getter/setter ceremony.  This is a process-wide
    // singleton confined to this translation unit, so direct field access is
    // clearer than a dozen trivially-returning accessors (see MEMORY.md:
    // "avoid abstractions that don't reduce copies/branches/lifetime bugs").
    ActionObserver actions_;
    std::vector<std::string> ports_;
    int observed_actions_ = 0;
    HDC hdc_ = nullptr;
    HGLRC glrc_ = nullptr;
    HWND hwnd_ = nullptr;
    DWORD owner_thread_ = 0;
    bool initialized_ = false;
    bool frame_active_ = false;
    ImFont* heading_font_ = nullptr;
    LayoutConfig layout_{};

    int dispatch(int actions) {
        actions_.publish(actions);
        return std::exchange(observed_actions_, 0);
    }
    void reset() {
        actions_ = ActionObserver{};
        observed_actions_ = 0;
        actions_.subscribe([this](int actions) { observed_actions_ |= actions; });
    }
};
enum class Action : std::uint32_t {
    ActionOpen = 1 << 0,
    ActionClose = 1 << 1,
    ActionClear = 1 << 2,
    ActionSend = 1 << 3,
    ActionSaveLog = 1 << 4,
    ActionSendEnabled = 1 << 5,
    ActionRefreshPorts = 1 << 6,
    ActionSyncSettings = 1 << 7,
    ActionSyncDisplay = 1 << 8,
    ActionPreviousPage = 1 << 9,
    ActionNextPage = 1 << 10,
    ActionAddPage = 1 << 11,
    ActionRemovePage = 1 << 12,
    ActionSyncMultiAuto = 1 << 13,
    ActionSyncAutoSave = 1 << 14,
    ActionChooseLogPath = 1 << 15,
    ActionMinimizeWindow = 1 << 16,
    ActionMaximizeWindow = 1 << 17,
    ActionCloseWindow = 1 << 18,
};

constexpr int action_mask(const Action action) noexcept {
    return static_cast<int>(action);
}

constexpr int& operator|=(int& value, const Action action) noexcept {
    value |= action_mask(action);
    return value;
}

static_assert(action_mask(Action::ActionOpen) == (1 << 0));
static_assert(action_mask(Action::ActionCloseWindow) == (1 << 18));

template <Action ActionValue>
struct Command final {
    template <typename Invocable, typename... Args>
    [[nodiscard]] static int Execute(Invocable&& invocable, Args&&... args) {
        static_assert(std::is_invocable_r_v<bool, Invocable, Args...>,
                      "UI commands must invoke a bool-returning control");
        return std::invoke(std::forward<Invocable>(invocable), std::forward<Args>(args)...)
            ? action_mask(ActionValue) : 0;
    }
};
ImVec4 color(float r, float g, float b, float a = 1.0f) { return ImVec4(r, g, b, a); }
ImVec4 rgb(unsigned int value, float alpha = 1.0f) {
    return color(((value >> 16) & 0xff) / 255.0f, ((value >> 8) & 0xff) / 255.0f,
                 (value & 0xff) / 255.0f, alpha);
}

namespace ui {
class PanelScope final {
public:
    PanelScope(const char* id, const ImVec2& size, bool border,
               ImGuiWindowFlags flags, const ImVec4& background)
        : visible_(false) {
        ImGui::PushStyleColor(ImGuiCol_ChildBg, background);
        visible_ = ImGui::BeginChild(id, size, border, flags);
        ImGui::PopStyleColor();
    }
    ~PanelScope() { ImGui::EndChild(); }
    PanelScope(const PanelScope&) = delete;
    PanelScope& operator=(const PanelScope&) = delete;
    explicit operator bool() const { return visible_; }
private:
    bool visible_;
};

template <typename DrawFn>
class StyleDecorator final {
public:
    StyleDecorator(ImGuiStyleVar style_var, float style_value,
                   DrawFn draw_fn)
        : style_var_(style_var), style_value_(style_value), draw_fn_(std::move(draw_fn)) {}
    template <typename... Args>
    decltype(auto) operator()(Args&&... args) {
        ImGui::PushStyleVar(style_var_, style_value_);
        struct PopStyle final {
            ~PopStyle() { ImGui::PopStyleVar(); }
        } pop_style;
        return std::invoke(draw_fn_, std::forward<Args>(args)...);
    }
private:
    ImGuiStyleVar style_var_;
    float style_value_;
    DrawFn draw_fn_;
};

template <typename DrawFn>
StyleDecorator(ImGuiStyleVar, float, DrawFn) -> StyleDecorator<DrawFn>;

template <typename DrawFn>
auto WithRounding(float radius, DrawFn&& draw_fn) {
    return StyleDecorator(ImGuiStyleVar_FrameRounding, radius,
                          std::forward<DrawFn>(draw_fn));
}

// Pushes the heading font (when configured) and pops it on scope exit, so the
// PushFont/PopFont pair stays balanced even on an early return or exception.
// Mirrors the RAII discipline of PanelScope / StyleDecorator above.
class ScopedHeadingFont final {
public:
    explicit ScopedHeadingFont(bool enabled) : active_(enabled) {
        if (active_) ImGui::PushFont(ImGuiRuntime::instance().heading_font_);
    }
    ~ScopedHeadingFont() {
        if (active_) ImGui::PopFont();
    }
    ScopedHeadingFont(const ScopedHeadingFont&) = delete;
    ScopedHeadingFont& operator=(const ScopedHeadingFont&) = delete;
private:
    bool active_;
};

// Minimal zero-allocation scope guard that runs a pop/close callable on scope
// exit.  Used to balance ImGui push/pop and Begin/End pairs (e.g. EndChild,
// PopStyleColor) without the heap-indirection of std::function.
template <typename PopFn>
class ScopedAction final {
public:
    explicit ScopedAction(PopFn&& pop) : pop_(std::move(pop)) {}
    ~ScopedAction() { pop_(); }
    ScopedAction(const ScopedAction&) = delete;
    ScopedAction& operator=(const ScopedAction&) = delete;
private:
    PopFn pop_;
};

PanelScope Panel(const char* id, const ImVec2& size, bool border = true,
                 ImGuiWindowFlags flags = 0, ImVec4 background = ImVec4(0.95f, 0.97f, 0.98f, 1.0f)) {
    return PanelScope(id, size, border, flags, background);
}

void Section(std::string_view title, std::string_view subtitle = {}, bool separator = true) {
    ScopedHeadingFont heading(ImGuiRuntime::instance().heading_font_ != nullptr);
    ImGui::TextColored(rgb(0x008080), "%.*s", static_cast<int>(title.size()), title.data());
    if (!subtitle.empty() && ImGui::GetContentRegionAvail().x >=
        ImGui::CalcTextSize(title.data(), title.data() + title.size()).x +
        ImGui::CalcTextSize(subtitle.data(), subtitle.data() + subtitle.size()).x + 16.0f) {
        ImGui::SameLine();
        ImGui::TextDisabled("%.*s", static_cast<int>(subtitle.size()), subtitle.data());
    } else if (!subtitle.empty()) {
        ImGui::TextDisabled("%.*s", static_cast<int>(subtitle.size()), subtitle.data());
    }
    if (separator) ImGui::Separator();
}

void Field(std::string_view label) {
    ImGui::TextColored(rgb(0x5A6B7A), "%.*s", static_cast<int>(label.size()), label.data());
}

struct ComboSpec final {
    const char* id;
    const char* label;
    int* value;
    const char* const* items;
    int count;
};

[[nodiscard]] bool ComboField(const ComboSpec& spec) {
    Field(spec.label);
    ImGui::SetNextItemWidth(-1.0f);
    return ImGui::Combo(spec.id, spec.value, spec.items, spec.count);
}

bool Toggle(const char* label, int* value);
bool PrimaryAction(const char* label, const ImVec2& size);
void EmptyState(std::string_view title, std::string_view detail);

void Header(int& actions, const bool connected) {
    ImGui::PushStyleColor(ImGuiCol_ChildBg, rgb(0x1E1E1E));
    // RAII pops: declared push-order so destructors run the reverse (pop order),
    // keeping every ImGui stack balanced even on an early return/exception.
    ScopedAction pop_child_bg([] { ImGui::PopStyleColor(); });
    auto& runtime = ImGuiRuntime::instance();
    const auto& layout = runtime.layout_;
    ImGui::BeginChild("##app_header", ImVec2(0, layout.header_height), false,
                      ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
    ScopedAction end_child([] { ImGui::EndChild(); });
    const ImVec2 position = ImGui::GetWindowPos();
    ImDrawList* const draw_list = ImGui::GetWindowDrawList();
    draw_list->AddRectFilled(ImVec2(position.x + 12.0f, position.y + 10.0f),
                             ImVec2(position.x + 36.0f, position.y + 34.0f),
                             ImGui::GetColorU32(rgb(0x009999)), 3.0f);
    ImGui::SetCursorPos(ImVec2(19.0f, 11.0f));
    ImGui::TextColored(rgb(0xFFFFFF), "X");
    ImGui::SetCursorPos(ImVec2(44.0f, 9.0f));
    {
        ScopedHeadingFont heading(ImGuiRuntime::instance().heading_font_ != nullptr);
        ImGui::TextColored(rgb(0xFFFFFF), "XCOM");
    }
    ImGui::SetCursorPos(ImVec2(44.0f, 26.0f));
    ImGui::TextColored(rgb(0xCDEBFA), "SERIAL CONSOLE");
    const char* const status = connected ? "ONLINE" : "OFFLINE";
    const float status_width = ImGui::CalcTextSize(status).x + 20.0f;
    ImGui::SetCursorPos(ImVec2(ImGui::GetWindowWidth() - status_width - 12.0f, 15.0f));
    ImGui::TextColored(connected ? rgb(0x7AD8D8) : rgb(0xFFD28A), "%s", status);
    ImGui::SetCursorPos(ImVec2(ImGui::GetWindowWidth() - 108.0f, 8.0f));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, 2.0f);
    ImGui::PushStyleColor(ImGuiCol_Button, rgb(0x1E1E1E));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, rgb(0x106EBE));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, rgb(0x005A9E));
    ImGui::PushStyleColor(ImGuiCol_Text, rgb(0xFFFFFF));
    ScopedAction pop_buttons([] { ImGui::PopStyleColor(4); ImGui::PopStyleVar(); });
    actions |= Command<Action::ActionMinimizeWindow>::Execute(
        [] { return ImGui::Button("-", ImVec2(30.0f, 28.0f)); });
    ImGui::SameLine(0.0f, 2.0f);
    actions |= Command<Action::ActionMaximizeWindow>::Execute(
        [] { return ImGui::Button("+", ImVec2(30.0f, 28.0f)); });
    ImGui::SameLine(0.0f, 2.0f);
    actions |= Command<Action::ActionCloseWindow>::Execute(
        [] { return ImGui::Button("x", ImVec2(30.0f, 28.0f)); });
    const float width = ImGui::GetWindowWidth();
    draw_list->AddRectFilled(ImVec2(position.x, position.y + layout.header_height - 3.0f),
                             ImVec2(position.x + width, position.y + layout.header_height),
                             ImGui::GetColorU32(rgb(0x009999)));
}

void ReceiveToolbar(int& actions, int rx_bytes, int tx_bytes, int* receive_hex,
                   int* timestamp, int* pause_display, int* auto_clear,
                   int* auto_clear_bytes, int* auto_save) {
    ImGui::Separator();
    if (ImGui::BeginTable("##receive_toolbar", 3, ImGuiTableFlags_SizingStretchProp)) {
        ImGui::TableNextColumn();
        if (Toggle("HEX", receive_hex)) actions |= Action::ActionSyncDisplay;
        ImGui::SameLine(0.0f, 8.0f);
        if (Toggle("Timestamp", timestamp)) actions |= Action::ActionSyncDisplay;
        ImGui::TableNextColumn();
        if (Toggle("Pause", pause_display)) actions |= Action::ActionSyncDisplay;
        ImGui::SameLine(0.0f, 8.0f);
        ImGui::TextDisabled("RX %d  /  TX %d", rx_bytes, tx_bytes);
        ImGui::TableNextColumn();
        actions |= Command<Action::ActionClear>::Execute([] { return ImGui::SmallButton("Clear"); });
        ImGui::SameLine(0.0f, 8.0f);
        actions |= Command<Action::ActionSaveLog>::Execute([] { return ImGui::SmallButton("Save log"); });
        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::Dummy(ImVec2(0, 1));
        ImGui::TableNextColumn();
        if (Toggle("Auto clear", auto_clear)) actions |= Action::ActionSyncDisplay;
        ImGui::SameLine(0.0f, 8.0f);
        ImGui::SetNextItemWidth(64.0f);
        if (ImGui::InputInt("##clear_bytes", auto_clear_bytes, 0, 0)) actions |= Action::ActionSyncDisplay;
        ImGui::SameLine(0.0f, 6.0f);
        ImGui::TextDisabled("bytes");
        ImGui::TableNextColumn();
        if (Toggle("Auto save", auto_save)) actions |= Action::ActionSyncAutoSave;
        ImGui::SameLine(0.0f, 8.0f);
        actions |= Command<Action::ActionChooseLogPath>::Execute(
            [] { return ImGui::SmallButton("Log path..."); });
        ImGui::EndTable();
    }
}

struct ToggleSpec final {
    const char* label;
    int* value;
    Action action;
};

template <size_t Count>
void RenderToggles(int& actions, const std::array<ToggleSpec, Count>& specs) {
    for (size_t index = 0; index < specs.size(); ++index) {
        if (index != 0) ImGui::SameLine();
        const ToggleSpec& spec = specs[index];
        if (Toggle(spec.label, spec.value)) actions |= spec.action;
    }
}

int ReceiveContent(int rx_bytes, int tx_bytes, int* receive_hex, int* timestamp,
                   int* pause_display, int* auto_clear, int* auto_clear_bytes,
                   int* auto_save, const char* receive_text, size_t receive_length) {
    int actions = 0;
    ReceiveToolbar(actions, rx_bytes, tx_bytes, receive_hex, timestamp, pause_display,
                   auto_clear, auto_clear_bytes, auto_save);
    const auto& layout = ImGuiRuntime::instance().layout_;
    const auto receive = Panel("##receive", ImVec2(0, layout.receive_height == 0.0f ? -228.0f : layout.receive_height), true,
                               ImGuiWindowFlags_HorizontalScrollbar, rgb(0xF7F9FB));
    if (receive_text && receive_length) {
        ImGui::TextUnformatted(receive_text, receive_text + receive_length);
        if (ImGui::GetIO().KeyCtrl && ImGui::IsKeyPressed(ImGuiKey_A)) ImGui::SetScrollHereY(1.0f);
    } else {
        EmptyState("WAITING FOR SERIAL DATA", "Select a port, then open the connection to begin monitoring.");
    }
    return actions;
}

int TransmitContent(int* send_hex, int* send_crlf, int* send_auto, int* send_period,
                    char* send_text, size_t send_capacity, char* multi_text,
                    size_t multi_slot_capacity, int* multi_enabled, int* multi_hex,
                    int* multi_crlf, int* multi_page, int* multi_page_count,
                    int* multi_auto, int* multi_period) {
    int actions = 0;
    if (ImGui::BeginTabBar("##transmit_tabs")) {
        if (ImGui::BeginTabItem("Single")) {
            ImGui::SetNextItemWidth(-110.0f);
            if (ImGui::InputTextMultiline("##send", send_text, send_capacity, ImVec2(-110.0f, 76.0f), ImGuiInputTextFlags_EnterReturnsTrue)) actions |= Action::ActionSend;
            ImGui::SameLine();
            actions |= Command<Action::ActionSend>::Execute([] { return PrimaryAction("Send", ImVec2(96, 76)); });
            const std::array<ToggleSpec, 3> options{{
                {"HEX send", send_hex, Action::ActionSyncSettings},
                {"Send newline", send_crlf, Action::ActionSyncSettings},
                {"Auto send", send_auto, Action::ActionSyncSettings},
            }};
            RenderToggles(actions, options);
            ImGui::SameLine();
            ImGui::SetNextItemWidth(80.0f);
            if (ImGui::InputInt("##send_period", send_period, 0, 0)) actions |= Action::ActionSyncSettings;
            ImGui::SameLine();
            ImGui::TextDisabled("ms");
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem("Multi")) {
            for (int index = 0; index < 8; ++index) {
                char label[16];
                char enabled_label[20];
                sprintf_s(label, "##multi%d", index);
                sprintf_s(enabled_label, "##enabled%d", index);
                if (Toggle(enabled_label, &multi_enabled[index])) actions |= Action::ActionSyncSettings;
                ImGui::SameLine();
                ImGui::SetNextItemWidth(-1.0f);
                if (ImGui::InputText(label, multi_text + index * multi_slot_capacity, multi_slot_capacity)) actions |= Action::ActionSyncSettings;
            }
            const std::array<ToggleSpec, 2> options{{
                {"HEX multi", multi_hex, Action::ActionSyncSettings},
                {"Newline multi", multi_crlf, Action::ActionSyncSettings},
            }};
            RenderToggles(actions, options);
            ImGui::SameLine();
            actions |= Command<Action::ActionSendEnabled>::Execute([] { return ImGui::Button("Send enabled"); });
            ImGui::SameLine();
            actions |= Command<Action::ActionPreviousPage>::Execute([] { return ImGui::Button("<"); });
            ImGui::SameLine();
            ImGui::Text("Page %d / %d", *multi_page + 1, *multi_page_count);
            ImGui::SameLine();
            actions |= Command<Action::ActionNextPage>::Execute([] { return ImGui::Button(">"); });
            ImGui::SameLine();
            actions |= Command<Action::ActionAddPage>::Execute([] { return ImGui::SmallButton("+ page"); });
            ImGui::SameLine();
            actions |= Command<Action::ActionRemovePage>::Execute([] { return ImGui::SmallButton("- page"); });
            const std::array<ToggleSpec, 1> cycle{{{"Auto cycle", multi_auto, Action::ActionSyncMultiAuto}}};
            RenderToggles(actions, cycle);
            ImGui::SameLine();
            ImGui::SetNextItemWidth(80.0f);
            if (ImGui::InputInt("##multi_period", multi_period, 0, 0)) actions |= Action::ActionSyncMultiAuto;
            ImGui::SameLine();
            ImGui::TextDisabled("ms");
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }
    return actions;
}

int ConnectionContent(char* port, size_t port_capacity, bool connected,
                      int* baud, int* data_bits, int* stop_bits, int* parity,
                      int* flow, int* dtr, int* rts,
                      const std::array<ComboSpec, 5>& serial_fields) {
    int actions = 0;
    Section("CONNECTION", connected ? "Port is active" : "Choose a port to begin");
    Field("PORT NAME");
    ImGui::SetNextItemWidth(-1.0f);
    if (ImGui::InputText("##port", port, port_capacity)) actions |= Action::ActionSyncSettings;
    Field("AVAILABLE PORTS");
    ImGui::SetNextItemWidth(-30.0f);
    if (ImGui::BeginCombo("##available_ports", port[0] ? port : "Select a port")) {
            const auto& port_list = ImGuiRuntime::instance().ports_;
            const Slice<std::string> ports(port_list.data(), port_list.size());
            for (const std::string& candidate : ports) {
                const bool selected = candidate == port;
                if (ImGui::Selectable(candidate.c_str(), selected)) {
                    strcpy_s(port, port_capacity, candidate.c_str());
                    actions |= Action::ActionSyncSettings;
                }
                if (selected) ImGui::SetItemDefaultFocus();
            }
            ImGui::EndCombo();
    }
    ImGui::SameLine(0.0f, 6.0f);
    actions |= Command<Action::ActionRefreshPorts>::Execute(
        [] { return ImGui::SmallButton("R"); });
    ImGui::Separator();
    if (!connected) actions |= Command<Action::ActionOpen>::Execute(
        [] { return PrimaryAction("Open", ImVec2(-1, 0)); });
    if (connected) actions |= Command<Action::ActionClose>::Execute(
        [] { return PrimaryAction("Close", ImVec2(-1, 0)); });
    ImGui::Spacing();
    Section("SERIAL PROFILE");
    for (const ComboSpec& field : serial_fields) {
        if (ComboField(field)) actions |= Action::ActionSyncSettings;
    }
    const std::array<ToggleSpec, 2> modem_options{{{"DTR", dtr, Action::ActionSyncSettings}, {"RTS", rts, Action::ActionSyncSettings}}};
    RenderToggles(actions, modem_options);
    return actions;
}

bool Toggle(const char* label, int* value) {
    const ImVec2 size(34.0f, 18.0f);
    const bool changed = ImGui::InvisibleButton(label, size);
    if (changed) *value = *value == 0 ? 1 : 0;
    const bool enabled = *value != 0;
    const ImVec2 minimum = ImGui::GetItemRectMin();
    const ImVec2 maximum = ImGui::GetItemRectMax();
    const float radius = (maximum.y - minimum.y) * 0.5f;
    ImDrawList* draw_list = ImGui::GetWindowDrawList();
    draw_list->AddRectFilled(minimum, maximum,
        ImGui::GetColorU32(enabled ? rgb(0x009999) : rgb(0xD5DCE3)), radius);
    const float knob_x = enabled ? maximum.x - radius : minimum.x + radius;
    draw_list->AddCircleFilled(ImVec2(knob_x, minimum.y + radius), radius - 2.0f,
                                ImGui::GetColorU32(rgb(0xFFFFFF)));
    if (label[0] != '#') {
        ImGui::SameLine(0.0f, 6.0f);
        ImGui::TextUnformatted(label);
    }
    return changed;
}

bool PrimaryAction(const char* label, const ImVec2& size = ImVec2(0, 0)) {
    ImGui::PushStyleColor(ImGuiCol_Button, rgb(0x009999));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, rgb(0x00B3B3));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, rgb(0x007F80));
    const bool clicked = WithRounding(3.0f, [](const char* text, const ImVec2& button_size) {
        return ImGui::Button(text, button_size);
    })(label, size);
    ImGui::PopStyleColor(3);
    return clicked;
}

void EmptyState(std::string_view title, std::string_view detail) {
    const ImVec2 available = ImGui::GetContentRegionAvail();
    const float title_width = ImGui::CalcTextSize(title.data(), title.data() + title.size()).x;
    const float detail_width = ImGui::CalcTextSize(detail.data(), detail.data() + detail.size()).x;
    const float start_y = ImGui::GetCursorPosY() + (available.y - 42.0f) * 0.34f;
    ImGui::SetCursorPos(ImVec2((ImGui::GetWindowWidth() - title_width) * 0.5f, start_y));
    ImGui::TextDisabled("%.*s", static_cast<int>(title.size()), title.data());
    ImGui::SetCursorPosX((ImGui::GetWindowWidth() - detail_width) * 0.5f);
    ImGui::TextDisabled("%.*s", static_cast<int>(detail.size()), detail.data());
}
}

std::string module_resource_path(std::string_view relative_name) {
    char module_path[MAX_PATH]{};
    const DWORD length = GetModuleFileNameA(nullptr, module_path, IM_ARRAYSIZE(module_path));
    if (length == 0 || length >= IM_ARRAYSIZE(module_path)) return {};
    std::string path(module_path, length);
    const size_t slash = path.find_last_of("\\/");
    if (slash == std::string::npos) return {};
    path.resize(slash + 1);
    path.append(relative_name.data(), relative_name.size());
    return path;
}

std::string module_asset_path(std::string_view file_name) {
    std::string path = "assets\\fonts\\";
    path.append(file_name.data(), file_name.size());
    return module_resource_path(path);
}

namespace {
// One declared [layout] key, with its inclusive clamp range and the member it
// sets.  Table-driven so every TOML key shares the same parse + clamp + assign
// path; a static_assert below keeps the table size in lock-step with
// LayoutConfig so a new field without a corresponding entry fails to compile.
struct LayoutEntry final {
    const char* key;
    float min;
    float max;
    float LayoutConfig::* member;
};
constexpr std::array kLayoutEntries{
    LayoutEntry{"sidebar_width",    160.0f, 320.0f, &LayoutConfig::sidebar_width},
    LayoutEntry{"compact_threshold", 600.0f, 1200.0f, &LayoutConfig::compact_threshold},
    LayoutEntry{"receive_height",     0.0f, 600.0f, &LayoutConfig::receive_height},
    LayoutEntry{"send_height",      140.0f, 360.0f, &LayoutConfig::send_height},
    LayoutEntry{"header_height",     40.0f,  72.0f, &LayoutConfig::header_height},
    LayoutEntry{"panel_gap",          2.0f,  24.0f, &LayoutConfig::panel_gap},
    LayoutEntry{"window_padding",     4.0f,  24.0f, &LayoutConfig::window_padding},
    LayoutEntry{"item_spacing",       2.0f,  16.0f, &LayoutConfig::item_spacing},
    LayoutEntry{"frame_padding_y",    2.0f,  10.0f, &LayoutConfig::frame_padding_y},
    LayoutEntry{"section_gap",        2.0f,  12.0f, &LayoutConfig::section_gap},
};
// LayoutConfig carries exactly ten float knobs (see struct above); this keeps
// the table size in lock-step so a missing or extra row is a compile error.
static_assert(kLayoutEntries.size() == LayoutConfig::kFieldCount,
              "layout table must enumerate every LayoutConfig knob");

std::string_view trim_view(std::string_view value) noexcept {
    const size_t first = value.find_first_not_of(" \t\r\n");
    if (first == std::string_view::npos) return {};
    const size_t last = value.find_last_not_of(" \t\r\n");
    return value.substr(first, last - first + 1);
}
}  // namespace

void load_layout_config() {
    auto& layout = ImGuiRuntime::instance().layout_;
    layout = LayoutConfig{};
    const std::string path = module_resource_path("assets\\layout.toml");
    std::ifstream input(path);
    if (!input) return;
    std::string line;
    bool in_layout = false;
    while (std::getline(input, line)) {
        const size_t comment = line.find('#');
        if (comment != std::string::npos) line.resize(comment);
        const std::string_view trimmed = trim_view(line);
        if (trimmed.empty()) continue;
        if (trimmed.front() == '[') {
            in_layout = trimmed == "[layout]";
            continue;
        }
        if (!in_layout) continue;
        const size_t equals = trimmed.find('=');
        if (equals == std::string_view::npos) continue;
        const std::string_view key = trim_view(trimmed.substr(0, equals));
        const std::string_view raw = trim_view(trimmed.substr(equals + 1));
        if (raw.empty()) continue;
        // Parse the float exactly once; strtof needs a NUL-terminated buffer.
        const std::string number(raw);
        const float value = std::strtof(number.c_str(), nullptr);
        for (const LayoutEntry& entry : kLayoutEntries) {
            if (key != entry.key) continue;
            if (value >= entry.min && value <= entry.max) {
                layout.*(entry.member) = value;
            }
            break;
        }
    }
}

void shutdown_impl() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_) return;
    if (wglGetCurrentContext() != runtime.glrc_) wglMakeCurrent(runtime.hdc_, runtime.glrc_);
    if (runtime.frame_active_) ImGui::EndFrame();
    ImGui_ImplOpenGL2_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    wglMakeCurrent(nullptr, nullptr);
    if (HGLRC glrc = std::exchange(runtime.glrc_, nullptr)) wglDeleteContext(glrc);
    HDC hdc = std::exchange(runtime.hdc_, nullptr);
    HWND hwnd = std::exchange(runtime.hwnd_, nullptr);
    if (hwnd && hdc) ReleaseDC(hwnd, hdc);
    std::exchange(runtime.owner_thread_, 0UL);
    std::exchange(runtime.initialized_, false);
    std::exchange(runtime.frame_active_, false);
    std::exchange(runtime.heading_font_, nullptr);
}
}

extern "C" __declspec(dllexport) void xcom_imgui_set_ports(const char* const* names, int count) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || count < 0 || (count > 0 && !names)) return;
    std::vector<std::string> ports;
    ports.reserve(static_cast<size_t>(count));
    for (int index = 0; index < count; ++index) {
        if (names[index] && names[index][0]) ports.emplace_back(names[index]);
    }
    runtime.ports_ = std::move(ports);
}

extern "C" __declspec(dllexport) int xcom_imgui_init(HWND hwnd) {
    auto& runtime = ImGuiRuntime::instance();
    if (!hwnd || runtime.initialized_ || !IsWindow(hwnd)) return 0;
    runtime.hwnd_ = hwnd;
    ImGuiRuntime::instance().reset();
    runtime.owner_thread_ = GetCurrentThreadId();
    runtime.hdc_ = GetDC(hwnd);
    if (!runtime.hdc_) { runtime.hwnd_ = nullptr; return 0; }

    PIXELFORMATDESCRIPTOR pfd{};
    pfd.nSize = sizeof(pfd);
    pfd.nVersion = 1;
    pfd.dwFlags = PFD_DRAW_TO_WINDOW | PFD_SUPPORT_OPENGL | PFD_DOUBLEBUFFER;
    pfd.iPixelType = PFD_TYPE_RGBA;
    pfd.cColorBits = 32;
    pfd.cDepthBits = 24;
    pfd.cStencilBits = 8;
    const int format = ChoosePixelFormat(runtime.hdc_, &pfd);
    if (!format || !SetPixelFormat(runtime.hdc_, format, &pfd)) { ReleaseDC(runtime.hwnd_, runtime.hdc_); runtime.hdc_ = nullptr; runtime.hwnd_ = nullptr; return 0; }
    runtime.glrc_ = wglCreateContext(runtime.hdc_);
    if (!runtime.glrc_ || !wglMakeCurrent(runtime.hdc_, runtime.glrc_)) { if (runtime.glrc_) wglDeleteContext(runtime.glrc_); ReleaseDC(runtime.hwnd_, runtime.hdc_); runtime.glrc_ = nullptr; runtime.hdc_ = nullptr; runtime.hwnd_ = nullptr; return 0; }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    load_layout_config();
    ImGui::StyleColorsLight();
    ImGuiIO& io = ImGui::GetIO();
    ImFontConfig font_config;
    font_config.OversampleH = 3;
    font_config.OversampleV = 2;
    font_config.PixelSnapH = true;
    const std::string body_font = module_asset_path("SiemensSlabRoman.ttf");
    if (ImFont* font = io.Fonts->AddFontFromFileTTF(body_font.c_str(), 16.0f, &font_config)) {
        io.FontDefault = font;
    } else if (ImFont* font = io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\segoeui.ttf", 16.0f, &font_config)) {
        io.FontDefault = font;
    }
    ImFontConfig heading_config = font_config;
    const std::string heading_font = module_asset_path("SiemensSlabBold.TTF");
    runtime.heading_font_ = io.Fonts->AddFontFromFileTTF(heading_font.c_str(), 17.0f, &heading_config);
    if (!runtime.heading_font_) runtime.heading_font_ = io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\segoeuib.ttf", 17.0f, &heading_config);
    const auto& layout = runtime.layout_;
    ImGuiStyle& style = ImGui::GetStyle();
    style.WindowRounding = 0.0f;
    style.ChildRounding = 6.0f;
    style.FrameRounding = 5.0f;
    style.PopupRounding = 6.0f;
    style.ScrollbarRounding = 4.0f;
    style.WindowBorderSize = 0.0f;
    style.FrameBorderSize = 0.0f;
    style.ChildBorderSize = 0.0f;
    style.WindowPadding = ImVec2(0.0f, 0.0f);
    style.FramePadding = ImVec2(8.0f, layout.frame_padding_y);
    style.ItemSpacing = ImVec2(layout.item_spacing, layout.section_gap);
    style.ItemInnerSpacing = ImVec2(6.0f, 4.0f);
    style.ScrollbarSize = 12.0f;
    style.Colors[ImGuiCol_Text] = rgb(0x1F2933);
    style.Colors[ImGuiCol_TextDisabled] = rgb(0x5A6B7A);
    style.Colors[ImGuiCol_WindowBg] = rgb(0xE8EEF2);
    style.Colors[ImGuiCol_ChildBg] = rgb(0xF4F7F9);
    style.Colors[ImGuiCol_PopupBg] = rgb(0xFFFFFF);
    style.Colors[ImGuiCol_Border] = rgb(0x8FAFC4, 0.38f);
    style.Colors[ImGuiCol_BorderShadow] = rgb(0xFFFFFF, 0.0f);
    style.Colors[ImGuiCol_FrameBg] = rgb(0xFFFFFF);
    style.Colors[ImGuiCol_FrameBgHovered] = rgb(0xE8F3F8);
    style.Colors[ImGuiCol_FrameBgActive] = rgb(0xD6EAF3);
    style.Colors[ImGuiCol_Button] = rgb(0xFFFFFF);
    style.Colors[ImGuiCol_ButtonHovered] = rgb(0xE3F0FB);
    style.Colors[ImGuiCol_ButtonActive] = rgb(0xD4E7F7);
    style.Colors[ImGuiCol_Header] = rgb(0xE3F0FB);
    style.Colors[ImGuiCol_HeaderHovered] = rgb(0xD4E7F7);
    style.Colors[ImGuiCol_HeaderActive] = rgb(0xD4E7F7);
    style.Colors[ImGuiCol_CheckMark] = rgb(0x009999);
    style.Colors[ImGuiCol_SliderGrab] = rgb(0x0078D7);
    style.Colors[ImGuiCol_SliderGrabActive] = rgb(0x005A9E);
    style.Colors[ImGuiCol_Tab] = rgb(0xEEF1F4);
    style.Colors[ImGuiCol_TabHovered] = rgb(0xE3F0FB);
    style.Colors[ImGuiCol_TabActive] = rgb(0x009999);
    style.Colors[ImGuiCol_TabUnfocused] = rgb(0xEEF1F4);
    style.Colors[ImGuiCol_TabUnfocusedActive] = rgb(0x009999);
    style.Colors[ImGuiCol_ScrollbarBg] = rgb(0xEEF1F4);
    style.Colors[ImGuiCol_ScrollbarGrab] = rgb(0xB4C0CC);
    style.Colors[ImGuiCol_ScrollbarGrabHovered] = rgb(0x93A5B6);
    style.Colors[ImGuiCol_ScrollbarGrabActive] = rgb(0x0078D7);
    if (!ImGui_ImplWin32_InitForOpenGL(hwnd)) { ImGui::DestroyContext(); wglMakeCurrent(nullptr, nullptr); wglDeleteContext(runtime.glrc_); ReleaseDC(runtime.hwnd_, runtime.hdc_); runtime.glrc_ = nullptr; runtime.hdc_ = nullptr; runtime.hwnd_ = nullptr; return 0; }
    if (!ImGui_ImplOpenGL2_Init()) { ImGui_ImplWin32_Shutdown(); ImGui::DestroyContext(); wglMakeCurrent(nullptr, nullptr); wglDeleteContext(runtime.glrc_); ReleaseDC(runtime.hwnd_, runtime.hdc_); runtime.glrc_ = nullptr; runtime.hdc_ = nullptr; runtime.hwnd_ = nullptr; return 0; }
    runtime.initialized_ = true;
    return 1;
}

extern "C" __declspec(dllexport) int xcom_imgui_draw_console(
    char* port, size_t port_capacity, int connected, int rx_bytes, int tx_bytes,
    int* baud, int* data_bits, int* stop_bits, int* parity, int* flow, int* dtr, int* rts,
    int* receive_hex, int* timestamp, int* pause_display, int* auto_clear, int* auto_clear_bytes,
    char* send_text, size_t send_capacity, int* send_hex, int* send_crlf, int* send_auto, int* send_period,
    char* multi_text, size_t multi_slot_capacity, int* multi_enabled, int* multi_hex, int* multi_crlf,
    int* multi_page, int* multi_page_count, int* multi_auto, int* multi_period, int* auto_save,
    const char* receive_text, size_t receive_length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || !runtime.frame_active_ || GetCurrentThreadId() != runtime.owner_thread_) return 0;
    int actions = 0;
    ImGuiIO& io = ImGui::GetIO();
    ImGui::SetNextWindowPos(ImVec2(0, 0), ImGuiCond_Always);
    ImGui::SetNextWindowSize(io.DisplaySize, ImGuiCond_Always);
    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar | ImGuiWindowFlags_NoResize |
        ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse;
    if (ImGui::Begin("##xcom_dashboard", nullptr, flags)) {
        ui::Header(actions, connected != 0);
        ImGui::Dummy(ImVec2(0.0f, 8.0f));
        ImGui::SetCursorPosX(8.0f);
        static const char* baud_items[] = { "1200", "2400", "4800", "9600", "19200", "38400", "57600", "115200", "230400", "460800", "921600", "1M", "2M", "3M" };
        static const char* data_items[] = { "5", "6", "7", "8" };
        static const char* stop_items[] = { "1", "1.5", "2" };
        static const char* parity_items[] = { "None", "Odd", "Even", "Mark", "Space" };
        static const char* flow_items[] = { "None", "RTS / CTS", "XON / XOFF" };
        const std::array<ui::ComboSpec, 5> serial_fields{{
            {"##baud", "BAUD RATE", baud, baud_items, IM_ARRAYSIZE(baud_items)},
            {"##data_bits", "DATA BITS", data_bits, data_items, IM_ARRAYSIZE(data_items)},
            {"##stop_bits", "STOP BITS", stop_bits, stop_items, IM_ARRAYSIZE(stop_items)},
            {"##parity", "PARITY", parity, parity_items, IM_ARRAYSIZE(parity_items)},
            {"##flow", "FLOW CONTROL", flow, flow_items, IM_ARRAYSIZE(flow_items)},
        }};
        const float content_width = ImGui::GetContentRegionAvail().x - 8.0f;
        const auto& layout = runtime.layout_;
        const float compact_sidebar = layout.sidebar_width - 28.0f;
        const float sidebar_width = content_width < layout.compact_threshold
            ? (compact_sidebar > 180.0f ? compact_sidebar : 180.0f)
            : layout.sidebar_width;
        if (const auto monitor = ui::Panel("##monitor_column", ImVec2(-sidebar_width - 6.0f, 0)); monitor) {
        ui::Section("RECEIVE", "MONITOR · LIVE SERIAL STREAM", false);
        actions |= ui::ReceiveContent(rx_bytes, tx_bytes, receive_hex, timestamp,
                                      pause_display, auto_clear, auto_clear_bytes,
                                      auto_save, receive_text, receive_length);
        const auto send_workspace = ui::Panel("##send_workspace", ImVec2(0, layout.send_height));
        ui::Section("TRANSMIT", "SEND A COMMAND OR BUILD A REUSABLE QUEUE", false);
        actions |= ui::TransmitContent(send_hex, send_crlf, send_auto, send_period,
                                       send_text, send_capacity, multi_text,
                                       multi_slot_capacity, multi_enabled, multi_hex,
                                       multi_crlf, multi_page, multi_page_count,
                                       multi_auto, multi_period);
        }
        ImGui::SameLine(0.0f, layout.panel_gap);
        {
        const auto serial_column = ui::Panel("##serial_column", ImVec2(0, 0));
        actions |= ui::ConnectionContent(port, port_capacity, connected != 0,
                                          baud, data_bits, stop_bits, parity, flow,
                                          dtr, rts, serial_fields);
        }
    }
    ImGui::End();
    return ImGuiRuntime::instance().dispatch(actions);
}

extern "C" __declspec(dllexport) int xcom_imgui_new_frame() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || runtime.frame_active_ || GetCurrentThreadId() != runtime.owner_thread_ ||
        !IsWindow(runtime.hwnd_) || !wglMakeCurrent(runtime.hdc_, runtime.glrc_)) return 0;
    ImGui_ImplOpenGL2_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    runtime.frame_active_ = true;
    return 1;
}

extern "C" __declspec(dllexport) int xcom_imgui_render() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || !runtime.frame_active_ || GetCurrentThreadId() != runtime.owner_thread_ ||
        !wglMakeCurrent(runtime.hdc_, runtime.glrc_)) return 0;
    ImGui::Render();
    ImGui_ImplOpenGL2_RenderDrawData(ImGui::GetDrawData());
    SwapBuffers(runtime.hdc_);
    runtime.frame_active_ = false;
    return 1;
}

extern "C" __declspec(dllexport) int xcom_imgui_wndproc(
    HWND hwnd, UINT msg, uintptr_t wparam, intptr_t lparam) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || hwnd != runtime.hwnd_ || GetCurrentThreadId() != runtime.owner_thread_) return 0;
    // ImGui's handler returns an LRESULT; the C ABI collapses it to a handled
    // boolean so the caller never sees a pointer-sized value for a true/false.
    return ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam) ? 1 : 0;
}

extern "C" __declspec(dllexport) void xcom_imgui_shutdown() {
    shutdown_impl();
}
