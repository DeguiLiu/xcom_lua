-- Copyright (C) xiaooloong  (lua-resty-iconv upstream)
-- License: GPL-3.0  (see iconv.LICENSE in this directory)
--
-- xcom_lua patch: add libiconv-* prefixed-symbol compatibility.
--
-- Upstream iconv.lua cdef's glibc-style symbols (iconv_open / iconv /
-- iconv_close). glibc and macOS libc export those names directly. libiconv
-- (the GNU libiconv standalone library used on Windows, e.g. the libiconv-2.dll
-- shipped by MSYS2 / Wireshark / Tesseract) exports prefixed names instead:
-- libiconv_open / libiconv / libiconv_close. objdump -p libiconv-2.dll
-- confirms only the prefixed names are exported.
--
-- Patch: declare BOTH sets of names in cdef (legal — cdef is just type info;
-- symbol lookup happens on first reference). At module-init time, probe which
-- set is bound and capture the matching function references in locals.
-- All call sites use the captured locals instead of bare ffi_c.iconv_open.
--
-- The probe is one-time at module load; per-call cost is unchanged from
-- upstream (one indirect call through a local).
--
-- Second patch (MinGW-libiconv safety): upstream `_M.new` calls
-- `iconv_close(ctx)` when `iconv_open` returns the `(iconv_t)-1` error
-- sentinel. On real glibc/macOS that close of an invalid handle is a harmless
-- no-op returning EBADF. The MinGW build of libiconv-2.dll, however,
-- segfaults on `iconv_close((iconv_t)-1)`. We now skip the close on the
-- failure path and just return the unsupported-charset error.

local ffi = require 'ffi'
local type = type
local tonumber = tonumber
local ffi_c = ffi.C
local ffi_new = ffi.new
local ffi_cast = ffi.cast
local ffi_gc = ffi.gc
local ffi_string = ffi.string
local ffi_typeof = ffi.typeof
local ffi_errno = ffi.errno
ffi.cdef[[
    typedef void *iconv_t;

    /* glibc / macOS native names */
    iconv_t iconv_open (const char *__tocode, const char *__fromcode);
    size_t  iconv (
        iconv_t __cd,
        char ** __inbuf, size_t * __inbytesleft,
        char ** __outbuf, size_t * __outbytesleft);
    int     iconv_close (iconv_t __cd);

    /* GNU libiconv standalone names (Windows libiconv-2.dll exports these) */
    iconv_t libiconv_open (const char *__tocode, const char *__fromcode);
    size_t  libiconv (
        iconv_t __cd,
        char ** __inbuf, size_t * __inbytesleft,
        char ** __outbuf, size_t * __outbytesleft);
    int     libiconv_close (iconv_t __cd);
]]

-- xcom_lua patch: resolve which symbol set is actually bound.
-- ffi.C.* raises "cannot resolve symbol" only when called; we wrap each
-- candidate in pcall and keep the first that succeeds.
local function resolve(name_glibc, name_libiconv)
    if pcall(function() return ffi_c[name_glibc] end) then
        return ffi_c[name_glibc]
    end
    if pcall(function() return ffi_c[name_libiconv] end) then
        return ffi_c[name_libiconv]
    end
    error("resty.iconv: neither '" .. name_glibc .. "' nor '" ..
          name_libiconv .. "' is bound in ffi.C. " ..
          "Pre-load libiconv via ffi.load before requiring this module.")
end
local iconv_open_fn  = resolve("iconv_open",      "libiconv_open")
local iconv_fn       = resolve("iconv",           "libiconv")
local iconv_close_fn = resolve("iconv_close",     "libiconv_close")

local maxsize = 4096
local char_ptr = ffi_typeof('char *')
local char_ptr_ptr = ffi_typeof('char *[1]')
local sizet_ptr = ffi_typeof('size_t[1]')
local iconv_open_err = ffi_cast('iconv_t', ffi_new('int', -1))

local ok, new_tab = pcall(require, "table.new")
if not ok then
    new_tab = function (narr, nrec) return {} end
end

local _M = new_tab(0, 8)
_M._VERSION = '0.2.0-xcom'

local mt = { __index = _M }

function _M.new(self, to, from, _maxsize)
    if not to or 'string' ~= type(to) or 1 > #to then
        return nil, 'dst charset required'
    end
    if not from or 'string' ~= type(from) or 1 > #from then
        return nil, 'src charset required'
    end
    _maxsize = tonumber(_maxsize) or maxsize
    local ctx = iconv_open_fn(to, from)
    if ctx == iconv_open_err then
        -- libiconv_open failed. Do NOT call iconv_close on `ctx`: the
        -- sentinel `(iconv_t)(size_t)-1` was never an open descriptor, and the
        -- MinGW build of libiconv_2.dll segfaults on iconv_close(-1) instead
        -- of returning an error. Just report the unsupported-combination error.
        return nil, ('conversion from %s to %s is not supported'):format(from, to)
    else
        ctx = ffi_gc(ctx, iconv_close_fn)
        local buffer = ffi_new('char[' .. _maxsize .. ']')
        return setmetatable({
            ctx = ctx,
            buffer = buffer,
            maxsize = _maxsize,
        }, mt)
    end
end


function _M.convert(self, text)
    local ctx = self.ctx
    if not ctx then
        return nil, 'not initialized'
    end
    if not text or 'string' ~= type(text) or 1 > #text then
        return nil, 'text required'
    end
    local maxsize = self.maxsize
    local buffer = self.buffer

    local dst_len = ffi_new(sizet_ptr, maxsize)
    local dst_buff = ffi_new(char_ptr_ptr, ffi_cast(char_ptr, buffer))

    local src_len = ffi_new(sizet_ptr, #text)
    local src_buff = ffi_new(char_ptr_ptr)
    src_buff[0] = ffi_new('char['.. #text .. ']', text)

    local ok = iconv_fn(ctx, src_buff, src_len, dst_buff, dst_len)
    if 0 <= ok then
        local len = maxsize - dst_len[0]
        local dst = ffi_string(buffer, len)
        return dst, tonumber(ok)
    else
        local err = ffi_errno()
        return nil, 'failed to convert, errno ' .. err
    end
end

function _M.finish(self)
    local ctx = self.ctx
    if not ctx then
        return nil, 'not initialized'
    end
    return iconv_close_fn(ffi_gc(ctx, nil))
end

return _M