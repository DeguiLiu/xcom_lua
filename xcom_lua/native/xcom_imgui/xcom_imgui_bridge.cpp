#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
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
#include <cfloat>

#include "imgui.h"
#include "imgui_impl_dx11.h"
#include "imgui_impl_win32.h"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(
    HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);

namespace {
struct LayoutConfig final {
    static constexpr size_t kFieldCount = 10U;
    static constexpr float kSidebarWidth = 164.0f;
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
constexpr float kReceiveFallbackHeight = 228.0f;

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

// Fixed serial-config dropdown labels (one entry per ABI value).  Shared with
// the Lua client's own value tables, so these are the single source of truth
// for the human-readable form of each baud/data/stop/parity/flow index.
constexpr const char* kBaudItems[] = {
    "1200", "2400", "4800", "9600", "19200", "38400", "57600", "115200",
    "230400", "460800", "921600", "1M", "2M", "3M",
};
constexpr const char* kDataItems[] = { "5", "6", "7", "8" };
constexpr const char* kStopItems[] = { "1", "1.5", "2" };
constexpr const char* kParityItems[] = { "None", "Odd", "Even", "Mark", "Space" };
constexpr const char* kFlowItems[] = { "None", "RTS / CTS", "XON / XOFF" };

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
    std::vector<std::string> ports_;
    ID3D11Device* device_ = nullptr;
    ID3D11DeviceContext* context_ = nullptr;
    IDXGISwapChain* swap_chain_ = nullptr;
    ID3D11RenderTargetView* render_target_ = nullptr;
    HWND hwnd_ = nullptr;
    std::uint32_t owner_thread_ = 0;  // thread id; DWORD == uint32_t on Windows
    bool initialized_ = false;
    bool frame_active_ = false;
    ImFont* heading_font_ = nullptr;
    LayoutConfig layout_{};
    std::string receive_text_{};
    // Byte offset of every line start in receive_text_ (offset 0 included);
    // rescanned by xcom_imgui_set_receive_text and consumed by the receive
    // clipper so per-frame rendering walks only visible lines.
    std::vector<std::size_t> receive_line_offsets_{};
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

// Named Siemens-style palette (single source for every hard-coded colour in
// the dashboard; keep in sync with ui/window.lua's PAL and assets/layout.toml).
namespace palette {
    constexpr unsigned int kHeaderDark = 0x1E1E1E;   // header strip / dark buttons
    constexpr unsigned int kAccentTeal = 0x009999;   // primary brand accent
    constexpr unsigned int kAccentHover = 0x00B3B3;  // primary button hover
    constexpr unsigned int kAccentPress = 0x007F80;  // primary button press
    constexpr unsigned int kHeaderChrome = 0x106EBE; // window button hover
    constexpr unsigned int kHeaderChromeDown = 0x005A9E; // window button press
    constexpr unsigned int kTextInverse = 0xFFFFFF;  // on-dark text / knob
    constexpr unsigned int kTextHeading = 0x008080;  // section heading
    constexpr unsigned int kTextMuted = 0x5A6B7A;    // field labels / disabled
    constexpr unsigned int kTextBody = 0x1F2933;     // default text
    constexpr unsigned int kStatusOnline = 0x7AD8D8; // ONLINE badge
    constexpr unsigned int kStatusOffline = 0xFFD28A; // OFFLINE badge
    constexpr unsigned int kHeaderSubtitle = 0xCDEBFA; // header strapline
    constexpr unsigned int kToggleOff = 0xD5DCE3;    // toggle track (disabled)
    constexpr unsigned int kSurfaceLight = 0xF7F9FB; // receive panel card
    constexpr unsigned int kSurfaceDefault = 0xF4F7F9; // default child panel
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
// Mirrors the RAII discipline of PanelScope / StyleDecorator above.  Takes the
// font pointer directly rather than reaching into ImGuiRuntime, keeping the
// guard independent of the singleton.
class ScopedHeadingFont final {
public:
    explicit ScopedHeadingFont(ImFont* font) : font_(font) {
        if (font_) ImGui::PushFont(font_);
    }
    ~ScopedHeadingFont() {
        if (font_) ImGui::PopFont();
    }
    ScopedHeadingFont(const ScopedHeadingFont&) = delete;
    ScopedHeadingFont& operator=(const ScopedHeadingFont&) = delete;
private:
    ImFont* font_;
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
                 ImGuiWindowFlags flags = 0,
                 ImVec4 background = rgb(palette::kSurfaceDefault)) {
    return PanelScope(id, size, border, flags, background);
}

void Section(std::string_view title, std::string_view subtitle = {}, bool separator = true) {
    ScopedHeadingFont heading(ImGuiRuntime::instance().heading_font_);
    ImGui::TextColored(rgb(palette::kTextHeading), "%.*s", static_cast<int>(title.size()), title.data());
    if (subtitle.empty()) {
        // No subtitle: nothing to place beside or below the title.
    } else if (ImGui::GetContentRegionAvail().x >=
        ImGui::CalcTextSize(title.data(), title.data() + title.size()).x +
        ImGui::CalcTextSize(subtitle.data(), subtitle.data() + subtitle.size()).x + 16.0f) {
        ImGui::SameLine();
        ImGui::TextDisabled("%.*s", static_cast<int>(subtitle.size()), subtitle.data());
    } else {
        ImGui::TextDisabled("%.*s", static_cast<int>(subtitle.size()), subtitle.data());
    }
    if (separator) ImGui::Separator();
}

void Field(std::string_view label) {
    ImGui::TextColored(rgb(palette::kTextMuted), "%.*s", static_cast<int>(label.size()), label.data());
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

enum class WindowButtonKind : std::uint8_t { Minimize, Maximize, Close };

bool WindowButton(const char* id, WindowButtonKind kind, ImDrawList* draw_list) {
    const ImVec2 size(30.0f, 28.0f);
    const bool pressed = ImGui::InvisibleButton(id, size);
    const ImVec2 min = ImGui::GetItemRectMin();
    const ImVec2 max = ImGui::GetItemRectMax();
    const bool hovered = ImGui::IsItemHovered();
    const bool active = ImGui::IsItemActive();
    const ImU32 background = ImGui::GetColorU32(
        kind == WindowButtonKind::Close
            ? (active ? rgb(0xA61B1B) : (hovered ? rgb(0xC93636) : rgb(palette::kHeaderDark)))
            : (active ? rgb(palette::kHeaderChromeDown)
                      : (hovered ? rgb(palette::kHeaderChrome) : rgb(palette::kHeaderDark))));
    draw_list->AddRectFilled(min, max, background, 2.0f);
    const ImU32 icon = ImGui::GetColorU32(rgb(palette::kTextInverse));
    const float center_x = (min.x + max.x) * 0.5f;
    const float center_y = (min.y + max.y) * 0.5f;
    if (kind == WindowButtonKind::Minimize) {
        draw_list->AddLine(ImVec2(center_x - 6.0f, center_y + 4.0f),
                           ImVec2(center_x + 6.0f, center_y + 4.0f), icon, 1.5f);
    } else if (kind == WindowButtonKind::Maximize) {
        draw_list->AddRect(ImVec2(center_x - 6.0f, center_y - 6.0f),
                           ImVec2(center_x + 6.0f, center_y + 6.0f), icon, 1.5f);
    } else {
        draw_list->AddLine(ImVec2(center_x - 6.0f, center_y - 6.0f),
                           ImVec2(center_x + 6.0f, center_y + 6.0f), icon, 1.5f);
        draw_list->AddLine(ImVec2(center_x + 6.0f, center_y - 6.0f),
                           ImVec2(center_x - 6.0f, center_y + 6.0f), icon, 1.5f);
    }
    return pressed;
}

void Header(int& actions, const bool connected) {
    ImGui::PushStyleColor(ImGuiCol_ChildBg, rgb(palette::kHeaderDark));
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
    const float brand_center_y = position.y + layout.header_height * 0.5f;
    draw_list->AddRectFilled(ImVec2(position.x + 12.0f, brand_center_y - 12.0f),
                             ImVec2(position.x + 36.0f, brand_center_y + 12.0f),
                             ImGui::GetColorU32(rgb(palette::kAccentTeal)), 3.0f);
    const ImU32 inverse = ImGui::GetColorU32(rgb(palette::kTextInverse));
    draw_list->AddLine(ImVec2(position.x + 18.0f, brand_center_y - 6.0f),
                       ImVec2(position.x + 30.0f, brand_center_y + 6.0f), inverse, 1.8f);
    draw_list->AddLine(ImVec2(position.x + 30.0f, brand_center_y - 6.0f),
                       ImVec2(position.x + 18.0f, brand_center_y + 6.0f), inverse, 1.8f);
    ImFont* const title_font = runtime.heading_font_ ? runtime.heading_font_ : ImGui::GetFont();
    const float title_size = 17.0f;
    const float title_y = brand_center_y - title_size * 0.5f - 1.0f;
    const ImVec2 title_pos(position.x + 46.0f, title_y);
    draw_list->AddText(title_font, title_size, title_pos, inverse, "XCOM");
    const float title_width = title_font->CalcTextSizeA(
        title_size, FLT_MAX, 0.0f, "XCOM").x;
    const float divider_x = title_pos.x + title_width + 12.0f;
    draw_list->AddLine(ImVec2(divider_x, brand_center_y - 8.0f),
                       ImVec2(divider_x, brand_center_y + 8.0f),
                       ImGui::GetColorU32(rgb(palette::kHeaderSubtitle, 0.45f)), 1.0f);
    const float subtitle_size = 12.0f;
    draw_list->AddText(ImGui::GetFont(), subtitle_size,
                       ImVec2(divider_x + 12.0f, brand_center_y - subtitle_size * 0.5f - 1.0f),
                       ImGui::GetColorU32(rgb(palette::kHeaderSubtitle)), "SERIAL CONSOLE");
    const char* const status = connected ? "ONLINE" : "OFFLINE";
    const float button_group_start = ImGui::GetWindowWidth() - 108.0f;
    const float status_width = ImGui::CalcTextSize(status).x + 20.0f;
    ImGui::SetCursorPos(ImVec2(button_group_start - status_width - 12.0f, 15.0f));
    ImGui::TextColored(connected ? rgb(palette::kStatusOnline) : rgb(palette::kStatusOffline), "%s", status);
    ImGui::SetCursorPos(ImVec2(button_group_start, 8.0f));
    actions |= Command<Action::ActionMinimizeWindow>::Execute(
        [draw_list] { return WindowButton("##window_minimize", WindowButtonKind::Minimize, draw_list); });
    ImGui::SameLine(0.0f, 2.0f);
    actions |= Command<Action::ActionMaximizeWindow>::Execute(
        [draw_list] { return WindowButton("##window_maximize", WindowButtonKind::Maximize, draw_list); });
    ImGui::SameLine(0.0f, 2.0f);
    actions |= Command<Action::ActionCloseWindow>::Execute(
        [draw_list] { return WindowButton("##window_close", WindowButtonKind::Close, draw_list); });
    const float width = ImGui::GetWindowWidth();
    draw_list->AddRectFilled(ImVec2(position.x, position.y + layout.header_height - 3.0f),
                             ImVec2(position.x + width, position.y + layout.header_height),
                             ImGui::GetColorU32(rgb(palette::kAccentTeal)));
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
                   int* auto_save) {
    int actions = 0;
    ReceiveToolbar(actions, rx_bytes, tx_bytes, receive_hex, timestamp, pause_display,
                   auto_clear, auto_clear_bytes, auto_save);
    const auto& layout = ImGuiRuntime::instance().layout_;
    const auto receive = Panel("##receive", ImVec2(0, layout.receive_height == 0.0f ? -kReceiveFallbackHeight : layout.receive_height), true,
                               ImGuiWindowFlags_HorizontalScrollbar, rgb(palette::kSurfaceLight));
    const std::string& receive_text = ImGuiRuntime::instance().receive_text_;
    if (receive_text.empty()) {
        EmptyState("WAITING FOR SERIAL DATA", "Select a port, then open the connection to begin monitoring.");
        return actions;
    }
    // Clipper path: only visible lines are measured and tessellated, so the
    // per-frame cost is O(viewport) instead of O(whole 64 KiB buffer) —
    // the dominant hot spot at high receive rates.  Line offsets are cached
    // in the runtime and rescanned only when the buffer changes.
    auto& runtime = ImGuiRuntime::instance();
    const std::vector<std::size_t>& line_offsets = runtime.receive_line_offsets_;
    ImGuiListClipper clipper;
    clipper.Begin(static_cast<int>(line_offsets.size()));
    while (clipper.Step()) {
        for (int line_index = clipper.DisplayStart; line_index < clipper.DisplayEnd; ++line_index) {
            const char* line_begin = receive_text.data() + line_offsets[static_cast<std::size_t>(line_index)];
            const char* line_end = line_index + 1 < static_cast<int>(line_offsets.size())
                ? receive_text.data() + line_offsets[static_cast<std::size_t>(line_index) + 1]
                : receive_text.data() + receive_text.size();
            ImGui::TextUnformatted(line_begin, line_end);
        }
    }
    // Auto-follow: keep the view pinned to the newest data while the user
    // stays at (or near) the bottom; a deliberate upward scroll detaches.
    if (ImGui::GetScrollY() >= ImGui::GetScrollMaxY() - 1.0f) {
        ImGui::SetScrollY(ImGui::GetScrollMaxY());
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
        ImGui::GetColorU32(enabled ? rgb(palette::kAccentTeal) : rgb(palette::kToggleOff)), radius);
    const float knob_x = enabled ? maximum.x - radius : minimum.x + radius;
    draw_list->AddCircleFilled(ImVec2(knob_x, minimum.y + radius), radius - 2.0f,
                                ImGui::GetColorU32(rgb(palette::kTextInverse)));
    if (label[0] != '#') {
        ImGui::SameLine(0.0f, 6.0f);
        ImGui::TextUnformatted(label);
    }
    return changed;
}

bool PrimaryAction(const char* label, const ImVec2& size = ImVec2(0, 0)) {
    ImGui::PushStyleColor(ImGuiCol_Button, rgb(palette::kAccentTeal));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, rgb(palette::kAccentHover));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, rgb(palette::kAccentPress));
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

// Directory of this DLL (not the exe).  The runtime bundle keeps
// xcom_imgui.dll in <app>/runtime/ while assets live in <app>/assets/, so
// probe the DLL directory first and its parent second; fall back to the exe
// directory when neither resolves.  This keeps fonts/layout.toml findable
// regardless of which exe hosts the DLL.
std::string module_directory() {
    char module_path[MAX_PATH]{};
    HMODULE module = nullptr;
    if (GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                               GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                           reinterpret_cast<LPCSTR>(&module_directory), &module) &&
        module) {
        GetModuleFileNameA(module, module_path, IM_ARRAYSIZE(module_path));
    }
    if (module_path[0] == '\0') {
        const std::uint32_t length =
            static_cast<std::uint32_t>(GetModuleFileNameA(nullptr, module_path, IM_ARRAYSIZE(module_path)));
        if (length == 0 || length >= IM_ARRAYSIZE(module_path)) return {};
    }
    std::string path(module_path);
    const size_t slash = path.find_last_of("\\/");
    if (slash == std::string::npos) return {};
    return path.substr(0, slash + 1);
}

std::string module_resource_path(std::string_view relative_name) {
    static const std::string base = module_directory();
    if (base.empty()) return {};
    // Probe <dll-dir>/<relative>, then <dll-dir>/../<relative> (runtime
    // bundle layout), then <exe-dir>/<relative>.
    std::string candidate = base;
    candidate.append(relative_name.data(), relative_name.size());
    if (GetFileAttributesA(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) return candidate;
    const size_t cut = base.size() > 1 ? base.substr(0, base.size() - 1).find_last_of("\\/") : std::string::npos;
    if (cut != std::string::npos) {
        std::string parent = base.substr(0, cut + 1);
        parent.append(relative_name.data(), relative_name.size());
        if (GetFileAttributesA(parent.c_str()) != INVALID_FILE_ATTRIBUTES) return parent;
    }
    char exe_path[MAX_PATH]{};
    const std::uint32_t length =
        static_cast<std::uint32_t>(GetModuleFileNameA(nullptr, exe_path, IM_ARRAYSIZE(exe_path)));
    if (length > 0 && length < IM_ARRAYSIZE(exe_path)) {
        std::string exe(exe_path, length);
        const size_t exe_slash = exe.find_last_of("\\/");
        if (exe_slash != std::string::npos) {
            exe.resize(exe_slash + 1);
            exe.append(relative_name.data(), relative_name.size());
            if (GetFileAttributesA(exe.c_str()) != INVALID_FILE_ATTRIBUTES) return exe;
        }
    }
    return candidate;  // first candidate; caller's fallbacks handle the miss
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

[[nodiscard]] bool create_render_target(ImGuiRuntime& runtime) noexcept {
    if (!runtime.swap_chain_ || !runtime.device_) return false;
    ID3D11Texture2D* back_buffer = nullptr;
    const HRESULT buffer_result = runtime.swap_chain_->GetBuffer(
        0, IID_PPV_ARGS(&back_buffer));
    if (FAILED(buffer_result)) return false;
    const HRESULT view_result = runtime.device_->CreateRenderTargetView(
        back_buffer, nullptr, &runtime.render_target_);
    back_buffer->Release();
    return SUCCEEDED(view_result);
}

void cleanup_render_target(ImGuiRuntime& runtime) noexcept {
    if (runtime.render_target_) {
        runtime.render_target_->Release();
        runtime.render_target_ = nullptr;
    }
}

// Release the DX11 resources acquired by xcom_imgui_init, resetting every
// runtime field to its pre-init state. Shared by init failure paths and
// shutdown_impl so cleanup can never drift between them.
void release_dx_resources(ImGuiRuntime& runtime) noexcept {
    cleanup_render_target(runtime);
    if (runtime.swap_chain_) {
        runtime.swap_chain_->Release();
        runtime.swap_chain_ = nullptr;
    }
    if (runtime.context_) {
        runtime.context_->ClearState();
        runtime.context_->Release();
        runtime.context_ = nullptr;
    }
    if (runtime.device_) {
        runtime.device_->Release();
        runtime.device_ = nullptr;
    }
    runtime.hwnd_ = nullptr;
}

void shutdown_impl() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_) return;
    if (runtime.frame_active_) ImGui::EndFrame();
    ImGui_ImplDX11_Shutdown();
    ImGui_ImplWin32_Shutdown();
    ImGui::DestroyContext();
    release_dx_resources(runtime);
    runtime.owner_thread_ = 0;
    runtime.initialized_ = false;
    runtime.frame_active_ = false;
    runtime.heading_font_ = nullptr;
    runtime.receive_text_.clear();
}
}

namespace {
// One static style assignment: target colour slot plus palette value (with
// optional alpha).  Table-driven so adding or re-tinting a colour is a data
// edit, not another hand-written assignment line; applied by apply_style().
struct StyleColorEntry final {
    ImGuiCol slot;
    unsigned int value;
    float alpha;
};
constexpr std::array kStyleColors{
    StyleColorEntry{ImGuiCol_Text, 0x1F2933, 1.0f},
    StyleColorEntry{ImGuiCol_TextDisabled, 0x5A6B7A, 1.0f},
    StyleColorEntry{ImGuiCol_WindowBg, 0xE8EEF2, 1.0f},
    StyleColorEntry{ImGuiCol_ChildBg, 0xF4F7F9, 1.0f},
    StyleColorEntry{ImGuiCol_PopupBg, 0xFFFFFF, 1.0f},
    StyleColorEntry{ImGuiCol_Border, 0x8FAFC4, 0.38f},
    StyleColorEntry{ImGuiCol_BorderShadow, 0xFFFFFF, 0.0f},
    StyleColorEntry{ImGuiCol_FrameBg, 0xFFFFFF, 1.0f},
    StyleColorEntry{ImGuiCol_FrameBgHovered, 0xE8F3F8, 1.0f},
    StyleColorEntry{ImGuiCol_FrameBgActive, 0xD6EAF3, 1.0f},
    StyleColorEntry{ImGuiCol_Button, 0xFFFFFF, 1.0f},
    StyleColorEntry{ImGuiCol_ButtonHovered, 0xE3F0FB, 1.0f},
    StyleColorEntry{ImGuiCol_ButtonActive, 0xD4E7F7, 1.0f},
    StyleColorEntry{ImGuiCol_Header, 0xE3F0FB, 1.0f},
    StyleColorEntry{ImGuiCol_HeaderHovered, 0xD4E7F7, 1.0f},
    StyleColorEntry{ImGuiCol_HeaderActive, 0xD4E7F7, 1.0f},
    StyleColorEntry{ImGuiCol_CheckMark, 0x009999, 1.0f},
    StyleColorEntry{ImGuiCol_SliderGrab, 0x0078D7, 1.0f},
    StyleColorEntry{ImGuiCol_SliderGrabActive, 0x005A9E, 1.0f},
    StyleColorEntry{ImGuiCol_Tab, 0xEEF1F4, 1.0f},
    StyleColorEntry{ImGuiCol_TabHovered, 0xE3F0FB, 1.0f},
    StyleColorEntry{ImGuiCol_TabActive, 0x009999, 1.0f},
    StyleColorEntry{ImGuiCol_TabUnfocused, 0xEEF1F4, 1.0f},
    StyleColorEntry{ImGuiCol_TabUnfocusedActive, 0x009999, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarBg, 0xEEF1F4, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarGrab, 0xB4C0CC, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarGrabHovered, 0x93A5B6, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarGrabActive, 0x0078D7, 1.0f},
};

// Geometry knobs that live outside layout.toml (fixed look, not user-tunable).
constexpr float kClearColor[4] = {0.91f, 0.94f, 0.96f, 1.0f};

void apply_style(const LayoutConfig& layout) {
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
    for (const StyleColorEntry& entry : kStyleColors) {
        style.Colors[entry.slot] = rgb(entry.value, entry.alpha);
    }
}
}  // namespace

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
    runtime.receive_text_.clear();
    runtime.receive_text_.reserve(64U * 1024U - 1U);
    runtime.hwnd_ = hwnd;
    runtime.owner_thread_ = GetCurrentThreadId();

