--[[--------------------------------------------------------------------------
ui/win32.lua - minimal Win32 API + GDI ffi.cdef binding for the serial client.

Declares only the Win32 subset the client uses: window/class registration,
message loop, common controls, GDI drawing, fonts/brushes, and the RICHEDIT
control's message contract.  All numeric constants are Lua scalars (no Windows
headers), so the module is `require`-safe on Linux for syntax/scoping checks.
DLL symbols are resolved lazily by load() on a Windows host.

Windows colour convention: COLORREF is a DWORD 0x00BBGGRR.  The RGB(r,g,b)
packing used throughout equals r + g*0x100 + b*0x10000.

Follows the OpenResty/LuaJIT module convention.
------------------------------------------------------------------------]]--

local ffi = require("ffi")

local M = {}

-- ---------------------------------------------------------------------------
-- Colour helper (0x00BBGGRR, the Win32 COLORREF layout).
-- ---------------------------------------------------------------------------
function M.rgb(r, g, b)
    return r + (g * 256) + (b * 65536)
end

-- Convert an ANSI palette integer 0xRRGGBB (see core/ansi.lua) into Win32
-- COLORREF form 0x00BBGGRR.  Bit-select each channel and repack.
function M.from_ansi_rgb(v)
    local r = math.floor(v / 65536) % 256
    local g = math.floor(v / 256) % 256
    local b = v % 256
    return M.rgb(r, g, b)
end

-- ---------------------------------------------------------------------------
-- Numeric constants (mirrored from Windows SDK).
-- ---------------------------------------------------------------------------
M.OPAQUE_WIDTH = 640
M.OPAQUE_HEIGHT = 480

-- Code pages for the UTF-8 <-> UTF-16 helpers below (kernel32).
M.CP_UTF8 = 65001
M.CP_ACP = 0

M.ofn = {
    OFN_OVERWRITEPROMPT = 0x00000002,
    OFN_HIDEREADONLY = 0x00000004,
    OFN_PATHMUSTEXIST = 0x00000800,
    OFN_FILEMUSTEXIST = 0x00001000,
    OFN_EXPLORER = 0x00080000,
    -- Installs lpfnHook, which is what keeps the luv receive drain alive
    -- inside the dialog's own modal message loop (Window:_ensure_ofn_hook).
    OFN_ENABLEHOOK = 0x00000020,
}

M.style = {
    WS_POPUP = 0x80000000,
    WS_VISIBLE = 0x10000000,
    WS_CLIPSIBLINGS = 0x04000000,
    WS_CLIPCHILDREN = 0x02000000,
    WS_CHILD = 0x40000000,
    WS_BORDER = 0x00800000,
    WS_CAPTION = 0x00C00000,
    WS_SYSMENU = 0x00080000,
    WS_THICKFRAME = 0x00040000,
    WS_MINIMIZEBOX = 0x00020000,
    WS_MAXIMIZEBOX = 0x00010000,
    WS_TABSTOP = 0x00010000,
    WS_OVERLAPPED = 0x00000000,
    WS_EX_TRANSPARENT = 0x00000020,
    WS_EX_TOOLWINDOW = 0x00000080,
    WS_EX_WINDOWEDGE = 0x00000100,
    WS_EX_CLIENTEDGE = 0x00000200,
    WS_EX_APPWINDOW = 0x00040000,
    SW_SHOW = 5,
    SW_SHOWNORMAL = 1,
    SW_HIDE = 0,
    SW_RESTORE = 9,
    SW_MAXIMIZE = 3,
    SW_MINIMIZE = 6,
    -- SetWindowPos flags / insert-after pseudo-handles.
    SWP_NOSIZE = 0x0001,
    SWP_NOMOVE = 0x0002,
    SWP_NOACTIVATE = 0x0010,
    HWND_TOPMOST = -1,
    HWND_NOTOPMOST = -2,
}

M.wait = {
    -- Queue-status wake mask for MsgWaitForMultipleObjectsEx: any input
    -- (mouse/keyboard/posted messages, paint, timer, posted-quit).
    QS_ALLINPUT = 0x04FF,
    -- MWMO_INPUTAVAILABLE: return immediately if messages are ALREADY queued
    -- (without it a stale peeked-empty queue could block a full timeout).
    MWMO_INPUTAVAILABLE = 0x0002,
    WAIT_TIMEOUT = 0x00000102,
    WAIT_OBJECT_0 = 0x00000000,
}

