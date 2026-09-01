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

// Enumerate Windows serial ports from the registry
// (HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM). Fills `out` up to its
// caller-provided capacity and returns the total number discovered, preserving
// the XCOM_ERR_FULL ABI contract without an internal fixed-port limit. No
// Win32 types leak past this TU boundary.
std::uint32_t enumerate_serial_ports(XcomPortInfo* out, std::uint32_t capacity);

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

class WinSerialBackend final {
public:
    // FixedFunction gives the owner a small, non-allocating callback bridge.
    // The CoreState capture is one pointer and therefore remains well inside
    // this inline buffer for the whole open/read/close session.
    using ReadCallback = foundation::FixedFunction<
        void(const std::uint8_t*, std::uint32_t)>;
    using FaultCallback = foundation::FixedFunction<void(std::int32_t)>;

    WinSerialBackend() noexcept;
    ~WinSerialBackend();
    WinSerialBackend(const WinSerialBackend&) = delete;
    WinSerialBackend& operator=(const WinSerialBackend&) = delete;

    [[nodiscard]] bool open(const SerialPortOptions& options,
                            ReadCallback on_read,
                            FaultCallback on_fault,
                            std::int32_t& error) noexcept;
    void close() noexcept;

    [[nodiscard]] bool write(const std::uint8_t* data, std::uint16_t size,
                             std::uint32_t timeout_ms, std::uint32_t& written,
                             std::int32_t& error) noexcept;
    void abort_pending_write() noexcept;
    void set_rts(bool enabled) noexcept;

    [[nodiscard]] bool is_open() const noexcept;

private:
    [[nodiscard]] bool configure(const SerialPortOptions& options,
                                 std::int32_t& error) noexcept;
    void read_loop() noexcept;
    void report_fault(std::int32_t error) noexcept;

    foundation::UniqueHandle port_;
    foundation::UniqueHandle read_event_;
    foundation::UniqueHandle write_event_;
    foundation::UniqueHandle stop_event_;
    OVERLAPPED read_overlapped_{};
    OVERLAPPED write_overlapped_{};
    ReadCallback on_read_;
    FaultCallback on_fault_;
    std::thread read_thread_;
    std::atomic<bool> stop_requested_{false};
    std::atomic<bool> open_{false};
};

}  // namespace xcom

#endif  // XCOM_SERIAL_BACKEND_WIN_HPP_
