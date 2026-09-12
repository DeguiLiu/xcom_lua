#pragma once
#include <cstdint>
#include <cstddef>
#include <cstdio>
#include <cstring>
typedef void* HANDLE; typedef void* HWND; typedef void* HKEY;
typedef unsigned long DWORD; typedef unsigned int UINT; typedef int BOOL;
typedef unsigned char BYTE; typedef unsigned short WORD; typedef long LONG;
typedef unsigned long ULONG; typedef long long LONG_PTR; typedef unsigned long long ULONG_PTR;
typedef unsigned long long ULONGLONG;
typedef unsigned long long DWORDLONG; typedef long LSTATUS; typedef const char* LPCSTR;
typedef char* LPSTR; typedef unsigned short ATOM; typedef unsigned int UINT_PTR;
typedef LONG_PTR LRESULT; typedef UINT_PTR WPARAM; typedef LONG_PTR LPARAM;
#define WINAPI __attribute__((stdcall))
#define CALLBACK
#define TRUE 1
#define FALSE 0
#define INVALID_HANDLE_VALUE ((HANDLE)(LONG_PTR)-1)
#define ERROR_SUCCESS 0UL
#define MAXDWORD 0xFFFFFFFFUL
#define INFINITE 0xFFFFFFFFUL
#define WAIT_OBJECT_0 0UL
#define WAIT_TIMEOUT 258UL
#define ERROR_IO_PENDING 997UL
#define ERROR_OPERATION_ABORTED 995UL
#define ERROR_DEVICE_REMOVED 1167UL
#define ERROR_ACCESS_DENIED 5UL
#define ERROR_INVALID_HANDLE 6UL
#define ERROR_FILE_NOT_FOUND 2UL
#define ERROR_INVALID_PARAMETER 87UL
#define ERROR_TIMEOUT 1460UL
#define ERROR_NOT_ENOUGH_MEMORY 8UL
#define ERROR_WRITE_FAULT 29UL
#define ERROR_NO_MORE_ITEMS 259UL
#define ERROR_PATH_NOT_FOUND 3UL
#define ERROR_INVALID_DATA 13UL
#define ERROR_NOT_SUPPORTED 50UL
#define ERROR_SEM_TIMEOUT 121UL
#define ERROR_BAD_COMMAND 22UL
#define ERROR_IO_DEVICE 1117UL
#define ERROR_NO_SYSTEM_RESOURCES 1450UL
#define ERROR_NOT_READY 21UL
#define GENERIC_READ 0x80000000UL
#define GENERIC_WRITE 0x40000000UL
#define OPEN_EXISTING 3UL
#define FILE_ATTRIBUTE_NORMAL 0x80UL
#define FILE_FLAG_OVERLAPPED 0x40000000UL
#define ONE5STOPBITS 1
#define ONESTOPBIT 0
#define TWOSTOPBITS 2
#define NOPARITY 0
#define ODDPARITY 1
#define EVENPARITY 2
#define MARKPARITY 3
#define SPACEPARITY 4
#define DTR_CONTROL_DISABLE 0
#define DTR_CONTROL_ENABLE 1
#define RTS_CONTROL_DISABLE 0
#define RTS_CONTROL_ENABLE 1
#define RTS_CONTROL_HANDSHAKE 2
#define SETRTS 3
#define CLRRTS 4
#define SETDTR 5
#define CLRDTR 6
#define CE_RXOVER 0x0001
#define CE_OVERRUN 0x0002
#define CE_RXPARITY 0x0004
#define CE_FRAME 0x0008
#define CE_BREAK 0x0010
#define KEY_QUERY_VALUE 0x0001
#define REG_SZ 1
#define REG_NONE 0
#define HKEY_LOCAL_MACHINE ((HKEY)(ULONG_PTR)0x80000002ULL)
struct OVERLAPPED { ULONG_PTR Internal, InternalHigh; union { struct { DWORD Offset, OffsetHigh; }; void* Pointer; }; HANDLE hEvent; };
struct COMSTAT { DWORD fCtsHold:1, fDsrHold:1, fRlsdHold:1, fXoffHold:1, fXoffSent:1, fEof:1, fTxim:1, fReserved:25, cbInQue, cbOutQue; };
struct DCB { DWORD DCBlength, BaudRate; DWORD fBinary:1,fParity:1,fOutxCtsFlow:1,fOutxDsrFlow:1,fDtrControl:2,fDsrSensitivity:1,fTXContinueOnXoff:1,fOutX:1,fInX:1,fErrorChar:1,fNull:1,fRtsControl:2,fAbortOnError:1,fDummy2:17; WORD wReserved; WORD XonLim, XoffLim; BYTE ByteSize, Parity, StopBits, XonChar, XoffChar, ErrorChar, EofChar, EvtChar; WORD wReserved1; };
struct COMMTIMEOUTS { DWORD ReadIntervalTimeout, ReadTotalTimeoutMultiplier, ReadTotalTimeoutConstant, WriteTotalTimeoutMultiplier, WriteTotalTimeoutConstant; };
struct SECURITY_ATTRIBUTES { DWORD nLength; void* lpSecurityDescriptor; BOOL bInheritHandle; };
typedef void* LPVOID; typedef const void* LPCVOID;
struct _FILETIME { DWORD dwLowDateTime, dwHighDateTime; };
HANDLE WINAPI CreateFileW(const wchar_t*, DWORD, DWORD, SECURITY_ATTRIBUTES*, DWORD, DWORD, HANDLE);
HANDLE WINAPI CreateEventW(SECURITY_ATTRIBUTES*, BOOL, BOOL, const wchar_t*);
BOOL WINAPI CloseHandle(HANDLE);
BOOL WINAPI SetEvent(HANDLE);
BOOL WINAPI ResetEvent(HANDLE);
DWORD WINAPI WaitForSingleObject(HANDLE, DWORD);
DWORD WINAPI WaitForMultipleObjects(DWORD, const HANDLE*, BOOL, DWORD);
BOOL WINAPI GetOverlappedResult(HANDLE, OVERLAPPED*, DWORD*, BOOL);
BOOL WINAPI CancelIoEx(HANDLE, OVERLAPPED*);
BOOL WINAPI ReadFile(HANDLE, void*, DWORD, DWORD*, OVERLAPPED*);
BOOL WINAPI WriteFile(HANDLE, const void*, DWORD, DWORD*, OVERLAPPED*);
BOOL WINAPI GetCommState(HANDLE, DCB*);
BOOL WINAPI SetCommState(HANDLE, DCB*);
BOOL WINAPI GetCommTimeouts(HANDLE, COMMTIMEOUTS*);
BOOL WINAPI SetCommTimeouts(HANDLE, COMMTIMEOUTS*);
BOOL WINAPI SetupComm(HANDLE, DWORD, DWORD);
BOOL WINAPI PurgeComm(HANDLE, DWORD);
BOOL WINAPI ClearCommError(HANDLE, DWORD*, COMSTAT*);
BOOL WINAPI EscapeCommFunction(HANDLE, DWORD);
BOOL WINAPI FlushFileBuffers(HANDLE);
BOOL WINAPI IsWindow(HWND);
DWORD WINAPI GetLastError(void);
void WINAPI SetLastError(DWORD);
DWORD WINAPI GetCurrentThreadId(void);
void WINAPI Sleep(DWORD);
LSTATUS WINAPI RegOpenKeyExA(HKEY, const char*, DWORD, DWORD, HKEY*);
LSTATUS WINAPI RegEnumValueA(HKEY, DWORD, char*, DWORD*, DWORD*, DWORD*, BYTE*, DWORD*);
LSTATUS WINAPI RegCloseKey(HKEY);
int WINAPI MultiByteToWideChar(UINT, DWORD, const char*, int, wchar_t*, int);
#define CP_UTF8 65001
#define MB_ERR_INVALID_CHARS 0x00000008