M.image = {
    ICON = 1,
    LOAD_FROM_FILE = 0x00000010,
    DEFAULT_SIZE = 0x00000040,
    -- LR_SHARED: hand back the cached resource image instead of a private
    -- copy. Required for a resource loaded from the module and never freed.
    LOAD_SHARED = 0x00008000,
}

-- Icon resource id in the launcher (.rc: `IDI_APP ICON "xcom.ico"`).
M.IDI_APP = 1

-- Standard fallback so a window always gets SOME icon: IDI_APPLICATION is a
-- predefined resource, so LoadIconA resolves it without any file or module.
M.IDI_APPLICATION = 32512

M.ctrl = {
    Button = "Button",
    Edit = "Edit",
    ComboBox = "ComboBox",
    Static = "Static",
    ListView = "SysListView32",
}

M.bs = {
    BS_PUSHBUTTON = 0x0000,
    BS_DEFPUSHBUTTON = 0x0001,
    BS_CHECKBOX = 0x0002,
    BS_AUTOCHECKBOX = 0x0003,
    BS_GROUPBOX = 0x0007,
    BS_OWNERDRAW = 0x000B,
}

M.es = {
    ES_LEFT = 0x0000,
    ES_MULTILINE = 0x0004,
    ES_UPPERCASE = 0x0008,
    ES_AUTOVSCROLL = 0x0040,
    ES_AUTOHSCROLL = 0x0080,
    ES_READONLY = 0x0800,
    ES_WANTRETURN = 0x1000,
    ES_NOHIDESEL = 0x0100,
}

M.cbs = {
    CBS_DROPDOWNLIST = 0x00000003,
    CBS_HASSTRINGS = 0x00000020,
}

M.wm = {
    WM_CREATE = 0x0001,
    WM_DESTROY = 0x0002,
    WM_SETTEXT = 0x000C,
    WM_SETFONT = 0x0030,
    WM_GETTEXT = 0x000D,
    WM_GETTEXTLENGTH = 0x000E,
    WM_PAINT = 0x000F,
    WM_CLOSE = 0x0010,
    WM_ERASEBKGND = 0x0014,
    WM_MOUSEHWHEEL = 0x020E,
    WM_SETCURSOR = 0x0020,
    WM_GETMINMAXINFO = 0x0024,
    WM_SIZE = 0x0005,
    WM_COMMAND = 0x0111,
    WM_NCHITTEST = 0x0084,
    WM_MOUSEMOVE = 0x0200,
    WM_LBUTTONDOWN = 0x0201,
    WM_LBUTTONUP = 0x0202,
    WM_LBUTTONDBLCLK = 0x0203,
    WM_MOUSEWHEEL = 0x020A,
    WM_KEYDOWN = 0x0100,
    WM_SYSKEYDOWN = 0x0104,
    WM_TIMER = 0x0113,
    WM_NOTIFY = 0x004E,
    WM_VSCROLL = 0x0115,
    WM_SYSCOMMAND = 0x0112,
    WM_CTLCOLORBTN = 0x0135,
    WM_CTLCOLOREDIT = 0x0133,
    WM_CTLCOLORLISTBOX = 0x0134,
    WM_CTLCOLORSTATIC = 0x0138,
    WM_CTLCOLORDLG = 0x0136,
    WM_NCLBUTTONDOWN = 0x00A1,
    WM_NCLBUTTONDBLCLK = 0x00A3,
    WM_NCRBUTTONUP = 0x00A7,
    WM_QUIT = 0x0012,
    -- Broadcast to every top-level window when the device tree changes; see
    -- M.dbt for the wParam values (only DEVNODES_CHANGED is needed here).
    WM_DEVICECHANGE = 0x0219,
}

-- WM_DEVICECHANGE wParam values (WinUser.h DBT_*).  DBT_DEVNODES_CHANGED is
-- broadcast to all top-level windows on ANY device-node addition/removal, so a
-- USB plug/unplug or a USB-CDC MCU powering up/down is seen without calling
-- RegisterDeviceNotification (that is only needed for the more specific
-- DBT_DEVTYP_* interface/volume events, which we do not handle).
M.dbt = {
    DBT_DEVNODES_CHANGED = 0x0007,
}

