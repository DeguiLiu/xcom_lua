// Windows PAL runtime regression: validates Dispatcher wake and dispatch.
#include <windows.h>

#include <array>
#include <atomic>
#include <cstdint>

#include "coact/ao.hpp"
#include "coact/event.hpp"
#include "coact/hsm.hpp"
#include "coact/runtime.hpp"
#include "pal_windows.hpp"

namespace {

constexpr std::uint16_t kSignal = 1U;

struct CounterContext {
    std::atomic<std::uint32_t>* count = nullptr;
};

struct CounterTraits {
    static constexpr std::uint64_t kRtcBudgetNs = 1000000ULL;
    static coact::LogicalPrio logical_prio() noexcept { return 1U; }
    static coact::PriorityClass priority_class() noexcept
    {
        return coact::PriorityClass::Normal;
    }
    static bool direct_eligible() noexcept { return false; }
    static bool isr_direct_safe() noexcept { return false; }
};

using CounterAo = coact::Ao<CounterContext, coact::Hsm<CounterContext>,
                            CounterTraits>;

constexpr std::array<coact::StateDef<CounterContext>, 2U> kStates{{
    {-1, nullptr, nullptr, "root", -1},
    {0, nullptr, nullptr, "active", -1},
}};
constexpr std::array<coact::TransitionDef<CounterContext>, 1U> kTransitions{{
    {1, kSignal, 1, coact::TransitionKind::Internal, nullptr,
     [](CounterContext& context, const coact::Event&) noexcept {
         context.count->fetch_add(1U, std::memory_order_relaxed);
     }},
}};

}  // namespace

int main()
{
    std::atomic<std::uint32_t> count{0U};
    coact::pal::Windows pal;
    CounterAo ao{kStates.data(), static_cast<std::uint16_t>(kStates.size()),
                 kTransitions.data(),
                 static_cast<std::uint16_t>(kTransitions.size()), 1, 2U};
    ao.context().count = &count;
    const coact::Event init{0U, 0U, 1U};
    ao.init(init);

    coact::Runtime<coact::DefaultConfig, coact::pal::Windows> runtime{pal};
    if (!runtime.bind_at(coact::TargetId{1U}, ao) || !runtime.initialize() ||
        !runtime.start()) {
        return 1;
    }

    coact::Event event{kSignal, 0U, 1U};
    const coact::SubmitResult submitted = runtime.coordinator().submit_from_task(
        coact::TargetId{1U}, &event, coact::EventQos{false, false});
    if (submitted.disposition != coact::SubmitDisposition::Queued) {
        runtime.stop();
        return 2;
    }

    for (std::uint32_t attempt = 0U; attempt < 100U; ++attempt) {
        if (count.load(std::memory_order_acquire) == 1U) {
            runtime.stop();
            return 0;
        }
        Sleep(5U);
    }
    runtime.stop();
    return 3;
}
