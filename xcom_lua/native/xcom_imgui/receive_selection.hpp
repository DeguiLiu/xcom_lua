#pragma once
// Pure selection geometry for the receive log.  No ImGui, no Win32, no
// allocation, so the host test runner (tools/run_host_cpp_tests.sh) can build
// and execute it on a Linux box: the boundary rules below are the part of the
// double-click gesture that is easy to get wrong (a byte-run rule would split a
// 3-byte CJK glyph, and an off-by-one at the line tail would select a
// neighbouring character), and they are exactly the part the GUI cannot be
// driven to check headlessly.
//
// SPDX-License-Identifier: MIT

#include <cstddef>

namespace xcom::imgui::selection {

// Byte range [begin, end) of the "word" that contains `offset`.
//
// Rules, in the order they are applied:
//   * an ASCII word byte is [A-Za-z0-9_] -- the identifiers, hex payloads and
//     log tokens a serial console is read for; everything else ASCII is its
//     own one-byte selection, so a double-click on a separator selects the
//     separator rather than swallowing the spaces around it;
//   * a non-ASCII byte selects the whole UTF-8 sequence it belongs to (a CJK
//     glyph is 3 bytes; selecting one byte would copy an invalid fragment);
//   * a truncated sequence at the line tail is one byte, same as the renderer's
//     own handling (a row can be cut mid-glyph by the receive window);
//   * an out-of-range offset is clamped into [0, length].
//
// `length` is the row's length in bytes, `offset` a byte index inside it.
struct Range final {
    std::size_t begin = 0;
    std::size_t end = 0;
};

[[nodiscard]] inline bool ascii_word_byte(const char c) noexcept {
    return (c >= '0' && c <= '9') || (c >= 'A' && c <= 'Z') ||
           (c >= 'a' && c <= 'z') || c == '_';
}

// Length in bytes of the UTF-8 sequence starting at `lead` (1 for a
// continuation byte or an invalid lead, so callers always advance).
[[nodiscard]] inline std::size_t utf8_sequence_length(const unsigned char lead) noexcept {
    if (lead >= 0xF0U) return 4U;
    if (lead >= 0xE0U) return 3U;
    if (lead >= 0xC0U) return 2U;
    return 1U;
}

[[nodiscard]] inline Range word_bounds(const char* line, std::size_t length,
                                       std::size_t offset) noexcept {
    Range range{};
    if (line == nullptr || length == 0U) {
        return range;
    }
    if (offset > length) {
        offset = length;
    }
    // The byte to the LEFT of the caret decides the word: a double-click
    // between two characters selects the one being pointed at, which is the
    // convention every text widget follows (`at == length` therefore looks at
    // the last byte, and `at == 0` looks at the first).
    std::size_t probe = offset < length ? offset : (offset > 0U ? offset - 1U : 0U);
    const unsigned char lead = static_cast<unsigned char>(line[probe]);
    if ((lead & 0x80U) != 0U) {
        // Walk back to the lead byte if the probe landed on a continuation.
        while (probe > 0U &&
               (static_cast<unsigned char>(line[probe]) & 0xC0U) == 0x80U) {
            --probe;
        }
        std::size_t sequence = utf8_sequence_length(
            static_cast<unsigned char>(line[probe]));
        if (sequence > length - probe) {
            sequence = 1U;   // truncated at the row tail
        }
        range.begin = probe;
        range.end = probe + sequence;
        return range;
    }
    if (!ascii_word_byte(line[probe])) {
        range.begin = probe;
        range.end = probe + 1U;
        return range;
    }
    std::size_t begin = probe;
    while (begin > 0U && ascii_word_byte(line[begin - 1U])) {
        --begin;
    }
    std::size_t end = probe;
    while (end < length && ascii_word_byte(line[end])) {
        ++end;
    }
    range.begin = begin;
    range.end = end;
    return range;
}

}  // namespace xcom::imgui::selection
