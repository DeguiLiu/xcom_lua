// fixed_vector.hpp - fixed-capacity contiguous object storage for XCOM.
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_FOUNDATION_FIXED_VECTOR_HPP_
#define XCOM_FOUNDATION_FIXED_VECTOR_HPP_

#include <array>
#include <cstddef>
#include <cstdint>
#include <new>
#include <type_traits>
#include <utility>

namespace xcom::foundation {

// FixedVector is intentionally not a cross-thread queue. Use coact's bounded
// queues for handoff; use this only for a contiguous, compile-time-bounded
// local collection where std::vector would allocate.
template <typename T, std::uint32_t Capacity>
class FixedVector final {
    static_assert(Capacity > 0U, "FixedVector capacity must be non-zero");

public:
    using value_type = T;
    using size_type = std::uint32_t;

    FixedVector() noexcept = default;
    ~FixedVector() noexcept { clear(); }

    FixedVector(const FixedVector&) = delete;
    FixedVector& operator=(const FixedVector&) = delete;

    [[nodiscard]] T* data() noexcept
    {
        return reinterpret_cast<T*>(storage_.data());
    }
    [[nodiscard]] const T* data() const noexcept
    {
        return reinterpret_cast<const T*>(storage_.data());
    }
    [[nodiscard]] T& operator[](size_type index) noexcept { return data()[index]; }
    [[nodiscard]] const T& operator[](size_type index) const noexcept
    {
        return data()[index];
    }
    [[nodiscard]] T* begin() noexcept { return data(); }
    [[nodiscard]] const T* begin() const noexcept { return data(); }
    [[nodiscard]] T* end() noexcept { return data() + size_; }
    [[nodiscard]] const T* end() const noexcept { return data() + size_; }
    [[nodiscard]] bool empty() const noexcept { return size_ == 0U; }
    [[nodiscard]] bool full() const noexcept { return size_ == Capacity; }
    [[nodiscard]] size_type size() const noexcept { return size_; }
    static constexpr size_type capacity() noexcept { return Capacity; }

    template <typename... Args>
    [[nodiscard]] bool try_emplace_back(Args&&... args) noexcept
    {
        static_assert(std::is_nothrow_constructible<T, Args...>::value,
                      "FixedVector requires nothrow element construction");
        if (full()) {
            return false;
        }
        ::new (static_cast<void*>(storage_.data() + sizeof(T) * size_))
            T(std::forward<Args>(args)...);
        ++size_;
        return true;
    }

    [[nodiscard]] bool try_push_back(const T& value) noexcept
    {
        return try_emplace_back(value);
    }
    [[nodiscard]] bool try_push_back(T&& value) noexcept
    {
        return try_emplace_back(std::move(value));
    }

    [[nodiscard]] bool pop_back() noexcept
    {
        if (empty()) {
            return false;
        }
        --size_;
        data()[size_].~T();
        return true;
    }

    void clear() noexcept
    {
        while (pop_back()) {
        }
    }

private:
    alignas(T) std::array<std::byte, sizeof(T) * Capacity> storage_{};
    size_type size_ = 0U;
};

}  // namespace xcom::foundation

#endif  // XCOM_FOUNDATION_FIXED_VECTOR_HPP_
