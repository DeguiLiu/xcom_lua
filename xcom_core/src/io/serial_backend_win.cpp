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

}  // namespace

WinSerialBackend::WinSerialBackend() noexcept = default;

WinSerialBackend::~WinSerialBackend()
{
    close();
}

bool WinSerialBackend::open(const SerialPortOptions& options,
                            ReadCallback on_read,
                            FaultCallback on_fault,
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
        read_thread_.join();
    }
    on_read_ = {};
    on_fault_ = {};
    open_.store(false, std::memory_order_release);
    port_.reset();
    read_event_.reset();
    write_event_.reset();
    stop_event_.reset();
    read_overlapped_ = OVERLAPPED{};
    write_overlapped_ = OVERLAPPED{};
}

bool WinSerialBackend::write(const std::uint8_t* data, std::uint16_t size,
                             std::uint32_t timeout_ms, std::uint32_t& written,
                             std::int32_t& error) noexcept
{
    written = 0U;
    error = ERROR_SUCCESS;
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
    const DWORD wait = WaitForSingleObject(write_event_.get(), timeout_ms);
    if (wait != WAIT_OBJECT_0) {
        CancelIoEx(port_.get(), &write_overlapped_);
        static_cast<void>(WaitForSingleObject(write_event_.get(), 200U));
        error = wait == WAIT_TIMEOUT ? ERROR_TIMEOUT : static_cast<std::int32_t>(GetLastError());
        return false;
    }
    if (GetOverlappedResult(port_.get(), &write_overlapped_, &native_written, FALSE) == FALSE) {
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
    if (port_.valid()) {
        CancelIoEx(port_.get(), &write_overlapped_);
    }
}

void WinSerialBackend::set_rts(bool enabled) noexcept
{
    if (port_.valid()) {
        EscapeCommFunction(port_.get(), enabled ? SETRTS : CLRRTS);
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
    dcb.fOutxCtsFlow = options.flow_control == 1U;
    dcb.fRtsControl = options.flow_control == 1U
                          ? RTS_CONTROL_HANDSHAKE
                          : (options.rts_enabled ? RTS_CONTROL_ENABLE : RTS_CONTROL_DISABLE);
    dcb.fDtrControl = options.dtr_enabled ? DTR_CONTROL_ENABLE : DTR_CONTROL_DISABLE;
    dcb.fOutX = options.flow_control == 2U;
    dcb.fInX = options.flow_control == 2U;
    if (SetCommState(port_.get(), &dcb) == FALSE) {
        error = static_cast<std::int32_t>(GetLastError());
        return false;
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
            if (received != 0U && on_read_) {
                on_read_(buffer.data(), received);
            }
            continue;
        }
        const DWORD read_error = GetLastError();
        if (read_error != ERROR_IO_PENDING) {
            if (!stop_requested_.load(std::memory_order_acquire)) {
                report_fault(static_cast<std::int32_t>(read_error));
            }
            return;
        }
        const std::array<HANDLE, 2> waits{stop_event_.get(), read_event_.get()};
        const DWORD wait = WaitForMultipleObjects(static_cast<DWORD>(waits.size()),
                                                   waits.data(), FALSE, INFINITE);
        if (wait == WAIT_OBJECT_0 || stop_requested_.load(std::memory_order_acquire)) {
            return;
        }
        if (wait != WAIT_OBJECT_0 + 1U ||
            GetOverlappedResult(port_.get(), &read_overlapped_, &received, FALSE) == FALSE) {
            const DWORD result_error = GetLastError();
            if (!stop_requested_.load(std::memory_order_acquire) &&
                result_error != ERROR_OPERATION_ABORTED) {
                report_fault(static_cast<std::int32_t>(result_error));
            }
            return;
        }
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

// ---------------------------------------------------------------------------
// Serial-port enumeration (registry-backed). The value names of the
// HARDWARE\DEVICEMAP\SERIALCOMM key are friendlier device descriptions while
// the REG_SZ values carry the COMx names. All Win32 registry types are
// confined to this TU; the public signature is pure C++.
// ---------------------------------------------------------------------------
std::uint32_t enumerate_serial_ports(XcomPortInfo* out, std::uint32_t capacity)
{
    HKEY serial_key = nullptr;
    const LSTATUS open_result = RegOpenKeyExA(
        HKEY_LOCAL_MACHINE, "HARDWARE\\DEVICEMAP\\SERIALCOMM", 0U,
        KEY_QUERY_VALUE, &serial_key);
    if (open_result != ERROR_SUCCESS) {
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
        if (value_result != ERROR_SUCCESS || value_type != REG_SZ) {
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
        }
        ++found;
    }
    RegCloseKey(serial_key);
    return found;
}

}  // namespace xcom
