// xcom_abi_internal.hpp - cross-TU declarations shared by xcom_core.cpp (which
// owns the opaque Handle/CoreState) and xcom_abi.cpp (the C ABI surface).
//
// SPDX-License-Identifier: MIT
#pragma once
#ifndef XCOM_ABI_INTERNAL_HPP_
#define XCOM_ABI_INTERNAL_HPP_

#include <cstdint>

#include <xcom/xcom.h>

#include "xcom_core.hpp"

namespace xcom {

struct CoreState;
struct Handle;

// Result of rx_ingress: distinguishes a fully accepted injection from a
// partial one. The pool-full byte count is accumulated into
// CoreCtx::metrics.rx_pool_exhausted_bytes by rx_ingress itself (exact
// shortfall, not the whole payload).
enum class RxIngressResult : std::uint8_t {
    kAllAccepted = 0U,      // every payload byte copied into a committed block
    kPartialAccepted = 1U,  // pool exhausted; some tail bytes were not accepted
};

// Factory helpers (opaque to the ABI layer).
Handle* xcom_handle_create() noexcept;
XcomStatus xcom_handle_boot(Handle* h) noexcept;
void xcom_handle_shutdown(Handle* h) noexcept;
void xcom_handle_destroy(Handle* h) noexcept;
CoreCtx* xcom_handle_core(Handle* h) noexcept;
bool xcom_handle_valid(const void* p) noexcept;

// RX ingress shared by the real callback thread and the injected test seam.
RxIngressResult rx_ingress(CoreCtx* core, const uint8_t* data,
                           uint32_t size) noexcept;

// Native Win32 serial-port enumeration.
XcomStatus list_ports_impl(XcomPortInfo* out, std::uint32_t capacity,
                           std::uint32_t* count) noexcept;

}  // namespace xcom

#endif /* XCOM_ABI_INTERNAL_HPP_ */
