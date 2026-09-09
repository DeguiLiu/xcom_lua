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
add_executable(xcom WIN32
    xcom_lua/native/launcher/xcom_launcher.cpp
    xcom_lua/native/launcher/xcom_launcher.rc
)
set_target_properties(xcom PROPERTIES
    RUNTIME_OUTPUT_DIRECTORY "${CMAKE_SOURCE_DIR}/xcom_lua/runtime"
)
# Inject the version from project() into the launcher's VS_VERSION_INFO.
set_target_properties(xcom PROPERTIES
    VERSION "${PROJECT_VERSION}"
)
target_compile_definitions(xcom PRIVATE
    XCOM_VERSION_MAJOR=${PROJECT_VERSION_MAJOR}
    XCOM_VERSION_MINOR=${PROJECT_VERSION_MINOR}
    XCOM_VERSION_PATCH=${PROJECT_VERSION_PATCH}
)
