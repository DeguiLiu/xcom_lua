// Minimal devguid.h stand-in for tools/check_cpp_syntax.sh. The real header
// defines the device setup-class GUIDs; serial_backend_win.cpp uses only
// GUID_DEVCLASS_PORTS. With INITGUID (initguid.h) the definition is
// instantiated in the TU, otherwise only declared.
#pragma once
#include "setupapi.h"

#ifdef INITGUID
const GUID GUID_DEVCLASS_PORTS = {
    0x4d36e978UL, 0xe325, 0x11ce,
    {0xbf, 0xc1, 0x08, 0x00, 0x2b, 0xe1, 0x03, 0x18}};
#else
extern const GUID GUID_DEVCLASS_PORTS;
#endif
