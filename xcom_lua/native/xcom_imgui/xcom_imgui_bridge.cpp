#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <algorithm>
#include <string>
#include <string_view>
#include <functional>
#include <fstream>
#include <cstdio>
#include <cstdlib>
#include <type_traits>
#include <utility>
#include <vector>
#include <array>
#include <cstdint>
#include <cfloat>
#include <cstring>

#include "imgui.h"
#include "imgui_internal.h"
#include "imgui_impl_dx11.h"
#include "imgui_impl_win32.h"
#include "implot.h"

extern IMGUI_IMPL_API LRESULT ImGui_ImplWin32_WndProcHandler(
    HWND hwnd, UINT msg, WPARAM wparam, LPARAM lparam);

namespace {
struct LayoutConfig final {
    static constexpr size_t kFieldCount = 10U;
    static constexpr float kSidebarWidth = 180.0f;
    static constexpr float kCompactThreshold = 760.0f;
    static constexpr float kReceiveHeight = 0.0f;
    static constexpr float kSendHeight = 196.0f;
    static constexpr float kHeaderHeight = 30.0f;
    static constexpr float kPanelGap = 0.0f;
    static constexpr float kWindowPadding = 1.0f;
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
static_assert(LayoutConfig::kSendHeight >= 100.0f);
constexpr float kFooterHeight = 22.0f;
constexpr float kControlHeight = 26.0f;
constexpr float kToggleHeight = 20.0f;
constexpr float kSidebarInset = 1.2f;
constexpr std::uint32_t kPanelBorder = 0xD5D5D5;   // 1.png combo / input border sampled

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
// Parity/flow dropdown text is localized (Lang::parity_items / flow_items);
// only the numeric kBaud/kData/kStop lists stay language-neutral here.
// Charset dropdown (index contract shared with ui/imgui_bridge.lua
// CHARSET_ITEMS; order matters).  Index 0/1 are passthroughs the Lua funnel
// short-circuits on.
constexpr const char* kCharsetItems[] = {
    "ASCII", "UTF-8", "GB2312", "BIG5", "SHIFT-JIS", "UTF-16",
};

// ---------------------------------------------------------------------------
// Localized UI strings.  Every user-facing label routes through one of these
// two tables; the active language is picked at init from [ui] language in
// layout.toml (see load_layout_config).  Chinese is the primary target
// (pic/1.png is a Chinese reference); English is the fallback.  Strings are
// UTF-8 literals — the TU is compiled /utf-8, and the body/heading fonts are
// baked with a CJK glyph merge so the hanzi render.  Keep each zh phrase
// short enough that switch+label+trailing input still fits the sidebar width.
// ---------------------------------------------------------------------------
struct Lang final {
    const char* online;
    const char* offline;
    const char* chip_lua;
    const char* chip_scope;
    const char* chip_set;
    const char* section_port;
    const char* select_port;
    const char* open;
    const char* close;
    const char* section_serial;
    const char* more;
    const char* custom;
    const char* section_recv;
    const char* hex_display;   // receive "十六进制"
    const char* timestamp;     // "时间戳"
    const char* pause;         // "暂停显示"
    const char* auto_clear;    // "自动清空"
    const char* save_to_file;  // "保存到文件"
    const char* charset;       // "编码"
    const char* frame_gap;     // "自动断帧"
    const char* ms;
    const char* tab_single;
    const char* tab_multi;
    const char* send_hex;
    const char* send_newline;
    const char* send_auto;
    const char* send;
    const char* run;
    const char* loop;
    const char* gap;
    const char* waiting;
    const char* ready;
    const char* open_a_port;
    const char* refresh_tip;
    const char* save_tip;
    const char* clear_tip;
    const char* path_tip;
    const char* settings_title;
    const char* general_tab;
    const char* appearance;
    const char* font_size;
    const char* mono_cjk_label;   // receive-log "show Chinese" toggle label
    const char* scope_title;
    const char* scripts_title;
    const char* send_slot_tip_prefix;   // "发送槽位 %d" / "Send slot %d"
    const char* parity_items[5];
    const char* flow_items[3];
    // Open-time modem-line tri-state (XCOM_LINE_*).  Items are ordered by the
    // ABI enum so combo index == value: 0 deassert, 1 assert, 2 leave alone.
    // A distinct group from the live DTR/RTS toggles.
    const char* open_line_label;    // "开端口线路" / "OPEN LINES"
    const char* open_line_items[3];
    // Serial-profile combo labels in the grid's fixed row order
    // (baud / data bits / stop bits / parity / flow — same order as
    // serial_fields in draw_console, which indexes this array positionally).
    const char* serial_field_labels[5];
    // Round-2 gaps from the untranslated-string audit (menus, script console,
    // scope window, header subtitle).
    const char* subtitle;               // header strapline under XCOM
    const char* menu_select_all;
    const char* menu_copy;
    const char* menu_paste;
    const char* menu_copy_sel;          // receive ctx: copy the selection
    const char* menu_copy_all;          // receive ctx: copy the retained tail
    const char* menu_copy_strip_ts;     // receive ctx: strip injected timestamps on copy
    const char* menu_clear_log;         // receive ctx: clear the log
    const char* menu_save_log;          // receive ctx: save retained tail to file
    const char* menu_resume;            // receive ctx: resume display (pause off)
    const char* script_new;
    const char* script_open_folder;
    const char* script_reload;
    const char* script_clear_log;
    const char* script_empty_title;
    const char* script_empty_detail;
    const char* repl_label;
    const char* plugin_windows;         // Settings section: plugin window toggles
    const char* scope_follow;
    const char* scope_hint;
    const char* scope_empty_title;
    const char* scope_empty_detail;     // mentions wave.push (ASCII token)
    const char* scope_axis_x;
    const char* scope_dt_fmt;           // printf-style "dt = %.3f s"
    float serial_label_col;             // serial-grid label column width

    // Invoke fn(const char*) for every translatable string in this table
    // (scalar labels + all dropdown item arrays).  The font baker derives the
    // merged glyph set from this so it can never drift from what the UI draws:
    // add a phrase here and it is baked automatically.
    template <typename Fn>
    void for_each_text(Fn&& fn) const noexcept {
        fn(online); fn(offline);
        fn(chip_lua); fn(chip_scope); fn(chip_set);
        fn(section_port); fn(select_port);
        fn(open); fn(close);
        fn(section_serial); fn(more); fn(custom);
        fn(section_recv);
        fn(hex_display); fn(timestamp); fn(pause); fn(auto_clear); fn(save_to_file);
        fn(charset); fn(frame_gap); fn(ms);
        fn(tab_single); fn(tab_multi);
        fn(send_hex); fn(send_newline); fn(send_auto);
        fn(send); fn(run); fn(loop); fn(gap);
        fn(waiting); fn(ready); fn(open_a_port);
        fn(refresh_tip); fn(save_tip); fn(clear_tip); fn(path_tip);
        fn(settings_title); fn(general_tab); fn(appearance); fn(font_size);
        fn(mono_cjk_label);
        fn(scope_title); fn(scripts_title);
        fn(send_slot_tip_prefix);
        for (const char* item : parity_items) { fn(item); }
        for (const char* item : flow_items) { fn(item); }
        for (const char* item : open_line_items) { fn(item); }
        fn(open_line_label);
        for (const char* item : serial_field_labels) { fn(item); }
        fn(subtitle);
        fn(menu_select_all); fn(menu_copy); fn(menu_paste);
        fn(menu_copy_sel); fn(menu_copy_all); fn(menu_copy_strip_ts);
        fn(menu_clear_log);
        fn(menu_save_log); fn(menu_resume);
        fn(script_new); fn(script_open_folder); fn(script_reload); fn(script_clear_log);
        fn(script_empty_title); fn(script_empty_detail);
        fn(repl_label);
        fn(plugin_windows);
        fn(scope_follow); fn(scope_hint); fn(scope_empty_title); fn(scope_empty_detail);
        fn(scope_axis_x); fn(scope_dt_fmt);
    }
};

// Compile-time contracts (conventions §5.4 line 184: assert at the definition
// site).  These arrays are consumed positionally by the serial-field grid and
// by the Lua parity/flow index contract; a size drift is silent at runtime, so
// it must fail the build instead.  Lang itself stays a standard-layout,
// trivially-copyable POD table (no per-instance state).
static_assert(std::is_standard_layout_v<Lang> && std::is_trivially_copyable_v<Lang>);
static_assert(std::size(Lang{}.parity_items) == 5U);   // matches ui/imgui_bridge.lua PARITY_ITEMS
static_assert(std::size(Lang{}.flow_items) == 3U);      // matches ui/imgui_bridge.lua FLOW_ITEMS
static_assert(std::size(Lang{}.open_line_items) == 3U); // == XCOM_LINE_* count (0/1/2)
static_assert(std::size(Lang{}.serial_field_labels) == 5U);  // == serial_fields row count

// Chinese labels mirror pic/1.png + llcom/SSCOM naming conventions.
constexpr Lang kLangZh{
    /*online*/ "在线", /*offline*/ "离线",
    /*chip_lua*/ "脚本", /*chip_scope*/ "波形", /*chip_set*/ "设置",
    /*section_port*/ "端口设置", /*select_port*/ "选择串口",
    /*open*/ "打开", /*close*/ "关闭",
    /*section_serial*/ "串口参数", /*more*/ "更多", /*custom*/ "自定义",
    /*section_recv*/ "接收设置",
    /*hex_display*/ "十六进制", /*timestamp*/ "时间戳",
    /*pause*/ "暂停显示", /*auto_clear*/ "自动清空", /*save_to_file*/ "保存到文件",
    /*charset*/ "编码", /*frame_gap*/ "自动断帧", /*ms*/ "毫秒",
    /*tab_single*/ "单条", /*tab_multi*/ "多条",
    /*send_hex*/ "十六进制", /*send_newline*/ "加回车换行", /*send_auto*/ "自动发送",
    /*send*/ "发送", /*run*/ "执行", /*loop*/ "循环", /*gap*/ "间隔",
    /*waiting*/ "等待串口数据", /*ready*/ "就绪", /*open_a_port*/ "请打开串口",
    /*refresh_tip*/ "刷新串口", /*save_tip*/ "保存接收日志",
    /*clear_tip*/ "清空接收日志", /*path_tip*/ "选择日志路径",
    /*settings_title*/ "设置", /*general_tab*/ "常规", /*appearance*/ "外观",
    /*font_size*/ "字号", /*mono_cjk_label*/ "接收窗口显示中文",
    /*scope_title*/ "波形", /*scripts_title*/ "脚本控制台",
    /*send_slot_tip_prefix*/ "发送槽位 %d",
    /*parity*/ {"无校验", "奇校验", "偶校验", "标志位", "空校验"},
    /*flow*/ {"无", "RTS / CTS", "XON / XOFF"},
    /*open_line_label*/ "开端口线路",
    /*open_line_items*/ {"拉低", "拉高", "不接触"},
    /*serial_field_labels*/ {"波特率", "数据位", "停止位", "校验位", "流控"},
    /*subtitle*/ "串口助手",
    /*menu_select_all*/ "全选", /*menu_copy*/ "复制", /*menu_paste*/ "粘贴",
    /*menu_copy_sel*/ "复制选中", /*menu_copy_all*/ "复制保留尾部",
    /*menu_copy_strip_ts*/ "复制时去除时间戳", /*menu_clear_log*/ "清空日志",
    /*menu_save_log*/ "保存日志到文件...", /*menu_resume*/ "继续显示",
    /*script_new*/ "新建", /*script_open_folder*/ "打开文件夹",
    /*script_reload*/ "重新加载", /*script_clear_log*/ "清空日志",
    /*script_empty_title*/ "请选择脚本", /*script_empty_detail*/ "从左侧列表挑选",
    /*repl_label*/ "命令行",
    /*plugin_windows*/ "插件窗口",
    /*scope_follow*/ "跟随",
    /*scope_hint*/ "拖拽:平移  滚轮:缩放  双击:适应",
    /*scope_empty_title*/ "无波形数据",
    /*scope_empty_detail*/ "脚本调用 wave.push(series, y) 推送数据",
    /*scope_axis_x*/ "时间 (秒)",
    /*scope_dt_fmt*/ "间隔 = %.3f 秒",
    /*serial_label_col*/ 56.0f,
};

constexpr Lang kLangEn{
    /*online*/ "ONLINE", /*offline*/ "OFFLINE",
    /*chip_lua*/ "Lua", /*chip_scope*/ "Scope", /*chip_set*/ "Set",
    /*section_port*/ "CONNECTION", /*select_port*/ "Select a port",
    /*open*/ "Open", /*close*/ "Close",
    /*section_serial*/ "SERIAL PROFILE", /*more*/ "MORE", /*custom*/ "CUSTOM",
    /*section_recv*/ "DISPLAY",
    /*hex_display*/ "HEX", /*timestamp*/ "Time",
    /*pause*/ "Pause", /*auto_clear*/ "Clear", /*save_to_file*/ "Save",
    /*charset*/ "Charset", /*frame_gap*/ "Frame Gap", /*ms*/ "ms",
    /*tab_single*/ "Single", /*tab_multi*/ "Multi",
    /*send_hex*/ "HEX", /*send_newline*/ "NEWLINE", /*send_auto*/ "AUTO",
    /*send*/ "Send", /*run*/ "Run", /*loop*/ "Loop", /*gap*/ "gap",
    /*waiting*/ "WAITING FOR SERIAL DATA", /*ready*/ "Ready", /*open_a_port*/ "Open a port",
    /*refresh_tip*/ "Refresh ports", /*save_tip*/ "Save receive log",
    /*clear_tip*/ "Clear receive log", /*path_tip*/ "Choose log path",
    /*settings_title*/ "Settings", /*general_tab*/ "General", /*appearance*/ "APPEARANCE",
    /*font_size*/ "Font size", /*mono_cjk_label*/ "Show Chinese in receive",
    /*scope_title*/ "Scope", /*scripts_title*/ "Script Console",
    /*send_slot_tip_prefix*/ "Send slot %d",
    /*parity*/ {"None", "Odd", "Even", "Mark", "Space"},
    /*flow*/ {"None", "RTS / CTS", "XON / XOFF"},
    /*open_line_label*/ "OPEN LINES",
    /*open_line_items*/ {"Deassert", "Assert", "Leave alone"},
    /*serial_field_labels*/ {"BAUD", "DATA", "STOP", "PARITY", "FLOW"},
    /*subtitle*/ "SERIAL CONSOLE",
    /*menu_select_all*/ "Select all", /*menu_copy*/ "Copy", /*menu_paste*/ "Paste",
    /*menu_copy_sel*/ "Copy selection", /*menu_copy_all*/ "Copy retained tail",
    /*menu_copy_strip_ts*/ "Copy without timestamps", /*menu_clear_log*/ "Clear log",
    /*menu_save_log*/ "Save log to file...", /*menu_resume*/ "Resume display",
    /*script_new*/ "New", /*script_open_folder*/ "Open folder",
    /*script_reload*/ "Reload", /*script_clear_log*/ "Clear log",
    /*script_empty_title*/ "SELECT A SCRIPT", /*script_empty_detail*/ "pick one from the list",
    /*repl_label*/ "REPL",
    /*plugin_windows*/ "PLUGIN WINDOWS",
    /*scope_follow*/ "Follow",
    /*scope_hint*/ "drag: pan  wheel: zoom  dbl-click: fit",
    /*scope_empty_title*/ "NO SCOPE DATA",
    /*scope_empty_detail*/ "wave.push(series, y) from a script feeds this plot",
    /*scope_axis_x*/ "time (s)",
    /*scope_dt_fmt*/ "dt = %.3f s",
    /*serial_label_col*/ 48.0f,
};


// Selection-anchor sentinels for the receive-log drag selection.  Byte
// offsets into receive_text_; kNoSelAnchor means "no active selection",
// kSelDragging marks "left button held, range extends with the drag".
constexpr std::size_t kNoSelAnchor = static_cast<std::size_t>(-1);
constexpr std::size_t kSelDragging = static_cast<std::size_t>(-2);

// ---- Font size knobs (single source of truth) -----------------------------
// Every font size in this TU derives from these constants — the settings-page
// radio labels, the pre-baked body faces, the heading face and the mono face
// (plus its CJK merge) all reference them, so retuning one knob updates the
// whole UI in one place.  CJK merges bake at (Latin size - kCjkShrinkPx):
// square hanzi fill their em box and read larger than the Latin x-height at
// equal px (that imbalance is what pushed "毫秒" off its sidebar row).
namespace fontsz {
inline constexpr std::array<float, 3> kBodySizes{13.0f, 15.0f, 17.0f};  // pre-baked body faces
inline constexpr int   kBodyDefaultIndex = 1;      // 15px default face
inline constexpr float kHeading  = 16.0f;          // header/title face
inline constexpr float kMono     = 15.0f;          // receive-log face
inline constexpr float kTitle    = 17.0f;          // "XCOM" brand text
inline constexpr float kSubtitle = 12.0f;          // header strapline
inline constexpr float kCjkShrinkPx = 1.0f;        // CJK = Latin - this
}   // namespace fontsz


// ---- ImPlot oscilloscope capacities (namespace scope: the C exports and
// the Runtime both use them; the previous class-private constants were
// unreachable from the extern "C" functions). ----
constexpr int kScopeChannelsMax = 4;
constexpr int kScopePointsMax = 20000;   // 4 ch * 20k * 2 arr * 4 B = 640 KB
struct ScopeChannel final {
    float xs[kScopePointsMax] = {};
    float ys[kScopePointsMax] = {};
    int offset = 0;
    int count = 0;
    bool visible = true;
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
    ImFont* mono_font_ = nullptr;
    LayoutConfig layout_{};
    std::string receive_text_{};
    std::string status_text_{};
    bool receive_follow_tail_ = true;
    float receive_scroll_y_ = 0.0f;
    // Text selection over the receive log (drag with the left button).
    // sel_begin/sel_end are the ordered pair the renderer shades, kept in
    // ABSOLUTE lifetime bytes (see receive_base_) so a window slide cannot
    // re-point them at different content.  anchor == kNoSelAnchor means "no
    // selection"; anchor == kSelDragging means "mouse is held, extend the
    // range" (both constants live at file scope above the class).
    std::size_t receive_sel_anchor_ = kNoSelAnchor;
    std::size_t receive_sel_begin_ = 0;
    std::size_t receive_sel_end_ = 0;
    // Absolute byte where the current drag started (set on the first row hit).
    std::size_t receive_sel_drag_origin_ = 0;
    bool receive_sel_drag_hit_ = false;
    // Byte offset of every line start in receive_text_ (offset 0 included);
    // rescanned by xcom_imgui_set_receive_text and consumed by the receive
    // clipper so per-frame rendering walks only visible lines.
    std::vector<std::size_t> receive_line_offsets_{};
    // Lifetime byte counter for the receive log: the absolute offset of
    // receive_text_[0].  Lua replaces the whole view buffer with a sliding
    // tail window on every flush, so window-relative selection offsets
    // would re-point at different content each push.  The selection
    // (begin/end/drag-origin) is therefore stored in ABSOLUTE bytes and
    // mapped to the window by subtracting receive_base_ at render time.
    std::size_t receive_base_ = 0;
    // Receive-tail window in bytes, minus the NUL.  Configurable at runtime
    // via xcom_imgui_set_receive_window ([display] receive_window_bytes in
    // config.ini); the historical fixed size is the default.
    std::size_t receive_limit_ = 64U * 1024U - 1U;
    // Pending receive-copy request.  Ctrl+C and the receive context menu queue
    // the bytes the user asked to copy here instead of writing the clipboard
    // directly, so the Lua bridge can apply the optional timestamp strip
    // (core/receive_copy.lua) before it sets the clipboard.  Empty == none
    // (we never queue an empty range).
    std::string receive_copy_pending_{};
    // ---- Phase 4 feature-extension state --------------------------------
    // All pointers below are LUA-OWNED: the Lua bridge allocates int[1]
    // buffers and registers them through the setter exports before the first
    // draw.  They are never cached or copied here — the established
    // ComboSpec discipline (see draw_console) applies: a rebuilt Lua bridge
    // hands new addresses in.
    int* baud_custom_ = nullptr;      // >0 overrides the preset BAUD combo
    int* multi_gap_ = nullptr;        // sequential-send inter-command delay ms
    int* charset_ = nullptr;          // index into kCharsetItems
    int* frame_gap_en_ = nullptr;     // auto frame-break toggle
    int* frame_gap_ms_ = nullptr;     // auto frame-break threshold ms
    int* copy_strip_ts_ = nullptr;    // receive copy: strip injected timestamps
    int* dtr_open_ = nullptr;         // open-time DTR: XCOM_LINE_* (0/1/2)
    int* rts_open_ = nullptr;         // open-time RTS: XCOM_LINE_* (0/1/2)
    // Keyword-highlight rules pushed from the Lua script engine.  Rendering
    // walks only clipper-visible lines x rules (see ReceiveContent), so the
    // per-frame cost is bounded regardless of log size.
    struct HighlightRule final {
        std::string pattern;          // plain substring (no regex)
        ImU32 color = 0;              // packed ABGR
        bool background = false;      // true: rect fill; false: colored text
    };
    std::vector<HighlightRule> highlight_rules_{};
    // Script console (floating window; header "Lua" button toggles it).
    bool scripts_visible_ = false;
    std::vector<std::string> script_names_{};
    // Display labels, index-aligned with script_names_.  Carries each script's
    // @name when it declared one, else the filename (Lua decides — see
    // core/script_engine.lua meta.display_name).  Kept SEPARATE from
    // script_names_ so the latter stays the stable index key: script_events_
    // carry only an index, and Lua maps it back through script_names().
    // Empty on a pre-labels DLL/Lua pair, in which case the console falls back
    // to script_names_ for rendering.
    std::vector<std::string> script_labels_{};
    // Hover tooltips for the script list, index-aligned with script_names_
    // exactly like script_labels_.  An EMPTY entry means "no tooltip" (a script
    // with neither @desc nor @name), so the renderer skips it rather than
    // opening an empty box.  Pushed by Lua through xcom_imgui_set_script_descs;
    // this vector owns its own strings, same lifetime as the labels above.
    std::vector<std::string> script_descs_{};
    int* script_enabled_ = nullptr;   // Lua-owned int[count]
    std::string script_log_{};        // full log text (Lua pushes the tail)
    std::vector<std::size_t> script_log_lines_{1, 0};  // line offsets
    bool script_log_follow_ = true;
    std::vector<int> script_events_{};   // packed (type<<8)|index
    char script_command_[512]{};         // REPL input (Lua drains it)
    bool script_command_ready_ = false;
    // Embedded editor state.  script_edit_index_ < 0 means "no file loaded".
    int script_edit_index_ = -1;
    std::string script_edit_path_{};
    std::string script_edit_buf_{1, '\0'};  // ImGui-owned NUL-terminated buffer
    bool script_edit_dirty_ = false;        // content differs from last save
    // CJK glyph ranges for the merged mono font.  Held as a Runtime member
    // (NOT a function-local static): AddFontFromFileTTF stores the POINTER,
    // so the ranges must outlive the font atlas — see docs/imgui-patterns-
    // reference.md section 6 for the lifetime analysis.
    ImVector<ImWchar> cjk_ranges_{};
    // Minimal glyph set for the localized body/heading faces: every code
    // point actually present in kLangZh/kLangEn (plus the plugin-page font
    // picker digits).  Built with AddText, NOT a stock CJK table — the full
    // ChineseSimplifiedCommon merge at four extra sizes blew the WARP atlas
    // budget (silent no-draw failure), a ~120-glyph merge cannot.  Same
    // pointer-lifetime contract as cjk_ranges_ above.
    ImVector<ImWchar> ui_glyph_ranges_{};
    // [font] mono_cjk switch from assets/layout.toml.  Default OFF so the
    // optional ~26 MB receive-log CJK merge is not resident unless the user
    // explicitly turns "show Chinese in receive" on (memory-first default).
    bool font_mono_cjk_ = false;
    // Set by the settings checkbox when the mono-CJK toggle changes; consumed
    // at the top of xcom_imgui_new_frame (never mid-draw) to rebuild fonts.
    bool font_rebuild_pending_ = false;
    // ---- ImPlot oscilloscope (scope) --------------------------------------
    // Per-channel ring buffer, the official ScrollingBuffer pattern
    // (implot_demo.cpp:140-163): fixed-capacity arrays + Offset; PlotLine
    // reads them in place through ImPlotSpec.Offset/Stride (zero reorder).
    // Pushed from Lua (xcom_imgui_scope_push) with uv.now() timestamps.
    // Capacity constants live at namespace scope (kScopeChannelsMax/…
    // below the class) so the C exports can reach them.
    ScopeChannel scope_[kScopeChannelsMax]{};
    float scope_history_s_ = 10.0f;   // trailing X window (seconds)
    bool scope_follow_ = true;        // false while the user pans back
    bool scope_y_fit_ = true;         // auto-fit Y (serial numeric streams)
    double scope_cursor_a_ = 0.0;     // measurement cursor A (seconds)
    double scope_cursor_b_ = 0.0;     // measurement cursor B (seconds)
    // Scope panel visibility.  No header chip toggles it any more: Lua drives
    // it from script activity (window.lua _reconcile_scope_visibility ->
    // xcom_imgui_scope_set_visible) and the panel's own title-bar X clears it
    // (reporting ActionToggleScope so Lua resyncs).
    bool scope_visible_ = false;
    bool scope_has_data_ = false;
    double scope_last_x_ = 0.0;
    // Settings popup (header "Set" chip).  Body-size fonts are pre-baked at
    // three px sizes; the radio re-points io.FontDefault (no atlas rebuild).
    bool settings_visible_ = false;
    ImFont* body_fonts_[3]{};   // 13 / 15 / 17 px, nullptr entries unusable
    int body_font_index_ = 1;
    // ---- Lua plugin pages ---------------------------------------------------
    // Lua declares settings pages through xcom_imgui_set_plugin_page() with a
    // line-oriented widget grammar (see ui::RenderPluginSpec).  This keeps the
    // DLL free of any lua_State knowledge (a cimgui FFI binding would break
    // the moment the vendored ImGui minor version drifts) while still letting
    // scripts add dynamic UI; interactions flow back as strings via
    // xcom_imgui_take_plugin_events.
    struct PluginPage final {
        static constexpr int kWidgetsMax = 32;
        std::string id;
        std::string title;
        std::string spec;
        // Live widget values, indexed by spec line (check 0/1, slider/combo
        // raw number / item index).  Defaults are parsed from the spec once
        // per declaration (values_ready_ gate), never by render-time probes.
        double values_[kWidgetsMax]{};
        bool values_ready_ = false;
        // Independent-window state (user ask: "lua插件生成的界面最好是独立的
        // 窗口").  Each plugin page is its own top-level ImGui window; the
        // Settings window keeps a toggle per page so a window the user closed
        // (X) can be re-opened.  Defaults to OPEN on declaration so enabling a
        // plugin shows its UI without a second click.
        bool window_open_ = true;
        bool window_appeared_ = false;   // first-frame position seed
    };
    std::vector<PluginPage> plugin_pages_{};         // declaration order
    std::vector<std::string> plugin_events_{};       // "page:kind:id[:value]"

