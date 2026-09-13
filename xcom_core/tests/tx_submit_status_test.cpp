// tx_submit_status_test.cpp - host test for the xcom_send rejection contract.
//
// Win32-free and coact-header-only: it includes only tx_submit_status.hpp (plus
// coact/config.hpp), so it builds and runs with a plain g++ on Linux, like
// thread_health_test.cpp / rx_block_lane_test.cpp. The real Dispatcher and the
// real Send AO Breaker still need Windows and remain covered indirectly.
//
// It pins the one user-visible distinction the send path must never blur:
//   - a full TxBlockPool / dispatcher queue is XCOM_ERR_FULL (the documented
//     "queue full, send less" signal);
//   - the Send AO's overload Breaker dropping a non-critical event is
//     XCOM_ERR_BUSY, because the pool is NOT full. Reporting FULL here sends the
//     user down a useless "reduce send volume" path.
//
// SPDX-License-Identifier: MIT
#include "tx_submit_status.hpp"

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

using coact::SubmitDisposition;

// Accepted outcomes (queued, handed straight to the Dispatcher, or coalesced)
// must all read as success to the caller.
void test_accepted_is_ok()
{
    CHECK(xcom::tx_submit_status(SubmitDisposition::Direct) == XCOM_OK,
          "Direct maps to XCOM_OK");
    CHECK(xcom::tx_submit_status(SubmitDisposition::Queued) == XCOM_OK,
          "Queued maps to XCOM_OK");
    CHECK(xcom::tx_submit_status(SubmitDisposition::Merged) == XCOM_OK,
          "Merged maps to XCOM_OK");
}

// The scheduler refusing the event is NOT buffer pressure: the TxBlockPool may
// be empty. Every member of this family must report BUSY, never FULL.
void test_overload_family_is_busy_not_full()
{
    CHECK(xcom::tx_submit_status(SubmitDisposition::DroppedOverload) ==
              XCOM_ERR_BUSY,
          "DroppedOverload maps to XCOM_ERR_BUSY (overload, not full)");
    CHECK(xcom::tx_submit_status(SubmitDisposition::RejectedState) ==
              XCOM_ERR_BUSY,
          "RejectedState maps to XCOM_ERR_BUSY");
    CHECK(xcom::tx_submit_status(SubmitDisposition::DroppedPolicy) ==
              XCOM_ERR_BUSY,
          "DroppedPolicy maps to XCOM_ERR_BUSY");
    CHECK(xcom::tx_submit_status(SubmitDisposition::DroppedRateLimit) ==
              XCOM_ERR_BUSY,
          "DroppedRateLimit maps to XCOM_ERR_BUSY");
    CHECK(xcom::tx_submit_status(SubmitDisposition::DroppedOverload) !=
              XCOM_ERR_FULL,
          "an overload drop is never reported as buffer-full");
}

// The scheduler's own queue-full IS a full condition, and stays FULL.
void test_rejected_full_stays_full()
{
    CHECK(xcom::tx_submit_status(SubmitDisposition::RejectedFull) ==
              XCOM_ERR_FULL,
          "RejectedFull maps to XCOM_ERR_FULL");
}

// No disposition may silently look like success except the accepted three, and
// none may look like FULL except RejectedFull.
void test_no_catch_all_is_accepted_or_full()
{
    const SubmitDisposition all[] = {
        SubmitDisposition::Direct,      SubmitDisposition::Queued,
        SubmitDisposition::Merged,      SubmitDisposition::DroppedPolicy,
        SubmitDisposition::DroppedRateLimit,
        SubmitDisposition::DroppedOverload,
        SubmitDisposition::RejectedFull, SubmitDisposition::RejectedState};
    for (const SubmitDisposition d : all) {
        const XcomStatus s = xcom::tx_submit_status(d);
        const bool accepted = (d == SubmitDisposition::Direct) ||
                              (d == SubmitDisposition::Queued) ||
                              (d == SubmitDisposition::Merged);
        CHECK(accepted == (s == XCOM_OK),
              "only accepted dispositions read XCOM_OK");
        CHECK((d == SubmitDisposition::RejectedFull) == (s == XCOM_ERR_FULL),
              "only RejectedFull reads XCOM_ERR_FULL");
    }
}

}  // namespace

int main()
{
    test_accepted_is_ok();
    test_overload_family_is_busy_not_full();
    test_rejected_full_stays_full();
    test_no_catch_all_is_accepted_or_full();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("tx_submit_status_test: all checks passed\n");
    return 0;
}
