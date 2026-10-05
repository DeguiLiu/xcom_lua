--[[--------------------------------------------------------------------------
core/fs_path.lua - the single UTF-8 -> CRT path boundary.

Why this exists (one owner for a cross-cutting rule):
  Every path this program builds is UTF-8: luv's fs_scandir returns UTF-8
  names, ImGui hands back UTF-8, and scripts/ ships CJK file names
  (绘制曲线.lua).  The C runtime's narrow path APIs - io.open/fopen,
  os.remove, os.rename - do NOT accept UTF-8 on Windows: they forward the
  bytes to the ANSI Win32 call, which decodes them in the process code page
  (GetACP).  On a CP936 host every CJK script name turns into mojibake and
  fopen answers ENOENT / EILSEQ, so all eight shipped CJK plugins silently
  failed to load and the console list fell back to the raw file name because
  the @name/@desc head read failed the same way.
  Measured on this host: GetACP=936, io.open("scripts/绘制曲线.lua")=nil,
  uv.fs_stat(same)=file.  The C++ side already converts explicitly
  (serial_backend_win.cpp, log_writer.cpp); this module is the Lua side's
  counterpart, so a new file operation never has to remember the rule.

Cost: an ASCII path - the overwhelming majority of calls - leaves through a
single byte-range scan and never touches FFI; only a non-ASCII path pays two
kernel32 conversions through grown-only scratch buffers.
--------------------------------------------------------------------------]]--

local M = {}

local ffi_ok, ffi = pcall(require, "ffi")
local kernel32
if ffi_ok and package.config:sub(1, 1) == "\\" then
    -- Same two prototypes core/charset.lua declares; a duplicate cdef of an
    -- identical signature is legal, and keeping this file self-contained
    -- means it can be required on its own.
    ffi.cdef[[
    int MultiByteToWideChar(unsigned int codePage, unsigned long flags,
                            const char* src, int srcLen,
                            unsigned short* dst, int dstLen);
    int WideCharToMultiByte(unsigned int codePage, unsigned long flags,
                            const unsigned short* src, int srcLen,
                            char* dst, int dstLen, const char* defChar,
                            int* usedDefChar);
    int MoveFileExW(const unsigned short* from, const unsigned short* to,
                    unsigned long flags);
    int CreateDirectoryW(const unsigned short* path, void* security);
    ]]
    local ok, k = pcall(ffi.load, "kernel32")
    if ok then
        kernel32 = k
    end
end

local CP_UTF8, CP_ACP = 65001, 0
local MB_ERR_INVALID_CHARS = 0x00000008
local MOVEFILE_REPLACE_EXISTING = 0x00000001
local NON_ASCII = "[\128-\255]"

-- Grown-only scratch, the core/charset.lua pattern: a stream of CJK paths
-- reuses two buffers instead of allocating per call.
local wide, wide_n = nil, 0
local ansi, ansi_n = nil, 0

-- UTF-8 path -> bytes the narrow CRT APIs accept.  Returns the input
-- unchanged for ASCII (fast path) and for anything that is not valid UTF-8,
-- so a legacy ANSI path is never converted twice.
function M.to_crt(path)
    if not kernel32 or not path:find(NON_ASCII) then
        return path
    end
    local n = kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        path, #path, nil, 0)
    if n <= 0 then
        return path
    end
    if wide_n < n then
        wide_n = n
        wide = ffi.new("unsigned short[?]", n)
    end
    if kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            path, #path, wide, n) <= 0 then
        return path
    end
    local m = kernel32.WideCharToMultiByte(CP_ACP, 0, wide, n, nil, 0,
        nil, nil)
    if m <= 0 then
        return path
    end
    if ansi_n < m then
        ansi_n = m
        ansi = ffi.new("char[?]", m)
    end
    if kernel32.WideCharToMultiByte(CP_ACP, 0, wide, n, ansi, m, nil,
            nil) <= 0 then
        return path
    end
    return ffi.string(ansi, m)
end

-- True when non-ASCII paths actually need converting on this host (Windows
-- with an ANSI code page).  Tests use it to assert the boundary is exercised
-- rather than silently skipped.
function M.encodes()
    return kernel32 ~= nil and M.to_crt("é") ~= "é"
end

function M.open(path, mode)
    return io.open(M.to_crt(path), mode)
end