    // Active UI language, resolved from [ui] language in layout.toml during
    // init (load_layout_config).  Defaults to Chinese (1.png is Chinese).
    bool ui_lang_zh_ = true;
    const Lang& lang() const noexcept { return ui_lang_zh_ ? kLangZh : kLangEn; }
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
    ActionSendSlot0 = 1 << 19,
    ActionSendSlot1 = 1 << 20,
    ActionSendSlot2 = 1 << 21,
    ActionSendSlot3 = 1 << 22,
    ActionSendSlot4 = 1 << 23,
    ActionSendSlot5 = 1 << 24,
    ActionSendSlot6 = 1 << 25,
    ActionSendSlot7 = 1 << 26,
    // Phase 4 feature extensions (Lua mirrors these in ui/window.lua
    // IMGUI_ACTION as scripts_window / run_sequence).
    ActionToggleScripts = 1 << 27,   // header "Lua" button -> script console
    ActionRunSequence = 1 << 28,     // Multi-tab "Run": sequential command list
    ActionToggleScope = 1 << 29,     // scope panel's own X (no header chip now)
    ActionToggleSettings = 1 << 30,  // header "Set" chip -> settings window
};

// Script-console event types reported through xcom_imgui_take_script_events;
// the packed event value is (type << 8) | script_index.
enum class ScriptEvent : std::uint8_t {
    Edit = 1,          // open this script in the embedded editor
    Reload = 2,        // reload this script now
    OpenFolder = 3,    // shell-open the scripts directory
    ClearLog = 4,      // clear the log panel
    NewScript = 5,     // create a new script (Lua supplies the name)
};

constexpr std::uint32_t action_mask(const Action action) noexcept {
    return static_cast<std::uint32_t>(action);
}

constexpr int& operator|=(int& value, const Action action) noexcept {
    value |= static_cast<int>(action_mask(action));
    return value;
}

static_assert(action_mask(Action::ActionOpen) == (std::uint32_t{1} << 0));
static_assert(action_mask(Action::ActionCloseWindow) == (std::uint32_t{1} << 18));
static_assert(action_mask(Action::ActionToggleScripts) == (std::uint32_t{1} << 27));
static_assert(action_mask(Action::ActionRunSequence) == (std::uint32_t{1} << 28));
static_assert(action_mask(Action::ActionToggleScope) == (std::uint32_t{1} << 29));
static_assert(action_mask(Action::ActionToggleSettings) == (std::uint32_t{1} << 30));

constexpr Action send_slot_action(const std::uint32_t index) noexcept {
    return static_cast<Action>(std::uint32_t{1} << (19 + index));
}

template <Action ActionValue>
struct Command final {
    template <typename Invocable, typename... Args>
    [[nodiscard]] static int Execute(Invocable&& invocable, Args&&... args) {
        static_assert(std::is_invocable_r_v<bool, Invocable, Args...>,
                      "UI commands must invoke a bool-returning control");
        return std::invoke(std::forward<Invocable>(invocable), std::forward<Args>(args)...)
            ? static_cast<int>(action_mask(ActionValue)) : 0;
    }
};
ImVec4 color(float r, float g, float b, float a = 1.0f) { return ImVec4(r, g, b, a); }
ImVec4 rgb(std::uint32_t value, float alpha = 1.0f) {
    return color(((value >> 16) & 0xff) / 255.0f, ((value >> 8) & 0xff) / 255.0f,
                 (value & 0xff) / 255.0f, alpha);
}

// Named palette (single source for every hard-coded colour in the dashboard;
// keep in sync with ui/window.lua's PAL and assets/layout.toml).  Extracted
// from the reference serial tool screenshot pic/1.png (see
// docs/1png-control-buttons.md and docs/1png-separators-status-font.md):
// blue-white window, blue SEND button, orange timestamps, red TX echo.
namespace palette {
    // Single source of truth; all values come from PIL pixel scans of pic/1.png
    // (2026-09-05), NOT from memory or 2.png/3.png. See
    // docs/1png-separators-status-font.md for the measurements.
    constexpr std::uint32_t kHeaderDark = 0x1E1E1E;   // header strip / dark buttons
    constexpr std::uint32_t kAccentTeal = 0x005A98;   // primary blue (1.png sampled: 909 px)
    constexpr std::uint32_t kAccentHover = 0x2E7FC4;  // primary button hover (extrapolated)
    constexpr std::uint32_t kAccentPress = 0x004270;  // pressed / heading blue (1.png: 344 px)
    constexpr std::uint32_t kHeaderChrome = 0x1D5785; // window button hover
    constexpr std::uint32_t kHeaderChromeDown = 0x004270; // window button press
    constexpr std::uint32_t kTextInverse = 0xFFFFFF;  // on-dark text / knob
    constexpr std::uint32_t kTextHeading = 0x004270;  // section heading (1.png deep blue)
    constexpr std::uint32_t kTextMuted = 0x8C8C8C;    // field labels / disabled
    constexpr std::uint32_t kTextBody = 0x1B1B1B;     // default text (1.png near-black)
    constexpr std::uint32_t kStatusOnline = 0x7AD8D8; // ONLINE badge (kept)
    constexpr std::uint32_t kStatusOffline = 0xFFD28A; // OFFLINE badge (kept)
    constexpr std::uint32_t kHeaderSubtitle = 0xCDEBFA; // header strapline
    constexpr std::uint32_t kToggleOff = 0xD5DCE3;    // toggle track (disabled)
    constexpr std::uint32_t kSurfaceLight = 0xFFFFFF; // receive log (1.png pure white)
    constexpr std::uint32_t kSurfaceDefault = 0xFBFCFD; // window / toolbar (1.png pale blue-white)
    constexpr std::uint32_t kSurfaceZone = 0xFEFEFE;  // TX editor + footer bands (1.png measured near-white)
    constexpr std::uint32_t kSurfaceSidebar = 0xEEEEF0; // right sidebar (1.png plain band: 60k+ px
                                                        // dominant in the control-column region)
    constexpr std::uint32_t kTimestamp = 0xF8AA00;    // "[HH:MM:SS.mmm] " prefixes (1.png exact: 367 px)
    constexpr std::uint32_t kRule = 0xEDEDED;         // 1px hairline separator (1.png sampled at y=60)
    constexpr std::uint32_t kHairline = 0xE6E6E6;     // pure inner separators (sidebar section rules /
                                                      // footer column divider): lighter than kRule,
                                                      // 1.png near-invisible hairline doctrine
    constexpr std::uint32_t kSidebarDivider = 0xEFEFEF; // column-gap line beside the sidebar: 1.png's
                                                      // trench band there runs #EFEFF1..#EEEEF0 (50k+
                                                      // px), i.e. lighter than the kRule header line
    constexpr std::uint32_t kPanelBorder = 0xD5D5D5;  // combo / input / header-chip border (1.png sampled)
    constexpr std::uint32_t kDangerRed = 0xC00500;    // danger / Close button (1.png exact: 606 px)
    constexpr std::uint32_t kSendBlue = 0x004275;     // SEND button fill (1.png measured, send zone)
    constexpr std::uint32_t kSendBlueHover = 0x2E7FC4;
    constexpr std::uint32_t kSendBluePress = 0x003157;
    constexpr std::uint32_t kTxRed = 0xD04138;        // echoed TX text (1.png sampled)
}

namespace ui {
// CRTP tag base (conventions §6.1 "骨架 + 钩子", §7 line 279 "拷贝/赋值 =
// delete").  Three near-identical scope guards below (PanelScope,
// ScopedHeadingFont, ScopedAction) each hand-rolled the same copy/assign
// deletion, which meets the §5.9 line 222 "出现第三处结构相似时才提取" bar for
// factoring.  The base holds NO per-instance state (§6.1 line 233 red line)
// and its destructor is protected+non-virtual, so a guard can never be sliced
// or deleted through a base pointer — only the concrete derived type lives on
// the stack, exactly as before.  Move stays implicitly deleted (derived
// classes declare a destructor), preserving the current guaranteed-RVO usage.
template <typename Derived>
class NonCopyable {
protected:
    NonCopyable() noexcept = default;
    ~NonCopyable() = default;
    NonCopyable(const NonCopyable&) = delete;
    NonCopyable& operator=(const NonCopyable&) = delete;
};

class PanelScope final : private NonCopyable<PanelScope> {
public:
    PanelScope(const char* id, const ImVec2& size, bool border,
               ImGuiWindowFlags flags, const ImVec4& background)
        : visible_(false) {
        ImGui::PushStyleColor(ImGuiCol_ChildBg, background);
        visible_ = ImGui::BeginChild(id, size, border, flags);
        ImGui::PopStyleColor();
    }
    ~PanelScope() { ImGui::EndChild(); }
    [[nodiscard]] explicit operator bool() const noexcept { return visible_; }
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
class ScopedHeadingFont final : private NonCopyable<ScopedHeadingFont> {
public:
    explicit ScopedHeadingFont(ImFont* font) : font_(font) {
        if (font_) ImGui::PushFont(font_);
    }
    ~ScopedHeadingFont() {
        if (font_) ImGui::PopFont();
    }
private:
    ImFont* font_;
};

// Minimal zero-allocation scope guard that runs a pop/close callable on scope
// exit.  Used to balance ImGui push/pop and Begin/End pairs (e.g. EndChild,
// PopStyleColor) without the heap-indirection of std::function.
template <typename PopFn>
class ScopedAction final : private NonCopyable<ScopedAction<PopFn>> {
public:
    explicit ScopedAction(PopFn&& pop) : pop_(std::move(pop)) {}
    ~ScopedAction() { pop_(); }
private:
    PopFn pop_;
};

PanelScope Panel(const char* id, const ImVec2& size, bool border = true,
                 ImGuiWindowFlags flags = 0,
                 ImVec4 background = rgb(palette::kSurfaceDefault)) {
    return PanelScope(id, size, border, flags, background);
}

void Section(std::string_view title, std::string_view subtitle = {}, bool separator = false) {
    const float start_x = ImGui::GetCursorPosX();
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
        ImGui::SetCursorPosX(start_x);
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

[[nodiscard]] bool GridComboField(const ComboSpec& spec) {
    ImGui::TableNextColumn();
    // Reference alignment: labels RIGHT-aligned in the label column, values
    // on a common left edge in the value column (two-column scan grid).
    const float label_width = ImGui::CalcTextSize(spec.label).x;
    const float col_width = ImGui::GetContentRegionAvail().x;
    ImGui::SetCursorPosX(ImGui::GetCursorPosX() +
                         (std::max)(0.0f, col_width - label_width - 2.0f));
    ImGui::TextColored(rgb(palette::kTextMuted), "%s", spec.label);
    ImGui::TableNextColumn();
    ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(4.0f, 3.0f));
    ImGui::SetNextItemWidth(-1.0f);
    const bool changed = ImGui::Combo(spec.id, spec.value, spec.items, spec.count);
    ImGui::PopStyleVar();
    return changed;
}

[[nodiscard]] bool Toggle(const char* label, int* value);
[[nodiscard]] bool PrimaryAction(const char* label, const ImVec2& size);
[[nodiscard]] bool DangerAction(const char* label, const ImVec2& size);
[[nodiscard]] bool SendAction(const char* label, const ImVec2& size);
void EmptyState(std::string_view title, std::string_view detail);

enum class UtilityIcon : std::uint8_t { Clear, Save, Path, Refresh };

[[nodiscard]] bool IconButton(const char* id, const UtilityIcon icon,
                              const char* tooltip) {
    // 28×26 was 24×22: larger hit area + heavier icon shapes (1.8 px stroke)
    // match the 13-15 px text size of the surrounding controls, so the
    // toolbar reads as one weight instead of "shrinking icons vs body text".
    constexpr ImVec2 kSize(28.0f, 26.0f);
    const bool pressed = ImGui::InvisibleButton(id, kSize);
    const ImVec2 minimum = ImGui::GetItemRectMin();
    const ImVec2 maximum = ImGui::GetItemRectMax();
    ImDrawList* const draw_list = ImGui::GetWindowDrawList();
    // kTextBody instead of kTextMuted: contrast ~8:1 vs 0xEDF3F7 panel bg,
    // above the 3:1 threshold for non-text UI components.  kTextMuted gave
    // a ghost-grey look on the light surface.
    const ImU32 stroke = ImGui::GetColorU32(rgb(palette::kTextBody));
    if (ImGui::IsItemHovered()) {
        draw_list->AddRectFilled(minimum, maximum,
                                 ImGui::GetColorU32(rgb(0xE0E7E1)), 3.0f);
    }
    const ImVec2 center((minimum.x + maximum.x) * 0.5f,
                        (minimum.y + maximum.y) * 0.5f);
    if (icon == UtilityIcon::Clear) {
        draw_list->AddLine(ImVec2(center.x - 6.0f, center.y - 6.0f), ImVec2(center.x + 6.0f, center.y + 6.0f), stroke, 1.8f);
        draw_list->AddLine(ImVec2(center.x + 6.0f, center.y - 6.0f), ImVec2(center.x - 6.0f, center.y + 6.0f), stroke, 1.8f);
    } else if (icon == UtilityIcon::Save) {
        draw_list->AddRect(ImVec2(center.x - 6.0f, center.y - 7.0f), ImVec2(center.x + 6.0f, center.y + 7.0f), stroke, 1.8f);
        draw_list->AddLine(ImVec2(center.x - 4.0f, center.y - 4.0f), ImVec2(center.x + 4.0f, center.y - 4.0f), stroke, 1.8f);
        draw_list->AddRectFilled(ImVec2(center.x - 4.0f, center.y + 1.0f), ImVec2(center.x + 4.0f, center.y + 5.0f), stroke);
    } else if (icon == UtilityIcon::Path) {
        draw_list->AddRect(ImVec2(center.x - 7.0f, center.y - 3.0f), ImVec2(center.x + 7.0f, center.y + 6.0f), stroke, 1.8f);
        draw_list->AddLine(ImVec2(center.x - 6.0f, center.y - 3.0f), ImVec2(center.x - 1.0f, center.y - 7.0f), stroke, 1.8f);
        draw_list->AddLine(ImVec2(center.x - 1.0f, center.y - 7.0f), ImVec2(center.x + 2.0f, center.y - 3.0f), stroke, 1.8f);
    } else {
        draw_list->AddCircle(center, 6.0f, stroke, 12, 1.8f);
        draw_list->AddTriangleFilled(ImVec2(center.x + 7.0f, center.y - 6.0f), ImVec2(center.x + 7.0f, center.y + 1.0f), ImVec2(center.x + 2.0f, center.y - 2.0f), stroke);
    }
    if (ImGui::IsItemHovered()) ImGui::SetTooltip("%s", tooltip);
    return pressed;
}

enum class WindowButtonKind : std::uint8_t { Minimize, Maximize, Close };

bool WindowButton(const char* id, WindowButtonKind kind, ImDrawList* draw_list) {
    // 24px tall so the 2px-inset buttons fit the 30px header exactly
    // (1.png header band is 30 logical px).
    const ImVec2 size(30.0f, 24.0f);
    const bool pressed = ImGui::InvisibleButton(id, size);
    const ImVec2 min = ImGui::GetItemRectMin();
    const ImVec2 max = ImGui::GetItemRectMax();
    const bool hovered = ImGui::IsItemHovered();
    const bool active = ImGui::IsItemActive();
    // Light header: window buttons are borderless glyphs on the header face
    // (1.png shows no dark slabs); only hover/press states paint a chip.
    const ImU32 background = ImGui::GetColorU32(
        kind == WindowButtonKind::Close
            ? (active ? rgb(0xA61B1B) : (hovered ? rgb(0xC93636) : rgb(palette::kSurfaceDefault)))
            : (active ? rgb(palette::kHeaderChromeDown)
                      : (hovered ? rgb(palette::kHeaderChrome) : rgb(palette::kSurfaceDefault))));
    draw_list->AddRectFilled(min, max, background, 2.0f);
    // Glyph strokes follow the header text color so they stay legible on the
    // light face; on press (dark/blue chip) the glyph inverts.
    const ImU32 icon = ImGui::GetColorU32(
        active ? rgb(palette::kTextInverse) : rgb(palette::kTextBody));
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
    // 1.png header is light (top rows measured #FBFCFD; #1E1E1E = 0 px in the
    // reference), so the dark slab and the 3px blue bottom strip are gone; a
    // 1px hairline separates it from the work area.
    ImGui::PushStyleColor(ImGuiCol_ChildBg, rgb(palette::kSurfaceDefault));
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
    constexpr float kBrandInset = 2.0f;
    // 1.png brand mark (x31..61, y16..51 measured): a BORDERLESS line-art
    // double-A glyph in primary blue #005A9E plus a short underline bar — no
    // filled tile, no white knockout.  Draw the strokes directly on the light
    // header face in kAccentTeal, then a 2px underline rect at the baseline
    // spanning the glyph width (AddRectFilled, integer edges — an AddLine
    // would anti-alias and bleed, cf. the footer top-rule note below).
    {
        const float bx = position.x + kBrandInset;
        const ImU32 mark = ImGui::GetColorU32(rgb(palette::kAccentTeal));
        const float top = brand_center_y - 12.0f;
        const float foot = brand_center_y + 7.0f;
        // Large A: apex + two legs + crossbar.
        draw_list->AddLine(ImVec2(bx + 16.0f, top), ImVec2(bx + 10.0f, foot), mark, 1.5f);
        draw_list->AddLine(ImVec2(bx + 16.0f, top), ImVec2(bx + 22.0f, foot), mark, 1.5f);
        draw_list->AddLine(ImVec2(bx + 12.5f, brand_center_y + 3.0f),
                           ImVec2(bx + 19.5f, brand_center_y + 3.0f), mark, 1.5f);
        // Small A (left, overlapping): shorter, same construction.
        draw_list->AddLine(ImVec2(bx + 7.0f, top + 5.0f), ImVec2(bx + 3.5f, foot), mark, 1.5f);
        draw_list->AddLine(ImVec2(bx + 7.0f, top + 5.0f), ImVec2(bx + 11.0f, foot), mark, 1.5f);
        draw_list->AddLine(ImVec2(bx + 4.5f, brand_center_y + 4.0f),
                           ImVec2(bx + 9.5f, brand_center_y + 4.0f), mark, 1.5f);
        // Underline bar: 2px, glyph-width (ref y46..51 = ~2px app).
        draw_list->AddRectFilled(ImVec2(bx + 3.0f, brand_center_y + 9.0f),
                                 ImVec2(bx + 22.0f, brand_center_y + 11.0f), mark);
    }
    ImFont* const title_font = runtime.heading_font_ ? runtime.heading_font_ : ImGui::GetFont();
    const float title_size = fontsz::kTitle;
    // "XCOM" at a fixed size has a constant width — measure once per font
    // (function-local static keyed on the font/size pair) instead of every
    // frame through the glyph-lookup loop.
    static float cached_title_width = -1.0f;
    static const ImFont* cached_title_font = nullptr;
    static float cached_title_size = 0.0f;
    if (cached_title_font != title_font || cached_title_size != title_size ||
        cached_title_width < 0.0f) {
        cached_title_font = title_font;
        cached_title_size = title_size;
        cached_title_width = title_font->CalcTextSizeA(
            title_size, FLT_MAX, 0.0f, "XCOM").x;
    }
    const float title_y = brand_center_y - title_size * 0.5f + 3.0f;
    const ImVec2 title_pos(position.x + kBrandInset + 34.0f, title_y);
    const ImU32 header_text = ImGui::GetColorU32(rgb(palette::kTextBody));
    draw_list->AddText(title_font, title_size, title_pos, header_text, "XCOM");
    const float divider_x = title_pos.x + cached_title_width + 12.0f;
    draw_list->AddLine(ImVec2(divider_x, brand_center_y - 8.0f),
                       ImVec2(divider_x, brand_center_y + 8.0f),
                       ImGui::GetColorU32(rgb(palette::kPanelBorder)), 1.0f);
    const float subtitle_size = fontsz::kSubtitle;
    draw_list->AddText(ImGui::GetFont(), subtitle_size,
                        ImVec2(divider_x + 12.0f, brand_center_y - subtitle_size * 0.5f + 3.0f),
                       ImGui::GetColorU32(rgb(palette::kTextMuted)),
                       ImGuiRuntime::instance().lang().subtitle);
    const char* const status = connected ? runtime.lang().online : runtime.lang().offline;
    const float button_group_start = ImGui::GetWindowWidth() - 108.0f;
    // Header toggle chips ("Set"/"Lua", right-to-left).  1.png shows the header
    // controls borderless — icon-only, no frames — so the chips drop their
    // white tile + outline entirely and express selection state via GLYPH TINT
    // instead (selected = kAccentTeal, unselected = kTextBody).  The labels
    // stay text for now: the icon set doesn't exist yet (docs/1png-icons.md
    // §7), and inventing glyphs would drift from the reference.
    //
    // The "Scope" chip is gone: the ImPlot panel is script-owned now (Lua shows
    // it while a script feeds wave points — see window.lua
    // _reconcile_scope_visibility).  ActionToggleScope / scope_visible_ stay so
    // the title-bar X on the panel itself still toggles and notifies Lua.
    // Table-driven: one chip spec per header toggle, right-to-left order.
    {
        auto& runtime = ImGuiRuntime::instance();
        struct HeaderChip final {
            const char* id;
            const char* label;
            float x_offset;   // relative to button_group_start (negative)
            float width;
            Action action_bit;
            bool* visible;
        };
        const HeaderChip chips[] = {
            {"##lua_console", runtime.lang().chip_lua, -44.0f, 36.0f,
             Action::ActionToggleScripts, &runtime.scripts_visible_},
            {"##settings_toggle", runtime.lang().chip_set, -96.0f, 40.0f,
             Action::ActionToggleSettings, &runtime.settings_visible_},
        };
        for (const HeaderChip& chip : chips) {
            ImGui::SetCursorPos(ImVec2(button_group_start + chip.x_offset, 3.0f));
            const bool pressed = ImGui::InvisibleButton(chip.id, ImVec2(chip.width, 24.0f));
            const ImVec2 min = ImGui::GetItemRectMin();
            const ImVec2 max = ImGui::GetItemRectMax();
            const float text_w = ImGui::CalcTextSize(chip.label).x;
            draw_list->AddText(
                ImVec2((min.x + max.x) * 0.5f - text_w * 0.5f, min.y + 5.0f),
                ImGui::GetColorU32(rgb(*chip.visible ? palette::kAccentTeal
                                                     : palette::kTextBody)),
                chip.label);
            if (pressed) {
                actions |= chip.action_bit;
                // The header button owns the toggle; the bit also notifies
                // Lua.  (A window's title-bar X reports the same bit AFTER
                // flipping the state itself — see the content renderers.)
                *chip.visible = *chip.visible ? false : true;
            }
        }
    }
    // Both status strings are fixed literals: cache their widths, keyed on
    // the current default font (a bridge restart rebuilds the ImGui context
    // and hands out a different ImFont*, invalidating the cache).
    static float status_width_cache[2] = {-1.0f, -1.0f};
    static const ImFont* status_width_font = nullptr;
    if (status_width_font != ImGui::GetFont()) {
        status_width_font = ImGui::GetFont();
        status_width_cache[0] = -1.0f;
        status_width_cache[1] = -1.0f;
    }
    const int status_idx = connected ? 1 : 0;
    if (status_width_cache[status_idx] < 0.0f) {
        status_width_cache[status_idx] = ImGui::CalcTextSize(status).x;
    }
    const float status_width = status_width_cache[status_idx] + 32.0f;
    // The status text must clear the whole chip cluster, not just the 12px
    // margin: Set/Lua start at button_group_start - 96 (the Scope chip is
    // gone), so anchor the label to the left of that.
    constexpr float kChipClusterLeft = 96.0f;
    ImGui::SetCursorPos(ImVec2(button_group_start - kChipClusterLeft - status_width - 8.0f, 8.0f));
    const ImVec2 status_origin = ImGui::GetCursorScreenPos();
    ImGui::GetWindowDrawList()->AddCircleFilled(
        ImVec2(status_origin.x + 5.0f, status_origin.y + ImGui::GetFontSize() * 0.5f),
        3.0f, ImGui::GetColorU32(connected ? rgb(palette::kSendBlue) : rgb(palette::kDangerRed)));
    ImGui::SetCursorPosX(ImGui::GetCursorPosX() + 12.0f);
    // Light header: the badge dot carries the color; the label uses dark body
    // text (bright cyan would be unreadable on #FBFCFD).
    ImGui::TextColored(rgb(palette::kTextBody), "%s", status);
    ImGui::SetCursorPos(ImVec2(button_group_start, 2.0f));
    actions |= Command<Action::ActionMinimizeWindow>::Execute(
        [draw_list] { return WindowButton("##window_minimize", WindowButtonKind::Minimize, draw_list); });
    ImGui::SameLine(0.0f, 2.0f);
    actions |= Command<Action::ActionMaximizeWindow>::Execute(
        [draw_list] { return WindowButton("##window_maximize", WindowButtonKind::Maximize, draw_list); });
    ImGui::SameLine(0.0f, 2.0f);
    actions |= Command<Action::ActionCloseWindow>::Execute(
        [draw_list] { return WindowButton("##window_close", WindowButtonKind::Close, draw_list); });
    const float width = ImGui::GetWindowWidth();
    // 1.png has no solid blue accent bar under the header; a single hairline
    // (kRule #EDEDED, y60/61 measured) separates the light header from the
    // work area.  AddRectFilled on an integer row, NOT AddLine at a .5 offset
    // — an anti-aliased #EDEDED line over #FBFCFD blends to ~#C6C6C6 (the
    // old render), while a filled scanline paints the measured color exactly
    // (same crisp-rule pattern as the footer top rule).
    draw_list->AddRectFilled(ImVec2(position.x, position.y + layout.header_height - 1.0f),
                             ImVec2(position.x + width, position.y + layout.header_height),
                             ImGui::GetColorU32(rgb(palette::kRule)));
}

void ReceiveToolbar(int& actions, int rx_bytes, int tx_bytes, int* receive_hex,
                   int* timestamp, int* pause_display, int* auto_clear,
                   int* auto_clear_bytes, int* auto_save) {
    (void)rx_bytes;
    (void)tx_bytes;
    ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(0.0f, 0.0f));
    if (ImGui::BeginTable("##display_grid", 1, ImGuiTableFlags_SizingStretchProp |
                                           ImGuiTableFlags_NoPadOuterX)) {
        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::SetCursorPosX(kSidebarInset);
        if (Toggle(ImGuiRuntime::instance().lang().hex_display, receive_hex)) actions |= Action::ActionSyncDisplay;

        // 时间戳 on its own row (user: the two-toggle first row pushed the
        // label past the sidebar edge once labels went Chinese).
        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::SetCursorPosX(kSidebarInset);
        if (Toggle(ImGuiRuntime::instance().lang().timestamp, timestamp)) actions |= Action::ActionSyncDisplay;

        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::SetCursorPosX(kSidebarInset);
        if (Toggle(ImGuiRuntime::instance().lang().pause, pause_display)) actions |= Action::ActionSyncDisplay;

        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::SetCursorPosX(kSidebarInset);
        if (Toggle(ImGuiRuntime::instance().lang().auto_clear, auto_clear)) actions |= Action::ActionSyncDisplay;
        ImGui::SameLine(0.0f, 6.0f);
        ImGui::SetNextItemWidth(56.0f);
        if (ImGui::InputInt("##clear_bytes", auto_clear_bytes, 0, 0)) actions |= Action::ActionSyncDisplay;

        // The path/save/clear icon buttons moved to the receive-area toolbar
        // (ReceiveContent): the 180px sidebar clipped them at the window
        // edge.  "保存到文件" stays here as the state toggle only.
        ImGui::TableNextRow();
        ImGui::TableNextColumn();
        ImGui::SetCursorPosX(kSidebarInset);
        if (Toggle(ImGuiRuntime::instance().lang().save_to_file, auto_save)) actions |= Action::ActionSyncAutoSave;

        // Charset selector + auto frame-break (Phase 4 extension controls).
        // Both report through ActionSyncDisplay like every other receive
        // option — the Lua side reads the changed ints from its own buffers.
        auto& runtime = ImGuiRuntime::instance();
        if (runtime.charset_ != nullptr) {
            ImGui::TableNextRow();
            ImGui::TableNextColumn();
            ImGui::SetCursorPosX(kSidebarInset);
            ImGui::TextUnformatted(runtime.lang().charset);
            ImGui::SameLine(0.0f, 6.0f);
            ImGui::SetNextItemWidth(-1.0f);
            if (ImGui::Combo("##charset", runtime.charset_, kCharsetItems,
                             static_cast<int>(std::size(kCharsetItems)))) {
                actions |= Action::ActionSyncDisplay;
            }
        }
        if (runtime.frame_gap_en_ != nullptr && runtime.frame_gap_ms_ != nullptr) {
            ImGui::TableNextRow();
            ImGui::TableNextColumn();
            ImGui::SetCursorPosX(kSidebarInset);
            if (Toggle(runtime.lang().frame_gap, runtime.frame_gap_en_)) actions |= Action::ActionSyncDisplay;
            ImGui::SameLine(0.0f, 6.0f);
            ImGui::SetNextItemWidth(40.0f);
            if (ImGui::InputInt("##frame_gap_ms", runtime.frame_gap_ms_, 0, 0)) {
                actions |= Action::ActionSyncDisplay;
            }
            ImGui::SameLine(0.0f, 4.0f);
            ImGui::TextDisabled("%s", runtime.lang().ms);
        }
        ImGui::EndTable();
    }
    ImGui::PopStyleVar();
}

struct ToggleSpec final {
    const char* label;
    int* value;
    Action action;
    // When false the switch renders disabled: the label is still visible but the
    // knob cannot be flipped.  Used for RTS under RTS/CTS flow control, where the
    // driver owns the pin -- the panel must not offer a level it cannot command.
    // Defaults to true, so the existing three-field aggregates are unchanged.
    bool enabled = true;
};

template <size_t Count>
void RenderToggles(int& actions, const std::array<ToggleSpec, Count>& specs) {
    for (size_t index = 0; index < specs.size(); ++index) {
        if (index != 0) ImGui::SameLine();
        const ToggleSpec& spec = specs[index];
        // Always paired (BeginDisabled(false) is a no-op), so the disabled stack
        // stays balanced on every path.
        ImGui::BeginDisabled(!spec.enabled);
        if (Toggle(spec.label, spec.value)) actions |= spec.action;
        ImGui::EndDisabled();
    }
}

void TextContextMenu(const char* popup_id, char* buffer, const size_t capacity) {
    const ImGuiID item_id = ImGui::GetItemID();
    if (ImGui::IsItemHovered() && ImGui::IsMouseClicked(ImGuiMouseButton_Right))
        ImGui::OpenPopup(popup_id);
    if (!ImGui::BeginPopup(popup_id)) return;
    ImGuiInputTextState* const state = ImGui::GetInputTextState(item_id);
    const bool has_selection = state != nullptr && state->HasSelection();
    const Lang& lang = ImGuiRuntime::instance().lang();
    if (ImGui::MenuItem(lang.menu_select_all)) {
        if (state != nullptr) state->SelectAll();
    }
    if (ImGui::MenuItem(lang.menu_copy, nullptr, false, buffer != nullptr && buffer[0] != '\0')) {
        int begin = 0;
        int end = static_cast<int>(strlen(buffer));
        if (has_selection) {
            begin = state->GetSelectionStart();
            end = state->GetSelectionEnd();
        }
        if (end > begin) {
            std::string selected(buffer + begin, static_cast<size_t>(end - begin));
            ImGui::SetClipboardText(selected.c_str());
        }
    }
    if (ImGui::MenuItem(lang.menu_paste, nullptr, false, ImGui::GetClipboardText() != nullptr)) {
        const char* const clip = ImGui::GetClipboardText();
        if (clip != nullptr && buffer != nullptr && capacity > 0U) {
            const size_t length = (std::min)(strlen(clip), capacity - 1U);
            memcpy(buffer, clip, length);
            buffer[length] = '\0';
            if (state != nullptr) state->ReloadUserBufAndMoveToEnd();
        }
    }
    ImGui::EndPopup();
}

// Queue the ABSOLUTE lifetime byte range [begin_abs, end_abs) of the receive
// log as a copy request for the Lua bridge.  The range is clamped to the
// retained window (receive_base_ .. base+size): bytes that already scrolled
// out are unrecoverable -- the byte-faithful source is the auto-save log, not
// this normalized view.  An empty / fully-out-of-window range queues nothing.
// Returns true when bytes were queued.
bool QueueReceiveCopy(ImGuiRuntime& runtime, std::size_t begin_abs,
                      std::size_t end_abs) {
    const std::size_t window_end =
        runtime.receive_base_ + runtime.receive_text_.size();
    const std::size_t from = (std::max)(begin_abs, runtime.receive_base_);
    const std::size_t to = (std::min)(end_abs, window_end);
    if (to <= from) return false;
    runtime.receive_copy_pending_.assign(
        runtime.receive_text_, from - runtime.receive_base_, to - from);
    return true;
}

[[nodiscard]] int ReceiveContent(int rx_bytes, int tx_bytes, int* receive_hex, int* timestamp,
                   int* pause_display, int* auto_clear, int* auto_clear_bytes,
                   int* auto_save) {
    int actions = 0;
    auto& runtime = ImGuiRuntime::instance();
    const auto& layout = runtime.layout_;
    // The receive panel reserves only the transmit workspace below it.
    constexpr float kTransmitSectionReserve = 0.0f;
    const float transmit_block = layout.send_height + kTransmitSectionReserve;
    // 1.png: the receive log has no rectangular border — whitespace plus the
    // hairlines around it do the separation.
    const auto receive = Panel("##receive",
                               ImVec2(0, layout.receive_height == 0.0f ? -transmit_block : layout.receive_height),
                               false, 0, rgb(palette::kSurfaceLight));
    // Log utility toolbar (user: the path/save/clear icons were clipped at the
    // 180px sidebar's right edge; UartAssist/SSCOM keep them on the receive
    // area, which is always wide enough).  Right-aligned row of icon buttons
    // above the log; rendered BEFORE the empty-state early-return so the
    // buttons stay available even with no data yet.
    {
        ImGui::SetCursorPosX(ImGui::GetWindowWidth() - 3.0f * 28.0f - 2.0f * 4.0f - kSidebarInset);
        actions |= Command<Action::ActionClear>::Execute(
            [] { return IconButton("##clear_log", UtilityIcon::Clear,
                                   ImGuiRuntime::instance().lang().clear_tip); });
        ImGui::SameLine(0.0f, 4.0f);
        actions |= Command<Action::ActionSaveLog>::Execute(
            [] { return IconButton("##save_log", UtilityIcon::Save,
                                   ImGuiRuntime::instance().lang().save_tip); });
        ImGui::SameLine(0.0f, 4.0f);
        actions |= Command<Action::ActionChooseLogPath>::Execute(
            [] { return IconButton("##choose_log_path", UtilityIcon::Path,
                                   ImGuiRuntime::instance().lang().path_tip); });
    }
    if (runtime.receive_text_.empty()) {
        EmptyState(ImGuiRuntime::instance().lang().waiting, {});
        runtime.receive_follow_tail_ = true;
        runtime.receive_scroll_y_ = 0.0f;
        // Nothing left to select: an empty buffer invalidates any range.
        runtime.receive_sel_anchor_ = kNoSelAnchor;
        runtime.receive_sel_begin_ = 0;
        runtime.receive_sel_end_ = 0;
        runtime.receive_sel_drag_hit_ = false;
        runtime.receive_base_ = 0;
        return actions;
    }
    // Official ImGui log-window pattern (imgui_demo.cpp ShowExampleAppLog):
    // a scrolling child + one TextUnformatted per line through ImGuiListClipper,
    // with auto-scroll decided by "was the view at the bottom BEFORE this
    // frame's content grew".  The earlier InputTextMultiline viewport fought
    // this on two fronts: its internal stb_textedit layout engine only treats
    // '\n' as a line break (a trailing '\r' rendered as a glyph and broke the
    // row metric), and its own cursor/scroll state raced the follow logic.
    const std::vector<std::size_t>& offsets = runtime.receive_line_offsets_;
    // Capture the at-bottom state BEFORE any rendering mutates the scroll
    // range.  Scrolling away (wheel/drag/scrollbar) makes this false, which
    // detaches the follow; scrolling back to the bottom re-attaches it.
    const bool was_at_bottom =
        ImGui::GetScrollY() >= ImGui::GetScrollMaxY();
    runtime.receive_follow_tail_ = was_at_bottom;
    // --- text selection (drag with the left button) ---------------------
    // Hit-testing runs per submitted row using GetItemRectMin/Max after each
    // TextUnformatted — no manual scroll math, the rects are authoritative.
    // The byte offset inside the hit line is computed from the mouse x with
    // the glyph advance of the (mono) font.
    const ImGuiIO& io = ImGui::GetIO();
    const bool log_hovered = ImGui::IsWindowHovered(ImGuiHoveredFlags_AllowWhenBlockedByActiveItem);
    // Selection state machine:
    //   * mouse-down over the log  -> start a drag (anchor set on first hit)
    //   * mouse held               -> extend to the current hit offset
    //   * mouse released           -> selection persists until the next press
    // The byte offset for a mouse position is computed per submitted row
    // during the clipper pass (GetItemRectMin/Max is authoritative, no
    // manual scroll math).
    const bool sel_drag_start =
        log_hovered && ImGui::IsMouseClicked(ImGuiMouseButton_Left);
    if (sel_drag_start) {
        runtime.receive_sel_anchor_ = kSelDragging;
        runtime.receive_sel_begin_ = 0;
        runtime.receive_sel_end_ = 0;
        runtime.receive_sel_drag_hit_ = false;
    }
    const bool sel_dragging =
        runtime.receive_sel_anchor_ == kSelDragging &&
        ImGui::IsMouseDown(ImGuiMouseButton_Left);
    const bool has_selection = runtime.receive_sel_end_ > runtime.receive_sel_begin_;
    // Keyboard shortcuts mirroring the context menu.  Ctrl+A selects the whole
    // retained tail; Ctrl+C queues the selection for the Lua-side copy (which
    // applies the optional timestamp strip).  Shortcut()'s default routing is
    // focus-scope based: the receive child serves these only while it is on the
    // focus path, and an active InputText (send box / script editor) owns
    // Ctrl+A / Ctrl+C itself -- so this never steals a text edit's keys.  Same
    // mechanism as the script console's Ctrl+S.
    if (ImGui::Shortcut(ImGuiMod_Ctrl | ImGuiKey_A)) {
        runtime.receive_sel_begin_ = runtime.receive_base_;
        runtime.receive_sel_end_ =
            runtime.receive_base_ + runtime.receive_text_.size();
    }
    if (ImGui::Shortcut(ImGuiMod_Ctrl | ImGuiKey_C)) {
        QueueReceiveCopy(runtime, runtime.receive_sel_begin_,
                         runtime.receive_sel_end_);
    }
    // Render the log glyphs with the fixed-width data face when available so
    // hex bytes and RX counters line up column-wise (typical serial-monitor
    // look).  A consistent per-line row height also keeps the clipper metric
    // stable regardless of glyph width.
    const bool mono_ok = runtime.mono_font_ != nullptr;
    if (mono_ok) ImGui::PushFont(runtime.mono_font_);
    const auto pop_mono = ScopedAction([mono_ok] {
        if (mono_ok) ImGui::PopFont();
    });
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0.0f, 0.0f));
    ImDrawList* const draw = ImGui::GetWindowDrawList();
    const ImU32 sel_color = ImGui::GetColorU32(ImGuiCol_TextSelectedBg);
    // Timestamp prefix painted per line (see the tint pass in the clipper):
    // fixed 15-byte "[HH:MM:SS.mmm] " shape emitted by rx_timestamp_prefix
    // in xcom_core (kTimestampPrefixBytes there == kTsPrefixBytes here).
    constexpr std::size_t kTsPrefixBytes = 15;
    const bool ts_enabled = timestamp != nullptr && *timestamp != 0;
    const ImU32 ts_color = ImGui::GetColorU32(rgb(palette::kTimestamp));
    const float line_h = ImGui::GetTextLineHeight();
    const float text_width = ImGui::GetContentRegionAvail().x;
    // The mono log face is fixed-width: measure one glyph once (64 chars
    // amortise any kerning/padding error) and answer every per-byte
    // measurement below in O(1) instead of a CalcTextSize call per byte
    // (which made a drag frame O(line^2) through the ImGui text path).
    // ASCII log bytes map 1:1 to glyphs; the measurement includes the current
    // font size scaling, whatever the 1.93 baked-font internals are.
    const float glyph_w =
        ImGui::CalcTextSize("MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM"
                            "MMMMMMMMMMMMMMMMMMMMMMMMMMMMMMMM", nullptr).x / 64.0f;
    // Window-relative helpers: the selection lives in ABSOLUTE stream bytes
    // (see receive_base_); line offsets and hit tests below are window
    // offsets, so every absolute <-> window crossing goes through `base`.
    const std::size_t base = runtime.receive_base_;
    ImGuiListClipper clipper;
    clipper.Begin(static_cast<int>(offsets.size()));
    while (clipper.Step()) {
        for (int line_no = clipper.DisplayStart; line_no < clipper.DisplayEnd;
             ++line_no) {
            const std::size_t line_off = offsets[static_cast<std::size_t>(line_no)];
            const char* const line_begin =
                runtime.receive_text_.data() + line_off;
            const char* const line_end =
                line_no + 1 < static_cast<int>(offsets.size())
                    ? runtime.receive_text_.data() + offsets[static_cast<std::size_t>(line_no) + 1U] - 1
                    : runtime.receive_text_.data() + runtime.receive_text_.size();
            const std::size_t line_len = static_cast<std::size_t>(line_end - line_begin);
            // One ASCII scan per row serves the selection, hit-test and
            // highlight paths: pure-ASCII rows keep every O(1) glyph_w
            // shortcut, rows with non-ASCII bytes fall back to measured
            // advances (GB2312->UTF-8 log text is 3 bytes per CJK glyph,
            // so a byte*glyph_w column math would land inside sequences).
            const bool ascii_only =
                std::none_of(line_begin, line_end,
                             [](char c) { return (c & 0x80) != 0; });
            // Pixel x of a byte offset inside this row (row-relative).  The
            // measured branch matches the highlight path's precedent: only
            // selection/hit paths consult it, never the per-line render.
            const auto offset_px = [&](const std::size_t off) -> float {
                if (ascii_only) {
                    return static_cast<float>(off) * glyph_w;
                }
                return ImGui::CalcTextSize(line_begin, line_begin + off).x;
            };
            // Byte offset of the mouse position inside this line (mouse x
            // against the uniform glyph advance), or npos when the mouse is
            // not over this row.  Non-ASCII rows advance codepoint by
            // codepoint so the returned byte offset always sits on a UTF-8
            // sequence start — a drag can never split a character.
            const auto hit_offset_in_row = [&](const ImVec2& p,
                                               const ImVec2& rmin,
                                               const ImVec2& rmax)
                -> std::size_t {
                if (p.y < rmin.y || p.y >= rmax.y || p.x < rmin.x) {
                    return static_cast<std::size_t>(-1);
                }
                const float mouse_x = p.x - rmin.x;
                if (ascii_only) {
                    const std::size_t col = static_cast<std::size_t>(
                        mouse_x / glyph_w + 0.5f);
                    return line_off + (col < line_len ? col : line_len);
                }
                float pen = 0.0f;
                std::size_t off = 0U;
                while (off < line_len) {
                    const unsigned char lead =
                        static_cast<unsigned char>(line_begin[off]);
                    std::size_t seq = 1U;
                    if (lead >= 0xF0U) {
                        seq = 4U;
                    } else if (lead >= 0xE0U) {
                        seq = 3U;
                    } else if (lead >= 0xC0U) {
                        seq = 2U;
                    }
                    if (off + seq > line_len) {
                        seq = 1U;  // truncated sequence at the row tail
                    }
                    const float w = ImGui::CalcTextSize(
                        line_begin + off, line_begin + off + seq).x;
                    if (mouse_x < pen + w * 0.5f) {
                        return line_off + off;
                    }
                    pen += w;
                    off += seq;
                }
                return line_off + line_len;
            };
            // Selection background under the glyphs: shade the intersection
            // of [sel_begin, sel_end) with this line.  A drag that spans
            // rows shades whole intermediate lines (from byte 0 to line end).
            if (has_selection || sel_dragging) {
                // Absolute -> window; clamping to >= 0 drops the part of the
                // range that already left the window (it stays in absolute
                // state so copy still gets everything visible it covered).
                const std::size_t sel_b =
                    runtime.receive_sel_begin_ > base ? runtime.receive_sel_begin_ - base : 0U;
                const std::size_t sel_e =
                    runtime.receive_sel_end_ > base ? runtime.receive_sel_end_ - base : 0U;
                if (sel_e > sel_b && line_off < sel_e &&
                    line_off + line_len > sel_b) {
                    const std::size_t from = sel_b > line_off ? sel_b - line_off : 0U;
                    const std::size_t to = sel_e < line_off + line_len
                                               ? sel_e - line_off : line_len;
                    const float px = offset_px(from);
                    const float width =
                        ascii_only ? static_cast<float>(to - from) * glyph_w
                                   : offset_px(to) - offset_px(from);
                    const ImVec2 rmin = ImGui::GetCursorScreenPos();
                    draw->AddRectFilled(rmin,
                                        ImVec2(rmin.x + (to == line_len ? text_width : px + width),
                                               rmin.y + line_h),
                                        sel_color);
                }
            }
            // ---- keyword highlight (script rules) -------------------------
            // Runs ONLY for clipper-visible lines x rules, so the cost is
            // bounded by ~40 rows x <=32 rules of plain substring search —
            // inside the receive-chain sublinear budget (MEMORY.md).
            // First collect every match into `hits` (offset, length, rule),
            // then render once: bg-style rules draw rects under the line and
            // text-style rules split the line into colored runs.  A line with
            // at least one text hit skips the default TextUnformatted (the
            // segments already draw it).
            bool drawn_as_segments = false;
            if (!runtime.highlight_rules_.empty()) {
                struct HitSpan final {
                    std::size_t offset;
                    std::size_t length;
                    const ImGuiRuntime::HighlightRule* rule;
                };
                HitSpan hits[64];
                int hit_count = 0;
                for (const ImGuiRuntime::HighlightRule& rule :
                     runtime.highlight_rules_) {
                    if (rule.pattern.empty()) continue;
                    const char* scan = line_begin;
                    while (scan + rule.pattern.size() <= line_end &&
                           hit_count < 64) {
                        const char* hit = std::search(
                            scan, line_end, rule.pattern.begin(),
                            rule.pattern.end());
                        if (hit == line_end) break;
                        hits[hit_count++] = HitSpan{
                            static_cast<std::size_t>(hit - line_begin),
                            rule.pattern.size(), &rule};
                        scan = hit + rule.pattern.size();
                    }
                }
                const ImVec2 pos = ImGui::GetCursorScreenPos();
                for (int h = 0; h < hit_count; ++h) {
                    const HitSpan& span = hits[h];
                    if (span.rule->background) {
                        // Background rect under the match (drawn first so the
                        // glyphs of the line land on top of it).
                        float px, pw;
                        if (ascii_only) {
                            px = static_cast<float>(span.offset) * glyph_w;
                            pw = static_cast<float>(span.length) * glyph_w;
                        } else {
                            px = ImGui::CalcTextSize(
                                line_begin, line_begin + span.offset).x;
                            pw = ImGui::CalcTextSize(
                                line_begin + span.offset,
                                line_begin + span.offset + span.length).x;
                        }
                        draw->AddRectFilled(
                            ImVec2(pos.x + px, pos.y),
                            ImVec2(pos.x + px + pw, pos.y + line_h),
                            span.rule->color, 2.0f);
                    }
                }
                // Text-style runs: walk the line left-to-right, drawing each
                // gap with the default color and each covered span with its
                // rule color (first rule wins on overlap; overlaps are rare
                // and a stable order beats per-pixel blending here).
                int next_text = -1;
                for (int h = 0; h < hit_count; ++h) {
                    if (!hits[h].rule->background) { next_text = h; break; }
                }
                if (next_text >= 0) {
                    drawn_as_segments = true;
                    const ImU32 base_col =
                        ImGui::GetColorU32(ImGuiCol_Text);
                    std::size_t cursor = 0;
                    float pen_x = 0.0f;
                    while (cursor < line_len || next_text < hit_count) {
                        if (next_text >= hit_count ||
                            hits[next_text].offset >= line_len) {
                            // Trailing gap after the last span.
                            if (cursor < line_len) {
                                const char* seg = line_begin + cursor;
                                const char* seg_end =
                                    next_text >= hit_count ? line_end
                                    : line_begin + (hits[next_text].offset <
                                                     line_len
                                                         ? hits[next_text].offset
                                                         : line_len);
                                float w = ascii_only
                                    ? static_cast<float>(seg_end - seg) *
                                          glyph_w
                                    : ImGui::CalcTextSize(seg, seg_end).x;
                                draw->AddText(ImVec2(pos.x + pen_x, pos.y),
                                    base_col, seg, seg_end);
                                pen_x += w;
                                cursor = static_cast<std::size_t>(
                                    seg_end - line_begin);
                            }
                            break;
                        }
                        const HitSpan& span = hits[next_text];
                        if (span.offset > cursor) {
                            // Gap before this span.
                            const char* seg = line_begin + cursor;
                            const char* seg_end = line_begin + span.offset;
                            float w = ascii_only
                                ? static_cast<float>(seg_end - seg) * glyph_w
                                : ImGui::CalcTextSize(seg, seg_end).x;
                            draw->AddText(ImVec2(pos.x + pen_x, pos.y),
                                base_col, seg, seg_end);
                            pen_x += w;
                        }
                        const char* seg = line_begin + span.offset;
                        const char* seg_end = seg + span.length;
                        float w = ascii_only
                            ? static_cast<float>(span.length) * glyph_w
                            : ImGui::CalcTextSize(seg, seg_end).x;
                        draw->AddText(ImVec2(pos.x + pen_x, pos.y),
                            span.rule->color, seg, seg_end);
                        pen_x += w;
                        cursor = span.offset + span.length;
                        ++next_text;
                    }
                }
            }
            if (!drawn_as_segments) {
                ImGui::TextUnformatted(line_begin, line_end);
            } else {
                // The segment path drew glyphs directly through the draw
                // list, so no item was submitted; add an invisible item of
                // the same line metrics so the drag-selection hit-testing
                // below (GetItemRectMin/Max) still sees this row.
                ImGui::Dummy(ImVec2(
                    static_cast<float>(line_len) * glyph_w, line_h));
            }
            // Timestamp tint: the core injects a fixed 15-byte
            // "[HH:MM:SS.mmm] " prefix at each line start when the Time
            // toggle is on.  Re-draw those glyphs in the reference orange
            // over the body-colour pass above (same draw list, same mono
            // font — a straight overdraw, no extra layout item).  The
            // sentinel bytes ('[' / ':' / ' ') pin the format cheaply.
            if (ts_enabled && line_len >= kTsPrefixBytes &&
                line_begin[0] == '[' && line_begin[3] == ':' &&
                line_begin[6] == ':' && line_begin[9] == '.' &&
                line_begin[13] == ']' && line_begin[14] == ' ') {
                const ImVec2 ts_pos = ImGui::GetItemRectMin();
                draw->AddText(nullptr, 0.0f, ts_pos, ts_color, line_begin,
                              line_begin + kTsPrefixBytes);
            }
            // Drag hit-testing against the row we just submitted.  Only the
            // row under the mouse passes the y range test, so the per-row
            // cost outside the hovered line is a single comparison.
            if (sel_dragging) {
                const ImVec2 rmin = ImGui::GetItemRectMin();
                const ImVec2 rmax = ImGui::GetItemRectMax();
                std::size_t at = hit_offset_in_row(io.MousePos, rmin, rmax);
                if (at == static_cast<std::size_t>(-1) &&
                    io.MousePos.y >= rmin.y && io.MousePos.y < rmax.y) {
                    // Over the row but left of the text start: clamp to byte 0.
                    at = io.MousePos.x < rmin.x ? line_off : line_off + line_len;
                }
                if (at != static_cast<std::size_t>(-1)) {
                    // Window offset -> absolute stream bytes for the state.
                    at += base;
                    if (!runtime.receive_sel_drag_hit_) {
                        runtime.receive_sel_drag_origin_ = at;
                        runtime.receive_sel_drag_hit_ = true;
                    }
                    const std::size_t origin = runtime.receive_sel_drag_origin_;
                    runtime.receive_sel_begin_ = at < origin ? at : origin;
                    runtime.receive_sel_end_ = at > origin ? at : origin;
                }
            }
        }
    }
    clipper.End();
    // Finish the drag: persist the selection (anchor back to "no drag").
    if (runtime.receive_sel_anchor_ == kSelDragging && !ImGui::IsMouseDown(ImGuiMouseButton_Left)) {
        runtime.receive_sel_anchor_ = kNoSelAnchor;
        if (!runtime.receive_sel_drag_hit_) {
            runtime.receive_sel_begin_ = runtime.receive_sel_end_ = 0;
        }
        // xcom_imgui_receive_append defers its prefix trim while a drag is in
        // progress so the selected bytes cannot slide out from under the
        // cursor.  Catch up here, on the first frame the button is observed
        // released: this is what re-establishes text.size() <= receive_limit_.
        // (The renderer clamps sel_begin/end to base, so a selection the trim
        // retires is shown clipped to byte 0, never underflowed.)
        if (runtime.receive_text_.size() > runtime.receive_limit_) {
            const std::size_t erase_n =
                runtime.receive_text_.size() - runtime.receive_limit_;
            runtime.receive_text_.erase(0, erase_n);
            runtime.receive_base_ += erase_n;
            std::vector<std::size_t>& offsets = runtime.receive_line_offsets_;
            offsets.erase(offsets.begin(),
                          std::lower_bound(offsets.begin(), offsets.end(), erase_n));
            for (std::size_t& off : offsets) off -= erase_n;
            if (offsets.empty() || offsets.front() != 0U) {
                offsets.insert(offsets.begin(), 0U);
            }
        }
    }
    ImGui::PopStyleVar();
    // pop_mono is a ScopedAction: its destructor pops the font at scope exit.
    // Follow-tail pin, official pattern: only when the view was at the bottom
    // at the START of the frame, called after all rows are submitted so the
    // scroll range reflects the new content.  An IN-PROGRESS drag freezes the
    // pin: chasing the tail while the mouse is held would slide the text out
    // from under the drag and cap the selection at the first visible row.
    // A persisted selection (button released) deliberately does NOT freeze —
    // the highlight travels upward with its lines until it leaves the window.
    if (runtime.receive_follow_tail_ && !sel_dragging) {
        ImGui::SetScrollHereY(1.0f);
    }
    runtime.receive_scroll_y_ = ImGui::GetScrollY();
    // Right-click context menu: the read-only multiline editor doesn't expose
    // one by default, so attach one explicitly.  The popup id is scoped to
    // the receive panel so other panels' right-clicks are unaffected.
    if (ImGui::IsWindowHovered() && ImGui::IsMouseClicked(ImGuiMouseButton_Right)) {
        ImGui::OpenPopup("##receive_context");
    }
    if (ImGui::BeginPopup("##receive_context")) {
        const bool has_sel = runtime.receive_sel_end_ > runtime.receive_sel_begin_;
        const bool has_text = !runtime.receive_text_.empty();
        const Lang& lang = runtime.lang();
        // Copy submenu.  The items do NOT touch the clipboard here: they queue
        // the requested bytes (QueueReceiveCopy) and the Lua bridge writes the
        // clipboard after applying the optional timestamp strip.  That keeps
        // the strip policy in ONE place (core/receive_copy.lua, unit-tested
        // headless) instead of duplicating the pattern in C++.  Ctrl+C mirrors
        // "Copy selection".
        if (ImGui::BeginMenu(lang.menu_copy, has_sel || has_text)) {
            if (ImGui::MenuItem(lang.menu_copy_sel, nullptr, false, has_sel)) {
                QueueReceiveCopy(runtime, runtime.receive_sel_begin_,
                                 runtime.receive_sel_end_);
            }
            // "All" reaches only the RETAINED tail (receive_limit_, default
            // 64 KiB - 1): earlier bytes have been retired from the view.
            if (ImGui::MenuItem(lang.menu_copy_all, nullptr, false, has_text)) {
                QueueReceiveCopy(runtime, runtime.receive_base_,
                                 runtime.receive_base_ +
                                     runtime.receive_text_.size());
            }
            ImGui::Separator();
            // Copy policy: when on, the injected "[HH:MM:SS.mmm] " prefixes
            // are stripped before the clipboard write.  The toggle is a
            // Lua-owned int (registered via xcom_imgui_set_copy_strip) so the
            // Lua side both persists and applies it; the item hides when the
            // bridge did not register the pointer (older Lua/DLL pairing).
            if (runtime.copy_strip_ts_ != nullptr) {
                bool strip = *runtime.copy_strip_ts_ != 0;
                if (ImGui::MenuItem(lang.menu_copy_strip_ts, nullptr, strip)) {
                    *runtime.copy_strip_ts_ = strip ? 0 : 1;
                }
            }
            ImGui::EndMenu();
        }
        // Select every retained byte: base..base+size is exactly the window, so
        // the copy-selection clamp above maps it 1:1 (no off-by-base error).
        if (ImGui::MenuItem(lang.menu_select_all, nullptr, false, has_text)) {
            runtime.receive_sel_begin_ = runtime.receive_base_;
            runtime.receive_sel_end_ =
                runtime.receive_base_ + runtime.receive_text_.size();
        }
        ImGui::Separator();
        // View toggles mirror the sidebar checkboxes exactly: same Lua-owned
        // int, same ActionSyncDisplay.  ReceiveContent draws BEFORE the sidebar
        // in xcom_imgui_draw_console, so a flip here is already visible to the
        // checkbox within this same frame (and a popup blocks the sidebar's
        // click, so the two can never both toggle in one frame).
        const bool hex_on = receive_hex != nullptr && *receive_hex != 0;
        if (ImGui::MenuItem(lang.hex_display, nullptr, hex_on, receive_hex != nullptr)) {
            *receive_hex = hex_on ? 0 : 1;
            actions |= Action::ActionSyncDisplay;
        }
        const bool ts_on = timestamp != nullptr && *timestamp != 0;
        if (ImGui::MenuItem(lang.timestamp, nullptr, ts_on, timestamp != nullptr)) {
            *timestamp = ts_on ? 0 : 1;
            actions |= Action::ActionSyncDisplay;
        }
        const bool paused = pause_display != nullptr && *pause_display != 0;
        if (ImGui::MenuItem(paused ? lang.menu_resume : lang.pause, nullptr, paused,
                            pause_display != nullptr)) {
            *pause_display = paused ? 0 : 1;
            actions |= Action::ActionSyncDisplay;
        }
        ImGui::Separator();
        if (ImGui::MenuItem(lang.menu_save_log)) {
            actions |= Action::ActionSaveLog;
        }
        if (ImGui::MenuItem(lang.menu_clear_log, nullptr, false, has_text)) {
            actions |= Action::ActionClear;
        }
        ImGui::EndPopup();
    }
    return actions;
}

[[nodiscard]] int TransmitContent(int* send_hex, int* send_crlf, int* send_auto, int* send_period,
                    char* send_text, size_t send_capacity, char* multi_text,
                    size_t multi_slot_capacity, int* multi_enabled, int* multi_hex,
                    int* multi_crlf, int* multi_page, int* multi_page_count,
                    int* multi_auto, int* multi_period, const bool send_ok) {
    // send_ok follows the Lua send_enabled bit (OPEN and not RECONNECTING,
    // passed as the console's `connected` argument).  Rather than let the
    // buttons stay clickable in CLOSED/OPENING/CLOSING/FAULT/RECONNECTING and
    // reject at runtime -- which reads as a dead button -- disable exactly the
    // controls that would send: Send, Send-enabled, the per-row slot buttons
    // and Run.  Editors and toggles stay live so the user can still compose.
    int actions = 0;
    const Lang& lang = ImGuiRuntime::instance().lang();
    if (ImGui::BeginTabBar("##transmit_tabs")) {
        if (ImGui::BeginTabItem(lang.tab_single)) {
            ImGui::SetCursorPosX(0.0f);
            // Option toolbar ABOVE the editor (reference layout): toggles and
            // the auto-cycle period read as one control strip, then the editor
            // fills everything left above the panel bottom.
            const std::array<ToggleSpec, 3> options{{
                {lang.send_hex, send_hex, Action::ActionSyncSettings},
                {lang.send_newline, send_crlf, Action::ActionSyncSettings},
                {lang.send_auto, send_auto, Action::ActionSyncSettings},
            }};
            RenderToggles(actions, options);
            ImGui::SameLine();
            ImGui::SetNextItemWidth(80.0f);
            if (ImGui::InputInt("##send_period", send_period, 0, 0)) actions |= Action::ActionSyncSettings;
            ImGui::SameLine();
            ImGui::TextDisabled("%s", lang.ms);
            // Toolbar row height (toggle ~20 + spacing) reserves the band the
            // editor must not cover.
            const float toolbar_h = ImGui::GetCursorPosY();
            const float editor_height = (std::max)(76.0f,
                ImGui::GetContentRegionAvail().y);
            ImGui::SetCursorPosY(toolbar_h);
            ImGui::SetNextItemWidth(-110.0f);
            // 1.png measures the TX editor near-white (#FEFEFE 97%), not the
            // pale-green wash — the green lives in RX log rows, fixed below.
            ImGui::PushStyleColor(ImGuiCol_FrameBg, rgb(palette::kSurfaceZone));
            ImGui::PushStyleColor(ImGuiCol_FrameBgHovered, rgb(palette::kSurfaceZone));
            ImGui::PushStyleColor(ImGuiCol_FrameBgActive, rgb(palette::kSurfaceZone));
            if (ImGui::InputTextMultiline("##send", send_text, send_capacity,
                                          ImVec2(-110.0f, editor_height),
                                          ImGuiInputTextFlags_EnterReturnsTrue)) actions |= Action::ActionSend;
            ImGui::PopStyleColor(3);
            TextContextMenu("##send_context", send_text, send_capacity);
            ImGui::SameLine();
            // Large primary Send vertically centred against the editor.
            ImGui::SetCursorPosY(ImGui::GetCursorPosY() + (editor_height - 48.0f) * 0.5f);
            ImGui::BeginDisabled(!send_ok);
            actions |= Command<Action::ActionSend>::Execute(
                [&lang] { return SendAction(lang.send, ImVec2(96, 48)); });
            ImGui::EndDisabled();
            ImGui::EndTabItem();
        }
        if (ImGui::BeginTabItem(lang.tab_multi)) {
            // Option strip ABOVE the grid (reference layout), mirroring the
            // Single tab's toolbar so both tabs read the same way.
            const std::array<ToggleSpec, 2> options{{
                {lang.send_hex, multi_hex, Action::ActionSyncSettings},
                {lang.send_newline, multi_crlf, Action::ActionSyncSettings},
            }};
            RenderToggles(actions, options);
            // Two-column grid keeps all eight slots visible in the compact
            // 920x650 layout while retaining the enable/index/content anchors.
            ImGui::PushStyleVar(ImGuiStyleVar_CellPadding, ImVec2(0.0f, 0.0f));
            if (ImGui::BeginTable("##multi_grid", 2, ImGuiTableFlags_SizingStretchProp)) {
                ImGui::TableSetupColumn("left", ImGuiTableColumnFlags_WidthStretch, 1.0f);
                ImGui::TableSetupColumn("right", ImGuiTableColumnFlags_WidthStretch, 1.0f);
                for (int row = 0; row < 4; ++row) {
                    ImGui::TableNextRow();
                    for (int column = 0; column < 2; ++column) {
                        const int index = row + column * 4;
                        char label[16];
                        char enabled_label[20];
                        sprintf_s(label, "##multi%d", index);
                        sprintf_s(enabled_label, "##enabled%d", index);
                        ImGui::TableNextColumn();
                        ImGui::PushID(index);
                        if (Toggle(enabled_label, &multi_enabled[index])) actions |= Action::ActionSyncSettings;
                        ImGui::SameLine(0.0f, 4.0f);
                        ImGui::AlignTextToFramePadding();
                        ImGui::TextDisabled("%d", index + 1);
                        ImGui::SameLine(0.0f, 6.0f);
                        // Reserve room for the enable marker, index and the
                        // numeric Send N button.  The button width is calibrated
                        // for a single glyph so the InputText gets the rest.
                        ImGui::SetNextItemWidth(-44.0f);
                        if (ImGui::InputText(label, multi_text + index * multi_slot_capacity, multi_slot_capacity)) actions |= Action::ActionSyncSettings;
                        TextContextMenu("##multi_context", multi_text + index * multi_slot_capacity, multi_slot_capacity);
                        ImGui::SameLine(0.0f, 4.0f);
                        char send_label[12];
                        // Short numeric labels keep the row tight; tooltip
                        // preserves the slot identity.  Plain "N" avoids the
                        // "Send >" misread caused by ">" being clipped.
                        sprintf_s(send_label, "%d", index + 1);
                        ImGui::BeginDisabled(!send_ok);
                        if (ImGui::Button(send_label, ImVec2(32.0f, kControlHeight))) {
                            actions |= send_slot_action(static_cast<std::uint32_t>(index));
                        }
                        ImGui::EndDisabled();
                        if (ImGui::IsItemHovered()) {
                            ImGui::SetTooltip(lang.send_slot_tip_prefix, index + 1);
                        }
                        ImGui::PopID();
                    }
                }
                ImGui::EndTable();
            }
            ImGui::PopStyleVar();
            // Hairline rule between the grid and the paging/auto-cycle row
            // (reference style: 1px near-invisible separators, ImGuiCol_
            // Separator is themed to the reference #EDEDED).
            ImGui::Separator();
            ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(3.0f, 2.0f));
            actions |= Command<Action::ActionPreviousPage>::Execute(
                [] { return ImGui::Button("<", ImVec2(28.0f, kControlHeight)); });
            ImGui::SameLine();
            ImGui::AlignTextToFramePadding();
            ImGui::Text("%d/%d", *multi_page + 1, *multi_page_count);
            ImGui::SameLine();
            actions |= Command<Action::ActionNextPage>::Execute(
                [] { return ImGui::Button(">", ImVec2(28.0f, kControlHeight)); });
            ImGui::SameLine();
            actions |= Command<Action::ActionAddPage>::Execute(
                [] { return ImGui::Button("+", ImVec2(28.0f, kControlHeight)); });
            ImGui::SameLine();
            actions |= Command<Action::ActionRemovePage>::Execute(
                [] { return ImGui::Button("-", ImVec2(28.0f, kControlHeight)); });
            ImGui::SameLine(0.0f, 6.0f);
            const std::array<ToggleSpec, 1> cycle{{{lang.loop, multi_auto, Action::ActionSyncMultiAuto}}};
            RenderToggles(actions, cycle);
            ImGui::SameLine();
            ImGui::SetNextItemWidth(80.0f);
            if (ImGui::InputInt("##multi_period", multi_period, 0, 0)) actions |= Action::ActionSyncMultiAuto;
            ImGui::SameLine();
            ImGui::TextDisabled("%s", lang.ms);
            // Sequential command list (Phase 4): gap-ms between entries + a
            // Run button that doubles as Stop while a sequence is in flight
            // (the Lua side owns the sequence timer state; it flips on the
            // same action bit).
            auto& runtime = ImGuiRuntime::instance();
            if (runtime.multi_gap_ != nullptr) {
                ImGui::SameLine(0.0f, 8.0f);
                ImGui::SetNextItemWidth(56.0f);
                if (ImGui::InputInt("##multi_gap", runtime.multi_gap_, 0, 0)) {
                    // Purely local state (Lua reads the int when it starts a
                    // sequence); no action bit needed.
                }
                ImGui::SameLine(0.0f, 2.0f);
                ImGui::TextDisabled("%s", lang.gap);
            }
            ImGui::SameLine();
            ImGui::SetCursorPosX(ImGui::GetWindowWidth() - 76.0f);
            if (runtime.multi_gap_ != nullptr) {
                ImGui::SetCursorPosX(ImGui::GetWindowWidth() - 138.0f);
                ImGui::BeginDisabled(!send_ok);
                actions |= Command<Action::ActionRunSequence>::Execute(
                    [&lang] { return PrimaryAction(lang.run, ImVec2(56.0f, kControlHeight)); });
                ImGui::EndDisabled();
                ImGui::SameLine(0.0f, 4.0f);
            }
            ImGui::SetCursorPosX(ImGui::GetWindowWidth() - 76.0f);
            ImGui::BeginDisabled(!send_ok);
            actions |= Command<Action::ActionSendEnabled>::Execute(
                [&lang] { return SendAction(lang.send, ImVec2(72.0f, kControlHeight)); });
            ImGui::EndDisabled();
            ImGui::PopStyleVar();
            ImGui::EndTabItem();
        }
        ImGui::EndTabBar();
    }
    return actions;
}