HANDLE WINAPI GetCurrentThread(void);
BOOL WINAPI SetThreadPriority(HANDLE, int);
#define THREAD_PRIORITY_ABOVE_NORMAL 1
typedef long long LONGLONG_SAFE;
union LARGE_INTEGER { struct { DWORD LowPart; LONG HighPart; }; long long QuadPart; };
BOOL WINAPI QueryPerformanceCounter(LARGE_INTEGER*);
BOOL WINAPI QueryPerformanceFrequency(LARGE_INTEGER*);
DWORD WINAPI GetEnvironmentVariableA(const char*, char*, DWORD);
typedef struct _SYSTEMTIME { WORD wYear,wMonth,wDayOfWeek,wDay,wHour,wMinute,wSecond,wMilliseconds; } SYSTEMTIME;
void WINAPI GetLocalTime(SYSTEMTIME*);
void WINAPI GetSystemTime(SYSTEMTIME*);
HANDLE WINAPI CreateFileA(const char*, DWORD, DWORD, SECURITY_ATTRIBUTES*, DWORD, DWORD, HANDLE);
BOOL WINAPI CreateDirectoryA(const char*, SECURITY_ATTRIBUTES*);
DWORD WINAPI GetFileAttributesA(const char*);
#define INVALID_FILE_ATTRIBUTES 0xFFFFFFFFUL
#define FILE_ATTRIBUTE_DIRECTORY 0x10UL
DWORD WINAPI GetTickCount(void);
ULONGLONG WINAPI GetTickCount64(void);
#define CREATE_ALWAYS 2UL
#define OPEN_ALWAYS 4UL
#define FILE_SHARE_READ 1UL
#define FILE_SHARE_WRITE 2UL
#define FILE_SHARE_DELETE 4UL
#define MOVEFILE_REPLACE_EXISTING 1UL
BOOL WINAPI MoveFileExA(const char*, const char*, DWORD);
BOOL WINAPI DeleteFileA(const char*);

// MSVC spells the x86 calling convention __stdcall; GCC needs the attribute.
#define __stdcall __attribute__((stdcall))

#define THREAD_PRIORITY_NORMAL 0
#define THREAD_PRIORITY_LOWEST -2
#define THREAD_PRIORITY_HIGHEST 2
BOOL WINAPI SetThreadPriority(HANDLE, int);
