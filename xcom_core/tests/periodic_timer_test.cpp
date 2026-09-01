#include <windows.h>

#include <atomic>
#include <cstdint>

#include "periodic_timer.hpp"

int main()
{
    std::atomic<std::uint32_t> fired{0U};
    xcom::runtime::PeriodicTimer timer;
    if (!timer.start(5U, [&fired]() noexcept {
            fired.fetch_add(1U, std::memory_order_relaxed);
        })) {
        return 1;
    }

    for (std::uint32_t attempt = 0U; attempt < 100U; ++attempt) {
        if (fired.load(std::memory_order_acquire) >= 2U) {
            timer.stop();
            if (timer.active()) {
                return 3;
            }
            const std::uint32_t before_restart =
                fired.load(std::memory_order_acquire);
            if (!timer.start(5U, [&fired]() noexcept {
                    fired.fetch_add(1U, std::memory_order_relaxed);
                })) {
                return 4;
            }
            for (std::uint32_t restart_attempt = 0U;
                 restart_attempt < 100U; ++restart_attempt) {
                if (fired.load(std::memory_order_acquire) > before_restart) {
                    timer.stop();
                    return timer.active() ? 5 : 0;
                }
                Sleep(5U);
            }
            timer.stop();
            return 6;
        }
        Sleep(5U);
    }
    timer.stop();
    return 2;
}
