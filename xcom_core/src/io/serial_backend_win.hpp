// serial_backend_win.hpp - minimal coact-bound Win32 serial I/O adapter.
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_SERIAL_BACKEND_WIN_HPP_
#define XCOM_SERIAL_BACKEND_WIN_HPP_

#include <cstdint>
#include <atomic>
#include <string_view>
#include <thread>

#include "foundation/fixed_function.hpp"
#include "foundation/unique_handle.hpp"

#include <xcom/xcom.h>

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <windows.h>

namespace xcom {

// Neutral "no native error" sentinel for the backend's out `error` parameters.
// Win32 maps success to ERROR_SUCCESS (0); this alias lets callers above the
// backend layer name that "clean" state without including winerror.h.
inline constexpr std::int32_t kSerialSuccess = 0;

// Bounded grace (ms) an in-flight transmit is allowed to finish before teardown
// falls back to CancelIoEx. Close must not be held indefinitely, so the value is
// deliberately small: one 4096-byte frame takes ~3.6 ms at 115200 baud and
// ~43 ms at 9600 baud, so 200 ms covers the tail of an already-started frame
// (the case that matters for a half-frame wedging a bootloader) without letting
// a stalled peer stall shutdown. Keep this well under the 2000 ms ABI close
// budget the runtime reserves.
inline constexpr std::uint32_t kTxDrainGraceMs = 200U;

// COMSTAT.f*Hold bits mirrored out of a stalled transmit (see write()'s
// `line_status` out-parameter). A timed-out send is frequently not a broken
// link but flow control asking us to wait, so these bits let the caller report
// the actual cause instead of a bare "timeout".
inline constexpr std::uint32_t kLineStatusCtsHold = 1U << 0U;   // waiting for CTS
inline constexpr std::uint32_t kLineStatusDsrHold = 1U << 1U;   // waiting for DSR
inline constexpr std::uint32_t kLineStatusXoffHold = 1U << 2U;  // peer sent XOFF

// Full message for a failed native transmit, for the core error ring. A timeout
// is annotated with the COMSTAT hold cause (bits above) so the user is told the
// peer never became ready / paused the link, not merely that time expired;
// every other error keeps the generic wording. Header-inline so the
// hardware-free host test can cover the mapping without a physical adapter.
[[nodiscard]] inline const char* describe_write_failure(
    std::int32_t error, std::uint32_t line_status) noexcept
{
    if (error != ERROR_TIMEOUT) {
        return "Win32 serial write failed";
    }
    if ((line_status & kLineStatusCtsHold) != 0U) {
        return "Win32 serial write timeout: CTS not asserted "
               "(peer not ready or flow control stalled)";
    }
    if ((line_status & kLineStatusDsrHold) != 0U) {
        return "Win32 serial write timeout: DSR not asserted (peer not ready)";
    }
    if ((line_status & kLineStatusXoffHold) != 0U) {
        return "Win32 serial write timeout: peer sent XOFF "
               "(software flow control paused)";
    }
    return "Win32 serial write timeout: peer not reading (TX buffer full)";
}

// Enumerate Windows serial ports from the registry
// (HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM). Fills `out` up to its
// caller-provided capacity and returns the total number discovered, preserving
// the XCOM_ERR_FULL ABI contract without an internal fixed-port limit. No
// Win32 types leak past this TU boundary.
//
// Backward-compatible wrapper: never probes occupancy and discards any
// enumeration error (busy stays 0). Prefer enumerate_serial_ports_ex when the
// caller needs the failure reason or the busy flag.
std::uint32_t enumerate_serial_ports(XcomPortInfo* out, std::uint32_t capacity);

// Error-aware / occupancy-aware enumeration.
//
// `error` receives 0 on success, or the native Win32 status (RegOpenKeyExA /
// RegEnumValueA LSTATUS) when the registry enumeration itself failed. A missing
// SERIALCOMM key is the normal "no ports present" state, NOT an error, so it
// returns count 0 with *error == 0.
//
// When `probe_busy` is true each discovered port is probed for exclusive
// occupancy: CreateFileW(share mode 0) is attempted and, on success, the handle
// is closed immediately. The probe never calls SetCommState or
// EscapeCommFunction and never performs I/O, so the DCB is not programmed and
// no SET_DTR/SET_RTS IOCTL is issued. A failed probe with
// GetLastError() == ERROR_ACCESS_DENIED sets info.busy = 1.
//
// STABILITY: probe_busy must be false for the default/safe path. A plain open
// still delivers an open IRP and some USB-UART bridges assert DTR on open,
// which can reset a running target board; only an explicit opt-in
// (XCOM_LIST_PORTS_PROBE_BUSY) should accept that. Probing is also skipped when
// capacity is 0, so the ABI size-query never touches a device.
std::uint32_t enumerate_serial_ports_ex(XcomPortInfo* out,
                                        std::uint32_t capacity,
                                        bool probe_busy,
                                        std::int32_t& error);

struct SerialPortOptions final {
    std::string_view port_name;
    std::uint32_t baud = 0U;
    std::uint8_t data_bits = 8U;
    std::uint8_t stop_bits = 0U;
    std::uint8_t parity = 0U;
    std::uint8_t flow_control = 0U;
    bool dtr_enabled = false;
    bool rts_enabled = false;
};

// v1.5 line-status report from ClearCommError, classified inside the Win32
// layer so no CE_*/COMSTAT constant leaks upward. Each category is 0/1 per
// poll (ClearCommError latches and clears a bitmask, it does not count); the
// core accumulates them into monotonic metrics. `error_flags` carries the raw
// lpErrors bitmask and `cb_in_que`/`cb_out_que` the driver queue depths, both
// for the diagnostic record. `hold_events` is 1 only on a rising edge into a
// Cts/Dsr/Rlsd/Xoff flow-control hold, so a steady handshake does not repeat.
struct SerialLineStatus final {
    std::uint32_t framing_errors = 0U;   // CE_FRAME
    std::uint32_t parity_errors = 0U;    // CE_RXPARITY
    std::uint32_t overrun_errors = 0U;   // CE_RXOVER | CE_OVERRUN
    std::uint32_t break_events = 0U;     // CE_BREAK
    std::uint32_t hold_events = 0U;      // fCtsHold/fDsrHold/fRlsdHold/fXoffHold edge
    std::uint32_t error_flags = 0U;      // raw ClearCommError lpErrors
    std::uint32_t cb_in_que = 0U;        // COMSTAT.cbInQue
    std::uint32_t cb_out_que = 0U;       // COMSTAT.cbOutQue
};

class WinSerialBackend final {
public:
    // FixedFunction gives the owner a small, non-allocating callback bridge.
    // The CoreState capture is one pointer and therefore remains well inside
    // this inline buffer for the whole open/read/close session.
    using ReadCallback = foundation::FixedFunction<
        void(const std::uint8_t*, std::uint32_t)>;
    using FaultCallback = foundation::FixedFunction<void(std::int32_t)>;
    // Fired from the read thread when ClearCommError reports a new line error
    // (or a rising flow-control hold). Not called on a quiet poll, so a healthy
    // line never enters this path.
    using LineStatusCallback =
        foundation::FixedFunction<void(const SerialLineStatus&)>;

