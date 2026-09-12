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

# Project-owned framework include root (relative to this product core).
set(XCOM_COACT_INCLUDE "${CMAKE_CURRENT_SOURCE_DIR}/framework/coact/include"
    CACHE PATH "project-owned coact runtime include dir" FORCE)

# --- xcom_core shared library ---------------------------------------------
add_library(xcom_core SHARED
    src/runtime/pal_windows.cpp
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
    target_compile_options(xcom_core PRIVATE
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
target_link_libraries(xcom_core PRIVATE advapi32)

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
target_include_directories(xcom_line_control_test PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include)
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
target_link_libraries(xcom_tx_diag_test PRIVATE advapi32)
set_target_properties(xcom_tx_diag_test PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
if(BUILD_TESTING)
    add_test(NAME xcom.tx_diag COMMAND xcom_tx_diag_test)
endif()

add_executable(xcom_windows_pal_test
    tests/windows_pal_test.cpp
    src/runtime/pal_windows.cpp
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
