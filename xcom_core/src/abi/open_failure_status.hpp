// open_failure_status.hpp - pure translation of the recorded owner open result
// into the caller-visible XcomStatus.
//
// Split out of xcom_abi.cpp (like runtime/tx_submit_status.hpp) so the host
// test tests/open_failure_status_test.cpp can pin the contract with a plain
// g++ on Linux: no <windows.h>, no coact, no DLL.
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_ABI_OPEN_FAILURE_STATUS_HPP_
#define XCOM_ABI_OPEN_FAILURE_STATUS_HPP_

#include <cstdint>

#include <xcom/xcom.h>

namespace xcom {

// Map one recorded CoreCtx::last_open_result value onto an XcomStatus.
//
// last_open_result is written by two producers with DIFFERENT value domains,
// so a plain static_cast to XcomStatus is wrong for one of them:
//
//   * ABI / core lifecycle writers store an XcomStatus directly: XCOM_OK (0)
//     or an XCOM_ERR_* enumerator (negative). XCOM_ERR_BUSY (-4) is the
//     "request queued, owner has not resolved it yet" sentinel, not a
//     terminal failure (xcom_abi.cpp queue_open).
//   * sink_owner_open stores the raw Win32 code returned by
//     WinSerialBackend::open()'s out-param (xcom_core.cpp). Those are
//     POSITIVE (GetLastError / ERROR_INVALID_PARAMETER / ERROR_NOT_ENOUGH_MEMORY
//     / ERROR_NOT_SUPPORTED), and a positive value is not a valid XcomStatus.
//
// Discriminator: sign. recorded > 0 is a raw Win32 code; recorded < 0 is an
// XCOM_ERR_* enumerator; 0 is XCOM_OK. This function never returns a positive
// value, and never returns XCOM_ERR_BUSY for a resolved failure (callers read
// BUSY as "poll again", so a terminal access-denied/sharing failure mapped to
// BUSY would make the UI poll forever -- see xcom_lua/ui/window.lua).
//
// Win32 -> XCOM mapping. The detail code is NOT lost: sink_owner_open also
// pushes the raw code into CoreCtx::errors (XcomError.code), which
// xcom_lua/ui/window.lua drains via xcom_take_error and translates through the
// same Win32 table. So XCOM_ERR_IO here is the lossless-per-ring "serial /
// Win32 error" code from xcom.h, not a discarded diagnosis.
inline XcomStatus open_failure_status_from_result(std::int32_t recorded) noexcept
{
    if (recorded > 0) {
        // Raw Win32 code. Only codes with a genuinely closer enumerator are
        // translated; everything else (ERROR_FILE_NOT_FOUND 2,
        // ERROR_PATH_NOT_FOUND 3, ERROR_ACCESS_DENIED 5, ERROR_NOT_ENOUGH_MEMORY
        // 8, ERROR_GEN_FAILURE 31, ERROR_SHARING_VIOLATION 32,
        // ERROR_NOT_SUPPORTED 50, ERROR_OPERATION_ABORTED 995,
        // ERROR_DEVICE_REMOVED 1167, ERROR_DEVICE_NOT_CONNECTED 1168, ...) is
        // the designated "serial / Win32 error" code, with the raw value kept
        // in the XcomError ring. NOTE: 5 and 32 are deliberately NOT mapped to
        // XCOM_ERR_BUSY even though "port in use" reads like busy; BUSY is a
        // poll-again sentinel, not a terminal failure.
        switch (recorded) {
        case 87:     // ERROR_INVALID_PARAMETER
            return XCOM_ERR_PARAM;
        case 121:    // ERROR_SEM_TIMEOUT
        case 258:    // WAIT_TIMEOUT
        case 1460:   // ERROR_TIMEOUT
            return XCOM_ERR_TIMEOUT;
        default:
            return XCOM_ERR_IO;
        }
    }
    if (recorded < 0) {
        // Already an XCOM_ERR_* enumerator (the only negative domain written);
        // pass it through, except the unresolved-request sentinel.
        return recorded == XCOM_ERR_BUSY
                   ? XCOM_ERR_IO
                   : static_cast<XcomStatus>(recorded);
    }
    // recorded == 0 (XCOM_OK) is not a resolved failure for a CLOSED port: a
    // caller polling after a failed attempt must never read a stale success.
    return XCOM_ERR_IO;
}

}  // namespace xcom

#endif /* XCOM_ABI_OPEN_FAILURE_STATUS_HPP_ */
