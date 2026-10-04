// receive_selection_test.cpp - double-click word boundaries for the receive log.
//
// The bridge's drag-select cannot be driven headlessly (it needs a live ImGui
// frame and a DX11 device), so the boundary RULES are kept in a pure header
// (xcom_lua/native/xcom_imgui/receive_selection.hpp) and pinned here.  What
// this suite is really defending:
//   * a CJK glyph is 3 bytes -- selecting one byte, or splitting one, would
//     put an invalid UTF-8 fragment on the clipboard (a GB2312 log converted to
//     UTF-8 is the ordinary case for this tool, not an exotic one);
//   * an ASCII identifier run is selected whole, but the separators around it
//     are NOT swallowed;
//   * every offset in [0, length] answers with an in-range, non-empty range, so
//     a click can never produce a zero-length (invisible) selection or read
//     past the row.
//
// Runs on a Linux host:   g++ -std=c++17 receive_selection_test.cpp
// SPDX-License-Identifier: MIT
#include <cstdio>
#include <cstring>
#include <string>

#include "receive_selection.hpp"

using xcom::imgui::selection::Range;
using xcom::imgui::selection::word_bounds;

static int failures = 0;
static int checks = 0;

static void check(bool condition, const char* what) {
    ++checks;
    if (!condition) {
        ++failures;
        std::printf("FAIL  %s\n", what);
    }
}

static void expect_range(const char* line, std::size_t offset,
                         std::size_t want_begin, std::size_t want_end,
                         const char* what) {
    const std::size_t length = std::strlen(line);
    const Range range = word_bounds(line, length, offset);
    const bool ok = range.begin == want_begin && range.end == want_end;
    ++checks;
    if (!ok) {
        ++failures;
        std::printf("FAIL  %s (offset=%zu got=[%zu,%zu) want=[%zu,%zu) text=\"%.*s\")\n",
                    what, offset, range.begin, range.end, want_begin, want_end,
                    static_cast<int>(range.end - range.begin), line + range.begin);
    }
}

int main()
{
    // (1) ASCII identifier run, probed from inside and from both edges.
    const char* token = "rx 0x1A2B timeout";
    expect_range(token, 4, 3, 9, "hex payload selected whole");
    expect_range(token, 3, 3, 9, "first byte of the run selects the run");
    expect_range(token, 8, 3, 9, "last byte of the run selects the run");
    expect_range(token, 2, 2, 3, "the space before it selects only itself");
    expect_range(token, 10, 10, 17, "the following word is its own run");

    // (2) Underscore and digits are word bytes; punctuation is not.
    expect_range("a_b-12", 0, 0, 3, "underscore joins the run");
    expect_range("a_b-12", 3, 3, 4, "the hyphen is its own selection");
    expect_range("a_b-12", 4, 4, 6, "digits after the hyphen are a run");

    // (3) CJK: the WHOLE 3-byte sequence, never a byte of it.  "温度" is
    // 6 bytes in UTF-8; a probe on any of them must return the same range.
    const std::string cjk = "\xE6\xB8\xA9\xE5\xBA\xA6=25";
    const std::size_t cjk_len = cjk.size();
    check(cjk_len == 9, "fixture is 6 bytes of CJK plus 3 ASCII");
    for (std::size_t offset = 0U; offset < 3U; ++offset) {
        const Range range = word_bounds(cjk.data(), cjk_len, offset);
        check(range.begin == 0U && range.end == 3U,
              "first glyph: every byte inside it selects all 3");
    }
    for (std::size_t offset = 3U; offset < 6U; ++offset) {
        const Range range = word_bounds(cjk.data(), cjk_len, offset);
        check(range.begin == 3U && range.end == 6U,
              "second glyph: every byte inside it selects all 3");
    }
    expect_range(cjk.c_str(), 6, 6, 7, "the '=' after the glyphs stands alone");

    // (4) A 2-byte sequence (Latin-1 accented letter) is selected whole too.
    const std::string accent = "\xC3\xA9x";
    const Range accented = word_bounds(accent.data(), accent.size(), 1U);
    check(accented.begin == 0U && accented.end == 2U,
          "a 2-byte sequence is selected whole");

    // (5) Edges and degenerate inputs never read out of range and never answer
    // with an empty selection.
    const char* tail = "abc";
    expect_range(tail, 3, 0, 3, "offset == length probes the last run");
    expect_range(tail, 99, 0, 3, "an out-of-range offset clamps");
    expect_range(tail, 0, 0, 3, "offset 0 selects the leading run");
    check(word_bounds(nullptr, 3U, 0U).begin == 0U, "null line is safe");
    check(word_bounds("", 0U, 0U).end == 0U, "empty line is safe");

    // (6) A glyph truncated by the row tail is one byte, not an overrun.
    const std::string cut = "ab\xE6\xB8";   // 3-byte lead, only 2 bytes present
    const Range truncated = word_bounds(cut.data(), cut.size(), 2U);
    check(truncated.begin == 2U && truncated.end == 3U,
          "a truncated sequence at the tail is one byte");

    // (7) Non-word ASCII at the very start / end stays in range.
    expect_range(" x", 0, 0, 1, "leading space selects itself");
    expect_range("x ", 1, 1, 2, "trailing space selects itself");

    std::printf("receive_selection: %d checks, %d failed\n", checks, failures);
    return failures == 0 ? 0 : 1;
}