M.ht = {
    HTCAPTION = 2,
    HTCLIENT = 1,
    HTLEFT = 10,
    HTRIGHT = 11,
    HTTOP = 12,
    HTTOPLEFT = 13,
    HTTOPRIGHT = 14,
    HTBOTTOM = 15,
    HTBOTTOMLEFT = 16,
    HTBOTTOMRIGHT = 17,
    HTTRANSPARENT = -1,
}

M.sc = {
    SC_SIZE = 0xF000,
    SC_MAXIMIZE = 0xF030,
    SC_RESTORE = 0xF120,
    SC_CLOSE = 0xF060,
}

M.cb = {
    CB_GETCOUNT = 0x0146,
    CB_ADDSTRING = 0x0143,
    CB_SETCURSEL = 0x014E,
    CB_GETCURSEL = 0x0147,
    CB_GETLBTEXTLEN = 0x0149,
    CB_GETLBTEXT = 0x0148,
    CB_RESETCONTENT = 0x014B,
}

M.bm = {
    BM_SETCHECK = 0x00F1,
    BM_GETCHECK = 0x00F0,
    BM_CLICK = 0x00F5,
    BM_SETSTATE = 0x00F3,
}

M.em = {
    -- Edit/RichEdit controls have no dedicated EM_GETTEXTLENGTH; the length is
    -- queried with the generic WM_GETTEXTLENGTH (0x000E).  Kept under M.em so
    -- receive_view reads it alongside the other EM_* it sends.
    EM_GETTEXTLENGTH = 0x000E,
    EM_SETSEL = 0x00B1,
    EM_REPLACESEL = 0x00C2,
    EM_SETCHARFORMAT = 0x00000444,  -- WM_USER + 68
    EM_GETSEL = 0x00B0,
    EM_GETSELTEXT = 0x00000403,
    EM_SCROLL = 0x00B5,
    EM_LINESCROLL = 0x00B6,
    EM_SETREADONLY = 0x00CF,
    EM_SETLIMITTEXT = 0x00C5,
}

M.characterFormatMask = {
    CFM_BOLD = 0x00000001,
    CFM_ITALIC = 0x00000002,
    CFM_COLOR = 0x40000000,
    CFM_BACKCOLOR = 0x04000000,
}

M.sysColor = {
    COLOR_WINDOW = 5,
    COLOR_BTNFACE = 15,
    COLOR_WINDOWTEXT = 8,
    COLOR_BTNTEXT = 18,
}

-- Standard pens/brushes for GetStockObject.
M.stock = {
    WHITE_BRUSH = 0,
    LTGRAY_BRUSH = 1,
    GRAY_BRUSH = 2,
    DKGRAY_BRUSH = 3,
    BLACK_BRUSH = 4,
    NULL_BRUSH = 5,
    WHITE_PEN = 6,
    BLACK_PEN = 7,
    DEFAULT_GUI_FONT = 17,
}

M.transparent = 1    -- SRCPAINT/SRCCOPY? no: OPAQUE = 2, TRANSPARENT = 1 for SetBkMode
M.opa = { TRANSPARENT = 1, OPAQUE = 2 }

M.updateFlush = { UPDATE_CLIENT = 2 }

M.SM_CXSCREEN = 0
M.SM_CYSCREEN = 1

M.logFontWeight = {
    FW_NORMAL = 400,
    FW_BOLD = 700,
}

M.charSet = { ANSI_CHARSET = 0, DEFAULT_CHARSET = 1 }
M.gdiPitch = { DEFAULT_PITCH = 0 }
M.fontQuality = { DEFAULT_QUALITY = 0, CLEARTYPE_QUALITY = 5, ANTIALIASED_QUALITY = 4 }
M.clipPrecision = { CLIP_DEFAULT_PRECIS = 0 }
M.outputPrecision = { OUT_DEFAULT_PRECIS = 0 }

M.textAlign = { TA_LEFT = 0, TA_CENTER = 1, TA_RIGHT = 2, TA_TOP = 0, TA_BOTTOM = 8 }

-- GDI constants for the waveform popup (wingdi.h).
M.gdi = {
    PS_SOLID = 0,
    SRCCOPY = 0x00CC0020,
    BI_RGB = 0,
    DIB_RGB_COLORS = 0,
    IDC_ARROW = 32512,
}

-- ---------------------------------------------------------------------------
-- FFI declarations (definitions only; resolved lazily by load()).
-- ---------------------------------------------------------------------------
-- RICHEDIT control uses its own window class name "RichEdit20A".
M.ctrl.RichEdit20A = "RichEdit20A"

