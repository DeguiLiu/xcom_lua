# xcom_core - C ABI wrapper DLL for the XCOM serial tool.
#
# Builds xcom_core.dll from the project-owned coact runtime and the native
# Win32 OVERLAPPED serial adapter. Output lands in <build-dir>/bin/xcom_core.dll.
cmake_minimum_required(VERSION 3.21)

if(CMAKE_SOURCE_DIR STREQUAL CMAKE_CURRENT_SOURCE_DIR)
    project(xcom_core LANGUAGES CXX VERSION 0.1.0)
    include(CTest)
    option(XCOM_BUILD_NATIVE_TESTS "Build hardware-free C++ core tests" ${BUILD_TESTING})
endif()

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release)
endif()

# coact is an external checkout, not vendored here. From this file,
# xcom_core/../../coact resolves to <workspace>/coact; its `windows` branch
# carries the Win32 PAL this core needs. Override for a different checkout.
set(XCOM_COACT_ROOT "${CMAKE_CURRENT_SOURCE_DIR}/../../coact"
    CACHE PATH "path to the external coact checkout (windows branch)")
set(XCOM_COACT_INCLUDE "${XCOM_COACT_ROOT}/include")

if(NOT EXISTS "${XCOM_COACT_INCLUDE}/coact/runtime.hpp")
    message(FATAL_ERROR
        "coact headers not found at ${XCOM_COACT_INCLUDE}/coact/runtime.hpp.\n"
        "xcom_core consumes an external coact checkout (windows branch).\n"
        "Pass -DXCOM_COACT_ROOT=<path-to-coact-windows-checkout> to point at it.")
endif()

# --- xcom_core shared library ---------------------------------------------
add_library(xcom_core SHARED
    ${XCOM_COACT_ROOT}/src/core/pal_windows.cpp
    src/runtime/periodic_timer.cpp
    src/foundation/unique_handle.cpp
    src/io/log_writer.cpp
    src/io/serial_backend_win.cpp
    src/diagnostics/diagnostic.cpp
    src/ao/xcom_ao.cpp
    src/runtime/xcom_core.cpp
    src/abi/xcom_abi.cpp
)
set_target_properties(xcom_core PROPERTIES
    OUTPUT_NAME xcom_core
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin
    LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib
)
add_library(xcom::core ALIAS xcom_core)
target_compile_features(xcom_core PRIVATE cxx_std_17)
target_include_directories(xcom_core PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/src/ao
    ${CMAKE_CURRENT_SOURCE_DIR}/src/abi
    ${CMAKE_CURRENT_SOURCE_DIR}/src/diagnostics
    ${XCOM_COACT_INCLUDE}
)

if(MSVC)
    # /W4: this target compiles coact's headers (pal_windows.cpp and every
    # ${XCOM_COACT_INCLUDE} include), so xcom_core owns the warning level for
    # that code. coact_core is an INTERFACE library that nothing here links
    # (xcom_core links only advapi32), so its usage requirements never reach
    # these TUs -- the flags must be set on the targets that actually compile.
    #
    # Deliberately NOT /WX: this repo has no Windows CI that can run MSVC, so a
    # fatal warning would turn an unverifiable local build into a hard failure.
    # Warnings at /W4 are a review aid here, not a gate. Do not add /WX without
    # first proving the Windows build is clean on a real MSVC toolchain.
    #
    # Deliberately NOT /GR- /EHs-c- (which coact_core sets for its own tests):
    # the ABI layer uses try/catch throughout -- 28 `catch` occurrences in
    # src/abi/xcom_abi.cpp -- so disabling the exception model would break the
    # shipping build. Those flags belong to coact's header-only test targets,
    # not to a DLL that must unwind across the C ABI.
    target_compile_options(xcom_core PRIVATE
        /W4
        /utf-8
        "$<$<CONFIG:Release>:/O2>"
        "$<$<CONFIG:Release>:/Gy>"
        "$<$<CONFIG:Release>:/Gw>")
    target_link_options(xcom_core PRIVATE
        "$<$<CONFIG:Release>:/OPT:REF>"
        "$<$<CONFIG:Release>:/OPT:ICF>")

    if(XCOM_ENABLE_IPO)
        include(CheckIPOSupported)
        check_ipo_supported(RESULT XCOM_IPO_SUPPORTED
                            OUTPUT XCOM_IPO_ERROR
                            LANGUAGES CXX)
        if(XCOM_IPO_SUPPORTED)
            set_property(TARGET xcom_core
                         PROPERTY INTERPROCEDURAL_OPTIMIZATION_RELEASE TRUE)
        else()
            message(STATUS "xcom_core: Release IPO unavailable: ${XCOM_IPO_ERROR}")
        endif()
    endif()
