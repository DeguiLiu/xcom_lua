// serial_backend_win.hpp - minimal coact-bound Win32 serial I/O adapter.
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_SERIAL_BACKEND_WIN_HPP_
#define XCOM_SERIAL_BACKEND_WIN_HPP_

#include <cstddef>
#include <cstdint>
#include <atomic>
#include <string_view>
#include <thread>
#include <utility>   // std::move

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
// a stalled peer stall shutdown. This is only the write-drain share of teardown;
// the read loop's cancelled-read grace (kCancelledReadGraceMs = 1500 ms,
// serial_backend_win.cpp) adds to it, so the whole backend teardown can hold the
// Dispatcher for up to ~1.7 s. That still fits the ~2000 ms close budget the
// runtime reserves on the exit path (the xcom_ffi.close default timeout). A
// shorter wait does not cover it: core_close defaults to CLOSE_WAIT_MS = 200 ms
// (window.lua), which can return before this grace expires and leaves the close
// to finish asynchronously, with the poll_status CLOSING watchdog covering a
// teardown that never confirms.
inline constexpr std::uint32_t kTxDrainGraceMs = 200U;

// Bounded per-read tick (ms). Each overlapped ReadFile is allowed at most this
// long, so an idle line completes the IRP with 0 bytes roughly every 50 ms
// instead of the read returning immediately and spinning the loop (the old
// ReadIntervalTimeout = MAXDWORD / zero-totals combination). The trade-off is a
// 50 ms ceiling on receive latency; in exchange the read thread never
// busy-polls and the per-completion ClearCommError is bounded to ~20 Hz when
// idle. See configure() for the exact COMMTIMEOUTS triple.
inline constexpr std::uint32_t kReadTickTimeoutMs = 50U;

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

// Extract the first NUL-terminated string of a REG_MULTI_SZ property buffer as
// SetupDiGetDeviceRegistryPropertyA returns SPDRP_HARDWAREID. Pure, bounded (at
// most `out_size - 1` bytes copied, always NUL-terminated), and free of Win32
// types so the hardware-free host test covers the parse without SetupAPI. An
// empty property - which some composite/virtual ports expose - yields "".
inline void copy_first_multi_sz(const std::uint8_t* raw,
                                std::uint32_t raw_bytes, char* out,
                                std::size_t out_size) noexcept
{
    if (out == nullptr || out_size == 0U) {
        return;
    }
    out[0] = '\0';
    if (raw == nullptr) {
        return;
    }
    std::size_t i = 0U;
    while (i + 1U < out_size && i < raw_bytes && raw[i] != 0U) {
        out[i] = static_cast<char>(raw[i]);
        ++i;
    }
    out[i] = '\0';
}

// Enumerate Windows serial ports from the registry
// (HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM). Fills `out` up to its
// caller-provided capacity and returns the total number discovered, preserving
// the XCOM_ERR_FULL ABI contract without an internal fixed-port limit. No
// Win32 types leak past this TU boundary.
//
// Backward-compatible wrapper: never probes occupancy and discards any
// enumeration error (busy stays 0). It DOES fill hardware_id, which is a
// non-disturbing registry read. Prefer enumerate_serial_ports_ex when the
// caller needs the failure reason or the busy flag.
std::uint32_t enumerate_serial_ports(XcomPortInfo* out, std::uint32_t capacity);

// Error-aware / occupancy-aware enumeration.
//
// `error` receives 0 on success, or the native Win32 status (RegOpenKeyExA /
// RegEnumValueA LSTATUS) when the registry enumeration itself failed. A missing
// SERIALCOMM key is the normal "no ports present" state, NOT an error, so it
// returns count 0 with *error == 0.
//
// Every returned entry also carries its stable PnP hardware id
// (XcomPortInfo.hardware_id, v1.6): the first string of SetupAPI
// SPDRP_HARDWAREID for the matching device, or "" when the property is absent
// (expected for some composite/virtual ports). This is a REGISTRY-ONLY property
// read - it NEVER opens the port, programs a DCB, or issues a line IOCTL - so it
// runs on the default path without risking a target reset and gives reconnect a
// key that survives COMx renumbering.
//
// When `probe_busy` is true each discovered port is probed for exclusive
// occupancy: CreateFileW(share mode 0) is attempted and, on success, the handle
// is closed immediately. The probe never calls SetCommState or
// EscapeCommFunction and never performs I/O, so the DCB is not programmed and
// no SET_DTR/SET_RTS IOCTL is issued. A failed probe with
// GetLastError() == ERROR_ACCESS_DENIED (or ERROR_SHARING_VIOLATION, which
// some filter/redirector drivers return for the same exclusive occupancy) sets
// info.busy = 1.
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

