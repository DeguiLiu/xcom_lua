// Minimal initguid.h stand-in for tools/check_cpp_syntax.sh. The real header
// makes DEFINE_GUID instantiate a GUID definition in the including TU; for the
// stub it is enough to define INITGUID, which devguid.h honours.
#pragma once
#ifndef INITGUID
#define INITGUID
#endif
