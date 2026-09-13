// tx_diag_test.cpp - hardware-free regression for the teardown TX drain grace
// (gap A) and the flow-control stall diagnosis (gap B).
//
// Both features act on a real COM port with a non-reading peer, which no CI
// has. What is exercisable without hardware:
//   1. the COMSTAT hold-bit -> error-message mapping (describe_write_failure);
//   2. the bounded write-drain grace constant is positive and small;
//   3. WinSerialBackend's guard paths on a never-opened port: write() is a
//      parameter error and abort_pending_write()/close() return promptly
//      instead of waiting on a nonexistent in-flight write.
// The real drain (a whole frame delivered before CancelIoEx) and live
// ClearCommError sampling still require a UART loopback/hardware test.
//
// SPDX-License-Identifier: MIT
#include <windows.h>

#include <cstdint>
#include <cstdio>
#include <cstring>

#include "serial_backend_win.hpp"

static int g_failures = 0;

#define CHECK(cond, msg)                                               \
    do {                                                               \
        if (!(cond)) {                                                 \
            std::fprintf(stderr, "FAIL: %s (%s:%d)\n", msg, __FILE__, \
                         __LINE__);                                    \
            ++g_failures;                                              \
        }                                                              \
        else {                                                         \
            std::printf("ok: %s\n", msg);                               \
        }                                                              \
        std::fflush(stdout);                                           \
    } while (0)

static bool contains(const char* haystack, const char* needle)
{
    return std::strstr(haystack, needle) != nullptr;
}

int main()
{
    using namespace xcom;

    // (1) A timeout names the hold actually reported by COMSTAT.
    CHECK(contains(describe_write_failure(ERROR_TIMEOUT, kLineStatusCtsHold),
                   "CTS"),
          "timeout + CtsHold reports CTS");
    CHECK(contains(describe_write_failure(ERROR_TIMEOUT, kLineStatusDsrHold),
                   "DSR"),
          "timeout + DsrHold reports DSR");
    CHECK(contains(describe_write_failure(ERROR_TIMEOUT, kLineStatusXoffHold),
                   "XOFF"),
          "timeout + XoffHold reports XOFF");
    CHECK(contains(describe_write_failure(ERROR_TIMEOUT, 0U), "not reading"),
          "timeout with no hold reports peer not reading");

    // A CTS hold takes priority: it is the most actionable cause of the three.
    CHECK(contains(describe_write_failure(
                       ERROR_TIMEOUT,
                       kLineStatusCtsHold | kLineStatusXoffHold),
                   "CTS"),
          "CtsHold wins over XoffHold");

    // Non-timeout errors keep the generic wording; the hold bits are irrelevant.
    CHECK(std::strcmp(describe_write_failure(ERROR_DEVICE_REMOVED,
                                             kLineStatusCtsHold),
                      "Win32 serial write failed") == 0,
          "non-timeout error keeps generic message");

    // (2) The write-drain grace must be positive and bounded. It is one share
    //     of the backend teardown: the read loop's cancelled-read grace
    //     (1500 ms, serial_backend_win.cpp) adds to it, keeping the whole
    //     teardown inside the ~2000 ms close budget the runtime reserves on the
    //     exit path (the xcom_ffi.close default timeout). The shorter
    //     core_close default (CLOSE_WAIT_MS = 200 ms, window.lua) can return
    //     before that grace expires.
    CHECK(kTxDrainGraceMs > 0U && kTxDrainGraceMs <= 500U,
          "drain grace is bounded");

    // (3) The per-read tick bounds each overlapped ReadFile so an idle line
    //     cannot spin the loop (the old ReadIntervalTimeout = MAXDWORD mode).
    CHECK(kReadTickTimeoutMs > 0U && kReadTickTimeoutMs <= 1000U,
          "read tick timeout is bounded");

    // (4) Line-format legality enforced before the port is opened: 1.5 stop
    //     bits exist only for a 5-data-bit word, and the ranges are closed.
    CHECK(valid_line_format(5U, 1U), "5 data bits + 1.5 stop bits is legal");
    CHECK(!valid_line_format(6U, 1U), "6 data bits + 1.5 stop bits is illegal");
    CHECK(!valid_line_format(7U, 1U), "7 data bits + 1.5 stop bits is illegal");
    CHECK(!valid_line_format(8U, 1U), "8 data bits + 1.5 stop bits is illegal");
    CHECK(valid_line_format(5U, 0U) && valid_line_format(8U, 0U),
          "1 stop bit is legal at 5 and 8 data bits");
    CHECK(valid_line_format(8U, 2U), "2 stop bits is legal at 8 data bits");
    CHECK(!valid_line_format(4U, 0U) && !valid_line_format(9U, 0U),
          "out-of-range data bits rejected");
    CHECK(!valid_line_format(8U, 3U), "out-of-range stop bits rejected");

    // (5) Guard paths on a never-opened backend.
    WinSerialBackend backend;
    CHECK(!backend.is_open(), "default backend is not open");

    std::uint32_t written = 0xFFFFFFFFU;
    std::int32_t error = 0;
    std::uint32_t line_status = 0xFFFFFFFFU;
    CHECK(!backend.write(nullptr, 0U, 1000U, written, error, &line_status),
          "write on closed backend is rejected");
    CHECK(error == ERROR_INVALID_PARAMETER, "closed-backend write is PARAM");
    CHECK(line_status == 0U, "line_status is reset on a rejected write");

    const DWORD start = GetTickCount();
    backend.abort_pending_write();
    backend.close();
    const DWORD elapsed = GetTickCount() - start;
    CHECK(elapsed < 100U,
          "teardown on a closed backend returns without waiting on a grace");

    if (g_failures != 0) {
        std::fprintf(stderr, "tx-diag tests FAILED (%d)\n", g_failures);
        return 1;
    }
    std::printf("tx-diag tests PASS\n");
    return 0;
}