// Tri-state modem-line drive requested at open. A bool could only express
// "drive the pin active" or "drive it inactive", and BOTH move a target line
// that a developer may have wired to a control pin (DTR is commonly on an MCU
// NRST/BOOT input), so there was no way to ask the open path to leave the line
// untouched. The numeric values match XcomPortConfig.dtr_enable / rts_enable so
// the ABI-to-backend mapping is a plain static_cast; the enum keeps intent named
// inside the core.
//
// LIMITATION (do not overstate): even LeaveAlone cannot stop CreateFileW itself
// from changing the pin. Some USB-UART bridges (CP210x/CH340 auto-reset
// circuits) drive DTR on the open IRP before any DCB is programmed, which is
// outside user-mode control. LeaveAlone suppresses only the transition THIS
// backend would otherwise issue (SetCommState fDtrControl plus the explicit
// EscapeCommFunction replay). Whether a target actually stops resetting must be
// confirmed on real hardware with a logic analyser on the bridge DTR/RTS and
// the target NRST/BOOT.
enum class LineDrive : std::uint8_t {
    Deassert = 0U,    // drive inactive: CLRxxx, DCB *_CONTROL_DISABLE
    Assert = 1U,      // drive active: SETxxx, DCB *_CONTROL_ENABLE
    LeaveAlone = 2U,  // do not drive: skip EscapeCommFunction (DCB still
                      // programs *_CONTROL_DISABLE, the least-driving value
                      // available, but that is NOT a high-impedance state)
};

// True when `drive` is one of the three defined states. Used by the backend's
// pre-open validation so an out-of-range value can never reach EscapeCommFunction
// or a DCB write. Header-inline, like valid_line_format, so the hardware-free
// host test covers it without an adapter.
[[nodiscard]] inline bool valid_line_drive(LineDrive drive) noexcept
{
    switch (drive) {
    case LineDrive::Deassert:
    case LineDrive::Assert:
    case LineDrive::LeaveAlone:
        return true;
    default:
        return false;
    }
}

struct SerialPortOptions final {
    std::string_view port_name;
    std::uint32_t baud = 0U;
    std::uint8_t data_bits = 8U;
    std::uint8_t stop_bits = 0U;
    std::uint8_t parity = 0U;
    std::uint8_t flow_control = 0U;
    LineDrive dtr_drive = LineDrive::Deassert;
    LineDrive rts_drive = LineDrive::Deassert;
};

// Line-format legality this backend enforces BEFORE opening the port. The Win32
// driver does not reject an illegal request, it silently coerces it (e.g. an
// unsupported baud rounds off, and 1.5 stop bits with 8 data bits becomes 1 stop
// bit), which would make open() report success for a port that was not actually
// configured as asked. 1.5 stop bits exist only for a 5-data-bit word; the
// ABI/config encoding of stop_bits is 0 = 1, 1 = 1.5, 2 = 2. Header-inline so
// the hardware-free host test can cover the cross-check without an adapter.
[[nodiscard]] inline bool valid_line_format(std::uint8_t data_bits,
                                            std::uint8_t stop_bits) noexcept
{
    if (data_bits < 5U || data_bits > 8U) {
        return false;
    }
    if (stop_bits > 2U) {
        return false;
    }
    if (stop_bits == 1U && data_bits != 5U) {
        return false;
    }
    return true;
}

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

// Outcome of one manual modem-line write. A bare void made three different
// outcomes indistinguishable: the pin was driven, the driver owns the pin under
// flow control so the request was deliberately not applied, or the Win32 call
// failed outright. The first must be reported as success and the other two must
// not - reporting a driver-owned or failed write as applied is the false
// success this enum exists to prevent.
enum class LineApplyResult : std::uint8_t {
    Applied = 0U,   // EscapeCommFunction succeeded; the driver accepted the level
    DriverOwned,    // RTS under RTS/CTS: the driver toggles the pin, request skipped
    Failed,         // EscapeCommFunction returned FALSE (e.g. device removed)
    Closed,         // no open port handle
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
    // is open. The caller MUST inspect the result: a failed or driver-owned
    // write must never be surfaced as an applied one.
    //
    // Under RTS/CTS hardware flow control the driver owns RTS
    // (fRtsControl = RTS_CONTROL_HANDSHAKE), so set_rts() returns DriverOwned
    // and issues no IOCTL; set_dtr() is never affected by flow control.
    [[nodiscard]] LineApplyResult set_rts(bool asserted) noexcept;
    [[nodiscard]] LineApplyResult set_dtr(bool asserted) noexcept;

    [[nodiscard]] bool is_open() const noexcept;

    // Liveness sink (design §4.2 item 3): the read loop calls `on_beat` once per
    // iteration - including the ~20 Hz zero-byte completions of an idle line -
    // so the core can tell "quiet line" from "read thread wedged". An empty
    // callback disables the stamp (and keeps this TU free of any coact/clock
    // dependency, so the hardware-free tx_diag_test still links without it). Set
    // by the owner before open(); the callback must outlive the read thread.
    using BeatCallback = foundation::FixedFunction<void()>;
    void set_read_beat(BeatCallback on_beat) noexcept
    {
        on_beat_ = std::move(on_beat);
    }


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
    // Core-installed liveness stamp called once per read-loop iteration; empty
    // until the owner installs it (see set_read_beat).
    BeatCallback on_beat_;
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
