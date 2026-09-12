#!/usr/bin/env bash
# check_cpp_syntax.sh - compiler-level syntax check for the Win32 sources.
#
# The real build needs MSVC on Windows (CMakeLists.txt hard-requires WIN32, and
# the sources include <windows.h>, <winreg.h>, DirectX 11 and the ImGui backends).
# That means a Linux developer can otherwise only eyeball a C++ change, which is
# how a bad cast sat unnoticed in the close path.
#
# This script supplies a minimal windows.h stand-in (tools/win32-stub) and runs
# g++ -fsyntax-only over the translation units that carry the serial/ABI logic.
# It catches syntax errors, type errors and missing declarations. It does NOT
# substitute for an MSVC build: it cannot validate anything that depends on real
# Windows headers, calling conventions or the DX11 device, and it skips the
# wide-char and atomic-width paths the stub does not model.
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
    -Ixcom_core/framework/coact/include
)

# The translation units that hold the serial backend, the ABI plumbing and the
# diagnostics writer, plus the hardware-free tests that cover them. Files whose
# errors trace to stub limitations (wide-char Win32 APIs, coact's atomic-width
# static assertions) are deliberately not listed: a red result here must mean a
# real defect, or the check gets ignored.
TUS=(
    xcom_core/src/io/serial_backend_win.cpp
    xcom_core/src/diagnostics/diagnostic.cpp
    # The two files that carry the port state machine: the HSM transition table
    # and the owner sinks in xcom_core.cpp, and the actions in xcom_ao.cpp. A
    # transition or an action that does not compile is a state machine that
    # silently stops transitioning, so they belong in this gate.
    xcom_core/src/ao/xcom_ao.cpp
    xcom_core/src/runtime/xcom_core.cpp
    xcom_core/src/abi/xcom_abi.cpp
    xcom_core/tests/line_control_test.cpp
    xcom_core/tests/line_error_test.cpp
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