endif()

target_compile_definitions(xcom_core PRIVATE
    XCOM_CORE_BUILD
    WIN32_LEAN_AND_MEAN
    NOMINMAX
    _CRT_SECURE_NO_WARNINGS)

# advapi32 is used by the native registry-backed serial-port enumerator.
# setupapi reads each port's SPDRP_HARDWAREID (read-only PnP property; never
# opens the port) so reconnect can key on stable hardware identity.
target_link_libraries(xcom_core PRIVATE advapi32 setupapi)

# --- hardware-free tests ----------------------------------------------------
if(XCOM_BUILD_NATIVE_TESTS)
add_executable(xcom_smoke_test tests/smoke_test.cpp)
target_compile_features(xcom_smoke_test PRIVATE cxx_std_17)
target_include_directories(xcom_smoke_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src)
target_compile_definitions(xcom_smoke_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_link_libraries(xcom_smoke_test PRIVATE xcom_core)
set_target_properties(xcom_smoke_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.smoke COMMAND xcom_smoke_test)
endif()

add_executable(xcom_session_churn_test tests/session_churn_test.cpp)
target_compile_features(xcom_session_churn_test PRIVATE cxx_std_17)
target_include_directories(xcom_session_churn_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(xcom_session_churn_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_link_libraries(xcom_session_churn_test PRIVATE xcom_core)
set_target_properties(xcom_session_churn_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.session_churn COMMAND xcom_session_churn_test)
endif()

add_executable(xcom_async_open_test tests/async_open_test.cpp)
target_compile_features(xcom_async_open_test PRIVATE cxx_std_17)
target_include_directories(xcom_async_open_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(xcom_async_open_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_link_libraries(xcom_async_open_test PRIVATE xcom_core)
set_target_properties(xcom_async_open_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.async_open COMMAND xcom_async_open_test)
endif()

add_executable(xcom_line_control_test tests/line_control_test.cpp)
target_compile_features(xcom_line_control_test PRIVATE cxx_std_17)
# src/io is needed for serial_backend_win.hpp's header-inline
# copy_first_multi_sz, which pins the v1.6 SPDRP_HARDWAREID parse without
# SetupAPI or a serial device.
target_include_directories(xcom_line_control_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation)
target_compile_definitions(xcom_line_control_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_link_libraries(xcom_line_control_test PRIVATE xcom_core)
set_target_properties(xcom_line_control_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.line_control COMMAND xcom_line_control_test)
endif()

# v1.5 line-error accounting contract. No serial hardware: the counts are
# injected through the TEST-ONLY seam and read back through the public
# snapshot ABI, covering the struct layout, monotonic accumulation, and the
# metrics reset-free semantics the real ClearCommError path relies on.
add_executable(xcom_line_error_test tests/line_error_test.cpp)
target_compile_features(xcom_line_error_test PRIVATE cxx_std_17)
target_include_directories(xcom_line_error_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_compile_definitions(xcom_line_error_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_link_libraries(xcom_line_error_test PRIVATE xcom_core)
set_target_properties(xcom_line_error_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.line_error COMMAND xcom_line_error_test)
endif()

# TX teardown drain + flow-control stall diagnosis. Compiles the backend TU
# directly (not via the DLL) so the guard paths and the header-inline message
# mapping are reachable without the exported C ABI.
add_executable(xcom_tx_diag_test
    tests/tx_diag_test.cpp
    src/io/serial_backend_win.cpp
    src/foundation/unique_handle.cpp)
target_compile_features(xcom_tx_diag_test PRIVATE cxx_std_17)
target_include_directories(xcom_tx_diag_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation)
target_compile_definitions(xcom_tx_diag_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
target_link_libraries(xcom_tx_diag_test PRIVATE advapi32 setupapi)
set_target_properties(xcom_tx_diag_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.tx_diag COMMAND xcom_tx_diag_test)
endif()

# Ref-counted RX lane: file-lane reservation (display must never starve the
# file), lossless file backpressure, and exact block lifetime. Win32-free, so
# it also builds and runs on a Linux host with g++ directly (see the header
# comment in the test); no xcom_core link is needed.
add_executable(xcom_rx_block_lane_test tests/rx_block_lane_test.cpp)
target_compile_features(xcom_rx_block_lane_test PRIVATE cxx_std_17)
target_include_directories(xcom_rx_block_lane_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${XCOM_COACT_INCLUDE})
set_target_properties(xcom_rx_block_lane_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.rx_block_lane COMMAND xcom_rx_block_lane_test)
endif()

# Thread-liveness logic (design §4.2 item 3): timeout detection, once-per-
# episode fault/recovery reporting, the parked (idle) exemption, and uint32
# wrap-safety. Win32-free and coact-free, so it also builds and runs on a Linux
# host with g++ directly; no xcom_core link is needed.
add_executable(xcom_thread_health_test tests/thread_health_test.cpp)
target_compile_features(xcom_thread_health_test PRIVATE cxx_std_17)
target_include_directories(xcom_thread_health_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime)
set_target_properties(xcom_thread_health_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.thread_health COMMAND xcom_thread_health_test)
endif()

# xcom_send rejection contract: a full pool / dispatcher queue is XCOM_ERR_FULL,
# while the Send AO's overload Breaker refusing a non-critical event is
# XCOM_ERR_BUSY (the pool may be empty). Win32-free and coact-header-only, so it
# also builds and runs on a Linux host with g++ directly; no xcom_core link.
add_executable(xcom_tx_submit_status_test tests/tx_submit_status_test.cpp)
target_compile_features(xcom_tx_submit_status_test PRIVATE cxx_std_17)
target_include_directories(xcom_tx_submit_status_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${XCOM_COACT_INCLUDE})
set_target_properties(xcom_tx_submit_status_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.tx_submit_status COMMAND xcom_tx_submit_status_test)
endif()

# Open-failure status contract: CoreCtx::last_open_result deliberately mixes
# negative XCOM_ERR_* sentinels with raw positive Win32 codes, but XcomStatus is
# documented as 0-or-negative and the front-end switches on the enumerators. A
# raw Win32 code escaping here is read as an unknown positive status. Win32-free
# (src/abi/open_failure_status.hpp + the public header only), so unlike the
# stub-backed host tests below this one also builds and runs on the Windows
# runner.
add_executable(xcom_open_failure_status_test tests/open_failure_status_test.cpp)
target_compile_features(xcom_open_failure_status_test PRIVATE cxx_std_17)
target_include_directories(xcom_open_failure_status_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src/abi
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
set_target_properties(xcom_open_failure_status_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.open_failure_status COMMAND xcom_open_failure_status_test)
endif()

# Manual DTR/RTS pin-write contract (defect A: a driver-owned RTS must not be a
# false success; defect B: a failed EscapeCommFunction must not be reported as
# applied). Linux-only: the test supplies fake Win32 definitions, which would
# collide with the real import library on Windows. On Windows the live pin
# behaviour needs a USB-UART adapter anyway. Build and run it directly with g++
# (see the header comment in the test); it needs no xcom_core link.
if(NOT WIN32)
add_executable(xcom_line_apply_test
    tests/line_apply_test.cpp
    src/io/serial_backend_win.cpp
    src/foundation/unique_handle.cpp)
target_compile_features(xcom_line_apply_test PRIVATE cxx_std_17)
target_include_directories(xcom_line_apply_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/../tools/win32-stub)
set_target_properties(xcom_line_apply_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.line_apply COMMAND xcom_line_apply_test)
endif()
endif()

# SerialAo lifecycle matrix: every (state, event) cell of the table-driven
# transition function, asserting the final state and whether port_state was
# published, plus the latch-compensated close/open-cancel convergence paths.
# Linux-only: it compiles xcom_ao.cpp against the Win32 stub and supplies a host
# coact::pal::monotonic_ms, which would collide with coact's real Win32 PAL on
# Windows. No xcom_core link is needed.
if(NOT WIN32)
add_executable(xcom_serial_transition_test
    tests/serial_transition_test.cpp
    src/ao/xcom_ao.cpp)
target_compile_features(xcom_serial_transition_test PRIVATE cxx_std_17)
target_include_directories(xcom_serial_transition_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/src/ao
    ${CMAKE_CURRENT_SOURCE_DIR}/src/diagnostics
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/../tools/win32-stub
    ${XCOM_COACT_INCLUDE})
set_target_properties(xcom_serial_transition_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.serial_transition COMMAND xcom_serial_transition_test)
endif()

# RxKickGate rejection contract: every producer arms the coalescing gate and then
# submits; if the submit is refused the gate must be released again, because an
# armed gate with no in-flight kick is a permanent receive-display blackhole
# while data keeps arriving. Needs the Win32 stub (xcom_core.hpp pulls in
# <windows.h>) and no xcom_core link, so it is host-only here for the same
# reason as xcom_line_apply_test above; tools/check_cpp_syntax.sh parses it on
# every CI run so it cannot rot silently.
add_executable(xcom_rx_kick_gate_test tests/rx_kick_gate_test.cpp)
target_compile_features(xcom_rx_kick_gate_test PRIVATE cxx_std_17)
target_include_directories(xcom_rx_kick_gate_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/src/diagnostics
    ${CMAKE_CURRENT_SOURCE_DIR}/../tools/win32-stub
    ${XCOM_COACT_INCLUDE})
set_target_properties(xcom_rx_kick_gate_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.rx_kick_gate COMMAND xcom_rx_kick_gate_test)
endif()

# Close/read race: a read IRP that completes concurrently with the stop event
# must still be reaped and delivered, not dropped because WaitForMultipleObjects
# returned the lower (stop) index. The test supplies fake Win32 definitions, so
# it can only be linked on the host; tools/check_cpp_syntax.sh parses it too.
add_executable(xcom_serial_close_reap_test
    tests/serial_close_reap_test.cpp
    src/io/serial_backend_win.cpp
    src/foundation/unique_handle.cpp)
target_compile_features(xcom_serial_close_reap_test PRIVATE cxx_std_17)
target_include_directories(xcom_serial_close_reap_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/../tools/win32-stub)
set_target_properties(xcom_serial_close_reap_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.serial_close_reap COMMAND xcom_serial_close_reap_test)
endif()

# Rejected-Fault fallback reconciliation: when the control pool is exhausted the
# critical Fault signal is refused, so the off-Dispatcher reporter latches it
# instead of closing the handle. serial_do_open must run the real Fault edge
# (kOwnerClose) before reopening, or the HSM has no Open edge and the stale COM
# handle is never released. Host-only (Win32 stub plus a host monotonic_ms),
# like the transition matrix below.
add_executable(xcom_fault_latch_reconcile_test
    tests/fault_latch_reconcile_test.cpp
    src/ao/xcom_ao.cpp)
target_compile_features(xcom_fault_latch_reconcile_test PRIVATE cxx_std_17)
target_include_directories(xcom_fault_latch_reconcile_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/src/ao
    ${CMAKE_CURRENT_SOURCE_DIR}/src/diagnostics
    ${CMAKE_CURRENT_SOURCE_DIR}/src/io
    ${CMAKE_CURRENT_SOURCE_DIR}/../tools/win32-stub
    ${XCOM_COACT_INCLUDE})
set_target_properties(xcom_fault_latch_reconcile_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.fault_latch_reconcile COMMAND xcom_fault_latch_reconcile_test)
endif()

# Unowned-receive loss ledger: bytes delivered after admission has been zeroed
# (close/shutdown reaping window) or while the port is still OPENING must be
# counted into save_rejected_bytes / rx_loss_offset rather than dropped, so the
# UI's DATA LOSS banner can report them. Host-only; the accounting helper is
# inline, so no xcom_core link is needed.
add_executable(xcom_rx_reject_count_test tests/rx_reject_count_test.cpp)
target_compile_features(xcom_rx_reject_count_test PRIVATE cxx_std_17)
target_include_directories(xcom_rx_reject_count_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${CMAKE_CURRENT_SOURCE_DIR}/src/foundation
    ${CMAKE_CURRENT_SOURCE_DIR}/src/diagnostics
    ${CMAKE_CURRENT_SOURCE_DIR}/../tools/win32-stub
    ${XCOM_COACT_INCLUDE})
set_target_properties(xcom_rx_reject_count_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.rx_reject_count COMMAND xcom_rx_reject_count_test)
endif()
endif()

add_executable(xcom_windows_pal_test
    tests/windows_pal_test.cpp
    ${XCOM_COACT_ROOT}/src/core/pal_windows.cpp
    src/foundation/unique_handle.cpp)
target_compile_features(xcom_windows_pal_test PRIVATE cxx_std_17)
target_include_directories(xcom_windows_pal_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime
    ${XCOM_COACT_INCLUDE})
target_compile_definitions(xcom_windows_pal_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
set_target_properties(xcom_windows_pal_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.windows_pal COMMAND xcom_windows_pal_test)
endif()

add_executable(xcom_periodic_timer_test
    tests/periodic_timer_test.cpp
    src/runtime/periodic_timer.cpp
    src/foundation/unique_handle.cpp)
target_compile_features(xcom_periodic_timer_test PRIVATE cxx_std_17)
target_include_directories(xcom_periodic_timer_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/src
    ${CMAKE_CURRENT_SOURCE_DIR}/src/runtime)
target_compile_definitions(xcom_periodic_timer_test PRIVATE
    WIN32_LEAN_AND_MEAN NOMINMAX _CRT_SECURE_NO_WARNINGS)
set_target_properties(xcom_periodic_timer_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.periodic_timer COMMAND xcom_periodic_timer_test)
endif()
endif()