    WinSerialBackend() noexcept;
    ~WinSerialBackend();
    WinSerialBackend(const WinSerialBackend&) = delete;
    WinSerialBackend& operator=(const WinSerialBackend&) = delete;

    [[nodiscard]] bool open(const SerialPortOptions& options,
                            ReadCallback on_read,
                            FaultCallback on_fault,
                            LineStatusCallback on_line_status,
                            std::int32_t& error) noexcept;
    void close() noexcept;

    // `line_status` is optional (nullptr to ignore). On a timeout it is filled
    // with the kLineStatus* bits sampled from the port's COMSTAT *before* the
    // failed transmit is cancelled, so the caller can name the stall cause; on
    // any other outcome it is set to 0.
    [[nodiscard]] bool write(const std::uint8_t* data, std::uint16_t size,
                             std::uint32_t timeout_ms, std::uint32_t& written,
                             std::int32_t& error,
                             std::uint32_t* line_status = nullptr) noexcept;

    // Bounded TX drain for teardown: if a WriteFile is still pending, wait up to
    // kTxDrainGraceMs for it to complete so the peer receives a whole frame,
    // then cancel. Never blocks longer than the grace. See the implementation
    // for the trade-off with an immediate CancelIoEx.
    void abort_pending_write() noexcept;

    // Manual modem-line control. `asserted` is the physical pin state the UI
    // exposes: true drives the line active (EscapeCommFunction SETxxx), false
    // drives it inactive (CLRxxx). Safe to call from any thread while the port
    // is open; no-ops once it has closed.
    //
    // Under RTS/CTS hardware flow control the driver owns RTS
    // (fRtsControl = RTS_CONTROL_HANDSHAKE), so set_rts() is a no-op then.
    void set_rts(bool asserted) noexcept;
    void set_dtr(bool asserted) noexcept;

    [[nodiscard]] bool is_open() const noexcept;


private:
    [[nodiscard]] bool configure(const SerialPortOptions& options,
                                 std::int32_t& error) noexcept;
    void read_loop() noexcept;
    void report_fault(std::int32_t error) noexcept;
    // Samples COMSTAT.fCtsHold/fDsrHold/fXoffHold into the kLineStatus* bits.
    // Only called from the write path on a timeout; the read_loop's own line
    // error monitoring is a separate ClearCommError caller.
    void capture_line_status(std::uint32_t* out) noexcept;
    // Clears the driver's line-error latch and, when a new CE_* flag or a
    // rising flow-control hold is present, reports it through on_line_status_.
    // Called from the read thread after each completed read, never concurrently
    // with itself.
    void poll_line_status() noexcept;

    foundation::UniqueHandle port_;
    foundation::UniqueHandle read_event_;
    foundation::UniqueHandle write_event_;
    foundation::UniqueHandle stop_event_;
    OVERLAPPED read_overlapped_{};
    OVERLAPPED write_overlapped_{};
    ReadCallback on_read_;
    FaultCallback on_fault_;
    LineStatusCallback on_line_status_;
    std::thread read_thread_;
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> open_{false};
    // True while a WriteFile is pending on write_overlapped_. Lets the bounded
    // teardown drain distinguish "a frame is in flight, give it grace" from
    // "nothing to drain, cancel immediately". Set on ERROR_IO_PENDING and
    // cleared once the overlapped result has been reaped.
    std::atomic<bool> write_in_flight_{false};
    // True while the DCB programs fRtsControl = RTS_CONTROL_HANDSHAKE, i.e.
    // RTS/CTS flow control owns the RTS pin and manual set_rts() must defer.
    std::atomic<bool> rts_handshake_{false};
    // Read-thread-only edge state for poll_line_status(): the hold bits seen on
    // the previous poll, so a steady CTS/XOFF handshake does not re-report.
    // Arming happens in open() before the read thread starts, so no concurrent
    // access is possible.
    std::uint32_t last_holds_ = 0U;
};

}  // namespace xcom

#endif  // XCOM_SERIAL_BACKEND_WIN_HPP_