[[nodiscard]] int ConnectionContent(char* port, size_t port_capacity, bool connected,
                      int* baud, int* data_bits, int* stop_bits, int* parity,
                      int* flow, int* dtr, int* rts,
                      const std::array<ComboSpec, 5>& serial_fields,
                      int rx_bytes, int tx_bytes, int* receive_hex, int* timestamp,
                      int* pause_display, int* auto_clear, int* auto_clear_bytes,
                      int* auto_save) {
    (void)rx_bytes;
    (void)tx_bytes;
    (void)receive_hex;
    (void)timestamp;
    (void)pause_display;
    (void)auto_clear;
    (void)auto_clear_bytes;
    (void)auto_save;
    ImGui::SetCursorPosX(kSidebarInset);
    int actions = 0;
    const Lang& lang = ImGuiRuntime::instance().lang();
    Section(lang.section_port);
    // Single "port combo" row: drop the separate editable PORT text field and
    // an obvious AVAILABLE label.  The combo both shows the persisted/current
    // port and picks one from the enumerated list; Refresh sits beside it.
    ImGui::SetCursorPosX(kSidebarInset);
    ImGui::SetNextItemWidth(-34.0f);
    // Disabled while a session is live, for the same invariant as the line
    // format combos below: the panel must never name a port other than the one
    // the open handle belongs to.  This is not cosmetic -- the pick writes
    // _imgui_port (window.lua:2196), which feeds _serial_config().port
    // (window.lua:1319), which _drive_reconnect reads as its recovery target
    // (window.lua:3422).  A pick made while connected would therefore silently
    // redirect reconnection to a DIFFERENT device -- the exact "silently
    // switched to another port" failure recorded as a defect in other tools.
    // Closing first remains the way to reach another port.
    ImGui::BeginDisabled(connected);
    if (ImGui::BeginCombo("##port_combo", port[0] ? port : lang.select_port)) {
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
    ImGui::EndDisabled();
    ImGui::SameLine(0.0f, 6.0f);
    actions |= Command<Action::ActionRefreshPorts>::Execute(
        [&lang] { return IconButton("##refresh_ports", UtilityIcon::Refresh, lang.refresh_tip); });
    ImGui::SetCursorPosX(kSidebarInset);
    if (!connected) actions |= Command<Action::ActionOpen>::Execute(
        [&lang] { return PrimaryAction(lang.open, ImVec2(-1, 0)); });
    ImGui::SetCursorPosX(kSidebarInset);
    if (connected) actions |= Command<Action::ActionClose>::Execute(
        [&lang] { return DangerAction(lang.close, ImVec2(-1, 0)); });
    // DTR/RTS moved up next to the open/close pair (user: the "更多" band is
    // hidden for now — see kMoreSectionEnabled — and these two modem lines are
    // primary enough to live right under the port action).
    // RTS is driver-owned under RTS/CTS hardware flow control (flow index 1;
    // xcom.h XcomPortConfig.flow_control, order mirrored by Lang::flow_items):
    // the driver decides the pin, so the switch is disabled rather than showing a
    // level the panel cannot command (same invariant as the connected-gated
    // combos above, and as RealTerm's documented handshake-pin rule).  DTR is NOT
    // governed by RTS/CTS (nor by XON/XOFF) and xcom_set_lines still applies the
    // DTR half under hw flow, so it stays enabled.  The flow combo itself is
    // disabled while connected, so this reads the same effective setting the DCB
    // was opened with.
    const bool rts_driver_owned = *flow == 1;
    ImGui::SetCursorPosX(kSidebarInset);
    const std::array<ToggleSpec, 2> modem_options{{
        {"DTR", dtr, Action::ActionSyncSettings},
        {"RTS", rts, Action::ActionSyncSettings, !rts_driver_owned},
    }};
    RenderToggles(actions, modem_options);
    ImGui::Dummy(ImVec2(0.0f, 5.0f));
    ImGui::Separator();
    ImGui::Spacing();
    ImGui::SetCursorPosX(kSidebarInset);
    Section(lang.section_serial);
    ImGui::SetCursorPosX(kSidebarInset);
    // The line format is programmed into the DCB exactly once, in
    // open()->configure() (serial_backend_win.cpp, the only SetCommState), and
    // there is no runtime reconfiguration path.  Editing these five combos
    // while connected would therefore change only the DISPLAYED value while
    // the port keeps the old one -- the panel would contradict the live DCB.
    // Gate them on `connected`, the same way the Open/Close buttons are gated.
    // DTR/RTS below stay enabled: set_dtr/set_rts really drive the pins live.
    ImGui::BeginDisabled(connected);
    if (ImGui::BeginTable("##serial_grid", 2, ImGuiTableFlags_SizingStretchProp)) {
        // Label column tracks the active language: 48 px fits the 4-char
        // English labels (BAUD/FLOW), 56 px fits the 3-hanzi Chinese labels
        // (波特率/校验位) without truncation.
        ImGui::TableSetupColumn("label", ImGuiTableColumnFlags_WidthFixed, lang.serial_label_col);
        ImGui::TableSetupColumn("value", ImGuiTableColumnFlags_WidthStretch, 1.0f);
        for (const ComboSpec& field : serial_fields) {
            ImGui::TableNextRow();
            if (GridComboField(field)) actions |= Action::ActionSyncSettings;
        }
        // 1.5 stop bits exists only for a 5-data-bit word: the core's
        // valid_line_format() (serial_backend_win.cpp) rejects every other
        // pairing, so an "8 data bits + 1.5 stop" pick would make Open fail on
        // a format the panel let the user choose.  Carry a data-bit change into
        // the Stop combo (index 1 == 1.5 -> 0 == 1) so the shipped UI cannot
        // hold the invalid pair.  data_bits is the 0-based combo index (0 ==
        // 5 bits), so 1.5 is legal only while *data_bits == 0.
        if (*stop_bits == 1 && *data_bits != 0) {
            *stop_bits = 0;
            actions |= Action::ActionSyncSettings;
        }
        ImGui::EndTable();
    }
    // Open-time modem-line tri-state (XCOM_LINE_*).  A SEPARATE group from the
    // live DTR/RTS toggles above: these are programmed once, at open.  "Leave
    // alone" is the only setting under which the open path issues no
    // EscapeCommFunction for that line, so a target with DTR->NRST / RTS->BOOT
    // is not reset just by opening the port.  Hidden on a DLL whose Lua peer
    // did not register the two int buffers (xcom_imgui_set_open_lines).
    {
        const auto& runtime = ImGuiRuntime::instance();
        if (runtime.dtr_open_ != nullptr || runtime.rts_open_ != nullptr) {
            ImGui::Spacing();
            ImGui::SetCursorPosX(kSidebarInset);
            Section(lang.open_line_label);
            if (ImGui::BeginTable("##open_line_grid", 2,
                                  ImGuiTableFlags_SizingStretchProp)) {
                ImGui::TableSetupColumn("label", ImGuiTableColumnFlags_WidthFixed,
                                        lang.serial_label_col);
                ImGui::TableSetupColumn("value", ImGuiTableColumnFlags_WidthStretch, 1.0f);
                const int item_count =
                    static_cast<int>(std::size(lang.open_line_items));
                if (runtime.dtr_open_ != nullptr) {
                    ImGui::TableNextRow();
                    if (GridComboField({"##dtr_open", "DTR", runtime.dtr_open_,
                                        lang.open_line_items, item_count})) {
                        actions |= Action::ActionSyncSettings;
                    }
                }
                if (runtime.rts_open_ != nullptr) {
                    ImGui::TableNextRow();
                    // Under RTS/CTS the driver owns RTS, so an open-time RTS
                    // choice cannot be honoured; disable rather than show a
                    // level the port will not program.
                    ImGui::BeginDisabled(*flow == 1);
                    if (GridComboField({"##rts_open", "RTS", runtime.rts_open_,
                                        lang.open_line_items, item_count})) {
                        actions |= Action::ActionSyncSettings;
                    }
                    ImGui::EndDisabled();
                }
                ImGui::EndTable();
            }
        }
    }
    ImGui::EndDisabled();
    // "更多" advanced band — kept per user request (may be re-enabled later),
    // but currently gated OFF by kMoreSectionEnabled so the sidebar shows only
    // primary controls.  DTR/RTS moved above the open/close row; the custom
    // baud override still lives here.  Flip the flag to true to restore.
    constexpr bool kMoreSectionEnabled = false;
    if constexpr (kMoreSectionEnabled) {
        ImGui::SetCursorPosX(kSidebarInset);
        if (ImGui::CollapsingHeader(lang.more, ImGuiTreeNodeFlags_DefaultOpen)) {
            // Custom baud override (Phase 4): a non-zero value wins over the preset
            // combo on the Lua side (serial_config clamps 300..3M); 0 = use preset.
            if (ImGuiRuntime::instance().baud_custom_ != nullptr) {
                ImGui::SetCursorPosX(kSidebarInset);
                ImGui::TextUnformatted(lang.custom);
                ImGui::SameLine(0.0f, 6.0f);
                ImGui::PushStyleVar(ImGuiStyleVar_FramePadding, ImVec2(4.0f, 3.0f));
                ImGui::SetNextItemWidth(-1.0f);
                if (ImGui::InputInt("##baud_custom", ImGuiRuntime::instance().baud_custom_,
                                    0, 0)) {
                    actions |= Action::ActionSyncSettings;
                }
                ImGui::PopStyleVar();
            }
            ImGui::SetCursorPosX(kSidebarInset);
            const std::array<ToggleSpec, 2> more_modem{{
                {"DTR", dtr, Action::ActionSyncSettings},
                {"RTS", rts, Action::ActionSyncSettings, !rts_driver_owned},
            }};
            RenderToggles(actions, more_modem);
        }
    }
    ImGui::Separator();
    ImGui::Spacing();
    ImGui::SetCursorPosX(kSidebarInset);
    Section(lang.section_recv);
    ReceiveToolbar(actions, rx_bytes, tx_bytes, receive_hex, timestamp,
                   pause_display, auto_clear, auto_clear_bytes, auto_save);
    return actions;
}

[[nodiscard]] bool Toggle(const char* label, int* value) {
    const ImVec2 size(28.0f, kToggleHeight);
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
        ImGui::AlignTextToFramePadding();
        ImGui::TextUnformatted(label);
    }
    return changed;
}

