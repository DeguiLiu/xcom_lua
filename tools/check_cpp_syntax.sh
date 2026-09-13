#!/usr/bin/env bash
# check_cpp_syntax.sh - compiler-level syntax check for the Win32 sources.
#
# The real build needs MSVC on Windows (CMakeLists.txt hard-requires WIN32, and
# the sources include <windows.h>, <winreg.h>, DirectX 11 and the ImGui backends).
# That means a Linux developer can otherwise only eyeball a C++ change, which is
# how a bad cast sat unnoticed in the close path.
#
# This script supplies a minimal windows.h stand-in (tools/win32-stub) and runs
# g++ -fsyntax-only over the translation units that carry the serial/ABI logic
# and the hardware-free tests around it. It catches syntax errors, type errors
# and missing declarations. It does NOT substitute for an MSVC build: it cannot
# validate anything that depends on real Windows headers, calling conventions or
# the DX11 device. The stub declares (never defines) the Win32 surface, so a TU
# can pass here while still being unlinkable on Linux; that is expected.
#
# Usage: tools/check_cpp_syntax.sh   (from the repository root)
# Exit: 0 when every checked TU parses, 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STUB="$ROOT/tools/win32-stub"
cd "$ROOT" || exit 1

if ! command -v g++ >/dev/null 2>&1; then
    echo "g++ not found; skipping C++ syntax check" >&2
    exit 0
fi

# coact is an external checkout (its `windows` branch), not vendored in this
# repo. $ROOT/../coact is <workspace>/coact, i.e. ../../coact from this script;
# override with XCOM_COACT_ROOT=<path-to-coact-windows-checkout>.
XCOM_COACT_ROOT="${XCOM_COACT_ROOT:-$ROOT/../coact}"
COACT_INCLUDE="$XCOM_COACT_ROOT/include"
if [ ! -f "$COACT_INCLUDE/coact/runtime.hpp" ]; then
    echo "coact headers not found at $COACT_INCLUDE/coact/runtime.hpp" >&2
    echo "xcom_core consumes an external coact checkout (windows branch)." >&2
    echo "Set XCOM_COACT_ROOT=<path-to-coact-windows-checkout> to point at it." >&2
    exit 1
fi

INCLUDES=(
    -I"$STUB"
    -Ixcom_core/src
    -Ixcom_core/src/runtime
    -Ixcom_core/src/diagnostics
    -Ixcom_core/src/io
    -Ixcom_core/src/foundation
    -Ixcom_core/src/ao
    -Ixcom_core/src/abi
    -Ixcom_core/include
    -I"$COACT_INCLUDE"
)

# The translation units that hold the serial backend, the log writer, the ABI
# plumbing, the diagnostics writer, the timer/launcher and the hardware-free
# tests that cover them. One exclusion is deliberate:
#   - xcom_imgui_bridge.cpp: needs <d3d11.h>, ImGui and implot.
# A red result here must mean a real defect, or the check gets ignored.
TUS=(
    xcom_core/src/io/serial_backend_win.cpp
    # The dedicated file writer. It used to be excluded: GCC's
    # std::is_nothrow_default_constructible reports a false negative for a
    # nested type with NSDMIs while the enclosing Impl is still incomplete, so
    # coact::SpscRing<FileJob, ...> tripped its static_assert. Fixed in
    # log_writer.cpp by giving FileJob/AtomicCompletion explicit noexcept
    # default ctors (behaviour- and ABI-identical); now gated so it stays clean.
    xcom_core/src/io/log_writer.cpp
    xcom_core/src/diagnostics/diagnostic.cpp
    xcom_core/src/runtime/periodic_timer.cpp
    xcom_core/src/foundation/unique_handle.cpp
    # The two files that carry the port state machine: the HSM transition table
    # and the owner sinks in xcom_core.cpp, and the actions in xcom_ao.cpp. A
    # transition or an action that does not compile is a state machine that
    # silently stops transitioning, so they belong in this gate.
    xcom_core/src/ao/xcom_ao.cpp
    xcom_core/src/runtime/xcom_core.cpp
    xcom_core/src/abi/xcom_abi.cpp
    # The upstream coact PAL implementation. The PAL class is declared by
    # coact's header and defined in this .cpp, so the gate must parse the .cpp
    # too or the migration's real surface stays unchecked.
    "$XCOM_COACT_ROOT/src/core/pal_windows.cpp"
    # The shipped launcher: it resolves its own path and spawns the interpreter
    # with a hidden console. Previously unchecked on Linux.
    xcom_lua/native/launcher/xcom_launcher.cpp
    # Hardware-free tests. These carry the ABI seams, the state-machine matrix,
    # the ref-counted block lane and the timer logic; parsing them here keeps
    # the test code itself free of type drift.
    xcom_core/tests/line_control_test.cpp
    xcom_core/tests/line_error_test.cpp
    xcom_core/tests/smoke_test.cpp
    xcom_core/tests/session_churn_test.cpp
    xcom_core/tests/async_open_test.cpp
    xcom_core/tests/tx_diag_test.cpp
    xcom_core/tests/rx_block_lane_test.cpp
    xcom_core/tests/thread_health_test.cpp
    xcom_core/tests/tx_submit_status_test.cpp
    xcom_core/tests/line_apply_test.cpp
    xcom_core/tests/serial_transition_test.cpp
    xcom_core/tests/periodic_timer_test.cpp
    xcom_core/tests/windows_pal_test.cpp
    # Host-only suites, which CMake cannot reach: the root CMakeLists aborts on a
    # non-Windows host, and on Windows these targets are skipped because they
    # need the Win32 stub. Parsing them here is the only thing that stops them
    # from rotting between the rare manual runs. The P0-1 gate-latch and P1-1
    # reap-before-return regressions live in the first two.
    xcom_core/tests/rx_kick_gate_test.cpp
    xcom_core/tests/serial_close_reap_test.cpp
    xcom_core/tests/open_failure_status_test.cpp
    xcom_core/tests/fault_latch_reconcile_test.cpp
    xcom_core/tests/rx_reject_count_test.cpp
    xcom_core/tests/open_pin_warning_test.cpp
)

fail=0
for tu in "${TUS[@]}"; do
    if [ ! -f "$tu" ]; then
        echo "MISSING $tu"
        fail=1
        continue
    fi
    # Collect diagnostics; a TU passes only when no error: line is emitted.
    out=$(g++ -fsyntax-only -std=c++17 -Wall -Wextra "${INCLUDES[@]}" "$tu" 2>&1)
    if grep -q 'error:' <<< "$out"; then
        echo "FAIL  $tu"
        grep 'error:' <<< "$out" | head -10
        fail=1
    else
        echo "OK    $tu"
    fi
done

if [ "$fail" -ne 0 ]; then
    echo
    echo "C++ syntax check FAILED (see the error lines above)."
fi
exit "$fail"