    RECT client_rect{};
    GetClientRect(hwnd, &client_rect);
    const UINT width = static_cast<UINT>(std::max<LONG>(1, client_rect.right - client_rect.left));
    const UINT height = static_cast<UINT>(std::max<LONG>(1, client_rect.bottom - client_rect.top));
    DXGI_SWAP_CHAIN_DESC swap_desc{};
    swap_desc.BufferCount = 2;
    swap_desc.BufferDesc.Width = width;
    swap_desc.BufferDesc.Height = height;
    swap_desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.OutputWindow = hwnd;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.Windowed = TRUE;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;
    constexpr D3D_FEATURE_LEVEL feature_levels[] = {
        D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0,
    };
    D3D_FEATURE_LEVEL feature_level{};
    const HRESULT device_result = D3D11CreateDeviceAndSwapChain(
        nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, D3D11_CREATE_DEVICE_SINGLETHREADED, feature_levels,
        static_cast<UINT>(IM_ARRAYSIZE(feature_levels)), D3D11_SDK_VERSION,
        &swap_desc, &runtime.swap_chain_, &runtime.device_, &feature_level,
        &runtime.context_);
    if (FAILED(device_result) || !create_render_target(runtime)) {
        release_dx_resources(runtime);
        runtime.owner_thread_ = 0;
        return 0;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    load_layout_config();
    ImGui::StyleColorsLight();
    ImGuiIO& io = ImGui::GetIO();
    ImFontConfig font_config;
    font_config.OversampleH = 2;
    font_config.OversampleV = 1;
    font_config.PixelSnapH = true;
    font_config.GlyphRanges = io.Fonts->GetGlyphRangesDefault();
    const std::string body_font = module_asset_path("SiemensSlabRoman.ttf");
    if (ImFont* font = io.Fonts->AddFontFromFileTTF(body_font.c_str(), 17.0f, &font_config)) {
        io.FontDefault = font;
    } else if (ImFont* font = io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\segoeui.ttf", 17.0f, &font_config)) {
        io.FontDefault = font;
    }
    ImFontConfig heading_config = font_config;
    const std::string heading_font = module_asset_path("SiemensSlabBold.TTF");
    runtime.heading_font_ = io.Fonts->AddFontFromFileTTF(heading_font.c_str(), 18.0f, &heading_config);
    if (!runtime.heading_font_) runtime.heading_font_ = io.Fonts->AddFontFromFileTTF("C:\\Windows\\Fonts\\segoeuib.ttf", 18.0f, &heading_config);
    apply_style(runtime.layout_);
    if (!ImGui_ImplWin32_Init(hwnd)) {
        ImGui::DestroyContext();
        release_dx_resources(runtime);
        runtime.owner_thread_ = 0;
        return 0;
    }
    if (!ImGui_ImplDX11_Init(runtime.device_, runtime.context_)) {
        ImGui_ImplWin32_Shutdown();
        ImGui::DestroyContext();
        release_dx_resources(runtime);
        runtime.owner_thread_ = 0;
        return 0;
    }
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
    (void)receive_text;
    (void)receive_length;
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
        const std::array<ui::ComboSpec, 5> serial_fields{{
            {"##baud", "BAUD RATE", baud, kBaudItems, static_cast<int>(std::size(kBaudItems))},
            {"##data_bits", "DATA BITS", data_bits, kDataItems, static_cast<int>(std::size(kDataItems))},
            {"##stop_bits", "STOP BITS", stop_bits, kStopItems, static_cast<int>(std::size(kStopItems))},
            {"##parity", "PARITY", parity, kParityItems, static_cast<int>(std::size(kParityItems))},
            {"##flow", "FLOW CONTROL", flow, kFlowItems, static_cast<int>(std::size(kFlowItems))},
        }};
        const float content_width = ImGui::GetContentRegionAvail().x - 8.0f;
        const auto& layout = runtime.layout_;
        const float compact_sidebar = layout.sidebar_width - 28.0f;
        const float sidebar_width = content_width < layout.compact_threshold
            ? (compact_sidebar > 160.0f ? compact_sidebar : 160.0f)
            : layout.sidebar_width;
        if (const auto monitor = ui::Panel("##monitor_column", ImVec2(-sidebar_width - 6.0f, 0)); monitor) {
            ui::Section("RECEIVE", "MONITOR · LIVE SERIAL STREAM", false);
            actions |= ui::ReceiveContent(rx_bytes, tx_bytes, receive_hex, timestamp,
                                          pause_display, auto_clear, auto_clear_bytes,
                                          auto_save);
            // Binding (not a bare temporary) keeps the panel's EndChild in this
            // scope, so the workspace stays open across the section below.
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
    // The accumulated action mask is the C ABI return value — returned to the
    // Lua caller verbatim (single consumer; no observer indirection needed).
    return actions;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_receive_text(
    const char* text, size_t length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return;
    constexpr size_t kReceiveLimit = 64U * 1024U - 1U;
    if (!text || length == 0) {
        runtime.receive_text_.clear();
        runtime.receive_line_offsets_.assign(1, 0);
        return;
    }
    const size_t bounded_length = (std::min)(length, kReceiveLimit);
    runtime.receive_text_.assign(text, bounded_length);
    // Rescan line starts once per text change (O(n) over the 64 KiB tail) so
    // the per-frame clipper render indexes lines without re-walking the text.
    std::vector<std::size_t>& offsets = runtime.receive_line_offsets_;
    offsets.clear();
    offsets.push_back(0);
    for (std::size_t index = 0; index < bounded_length; ++index) {
        if (runtime.receive_text_[index] == '\n') offsets.push_back(index + 1);
    }
}

extern "C" __declspec(dllexport) int xcom_imgui_new_frame() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || runtime.frame_active_ || GetCurrentThreadId() != runtime.owner_thread_ ||
        !IsWindow(runtime.hwnd_) || !runtime.device_ || !runtime.context_) return 0;
    ImGui_ImplDX11_NewFrame();
    ImGui_ImplWin32_NewFrame();
    ImGui::NewFrame();
    runtime.frame_active_ = true;
    return 1;
}

extern "C" __declspec(dllexport) int xcom_imgui_render() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || !runtime.frame_active_ || GetCurrentThreadId() != runtime.owner_thread_ ||
        !runtime.swap_chain_ || !runtime.render_target_ || !runtime.context_) return 0;
    ImGui::Render();
    runtime.context_->OMSetRenderTargets(1, &runtime.render_target_, nullptr);
    runtime.context_->ClearRenderTargetView(runtime.render_target_, kClearColor);
    ImGui_ImplDX11_RenderDrawData(ImGui::GetDrawData());
    runtime.swap_chain_->Present(1, 0);
    runtime.frame_active_ = false;
    return 1;
}

extern "C" __declspec(dllexport) int xcom_imgui_wndproc(
    HWND hwnd, UINT msg, uintptr_t wparam, intptr_t lparam) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || hwnd != runtime.hwnd_ || GetCurrentThreadId() != runtime.owner_thread_) return 0;
    if (msg == WM_SIZE && wparam != SIZE_MINIMIZED && runtime.swap_chain_) {
        const UINT width = LOWORD(static_cast<LPARAM>(lparam));
        const UINT height = HIWORD(static_cast<LPARAM>(lparam));
        if (width > 0 && height > 0) {
            cleanup_render_target(runtime);
            if (SUCCEEDED(runtime.swap_chain_->ResizeBuffers(0, width, height,
                                                              DXGI_FORMAT_UNKNOWN, 0))) {
                // Best-effort: a resize that cannot recreate the RTV leaves a
                // null target, which xcom_imgui_render() then guards against.
                (void)create_render_target(runtime);
            }
        }
    }
    // ImGui's handler returns an LRESULT; the C ABI collapses it to a handled
    // boolean so the caller never sees a pointer-sized value for a true/false.
    return ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam) ? 1 : 0;
}

extern "C" __declspec(dllexport) void xcom_imgui_shutdown() {
    shutdown_impl();
}
