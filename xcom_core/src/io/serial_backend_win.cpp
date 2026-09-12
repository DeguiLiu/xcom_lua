// serial_backend_win.cpp - minimal coact-bound Win32 serial I/O adapter.
// SPDX-License-Identifier: MIT
#include "serial_backend_win.hpp"

#include <array>
#include <string>
#include <utility>

#include "foundation/text.hpp"

#include <winreg.h>

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
// second CreateFileW fail with ERROR_ACCESS_DENIED. That failure path is
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
        return GetLastError() == ERROR_ACCESS_DENIED;
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

void WinSerialBackend::set_rts(bool asserted) noexcept
{
    if (!port_.valid()) {
        return;
    }
    if (rts_handshake_.load(std::memory_order_acquire)) {
        return;   // driver owns RTS under RTS/CTS flow control
    }
    EscapeCommFunction(port_.get(), asserted ? SETRTS : CLRRTS);
}

void WinSerialBackend::set_dtr(bool asserted) noexcept
{
    if (port_.valid()) {
        EscapeCommFunction(port_.get(), asserted ? SETDTR : CLRDTR);
    }
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
    dcb.fRtsControl = handshake
                          ? RTS_CONTROL_HANDSHAKE
                          : (options.rts_enabled ? RTS_CONTROL_ENABLE
                                                 : RTS_CONTROL_DISABLE);
    dcb.fDtrControl = options.dtr_enabled ? DTR_CONTROL_ENABLE
                                          : DTR_CONTROL_DISABLE;
    dcb.fOutX = options.flow_control == 2U;
    dcb.fInX = options.flow_control == 2U;
    if (SetCommState(port_.get(), &dcb) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
    }
    rts_handshake_.store(handshake, std::memory_order_release);
    // Pin the requested levels explicitly. The DCB DISABLE value's pin
    // behavior is driver-dependent, so without this replay a board can be
    // left held in reset (DTR asserted) or in BOOT (RTS asserted). In HANDSHAKE
    // mode the driver owns RTS and SETRTS/CLRRTS must not be issued against it.
    EscapeCommFunction(port_.get(), options.dtr_enabled ? SETDTR : CLRDTR);
    if (!handshake) {
        EscapeCommFunction(port_.get(), options.rts_enabled ? SETRTS : CLRRTS);
    }
    COMMTIMEOUTS timeouts{};
    timeouts.ReadIntervalTimeout = MAXDWORD;
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
        // thread (and close()'s join) forever. Returning here is safe: the read
        // thread touches only stack state after this point, so nothing dangles
        // even though close() is about to reset the handles and the backend.
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
        if (wait == WAIT_OBJECT_0 || stop_requested_.load(std::memory_order_acquire)) {
            return;
        }
        if (wait != WAIT_OBJECT_0 + 1U ||
            GetOverlappedResult(port_.get(), &read_overlapped_, &received, FALSE) == FALSE) {
            const DWORD result_error = GetLastError();
            if (!stop_requested_.load(std::memory_order_acquire) &&
                result_error != ERROR_OPERATION_ABORTED) {
                report_fault(static_cast<std::int32_t>(result_error));
                open_.store(false, std::memory_order_release);
            }
            return;
        }
        poll_line_status();
        if (received != 0U && on_read_) {
            on_read_(buffer.data(), received);
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
