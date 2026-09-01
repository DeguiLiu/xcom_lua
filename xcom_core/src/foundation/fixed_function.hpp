// fixed_function.hpp - fixed-capacity callback for XCOM internal bridges.
#pragma once
#ifndef XCOM_FOUNDATION_FIXED_FUNCTION_HPP_
#define XCOM_FOUNDATION_FIXED_FUNCTION_HPP_

#include <cstddef>
#include <new>
#include <type_traits>
#include <utility>

namespace xcom::foundation {

template <typename Signature, std::size_t Capacity = 2U * sizeof(void*)>
class FixedFunction;

template <typename Result, typename... Args, std::size_t Capacity>
class FixedFunction<Result(Args...), Capacity> final {
public:
    FixedFunction() noexcept = default;

    template <typename Callable,
              typename = std::enable_if_t<!std::is_same_v<
                  std::decay_t<Callable>, FixedFunction>>>
    FixedFunction(Callable&& callable) noexcept
    {
        using Decayed = std::decay_t<Callable>;
        static_assert(sizeof(Decayed) <= Capacity,
                      "callback exceeds XCOM fixed-function capacity");
        static_assert(alignof(Decayed) <= alignof(Storage),
                      "callback alignment exceeds XCOM fixed-function storage");
        ::new (&storage_) Decayed(std::forward<Callable>(callable));
        invoke_ = [](Storage& storage, Args... args) -> Result {
            return (*reinterpret_cast<Decayed*>(&storage))(
                std::forward<Args>(args)...);
        };
        move_ = [](Storage& destination, Storage& source) noexcept {
            ::new (&destination) Decayed(
                std::move(*reinterpret_cast<Decayed*>(&source)));
            reinterpret_cast<Decayed*>(&source)->~Decayed();
        };
        destroy_ = [](Storage& storage) noexcept {
            reinterpret_cast<Decayed*>(&storage)->~Decayed();
        };
    }

    ~FixedFunction() { reset(); }
    FixedFunction(const FixedFunction&) = delete;
    FixedFunction& operator=(const FixedFunction&) = delete;

    FixedFunction(FixedFunction&& other) noexcept
        : invoke_(other.invoke_), move_(other.move_), destroy_(other.destroy_)
    {
        if (other.move_ != nullptr) {
            other.move_(storage_, other.storage_);
            other.clear();
        }
    }

    FixedFunction& operator=(FixedFunction&& other) noexcept
    {
        if (this != &other) {
            reset();
            invoke_ = other.invoke_;
            move_ = other.move_;
            destroy_ = other.destroy_;
            if (other.move_ != nullptr) {
                other.move_(storage_, other.storage_);
                other.clear();
            }
        }
        return *this;
    }

    explicit operator bool() const noexcept { return invoke_ != nullptr; }

    Result operator()(Args... args) const
    {
        return invoke_(storage_, std::forward<Args>(args)...);
    }

private:
    using Storage = std::aligned_storage_t<Capacity, alignof(void*)>;
    using Invoke = Result (*)(Storage&, Args...);
    using Move = void (*)(Storage&, Storage&) noexcept;
    using Destroy = void (*)(Storage&) noexcept;

    void clear() noexcept
    {
        invoke_ = nullptr;
        move_ = nullptr;
        destroy_ = nullptr;
    }

    void reset() noexcept
    {
        if (destroy_ != nullptr) {
            destroy_(storage_);
        }
        clear();
    }

    mutable Storage storage_{};
    Invoke invoke_ = nullptr;
    Move move_ = nullptr;
    Destroy destroy_ = nullptr;
};

}  // namespace xcom::foundation

#endif  // XCOM_FOUNDATION_FIXED_FUNCTION_HPP_
