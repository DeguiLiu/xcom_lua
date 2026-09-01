#include "periodic_timer.hpp"

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

#include <limits>
#include <utility>

namespace xcom::runtime {
namespace {

constexpr std::uint64_t kNsPerMs = 1000000ULL;

[[nodiscard]] DWORD wait_milliseconds(std::uint64_t remaining_ns) noexcept
{
    const std::uint64_t rounded_ms =
        (remaining_ns + (kNsPerMs - 1U)) / kNsPerMs;
    constexpr std::uint64_t kMaxWait =
        static_cast<std::uint64_t>(std::numeric_limits<DWORD>::max() - 1U);
    return static_cast<DWORD>(rounded_ms > kMaxWait ? kMaxWait : rounded_ms);
}

}  // namespace

PeriodicTimer::PeriodicTimer() noexcept
    : wake_event_(CreateEventW(nullptr, FALSE, FALSE, nullptr))
{
    LARGE_INTEGER frequency{};
    if (QueryPerformanceFrequency(&frequency) != FALSE && frequency.QuadPart > 0) {
        qpc_frequency_ = static_cast<std::uint64_t>(frequency.QuadPart);
    }
}

PeriodicTimer::~PeriodicTimer()
{
    stop();
}

bool PeriodicTimer::start(std::uint32_t interval_ms, Callback callback) noexcept
{
    stop();
    if (interval_ms == 0U || !callback || !wake_event_.valid()
        || qpc_frequency_ == 0U) {
        return false;
    }

    interval_ns_ = static_cast<std::uint64_t>(interval_ms) * kNsPerMs;
    callback_ = std::move(callback);
    ResetEvent(wake_event_.get());
    stop_requested_.store(false, std::memory_order_release);
    active_.store(true, std::memory_order_release);
    try {
        worker_ = std::thread(&PeriodicTimer::run, this);
    }
    catch (...) {
        active_.store(false, std::memory_order_release);
        callback_ = Callback{};
        interval_ns_ = 0U;
        return false;
    }
    return true;
}

void PeriodicTimer::stop() noexcept
{
    stop_requested_.store(true, std::memory_order_release);
    if (wake_event_.valid()) {
        SetEvent(wake_event_.get());
    }
    if (worker_.joinable()) {
        worker_.join();
    }
    active_.store(false, std::memory_order_release);
    callback_ = Callback{};
    interval_ns_ = 0U;
}

bool PeriodicTimer::active() const noexcept
{
    return active_.load(std::memory_order_acquire);
}

std::uint64_t PeriodicTimer::monotonic_ns() const noexcept
{
    LARGE_INTEGER counter{};
    if (QueryPerformanceCounter(&counter) == FALSE || qpc_frequency_ == 0U) {
        return 0U;
    }
    const std::uint64_t ticks = static_cast<std::uint64_t>(counter.QuadPart);
    return ((ticks / qpc_frequency_) * 1000000000ULL)
         + (((ticks % qpc_frequency_) * 1000000000ULL) / qpc_frequency_);
}

void PeriodicTimer::run() noexcept
{
    // Auto-send is intentionally below the coact Dispatcher and serial I/O
    // workers: it is best-effort control traffic, never receive-path work.
    static_cast<void>(SetThreadPriority(GetCurrentThread(),
                                        THREAD_PRIORITY_BELOW_NORMAL));
    std::uint64_t deadline_ns = monotonic_ns() + interval_ns_;
    while (!stop_requested_.load(std::memory_order_acquire)) {
        const std::uint64_t now_ns = monotonic_ns();
        if (now_ns < deadline_ns) {
            static_cast<void>(WaitForSingleObject(
                wake_event_.get(), wait_milliseconds(deadline_ns - now_ns)));
            continue;
        }

        callback_();
        const std::uint64_t after_callback_ns = monotonic_ns();
        deadline_ns += interval_ns_;
        if (deadline_ns <= after_callback_ns) {
            const std::uint64_t skipped =
                ((after_callback_ns - deadline_ns) / interval_ns_) + 1U;
            deadline_ns += skipped * interval_ns_;
        }
    }
}

}  // namespace xcom::runtime
