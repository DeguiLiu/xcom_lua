// serial_backend_win.cpp - minimal coact-bound Win32 serial I/O adapter.
// SPDX-License-Identifier: MIT
#include "serial_backend_win.hpp"

#include <array>
#include <cstring>
#include <string>
#include <utility>

#include "foundation/text.hpp"

#include <winreg.h>
// SetupAPI is the read-only PnP view of the device tree. Used ONLY during
// enumeration to read SPDRP_HARDWAREID for an already-known COMx; it never
// opens the port (no CreateFileW, SetCommState, EscapeCommFunction or I/O).
// initguid.h instantiates GUID_DEVCLASS_PORTS in this TU so the device-class
// GUID needs no extra import library.
#include <initguid.h>
#include <devguid.h>
#include <setupapi.h>

// winerror.h, included by <windows.h>, names this canonical "another process
// holds the device" status as 32. The Linux syntax-check stub in
// tools/win32-stub models only the Win32 surface this TU used before, so spell
// the documented value as a fallback there; a real Windows build uses the SDK
// macro unchanged.
#ifndef ERROR_SHARING_VIOLATION
#define ERROR_SHARING_VIOLATION 32U
#endif

namespace xcom {
namespace {

constexpr std::uint32_t kReadChunkBytes = 4096U;

// Grace period granted to a cancelled read before the read thread gives up and
// exits. Only armed once stop_requested_ is set, so a healthy session waits
// indefinitely (zero overhead) and only teardown is bounded. A driver that
// honours CancelIoEx signals read_event_ well inside this; one that does not
// (wedge, USB stack stuck mid-IRP) would otherwise hold the read thread — and
// therefore close()'s join — forever.
constexpr DWORD kCancelledReadGraceMs = 1500U;

std::wstring utf8_to_wide(std::string_view text)
{
    if (text.empty()) {
        return {};
    }
    const int required = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
                                              text.data(),
                                              static_cast<int>(text.size()),
                                              nullptr, 0);
    if (required <= 0) {
        return {};
    }
    std::wstring result(static_cast<std::size_t>(required), L'\0');
    if (MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, text.data(),
                            static_cast<int>(text.size()), result.data(),
                            required) != required) {
        return {};
    }
    return result;
}

BYTE map_stop_bits(std::uint8_t value) noexcept
{
    switch (value) {
    case 1U: return ONE5STOPBITS;
    case 2U: return TWOSTOPBITS;
    default: return ONESTOPBIT;
    }
}

BYTE map_parity(std::uint8_t value) noexcept
{
    switch (value) {
    case 1U: return ODDPARITY;
    case 2U: return EVENPARITY;
    case 3U: return MARKPARITY;
    case 4U: return SPACEPARITY;
    default: return NOPARITY;
    }
}

// Full pre-open validation. Mirrors the ABI layer's range checks and adds the
// data-bits/stop-bits cross-check the Win32 DCB does not enforce: the driver
// coerces an illegal 1.5-stop-bit / 8-data-bit word to 1 stop bit instead of
// failing, so it has to be rejected here or open() would bless a port that is
// not on the wire. Runs before CreateFileW so an invalid request never opens
// (and never pulses DTR on) the device.
bool validate_serial_options(const SerialPortOptions& options,
                             std::int32_t& error) noexcept
{
    if (options.baud == 0U || options.parity > 4U ||
        options.flow_control > 2U) {
        error = ERROR_INVALID_PARAMETER;
        return false;
    }
    if (!valid_line_format(options.data_bits, options.stop_bits)) {
        error = ERROR_INVALID_PARAMETER;
        return false;
    }
    // Reject an out-of-range drive state before CreateFileW. The ABI layer already
    // refuses raw values above LeaveAlone (XCOM_ERR_PARAM); this is the
    // defence-in-depth that guarantees no later stage can static_cast a stray
    // value into a DCB write or an EscapeCommFunction call.
    if (!valid_line_drive(options.dtr_drive) ||
        !valid_line_drive(options.rts_drive)) {
        error = ERROR_INVALID_PARAMETER;
        return false;
    }
    return true;
}

