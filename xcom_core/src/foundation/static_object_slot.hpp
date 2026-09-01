// static_object_slot.hpp - one-slot placement storage for heavyweight cores.
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_FOUNDATION_STATIC_OBJECT_SLOT_HPP_
#define XCOM_FOUNDATION_STATIC_OBJECT_SLOT_HPP_

#include "coact/assert.hpp"

#include <array>
#include <atomic>
#include <cstddef>
#include <cstdint>
#include <new>
#include <utility>

namespace xcom::foundation {

// A single preallocated object slot. It owns the backing storage, while the
// returned pointer is only an observer needed during C ABI construction. This
// is for heavyweight singleton sessions (CoreState), not a general allocator.
template <typename T>
class StaticObjectSlot final {
public:
    StaticObjectSlot() noexcept = default;
    ~StaticObjectSlot() = default;

    StaticObjectSlot(const StaticObjectSlot&) = delete;
    StaticObjectSlot& operator=(const StaticObjectSlot&) = delete;

    template <typename... Args>
    [[nodiscard]] T* try_emplace(Args&&... args) noexcept
    {
        std::uint32_t expected = 0U;
        if (!occupied_.compare_exchange_strong(expected, 1U,
                                               std::memory_order_acq_rel,
                                               std::memory_order_relaxed)) {
            return nullptr;
        }
        return ::new (static_cast<void*>(storage_.data()))
            T(std::forward<Args>(args)...);
    }

    void destroy(T& object) noexcept
    {
        COACT_ASSERT(&object == reinterpret_cast<T*>(storage_.data()));
        object.~T();
        occupied_.store(0U, std::memory_order_release);
    }

    // Validate an opaque observer without dereferencing it. This is useful at
    // C ABI boundaries where a caller can provide an arbitrary address.
    [[nodiscard]] bool contains(const T* object) const noexcept
    {
        return object == reinterpret_cast<const T*>(storage_.data()) &&
               occupied_.load(std::memory_order_acquire) != 0U;
    }

private:
    alignas(T) std::array<std::byte, sizeof(T)> storage_{};
    std::atomic<std::uint32_t> occupied_{0U};
};

}  // namespace xcom::foundation

#endif  // XCOM_FOUNDATION_STATIC_OBJECT_SLOT_HPP_