// 1.png Open/major (text) controls are restrained: light #FEFEFE/#F8F8F8 fill,
// no solid-color slab — only a thin #D5D5D5 border (via FrameBorderSize) + dark
// #1B1B1B text. Send/SendAction stays solid blue; these are the outline buttons.
[[nodiscard]] bool PrimaryAction(const char* label, const ImVec2& size = ImVec2(0, 0)) {
    ImGui::PushStyleColor(ImGuiCol_Button, rgb(0xFEFEFE));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, rgb(0xE9ECED));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, rgb(0xDFE3E5));
    ImGui::PushStyleColor(ImGuiCol_Text, rgb(palette::kTextBody));
    const ImVec2 resolved_size(size.x, size.y > 0.0f ? size.y : kControlHeight);
    const bool clicked = WithRounding(3.0f, [](const char* text, const ImVec2& button_size) {
        return ImGui::Button(text, button_size);
    })(label, resolved_size);
    ImGui::PopStyleColor(4);
    return clicked;
}

// Close = restrained outline w/ red label (1.png shows no solid danger slab; the
// signal is red text on a light face, thin #D5 border inherited from ImGuiCol_Border).
[[nodiscard]] bool DangerAction(const char* label, const ImVec2& size = ImVec2(0, 0)) {
    ImGui::PushStyleColor(ImGuiCol_Button, rgb(0xFEFEFE));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, rgb(0xFBEAE8));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, rgb(0xF4D8D5));
    ImGui::PushStyleColor(ImGuiCol_Text, rgb(palette::kDangerRed));
    const ImVec2 resolved_size(size.x, size.y > 0.0f ? size.y : kControlHeight);
    const bool clicked = WithRounding(3.0f, [](const char* text, const ImVec2& button_size) {
        return ImGui::Button(text, button_size);
    })(label, resolved_size);
    ImGui::PopStyleColor(4);
    return clicked;
}

