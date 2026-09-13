// thread_health_test.cpp - host test for the platform-free liveness logic.
//
// Win32-free and coact-free: it includes only thread_health.hpp, so it builds
// and runs with a plain g++ on Linux (see the CMake target for the Windows
// build). It covers the parts of design §4.2 item 3 that are pure logic:
// timeout detection, once-per-episode fault reporting, once-per-recovery
// reporting, the parked (idle) exemption, and uint32 wrap-safety. The thread
// wiring itself (real beats, real ErrorRing pushes) is exercised only on
// Windows and remains untested here.
//
// SPDX-License-Identifier: MIT
#include "thread_health.hpp"

#include <cstdio>

static int g_failures = 0;

#define CHECK(cond, msg)                                               \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, \
                         __LINE__);                                    \
            ++g_failures;                                              \
        }                                                              \
        else {                                                         \
            std::printf("ok: %s\n", msg);                              \
        }                                                              \
        std::fflush(stdout);                                           \
    } while (0)

namespace {

using xcom::LivenessEdge;
using xcom::LivenessResult;
using xcom::LivenessState;

constexpr std::uint32_t kTimeout = 1000U;

LivenessResult eval(LivenessState& state, std::uint32_t now, bool parked,
                    bool running = true)
{
    return xcom::liveness_evaluate(state, now, kTimeout, running, parked);
}

// A thread that has not beaten yet is never a wedge (last_beat == 0).
void test_unstarted_is_healthy()
{
    LivenessState state{};
    const LivenessResult result = eval(state, 100000U, false);
    CHECK(result.edge == LivenessEdge::kNone, "unstarted: no fault");
    CHECK(result.episodes == 0U, "unstarted: no episode counted");
}

// A recent beat is healthy, including exactly at the timeout boundary.
void test_recent_beat_is_healthy()
{
    LivenessState state{};
    state.last_beat_ms = 10000U;
    CHECK(eval(state, 10500U, false).edge == LivenessEdge::kNone,
          "recent beat: healthy");
    CHECK(eval(state, 11000U, false).edge == LivenessEdge::kNone,
          "beat exactly at timeout: healthy (strictly greater trips)");
    CHECK(eval(state, 11001U, false).edge == LivenessEdge::kFault,
          "one ms past timeout: fault");
}

// One fault entry per episode, not one per check.
void test_fault_is_episode_bounded()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    const LivenessResult first = eval(state, 5000U, false);
    CHECK(first.edge == LivenessEdge::kFault, "fault edge on the first expiry");
    CHECK(first.elapsed_ms == 4000U, "fault reports elapsed ms");
    CHECK(first.episodes == 1U, "first episode counted");
    CHECK(eval(state, 5100U, false).edge == LivenessEdge::kNone,
          "second check in the same episode: no repeat entry");
    CHECK(state.episodes == 1U, "episode count unchanged mid-episode");
}

// One recovery entry, then silent, and a second episode can begin.
void test_recovery_is_episode_bounded()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    static_cast<void>(eval(state, 5000U, false));
    state.last_beat_ms = 4900U;
    LivenessResult result = eval(state, 5000U, false);
    CHECK(result.edge == LivenessEdge::kRecovery, "recovery edge once");
    CHECK(eval(state, 5010U, false).edge == LivenessEdge::kNone,
          "no second recovery entry");
    CHECK(!state.faulted, "recovered state cleared");
    // A later stall is a fresh episode.
    state.last_beat_ms = 6000U;
    result = eval(state, 9000U, false);
    CHECK(result.edge == LivenessEdge::kFault, "second fault episode");
    CHECK(result.episodes == 2U, "episode counter advanced");
}

// Parked (idle in a known wait) is alive even with an ancient beat, and a park
// also clears an already-reported fault.
void test_parked_is_healthy_and_clears_fault()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    CHECK(eval(state, 500000U, true).edge == LivenessEdge::kNone,
          "long park: no fault");
    CHECK(eval(state, 500000U, false).edge == LivenessEdge::kFault,
          "same stamp unparked: fault");
    CHECK(eval(state, 500000U, true).edge == LivenessEdge::kRecovery,
          "park after a fault: recovery");
    CHECK(!state.faulted, "park cleared the fault flag");
}

// uint32 subtraction must survive a monotonic-ms wrap.
void test_wrap_safe()
{
    LivenessState state{};
    state.last_beat_ms = 0xFFFFFE00U;   // 512 ms before wrap
    CHECK(eval(state, 100U, false).edge == LivenessEdge::kNone,
          "wrapped beat 612 ms ago: healthy");

    LivenessState stalled{};
    stalled.last_beat_ms = 0xFFFFFC00U;   // 1024 ms before wrap
    CHECK(eval(stalled, 100U, false).edge == LivenessEdge::kFault,
          "wrapped beat 1124 ms ago: fault");

    LivenessState fresh{};
    fresh.last_beat_ms = 0xFFFFFF00U;   // 256 ms before wrap
    CHECK(eval(fresh, 100U, false).edge == LivenessEdge::kNone,
          "wrapped beat 356 ms ago: healthy");
}