function M.remove(path)
    return os.remove(M.to_crt(path))
end

-- One UTF-16 buffer, grown only, holding both paths of a rename as the
-- double-NUL-terminated "from\0to\0" pair the wide API wants.  Nulling the
-- separator instead of allocating per path keeps this allocation-free after
-- the first non-trivial call, matching to_crt's scratch discipline.
local wpair, wpair_n = nil, 0

-- UTF-8 -> UTF-16 for the two paths of one rename.  Returns two
-- unsigned-short pointers (into the shared scratch) or nil when the host has no
-- kernel32 or a path is not valid UTF-8 (a legacy ANSI path never gets
-- converted twice: the caller falls back to the narrow CRT call).
local function to_wide_pair(from, to)
    local nf = kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        from, #from, nil, 0)
    if nf <= 0 then
        return nil
    end
    local nt = kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        to, #to, nil, 0)
    if nt <= 0 then
        return nil
    end
    local need = nf + 1 + nt + 1
    if wpair_n < need then
        wpair_n = need
        wpair = ffi.new("unsigned short[?]", need)
    end
    if kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            from, #from, wpair, nf) <= 0 then
        return nil
    end
    wpair[nf] = 0
    if kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            to, #to, wpair + nf + 1, nt) <= 0 then
        return nil
    end
    wpair[nf + 1 + nt] = 0
    return wpair, wpair + nf + 1
end

-- One UTF-16 path in the same scratch, NUL-terminated.
local wone, wone_n = nil, 0

local function to_wide_one(path)
    local n = kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        path, #path, nil, 0)
    if n <= 0 then
        return nil
    end
    if wone_n < n + 1 then
        wone_n = n + 1
        wone = ffi.new("unsigned short[?]", n + 1)
    end
    if kernel32.MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
            path, #path, wone, n) <= 0 then
        return nil
    end
    wone[n] = 0
    return wone
end

-- Atomic replace.  The CRT rename this used to call FAILS on Windows whenever
-- the destination exists (measured: "File exists"), so every config write had
-- to delete the live config.ini first and rename the temp file into the hole
-- -- a window in which the user's settings did not exist on disk at all, and a
-- crash inside it destroyed them (the .tmp was left behind).  MoveFileExW with
-- REPLACE_EXISTING is the atomic replace the comment in core/config.lua always
-- claimed, and it needs the wide API because the path is UTF-8 (see the module
-- header).  Any failure falls back to the CRT call, so a host without
-- kernel32 (the Linux review host) and a legacy ANSI path behave as before.
function M.rename(from, to)
    if kernel32 then
        local wide_from, wide_to = to_wide_pair(from, to)
        if wide_from and
           kernel32.MoveFileExW(wide_from, wide_to, MOVEFILE_REPLACE_EXISTING) ~= 0 then
            return true
        end
    end
    return os.rename(M.to_crt(from), M.to_crt(to))
end

-- Create one directory (Windows only; the client uses it for the
-- %APPDATA%\XCOM fallback config directory).  CreateDirectoryW rather than
-- os.execute("mkdir"): the path is UTF-8 and a shell would go through the code
-- page again, which is the bug this module exists to prevent.  A false return
-- means either "no kernel32" or "the directory could not be created".
function M.mkdir(path)
    if not kernel32 then
        return false
    end
    local wide = to_wide_one(path)
    if not wide then
        return false
    end
    return kernel32.CreateDirectoryW(wide, nil) ~= 0
end

-- loadfile with a UTF-8 path: the source is read through the converted path,
-- but the chunk is named with the original UTF-8 string so a runtime error
-- still prints 绘制曲线.lua:12 instead of mojibake.
-- On the failure path loadfile supplies the CRT's own wording ("No such file
-- or directory"), but its copy of the name is the ANSI-encoded one, which the
-- UTF-8 Script Console renders as mojibake; report the reason with the UTF-8
-- name instead.
local function croak(path)
    local _, err = loadfile(M.to_crt(path))
    local reason = type(err) == "string" and err:match("^.-: (.*)$")
    if reason then
        return nil, path .. ": " .. reason
    end
    return nil, err
end

function M.load(path)
    local f = M.open(path, "rb")
    if not f then
        return croak(path)
    end
    local src = f:read("*a")
    f:close()
    if not src then
        return croak(path)
    end
    return loadstring(src, "@" .. path)
end

return M
