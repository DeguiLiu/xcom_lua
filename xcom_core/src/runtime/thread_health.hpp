// thread_health.hpp - platform-free liveness logic for the thread heartbeat.
//
// Design: docs/design-state-machines.md §4. Liveness is ORTHOGONAL to the port
// state machine (§4.1) and to progress (§4.3):
//   - A beat means "the monitored loop reached its wait point or completed an
//     iteration", NOT "work arrived". An idle-but-healthy thread still beats.
//   - A thread parked in its KNOWN blocking wait (an infinite PAL wait, an idle
//     log-writer wake) is alive even though no beat has advanced; treating a
//     long park as a wedge would false-alarm on every quiet line, and a false
//     "thread wedged" report in a diagnostic tool is worse than a late one.
//   - PROGRESS is a different axis: a writer retrying a dead disk is alive and
//     keeps beating while making no progress. That condition is reported by the
//     storage-stall episode in log_writer.cpp, NOT here. Do not "fix" a beat to
//     also require progress.
//
// This header deliberately carries no platform or coact dependency so the
// timeout / episode-bounding / recovery logic is host-testable (thread_health_
// test.cpp compiles it with a plain g++ on Linux).
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_THREAD_HEALTH_HPP_
#define XCOM_THREAD_HEALTH_HPP_

#include <cstdint>

