--[[--------------------------------------------------------------------------
ui/controls.lua - thin LuaJIT+Win32 control factories.

A tiny, non-owning control wrapper layer wrapping raw HWND creation for the
Button/ComboBox/Edit/CheckBox/Static/RICHEDIT classes.  Each factory returns a
control table {hwnd=, id=, kind=, ...} plus small helpers.  Because this caller
is single-threaded, no locking or message-queue marshalling is needed; event
dispatch is handled by the owning window's WM_COMMAND / WM_NOTIFY handling
(see ui/window.lua / panel modules).

Adapted in spirit from LuaDui's Lua-visible control objects (reference only;
no library is linked).
------------------------------------------------------------------------]]--

local ffi = require("ffi")
local w = require("win32")

local M = {}

-- Next control id.  Base at 100 to leave room for menu/window ids.
local next_id = 100

local function alloc_id()
    local id = next_id
    next_id = next_id + 1
    return id
end

--[[-------------------------------------------------------------------------
new(parent, class, style, ex_style, text, x, y, cx, cy) -> ctl
Low-level CreateWindowExA wrapper producing a control record.  The child id is
passed through the hMenu parameter (its low word is the child id).
------------------------------------------------------------------------]]--
local function create(parent, class, style, ex_style, text, x, y, cx, cy, id)
    id = id or alloc_id()
    local hwnd = w.user32.CreateWindowExA(
        ex_style or 0,
        class,
        text or "",
        style or 0,
        x, y, cx, cy,
        parent,
        ffi.cast("void*", id), -- child id in hMenu slot
        w.kernel32.GetModuleHandleA(nil),
        nil
    )
    if hwnd == nil or hwnd == ffi.new("HWND[1]")[0] then
        return nil
    end
    -- Explicitly use the same readable proportional font everywhere.  The
    -- stock DEFAULT_GUI_FONT can resolve to a bitmap font when the process has
    -- no visual-style manifest, producing the tiny monospace appearance seen
    -- in the old screenshot.
    local ui_font = w.gdi32.CreateFontA(14, 0, 0, 0, 400, 0, 0, 0,
                                        1, 0, 0, 5, 0, "Segoe UI")
    if ui_font then
        w.user32.SendMessageA(hwnd, w.wm.WM_SETFONT,
                              ffi.cast("WPARAM", ui_font), 1)
    end
    return { hwnd = hwnd, id = id, kind = class }
end

-- Buttons ----------------------------------------------------------------
function M.button(parent, text, opts)
    opts = opts or {}
    local style = w.style.WS_CHILD + w.style.WS_VISIBLE + w.bs.BS_PUSHBUTTON + w.style.WS_TABSTOP
    if opts.def then
        style = style - w.bs.BS_PUSHBUTTON + w.bs.BS_DEFPUSHBUTTON
    end
    return create(parent, w.ctrl.Button, style, 0, text,
                  opts.x or 0, opts.y or 0, opts.w or 80, opts.h or 24)
end

function M.checkbox(parent, text, opts)
    opts = opts or {}
    local style = w.style.WS_CHILD + w.style.WS_VISIBLE + w.bs.BS_AUTOCHECKBOX + w.style.WS_TABSTOP
    return create(parent, w.ctrl.Button, style, 0, text,
                  opts.x or 0, opts.y or 0, opts.w or 80, opts.h or 20)
end

function M.checkbox_checked(ctl)
    return w.user32.SendMessageA(ctl.hwnd, w.bm.BM_GETCHECK, 0, 0) ~= 0
end

function M.set_checked(ctl, on)
    w.user32.SendMessageA(ctl.hwnd, w.bm.BM_SETCHECK, on and 1 or 0, 0)
end

-- Edit (single or multi line) --------------------------------------------
function M.edit(parent, text, opts)
    opts = opts or {}
    local style = w.style.WS_CHILD + w.style.WS_VISIBLE + w.style.WS_TABSTOP
    if opts.multiline then
        style = style + w.es.ES_MULTILINE + w.es.ES_AUTOVSCROLL
        if opts.wantreturn then style = style + w.es.ES_WANTRETURN end
    end
    if opts.hscroll then style = style + w.es.ES_AUTOHSCROLL end
    if opts.readonly then style = style + w.es.ES_READONLY end
    return create(parent, w.ctrl.Edit, style, w.style.WS_EX_CLIENTEDGE, text,
                  opts.x or 0, opts.y or 0, opts.w or 120, opts.h or 24)
end

-- ComboBox (dropdown list) -----------------------------------------------
function M.combo(parent, items, opts)
    opts = opts or {}
    local style = w.style.WS_CHILD + w.style.WS_VISIBLE + w.cbs.CBS_DROPDOWNLIST + w.style.WS_TABSTOP
    local ctl = create(parent, w.ctrl.ComboBox, style, 0, "",
                       opts.x or 0, opts.y or 0, opts.w or 110, opts.h or 200)
    if not ctl then
        return nil
    end
    for _, it in ipairs(items or {}) do
        w.user32.SendMessageA(ctl.hwnd, w.cb.CB_ADDSTRING, 0,
                              ffi.cast("LPARAM", it))
    end
    if opts.sel ~= nil then
        w.user32.SendMessageA(ctl.hwnd, w.cb.CB_SETCURSEL, opts.sel, 0)
    end
    return ctl
end

