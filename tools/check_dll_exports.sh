#!/usr/bin/env bash
# Compare the functions the Lua FFI layer DECLARES with the ones the shipped
# runtime DLLs actually EXPORT.
#
# Why this exists.  Twice now the tree has carried a Lua/cdef change whose
# matching binary was never rebuilt: the DLL in xcom_lua/runtime/ kept the old
# implementation, every new widget or snapshot field degraded silently (the
# optional_export() fallbacks exist precisely so it degrades instead of
# crashing), and nothing in CI noticed because the Windows job builds the DLL
# into its own build tree and never compares it with the tracked one.  The
# mismatch is invisible at run time by design, so it has to be caught here.
#
# This is a SYMBOL check, not a behavioural one: it cannot run the DLLs.  It
# answers one question -- "is the committed binary in step with the source?" --
# and it is the cheap half of the ABI gate whose runtime half is
# tools/hw-tests/abi_pins.lua (Windows only).
#
# Usage: tools/check_dll_exports.sh          # exit 1 on a missing export
#        OBJDUMP=... tools/check_dll_exports.sh
#
# SPDX-License-Identifier: MIT
set -u

cd "$(dirname "$0")/.." || exit 2

OBJDUMP="${OBJDUMP:-objdump}"
if ! command -v "$OBJDUMP" >/dev/null 2>&1; then
    echo "SKIP  no objdump: cannot read PE export tables"
    exit 0
fi

fail=0

# exports_of <dll> -> one xcom_* symbol per line, sorted.
# Restricted to the xcom_ prefix on purpose: objdump -p also prints the
# relocation table, whose entries share the "[ N] NAME" shape, and the ABI
# question here is only about the xcom_ functions the Lua layer calls.
exports_of() {
    "$OBJDUMP" -p "$1" 2>/dev/null |
        sed -n 's/.*\[[[:space:]]*[0-9]*\][[:space:]]*\(xcom_[A-Za-z0-9_]*\)$/\1/p' |
        sort -u
}

# declared_in <lua-file> <regex> -> one symbol per line, sorted
declared_in() {
    grep -oE "xcom_[a-z0-9_]+[[:space:]]*\(" "$1" |
        sed 's/[[:space:]]*($//;s/($//' |
        sort -u
}

# check <label> <dll> <lua-file>
check() {
    local label="$1" dll="$2" lua="$3"
    if [ ! -f "$dll" ]; then
        echo "SKIP  $label: $dll not present"
        return
    fi
    if [ ! -f "$lua" ]; then
        echo "FAIL  $label: $lua not present (the declaration side is gone)"
        fail=1
        return
    fi
    local exports declared missing extra
    exports=$(exports_of "$dll")
    declared=$(declared_in "$lua")
    missing=$(comm -23 <(printf '%s\n' "$declared") <(printf '%s\n' "$exports"))
    extra=$(comm -13 <(printf '%s\n' "$declared") <(printf '%s\n' "$exports"))
    if [ -n "$missing" ]; then
        echo "FAIL  $label: declared in $(basename "$lua") but NOT exported by $dll"
        printf '        %s\n' $missing
        echo "        -> rebuild $dll on Windows and commit it (see"
        echo "           xcom_lua/native/xcom_imgui/README.md for the commands)."
        fail=1
    else
        echo "OK    $label: every declared symbol is exported"
    fi
    if [ -n "$extra" ]; then
        # Not a failure and not listed by name: the core legitimately exports
        # C-side entry points the Lua layer never calls (file streams, test
        # hooks), so an enumeration here would be permanent noise on a green
        # tree. The count still surfaces the other direction of drift -- a
        # binary built from a newer source than the one committed.
        echo "INFO  $label: $(( $(printf '%s\n' "$extra" | wc -l) )) exported symbol(s) this Lua layer does not call"
    fi
}

check "xcom_core"  "xcom_lua/runtime/xcom_core.dll"  "xcom_lua/core/xcom_ffi.lua"
check "xcom_imgui" "xcom_lua/runtime/xcom_imgui.dll" "xcom_lua/ui/imgui_bridge.lua"

if [ "$fail" -ne 0 ]; then
    echo
    echo "DLL export check FAILED: the committed binary is behind the source."
    exit 1
fi
echo
echo "DLL export check OK: the committed binaries match the declared ABI."