// Occupancy probe for enumeration (see enumerate_serial_ports_ex).
//
// STABILITY: this is OPT-IN and is NEVER invoked by default. A plain
// CreateFileW still delivers an open IRP and some USB-UART bridges
// (CP210x/CH340 and Arduino auto-reset circuits) drive DTR low on open, which
// can reset a running target board. The default enumeration path therefore
// passes probe_busy == false and leaves XcomPortInfo.busy at 0; the caller must
// explicitly request XCOM_LIST_PORTS_PROBE_BUSY to accept that risk.
//
// When it is requested: a COM port held by another handle that asked for
// exclusive access (dwShareMode 0, what every serial terminal uses) makes a
// second CreateFileW fail with ERROR_ACCESS_DENIED (or, on some filter /
// redirector drivers, ERROR_SHARING_VIOLATION). That failure path is
// completely side-effect free: no handle is ever returned for the busy port.
// On the success path (port free) the handle is closed immediately. This
// helper performs NO I/O and does NOT call SetCommState or EscapeCommFunction:
// without a DCB update the driver is never asked to program fDtrControl /
// fRtsControl, so no IOCTL_SERIAL_SET_DTR / SET_RTS is issued from here. The
// residual open-time DTR behaviour above is driver-owned and cannot be
// suppressed from user mode, which is why the default stays safe.
bool probe_port_busy(const char* port_name) noexcept
{
    if (port_name == nullptr || port_name[0] == '\0') {
        return false;
    }
    std::wstring device = utf8_to_wide(port_name);
    if (device.empty()) {
        return false;
    }
    if (device.rfind(L"\\\\.\\", 0U) != 0U) {
        device.insert(0U, L"\\\\.\\");
    }
    HANDLE probe = CreateFileW(device.c_str(), GENERIC_READ | GENERIC_WRITE,
                               0U, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                               nullptr);
    if (probe == INVALID_HANDLE_VALUE) {
        // A port held by another handle that asked for exclusive access
        // (dwShareMode 0) normally fails with ERROR_ACCESS_DENIED, but some
        // filter/redirector drivers surface the same occupancy as
        // ERROR_SHARING_VIOLATION (32). Classifying only ACCESS_DENIED made
        // the opt-in probe report such a port as free, so the user only found
        // out when the open itself failed. Both codes mean "in use".
        const DWORD open_error = GetLastError();
        return open_error == ERROR_ACCESS_DENIED ||
               open_error == ERROR_SHARING_VIOLATION;
    }
    CloseHandle(probe);
    return false;
}

}  // namespace

WinSerialBackend::WinSerialBackend() noexcept = default;

WinSerialBackend::~WinSerialBackend()
{
    close();
}

bool WinSerialBackend::open(const SerialPortOptions& options,
                            ReadCallback on_read,
                            FaultCallback on_fault,
                            LineStatusCallback on_line_status,
                            std::int32_t& error) noexcept
{
    close();
    error = ERROR_SUCCESS;
    if (!validate_serial_options(options, error)) {
        return false;
    }
    try {
        std::wstring device = utf8_to_wide(options.port_name);
        if (device.empty()) {
            error = ERROR_INVALID_PARAMETER;
            return false;
        }
        if (device.rfind(L"\\\\.\\", 0U) != 0U) {
            device.insert(0U, L"\\\\.\\");
        }
        port_.reset(CreateFileW(device.c_str(), GENERIC_READ | GENERIC_WRITE,
                                0U, nullptr, OPEN_EXISTING,
                                FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OVERLAPPED,
                                nullptr));
        if (!port_.valid()) {
            error = static_cast<std::int32_t>(GetLastError());
            return false;
        }
        read_event_.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        write_event_.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        stop_event_.reset(CreateEventW(nullptr, TRUE, FALSE, nullptr));
        if (!read_event_.valid() || !write_event_.valid() || !stop_event_.valid()) {
            error = static_cast<std::int32_t>(GetLastError());
            close();
            return false;
        }
        read_overlapped_ = OVERLAPPED{};
        write_overlapped_ = OVERLAPPED{};
        read_overlapped_.hEvent = read_event_.get();
        write_overlapped_.hEvent = write_event_.get();
        if (!configure(options, error)) {
            close();
            return false;
        }
        on_read_ = std::move(on_read);
        on_fault_ = std::move(on_fault);
        on_line_status_ = std::move(on_line_status);
        last_holds_ = 0U;
        stop_requested_.store(false, std::memory_order_release);
        open_.store(true, std::memory_order_release);
        read_thread_ = std::thread(&WinSerialBackend::read_loop, this);
        return true;
    }
    catch (...) {
        error = ERROR_NOT_ENOUGH_MEMORY;
        close();
        return false;
    }
}

void WinSerialBackend::close() noexcept
{
    stop_requested_.store(true, std::memory_order_release);
    if (stop_event_.valid()) {
        SetEvent(stop_event_.get());
    }
    if (port_.valid()) {
        CancelIoEx(port_.get(), &read_overlapped_);
        CancelIoEx(port_.get(), &write_overlapped_);
    }
    if (read_thread_.joinable()) {
        // Join, bounded in practice rather than in this call: the read loop
        // arms its own kCancelledReadGraceMs timeout once stop_requested_ is
        // set, so a driver that ignores CancelIoEx releases the thread instead
        // of blocking teardown forever. stop_requested_ is already published
        // above, so the loop cannot re-enter an infinite wait.
        //
        // We still do not detach. The read loop dereferences port_,
        // read_event_ and read_overlapped_ each iteration, and the backend is a
        // by-value member of a static-slot CoreState that destroy() recycles, so
        // a still-running thread could touch freed memory. The in-thread timeout
        // above is what makes the join terminate, without needing shared
        // ownership.
        read_thread_.join();
    }
    on_read_ = {};
    on_fault_ = {};
    on_line_status_ = {};
    open_.store(false, std::memory_order_release);
    // No write can be in flight once the writer has been joined; clear the flag
    // so a later reopen's teardown does not wait on a stale session's event.
    write_in_flight_.store(false, std::memory_order_release);
    port_.reset();
    read_event_.reset();
    write_event_.reset();
    stop_event_.reset();
    read_overlapped_ = OVERLAPPED{};
    write_overlapped_ = OVERLAPPED{};
}

