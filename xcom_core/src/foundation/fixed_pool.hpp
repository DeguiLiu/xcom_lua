// fixed_pool.hpp - inline tagged-CAS fixed block pool for XCOM data lanes.
#pragma once
#ifndef XCOM_FOUNDATION_FIXED_POOL_HPP_
#define XCOM_FOUNDATION_FIXED_POOL_HPP_

#include "coact/assert.hpp"

#include <atomic>
#include <array>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <limits>

namespace xcom::foundation {

template <std::uint32_t BlockSize, std::uint32_t BlockCount>
class FixedPool final {
    static constexpr std::uint32_t kEmpty =
        std::numeric_limits<std::uint32_t>::max();

    static_assert(BlockSize >= sizeof(std::uint32_t),
                  "fixed pool block must store its free-list link");
    static_assert(BlockCount > 0U && BlockCount < kEmpty,
                  "fixed pool block count must not collide with the empty index");
    static_assert(std::atomic<std::uint64_t>::is_always_lock_free,
                  "XCOM requires a lock-free 64-bit tagged free-list head");

public:
    FixedPool() noexcept : head_(pack(0U, 0U))
    {
        for (std::uint32_t index = 0U; index + 1U < BlockCount; ++index) {
            store_next(index, index + 1U);
        }
        store_next(BlockCount - 1U, kEmpty);
    }

    FixedPool(const FixedPool&) = delete;
    FixedPool& operator=(const FixedPool&) = delete;

    void* allocate() noexcept
    {
        std::uint64_t head = head_.load(std::memory_order_relaxed);
        while (index(head) != kEmpty) {
            const std::uint32_t current = index(head);
            const std::uint32_t next = load_next(current);
            const std::uint64_t desired = pack(next, tag(head) + 1U);
            if (head_.compare_exchange_weak(head, desired,
                                            std::memory_order_acq_rel,
                                            std::memory_order_relaxed)) {
                return block_ptr(current);
            }
        }
        return nullptr;
    }

    void release(void* block) noexcept
    {
        COACT_ASSERT(owns(block));
        const std::uint32_t current = block_index(block);
        std::uint64_t head = head_.load(std::memory_order_relaxed);
        for (;;) {
            store_next(current, index(head));
            const std::uint64_t desired = pack(current, tag(head) + 1U);
            if (head_.compare_exchange_weak(head, desired,
                                            std::memory_order_acq_rel,
                                            std::memory_order_relaxed)) {
                return;
            }
        }
    }

    [[nodiscard]] void* block_ptr(std::uint32_t index_value) noexcept
    {
        COACT_ASSERT(index_value < BlockCount);
        return storage_.data() + (stride() * index_value);
    }

    [[nodiscard]] std::uint32_t block_index(const void* block) const noexcept
    {
        return static_cast<std::uint32_t>(
            (static_cast<const std::byte*>(block) - storage_.data()) / stride());
    }

private:
    static constexpr std::size_t stride()
    {
        return (BlockSize + alignof(std::max_align_t) - 1U) &
               ~(alignof(std::max_align_t) - 1U);
    }
    // A 32-bit ABA generation requires 2^32 successful head mutations before
    // it wraps. On the supported x64 target this remains a lock-free CAS while
    // removing the former 16-bit generation's short wrap window.
    static constexpr std::uint64_t pack(std::uint32_t index_value,
                                        std::uint32_t tag_value) noexcept
    {
        return static_cast<std::uint64_t>(index_value) |
               (static_cast<std::uint64_t>(tag_value) << 32U);
    }
    static constexpr std::uint32_t index(std::uint64_t head) noexcept
    {
        return static_cast<std::uint32_t>(head);
    }
    static constexpr std::uint32_t tag(std::uint64_t head) noexcept
    {
        return static_cast<std::uint32_t>(head >> 32U);
    }
    [[nodiscard]] bool owns(const void* block) const noexcept
    {
        const auto address = reinterpret_cast<std::uintptr_t>(block);
        const auto start = reinterpret_cast<std::uintptr_t>(storage_.data());
        return address >= start && address < start + sizeof(storage_) &&
               ((address - start) % stride()) == 0U;
    }
    void store_next(std::uint32_t block, std::uint32_t next) noexcept
    {
        std::memcpy(storage_.data() + (stride() * block), &next, sizeof(next));
    }
    [[nodiscard]] std::uint32_t load_next(std::uint32_t block) const noexcept
    {
        std::uint32_t next = kEmpty;
        std::memcpy(&next, storage_.data() + (stride() * block), sizeof(next));
        return next;
    }

    alignas(std::max_align_t)
        std::array<std::byte, stride() * BlockCount> storage_{};
    std::atomic<std::uint64_t> head_;
};

}  // namespace xcom::foundation

#endif  // XCOM_FOUNDATION_FIXED_POOL_HPP_
