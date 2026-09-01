cmake_minimum_required(VERSION 3.21)

project(XCOM VERSION 1.2.0 LANGUAGES CXX)

if(NOT WIN32)
    message(FATAL_ERROR "XCOM currently supports the native Win32 serial backend only.")
endif()

include(CTest)

option(XCOM_BUILD_NATIVE_TESTS "Build hardware-free C++ core tests" ${BUILD_TESTING})
option(XCOM_ENABLE_IPO "Enable supported Release IPO/LTCG optimizations" ON)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

# Keep all generated native artifacts below one conventional build tree.
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/bin")
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY "${CMAKE_BINARY_DIR}/lib")

add_subdirectory(xcom_core)
