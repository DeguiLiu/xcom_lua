# XCOM C++ Frameworks

XCOM consumes the coact event runtime from an **external checkout**, not from a
vendored copy in this tree. The `windows` branch of that checkout carries the
Win32 PAL adapter XCOM needs.

The include root is resolved by the `XCOM_COACT_ROOT` cache variable (default
`../../coact` relative to `xcom_core/`, i.e. `<workspace>/coact`); see
`xcom_core/CMakeLists.txt` and `tools/check_cpp_syntax.sh`. XCOM includes only
`coact/include` and does not add coact's standalone test or example CMake
project to the product build.

XCOM's own C++ stays in `../src`: the versioned ABI, the Win32 serial backend,
the file writer and the product-specific Active Objects. The Windows PAL is the
one coact ships on its `windows` branch — the product compiles coact's own
`src/core/pal_windows.cpp` rather than carrying a second implementation, and
binds it to a real `SpinCriticalSection` because irq masking is a no-op on an
SMP host. Keeping the boundary explicit prevents a product helper from becoming
a second scheduler or queue implementation.
