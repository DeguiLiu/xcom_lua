// Minimal SetupAPI stand-in for tools/check_cpp_syntax.sh (Linux -fsyntax-only).
// Declares (never defines) only the surface serial_backend_win.cpp uses to read
// a port's SPDRP_HARDWAREID. Layouts are NOT ABI-accurate; the real Windows SDK
// is authoritative and is what an MSVC build compiles against.
#pragma once
#include "windows.h"

typedef struct _GUID {
    unsigned long Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char Data4[8];
} GUID;

typedef void* HDEVINFO;

struct SP_DEVINFO_DATA {
    DWORD cbSize;
    GUID ClassGuid;
    DWORD DevInst;
    ULONG_PTR Reserved;
};

#define DIGCF_PRESENT 0x00000002UL
#define DIGCF_ALLCLASSES 0x00000004UL
#define DIGCF_DEVICEINTERFACE 0x00000010UL
#define DICS_FLAG_GLOBAL 0x00000001UL
#define DICS_FLAG_CONFIGSPECIFIC 0x00000002UL
#define DIREG_DEV 0x00000001UL
#define SPDRP_HARDWAREID 0x00000000UL
#define SPDRP_FRIENDLYNAME 0x0000000CUL

HDEVINFO WINAPI SetupDiGetClassDevsA(const GUID*, const char*, HWND, DWORD);
BOOL WINAPI SetupDiEnumDeviceInfo(HDEVINFO, DWORD, SP_DEVINFO_DATA*);
HKEY WINAPI SetupDiOpenDevRegKey(HDEVINFO, SP_DEVINFO_DATA*, DWORD, DWORD,
                                 DWORD, DWORD);
BOOL WINAPI SetupDiGetDeviceRegistryPropertyA(HDEVINFO, SP_DEVINFO_DATA*, DWORD,
                                              DWORD*, BYTE*, DWORD, DWORD*);
BOOL WINAPI SetupDiDestroyDeviceInfoList(HDEVINFO);