ffi.cdef[[
typedef int LONG;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef unsigned short WORD;
typedef int BOOL;
typedef unsigned char BYTE;
typedef char CHAR;
/* WPARAM is UINT_PTR (unsigned); LPARAM is LONG_PTR (signed) — verified
 * against ref/win32_api_luajit-master/winapi_winusertypes.lua. */
typedef uintptr_t WPARAM;
typedef intptr_t LPARAM;
typedef void* HANDLE;
typedef void* HGDIOBJ;
typedef struct HWND__* HWND;
typedef struct HDC__* HDC;
typedef struct HBRUSH__* HBRUSH;
typedef struct HPEN__* HPEN;
typedef struct HFONT__* HFONT;
typedef struct HBITMAP__* HBITMAP;
typedef struct HICON__* HICON;
typedef struct HCURSOR__* HCURSOR;
typedef struct HINSTANCE__* HINSTANCE;
typedef struct HMODULE__* HMODULE;
typedef const char* LPCSTR;
typedef char* LPSTR;
typedef unsigned short WCHAR;
typedef const unsigned short* LPCWSTR;
typedef unsigned short* LPWSTR;
typedef void* LPVOID;
typedef int ATOM;

typedef struct { LONG left; LONG top; LONG right; LONG bottom; } RECT;
typedef struct { LONG x; LONG y; } POINT;
typedef struct { LONG cx; LONG cy; } SIZE;
typedef DWORD COLORREF;
typedef DWORD LCID;

/* Paint info for BeginPaint/EndPaint (wingdi.h PAINTSTRUCT). */
typedef struct {
    HDC hdc;
    BOOL fErase;
    RECT rcPaint;
    BOOL fRestore;
    BOOL fIncUpdate;
    BYTE rgbReserved[32];
} PAINTSTRUCT;

/* LRESULT on x64 is LONG_PTR (8 bytes); declaring this LONG (4 bytes) would
 * truncate the high 32 bits of every value the WndProc callback returns
 * (DefWindowProcA's return, or any pointer-sized result forwarded through
 * WM_NOTIFY/WM_CTLCOLOR* handlers that return an HBRUSH cast to intptr_t). */
typedef intptr_t (__stdcall *WNDPROC)(HWND, UINT, WPARAM, LPARAM);

/* Plain WNDCLASS layout: 10 fields, no leading cbSize. The WNDCLASSEX layout
 * is a different struct (leading cbSize + trailing hIconSm); passing that to
 * RegisterClass shifts every field by 4 bytes, so lpfnWndProc would read the
 * `style` value and corrupt the window procedure pointer on the first call.
 *
 * This is the ANSI (A) side: lpszMenuName/lpszClassName are LPCSTR, so it must
 * be registered with RegisterClassA and paired with DefWindowProcA. Passing an
 * ANSI class-name pointer to RegisterClassW would have it decoded as UTF-16,
 * producing a garbage class name that the later CreateWindowExA lookup cannot
 * find. The whole UI layer uses *A entry points (CreateWindowExA,
 * SetWindowTextA, TextOutA), so A is the consistent side here. */
typedef struct {
    UINT style;
    WNDPROC lpfnWndProc;
    int cbClsExtra;
    int cbWndExtra;
    HINSTANCE hInstance;
    HICON hIcon;
    HCURSOR hCursor;
    HBRUSH hbrBackground;
    LPCSTR lpszMenuName;
    LPCSTR lpszClassName;
} WNDCLASSA;

typedef struct {
    UINT cbSize;
    LONG lfHeight;
    LONG lfWidth;
    LONG lfEscapement;
    LONG lfOrientation;
    LONG lfWeight;
    BYTE lfItalic;
    BYTE lfUnderline;
    BYTE lfStrikeOut;
    BYTE lfCharSet;
    BYTE lfOutPrecision;
    BYTE lfClipPrecision;
    BYTE lfQuality;
    BYTE lfPitchAndFamily;
    CHAR lfFaceName[32];
} LOGFONTW;

typedef struct {
    UINT cbSize;
    DWORD dwMask;
    DWORD dwEffects;
    LONG yHeight;
    LONG yOffset;
    COLORREF crTextColor;
    BYTE bCharSet;
    BYTE bPitchAndFamily;
    CHAR szFaceName[32];
    WORD wWeight;
    short sSpacing;
    COLORREF crBackColor;
    LCID lcid;
    DWORD dwReserved;
    short sStyle;
    WORD wKerning;
    BYTE bUnderlineType;
    BYTE bAnimation;
    BYTE bRevAuthor;
    BYTE bUnderlineColor;
} CHARFORMAT2A;

typedef struct MSG MSG;

typedef struct {
    DWORD dwSize;
    DWORD dwICC;
} INITCOMMONCONTROLSEX;

HINSTANCE GetModuleHandleA(LPCSTR lpModuleName);
DWORD GetModuleFileNameA(HINSTANCE hModule, char* lpFilename, DWORD nSize);
HWND CreateWindowExA(DWORD dwExStyle, LPCSTR lpClassName, LPCSTR lpWindowName,
                     DWORD dwStyle, int x, int y, int nWidth, int nHeight,
                     HWND hWndParent, void* hMenu, HINSTANCE hInstance, LPVOID lpParam);
BOOL DestroyWindow(HWND hWnd);
BOOL ShowWindow(HWND hWnd, int nCmdShow);
BOOL UpdateWindow(HWND hWnd);
HWND GetFocus(void);
BOOL SetFocus(HWND hWnd);
HWND GetParent(HWND hWnd);
BOOL GetClientRect(HWND hWnd, RECT* lpRect);
BOOL GetWindowRect(HWND hWnd, RECT* lpRect);
BOOL MoveWindow(HWND hWnd, int X, int Y, int nWidth, int nHeight, BOOL bRepaint);
BOOL ScreenToClient(HWND hWnd, POINT* lpPoint);
BOOL ClientToScreen(HWND hWnd, POINT* lpPoint);
void SetTimer(HWND hWnd, uintptr_t nIDEvent, UINT uElapse, void* lpTimerFunc);
BOOL KillTimer(HWND hWnd, uintptr_t uIDEvent);
/* Event-driven wait: blocks until a Win32 message of the wake mask arrives or
 * the timeout elapses, whichever is first.  Replaces sleep-polling in the
 * message loop. */
DWORD MsgWaitForMultipleObjectsEx(DWORD nCount, const HANDLE* pHandles,
                                  DWORD dwMilliseconds, DWORD dwWakeMask,
                                  DWORD dwFlags);
HWND GetDesktopWindow(void);
UINT GetDlgCtrlID(HWND hWnd);
HWND GetDlgItem(HWND hWnd, int nIDDlgItem);
void GetTextMetricsA(HDC hdc, void* lptm);
int GetSystemMetrics(int nIndex);
int GetDeviceCaps(HDC hdc, int nIndex);
HGDIOBJ GetStockObject(int fnObject);
int SetBkMode(HDC hdc, int iBkMode);
COLORREF SetBkColor(HDC hdc, COLORREF color);
COLORREF SetTextColor(HDC hdc, COLORREF color);
int SetTextAlign(HDC hdc, UINT fMode);
HDC GetDC(HWND hWnd);
int ReleaseDC(HWND hWnd, HDC hDC);
HDC BeginPaint(HWND hWnd, PAINTSTRUCT* lpPaint);
BOOL EndPaint(HWND hWnd, const PAINTSTRUCT* lpPaint);
HBRUSH CreateSolidBrush(COLORREF color);
BOOL DeleteObject(void* hObject);
HFONT CreateFontA(int nHeight, int nWidth, int nEscapement, int nOrientation,
                  int fnWeight, DWORD fdwItalic, DWORD fdwUnderline,
                  DWORD fdwStrikeOut, DWORD fdwCharSet, DWORD fdwOutputPrecision,
                  DWORD fdwClipPrecision, DWORD fdwQuality, DWORD fdwPitchAndFamily,
                  LPCSTR lpszFace);
HGDIOBJ SelectObject(HDC hdc, HGDIOBJ hgdiobj);
BOOL TextOutA(HDC hdc, int x, int y, LPCSTR lpString, int nCount);
BOOL Rectangle(HDC hdc, int left, int top, int right, int bottom);
BOOL FillRect(HDC hdc, const RECT* lpRect, HBRUSH hbr);
BOOL StretchBlt(HDC hdcDest, int xDest, int yDest, int wDest, int hDest,
                HDC hdcSrc, int xSrc, int ySrc, int wSrc, int hSrc, DWORD rop);
BOOL Ellipse(HDC hdc, int left, int top, int right, int bottom);
HDC CreateCompatibleDC(HDC hdc);
HBITMAP CreateCompatibleBitmap(HDC hdc, int cx, int cy);
BOOL DeleteDC(HDC hdc);
int MulDiv(int a, int b, int c);
BOOL TextOutU(HDC hdc, int x, int y, const unsigned short* lpString, int nCount);
int DrawTextA(HDC hdc, LPCSTR lpchText, int cchText, RECT* lprc, UINT format);

void SetWindowTextA(HWND hWnd, const char* lpString);
int GetWindowTextLengthA(HWND hWnd);
int GetWindowTextA(HWND hWnd, char* lpString, int nMaxCount);
intptr_t SendMessageA(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);
intptr_t DefWindowProcA(HWND hWnd, UINT msg, WPARAM wParam, LPARAM lParam);
ATOM RegisterClassA(WNDCLASSA* pWndClass);
void* LoadImageA(HINSTANCE hInst, const char* name, UINT type,
                 int cx, int cy, UINT fuLoad);
HICON LoadIconA(HINSTANCE hInst, const char* name);
BOOL UnregisterClassA(LPCSTR lpClassName, HINSTANCE hInstance);
void PostQuitMessage(int nExitCode);
BOOL TranslateMessage(const MSG* lpMsg);
intptr_t DispatchMessageW(const MSG* lpMsg);
BOOL PeekMessageW(void* lpMsg, HWND hWnd, UINT wMsgFilterMin, UINT wMsgFilterMax, UINT wRemoveMsg);
BOOL GetMessageW(void* lpMsg, HWND hWnd, UINT wMsgFilterMin, UINT wMsgFilterMax);
BOOL GetClassNameW(HWND hWnd, LPWSTR lpClassName, int nMaxCount);

void GetCursorPos(POINT* lpPoint);
BOOL SetCursorPos(int X, int Y);

/* winmm timer resolution: MsgWaitForMultipleObjectsEx sleeps in units of the
 * system timer (15.6 ms by default), which delays the 10 ms luv drain
 * deadline to ~23 ms under a full-bandwidth stream.  timeBeginPeriod(1)
 * raises the resolution process-wide while the app runs. */
UINT timeBeginPeriod(UINT uPeriod);
UINT timeEndPeriod(UINT uPeriod);
HWND WindowFromPoint(POINT pt);
BOOL SetWindowPos(HWND hWnd, HWND hWndInsertAfter, int x, int y, int cx, int cy, UINT uFlags);
BOOL EnableWindow(HWND hWnd, BOOL bEnable);
BOOL IsWindowEnabled(HWND hWnd);
BOOL InvalidateRect(HWND hWnd, RECT* lpRect, BOOL bErase);
HBRUSH GetSysColorBrush(int nIndex);
HBRUSH CreatePatternBrush(HBITMAP hbm);

// message loop msg struct
struct MSG {
    HWND hwnd;
    UINT message;
    WPARAM wParam;
    LPARAM lParam;
    DWORD time;
    POINT pt;
};

// UTF-8 <-> UTF-16 (kernel32).
int MultiByteToWideChar(UINT codePage, DWORD flags, const char* src, int srcLen,
                        unsigned short* dst, int dstLen);
int WideCharToMultiByte(UINT codePage, DWORD flags, const unsigned short* src,
                        int srcLen, char* dst, int dstLen, const char* defChar,
                        BOOL* usedDefChar);

// Common Item Dialog (comdlg32) — save dialog.
// OFN_ENABLEHOOK hook proc, the same shape as LPOFNHOOKPROC in commdlg.h
// (UINT_PTR return, __stdcall).  window.lua installs one via lpfnHook so the
// luv receive drain keeps running while the dialog's modal message loop owns
// the UI thread; see Window:_ensure_ofn_hook for why that is not optional.
typedef uintptr_t (__stdcall *OFNHookProc)(HWND, UINT, WPARAM, LPARAM);
typedef struct {
    DWORD lStructSize;
    HWND hwndOwner;
    HINSTANCE hInstance;
    LPCWSTR lpstrFilter;
    LPWSTR lpstrCustomFilter;
    DWORD nMaxCustFilter;
    DWORD nFilterIndex;
    LPWSTR lpstrFile;
    DWORD nMaxFile;
    LPWSTR lpstrFileTitle;
    DWORD nMaxFileTitle;
    LPCWSTR lpstrInitialDir;
    LPCWSTR lpstrTitle;
    DWORD Flags;
    unsigned short nFileOffset;
    unsigned short nFileExtension;
    LPCWSTR lpstrDefExt;
    LPARAM lCustData;
    OFNHookProc lpfnHook;
    LPCWSTR lpTemplateName;
} OPENFILENAMEW;
BOOL GetSaveFileNameW(OPENFILENAMEW* lpofn);
BOOL GetOpenFileNameW(OPENFILENAMEW* lpofn);
BOOL InitCommonControlsEx(const INITCOMMONCONTROLSEX* picce);

/* ---- GDI drawing (waveform popup, core/waveform.lua) ---- */
DWORD GetPixel(HDC hdc, int x, int y);
BOOL MoveToEx(HDC hdc, int x, int y, POINT* lpPoint);
BOOL LineTo(HDC hdc, int x, int y);
BOOL Polyline(HDC hdc, const POINT* lppt, int cPoints);
HPEN CreatePen(int iPenStyle, int cWidth, COLORREF color);
BOOL BitBlt(HDC hdcDest, int xDest, int yDest, int wDest, int hDest,
            HDC hdcSrc, int xSrc, int ySrc, DWORD rop);
typedef struct {
    DWORD biSize;
    LONG  biWidth;
    LONG  biHeight;
    WORD  biPlanes;
    WORD  biBitCount;
    DWORD biCompression;
    DWORD biSizeImage;
    LONG  biXPelsPerMeter;
    LONG  biYPelsPerMeter;
    DWORD biClrUsed;
    DWORD biClrImportant;
} BITMAPINFOHEADER;
typedef struct { BYTE rgbBlue; BYTE rgbGreen; BYTE rgbRed; BYTE rgbReserved; } RGBQUAD;
typedef struct {
    BITMAPINFOHEADER bmiHeader;
    RGBQUAD bmiColors[1];
} BITMAPINFO;
int GetDIBits(HDC hdc, HBITMAP hbm, UINT start, UINT lines, void* bits,
              BITMAPINFO* lpbi, UINT usage);

/* ---- waveform popup window helpers ---- */
HCURSOR LoadCursorA(HINSTANCE hInstance, LPCSTR lpCursorName);
BOOL SetCapture(HWND hWnd);
BOOL ReleaseCapture(void);
BOOL SetForegroundWindow(HWND hWnd);
/* PS_SOLID = 0; SRCCOPY = 0x00CC0020 (constants below, in M.gdi). */

/* ---- shell helpers ---- */
/* ShellExecuteW returns as soon as the verb is dispatched; it does not wait
 * for Explorer. That is what makes it usable from the message pump, where
 * os.execute('start ...') would block the UI thread until the shell exited. */
HINSTANCE ShellExecuteW(HWND hwnd, LPCWSTR lpOperation, LPCWSTR lpFile,
                        LPCWSTR lpParameters, LPCWSTR lpDirectory, int nShowCmd);
]]

