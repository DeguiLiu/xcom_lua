// Fixed-capacity periodic timer for XCOM's coact ingress.
#pragma once
#ifndef XCOM_RUNTIME_PERIODIC_TIMER_HPP_
#define XCOM_RUNTIME_PERIODIC_TIMER_HPP_

#include <atomic>
#include <cstdint>
#include <thread>

#include "foundation/fixed_function.hpp"
#include "foundation/unique_handle.hpp"

namespace xcom::runtime {

// A single-control-owner periodic timer. It preserves an absolute monotonic
// deadline and skips missed periods, so a delayed callback cannot create a
// catch-up burst of coact events. The callback runs on this worker and must
// only perform a bounded ingress operation.
class PeriodicTimer final {
public:
    using Callback = foundation::FixedFunction<void()>;

    PeriodicTimer() noexcept;
    ~PeriodicTimer();
    PeriodicTimer(const PeriodicTimer&) = delete;
    PeriodicTimer& operator=(const PeriodicTimer&) = delete;
    PeriodicTimer(PeriodicTimer&&) = delete;
    PeriodicTimer& operator=(PeriodicTimer&&) = delete;

    [[nodiscard]] bool start(std::uint32_t interval_ms, Callback callback) noexcept;
    void stop() noexcept;
    [[nodiscard]] bool active() const noexcept;

private:
    [[nodiscard]] std::uint64_t monotonic_ns() const noexcept;
    void run() noexcept;

    foundation::UniqueHandle wake_event_;
    Callback callback_{};
    std::thread worker_{};
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> active_{false};
    std::uint64_t interval_ns_{0U};
    std::uint64_t qpc_frequency_{0U};
};

}  // namespace xcom::runtime

#endif  // XCOM_RUNTIME_PERIODIC_TIMER_HPP_
