// open_failure_status_test.cpp - host test for the open-failure status contract.
//
// Win32-free: it includes only open_failure_status.hpp (<cstdint> + xcom.h), so
// it builds and runs with a plain g++ on Linux, like tx_submit_status_test.cpp.
// The full ABI path still needs Windows and is exercised indirectly.
//
// It pins the one invariant the C ABI must never violate: XcomStatus is
// XCOM_OK (0) or a NEGATIVE XCOM_ERR_* enumerator. CoreCtx::last_open_result
// carries two disjoint value domains -- the lifecycle's XCOM_ERR_* codes and
// the serial owner sink's raw POSITIVE Win32 codes -- so the translation must
// fold the Win32 domain onto existing enumerators and let no positive value
// escape to the LuaJIT FFI.
//
// Two failure modes are pinned explicitly:
//   * a raw Win32 code returned unchanged (the original defect);
//   * ERROR_ACCESS_DENIED (5) / ERROR_SHARING_VIOLATION (32) mapped to
//     XCOM_ERR_BUSY, which is a "poll again" sentinel, not a terminal failure:
//     the UI would then poll a dead open forever.
//
// SPDX-License-Identifier: MIT
#include "open_failure_status.hpp"

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

using xcom::open_failure_status_from_result;

// Every legal XcomStatus enumerator (xcom.h). The result must always be one of
// these; a positive or an out-of-range negative is an ABI violation.
bool is_known_status(XcomStatus s)
{
    return s == XCOM_OK || s == XCOM_ERR_PARAM || s == XCOM_ERR_NOT_OPEN ||
           s == XCOM_ERR_ALREADY_OPEN || s == XCOM_ERR_BUSY ||
           s == XCOM_ERR_FULL || s == XCOM_ERR_IO || s == XCOM_ERR_TIMEOUT ||
           s == XCOM_ERR_DRAIN_INCOMPLETE || s == XCOM_ERR_UNSUPPORTED;
}

// ---- (1) the core invariant: a raw Win32 code can never escape ------------
void test_win32_codes_never_escape_positive()
{
    // The codes CreateFileW / SetCommState / CreateEventW can actually leave in
    // the backend's out-param, plus the ERROR_SHARING_VIOLATION the serial
    // backend fix introduces, plus an unknown code.
    const std::int32_t win32_codes[] = {
        2,     // ERROR_FILE_NOT_FOUND
        3,     // ERROR_PATH_NOT_FOUND
        5,     // ERROR_ACCESS_DENIED
        8,     // ERROR_NOT_ENOUGH_MEMORY (CreateEventW / catch-all)
        31,    // ERROR_GEN_FAILURE
        32,    // ERROR_SHARING_VIOLATION
        50,    // ERROR_NOT_SUPPORTED (driver coerced the DCB)
        87,    // ERROR_INVALID_PARAMETER
        110,   // ERROR_OPEN_FAILED
        995,   // ERROR_OPERATION_ABORTED
        1167,  // ERROR_DEVICE_REMOVED
        1168,  // ERROR_DEVICE_NOT_CONNECTED
        424242 // unknown / unenumerated
    };
    for (const std::int32_t code : win32_codes) {
        const XcomStatus s = open_failure_status_from_result(code);
        CHECK(s < 0, "raw Win32 code folds to a negative XcomStatus");
        CHECK(is_known_status(s), "raw Win32 code folds to a known enumerator");
    }
}

// A broad sweep proves the property is systematic, not just the sampled codes.
void test_no_positive_input_can_return_a_positive_or_ok()
{
    bool all_negative = true;
    bool any_ok = false;
    for (std::int32_t code = 1; code <= 2048; ++code) {
        const XcomStatus s = open_failure_status_from_result(code);
        if (s >= 0) {
            all_negative = false;
        }
        if (s == XCOM_OK) {
            any_ok = true;
        }
    }
    CHECK(all_negative, "positive sweep 1..2048: every result is negative");
    CHECK(!any_ok, "positive sweep 1..2048: no result is XCOM_OK");
}

// ---- (2) access / sharing failures must NOT become the BUSY sentinel ------
void test_access_and_sharing_never_map_to_busy()
{
    // BUSY makes window.lua skip the result as "still in progress" and keep
    // polling; a definitive denial must terminate the attempt instead.
    CHECK(open_failure_status_from_result(5) != XCOM_ERR_BUSY,
          "ERROR_ACCESS_DENIED is not XCOM_ERR_BUSY");
    CHECK(open_failure_status_from_result(32) != XCOM_ERR_BUSY,
          "ERROR_SHARING_VIOLATION is not XCOM_ERR_BUSY");
    CHECK(open_failure_status_from_result(5) == XCOM_ERR_IO,
          "ERROR_ACCESS_DENIED -> XCOM_ERR_IO");
    CHECK(open_failure_status_from_result(32) == XCOM_ERR_IO,
          "ERROR_SHARING_VIOLATION -> XCOM_ERR_IO");
}