-- ---------------------------------------------------------------------------
-- Module-level lazy loaders (Windows DLL symbol resolution).
-- ---------------------------------------------------------------------------
local user32, gdi32, kernel32, shell32, comctl32, comdlg32, riched20, winmm

local function is_windows()
    return package.config:sub(1, 1) == "\\"
end
M.is_windows = is_windows

function M.load()
    if user32 then
        return true
    end
    if not is_windows() then
        error("win32 UI requires a Windows host", 2)
    end
    local ok
    ok, user32 = pcall(ffi.load, "user32")
    if not ok then
        error("user32.dll load failed: " .. tostring(user32), 2)
    end
    gdi32 = ffi.load("gdi32")
    kernel32 = ffi.load("kernel32")
    shell32 = ffi.load("shell32")
    comctl32 = ffi.load("comctl32")
    comdlg32 = ffi.load("comdlg32")
    -- Best-effort: winmm provides timeBeginPeriod; absent on rare reduced
    -- images, in which case the loop falls back to the default timer
    -- resolution (15.6 ms).
    ok, winmm = pcall(ffi.load, "winmm")
    if ok then
        M.winmm = winmm
        winmm.timeBeginPeriod(1)
    end
    -- RICHEDIT lives in riched20.dll.
    ok, riched20 = pcall(ffi.load, "riched20")
    if not ok then
        -- some systems ship RichEdit 3 in msftedit but riched20 is standard.
        ok, riched20 = pcall(ffi.load, "msftedit")
        if not ok then
            error("neither riched20 nor msftedit available", 2)
        end
    end
    M.user32 = user32
    M.gdi32 = gdi32
    M.kernel32 = kernel32
    M.shell32 = shell32
    M.comctl32 = comctl32
    M.comdlg32 = comdlg32
    M.riched20 = riched20
    -- Match ref/win32_api_luajit-master: initialize the v6 common-control
    -- classes before creating ComboBox/RichEdit children.
    local icc = ffi.new("INITCOMMONCONTROLSEX")
    icc.dwSize = ffi.sizeof(icc)
    icc.dwICC = 0x0000FFFF -- ICC_WIN95_CLASSES plus the standard extras
    comctl32.InitCommonControlsEx(icc)
    return true
