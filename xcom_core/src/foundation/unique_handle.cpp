// unique_handle.cpp - shared Win32 HANDLE RAII implementation.
// SPDX-License-Identifier: MIT
#include "unique_handle.hpp"

namespace xcom {
namespace foundation {

UniqueHandle::~UniqueHandle()
{
    reset();
}

UniqueHandle::UniqueHandle(UniqueHandle&& other) noexcept
    : handle_(std::exchange(other.handle_, nullptr))
{
}

UniqueHandle& UniqueHandle::operator=(UniqueHandle&& other) noexcept
{
    if (this != &other) {
        reset(std::exchange(other.handle_, nullptr));
    }
    return *this;
}

void UniqueHandle::reset(HANDLE handle) noexcept
{
    if (valid()) {
        CloseHandle(handle_);
    }
    handle_ = handle;
}

}  // namespace foundation
}  // namespace xcom