// Signature SEND control: reference primary-blue (#005A9E, ~8px rounding,
// white label).  Used for both the Single-tab Send and the Multi-tab
// Send-enabled action.
[[nodiscard]] bool SendAction(const char* label, const ImVec2& size) {
    ImGui::PushStyleColor(ImGuiCol_Button, rgb(palette::kSendBlue));
    ImGui::PushStyleColor(ImGuiCol_ButtonHovered, rgb(palette::kSendBlueHover));
    ImGui::PushStyleColor(ImGuiCol_ButtonActive, rgb(palette::kSendBluePress));
    ImGui::PushStyleColor(ImGuiCol_Text, rgb(palette::kTextInverse));
    const bool clicked = WithRounding(8.0f, [](const char* text, const ImVec2& button_size) {
        return ImGui::Button(text, button_size);
    })(label, size);
    ImGui::PopStyleColor(4);
    return clicked;
}

void EmptyState(std::string_view title, std::string_view detail) {
    const ImVec2 available = ImGui::GetContentRegionAvail();
    const float title_width = ImGui::CalcTextSize(title.data(), title.data() + title.size()).x;
    const float start_y = ImGui::GetCursorPosY() + (available.y - 42.0f) * 0.5f;
    ImGui::SetCursorPos(ImVec2(12.0f, start_y));
    ImGui::TextDisabled("> %.*s", static_cast<int>(title.size()), title.data());
    if (!detail.empty()) {
        ImGui::SetCursorPosX(24.0f);
        ImGui::TextDisabled("%.*s", static_cast<int>(detail.size()), detail.data());
    }
}

void Footer(const bool connected, const int rx_bytes, const int tx_bytes) {
    auto& runtime = ImGuiRuntime::instance();
    const auto footer = Panel("##status_footer", ImVec2(0, kFooterHeight), false,
                              ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse,
                              rgb(palette::kSurfaceZone));
    if (!footer) return;
    ImDrawList* const draw_list = ImGui::GetWindowDrawList();
    const ImVec2 origin = ImGui::GetWindowPos();
    const float footer_width = ImGui::GetWindowWidth();
    const float content_boundary = (std::max)(180.0f,
        footer_width - runtime.layout_.sidebar_width);
    const float baseline = origin.y + (kFooterHeight - ImGui::GetFontSize()) * 0.5f;
    const ImU32 border = ImGui::GetColorU32(rgb(0x8C8C8C, 1.0f));   // 1.png footer top rule, measured
    const ImU32 divider = ImGui::GetColorU32(rgb(0xD8D8DA, 0.9f));
    draw_list->AddRectFilled(ImVec2(origin.x, origin.y),
                             ImVec2(origin.x + footer_width, origin.y + kFooterHeight),
                             ImGui::GetColorU32(rgb(palette::kSurfaceZone)));
    // Crisp 1px top rule: AddLine at a .5 offset anti-aliases #8C8C8C over the
    // #FEFEFE band into ~#C5C5C5 (fails the ±20 verify contract); a filled
    // integer-height row paints the measured #8C8C8C in a single scanline.
    draw_list->AddRectFilled(ImVec2(origin.x, origin.y),
                             ImVec2(origin.x + footer_width, origin.y + 1.0f), border);
    const std::string_view state_label = connected ? runtime.lang().online : runtime.lang().offline;
    const ImU32 state_color = ImGui::GetColorU32(
        connected ? rgb(palette::kAccentTeal) : rgb(palette::kTextMuted));
    const float state_width = ImGui::CalcTextSize(state_label.data(),
                                                   state_label.data() + state_label.size()).x;
    const ImVec2 state_min(origin.x + 10.0f, origin.y + 3.0f);
    const ImVec2 state_max(state_min.x + state_width + 24.0f, origin.y + kFooterHeight - 3.0f);
    draw_list->AddRectFilled(state_min, state_max,
                             ImGui::GetColorU32(connected ? rgb(0xC6ECE8) : rgb(0xE9E0CF)), 3.0f);
    draw_list->AddCircleFilled(ImVec2(state_min.x + 8.0f, baseline + ImGui::GetFontSize() * 0.5f),
                               3.0f, state_color);
    draw_list->AddText(ImVec2(state_min.x + 16.0f, baseline), state_color,
                       state_label.data(), state_label.data() + state_label.size());
    char counters[48]{};
    if (connected) sprintf_s(counters, "RX %d   TX %d", rx_bytes, tx_bytes);
    else strcpy_s(counters, "RX --   TX --");
    // Re-measure the counter text only when its bytes changed (data frames
    // at ~10 fps re-format every frame but the string is often identical
    // between them, e.g. while paused or idle).  Keyed on the font like the
    // header caches above.
    static float cached_counters_width = -1.0f;
    static char cached_counters[48]{};
    static const ImFont* counters_font = nullptr;
    const ImFont* const current_font = ImGui::GetFont();
    if (counters_font != current_font) {
        counters_font = current_font;
        cached_counters_width = -1.0f;
        cached_counters[0] = '\0';
    }
    if (cached_counters_width < 0.0f || strcmp(cached_counters, counters) != 0) {
        cached_counters_width = ImGui::CalcTextSize(counters).x;
        strcpy_s(cached_counters, counters);
    }
    const float counters_width = cached_counters_width;
    const float counter_x = (std::max)(content_boundary - counters_width - 18.0f,
                                       (state_max.x - origin.x) + 24.0f);
    draw_list->AddText(ImVec2(origin.x + counter_x, baseline),
                       ImGui::GetColorU32(rgb(palette::kTextMuted)), counters);
    // The two hint literals are fixed; cache each width, font-keyed.
    const std::string_view hint = connected ? std::string_view{runtime.lang().ready}
                                            : std::string_view{runtime.lang().open_a_port};
    static float hint_width_cache[2] = {-1.0f, -1.0f};
    static const ImFont* hint_width_font = nullptr;
    if (hint_width_font != current_font) {
        hint_width_font = current_font;
        hint_width_cache[0] = -1.0f;
        hint_width_cache[1] = -1.0f;
    }
    const int hint_idx = connected ? 1 : 0;
    if (hint_width_cache[hint_idx] < 0.0f) {
        hint_width_cache[hint_idx] = ImGui::CalcTextSize(
            hint.data(), hint.data() + hint.size()).x;
    }
    const float hint_width = hint_width_cache[hint_idx];
    // Live status line from Lua (xcom_imgui_set_status): open failures, port
    // causes, DTR/RTS rejections, data-loss banners, reconnect countdown. The
    // buffer was previously write-only — Lua set it on 30+ paths (window.lua)
    // and nothing ever drew it, so every one of those messages was invisible
    // in the ImGui front-end and the UI looked unresponsive to failures.
    // Render it in the free space between the RX/TX counters and the right-hand
    // hint, clipping to whatever room is left so a long message can never
    // collide with either neighbour.
    if (!runtime.status_text_.empty()) {
        const float text_left = origin.x + counter_x + counters_width + 12.0f;
        const float text_right = origin.x + (std::max)(
            footer_width - hint_width - 14.0f, content_boundary + 8.0f) - 8.0f;
        if (text_right > text_left) {
            const ImVec4 clip(text_left, origin.y, text_right,
                              origin.y + kFooterHeight);
            draw_list->PushClipRect(ImVec2(clip.x, clip.y),
                                    ImVec2(clip.z, clip.w), true);
            draw_list->AddText(ImVec2(text_left, baseline),
                               ImGui::GetColorU32(rgb(0xB4551F)),  // amber: advisory
                               runtime.status_text_.c_str());
            draw_list->PopClipRect();
        }
    }
    draw_list->AddText(ImVec2(origin.x + (std::max)(footer_width - hint_width - 14.0f,
                                                     content_boundary + 8.0f), baseline),
                       ImGui::GetColorU32(rgb(palette::kTextMuted)), hint.data(),
                       hint.data() + hint.size());
    draw_list->AddLine(ImVec2(origin.x + content_boundary, origin.y + 4.0f),
                       ImVec2(origin.x + content_boundary, origin.y + kFooterHeight - 4.0f),
                       divider, 1.0f);
}

// ---------------------------------------------------------------------------
// Script Console (floating window; toggled by the header "Lua" button).
// Layout: left script list + right editor + bottom log + one-line REPL.
// Pattern sources (docs/imgui-implot-reference.md):
//   * second Begin window — example main.cpp:178-186, Cond_FirstUseEver so
//     the user can drag/resize it;
//   * log panel — official ExampleAppLog clipper + follow-tail;
//   * editor — InputTextMultiline + CallbackResize (std::string buffer) +
//     ImGui::Shortcut(Ctrl+S) which only fires while this window is focused
//     (Shortcut default route is focused-window-first);
//   * REPL — ExampleAppConsole input flags + SetKeyboardFocusHere(-1).
// ---------------------------------------------------------------------------
int ScriptEditorResize(ImGuiInputTextCallbackData* data) {
    auto* buffer = static_cast<std::string*>(data->UserData);
    if (data->EventFlag == ImGuiInputTextFlags_CallbackResize) {
        buffer->resize(static_cast<size_t>(data->BufSize));
        data->Buf = buffer->data();
    }
    return 0;
}