function M.combo_cur(ctl)
    return tonumber(w.user32.SendMessageA(ctl.hwnd, w.cb.CB_GETCURSEL, 0, 0)) or -1
end

function M.combo_text(ctl, index)
    index = index or M.combo_cur(ctl)
    if index < 0 then
        return ""
    end
    local len = tonumber(w.user32.SendMessageA(ctl.hwnd, w.cb.CB_GETLBTEXTLEN, index, 0)) or 0
    local buf = ffi.new("char[?]", len + 1)
    w.user32.SendMessageA(ctl.hwnd, w.cb.CB_GETLBTEXT, index,
                          ffi.cast("LPARAM", buf))
    return ffi.string(buf)
end

function M.combo_set(ctl, items)
    w.user32.SendMessageA(ctl.hwnd, w.cb.CB_RESETCONTENT, 0, 0)
    for _, it in ipairs(items or {}) do
        w.user32.SendMessageA(ctl.hwnd, w.cb.CB_ADDSTRING, 0,
                              ffi.cast("LPARAM", it))
    end
    -- default to the first item (matching the Python client's initial state).
    w.user32.SendMessageA(ctl.hwnd, w.cb.CB_SETCURSEL, 0, 0)
end

function M.combo_count(ctl)
    return tonumber(w.user32.SendMessageA(ctl.hwnd, w.cb.CB_GETCOUNT, 0, 0)) or 0
end

-- Select the item whose text matches `want`; returns the index or -1.
function M.combo_select_text(ctl, want)
    if want == nil then
        return -1
    end
    local n = M.combo_count(ctl)
    local text_want = tostring(want)
    for i = 0, n - 1 do
        if M.combo_text(ctl, i) == text_want then
            w.user32.SendMessageA(ctl.hwnd, w.cb.CB_SETCURSEL, i, 0)
            return i
        end
    end
    return -1
end

-- Static label -----------------------------------------------------------
function M.label(parent, text, opts)
    opts = opts or {}
    local style = w.style.WS_CHILD + w.style.WS_VISIBLE
    return create(parent, w.ctrl.Static, style, 0, text,
                  opts.x or 0, opts.y or 0, opts.w or 60, opts.h or 20)
end

-- RichEdit receive view --------------------------------------------------
function M.richedit(parent, opts)
    opts = opts or {}
    local style = w.style.WS_CHILD + w.style.WS_VISIBLE + w.style.WS_TABSTOP +
                  w.es.ES_MULTILINE + w.es.ES_READONLY + w.es.ES_AUTOVSCROLL +
                  w.es.ES_NOHIDESEL
    local ctl = create(parent, w.ctrl.RichEdit20A, style, w.style.WS_EX_CLIENTEDGE,
                       "", opts.x or 0, opts.y or 0, opts.w or 400, opts.h or 300)
    return ctl
end

-- Common window-message helpers used by panels --------------------------
function M.set_text(ctl, text)
    w.user32.SetWindowTextA(ctl.hwnd, text)
end

function M.get_text(ctl)
    local n = w.user32.GetWindowTextLengthA(ctl.hwnd)
    local buf = ffi.new("char[?]", n + 1)
    w.user32.GetWindowTextA(ctl.hwnd, buf, n + 1)
    return ffi.string(buf)
end

-- Keep geometry changes behind the control wrapper so panel modules never
-- manipulate raw HWNDs directly.  Combo boxes keep their drop-list height;
-- callers may optionally supply it as `h`.
function M.move(ctl, x, y, width, height)
    if ctl and ctl.hwnd then
        w.user32.MoveWindow(ctl.hwnd, x, y, width, height or 24, 1)
    end
end

-- Forward-declared: M.vflow below refers to vmerge before its definition
-- line; Lua resolves same-scope local-function references by lexical
-- position, not by name at call time, so without this the reference would
-- compile as an undefined global and crash on first call.
local vmerge

-- Builder: place a series of controls using a simple vertical layout cursor.
-- Returns the constructed control records in order.  `defs` is a list of
-- {kind=, text=, w=, h=, opts=}.  Advance `cursor_y` by the last height + gap.
function M.vflow(parent, defs, x, start_y, gap)
    gap = gap or 8
    local local_y = start_y
    local out = {}
    for _, d in ipairs(defs) do
        local c
        local h = d.h or 24
        if d.kind == "button" then
            c = M.button(parent, d.text or "", vmerge(d, { y = local_y, x = x, w = d.w or 80 }))
        elseif d.kind == "label" then
            c = M.label(parent, d.text or "", vmerge(d, { y = local_y, x = x, w = d.w or 60, h = h }))
        elseif d.kind == "checkbox" then
            c = M.checkbox(parent, d.text or "", vmerge(d, { y = local_y, x = x, w = d.w or 80, h = h }))
        elseif d.kind == "edit" then
            c = M.edit(parent, d.text or "", vmerge(d, { y = local_y, x = x, w = d.w or 120, h = h }))
        elseif d.kind == "combo" then
            c = M.combo(parent, d.items or {}, vmerge(d, { y = local_y, x = x, w = d.w or 110, h = d.drop_h or 200 }))
        end
        if c then
            out[#out + 1] = c
        end
        local_y = local_y + h + gap
    end
    return out, local_y
end

local function vmerge(d, base)
    for k, v in pairs(d.opts or {}) do
        if base[k] == nil then
            base[k] = v
        end
    end
    return base
end
M._vmerge = vmerge

M.new = create
M.alloc_id = alloc_id

return M