// A stopped thread must never be judged. Its stamp is stale and `parked` was
// cleared on its final return, which would otherwise read as an endless stall;
// the lifecycle gate closes any open episode and then stays silent.
void test_stopped_thread_is_suppressed()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    CHECK(eval(state, 5000U, false).edge == LivenessEdge::kFault,
          "running with a stale beat: fault");
    CHECK(eval(state, 6000U, false, false).edge == LivenessEdge::kRecovery,
          "stopped after a fault: recovery, not a second fault");
    CHECK(eval(state, 9000000U, false, false).edge == LivenessEdge::kNone,
          "stopped thread never faults again");
    CHECK(!state.faulted, "stopped thread is not left faulted");
    CHECK(eval(state, 9000000U, false, false).episodes == 1U,
          "stop did not invent an episode");
}

// The writer now beats before each WriteFile, so only a SINGLE call that
// outlasts the timeout may trip. That span is unbounded by the platform; this
// pins the one accepted false alarm (liveness vs progress, design 4.4 item 3).
void test_single_unbeated_call_can_trip()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    CHECK(eval(state, 1000U + kTimeout, false).edge == LivenessEdge::kNone,
          "single call exactly at the timeout: healthy");
    CHECK(eval(state, 1000U + kTimeout + 1U, false).edge == LivenessEdge::kFault,
          "single un-beated call past the timeout: fault (documented bound)");
}

// Unparking must publish a fresh beat BEFORE clearing `parked`: if the observer
// sees parked=0 while the stamp is still stale it emits one spurious fault.
void test_clear_parked_after_stale_beat_faults()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    CHECK(eval(state, 9000U, true).edge == LivenessEdge::kNone,
          "parked with a stale stamp: healthy");
    CHECK(eval(state, 9000U, false).edge == LivenessEdge::kFault,
          "park cleared with a stale stamp: the spurious fault to avoid");
    state.last_beat_ms = 9000U;   // the ordered fix beats first
    CHECK(eval(state, 9050U, false).edge == LivenessEdge::kRecovery,
          "fresh beat then unpark: recovery, no extra fault");
}

// A beat landing exactly on the uint32 wrap stores 0; once an earlier beat has
// latched `started`, the wrap beat must still be evaluated, not masked.
void test_wrap_zero_beat_is_not_masked_after_start()
{
    LivenessState state{};
    state.last_beat_ms = 1000U;
    static_cast<void>(eval(state, 1000U, false));
    state.last_beat_ms = 0U;   // beat at the wrap instant
    CHECK(eval(state, kTimeout + 1U, false).edge == LivenessEdge::kFault,
          "zero wrap beat after start: still evaluated");
}

// Parked-watch: a long park is a distinct informational episode, not a stall.
// It fires once and clears once, and is suppressed while the thread is stopped.
void test_park_watch_episode()
{
    using xcom::ParkWatchState;
    constexpr std::uint32_t kPark = xcom::kDispatcherParkedInfoMs;
    ParkWatchState state{};
    CHECK(xcom::liveness_evaluate_park(state, 1000U, 0U, kPark, true).edge ==
              LivenessEdge::kNone,
          "not parked: no signal");
    CHECK(xcom::liveness_evaluate_park(state, 1000U, 1000U, kPark, true).edge ==
              LivenessEdge::kNone,
          "short park: no signal");
    CHECK(xcom::liveness_evaluate_park(state, 70000U, 1000U, kPark, true).edge ==
              LivenessEdge::kFault,
          "long park: one informational edge");
    CHECK(xcom::liveness_evaluate_park(state, 80000U, 1000U, kPark, true).edge ==
              LivenessEdge::kNone,
          "still parked: no repeat");
    CHECK(xcom::liveness_evaluate_park(state, 80000U, 0U, kPark, true).edge ==
              LivenessEdge::kRecovery,
          "unpark: one recovery edge");
    CHECK(xcom::liveness_evaluate_park(state, 200000U, 1000U, kPark, false).edge ==
              LivenessEdge::kNone,
          "stopped thread: park-watch suppressed");
}

}  // namespace

int main()
{
    test_unstarted_is_healthy();
    test_recent_beat_is_healthy();
    test_fault_is_episode_bounded();
    test_recovery_is_episode_bounded();
    test_parked_is_healthy_and_clears_fault();
    test_wrap_safe();
    test_stopped_thread_is_suppressed();
    test_single_unbeated_call_can_trip();
    test_clear_parked_after_stale_beat_faults();
    test_wrap_zero_beat_is_not_masked_after_start();
    test_park_watch_episode();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("thread_health_test: all checks passed\n");
    return 0;
}
