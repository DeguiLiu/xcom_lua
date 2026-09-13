#!/usr/bin/env bash
# run_host_cpp_tests.sh - build and RUN the hardware-free C++ suites that the
# CMake build cannot reach, so CI executes them instead of merely parsing them.
#
# Why this exists: the root CMakeLists.txt aborts on a non-Windows host, and the
# suites below are registered under if(NOT WIN32) because they supply fake Win32
# definitions that would collide with the real import library on Windows. The
# two facts together meant no CI job ever ran them - tools/check_cpp_syntax.sh
# parsed them (catching type drift) but a regression in their behaviour could
# only be found by a developer running the recipe in each file's header by hand.
# An unexecuted regression test is not a regression test.
#
# Each suite is self-contained: it links only its own sources plus, where the
# suite drives the real backend, serial_backend_win.cpp + unique_handle.cpp.
# -ffunction-sections -Wl,--gc-sections is applied uniformly because a suite
# that touches the port-enumeration path would otherwise pull in SetupAPI
# symbols the stub intentionally only declares.
#
# Usage: tools/run_host_cpp_tests.sh   (from the repository root)
# Exit: 0 when every suite builds and passes, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || exit 1

if ! command -v g++ >/dev/null 2>&1; then
    echo "g++ not found; cannot build the host suites" >&2
    exit 1
fi

# coact is an external checkout (its `windows` branch), not vendored: some
# suites include coact headers through xcom_core.hpp. Same resolution as
# tools/check_cpp_syntax.sh.
XCOM_COACT_ROOT="${XCOM_COACT_ROOT:-$ROOT/../coact}"
if [ ! -f "$XCOM_COACT_ROOT/include/coact/runtime.hpp" ]; then
    echo "coact headers not found at $XCOM_COACT_ROOT/include/coact/runtime.hpp" >&2
    echo "Set XCOM_COACT_ROOT=<path-to-coact-windows-checkout> to point at it." >&2
    exit 1
fi

INCLUDES=(
    -I"$ROOT/tools/win32-stub"
    -I"$ROOT/xcom_core/include"
    -I"$ROOT/xcom_core/src"
    -I"$ROOT/xcom_core/src/runtime"
    -I"$ROOT/xcom_core/src/foundation"
    -I"$ROOT/xcom_core/src/ao"
    -I"$ROOT/xcom_core/src/diagnostics"
    -I"$ROOT/xcom_core/src/io"
    -I"$XCOM_COACT_ROOT/include"
)

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0
fail=0

run_suite() {
    local name="$1"
    shift
    local bin="$WORK/$name"
    if ! g++ -std=c++17 -pthread "${INCLUDES[@]}" \
             -ffunction-sections -Wl,--gc-sections \
             "$@" -o "$bin" >"$WORK/$name.build.log" 2>&1; then
        echo "BUILD FAIL  $name"
        grep 'error:' "$WORK/$name.build.log" | head -10
        fail=$((fail + 1))
        return
    fi
    # A suite that hangs must not hang the job: it is a failure, not a wait.
    local -a launcher=()
    command -v timeout >/dev/null 2>&1 && launcher=(timeout 120)
    if "${launcher[@]}" "$bin" >"$WORK/$name.log" 2>&1; then
        echo "PASS  $name"
        pass=$((pass + 1))
    else
        echo "FAIL  $name (rc=$?)"
        tail -20 "$WORK/$name.log"
        fail=$((fail + 1))
    fi
}

# --- suites with no xcom_core link ----------------------------------------
run_suite rx_block_lane xcom_core/tests/rx_block_lane_test.cpp
run_suite rx_kick_gate xcom_core/tests/rx_kick_gate_test.cpp
run_suite rx_reject_count xcom_core/tests/rx_reject_count_test.cpp

# --- suites that drive the real Win32 backend against the stub -------------
run_suite line_apply \
    xcom_core/tests/line_apply_test.cpp \
    xcom_core/src/io/serial_backend_win.cpp \
    xcom_core/src/foundation/unique_handle.cpp
run_suite serial_close_reap \
    xcom_core/tests/serial_close_reap_test.cpp \
    xcom_core/src/io/serial_backend_win.cpp \
    xcom_core/src/foundation/unique_handle.cpp
run_suite open_pin_warning \
    xcom_core/tests/open_pin_warning_test.cpp \
    xcom_core/src/io/serial_backend_win.cpp \
    xcom_core/src/foundation/unique_handle.cpp
run_suite serial_short_write \
    xcom_core/tests/serial_short_write_test.cpp \
    xcom_core/src/io/serial_backend_win.cpp \
    xcom_core/src/foundation/unique_handle.cpp
run_suite log_writer_shutdown \
    xcom_core/tests/log_writer_shutdown_test.cpp \
    xcom_core/src/io/log_writer.cpp \
    xcom_core/src/foundation/unique_handle.cpp

# --- suites that compile the AO state machine ------------------------------
run_suite serial_transition \
    xcom_core/tests/serial_transition_test.cpp \
    xcom_core/src/ao/xcom_ao.cpp
run_suite fault_latch_reconcile \
    xcom_core/tests/fault_latch_reconcile_test.cpp \
    xcom_core/src/ao/xcom_ao.cpp

echo
echo "host C++ suites: $pass passed, $fail failed"
exit $((fail != 0))
