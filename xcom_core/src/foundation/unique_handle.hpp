// unique_handle.hpp - shared Win32 HANDLE RAII for XCOM internals.
//
// Promoted out of io/serial_backend_win.hpp so both the serial backend and the
// coact Windows PAL can own kernel handles without duplicating the move /
// delete-copy / CloseHandle discipline. Value members, no allocation.
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_FOUNDATION_UNIQUE_HANDLE_HPP_
#define XCOM_FOUNDATION_UNIQUE_HANDLE_HPP_

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>

#include <utility>   // std::exchange

namespace xcom {
namespace foundation {

// Owns a single Win32 HANDLE. Move-only; destroys the handle on destruction
// or reset(). valid() treats both nullptr and INVALID_HANDLE_VALUE as empty so
// callers never leak a stale sentinel.
class UniqueHandle final {
public:
    UniqueHandle() noexcept = default;
    explicit UniqueHandle(HANDLE handle) noexcept : handle_(handle) {}
    ~UniqueHandle();

    UniqueHandle(const UniqueHandle&) = delete;
    UniqueHandle& operator=(const UniqueHandle&) = delete;

    UniqueHandle(UniqueHandle&& other) noexcept;
    UniqueHandle& operator=(UniqueHandle&& other) noexcept;

    [[nodiscard]] HANDLE get() const noexcept { return handle_; }
    [[nodiscard]] bool valid() const noexcept
    {
        return handle_ != nullptr && handle_ != INVALID_HANDLE_VALUE;
    }
    void reset(HANDLE handle = nullptr) noexcept;

private:
    HANDLE handle_ = nullptr;
};

}  // namespace foundation
}  // namespace xcom

#endif  // XCOM_FOUNDATION_UNIQUE_HANDLE_HPP_
