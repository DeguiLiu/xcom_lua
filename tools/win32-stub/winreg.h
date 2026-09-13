#pragma once
#include "windows.h"

// Registry value read, used by the PnP hardware-id enumeration in
// serial_backend_win.cpp (PortName under a device's Device Parameters key).
LSTATUS WINAPI RegQueryValueExA(HKEY, const char*, DWORD*, DWORD*, BYTE*,
                                DWORD*);
