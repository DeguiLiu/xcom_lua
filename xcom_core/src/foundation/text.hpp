// text.hpp - bounded text transfer helpers for C ABI interop.
#pragma once
#ifndef XCOM_FOUNDATION_TEXT_HPP_
#define XCOM_FOUNDATION_TEXT_HPP_

#include <algorithm>
#include <array>
#include <cstddef>
#include <cstring>
#include <string_view>

namespace xcom::foundation {

inline void copy_text(std::string_view source, char* destination,
                      std::size_t capacity) noexcept
{
    if (destination == nullptr || capacity == 0U) {
        return;
    }
    const std::size_t count = std::min(source.size(), capacity - 1U);
    if (count > 0U) {
        std::memcpy(destination, source.data(), count);
    }
    destination[count] = '\0';
}

template <std::size_t Capacity>
void copy_text(std::string_view source,
               std::array<char, Capacity>& destination) noexcept
{
    copy_text(source, destination.data(), destination.size());
}

}  // namespace xcom::foundation

#endif  // XCOM_FOUNDATION_TEXT_HPP_