end

-- ---------------------------------------------------------------------------
-- UTF-8 <-> UTF-16 helpers (pure Lua, unit-testable).  The target runtime is
-- openresty luajit.exe (x64), so the *W entry points need UTF-16 as unsigned
-- 16-bit units, not the ANSI code page.
-- ---------------------------------------------------------------------------

-- utf8 string -> ffi WCHAR buffer (could be nil on empty).  Caller owns any
-- returned cdata (GC'd).  The two-pass sizing mirrors win32_api_luajit's
-- winapi_wcs.lua: query with a NULL dst, then allocate and fill.
function M.utf8_to_utf16(s)
    if not s or #s == 0 then
        return nil
    end
    local needed = kernel32.MultiByteToWideChar(M.CP_UTF8, 0, s, #s, nil, 0)
    if needed <= 0 then
        return nil
    end
    -- Win32 W APIs require NUL-terminated strings.  Keep one spare unit even
    -- when the source contains embedded NULs (file-dialog filters do).
    local buf = ffi.new("unsigned short[?]", needed + 1)
    kernel32.MultiByteToWideChar(M.CP_UTF8, 0, s, #s, buf, needed)
    buf[needed] = 0
    return buf
end

-- utf16 buffer (as an ffi WCHAR*) -> Lua UTF-8 string, stopping at the first
-- NUL or at `len` units.  `len` is the count of units (not bytes).
function M.utf16_to_utf8(ptr, len)
    if ptr == nil then
        return ""
    end
    local n = 0
    while ptr[n] ~= 0 and (len == nil or n < len) do
        n = n + 1
    end
    if n == 0 then
        return ""
    end
    local needed = kernel32.WideCharToMultiByte(M.CP_UTF8, 0, ptr, n, nil, 0,
                                                nil, nil)
    if needed <= 0 then
        return ""
    end
    local buf = ffi.new("char[?]", needed)
    kernel32.WideCharToMultiByte(M.CP_UTF8, 0, ptr, n, buf, needed, nil, nil)
    return ffi.string(buf, needed)
end

-- ---------------------------------------------------------------------------
-- Shell
-- ---------------------------------------------------------------------------

local SW_SHOWNORMAL = 1

-- Open a DIRECTORY with its registered handler.  Returns true when the shell
-- accepted the request.
--
-- Directories only, and that restriction IS the safety argument: a directory
-- always has explorer as its handler, so no association lookup happens and none
-- of the cases where ShellExecuteW BLOCKS this thread can arise.  Those cases
-- are real, so respect them if this helper is ever pointed at a file: an
-- unassociated extension raises the "How do you want to open this file?"
-- picker, a DDE handler waits for its handshake, an elevated target waits on
-- the secure-desktop prompt, and a disconnected network path or an unresolved
-- shortcut can stall for tens of seconds.  Any of those would freeze the
-- message loop and, with it, the receive drain - the same thread here is the
-- one draining serial data.  If a file ever has to be opened, do NOT reuse this
-- helper: run the shell call off the UI thread instead.
--
-- The alternative it replaced, os.execute('start "" "..."'), was worse on two
-- counts: it blocked until the spawned process exited, and it interpolated the
-- path into a command line, so any quote or metacharacter in it became shell
-- syntax.  Passing the path as a wide-string argument keeps it data, not code.
function M.open_folder(path)
    if not path or path == "" then
        return false
    end
    local wide = M.utf8_to_utf16(path)
    if wide == nil then
        return false
    end
    -- Cast the HINSTANCE result to an integer: a return value <= 32 is an
    -- error code, anything above is success.  Without the cast LuaJIT yields
    -- a pointer cdata that cannot be compared to a number.
    local result = ffi.cast("intptr_t",
        M.shell32.ShellExecuteW(nil, "open", wide, nil, nil, SW_SHOWNORMAL))
    return result > 32
end

return M