[[nodiscard]] int ScriptConsoleContent() {
    auto& runtime = ImGuiRuntime::instance();
    int actions = 0;
    if (!runtime.scripts_visible_) return actions;
    ImGui::SetNextWindowSize(ImVec2(640.0f, 480.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(140.0f, 120.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowSizeConstraints(ImVec2(420.0f, 300.0f),
                                        ImVec2(1200.0f, 900.0f));
    bool open = true;
    const std::string console_title = std::string{ImGuiRuntime::instance().lang().scripts_title} + "###scripts";
    const Lang& lang = ImGuiRuntime::instance().lang();
    if (ImGui::Begin(console_title.c_str(), &open)) {
        // ---- toolbar ------------------------------------------------------
        if (ImGui::Button(lang.script_new)) {
            runtime.script_events_.push_back(
                (static_cast<int>(ScriptEvent::NewScript) << 8));
        }
        ImGui::SameLine();
        if (ImGui::Button(lang.script_open_folder)) {
            runtime.script_events_.push_back(
                (static_cast<int>(ScriptEvent::OpenFolder) << 8));
        }
        ImGui::SameLine();
        if (ImGui::Button(lang.script_reload)) {
            runtime.script_events_.push_back(
                (static_cast<int>(ScriptEvent::Reload) << 8) |
                (runtime.script_edit_index_ >= 0
                     ? runtime.script_edit_index_ : 0));
        }
        ImGui::SameLine();
        if (ImGui::Button(lang.script_clear_log)) {
            runtime.script_events_.push_back(
                (static_cast<int>(ScriptEvent::ClearLog) << 8));
        }
        ImGui::SameLine();
        if (runtime.script_edit_dirty_) {
            ImGui::TextColored(rgb(0xE8681A), "*");
        }
        // Ctrl+S -> save event (routed: fires only while this window holds
        // focus; the Lua side writes the file and reloads the script).
        if (ImGui::Shortcut(ImGuiMod_Ctrl | ImGuiKey_S)) {
            runtime.script_events_.push_back(
                (static_cast<int>(ScriptEvent::Edit) << 8) | 0x40);
        }
        // ---- body: left list / right editor --------------------------------
        // Explicit height budget (single-level children; the earlier nested
        // (0,0) child combination produced ambiguous fill semantics).
        const float log_h = 110.0f;
        const float repl_h = ImGui::GetFrameHeightWithSpacing();
        const float body_h = ImGui::GetContentRegionAvail().y - log_h -
                             repl_h - ImGui::GetStyle().ItemSpacing.y * 3.0f -
                             ImGui::GetStyle().SeparatorSize * 2.0f;
        if (body_h > 60.0f) {
            // Left: script list.
            if (ImGui::BeginChild("##script_list", ImVec2(170.0f, body_h),
                                  ImGuiChildFlags_Borders |
                                      ImGuiChildFlags_ResizeX)) {
                for (int index = 0;
                     index < static_cast<int>(runtime.script_names_.size());
                     ++index) {
                    ImGui::PushID(index);
                    // Lua owns the enable ints; Checkbox needs bool —
                    // translate both directions (ImGui writes the bool).
                    bool checked =
                        runtime.script_enabled_ != nullptr &&
                        runtime.script_enabled_[index] != 0;
                    if (ImGui::Checkbox("##en", &checked)) {
                        if (runtime.script_enabled_ != nullptr) {
                            runtime.script_enabled_[index] = checked ? 1 : 0;
                        }
                    }
                    ImGui::SameLine();
                    const bool selected = runtime.script_edit_index_ == index;
                    // Show the human label (@name) when Lua supplied one;
                    // fall back to the filename for a pre-labels pair.  The
                    // selected index and the event index stay the NAME index —
                    // only the rendered string differs.
                    const char* const shown =
                        runtime.script_labels_.size() ==
                                runtime.script_names_.size()
                            ? runtime.script_labels_[index].c_str()
                            : runtime.script_names_[index].c_str();
                    if (ImGui::Selectable(shown, selected)) {
                        runtime.script_events_.push_back(
                            (static_cast<int>(ScriptEvent::Edit) << 8) | index);
                    }
                    // @desc/@name hover text from Lua (may be CJK; its glyphs
                    // are baked from script_descs_ in rebuild_fonts).  An empty
                    // entry means "no tooltip" -- never open an empty box.
                    // SetTooltip("%s", ...) keeps the text from being read as a
                    // printf format string.
                    if (ImGui::IsItemHovered() &&
                        index < static_cast<int>(runtime.script_descs_.size()) &&
                        !runtime.script_descs_[index].empty()) {
                        ImGui::SetTooltip("%s", runtime.script_descs_[index].c_str());
                    }
                    ImGui::PopID();
                }
            }
            ImGui::EndChild();
            ImGui::SameLine();
            // Right: embedded editor (mono font when available).
            if (ImGui::BeginChild("##script_editor", ImVec2(0.0f, body_h))) {
                if (runtime.script_edit_index_ < 0) {
                    EmptyState(lang.script_empty_title, lang.script_empty_detail);
                } else {
                    ImGui::TextDisabled("%s", runtime.script_edit_path_.c_str());
                    const auto mono_ok = runtime.mono_font_ != nullptr;
                    if (mono_ok) ImGui::PushFont(runtime.mono_font_);
                    ImGuiInputTextFlags flags =
                        ImGuiInputTextFlags_AllowTabInput |
                        ImGuiInputTextFlags_CallbackResize;
                    const bool changed = ImGui::InputTextMultiline(
                        "##script_edit", runtime.script_edit_buf_.data(),
                        runtime.script_edit_buf_.size(),
                        ImVec2(-FLT_MIN, 0.0f),
                        flags, ScriptEditorResize,
                        &runtime.script_edit_buf_);
                    if (changed) runtime.script_edit_dirty_ = true;
                    if (mono_ok) ImGui::PopFont();
                }
            }
            ImGui::EndChild();
        }
        // ---- log panel ------------------------------------------------------
        ImGui::Separator();
        if (ImGui::BeginChild("##script_log", ImVec2(0.0f, log_h),
                              ImGuiChildFlags_Borders,
                              ImGuiWindowFlags_HorizontalScrollbar)) {
            // Follow-tail decided by the at-bottom state BEFORE rendering.
            const bool was_bottom =
                ImGui::GetScrollY() >= ImGui::GetScrollMaxY();
            const char* const data = runtime.script_log_.data();
            const std::vector<std::size_t>& offsets = runtime.script_log_lines_;
            ImGuiListClipper clipper;
            clipper.Begin(static_cast<int>(offsets.size()));
            while (clipper.Step()) {
                for (int line_no = clipper.DisplayStart;
                     line_no < clipper.DisplayEnd; ++line_no) {
                    const std::size_t begin_off =
                        offsets[static_cast<std::size_t>(line_no)];
                    const std::size_t end_off =
                        line_no + 1 < static_cast<int>(offsets.size())
                            ? offsets[static_cast<std::size_t>(line_no) + 1U] - 1U
                            : runtime.script_log_.size();
                    // Level-prefix coloring ([ERROR]/[WARN ]/... from the Lua
                    // engine's fixed-width tags).
                    const char* const line_begin = data + begin_off;
                    const char* const line_end = data + end_off;
                    ImVec4 color(0.0f, 0.0f, 0.0f, -1.0f);
                    if (line_end - line_begin > 6 && line_begin[0] == '[') {
                        if (strncmp(line_begin, "[ERROR", 6) == 0 ||
                            strncmp(line_begin, "[FATAL", 6) == 0) {
                            color = rgb(0xC50500);
                        } else if (strncmp(line_begin, "[WARN ", 6) == 0) {
                            color = rgb(0xB36B00);
                        } else if (strncmp(line_begin, "[INFO ", 6) == 0) {
                            color = rgb(0x1B7F3B);
                        }
                    }
                    if (color.w > 0.0f) ImGui::TextColored(color, "%.*s",
                        static_cast<int>(end_off - begin_off), line_begin);
                    else ImGui::TextUnformatted(line_begin, line_end);
                }
            }
            clipper.End();
            if (runtime.script_log_follow_ && was_bottom) {
                ImGui::SetScrollHereY(1.0f);
            }
        }
        ImGui::EndChild();
        // ---- REPL -----------------------------------------------------------
        ImGui::Separator();
        ImGui::PushItemWidth(-60.0f);
        const bool submitted = ImGui::InputText(
            "##repl", runtime.script_command_, sizeof(runtime.script_command_),
            ImGuiInputTextFlags_EnterReturnsTrue |
                ImGuiInputTextFlags_EscapeClearsAll);
        ImGui::PopItemWidth();
        if (submitted) {
            runtime.script_command_ready_ = true;
            ImGui::SetKeyboardFocusHere(-1);
        }
        ImGui::SameLine();
        ImGui::TextDisabled("%s", lang.repl_label);
    }
    ImGui::End();  // must run even when Begin returned false (collapsed)
    if (!open) {
        // Closed via the title-bar X: report the toggle so the Lua mirror
        // stays in sync.
        actions |= Action::ActionToggleScripts;
        runtime.scripts_visible_ = false;
    }
    return actions;
}

// ---------------------------------------------------------------------------
// ImPlot oscilloscope (floating window).  Pattern: official Demo_RealtimePlots
// ScrollingBuffer + SetupAxisLimits(ImGuiCond_Always) follow-tail
// (implot_demo.cpp:1043-1055) + DragLineX measurement cursors with a
// TagX dt readout.  Panning away (drag/box-select) detaches the follow; a
// double-click re-fits (ImPlot built-in).  Data flows in ONLY through
// xcom_imgui_scope_push (Lua side, uv.now() timestamps) — the bridge never
// samples time itself because frames are passive (16-100 ms).
// Visibility is host-driven: Lua sets scope_visible_ from script activity
// (window.lua _reconcile_scope_visibility); the panel's title-bar X clears it
// here and reports ActionToggleScope so Lua records the dismissal.
// ---------------------------------------------------------------------------
[[nodiscard]] int ScopeContent() {
    auto& runtime = ImGuiRuntime::instance();
    int actions = 0;
    if (!runtime.scope_visible_) return actions;
    ImGui::SetNextWindowSize(ImVec2(760.0f, 320.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(80.0f, 420.0f), ImGuiCond_FirstUseEver);
    bool open = true;
    const Lang& lang = ImGuiRuntime::instance().lang();
    const std::string scope_title = std::string{lang.scope_title} + "###scope";
    if (ImGui::Begin(scope_title.c_str(), &open)) {
        // History window + follow toggle.
        ImGui::SetNextItemWidth(120.0f);
        ImGui::SliderFloat("##history", &runtime.scope_history_s_, 1.0f, 60.0f,
                           "%.1f s");
        ImGui::SameLine();
        if (ImGui::Checkbox(lang.scope_follow, &runtime.scope_follow_)) {}
        ImGui::SameLine();
        ImGui::TextDisabled("%s", lang.scope_hint);
        if (!runtime.scope_has_data_) {
            EmptyState(lang.scope_empty_title, lang.scope_empty_detail);
        } else {
            const double latest = runtime.scope_last_x_;
            if (ImPlot::BeginPlot(
                    "##scope_plot", ImVec2(-1.0f, -ImGui::GetFrameHeightWithSpacing()),
                    ImPlotFlags_Crosshairs)) {
                ImPlot::SetupAxes(lang.scope_axis_x, nullptr,
                                  ImPlotAxisFlags_NoTickLabels, 0);
                // Follow-tail: lock X to [latest-history, latest] every
                // frame (ImGuiCond_Always); pan/box-select by the user makes
                // GetPlotLimits drift — we then release follow so the view
                // sticks where they left it.
                if (runtime.scope_follow_) {
                    ImPlot::SetupAxisLimits(
                        ImAxis_X1, latest - runtime.scope_history_s_, latest,
                        ImGuiCond_Always);
                } else {
                    const ImPlotRect view = ImPlot::GetPlotLimits();
                    // Re-attach when the user pans back near the tail.
                    if (view.X.Max >= latest - 0.05) {
                        runtime.scope_follow_ = true;
                    }
                }
                ImPlot::SetupAxisLimits(ImAxis_Y1, -0.2, 5.2, ImGuiCond_Once);
                // Auto-fit Y so a serial numeric stream (sensor/ADC values of
                // any range) is visible without a pre-configured bound; the
                // first real sample wins the range and follow keeps the tail
                // centred.  A user zoom/pan on Y is respected until they
                // scroll back to bottom (ImPlot re-fits on ImGuiCond_Once is
                // skipped after the first frame, so this stays auto only for
                // the demo/deterministic streams).
                runtime.scope_y_fit_ = true;
                if (runtime.scope_y_fit_) {
                    ImPlot::SetupAxis(ImAxis_Y1, nullptr,
                                      ImPlotAxisFlags_AutoFit);
                }
                // Channels: fixed palette, ring read via Spec.Offset/Stride.
                static const ImVec4 kChannelColors[kScopeChannelsMax] = {
                    ImVec4(0.00f, 0.80f, 0.40f, 1.0f),   // CH1 green
                    ImVec4(0.20f, 0.60f, 1.00f, 1.0f),   // CH2 blue
                    ImVec4(1.00f, 0.33f, 0.33f, 1.0f),   // CH3 red
                    ImVec4(1.00f, 0.80f, 0.00f, 1.0f),   // CH4 amber
                };
                for (int ch = 0; ch < kScopeChannelsMax; ++ch) {
                    const auto& channel = runtime.scope_[ch];
                    if (channel.count < 2 || !channel.visible) continue;
                    char label[8];
                    sprintf_s(label, "CH%d", ch + 1);
                    ImPlotSpec spec;
                    spec.LineColor = kChannelColors[ch];
                    spec.LineWeight = 1.5f;
                    spec.Offset = channel.offset;
                    spec.Stride = sizeof(float);
                    ImPlot::PlotLine(label, channel.xs, channel.ys,
                                     channel.count, spec);
                }
                // Measurement cursors A/B + dt readout.
                ImPlot::DragLineX(1, &runtime.scope_cursor_a_,
                                  ImVec4(0.92f, 0.40f, 0.10f, 0.9f), 1.0f,
                                  ImPlotDragToolFlags_NoFit);
                ImPlot::DragLineX(2, &runtime.scope_cursor_b_,
                                  ImVec4(0.92f, 0.40f, 0.10f, 0.9f), 1.0f,
                                  ImPlotDragToolFlags_NoFit);
                ImPlot::TagX(runtime.scope_cursor_a_,
                             ImVec4(0.92f, 0.40f, 0.10f, 0.9f), "A");
                ImPlot::TagX(runtime.scope_cursor_b_,
                             ImVec4(0.92f, 0.40f, 0.10f, 0.9f), "B");
                ImGui::PushStyleColor(ImGuiCol_Text, rgb(palette::kTextMuted));
                ImGui::Text(lang.scope_dt_fmt,
                            runtime.scope_cursor_b_ - runtime.scope_cursor_a_);
                ImGui::PopStyleColor();
                if (ImPlot::IsPlotHovered()) {
                    const ImPlotPoint mp = ImPlot::GetPlotMousePos();
                    ImPlot::Annotation(mp.x, mp.y, ImVec4(1, 1, 0, 1),
                                       ImVec2(10, 10), true,
                                       "(%.3f, %.3f)", mp.x, mp.y);
                }
                ImPlot::EndPlot();
            }
        }
    }
    ImGui::End();
    if (!open) {
        actions |= Action::ActionToggleScope;
        runtime.scope_visible_ = false;
    }
    return actions;
}

// Plugin spec grammar (one widget per line; Lua owns the page, C++ owns the
// drawing; values live in PluginPage::values_ indexed by spec line).  Widget
// ids must be [A-Za-z0-9_.-] — ':' is the field separator and NUL terminates
// nothing here, so a ':' inside an id would desync the event protocol:
//   # ...                       comment
//   title:Label text            section label
//   check:wid:Label:0|1         toggle chip (last field = default)
//   slider:wid:Label:min:max:default
//   combo:wid:Label:idx:a|b|c   items joined by '|' (idx = default item)
//   button:wid:Label            fires a click event
// Every interaction appends "page:kind:wid[:value]" to plugin_events_.
// Widgets render under PushID(wid), so ids stay unique even when two lines
// share a visible label.
std::string_view spec_field(std::string_view& line, const char delimiter) {
    const size_t pos = line.find(delimiter);
    std::string_view field = pos == std::string_view::npos
                                 ? line : line.substr(0, pos);
    line = pos == std::string_view::npos
               ? std::string_view{} : line.substr(pos + 1);
    return field;
}

void spec_event(ImGuiRuntime& runtime, const ImGuiRuntime::PluginPage& page,
                std::string_view kind, std::string_view widget_id,
                std::string_view value) {
    constexpr size_t kMaxQueued = 256U;   // bounded: a Lua side that never
    if (runtime.plugin_events_.size() >= kMaxQueued) {   // drains must not grow
        runtime.plugin_events_.erase(runtime.plugin_events_.begin());
    }
    std::string event{page.id};
    event.push_back(':');
    event.append(kind.data(), kind.size());
    event.push_back(':');
    event.append(widget_id.data(), widget_id.size());
    if (!value.empty()) {
        event.push_back(':');
        event.append(value.data(), value.size());
    }
    runtime.plugin_events_.push_back(std::move(event));
}

// Split one spec line's tail into per-widget defaults (first pass, run once
// per page declaration).  Storing defaults up front keeps the render pass
// free of "0 means unset" sentinel bugs (a combo on item 0, a slider at 0).
void LoadPluginDefaults(ImGuiRuntime::PluginPage& page) {
    std::string_view rest{page.spec};
    int line_index = 0;
    while (!rest.empty()) {
        const size_t newline = rest.find('\n');
        std::string_view row = newline == std::string_view::npos
                                   ? rest : rest.substr(0, newline);
        rest = newline == std::string_view::npos
                   ? std::string_view{} : rest.substr(newline + 1);
        const int widget_line = line_index;
        ++line_index;
        if (widget_line >= ImGuiRuntime::PluginPage::kWidgetsMax) {
            break;
        }
        if (row.empty() || row[0] == '#') {
            continue;
        }
        const std::string_view kind = spec_field(row, ':');
        if (kind == "check") {
            (void)spec_field(row, ':');   // widget id
            (void)spec_field(row, ':');   // label
            page.values_[widget_line] = atoi(std::string(spec_field(row, ':')).c_str());
        } else if (kind == "slider") {
            (void)spec_field(row, ':');   // widget id
            (void)spec_field(row, ':');   // label
            (void)spec_field(row, ':');   // min
            (void)spec_field(row, ':');   // max
            page.values_[widget_line] = strtod(std::string(row).c_str(), nullptr);
        } else if (kind == "combo") {
            (void)spec_field(row, ':');   // widget id
            (void)spec_field(row, ':');   // label
            page.values_[widget_line] = atoi(std::string(spec_field(row, ':')).c_str());
        }
    }
    page.values_ready_ = true;
}

void RenderPluginSpec(ImGuiRuntime& runtime, ImGuiRuntime::PluginPage& page) {
    if (!page.values_ready_) LoadPluginDefaults(page);
    std::string_view rest{page.spec};
    int line_index = 0;
    char number[32]{};
    while (!rest.empty()) {
        const size_t newline = rest.find('\n');
        std::string_view row = newline == std::string_view::npos
                                   ? rest : rest.substr(0, newline);
        rest = newline == std::string_view::npos
                   ? std::string_view{} : rest.substr(newline + 1);
        const int widget_line = line_index;
        ++line_index;
        if (widget_line >= ImGuiRuntime::PluginPage::kWidgetsMax) {
            break;   // spec longer than the value slots: stop, do not drop keys
        }
        if (row.empty() || row[0] == '#') {
            continue;
        }
        std::string_view kind = spec_field(row, ':');
        if (kind == "title") {
            Section(row);
            continue;
        }
        std::string_view wid = spec_field(row, ':');
        std::string_view label = spec_field(row, ':');
        // PushID(wid) keeps widget IDs unique even when two lines share a
        // visible label (the "Label###id" trick would print through Toggle's
        // TextUnformatted, which does not strip the ## suffix).
        ImGui::PushID(std::string(wid).c_str());
        if (kind == "check") {
            int state = static_cast<int>(page.values_[widget_line]);
            if (Toggle(std::string(label).c_str(), &state)) {
                page.values_[widget_line] = state;
                spec_event(runtime, page, "check", wid, 0 == state ? "0" : "1");
            }
        } else if (kind == "button") {
            if (ImGui::Button(std::string(label).c_str())) {
                spec_event(runtime, page, "click", wid, {});
            }
        } else if (kind == "slider") {
            const float lo = static_cast<float>(
                strtod(std::string(spec_field(row, ':')).c_str(), nullptr));
            const float hi = static_cast<float>(
                strtod(std::string(spec_field(row, ':')).c_str(), nullptr));
            float slider_value = static_cast<float>(page.values_[widget_line]);
            if (ImGui::SliderFloat(std::string(label).c_str(), &slider_value, lo, hi)) {
                page.values_[widget_line] = slider_value;
                sprintf_s(number, "%.6g", static_cast<double>(slider_value));
                spec_event(runtime, page, "slider", wid, number);
            }
        } else if (kind == "combo") {
            (void)spec_field(row, ':');   // default index (already loaded)
            std::string items{row};   // 'a|b|c' -> ImGui display "a\0b\0c\0"
            for (char& ch : items) {
                if (ch == '|') ch = '\0';
            }
            int current = static_cast<int>(page.values_[widget_line]);
            if (ImGui::Combo(std::string(label).c_str(), &current, items.c_str())) {
                page.values_[widget_line] = current;
                sprintf_s(number, "%d", current);
                spec_event(runtime, page, "combo", wid, number);
            }
        }
        ImGui::PopID();
    }
}

// Settings floating window (user ask: "设置"按钮弹出配置).  Left column keeps
// host-level options (body font size, like llcom's SettingWindow basics).  Lua
// plugin pages (xcom_imgui_set_plugin_page) no longer render as tabs here:
// each is its own top-level window (PluginWindowsContent below), and this
// window keeps a "Plugin windows" section with one toggle per page so a window
// the user closed can be re-opened.
[[nodiscard]] int SettingsContent() {
    auto& runtime = ImGuiRuntime::instance();
    int actions = 0;
    if (!runtime.settings_visible_) return actions;
    ImGui::SetNextWindowSize(ImVec2(560.0f, 400.0f), ImGuiCond_FirstUseEver);
    ImGui::SetNextWindowPos(ImVec2(180.0f, 90.0f), ImGuiCond_FirstUseEver);
    bool open = true;
    const Lang& lang = ImGuiRuntime::instance().lang();
    // Keep the window's ImGui ID stable ("###settings") across language
    // switches so the floating-window position persists in imgui.ini.
    const std::string settings_title = std::string{lang.settings_title} + "###settings";
    if (ImGui::Begin(settings_title.c_str(), &open)) {
        if (ImGui::BeginTabBar("##settings_tabs")) {
            if (ImGui::BeginTabItem(lang.general_tab)) {
                Section(lang.appearance);
                ImGui::TextUnformatted(lang.font_size);
                for (int index = 0; index < 3; ++index) {
                    char label[24]{};
                    sprintf_s(label, "%d px", static_cast<int>(fontsz::kBodySizes[index]));
                    const bool active = runtime.body_font_index_ == index;
                    // Swap io.FontDefault between the pre-baked body faces (the
                    // atlases exist from init, so this is a pointer flip, not a
                    // texture rebuild).
                    if (ImGui::RadioButton(label, active)) {
                        if (ImFont* font = runtime.body_fonts_[index]) {
                            runtime.body_font_index_ = index;
                            ImGui::GetIO().FontDefault = font;
                        }
                    }
                }
                // Runtime toggle for baking the mono font's CJK glyphs (2500
                // hanzi + kana): on = receive log shows Chinese, off = Chinese
                // renders as '?' and the ~26 MB of extra bitmap memory is freed.
                // The actual atlas rebuild is deferred to the top of the next
                // new_frame (never mid-draw) to avoid touching fonts while a
                // window/draw-list is live.
                bool show_chinese = runtime.font_mono_cjk_;
                if (ImGui::Checkbox(lang.mono_cjk_label, &show_chinese)) {
                    if (show_chinese != runtime.font_mono_cjk_) {
                        runtime.font_mono_cjk_ = show_chinese;
                        runtime.font_rebuild_pending_ = true;
                    }
                }
                ImGui::EndTabItem();
            }
            // Lua plugin pages are NO LONGER tabs of this window: each renders
            // as its own top-level window (PluginWindowsContent, below).  The
            // Settings window keeps one toggle per page so a window the user
            // closed can be brought back.  The section is hidden entirely when
            // no plugin declared a page.
            if (!runtime.plugin_pages_.empty()) {
                ImGui::Separator();
                Section(lang.plugin_windows);
                for (auto& page : runtime.plugin_pages_) {
                    ImGui::PushID(page.id.c_str());
                    bool open = page.window_open_;
                    if (ImGui::Checkbox(page.title.c_str(), &open)) {
                        page.window_open_ = open;
                        if (open) page.window_appeared_ = false;  // re-seed pos
                    }
                    ImGui::PopID();
                }
            }
            ImGui::EndTabBar();
        }
    }
    ImGui::End();
    if (!open) {
        actions |= Action::ActionToggleSettings;
        runtime.settings_visible_ = false;
    }
    return actions;
}

// Lua plugin pages as independent floating windows (user ask: "lua插件生成的
// 界面最好是独立的窗口").  Each PluginPage gets its own top-level ImGui window
// whose ImGui ID is keyed off the page id, so two plugins sharing a display
// title still get distinct windows/positions.  A closed (X) window does NOT
// drop the page — the spec stays live and the Settings window's toggle
// re-opens it, which is what makes the checkbox in Settings meaningful.
[[nodiscard]] int PluginWindowsContent() {
    auto& runtime = ImGuiRuntime::instance();
    if (runtime.plugin_pages_.empty()) return 0;
    int actions = 0;
    for (auto& page : runtime.plugin_pages_) {
        if (!page.window_open_) continue;
        // First appearance: cascade the window so two plugins don't stack
        // exactly on top of each other.  Persisted position (imgui.ini) wins
        // on later runs via FirstUseEver.
        if (!page.window_appeared_) {
            page.window_appeared_ = true;
            ImGui::SetNextWindowSize(ImVec2(360.0f, 260.0f),
                                     ImGuiCond_FirstUseEver);
            ImGui::SetNextWindowPos(ImVec2(220.0f, 120.0f),
                                    ImGuiCond_FirstUseEver);
        }
        bool open = page.window_open_;
        // "Title###plugin_<id>": the part before ### is the visible title
        // (user-authored, may be Chinese), the part after is the stable ImGui
        // ID — so two plugins sharing a display title still get distinct
        // windows and remembered positions.  The id originates from Lua's
        // "script.lua:local_id" page key, so it is unique process-wide.
        const std::string window_title{page.title + "###plugin_" + page.id};
        if (ImGui::Begin(window_title.c_str(), &open)) {
            RenderPluginSpec(runtime, page);
        }
        ImGui::End();
        // The X button flips `open`; mirror it so Settings' checkbox follows
        // and the window stays closed until re-opened.
        page.window_open_ = open;
    }
    return actions;
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

// Absolute path of a font shipped with Windows itself (CJK faces, console
// mono).  Resolved once through GetWindowsDirectoryW so a non-C: system
// drive works; the historical literals hardcoded C:\Windows\Fonts and
// silently degraded to fallbacks on relocated installs.
std::string system_font_path(std::string_view file_name) {
    static const std::string dir = [] {
        wchar_t wide[MAX_PATH] = {};
        const UINT n = GetWindowsDirectoryW(wide, MAX_PATH);
        if (n == 0U || n >= MAX_PATH) {
            return std::string("C:\\Windows");
        }
        std::string narrow;
        narrow.resize(n * 3U + 1U);
        const int bytes = WideCharToMultiByte(CP_UTF8, 0U, wide, n,
                                              narrow.data(),
                                              static_cast<int>(narrow.size()),
                                              nullptr, nullptr);
        if (bytes <= 0) {
            return std::string("C:\\Windows");
        }
        narrow.resize(static_cast<size_t>(bytes));
        narrow += "\\Fonts";
        return narrow;
    }();
    std::string path = dir;
    path += '\\';
    path.append(file_name.data(), file_name.size());
    return path;
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
    LayoutEntry{"sidebar_width",    150.0f, 320.0f, &LayoutConfig::sidebar_width},
    LayoutEntry{"compact_threshold", 600.0f, 1200.0f, &LayoutConfig::compact_threshold},
    LayoutEntry{"receive_height",     0.0f, 600.0f, &LayoutConfig::receive_height},
    LayoutEntry{"send_height",      100.0f, 360.0f, &LayoutConfig::send_height},
    LayoutEntry{"header_height",     24.0f,  72.0f, &LayoutConfig::header_height},
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
    // [layout] numeric knobs + [font] boolean switches + [ui] language share
    // one scanner; the section tag routes each key to its consumer.
    int section = 0;  // 0 = none, 1 = [layout], 2 = [font], 3 = [ui]
    while (std::getline(input, line)) {
        const size_t comment = line.find('#');
        if (comment != std::string::npos) line.resize(comment);
        const std::string_view trimmed = trim_view(line);
        if (trimmed.empty()) continue;
        if (trimmed.front() == '[') {
            section = trimmed == "[layout]" ? 1
                        : trimmed == "[font]" ? 2
                        : trimmed == "[ui]" ? 3 : 0;
            continue;
        }
        if (section == 3) {
            // [ui] switches: language = "zh" | "en" (default zh, matching the
            // Chinese pic/1.png reference).
            const size_t equals = trimmed.find('=');
            if (equals == std::string_view::npos) continue;
            const std::string_view key = trim_view(trimmed.substr(0, equals));
            std::string_view raw = trim_view(trimmed.substr(equals + 1));
            if (raw.size() >= 2 && (raw.front() == '"' || raw.front() == '\'')) {
                raw = raw.substr(1, raw.size() - 2);   // strip quotes
            }
            if (key == "language") {
                ImGuiRuntime::instance().ui_lang_zh_ = !(raw == "en" || raw == "English");
            }
            continue;
        }
        if (section == 2) {
            // [font] switches: show_chinese_in_receive (default off). The
            // plain-language config key maps to the internal font_mono_cjk_
            // flag; see the member comment for the memory-first default.
            const size_t equals = trimmed.find('=');
            if (equals == std::string_view::npos) continue;
            const std::string_view key = trim_view(trimmed.substr(0, equals));
            const std::string_view raw = trim_view(trimmed.substr(equals + 1));
            if (key == "show_chinese_in_receive") {
                ImGuiRuntime::instance().font_mono_cjk_ =
                    raw != "false" && raw != "off" && raw != "0";
            }
            continue;
        }
        if (section != 1) continue;
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
    ImPlot::DestroyContext();  // before ImGui::DestroyContext
    ImGui::DestroyContext();
    release_dx_resources(runtime);
    runtime.owner_thread_ = 0;
    runtime.initialized_ = false;
    runtime.frame_active_ = false;
    runtime.heading_font_ = nullptr;
    runtime.mono_font_ = nullptr;
    runtime.receive_text_.clear();
}
}

namespace {
// One static style assignment: target colour slot plus palette value (with
// optional alpha).  Table-driven so adding or re-tinting a colour is a data
// edit, not another hand-written assignment line; applied by apply_style().
struct StyleColorEntry final {
    ImGuiCol slot;
    std::uint32_t value;
    float alpha;
};
constexpr std::array kStyleColors{
    StyleColorEntry{ImGuiCol_Text, 0x1B1B1B, 1.0f},
    StyleColorEntry{ImGuiCol_TextDisabled, 0x8C8C8C, 1.0f},
    StyleColorEntry{ImGuiCol_WindowBg, 0xFBFCFD, 1.0f},
    StyleColorEntry{ImGuiCol_ChildBg, 0xFBFCFD, 1.0f},                  // 1.png: no gray default children
    StyleColorEntry{ImGuiCol_PopupBg, 0xFFFFFF, 1.0f},
    StyleColorEntry{ImGuiCol_Border, 0xB8BFC7, 0.9f},                   // 1px edges: inputs + floating-panel borders
    StyleColorEntry{ImGuiCol_BorderShadow, 0xFFFFFF, 0.0f},
    StyleColorEntry{ImGuiCol_TextSelectedBg, 0x005A98, 0.35f},           // 1.png primary blue selection
    StyleColorEntry{ImGuiCol_Separator, 0xDEDEDE, 1.0f},               // 1.png sidebar section lines
    StyleColorEntry{ImGuiCol_FrameBg, 0xFFFFFF, 1.0f},
    StyleColorEntry{ImGuiCol_FrameBgHovered, 0xE8F3F8, 1.0f},
    StyleColorEntry{ImGuiCol_FrameBgActive, 0xD6EAF3, 1.0f},
    StyleColorEntry{ImGuiCol_Button, 0xF8F8F8, 1.0f},                    // 1.png plain (Open) btn bg
    StyleColorEntry{ImGuiCol_ButtonHovered, 0xE3F0FB, 1.0f},
    StyleColorEntry{ImGuiCol_ButtonActive, 0xD4E7F7, 1.0f},
    StyleColorEntry{ImGuiCol_Header, 0xE3F0FB, 1.0f},
    StyleColorEntry{ImGuiCol_HeaderHovered, 0xD4E7F7, 1.0f},
    StyleColorEntry{ImGuiCol_HeaderActive, 0xD4E7F7, 1.0f},
    StyleColorEntry{ImGuiCol_CheckMark, 0x005A98, 1.0f},                // 1.png primary
    StyleColorEntry{ImGuiCol_SliderGrab, 0x005A98, 1.0f},
    StyleColorEntry{ImGuiCol_SliderGrabActive, 0x004270, 1.0f},
    StyleColorEntry{ImGuiCol_Tab, 0xFBFCFD, 1.0f},                     // 1.png tab band is white, no gray strip
    StyleColorEntry{ImGuiCol_TabHovered, 0xE3F0FB, 1.0f},
    StyleColorEntry{ImGuiCol_TabActive, 0x005A98, 1.0f},
    StyleColorEntry{ImGuiCol_TabUnfocused, 0xFBFCFD, 1.0f},
    StyleColorEntry{ImGuiCol_TabUnfocusedActive, 0x005A98, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarBg, 0xE8EAEC, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarGrab, 0xC4C8CC, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarGrabHovered, 0xAEB4BA, 1.0f},
    StyleColorEntry{ImGuiCol_ScrollbarGrabActive, 0x005A98, 1.0f},
};

// Geometry knobs that live outside layout.toml (fixed look, not user-tunable).
constexpr float kClearColor[4] = {0xFB / 255.0f, 0xFC / 255.0f, 0xFD / 255.0f, 1.0f};

// Shared CJK font data (memory).  AddFontFromFileTTF copies the WHOLE file
// into the atlas per call, so merging a font at several sizes would duplicate
// the bytes per merge.  Load the ONE CJK face (the bundled SimHeiCJK.ttf,
// ~0.7 MB) into a static buffer and hand every merge (body 13/15/17 + heading
// + mono) the same pointer with FontDataOwnedByAtlas=false.  File-scope static
// keeps the buffer alive for the whole process (including after a runtime
// rebuild via ClearFonts() + re-AddFont) so a rebuild never re-reads the disk.
// The bold msyhbd.ttc (~17 MB) is deliberately not loaded: the heading's LATIN
// weight comes from SiemensSlabBold, and its few CJK label glyphs reuse this
// regular face (see merge_ui_glyphs) — that drop alone saved ~17 MB resident.
static const std::vector<char> cjk_data = [] {
    std::vector<char> buf;
    if (FILE* const f = fopen(module_asset_path("SimHeiCJK.ttf").c_str(), "rb")) {
        fseek(f, 0, SEEK_END);
        const long size = ftell(f);
        fseek(f, 0, SEEK_SET);
        buf.resize(static_cast<size_t>(size));
        if (fread(buf.data(), 1, buf.size(), f) != buf.size()) buf.clear();
        fclose(f);
    }
    return buf;
}();

// Rebuild the entire font atlas in place: clears all registered fonts (and
// their per-size glyph bitmaps), then re-Adds body/heading/mono faces.  Called
// at init (first build) and on demand when the mono-CJK toggle flips at
// runtime.  This bridges ImGui 1.93's dynamic atlas: we never call Build() or
// the DX11 device-object invalidation — ClearFonts() is documented mid-frame
// safe (1.92+) and the renderer's RendererHasTextures flag defers texture
// re-creation to the next NewFrame, so the old textures are released after
// their frames in flight retire (`WantDestroyNextFrame`).
//
// Ownership/lifetime contracts (see the init-site comments — they still hold):
//   * cjk_data is a file-scope `static const std::vector<char>` (bundled
//     SimHeiCJK.ttf, ~0.7 MB) owned by the process, passed with
//     FontDataOwnedByAtlas=false; after ClearFonts() the buffer is untouched,
//     so the rebuild reuses it without a second disk read.
//   * ui_glyph_ranges_ / cjk_ranges_ are Runtime ImVector<ImWchar> members the
//     atlas stores POINTERS into; they must be cleared() then re-BuildRanges'd
//     here (AddFontFromFileTTF records only the .Data pointer).
//   * io.FontDefault is NOT cleared by ClearFonts(), so it is reset manually to
//     the current body_font_index_ face (nullptr guard) rather than a hardcoded
//     15px.
static void rebuild_fonts(ImGuiRuntime& runtime) {
    ImGuiIO& io = ImGui::GetIO();

    // (1) Null out every live ImFont pointer and clear the atlas.  FontDefault
    // must be cleared explicitly: ClearFonts() drops the registered sources but
    // leaves FontDefault untouched, which would dangle past a resize.
    runtime.body_fonts_[0] = runtime.body_fonts_[1] = runtime.body_fonts_[2] = nullptr;
    runtime.heading_font_ = nullptr;
    runtime.mono_font_ = nullptr;
    io.FontDefault = nullptr;
    io.Fonts->ClearFonts();

    // (2) Rebuild the localized-label glyph set from the active Lang table.
    // The body/heading faces store ui_glyph_ranges_.Data by pointer, so the
    // buffer must be freshly built (and cleared) before any AddFont below.
    runtime.ui_glyph_ranges_.clear();
    {
        ImFontGlyphRangesBuilder text_builder;   // stack: 8 KB bitmap, never static
        const Lang& lang = runtime.lang();
        lang.for_each_text([&text_builder](const char* const utf8) { text_builder.AddText(utf8); });
        text_builder.AddText("0123456789");
        // Script list labels (@name) are user-authored Chinese, so their glyphs
        // are NOT in the Lang tables — register them here or a script calling
        // itself "绘制曲线" renders as tofu in the console list.  The body and
        // heading faces both merge ui_glyph_ranges_, so one pass covers both.
        for (const std::string& label : runtime.script_labels_) {
            text_builder.AddText(label.c_str());
        }
        // Script-list hover tooltips (@desc) are user-authored too and render
        // in the body face via SetTooltip, so they need the same glyph merge.
        for (const std::string& desc : runtime.script_descs_) {
            text_builder.AddText(desc.c_str());
        }
        // The footer status line is set by Lua and may contain Chinese
        // ("端口被其他程序占用", "串口连接异常，等待恢复...").  It is re-baked
        // on change (see xcom_imgui_set_status), so only the current string
        // needs to be registered here.
        if (!runtime.status_text_.empty()) {
            text_builder.AddText(runtime.status_text_.c_str());
        }
        text_builder.BuildRanges(&runtime.ui_glyph_ranges_);
    }

    // ImFontConfig for the base Latin body faces.
    ImFontConfig font_config;
    font_config.OversampleH = 2;
    font_config.OversampleV = 1;
    font_config.PixelSnapH = true;
    font_config.GlyphRanges = io.Fonts->GetGlyphRangesDefault();

    // Merge the localized CJK label set into the most-recently-added face.
    // (MergeMode targets the last AddFont, not a named font; hence the strict
    // call ordering below.)  Reuses the single resident cjk_data buffer.
    //
    // CJK is baked ONE PIXEL SMALLER than the Latin face (size_px - 1).  In the
    // 1.92 dynamic atlas a merged source's SizePixels is a RELATIVE scale vs
    // the first source (imgui_draw.cpp: ScaleFactor *= src->SizePixels /
    // ref_size, ref_size = the Latin face's size), so passing size_px-1 renders
    // hanzi at (size_px-1) while Siemens Latin stays at size_px.  YaHei/SimHei
    // square glyphs fill their em box and read visibly larger than the Latin
    // x-height at equal px — this is what pushed "毫秒" out of the sidebar row.
    auto merge_ui_glyphs = [&io, &runtime](const float size_px) {
        const float cjk_size = size_px - fontsz::kCjkShrinkPx;
        const std::vector<char>& source = cjk_data;
        if (!source.empty()) {
            ImFontConfig merge;
            merge.MergeMode = true;
            merge.FontDataOwnedByAtlas = false;
            if (io.Fonts->AddFontFromMemoryTTF(const_cast<char*>(source.data()),
                                               static_cast<int>(source.size()),
                                               cjk_size, &merge,
                                               runtime.ui_glyph_ranges_.Data) != nullptr) {
                return;
            }
        }
        ImFontConfig merge;
        merge.MergeMode = true;
        io.Fonts->AddFontFromFileTTF(system_font_path("simsun.ttc").c_str(), cjk_size, &merge,
                                     runtime.ui_glyph_ranges_.Data);
    };

    const std::string body_font = module_asset_path("SiemensSlabRoman.ttf");
    {
        ImFont* fallback_font = nullptr;
        for (size_t index = 0; index < fontsz::kBodySizes.size(); ++index) {
            ImFont* font = io.Fonts->AddFontFromFileTTF(body_font.c_str(),
                                                        fontsz::kBodySizes[index], &font_config);
            if (!font) {
                font = io.Fonts->AddFontFromFileTTF(system_font_path("segoeui.ttf").c_str(),
                                                    fontsz::kBodySizes[index], &font_config);
            }
            merge_ui_glyphs(fontsz::kBodySizes[index]);
            runtime.body_fonts_[index] = font;
            if (fontsz::kBodyDefaultIndex == static_cast<int>(index)) fallback_font = font;
        }
        if (fallback_font) io.FontDefault = fallback_font;
    }

    ImFontConfig heading_config = font_config;
    const std::string heading_font = module_asset_path("SiemensSlabBold.TTF");
    runtime.heading_font_ = io.Fonts->AddFontFromFileTTF(heading_font.c_str(), fontsz::kHeading, &heading_config);
    if (!runtime.heading_font_) runtime.heading_font_ = io.Fonts->AddFontFromFileTTF(system_font_path("segoeuib.ttf").c_str(), fontsz::kHeading, &heading_config);
    merge_ui_glyphs(fontsz::kHeading);   // heading is its own face — bake CJK so labels render correctly

    // Monospace data face for the serial log / hex column.
    runtime.mono_font_ = io.Fonts->AddFontFromFileTTF(
        system_font_path("consola.ttf").c_str(), fontsz::kMono, nullptr,
        io.Fonts->GetGlyphRangesDefault());
    if (!runtime.mono_font_) {
        runtime.mono_font_ = io.Fonts->AddFontFromFileTTF(
            system_font_path("cascadiamono.ttf").c_str(), fontsz::kMono, nullptr,
            io.Fonts->GetGlyphRangesDefault());
    }

    // Mono CJK merge, gated by the runtime toggle (default false).  When off,
    // the receive-log mono face simply keeps its default ranges and any CJK
    // bytes render as '?' — while the body/heading faces' own ui_glyph_ranges_
    // merge (above) keeps the localized labels intact.
    if (runtime.font_mono_cjk_) {
        runtime.cjk_ranges_.clear();
        ImFontGlyphRangesBuilder builder;
        builder.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
        builder.AddRanges(io.Fonts->GetGlyphRangesJapanese());
        builder.BuildRanges(&runtime.cjk_ranges_);
        ImFontConfig merge_config;
        merge_config.MergeMode = true;
        static constexpr int kGlyphBudget = 4200;   // ~2048px atlas page
        int glyph_count = 0;
        for (int i = 0; i + 1 < runtime.cjk_ranges_.size(); i += 2) {
            glyph_count += runtime.cjk_ranges_[i + 1] - runtime.cjk_ranges_[i];
        }
        if (glyph_count > kGlyphBudget) {
            runtime.cjk_ranges_.clear();
            ImFontGlyphRangesBuilder fallback;
            fallback.AddRanges(io.Fonts->GetGlyphRangesChineseSimplifiedCommon());
            fallback.BuildRanges(&runtime.cjk_ranges_);
        }
        ImFont* merged = nullptr;
        const float mono_cjk = fontsz::kMono - fontsz::kCjkShrinkPx;
        if (!cjk_data.empty()) {
            merge_config.FontDataOwnedByAtlas = false;
            merged = io.Fonts->AddFontFromMemoryTTF(
                const_cast<char*>(cjk_data.data()), static_cast<int>(cjk_data.size()), mono_cjk,
                &merge_config, runtime.cjk_ranges_.Data);
        } else {
            // Bundled SimHeiCJK.ttf missing (corrupted install): fall back to
            // the system SimHei face so the receive log still renders CJK in
            // the same family instead of the heavier, differently-metriced
            // YaHei.  simhei.ttf ships with every Windows install.
            merged = io.Fonts->AddFontFromFileTTF(
                system_font_path("simhei.ttf").c_str(), mono_cjk, &merge_config,
                runtime.cjk_ranges_.Data);
        }
        if (!merged) {
            merge_config.FontDataOwnedByAtlas = true;
            io.Fonts->AddFontFromFileTTF(
                system_font_path("simsun.ttc").c_str(), mono_cjk, &merge_config,
                runtime.cjk_ranges_.Data);
        }
    } else {
        // Off: no mono CJK merge, so drop the previous range buffer too —
        // ClearFonts() already detached the atlas's pointers to it; clearing
        // here releases the ImVector's memory rather than leaving it resident.
        runtime.cjk_ranges_.clear();
    }

    // (4) Restore FontDefault to the current body size (not a hardcoded 15px).
    // (5) Deliberately do NOT call Build()/InvalidateDeviceObjects()/
    //     CreateDeviceObjects(); the next NewFrame lazily re-bakes textures.
    if (runtime.body_font_index_ >= 0 && runtime.body_font_index_ < 3 &&
        runtime.body_fonts_[runtime.body_font_index_]) {
        io.FontDefault = runtime.body_fonts_[runtime.body_font_index_];
    }
}

void apply_style(const LayoutConfig& layout) {
    ImGuiStyle& style = ImGui::GetStyle();
    style.WindowRounding = 0.0f;
    style.ChildRounding = 0.0f;
    style.FrameRounding = 2.5f;   // 1.png frames are nearly square; 5px read too pill-like
    style.PopupRounding = 6.0f;
    style.TabRounding = 0.0f;
    style.ScrollbarRounding = 4.0f;
    style.WindowBorderSize = 0.0f;
    style.FrameBorderSize = 1.0f;
    style.ChildBorderSize = 1.0f;
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
    // Drop any stale copy request from a previous bridge instance.
    runtime.receive_copy_pending_.clear();
    // Full state reset for the absolute-coordinate contract: receive_base_
    // and the selection describe the CURRENT buffer contents, so a re-init
    // (bridge rebuilt without process restart) must drop them along with
    // the stale line-offset index — the empty-buffer early return in
    // ReceiveContent would otherwise be the only thing papering over it.
    runtime.receive_line_offsets_.assign(1, 0);
    runtime.receive_base_ = 0;
    runtime.receive_sel_anchor_ = kNoSelAnchor;
    runtime.receive_sel_begin_ = 0;
    runtime.receive_sel_end_ = 0;
    runtime.receive_sel_drag_origin_ = 0;
    runtime.receive_sel_drag_hit_ = false;
    runtime.hwnd_ = hwnd;
    runtime.owner_thread_ = GetCurrentThreadId();

    RECT client_rect{};
    GetClientRect(hwnd, &client_rect);
    const UINT width = static_cast<UINT>(std::max<LONG>(1, client_rect.right - client_rect.left));
    const UINT height = static_cast<UINT>(std::max<LONG>(1, client_rect.bottom - client_rect.top));
    DXGI_SWAP_CHAIN_DESC swap_desc{};
    swap_desc.BufferCount = 1;
    swap_desc.BufferDesc.Width = width;
    swap_desc.BufferDesc.Height = height;
    swap_desc.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    swap_desc.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    swap_desc.OutputWindow = hwnd;
    swap_desc.SampleDesc.Count = 1;
    swap_desc.Windowed = TRUE;
    swap_desc.SwapEffect = DXGI_SWAP_EFFECT_DISCARD;
    constexpr D3D_FEATURE_LEVEL feature_levels[] = {
        D3D_FEATURE_LEVEL_11_0, D3D_FEATURE_LEVEL_10_0,
    };
    // Default device policy: HARDWARE (real GPU) first, degrading to the WARP
    // software rasterizer only when no hardware adapter is usable (a GPU-less
    // VM, a remote-desktop session, or a machine whose driver fails D3D11).
    // Rationale — WARP costs ~20-25 ms per presented frame (measured under the
    // receive-line-rate stress: one xcom_imgui::render() is ~25 ms, i.e. well
    // over a core at 10-60 fps), which is the "receiving => CPU high, fps
    // drops" symptom.  A D3D11-capable GPU presents the same frame in well
    // under a millisecond, freeing the core for the receive/UI work that
    // genuinely needs it.  We STILL keep WARP as the fallback so a box without
    // a usable GPU (where Curve/Scope still works off ImPlot over DX) is not
    // left with a blank window — matching the previous all-WARP baseline there.
    // Set XCOM_IMGUI_FORCE_WARP=1 to pin WARP (e.g. shared/remote hosts that
    // must not engage the discrete GPU for plain 2D text).
    //
    // Creation goes into locals so a failed Hardware attempt can never leave
    // runtime.swap_chain_/device_/context_ half-initialised before we retry.
    struct DeviceAttempt {
        IDXGISwapChain* swap_chain = nullptr;
        ID3D11Device* device = nullptr;
        ID3D11DeviceContext* context = nullptr;
    };
    DeviceAttempt attempt{};
    D3D_FEATURE_LEVEL feature_level{};
    const auto create_device = [&](D3D_DRIVER_TYPE driver) -> HRESULT {
        return D3D11CreateDeviceAndSwapChain(
            nullptr, driver, nullptr,
            D3D11_CREATE_DEVICE_SINGLETHREADED |
                D3D11_CREATE_DEVICE_PREVENT_INTERNAL_THREADING_OPTIMIZATIONS,
            feature_levels, static_cast<UINT>(IM_ARRAYSIZE(feature_levels)),
            D3D11_SDK_VERSION, &swap_desc, &attempt.swap_chain, &attempt.device,
            &feature_level, &attempt.context);
    };
    const char* const force_warp = std::getenv("XCOM_IMGUI_FORCE_WARP");
    const bool pin_warp = (force_warp != nullptr) && (std::atoi(force_warp) != 0);
    // D3D11CreateDeviceAndSwapChain may leave output pointers set even on a
    // failed attempt (its null-on-failure contract is not load-bearing across
    // drivers), so reset the locals before every retry — we must never adopt a
    // half-owned device/chain on the WARP fallback.
    bool have_device = false;
    if (!pin_warp) {
        attempt = DeviceAttempt{};
        have_device = SUCCEEDED(create_device(D3D_DRIVER_TYPE_HARDWARE));
    }
    if (!have_device) {
        attempt = DeviceAttempt{};
        have_device = SUCCEEDED(create_device(D3D_DRIVER_TYPE_WARP));
    }
    if (have_device) {
        runtime.swap_chain_ = attempt.swap_chain;
        runtime.device_ = attempt.device;
        runtime.context_ = attempt.context;
    }
    if (!have_device || !create_render_target(runtime)) {
        release_dx_resources(runtime);
        runtime.owner_thread_ = 0;
        return 0;
    }

    IMGUI_CHECKVERSION();
    ImGui::CreateContext();
    ImPlot::CreateContext();   // must pair with DestroyContext in shutdown
    load_layout_config();
    ImGui::StyleColorsLight();
    ImGuiIO& io = ImGui::GetIO();
    // Keep keyboard navigation and the native Win32 clipboard/context menu
    // path enabled for every InputText widget.
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard;
    io.ConfigInputTextCursorBlink = true;
    rebuild_fonts(runtime);
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
    // ---- Warm-up frames (first-second display fix) --------------------------
    // The 1.92 dynamic atlas bakes glyphs lazily: the first NewFrame() kicks
    // off ImFontAtlasUpdateNewFrame() and the DX11 backend creates/uploads the
    // font texture with a frame of latency.  Without warming up, the first
    // visible frames after ShowWindow render with missing glyphs (the "first
    // second looks broken" symptom).  Run two headless NewFrame/Render passes
    // here — no Present, nothing reaches the screen — so the atlas and its
    // textures are fully baked and uploaded before the window is shown.  Two
    // passes because texture creation itself is deferred one frame
    // (RendererHasTextures: create on N, usable on N+1).
    for (int warm = 0; warm < 2; ++warm) {
        ImGui_ImplDX11_NewFrame();
        ImGui_ImplWin32_NewFrame();
        ImGui::NewFrame();
        ImGui::Render();
    }
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
        ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse |
        ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse |
        ImGuiWindowFlags_NoBringToFrontOnFocus;
    if (ImGui::Begin("##xcom_dashboard", nullptr, flags)) {
        const auto& layout = runtime.layout_;
        ui::Header(actions, connected != 0);
        ImGui::SetCursorPosY(layout.header_height);
        ImGui::SetCursorPosX(layout.window_padding);
        // NOTE: deliberately NOT a function-local static — ComboSpec stores
        // the caller's int* pointers, and a rebuilt Lua bridge hands new
        // addresses in; caching would dangle.  Five small stack structs per
        // frame are negligible against that hazard.  Labels and the
        // parity/flow item lists come from the active Lang table (row order
        // matches Lang::serial_field_labels); baud/data/stop items are
        // language-neutral numbers and stay global.
        const Lang& lang = runtime.lang();
        const std::array<ui::ComboSpec, 5> serial_fields{{
            {"##baud", lang.serial_field_labels[0], baud, kBaudItems, static_cast<int>(std::size(kBaudItems))},
            {"##data_bits", lang.serial_field_labels[1], data_bits, kDataItems, static_cast<int>(std::size(kDataItems))},
            {"##stop_bits", lang.serial_field_labels[2], stop_bits, kStopItems, static_cast<int>(std::size(kStopItems))},
            {"##parity", lang.serial_field_labels[3], parity, lang.parity_items, static_cast<int>(std::size(lang.parity_items))},
            {"##flow", lang.serial_field_labels[4], flow, lang.flow_items, static_cast<int>(std::size(lang.flow_items))},
        }};
        const float content_width = ImGui::GetContentRegionAvail().x - layout.window_padding;
        const float compact_sidebar = layout.sidebar_width - 28.0f;
        const float sidebar_width = content_width < layout.compact_threshold
            ? (compact_sidebar > 160.0f ? compact_sidebar : 160.0f)
            : layout.sidebar_width;
        // Reference (pic/2.png) separations: the two columns share the same
        // base colour and are divided by a thin straight gap holding a pair
        // of hairlines — NOT a hard border on the sidebar.  We realise it as an
        // explicit transparent gap column so the lines live in that column's
        // own draw list and aren't overpainted by the two content children.
        const float gap = 6.0f;   // slim separating gap; 1.png relies on hairline + bg contrast, no large trench
        // All three columns get their exact width: monitor grows to the
        // available width (via the negative width idiom), gap and sidebar are
        // fixed.
        if (const auto monitor = ui::Panel(
                "##monitor_column", ImVec2(-(sidebar_width + gap), -kFooterHeight), false,
                ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse); monitor) {
            actions |= ui::ReceiveContent(rx_bytes, tx_bytes, receive_hex, timestamp,
                                          pause_display, auto_clear, auto_clear_bytes,
                                          auto_save);
            // Binding (not a bare temporary) keeps the panel's EndChild in this
            // scope, so the workspace stays open across the section below.
            // Near-white send band per 1.png measurement (#FEFEFE).
            const auto send_workspace = ui::Panel("##send_workspace", ImVec2(0, layout.send_height),
                                                  false, 0, rgb(palette::kSurfaceZone));
            actions |= ui::TransmitContent(send_hex, send_crlf, send_auto, send_period,
                                           send_text, send_capacity, multi_text,
                                           multi_slot_capacity, multi_enabled, multi_hex,
                                           multi_crlf, multi_page, multi_page_count,
                                           multi_auto, multi_period, connected != 0);
        }
        // Inner gap column (transparent child) carrying the single 1px
        // hairline that separates the two panels (1.png: border-free panels
        // divided by one near-invisible #E6E6E6 rule).
        const float col_top = layout.header_height;
        const float col_height = ImGui::GetIO().DisplaySize.y - kFooterHeight - col_top;
        ImGui::SameLine(0.0f, 0.0f);
        {
            ImGui::PushStyleColor(ImGuiCol_ChildBg, IM_COL32(0, 0, 0, 0));
            const auto gap_col = ImGui::BeginChild("##col_gap", ImVec2(gap, col_height), false,
                                                   ImGuiWindowFlags_NoScrollbar | ImGuiWindowFlags_NoScrollWithMouse);
            if (gap_col) {
                ImDrawList* const dl = ImGui::GetWindowDrawList();
                const ImVec2 ori = ImGui::GetWindowPos();
                dl->AddLine(ImVec2(ori.x + gap * 0.5f, ori.y),
                            ImVec2(ori.x + gap * 0.5f, ori.y + col_height),
                            ImGui::GetColorU32(rgb(palette::kRule)), 1.0f);
            }
            ImGui::EndChild();
            ImGui::PopStyleColor();
        }
        ImGui::SameLine(0.0f, 0.0f);
        {
            // Border-free sidebar at a fixed width on the same base surface.
            // The stacked sections (port + serial + receive) do not always fit
            // the column height (e.g. 920x650 leaves ~0 px of slack), and a
            // plain child let the last toggle row slide under the footer band
            // drawn below it (the red-boxed overlap).  Give the sidebar an
            // explicit scrolling region so overflowing content scrolls instead
            // of painting past the column's bottom edge.
            {
                const auto serial_column = ui::Panel(
                    "##serial_column", ImVec2(sidebar_width, -kFooterHeight), false,
                    ImGuiWindowFlags_None, rgb(palette::kSurfaceSidebar));
                (void)serial_column;
                actions |= ui::ConnectionContent(
                    port, port_capacity, connected != 0,
                    baud, data_bits, stop_bits, parity, flow,
                    dtr, rts, serial_fields,
                    rx_bytes, tx_bytes, receive_hex, timestamp,
                    pause_display, auto_clear, auto_clear_bytes,
                    auto_save);
            }
        }
        ImGui::SetCursorPosY(ImGui::GetIO().DisplaySize.y - kFooterHeight);
        ImGui::SetCursorPosX(0.0f);
        ui::Footer(connected != 0, rx_bytes, tx_bytes);
    }
    ImGui::End();
    // Floating windows render AFTER the dashboard so they layer on top; a
    // second Begin in the same frame is standard ImGui (see the official
    // example's "Another Window").  Both the header "Lua" button and the
    // console's own title-bar X report ActionToggleScripts; the C++ state was
    // already flipped at the source, so Lua only mirrors it.
    actions |= ui::ScriptConsoleContent();
    actions |= ui::ScopeContent();
    actions |= ui::SettingsContent();
    // Lua plugin pages render as independent floating windows ON TOP of the
    // Settings window, so the toggles that re-open them stay reachable.
    actions |= ui::PluginWindowsContent();
    // The accumulated action mask is the C ABI return value — returned to the
    // Lua caller verbatim (single consumer; no observer indirection needed).
    return actions;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_receive_window(
    size_t bytes) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return;
    // Clamp to the same range the Lua side enforces (RECEIVE_WINDOW_MIN/MAX
    // in imgui_bridge.lua): below 16 KiB the log viewport starves, above
    // 1 MiB the per-change line-offset rescan outgrows the WARP frame budget.
    constexpr size_t kWindowMin = 16U * 1024U;
    constexpr size_t kWindowMax = 1024U * 1024U;
    if (bytes < kWindowMin) bytes = kWindowMin;
    if (bytes > kWindowMax) bytes = kWindowMax;
    runtime.receive_limit_ = bytes - 1U;
    // Shrink an over-long tail immediately so the new bound is observable
    // without waiting for the next set_receive_text.  The retained suffix is
    // a suffix of the old text, so the old line offsets stay valid after
    // subtracting the erased prefix length — no rescan needed.
    if (runtime.receive_text_.size() > runtime.receive_limit_) {
        const std::size_t erase_n =
            runtime.receive_text_.size() - runtime.receive_limit_;
        runtime.receive_text_.erase(0, erase_n);
        // Same lifetime-counter bookkeeping as set_receive_text: the window
        // head moved forward, keep the absolute selection consistent with it.
        // NOTE: receive_base_ is authoritative-from-Lua (set_receive_text is
        // always preceded by xcom_imgui_set_receive_base), so this bump only
        // keeps the interim frame coherent until the next Lua push.
        runtime.receive_base_ += erase_n;
        std::vector<std::size_t>& offsets = runtime.receive_line_offsets_;
        offsets.erase(offsets.begin(),
                      std::lower_bound(offsets.begin(), offsets.end(), erase_n));
        for (std::size_t& off : offsets) off -= erase_n;
        if (offsets.empty() || offsets.front() != 0U) {
            offsets.insert(offsets.begin(), 0U);
        }
    }
}

extern "C" __declspec(dllexport) void xcom_imgui_set_receive_text(
    const char* text, size_t length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return;
    if (!text || length == 0) {
        runtime.receive_text_.clear();
        runtime.receive_line_offsets_.assign(1, 0);
        runtime.receive_follow_tail_ = true;
        runtime.receive_scroll_y_ = 0.0f;
        runtime.receive_base_ = 0;
        runtime.receive_sel_anchor_ = kNoSelAnchor;
        runtime.receive_sel_begin_ = 0;
        runtime.receive_sel_end_ = 0;
        runtime.receive_sel_drag_hit_ = false;
        return;
    }
    const size_t bounded_length = (std::min)(length, runtime.receive_limit_);
    // receive_base_ (the absolute offset of receive_text_[0]) is owned by
    // Lua: the bridge pushes a sliding tail window and reports, through
    // xcom_imgui_set_receive_base just before every push, where that window
    // sits in the lifetime stream.  The selection lives in the same absolute
    // coordinates, so it travels WITH its text as the window slides instead
    // of staying pinned at fixed rows over new content.  A plain set with no
    // base update keeps the previous mapping (older DLL/Lua pairs simply
    // keep base 0: the historical window-relative behaviour).
    runtime.receive_text_.assign(text, bounded_length);
    // Rescan line starts once per text change (O(n) over the receive tail) so
    // the per-frame clipper render indexes lines without re-walking the text.
    //
    // Hot-path notes (this runs on every receive flush, up to ~100x/s at full
    // bandwidth): memchr jumps between newlines with the CRT's SIMD scan
    // instead of a per-byte loop, and one reserve up front removes the ~11
    // geometric reallocations a 64 KiB tail (~2k lines) would otherwise pay
    // per call.  The 1-line worst case still costs only the reserve check.
    std::vector<std::size_t>& offsets = runtime.receive_line_offsets_;
    offsets.clear();
    offsets.reserve(bounded_length / 32U + 2U);
    offsets.push_back(0);
    const char* const data = runtime.receive_text_.data();
    const char* scan = data;
    const char* const data_end = data + bounded_length;
    while (const char* const nl = static_cast<const char*>(
               std::memchr(scan, '\n', static_cast<size_t>(data_end - scan)))) {
        offsets.push_back(static_cast<std::size_t>(nl - data) + 1U);
        scan = nl + 1;
    }
    // Lone '\r' line breaks (classic Mac / some devices) never survive the
    // core's CRLF normalisation, so the historical '\r' branch is dropped:
    // the text view only ever receives '\n' terminated lines now.
}

// Incremental append: add `delta` (a fresh receive batch) to the tail and
// extend the line-offset index only over the newly appended bytes, then drop
// an over-long prefix.  This is the zero-copy/low-churn counterpart to
// xcom_imgui_set_receive_text: Lua pushes each drained batch ONCE and never
// rebuilds or re-scans the whole tail, so a steady stream costs O(delta) per
// push instead of O(window) per flush.  receive_base_ (the absolute offset of
// receive_text_[0]) is advanced by the trimmed prefix so the Lua-owned
// absolute selection keeps tracking its text across slides.
extern "C" __declspec(dllexport) void xcom_imgui_receive_append(
    const char* delta, size_t length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return;
    if (!delta || length == 0) return;

    std::string& text = runtime.receive_text_;
    std::vector<std::size_t>& offsets = runtime.receive_line_offsets_;

    // Offset-index invariant (shared by ALL mutation paths: set_receive_text,
    // set_receive_window trim, this append): front()==0, every entry is a
    // line start, and the LAST entry is the start of the possibly-partial
    // final line == would equal text.size() when the tail ends at '\n'.
    // Therefore appending only creates new entries for '\n' inside the delta
    // and the scan starts exactly at the old size -- no boundary seeding.
    const std::size_t scan_from = text.size();
    text.append(delta, length);
    // Reserve up front so the ~dozen pushes for a 64 KiB batch never pay a
    // geometric realloc of the whole index vector.
    offsets.reserve(offsets.size() + length / 32U + 2U);
    const char* const data = text.data();
    const char* scan = data + scan_from;
    const char* const data_end = data + text.size();
    while (const char* const nl = static_cast<const char*>(
               std::memchr(scan, '\n', static_cast<size_t>(data_end - scan)))) {
        offsets.push_back(static_cast<std::size_t>(nl - data) + 1U);
        scan = nl + 1;
    }

    // Prefix-trim to the window limit, mirroring xcom_imgui_set_receive_window
    // (retained-suffix offsets stay valid after subtracting the erased length,
    // so the index is shifted, never rebuilt).  receive_base_ advances with
    // the window head so the absolute selection keeps tracking its text.
    // follow_tail_ is deliberately untouched: scrolling to the bottom stays a
    // render-time decision (was_at_bottom), so incoming data never yanks a
    // user who is reading history.
    // INVARIANT: while a drag selection is in progress (anchor == kSelDragging)
    // the trim is DEFERRED, so every absolute selection byte keeps the same
    // window offset for the whole drag -- otherwise a heavy stream would erase
    // the prefix, advance receive_base_ and slide the selected text out from
    // under the held cursor.  The deferred trim is performed by the render loop
    // on the frame the left button is observed released (ReceiveContent), which
    // restores text.size() <= receive_limit_ after every drag.
    if (text.size() > runtime.receive_limit_ &&
        runtime.receive_sel_anchor_ != kSelDragging) {
        const std::size_t erase_n = text.size() - runtime.receive_limit_;
        text.erase(0, erase_n);
        runtime.receive_base_ += erase_n;
        offsets.erase(offsets.begin(),
                      std::lower_bound(offsets.begin(), offsets.end(), erase_n));
        for (std::size_t& off : offsets) off -= erase_n;
        if (offsets.empty() || offsets.front() != 0U) {
            offsets.insert(offsets.begin(), 0U);
        }
    }
}

// Copy the current tail into `out` (up to `capacity` bytes, NUL-terminated)
// and report its absolute base + length.  Lets Lua read back the native view
// for the rare "Save visible" path without keeping a shadow copy per batch.
extern "C" __declspec(dllexport) size_t xcom_imgui_get_receive_text(
    char* out, size_t capacity, size_t* base_out) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return 0;
    const std::size_t n = runtime.receive_text_.size();
    if (base_out) *base_out = runtime.receive_base_;
    if (out && capacity > 0) {
        const std::size_t copy = (std::min)(n, capacity - 1U);
        std::memcpy(out, runtime.receive_text_.data(), copy);
        out[copy] = '\0';
        return copy;
    }
    return n;
}

// Publish where the current receive window sits in the lifetime stream.
// Lua owns the sliding tail (it concatenates/retires chunks in
// Window:_flush_imgui_receive), so only it can say how many bytes precede
// receive_text_[0]; it calls this right before every set_receive_text.
// The selection state is stored in these same absolute coordinates, which
// is what lets a shaded range travel with its text instead of staying
// pinned over new arrivals (see receive_base_).
extern "C" __declspec(dllexport) void xcom_imgui_set_receive_base(
    size_t absolute_offset) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return;
    runtime.receive_base_ = absolute_offset;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_status(const char* text) {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || GetCurrentThreadId() != runtime.owner_thread_) return;
    constexpr std::size_t kStatusLimit = 160U;
    // Null-safe: an empty view's data() may be null, and assign(nullptr, 0)
    // is undefined; short-circuit instead of clamping a null pointer.
    if (text == nullptr || text[0] == '\0') {
        // Clearing never needs a rebuild: the legacy glyphs stay baked (a
        // slightly over-full atlas only costs atlas space, never correctness),
        // and the next non-empty status takes the missing-glyph path below.
        runtime.status_text_.clear();
        return;
    }
    const std::string_view value(text);
    std::string next(value.data(),
                     value.size() < kStatusLimit ? value.size() : kStatusLimit);
    if (next == runtime.status_text_) return;   // no change: no font churn
    runtime.status_text_ = std::move(next);
    // The line is drawn in the footer (see Footer()) and may contain Chinese
    // from Lua, so its glyphs must exist in the baked atlas. Status strings
    // appear at runtime, long after the first bake, so defer a rebuild to the
    // top of the next frame — the same safe point the script-@name and
    // mono-CJK paths use.
    //
    // rebuild_fonts() re-bakes the whole atlas and is far too expensive to run
    // on every status change (the reconnect countdown rewrites this string
    // every second, the data-loss banner every 250 ms). Decode the UTF-8 and
    // ask the body faces whether they already cover every code point; only a
    // genuinely new glyph — a Chinese cause string appearing for the first
    // time in this session — schedules the rebuild. All three body sizes are
    // checked because the settings panel can switch the active face after the
    // glyphs were first baked.
    if (runtime.body_fonts_[1] != nullptr) {
        bool missing = false;
        for (std::size_t i = 0; i < runtime.status_text_.size() && !missing;) {
            const unsigned char lead =
                static_cast<unsigned char>(runtime.status_text_[i]);
            std::uint32_t cp = lead;
            std::size_t len = 1U;
            if (lead >= 0xF0U) { cp = lead & 0x07U; len = 4U; }
            else if (lead >= 0xE0U) { cp = lead & 0x0FU; len = 3U; }
            else if (lead >= 0xC0U) { cp = lead & 0x1FU; len = 2U; }
            if (i + len > runtime.status_text_.size()) break;   // truncated tail
            for (std::size_t k = 1U; k < len; ++k) {
                cp = (cp << 6U) |
                     (static_cast<unsigned char>(runtime.status_text_[i + k]) & 0x3FU);
            }
            i += len;
            if (cp < 0x80U) continue;   // ASCII is always baked
            for (ImFont* const body : runtime.body_fonts_) {
                if (body != nullptr &&
                    !body->IsGlyphInFont(static_cast<ImWchar>(cp))) {
                    missing = true;
                    break;
                }
            }
        }
        if (missing) {
            runtime.font_rebuild_pending_ = true;
        }
    } else {
        // Pre-bake: nothing is loaded yet, so the initial bake (which also
        // registers status_text_) will pick the glyphs up.
        runtime.font_rebuild_pending_ = true;
    }
}

extern "C" __declspec(dllexport) int xcom_imgui_new_frame() {
    auto& runtime = ImGuiRuntime::instance();
    if (!runtime.initialized_ || runtime.frame_active_ || GetCurrentThreadId() != runtime.owner_thread_ ||
        !IsWindow(runtime.hwnd_) || !runtime.device_ || !runtime.context_) return 0;
    // Deferred font rebuild (mono-CJK toggle).  Must run here, before
    // DX11_NewFrame schedules the lazy atlas bake: the previous frame is
    // presented (frame_active_ == false), no window is mid-Begin, and no
    // draw-list holds a font — so ClearFonts()/AddFont() are safe.
    if (runtime.font_rebuild_pending_) {
        runtime.font_rebuild_pending_ = false;
        rebuild_fonts(runtime);
    }
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
    // Present immediately during interactive resize. Waiting for a vblank
    // leaves the previous frame visible while Windows is in its modal sizing
    // loop, which looks like a stretched/ghosted dashboard.
    runtime.swap_chain_->Present(0, 0);
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
            InvalidateRect(hwnd, nullptr, FALSE);
        }
    }
    if (msg == WM_EXITSIZEMOVE) InvalidateRect(hwnd, nullptr, FALSE);
    // ImGui's handler returns an LRESULT; the C ABI collapses it to a handled
    // boolean so the caller never sees a pointer-sized value for a true/false.
    return ImGui_ImplWin32_WndProcHandler(hwnd, msg, wparam, lparam) ? 1 : 0;
}

extern "C" __declspec(dllexport) void xcom_imgui_shutdown() {
    shutdown_impl();
}

// ---------------------------------------------------------------------------
// Phase 4 feature-extension exports.  Every setter is idempotent and may be
// called before the first draw; the draw path treats a null pointer as
// "feature not registered" and hides the widget.  All follow the established
// guard (initialized + owner thread) of the existing exports.
// ---------------------------------------------------------------------------

namespace {
bool extension_ready(ImGuiRuntime& runtime) {
    return runtime.initialized_ && GetCurrentThreadId() == runtime.owner_thread_;
}
}  // namespace

extern "C" __declspec(dllexport) void xcom_imgui_set_baud_extra(int* custom_baud) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.baud_custom_ = custom_baud;
}

// Open-time modem-line tri-state (XCOM_LINE_*: 0 deassert / 1 assert /
// 2 leave alone).  The two Lua-owned int buffers are edited in place by the
// serial-grid combos; Lua reads them back through imgui_bridge.serial_config
// and forwards them to XcomPortConfig.dtr_enable/rts_enable at open.  Range is
// not policed here: the C ABI (xcom_abi.cpp queue_open) rejects anything above
// XCOM_LINE_LEAVE_ALONE, and the Lua side normalises the combo index first.
extern "C" __declspec(dllexport) void xcom_imgui_set_open_lines(
    int* dtr_open, int* rts_open) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.dtr_open_ = dtr_open;
    runtime.rts_open_ = rts_open;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_multi_extra(int* gap_ms) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.multi_gap_ = gap_ms;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_charset(int* index) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.charset_ = index;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_frame_gap(int* enabled, int* ms) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.frame_gap_en_ = enabled;
    runtime.frame_gap_ms_ = ms;
}