namespace xcom {

// Thresholds. Pick each comfortably above the slowest legitimate beat interval;
// a false wedge alarm is worse than a late one.
//
// Serial read: an idle line completes its overlapped ReadFile about every
// kReadTickTimeoutMs == 50 ms, so the loop beats ~20 Hz. 1000 ms is a 20x
// margin and still detects a driver that never completes the IRP.
inline constexpr std::uint32_t kSerialReadBeatTimeoutMs = 1000U;

// Dispatcher: while a port is OPEN/CLOSED (i.e. no synchronous owner action is
// running) every dispatched action is budgeted at <= 2 ms (SerialTraits), so
// 1000 ms is ~500x the slowest legitimate gap. The check is suspended while the
// port is OPENING/CLOSING/FAULT because owner_open/owner_close may legitimately
// block for seconds there (the ABI open caller waits up to ~2 s).
inline constexpr std::uint32_t kDispatcherBeatTimeoutMs = 1000U;

// Log writer: the writer loop beats once per iteration and write_all() now
// beats before EVERY WriteFile, so draining a file in many small writes is
// covered. The retry loops beat once per retry, but their 50 ms sleep runs only
// after a FAILED call: that rhythm does NOT bound one call. The only un-beated
// span left is a single synchronous WriteFile, for which the platform offers no
// per-call timeout. A call into a stalled network redirector can therefore
// exceed 2000 ms and trip ONE false "stalled" episode. Accepting that is
// deliberate: liveness ("the thread is alive") and progress ("bytes reach the
// disk") are different axes, and the storage-stall episode in log_writer.cpp
// reports the progress axis. Do not merge them.
inline constexpr std::uint32_t kLogWriterBeatTimeoutMs = 2000U;

// Dispatcher parked-watch threshold. An idle dispatcher parks in an INFINITE
// wait BY DESIGN, so no finite threshold can prove a wedge: a long park may be
// healthy idleness or a WaitForSingleObject hung after a lost wakeup, and this
// signal cannot tell the two apart (design section 4.4 item 1). The threshold
// only turns the otherwise-silent park into something observable, worded as
// informational and never as "stalled". One minute is far longer than any
// legitimate synchronous owner action.
inline constexpr std::uint32_t kDispatcherParkedInfoMs = 60000U;

// Per-thread liveness state. `last_beat_ms` is a monotonic millisecond stamp
// written by the monitored thread; 0 before the first beat means "the producer
// has not started yet" and is never treated as a wedge. `faulted`/`episodes`
// are owned by the single observer (the 250 ms snapshot poll).
struct LivenessState {
    std::uint32_t last_beat_ms = 0U;
    // Sticky "a nonzero beat has ever been seen". A derived flag would mask one
    // check whenever a beat lands exactly on the uint32 wrap and stores 0, so
    // the fact is latched instead of re-derived from the stamp each time.
    bool started = false;
    bool faulted = false;
    std::uint32_t episodes = 0U;
};

// Episode state for the non-alarming dispatcher parked-watch. Kept separate
// from LivenessState because a long park is NOT a stall: it reuses the same
// once-per-episode edge shape but the caller must word it as information.
struct ParkWatchState {
    bool reported = false;
    std::uint32_t episodes = 0U;
};

enum class LivenessEdge : std::uint8_t {
    kNone = 0U,
    kFault = 1U,
    kRecovery = 2U
};

struct LivenessResult {
    LivenessEdge edge = LivenessEdge::kNone;
    std::uint32_t elapsed_ms = 0U;   // wrap-safe ms since the last beat
    std::uint32_t episodes = 0U;     // fault episodes to date
};

// Decide the fault/recovery edge for one monitored thread.
//
// `running` is false once the thread has stopped (or before it starts): a
// stopped thread leaves a stale stamp and a cleared parked flag, which would
// otherwise read as an endless stall, so it is skipped entirely and any open
// episode is closed with kRecovery. `parked` is true when a RUNNING thread is
// sitting in its known blocking wait (or is not expected to run at all, e.g.
// the port is closed): a parked thread is healthy by definition. kFault is
// returned exactly on the healthy->expired edge and kRecovery exactly on
// expired->healthy, so a fast checker cadence can never flood the error ring
// with one entry per check.
[[nodiscard]] inline LivenessResult liveness_evaluate(
    LivenessState& state, std::uint32_t now_ms, std::uint32_t timeout_ms,
    bool running, bool parked) noexcept
{
    if (state.last_beat_ms != 0U) {
        state.started = true;
    }
    // uint32 subtraction is wrap-safe: a clock that wrapped past last_beat
    // yields the true (small) elapsed, a stamp from the future yields a large
    // elapsed that the timeout then catches.
    const std::uint32_t elapsed = now_ms - state.last_beat_ms;
    const bool expired =
        running && state.started && (false == parked) && (elapsed > timeout_ms);

    LivenessResult result{};
    result.elapsed_ms = elapsed;
    if (expired && (false == state.faulted)) {
        state.faulted = true;
        ++state.episodes;
        result.edge = LivenessEdge::kFault;
    }
    else if ((false == expired) && state.faulted) {
        state.faulted = false;
        result.edge = LivenessEdge::kRecovery;
    }
    result.episodes = state.episodes;
    return result;
}

// Decide the informational edge for a thread parked in its known blocking wait.
// `since_ms` is the monotonic stamp when the park began (0 means "not parked");
// `running` suppresses the signal once the thread has stopped. A park longer
// than `threshold_ms` is reported ONCE and cleared ONCE, exactly like a
// liveness episode. This logic CANNOT tell an idle-but-healthy dispatcher from
// one hung in the wait after a lost wakeup - both are the same INFINITE wait -
// so the caller must word the edge as information, never as a stall.
[[nodiscard]] inline LivenessResult liveness_evaluate_park(
    ParkWatchState& state, std::uint32_t now_ms, std::uint32_t since_ms,
    std::uint32_t threshold_ms, bool running) noexcept
{
    const bool parked = since_ms != 0U;
    const std::uint32_t elapsed = parked ? (now_ms - since_ms) : 0U;
    const bool long_park = running && parked && (elapsed > threshold_ms);

    LivenessResult result{};
    result.elapsed_ms = elapsed;
    if (long_park && (false == state.reported)) {
        state.reported = true;
        ++state.episodes;
        result.edge = LivenessEdge::kFault;
    }
    else if ((false == long_park) && state.reported) {
        state.reported = false;
        result.edge = LivenessEdge::kRecovery;
    }
    result.episodes = state.episodes;
    return result;
}

}  // namespace xcom

#endif /* XCOM_THREAD_HEALTH_HPP_ */