bool WinSerialBackend::write(const std::uint8_t* data, std::uint16_t size,
                             std::uint32_t timeout_ms, std::uint32_t& written,
                             std::int32_t& error,
                             std::uint32_t* line_status) noexcept
{
    written = 0U;
    error = ERROR_SUCCESS;
    if (line_status != nullptr) {
        *line_status = 0U;
    }
    if (!open_.load(std::memory_order_acquire) || !port_.valid() ||
        data == nullptr || size == 0U) {
        error = ERROR_INVALID_PARAMETER;
        return false;
    }
    ResetEvent(write_event_.get());
    DWORD native_written = 0U;
    if (WriteFile(port_.get(), data, size, &native_written, &write_overlapped_) != FALSE) {
        written = native_written;
        return written == size;
    }
    const DWORD pending_error = GetLastError();
    if (pending_error != ERROR_IO_PENDING) {
        error = static_cast<std::int32_t>(pending_error);
        return false;
    }
    write_in_flight_.store(true, std::memory_order_release);
    const DWORD wait = WaitForSingleObject(write_event_.get(), timeout_ms);
    if (wait != WAIT_OBJECT_0) {
        // Gap B: sample COMSTAT before cancelling, while the port still reflects
        // the stall. fCtsHold/fXoffHold tell "peer not ready / peer paused"
        // apart from a genuinely full TX path, instead of reporting a bare
        // ERROR_TIMEOUT the UI cannot explain.
        if (wait == WAIT_TIMEOUT) {
            capture_line_status(line_status);
        }
        CancelIoEx(port_.get(), &write_overlapped_);
        static_cast<void>(WaitForSingleObject(write_event_.get(), 200U));
        error = wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : static_cast<std::int32_t>(GetLastError());
        write_in_flight_.store(false, std::memory_order_release);
        return false;
    }
    const BOOL reaped =
        GetOverlappedResult(port_.get(), &write_overlapped_, &native_written, FALSE);
    write_in_flight_.store(false, std::memory_order_release);
    if (reaped == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    written = native_written;
    if (written != size) {
        error = ERROR_WRITE_FAULT;
        return false;
    }
    return true;
}

void WinSerialBackend::abort_pending_write() noexcept
{
    if (!port_.valid()) {
        return;
    }
    // Bounded TX drain (gap A). Cancelling an in-flight transmit can leave the
    // peer holding a half-frame, which is enough to wedge a firmware
    // bootloader, so teardown first gives an already-started frame a short
    // grace to finish. The wait is bounded by kTxDrainGraceMs, therefore
    // close/join is held for at most that grace plus the OS cancel; if no write
    // is pending this is a plain CancelIoEx no-op exactly as before. On a clean
    // drain the writer thread reaps the overlapped result itself, so we must
    // NOT cancel under it here.
    if (write_in_flight_.load(std::memory_order_acquire)) {
        const DWORD drained = WaitForSingleObject(write_event_.get(),
                                                  kTxDrainGraceMs);
        if (drained == WAIT_OBJECT_0) {
            return;
        }
    }
    CancelIoEx(port_.get(), &write_overlapped_);
}

void WinSerialBackend::capture_line_status(std::uint32_t* out) noexcept
{
    if (out == nullptr) {
        return;
    }
    *out = 0U;
    if (!port_.valid()) {
        return;
    }
    COMSTAT stat{};
    DWORD errors = 0U;
    if (ClearCommError(port_.get(), &errors, &stat) == FALSE) {
        return;
    }
    if (stat.fCtsHold != 0U) {
        *out |= kLineStatusCtsHold;
    }
    if (stat.fDsrHold != 0U) {
        *out |= kLineStatusDsrHold;
    }
    if (stat.fXoffHold != 0U) {
        *out |= kLineStatusXoffHold;
    }
}

LineApplyResult WinSerialBackend::set_rts(bool asserted) noexcept
{
    if (!port_.valid()) {
        return LineApplyResult::Closed;
    }
    if (rts_handshake_.load(std::memory_order_acquire)) {
        // Driver owns RTS under RTS/CTS. Deliberately not applied, and NOT a
        // failure: the caller must still be told so it does not display an RTS
        // change that never reached the pin.
        return LineApplyResult::DriverOwned;
    }
    if (EscapeCommFunction(port_.get(), asserted ? SETRTS : CLRRTS) == FALSE) {
        return LineApplyResult::Failed;
    }
    return LineApplyResult::Applied;
}

LineApplyResult WinSerialBackend::set_dtr(bool asserted) noexcept
{
    if (!port_.valid()) {
        return LineApplyResult::Closed;
    }
    if (EscapeCommFunction(port_.get(), asserted ? SETDTR : CLRDTR) == FALSE) {
        return LineApplyResult::Failed;
    }
    return LineApplyResult::Applied;
}

bool WinSerialBackend::is_open() const noexcept
{
    return open_.load(std::memory_order_acquire);
}

bool WinSerialBackend::configure(const SerialPortOptions& options,
                                 std::int32_t& error) noexcept
{
    if (SetupComm(port_.get(), kReadChunkBytes, kReadChunkBytes) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    DCB dcb{};
    dcb.DCBlength = sizeof(dcb);
    if (GetCommState(port_.get(), &dcb) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    dcb.BaudRate = options.baud;
    dcb.ByteSize = options.data_bits;
    dcb.StopBits = map_stop_bits(options.stop_bits);
    dcb.Parity = map_parity(options.parity);
    dcb.fBinary = TRUE;
    dcb.fParity = options.parity != 0U;
    const bool handshake = options.flow_control == 1U;
    dcb.fOutxCtsFlow = handshake ? TRUE : FALSE;
    // LeaveAlone selects the DISABLE encoding: among the three DCB line-control
    // values it is the only one that does not actively assert the pin.
    // LIMITATION: DISABLE is not "leave the line floating". Windows has no
    // high-impedance modem-control setting, and some drivers still present a
    // level for DISABLE, so this cannot guarantee the pin is untouched during
    // SetCommState. It only avoids the SETxxx assertion we would otherwise
    // request; the true open-time behaviour is driver-owned.
    dcb.fRtsControl = handshake
                          ? RTS_CONTROL_HANDSHAKE
                          : (options.rts_drive == LineDrive::Assert
                                 ? RTS_CONTROL_ENABLE
                                 : RTS_CONTROL_DISABLE);
    dcb.fDtrControl = options.dtr_drive == LineDrive::Assert
                          ? DTR_CONTROL_ENABLE
                          : DTR_CONTROL_DISABLE;
    dcb.fOutX = options.flow_control == 2U;
    dcb.fInX = options.flow_control == 2U;
    // A line error must NOT tear down the read IRP. The reset value is
    // driver-specific; with fAbortOnError TRUE a framing/overrun error aborts
    // the pending ReadFile, which surfaces in read_loop as a failed overlapped
    // completion and would make the reader classify an ordinary line glitch as a
    // fatal fault. Keep it FALSE so errors arrive through the ClearCommError
    // latch the read loop already polls.
    dcb.fAbortOnError = FALSE;
    if (SetCommState(port_.get(), &dcb) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    // Verify the driver honoured the DCB before trusting the port. SetCommState
    // succeeds even when the hardware cannot provide the request: a USB bridge
    // silently rounds an unsupported baud (e.g. 250000), and 1.5 stop bits with
    // 8 data bits is coerced to 1 stop bit. Reading the DCB back is the only way
    // to tell "configured as asked" from "configured as the driver felt like",
    // and comparing exactly the fields programmed above catches the coercion
    // instead of reporting a lie. DCBlength must be set or GetCommState fails.
    DCB verified{};
    verified.DCBlength = sizeof(verified);
    if (GetCommState(port_.get(), &verified) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    if (verified.BaudRate != dcb.BaudRate || verified.ByteSize != dcb.ByteSize ||
        verified.StopBits != dcb.StopBits || verified.Parity != dcb.Parity ||
        verified.fBinary != dcb.fBinary || verified.fParity != dcb.fParity ||
        verified.fOutxCtsFlow != dcb.fOutxCtsFlow ||
        verified.fRtsControl != dcb.fRtsControl ||
        verified.fDtrControl != dcb.fDtrControl || verified.fOutX != dcb.fOutX ||
        verified.fInX != dcb.fInX ||
        verified.fAbortOnError != dcb.fAbortOnError) {
        error = ERROR_NOT_SUPPORTED;
        return false;
    }
    rts_handshake_.store(handshake, std::memory_order_release);
    // Pin the requested levels explicitly. The DCB DISABLE value's pin
    // behavior is driver-dependent, so without this replay a board can be
    // left held in reset (DTR asserted) or in BOOT (RTS asserted). In HANDSHAKE
    // mode the driver owns RTS and SETRTS/CLRRTS must not be issued against it.
    //
    // LeaveAlone skips the replay for that line: no SETxxx/CLRxxx is issued, so
    // the only remaining open-time influence is the DCB value programmed above
    // and whatever CreateFileW itself did. LIMITATION: this removes OUR
    // transition, not every possible one - a bridge that asserts DTR on the open
    // IRP is outside user-mode control. Whether a target stops resetting must be
    // verified on hardware; it is not claimed here.
    //
    // The result is deliberately ignored here: the DCB above already programmed
    // the level, so a redundant-IOCTL failure must not fail an otherwise valid
    // open. That leaves the open-time DTR/BOOT pulse as a KNOWN silent-failure
    // and known target-reset risk (needs real hardware to resolve; tracked
    // separately). set_dtr()/set_rts() are used only so the return is captured
    // rather than discarded at the source - it changes no behaviour.
    if (options.dtr_drive != LineDrive::LeaveAlone) {
        static_cast<void>(set_dtr(options.dtr_drive == LineDrive::Assert));
    }
    if (!handshake && options.rts_drive != LineDrive::LeaveAlone) {
        static_cast<void>(set_rts(options.rts_drive == LineDrive::Assert));
    }
    COMMTIMEOUTS timeouts{};
    // Bounded tick, not the old "return immediately" mode. ReadIntervalTimeout =
    // MAXDWORD combined with zero total-timeout fields makes every ReadFile
    // complete at once (MSDN: "return immediately ... even if no bytes have been
    // received"), so an idle line spun the read loop — and its per-completion
    // ClearCommError — at full CPU. Here no inter-byte gap timeout is used; the
    // total timeout (multiplier 0 * bytes + constant) caps each IRP at
    // kReadTickTimeoutMs, so an idle line completes with 0 bytes about every
    // 50 ms and the loop ticks ~20 Hz instead of spinning. A 0-byte completion
    // therefore costs the full 50 ms, so it cannot busy-loop.
    //
    // Trade-off: up to kReadTickTimeoutMs of added receive latency. That is
    // imperceptible in a console, while the CPU saving is not. The MSDN
    // "MAXDWORD interval + MAXDWORD multiplier + constant" form is deliberately
    // NOT used: it completes as soon as the first buffered byte arrives, which
    // at 921600 baud can mean one completion — and one ClearCommError — per byte.
    timeouts.ReadIntervalTimeout = 0U;
    timeouts.ReadTotalTimeoutMultiplier = 0U;
    timeouts.ReadTotalTimeoutConstant = kReadTickTimeoutMs;
    if (SetCommTimeouts(port_.get(), &timeouts) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    return true;
}

void WinSerialBackend::read_loop() noexcept
{
    SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_ABOVE_NORMAL);
    std::array<std::uint8_t, kReadChunkBytes> buffer{};
    while (!stop_requested_.load(std::memory_order_acquire)) {
        // Liveness: the loop completed an iteration (a read returned, with or
        // without bytes, or a fault is about to be handled). An idle line still
        // reaches here about every 50 ms via the COMMTIMEOUTS read tick, so an
        // old stamp means the thread is stuck inside the driver, not idle.
        if (on_beat_) {
            on_beat_();
        }
        ResetEvent(read_event_.get());
        // Re-zero the OVERLAPPED bookkeeping fields each read. The hEvent
        // member is re-armed below (ResetEvent already cleared the event) and
        // must be preserved across iterations; Internal/InternalHigh/Offset/
        // OffsetHigh are OS-owned per pending operation, so a stale value from
        // a previous read must not leak into the next ReadFile.
        read_overlapped_.Internal = 0UL;
        read_overlapped_.InternalHigh = 0UL;
        read_overlapped_.Offset = 0UL;
        read_overlapped_.OffsetHigh = 0UL;
        DWORD received = 0U;
        const BOOL complete = ReadFile(port_.get(), buffer.data(),
                                       static_cast<DWORD>(buffer.size()),
                                       &received, &read_overlapped_);
        if (complete != FALSE) {
            poll_line_status();
            if (received != 0U && on_read_) {
                on_read_(buffer.data(), received);
            }
            continue;
        }
        const DWORD read_error = GetLastError();
        if (read_error != ERROR_IO_PENDING) {
            if (!stop_requested_.load(std::memory_order_acquire)) {
                report_fault(static_cast<std::int32_t>(read_error));
                // The read thread is exiting, so the port can no longer deliver
                // bytes. Clear open_ here too: the fault path on the Dispatcher
                // also closes the backend (which clears it), but if that close
                // event is lost the handle would otherwise report is_open()
                // true forever and writes/status would keep targeting a dead
                // port.
                open_.store(false, std::memory_order_release);
            }
            return;
        }
        const std::array<HANDLE, 2> waits{stop_event_.get(), read_event_.get()};
        // A healthy session waits indefinitely: the read blocks until the driver
        // completes it or shutdown signals stop_event_. The bounded wait is
        // armed only when a close is already in progress, which is the one case
        // where a driver that ignores CancelIoEx must not be allowed to hold the
        // thread (and close()'s join) forever.
        //
        // LIFETIME: returning after this point is safe because close() joins
        // THIS thread before it resets port_, the event handles or on_read_
        // (see close()). A late on_read_ call below therefore still targets
        // live objects; the callback itself re-checks the runtime's admission
        // gate, so a delivery racing teardown is either ingested or explicitly
        // refused there, never dereferenced after free.
        const DWORD wait_timeout = stop_requested_.load(std::memory_order_acquire)
                                       ? kCancelledReadGraceMs
                                       : INFINITE;
        const DWORD wait = WaitForMultipleObjects(static_cast<DWORD>(waits.size()),
                                                   waits.data(), FALSE, wait_timeout);
        if (wait == WAIT_TIMEOUT) {
            // The driver never released the pending IRP. Record it and let the
            // thread exit so teardown can proceed; the port is being closed
            // anyway, so leaving the IRP outstanding costs nothing.
            if (on_fault_) {
                on_fault_(static_cast<std::int32_t>(ERROR_OPERATION_ABORTED));
            }
            open_.store(false, std::memory_order_release);
            return;
        }
        // stop_event_ is index 0 and read_event_ is index 1. WaitForMultipleObjects
        // reports the LOWEST signaled index, so a stop that races a completion
        // returns WAIT_OBJECT_0 even though read_event_ is ALSO set. Decide from
        // the read event itself, not from the raw wait code: a completed read
        // must be reaped and delivered before returning, in both the
        // simultaneous ("both signaled") and the read-first cases.
        const bool read_completed =
            (wait == WAIT_OBJECT_0 + 1U) ||
            ((wait == WAIT_OBJECT_0) &&
             (WaitForSingleObject(read_event_.get(), 0U) == WAIT_OBJECT_0));
        if (!read_completed) {
            // stop_event_ alone: the IRP is still pending (close() has already
            // issued CancelIoEx) and no bytes completed, so there is nothing to
            // reap. Any other result is WAIT_FAILED: no object was signaled and
            // no operation completed, so `received` still holds this iteration's
            // initial zero and must not be delivered. GetLastError() belongs to
            // the failed wait; a deliberate teardown must not be reported as a
            // device fault.
            const bool wait_failed =
                (wait != WAIT_OBJECT_0) && (wait != WAIT_OBJECT_0 + 1U);
            if (wait_failed &&
                !stop_requested_.load(std::memory_order_acquire)) {
                report_fault(static_cast<std::int32_t>(GetLastError()));
                open_.store(false, std::memory_order_release);
            }
            return;
        }
        // read_event_ is set: the kernel has completed the read IRP,
        // successfully or not. That is the ONLY condition under which `received`
        // is safe to consume — GetOverlappedResult copies the transferred count
        // out of the just-completed OVERLAPPED, so it can be neither a torn count
        // nor a stale one from a previous iteration. On a failed completion a
        // driver may still report the partial count the kernel moved before the
        // error (line error, abort, surprise removal); those bytes must reach
        // on_read_ instead of being silently discarded.
        const BOOL reaped =
            GetOverlappedResult(port_.get(), &read_overlapped_, &received, FALSE);
        const DWORD result_error =
            reaped != FALSE ? ERROR_SUCCESS : GetLastError();
        // A failed completion is not obliged to bound the count by the request;
        // clamp so on_read_ can never be handed more than `buffer` holds.
        if (received > static_cast<DWORD>(buffer.size())) {
            received = static_cast<DWORD>(buffer.size());
        }
        if (reaped != FALSE) {
            poll_line_status();
        }
        // Deliver any transferred bytes FIRST, before the fault is reported. The
        // fault path below (and the Dispatcher that consumes it) tears the
        // session down, so bytes delivered afterwards would be lost with it.
        if (received != 0U && on_read_) {
            on_read_(buffer.data(), received);
        }
        if (reaped == FALSE) {
            // Any failure here is reported, including ERROR_OPERATION_ABORTED.
            // The only place this backend cancels the read IRP is close(), and
            // it publishes stop_requested_ before calling CancelIoEx, so a
            // deliberate teardown is already filtered by the guard above. An
            // abort that arrives with stop_requested_ still false therefore
            // means the DRIVER dropped the IRP (surprise removal / USB
            // re-enumeration). Suppressing it would exit this thread without
            // raising a fault while open_ stayed true, leaving a session that
            // reports OPEN with no reader forever.
            if (!stop_requested_.load(std::memory_order_acquire)) {
                report_fault(static_cast<std::int32_t>(result_error));
                open_.store(false, std::memory_order_release);
            }
            return;
        }
        if (stop_requested_.load(std::memory_order_acquire)) {
            // The completion reaped above was raced by a stop (or discovered
            // behind one); its bytes were delivered before this point. Honour
            // the stop now. Safe to return: close() is still blocked in its
            // join and has not yet reset port_, the event handles or on_read_.
            return;
        }
    }
}

void WinSerialBackend::report_fault(std::int32_t error) noexcept
{
    if (on_fault_) {
        on_fault_(error);
    }
}

void WinSerialBackend::poll_line_status() noexcept
{
    if (!port_.valid() || !on_line_status_) {
        return;
    }
    COMSTAT stat{};
    DWORD errors = 0U;
    if (ClearCommError(port_.get(), &errors, &stat) == FALSE) {
        return;
    }
    // Fold the four COMSTAT hold flags into the same bit space the write path
    // uses for kLineStatus*, plus an Rlsd bit, so the edge comparison is one
    // value. Rlsd has no write-stall constant (a receive-side suspension).
    std::uint32_t holds = 0U;
    if (stat.fCtsHold != 0U) {
        holds |= kLineStatusCtsHold;
    }
    if (stat.fDsrHold != 0U) {
        holds |= kLineStatusDsrHold;
    }
    if (stat.fXoffHold != 0U) {
        holds |= kLineStatusXoffHold;
    }
    if (stat.fRlsdHold != 0U) {
        holds |= (1U << 3U);   // kLineStatusRlsdHold
    }
    // CE_TXFULL and COMSTAT.fXoffSent deliberately get no dedicated category.
    // CE_TXFULL is a transmit-side "queue full" condition, not a receive
    // overrun, so folding it into overrun_errors would misreport data loss; it
    // is still carried verbatim in SerialLineStatus.error_flags because the
    // poll fires on any nonzero error mask. fXoffSent means the driver sent an
    // XOFF to the peer (receive backpressure) and is distinct from fXoffHold
    // (peer paused us); SerialLineStatus has no backpressure field and the
    // runtime's rx_backpressure counter is fed elsewhere, so surfacing it would
    // need a runtime change outside this backend. Recorded as a known
    // observability gap rather than a counter nobody reads.
    const bool hold_edge = holds != last_holds_;
    last_holds_ = holds;
    if (errors == 0U && (!hold_edge || holds == 0U)) {
        return;   // quiet line, or a hold release: nothing worth reporting
    }
    SerialLineStatus status{};
    status.error_flags = static_cast<std::uint32_t>(errors);
    if ((errors & CE_FRAME) != 0U) {
        status.framing_errors = 1U;
    }
    if ((errors & CE_RXPARITY) != 0U) {
        status.parity_errors = 1U;
    }
    if ((errors & (CE_RXOVER | CE_OVERRUN)) != 0U) {
        status.overrun_errors = 1U;
    }
    if ((errors & CE_BREAK) != 0U) {
        status.break_events = 1U;
    }
    status.hold_events = (hold_edge && holds != 0U) ? 1U : 0U;
    status.cb_in_que = static_cast<std::uint32_t>(stat.cbInQue);
    status.cb_out_que = static_cast<std::uint32_t>(stat.cbOutQue);
    on_line_status_(status);
}

// ---------------------------------------------------------------------------
// Serial-port enumeration (registry-backed). The value names of the
// HARDWARE\DEVICEMAP\SERIALCOMM key are friendlier device descriptions while
// the REG_SZ values carry the COMx names. All Win32 registry types are
// confined to this TU; the public signature is pure C++.
// ---------------------------------------------------------------------------

// One (COMx -> stable PnP hardware id) mapping read from the device tree.
// `port` is the COMx as reported by the device's Device Parameters\PortName
// value (the same name SERIALCOMM carries); `hardware_id` is the first string
// of the SPDRP_HARDWAREID REG_MULTI_SZ, or empty when the property is absent.
struct PortHardwareId final {
    std::array<char, 64U> port{};
    std::array<char, 96U> hardware_id{};   // XcomPortInfo.hardware_id
};

constexpr std::uint32_t kMaxPortHardwareIds = 64U;

// Build the COMx -> hardware-id table from the PnP device tree.
//
// STABILITY: this is a REGISTRY/PROPERTY READ ONLY. It enumerates the Ports
// setup class and, per device, opens that device's "Device Parameters" registry
// key to read PortName and calls SetupDiGetDeviceRegistryPropertyA for
// SPDRP_HARDWAREID. It never opens the serial port: no CreateFileW, no
// SetCommState, no EscapeCommFunction, no I/O. Enumeration therefore cannot
// pulse DTR/RTS or reset the target board, which is why it runs on the default
// (non-probe) path.
//
// A missing SPDRP_HARDWAREID is expected for some composite/virtual ports and
// is NOT an error: the entry is returned with an empty hardware_id so the
// caller falls back to description matching.
std::uint32_t collect_port_hardware_ids(PortHardwareId* out,
                                        std::uint32_t capacity) noexcept
{
    if (out == nullptr || capacity == 0U) {
        return 0U;
    }
    HDEVINFO devices = SetupDiGetClassDevsA(&GUID_DEVCLASS_PORTS, nullptr,
                                            nullptr, DIGCF_PRESENT);
    if (devices == INVALID_HANDLE_VALUE) {
        return 0U;
    }
    std::uint32_t found = 0U;
    for (DWORD index = 0U; found < capacity; ++index) {
        SP_DEVINFO_DATA info{};
        info.cbSize = sizeof(info);
        if (SetupDiEnumDeviceInfo(devices, index, &info) == FALSE) {
            break;
        }
        PortHardwareId entry{};
        // PortName lives in the device's Device Parameters key; reading it is a
        // registry read, not a port open.
        HKEY params = SetupDiOpenDevRegKey(devices, &info, DICS_FLAG_GLOBAL, 0U,
                                           DIREG_DEV, KEY_QUERY_VALUE);
        if (params == INVALID_HANDLE_VALUE) {
            continue;   // no Device Parameters key: not a serial port device
        }
        DWORD type = REG_NONE;
        DWORD bytes = static_cast<DWORD>(entry.port.size());
        const LSTATUS rc = RegQueryValueExA(
            params, "PortName", nullptr, &type,
            reinterpret_cast<BYTE*>(entry.port.data()), &bytes);
        RegCloseKey(params);
        if (rc != ERROR_SUCCESS || type != REG_SZ) {
            continue;   // e.g. an LPT port, or a device without a PortName yet
        }
        entry.port[entry.port.size() - 1U] = '\0';

        std::array<BYTE, 512U> raw{};
        DWORD raw_bytes = 0U;
        if (SetupDiGetDeviceRegistryPropertyA(
                devices, &info, SPDRP_HARDWAREID, nullptr, raw.data(),
                static_cast<DWORD>(raw.size()), &raw_bytes) != FALSE) {
            // SPDRP_HARDWAREID is a REG_MULTI_SZ; the first string is the
            // canonical id. copy_first_multi_sz is bounded and NUL-terminates;
            // an absent/empty property leaves hardware_id "".
            copy_first_multi_sz(raw.data(),
                                static_cast<std::uint32_t>(raw.size()),
                                entry.hardware_id.data(),
                                entry.hardware_id.size());
        }
        out[found] = entry;
        ++found;
    }
    SetupDiDestroyDeviceInfoList(devices);
    return found;
}

// Copy the hardware id for `port_name` from the table, or leave an empty string
// when there is no match or the property was absent.
void copy_port_hardware_id(const char* port_name,
                           const PortHardwareId* table, std::uint32_t count,
                           char* out, std::size_t out_size) noexcept
{
    if (out == nullptr || out_size == 0U) {
        return;
    }
    out[0] = '\0';
    if (port_name == nullptr || table == nullptr) {
        return;
    }
    for (std::uint32_t i = 0U; i < count; ++i) {
        if (std::strcmp(table[i].port.data(), port_name) == 0) {
            foundation::copy_text(table[i].hardware_id.data(), out, out_size);
            return;
        }
    }
}

std::uint32_t enumerate_serial_ports_ex(XcomPortInfo* out,
                                        std::uint32_t capacity,
                                        bool probe_busy,
                                        std::int32_t& error)
{
    error = 0;
    HKEY serial_key = nullptr;
    const LSTATUS open_result = RegOpenKeyExA(
        HKEY_LOCAL_MACHINE, "HARDWARE\\DEVICEMAP\\SERIALCOMM", 0U,
        KEY_QUERY_VALUE, &serial_key);
    if (open_result != ERROR_SUCCESS) {
        // SERIALCOMM only exists once at least one COM port has been created, so
        // a missing key is the ordinary "no ports" state, not an enumeration
        // failure. Only surface genuine errors (e.g. access denied) so the UI
        // can tell "no serial ports" from "could not read the port list".
        if (open_result == ERROR_FILE_NOT_FOUND ||
            open_result == ERROR_PATH_NOT_FOUND) {
            return 0U;
        }
        error = static_cast<std::int32_t>(open_result);
        return 0U;
    }

    // Stable-identity lookup. Skipped for the capacity == 0 size query, which
    // must stay free of device-tree work (the ABI size query must not touch a
    // device). Registry-only and non-disturbing, so it runs on the default path.
    std::array<PortHardwareId, kMaxPortHardwareIds> hardware_ids{};
    std::uint32_t hardware_id_count = 0U;
    if (capacity != 0U) {
        hardware_id_count = collect_port_hardware_ids(
            hardware_ids.data(),
            static_cast<std::uint32_t>(hardware_ids.size()));
    }

    std::uint32_t found = 0U;
    for (DWORD native_index = 0U;; ++native_index) {
        std::array<char, 256U> device_name{};
        std::array<char, 64U> port_name{};
        DWORD device_name_size = static_cast<DWORD>(device_name.size() - 1U);
        DWORD port_name_size = static_cast<DWORD>(port_name.size() - 1U);
        DWORD value_type = REG_NONE;
        const LSTATUS value_result = RegEnumValueA(
            serial_key, native_index, device_name.data(), &device_name_size,
            nullptr, &value_type,
            reinterpret_cast<BYTE*>(port_name.data()), &port_name_size);
        if (value_result == ERROR_NO_MORE_ITEMS) {
            break;
        }
        if (value_result != ERROR_SUCCESS) {
            // Preserve the pre-existing enumeration behaviour exactly: skip the
            // unreadable value and keep walking. RegEnumValueA is index-based,
            // so advancing still terminates at ERROR_NO_MORE_ITEMS. Only record
            // the first native status for reporting; enumeration never aborts
            // early because of it.
            if (error == 0) {
                error = static_cast<std::int32_t>(value_result);
            }
            continue;
        }
        if (value_type != REG_SZ) {
            continue;
        }
        device_name[device_name_size] = '\0';
        port_name[port_name_size < port_name.size()
                      ? port_name_size : port_name.size() - 1U] = '\0';
        if (found < capacity) {
            XcomPortInfo& info = out[found];
            info = XcomPortInfo{};
            foundation::copy_text(port_name.data(), info.name, sizeof(info.name));
            foundation::copy_text(device_name.data(), info.description,
                                  sizeof(info.description));
            copy_port_hardware_id(info.name, hardware_ids.data(),
                                  hardware_id_count, info.hardware_id,
                                  sizeof(info.hardware_id));
            // Probe only when a real output slot exists: the capacity == 0 size
            // query must stay side-effect free.
            info.busy = (probe_busy && probe_port_busy(info.name)) ? 1U : 0U;
        }
        ++found;
    }
    RegCloseKey(serial_key);
    return found;
}

// Backward-compatible wrapper for list_ports_impl: no occupancy probe, no error
// propagation. Existing callers keep their exact behaviour.
std::uint32_t enumerate_serial_ports(XcomPortInfo* out, std::uint32_t capacity)
{
    std::int32_t ignored = 0;
    return enumerate_serial_ports_ex(out, capacity, false, ignored);
}

}  // namespace xcom