// ---- (3) closest-enumerator mapping ---------------------------------------
void test_closest_enumerator_mapping()
{
    CHECK(open_failure_status_from_result(87) == XCOM_ERR_PARAM,
          "ERROR_INVALID_PARAMETER -> XCOM_ERR_PARAM");
    CHECK(open_failure_status_from_result(121) == XCOM_ERR_TIMEOUT,
          "ERROR_SEM_TIMEOUT -> XCOM_ERR_TIMEOUT");
    CHECK(open_failure_status_from_result(258) == XCOM_ERR_TIMEOUT,
          "WAIT_TIMEOUT -> XCOM_ERR_TIMEOUT");
    CHECK(open_failure_status_from_result(1460) == XCOM_ERR_TIMEOUT,
          "ERROR_TIMEOUT -> XCOM_ERR_TIMEOUT");
    // Codes with no closer enumerator stay on the designated Win32 code.
    CHECK(open_failure_status_from_result(2) == XCOM_ERR_IO,
          "ERROR_FILE_NOT_FOUND -> XCOM_ERR_IO");
    CHECK(open_failure_status_from_result(50) == XCOM_ERR_IO,
          "ERROR_NOT_SUPPORTED -> XCOM_ERR_IO (not overloaded with -9)");
    CHECK(open_failure_status_from_result(995) == XCOM_ERR_IO,
          "ERROR_OPERATION_ABORTED -> XCOM_ERR_IO");
    CHECK(open_failure_status_from_result(1167) == XCOM_ERR_IO,
          "ERROR_DEVICE_REMOVED -> XCOM_ERR_IO");
}

// ---- (4) the XCOM domain passes through unchanged -------------------------
void test_xcom_enumerators_pass_through()
{
    CHECK(open_failure_status_from_result(XCOM_ERR_PARAM) == XCOM_ERR_PARAM,
          "XCOM_ERR_PARAM passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_NOT_OPEN) ==
              XCOM_ERR_NOT_OPEN,
          "XCOM_ERR_NOT_OPEN passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_ALREADY_OPEN) ==
              XCOM_ERR_ALREADY_OPEN,
          "XCOM_ERR_ALREADY_OPEN passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_FULL) == XCOM_ERR_FULL,
          "XCOM_ERR_FULL passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_IO) == XCOM_ERR_IO,
          "XCOM_ERR_IO passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_TIMEOUT) ==
              XCOM_ERR_TIMEOUT,
          "XCOM_ERR_TIMEOUT passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_DRAIN_INCOMPLETE) ==
              XCOM_ERR_DRAIN_INCOMPLETE,
          "XCOM_ERR_DRAIN_INCOMPLETE passes through");
    CHECK(open_failure_status_from_result(XCOM_ERR_UNSUPPORTED) ==
              XCOM_ERR_UNSUPPORTED,
          "XCOM_ERR_UNSUPPORTED passes through");
}

// ---- (5) not-a-resolved-failure values become XCOM_ERR_IO -----------------
void test_unresolved_or_stale_is_io()
{
    // XCOM_OK from a previous session must not read as success for a CLOSED
    // port; BUSY is the queued sentinel and must not read as a terminal cause.
    CHECK(open_failure_status_from_result(XCOM_OK) == XCOM_ERR_IO,
          "recorded XCOM_OK on a CLOSED port -> XCOM_ERR_IO");
    CHECK(open_failure_status_from_result(XCOM_ERR_BUSY) == XCOM_ERR_IO,
          "recorded XCOM_ERR_BUSY sentinel -> XCOM_ERR_IO");
}

}  // namespace

int main()
{
    test_win32_codes_never_escape_positive();
    test_no_positive_input_can_return_a_positive_or_ok();
    test_access_and_sharing_never_map_to_busy();
    test_closest_enumerator_mapping();
    test_xcom_enumerators_pass_through();
    test_unresolved_or_stale_is_io();

    if (g_failures != 0) {
        std::fprintf(stderr, "%d check(s) failed\n", g_failures);
        return 1;
    }
    std::printf("open_failure_status_test: all checks passed\n");
    return 0;
}