// ---- receive copy path -----------------------------------------------------
// Register the Lua-owned "copy without timestamps" toggle.  The receive
// context menu reads/flips it in place; the Lua side persists it ([display]
// strip_timestamp_on_copy) and applies it when it services a copy.
extern "C" __declspec(dllexport) void xcom_imgui_set_copy_strip(int* enabled) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.copy_strip_ts_ = enabled;
}

// Hand the pending receive-copy request to Lua and clear it.  Ctrl+C / the
// context menu queue the bytes in QueueReceiveCopy instead of writing the
// clipboard, so the Lua bridge can strip timestamps first.  Returns the number
// of bytes copied into `out` (NUL-terminated), or 0 when nothing is pending.
// The caller sizes `out` to the receive window, so a request always fits; a
// smaller buffer truncates.
extern "C" __declspec(dllexport) size_t xcom_imgui_take_receive_copy(
    char* out, size_t capacity) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime) || !out || capacity == 0) return 0;
    const std::string& pending = runtime.receive_copy_pending_;
    if (pending.empty()) return 0;
    const std::size_t copy = (std::min)(pending.size(), capacity - 1U);
    std::memcpy(out, pending.data(), copy);
    out[copy] = '\0';
    // Release the request even when the caller's buffer was too small: a
    // truncated copy is still the copy the user asked for, and holding it
    // would re-copy stale bytes on the next frame.
    runtime.receive_copy_pending_.clear();
    return copy;
}

// Write text the Lua bridge has already transformed (timestamp-stripped or
// raw) to the OS clipboard.  ImGui's platform backend owns the actual
// clipboard call, so no raw Win32 clipboard code is needed here.
extern "C" __declspec(dllexport) void xcom_imgui_set_clipboard_text(
    const char* text, size_t length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    const std::string value(text ? text : "", text ? length : 0);
    ImGui::SetClipboardText(value.c_str());
}

// packed = "pattern\0RRGGBB\0style\0" repeated `count` times (style: "text"
// or "bg").  count == 0 clears.  Colors arrive as RRGGBB hex text and are
// repacked to ImU32 ABGR with full alpha (bg rules render with 0.35 alpha at
// draw time through a dedicated packed constant — the rule color itself
// stays opaque so text rules read at full strength).
extern "C" __declspec(dllexport) void xcom_imgui_set_highlight_rules(
    const char* packed, int count) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.highlight_rules_.clear();
    if (!packed || count <= 0) return;
    if (count > 32) count = 32;  // shared cap with the Lua engine
    const char* cursor = packed;
    for (int index = 0; index < count; ++index) {
        ImGuiRuntime::HighlightRule rule;
        rule.pattern = cursor;
        cursor += rule.pattern.size() + 1;
        // Parse RRGGBB hex.
        std::uint32_t rgb_value = 0;
        for (int digit = 0; digit < 6 && *cursor != '\0'; ++digit, ++cursor) {
            const char c = *cursor;
            std::uint32_t nibble;
            if (c >= '0' && c <= '9') nibble = static_cast<std::uint32_t>(c - '0');
            else if (c >= 'A' && c <= 'F') nibble = static_cast<std::uint32_t>(c - 'A' + 10);
            else if (c >= 'a' && c <= 'f') nibble = static_cast<std::uint32_t>(c - 'a' + 10);
            else break;
            rgb_value = (rgb_value << 4) | nibble;
        }
        while (*cursor != '\0') ++cursor;  // skip any overflow digits
        ++cursor;                           // past the NUL
        const std::string_view style(cursor);
        cursor += style.size() + 1;
        rule.background = style == "bg";
        // RRGGBB -> ImU32 ABGR (ImGui's byte order).
        const std::uint32_t r = (rgb_value >> 16) & 0xFF;
        const std::uint32_t g = (rgb_value >> 8) & 0xFF;
        const std::uint32_t b = rgb_value & 0xFF;
        if (rule.background) {
            // Background rules draw with 0.35 alpha for a marker look.
            rule.color = IM_COL32(r, g, b, 90);
        } else {
            rule.color = IM_COL32(r, g, b, 255);
        }
        runtime.highlight_rules_.push_back(std::move(rule));
    }
}

// names_packed = "name1\0name2\0..."; enabled is a Lua-owned int[count] the
// console checkboxes write in place (Lua reads them directly — no event).
extern "C" __declspec(dllexport) void xcom_imgui_set_scripts(
    const char* names_packed, int* enabled, int count) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.script_names_.clear();
    runtime.script_labels_.clear();   // labels are index-aligned with names
    runtime.script_descs_.clear();    // tooltips too: never keep a stale map
    if (!names_packed || count <= 0) {
        runtime.script_enabled_ = nullptr;
        return;
    }
    const char* cursor = names_packed;
    for (int index = 0; index < count; ++index) {
        runtime.script_names_.emplace_back(cursor);
        cursor += runtime.script_names_.back().size() + 1;
    }
    runtime.script_enabled_ = enabled;
}

// Display labels for the script list ("label1\0label2\0..."), index-aligned
// with the names handed to xcom_imgui_set_scripts.  A separate export so the
// set_scripts ABI / index-key contract is untouched; Lua sends the same count
// and order.  The font glyphs for these strings are registered in
// rebuild_fonts() — without that a Chinese @name would render as tofu.
extern "C" __declspec(dllexport) void xcom_imgui_set_script_labels(
    const char* labels_packed) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    std::vector<std::string> next;
    if (labels_packed) {
        const char* cursor = labels_packed;
        // Walk the NUL-separated list; the empty trailing token after the last
        // separator terminates it.
        while (*cursor != '\0' &&
               next.size() < runtime.script_names_.size()) {
            next.emplace_back(cursor);
            cursor += next.back().size() + 1;
        }
    }
    // A label vector shorter than the name list (Lua sent fewer) is discarded
    // wholesale: a partial mapping would mislabel rows.
    if (!next.empty() && next.size() != runtime.script_names_.size()) {
        next.clear();
    }
    if (next == runtime.script_labels_) return;   // no change: no font churn
    runtime.script_labels_ = std::move(next);
    // Glyphs are baked in rebuild_fonts() from these strings.  When the app is
    // already running a label can appear/change after the last bake (a script
    // was enabled or its @name edited), so defer a rebuild to the top of the
    // next frame — same safe point the mono-CJK toggle uses.  At init the
    // initial bake has not happened yet, so no rebuild is needed (and asking
    // for one here would run before the DX11 device exists).
    if (runtime.initialized_) {
        runtime.font_rebuild_pending_ = true;
    }
}

// Hover tooltips for the script list ("desc1\0desc2\0..."), the tooltip
// companion to script_labels() and index-aligned with the same names.  Like
// labels, a separate export keeps the set_scripts ABI untouched.  Unlike
// labels, `count` is passed explicitly: a script with neither @desc nor @name
// has an EMPTY tooltip, and the label parser (which stops at the first empty
// token) would truncate the list at that point and misalign every later row.
// The count is what guarantees index alignment; a count that disagrees with the
// current name list is discarded wholesale rather than applied partially.
extern "C" __declspec(dllexport) void xcom_imgui_set_script_descs(
    const char* descs_packed, int count) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    std::vector<std::string> next;
    if (descs_packed && count > 0 &&
        count == static_cast<int>(runtime.script_names_.size())) {
        const char* cursor = descs_packed;
        for (int index = 0; index < count; ++index) {
            next.emplace_back(cursor);
            cursor += next.back().size() + 1;
        }
    }
    if (next == runtime.script_descs_) return;   // no change: no font churn
    runtime.script_descs_ = std::move(next);
    // Same deferred-rebuild contract as labels: a @desc can appear/change after
    // the last bake, so register the glyphs at the top of the next frame.
    if (runtime.initialized_) {
        runtime.font_rebuild_pending_ = true;
    }
}
// ring only when dirty).  Line offsets are rebuilt with the same memchr scan
// as the receive text.
extern "C" __declspec(dllexport) void xcom_imgui_set_script_log(
    const char* text, size_t length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    if (!text || length == 0) {
        runtime.script_log_.clear();
        runtime.script_log_lines_.assign(1, 0);
        return;
    }
    constexpr std::size_t kLogLimit = 128U * 1024U;
    if (length > kLogLimit) {
        text += length - kLogLimit;
        length = kLogLimit;
    }
    runtime.script_log_.assign(text, length);
    std::vector<std::size_t>& offsets = runtime.script_log_lines_;
    offsets.clear();
    offsets.reserve(length / 48U + 2U);
    offsets.push_back(0);
    const char* const data = runtime.script_log_.data();
    const char* scan = data;
    const char* const data_end = data + length;
    while (const char* const nl = static_cast<const char*>(
               std::memchr(scan, '\n', static_cast<size_t>(data_end - scan)))) {
        offsets.push_back(static_cast<std::size_t>(nl - data) + 1U);
        scan = nl + 1;
    }
}

extern "C" __declspec(dllexport) void xcom_imgui_set_scripts_visible(int visible) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.scripts_visible_ = visible != 0;
}

extern "C" __declspec(dllexport) int xcom_imgui_take_script_events(
    int* events, int capacity) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime) || !events || capacity <= 0) return 0;
    const int moved = static_cast<int>(
        runtime.script_events_.size() < static_cast<size_t>(capacity)
            ? runtime.script_events_.size()
            : static_cast<size_t>(capacity));
    for (int index = 0; index < moved; ++index) {
        events[index] = runtime.script_events_[static_cast<size_t>(index)];
    }
    runtime.script_events_.erase(
        runtime.script_events_.begin(),
        runtime.script_events_.begin() + moved);
    return moved;
}

extern "C" __declspec(dllexport) int xcom_imgui_script_take_command(
    char* out, int capacity) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime) || !out || capacity <= 0) return 0;
    if (!runtime.script_command_ready_) return 0;
    runtime.script_command_ready_ = false;
    const int length = static_cast<int>(strnlen(runtime.script_command_,
                                                sizeof(runtime.script_command_)));
    const int copied = length < capacity ? length : capacity - 1;
    memcpy(out, runtime.script_command_, static_cast<size_t>(copied));
    out[copied] = '\0';
    runtime.script_command_[0] = '\0';
    return 1;
}

// Editor content: Lua pushes the file text when a script is selected.
extern "C" __declspec(dllexport) void xcom_imgui_script_load_editor(
    const char* path, const char* text, size_t length) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.script_edit_path_.assign(path ? path : "");
    runtime.script_edit_buf_.assign(text ? text : "", text ? length : 0);
    if (runtime.script_edit_buf_.empty() ||
        runtime.script_edit_buf_.back() != '\0') {
        runtime.script_edit_buf_.push_back('\0');
    }
    runtime.script_edit_dirty_ = false;
}

// Select which script the editor shows (index into script_names_; -1 empty).
extern "C" __declspec(dllexport) void xcom_imgui_script_select(int index) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.script_edit_index_ = index;
    if (index < 0) {
        runtime.script_edit_path_.clear();
        runtime.script_edit_buf_.assign(1, '\0');
        runtime.script_edit_dirty_ = false;
    }
}

// Returns 1 and copies the editor text when the user pressed Ctrl+S since
// the last call (save event); 0 otherwise.  The path is returned through
// out_path (the file the editor has loaded).
extern "C" __declspec(dllexport) int xcom_imgui_script_take_editor_save(
    char* out_path, int path_capacity, char* out_text, int text_capacity) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime) || !out_path || !out_text ||
        path_capacity <= 0 || text_capacity <= 0) return 0;
    // The save event is delivered as ScriptEvent::Edit with the 0x40 flag.
    for (size_t index = 0; index < runtime.script_events_.size(); ++index) {
        const int event = runtime.script_events_[index];
        if ((event >> 8) == static_cast<int>(ScriptEvent::Edit) &&
            (event & 0x40) != 0) {
            runtime.script_events_.erase(
                runtime.script_events_.begin() +
                static_cast<std::ptrdiff_t>(index));
            const int path_len = static_cast<int>(
                runtime.script_edit_path_.size());
            const int path_copied = path_len < path_capacity
                ? path_len : path_capacity - 1;
            memcpy(out_path, runtime.script_edit_path_.c_str(),
                   static_cast<size_t>(path_copied));
            out_path[path_copied] = '\0';
            const int text_len = static_cast<int>(
                runtime.script_edit_buf_.size());
            const int text_copied = text_len < text_capacity
                ? text_len : text_capacity - 1;
            memcpy(out_text, runtime.script_edit_buf_.c_str(),
                   static_cast<size_t>(text_copied));
            out_text[text_copied] = '\0';
            runtime.script_edit_dirty_ = false;
            return 1;
        }
    }
    return 0;
}

// ---------------------------------------------------------------------------
// ImPlot oscilloscope data channel (Lua -> C++).  x is seconds (Lua supplies
// uv.now()/1000.0 — never accumulated DeltaTime: passive 16-100 ms frames
// under-sample); y is the sample value.  channel is 1-based (script-facing).
// ---------------------------------------------------------------------------

extern "C" __declspec(dllexport) int xcom_imgui_scope_push(
    int channel, double x, double y) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return 0;
    const int index = channel - 1;
    if (index < 0 || index >= kScopeChannelsMax) return 0;
    auto& scope = runtime.scope_[index];
    const int slot = (scope.offset + scope.count) % kScopePointsMax;
    scope.xs[slot] = static_cast<float>(x);
    scope.ys[slot] = static_cast<float>(y);
    if (scope.count < kScopePointsMax) {
        ++scope.count;
    } else {
        scope.offset = (scope.offset + 1) % kScopePointsMax;
    }
    runtime.scope_has_data_ = true;
    if (x > runtime.scope_last_x_) runtime.scope_last_x_ = x;
    return 1;
}

extern "C" __declspec(dllexport) void xcom_imgui_scope_clear(void) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    for (auto& channel : runtime.scope_) {
        channel.offset = 0;
        channel.count = 0;
    }
    runtime.scope_has_data_ = false;
    runtime.scope_last_x_ = 0.0;
}

extern "C" __declspec(dllexport) void xcom_imgui_scope_configure(
    int channel, int visible) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    const int index = channel - 1;
    if (index >= 0 && index < kScopeChannelsMax) {
        runtime.scope_[index].visible = visible != 0;
    }
}

extern "C" __declspec(dllexport) void xcom_imgui_scope_set_visible(int visible) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.scope_visible_ = visible != 0;
}

// ---------------------------------------------------------------------------
// Settings window + Lua plugin pages.  set_plugin_page upserts by id: an empty
// spec removes the page.  take_plugin_events copies the queued events as
// NUL-separated "page:kind:wid[:value]" records and returns the byte count
// (0 = idle); a full buffer keeps the events for the next drain.
// ---------------------------------------------------------------------------

extern "C" __declspec(dllexport) void xcom_imgui_set_settings_visible(int visible) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    runtime.settings_visible_ = visible != 0;
}

extern "C" __declspec(dllexport) void xcom_imgui_set_plugin_page(
    const char* id, const char* title, const char* spec) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime)) return;
    if (!id || '\0' == id[0]) return;
    const std::string page_id{id};
    for (auto& page : runtime.plugin_pages_) {
        if (page.id == page_id) {
            if (!spec || '\0' == spec[0]) {
                runtime.plugin_pages_.erase(
                    runtime.plugin_pages_.begin() +
                    (&page - runtime.plugin_pages_.data()));
            } else {
                page.title = title ? title : page_id;
                page.spec = spec;
                page.values_ready_ = false;   // defaults follow the new spec
                std::fill(page.values_,
                          page.values_ + ImGuiRuntime::PluginPage::kWidgetsMax, 0.0);
            }
            return;
        }
    }
    if (!spec || '\0' == spec[0]) return;   // removing an unknown page: no-op
    ImGuiRuntime::PluginPage page;
    page.id = page_id;
    page.title = title ? title : page_id;
    page.spec = spec;
    runtime.plugin_pages_.push_back(std::move(page));
}

extern "C" __declspec(dllexport) int xcom_imgui_take_plugin_events(
    char* out, int capacity) {
    auto& runtime = ImGuiRuntime::instance();
    if (!extension_ready(runtime) || !out || capacity <= 0) return 0;
    int written = 0;
    size_t consumed = 0;
    for (const std::string& event : runtime.plugin_events_) {
        const int need = static_cast<int>(event.size()) + 1;   // + NUL
        if (written + need > capacity) {
            break;
        }
        memcpy(out + written, event.c_str(), event.size() + 1);
        written += need;
        ++consumed;
    }
    runtime.plugin_events_.erase(runtime.plugin_events_.begin(),
                                 runtime.plugin_events_.begin() +
                                     static_cast<std::ptrdiff_t>(consumed));
    return written;
}
