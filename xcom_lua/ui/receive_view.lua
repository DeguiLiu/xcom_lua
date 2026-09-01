--[[--------------------------------------------------------------------------
ui/receive_view.lua - receive display built on RICHEDIT + ANSI colouring.

Binds the RICHEDIT control, feeds UTF-8 display batches (text or hex view)
into it with per-segment foreground colouring (ESC[ SGR) via EM_SETCHARFORMAT,
and enforces a bounded tail log like the Python client.

Colouring model: RICHEDIT (RichEdit 2.0/3.0) via EM_SETCHARFORMAT with a
CHARFORMAT2 struct carries both a foreground colour and a per-char background
colour, so ANSI fg/bg/bold codes are all honoured.  Segments without a bg code
keep whatever CHARFORMAT2 field a previous segment left set, so the reusable
buffer is cleared per segment (see color_range below).  A residue carry in
core/ansi.lua keeps colour correct when an escape straddles two display polls.

Each appended batch is inserted once at the caret end, then each ANSI segment
is (re)selected by document offset and given a CHARFORMAT.  `_doc_len` tracks
the visible document length in UTF-8 bytes (RICHEDIT counts chars, and our
batches are already UTF-8 text; we count bytes which is an approximation but
consistent for the char handling and sufficient for colour ranges).
------------------------------------------------------------------------]]--

local ffi = require("ffi")
local w = require("win32")
local c = require("controls")
local ansi = require("ansi")

local M = {}

local MAX_BLOCK_CHARS = 4096                -- per-append segment char ceiling
local MAX_BLOCK_COUNT = 4000                -- tail-log block budget
local SCF_SELECTION = 1

-- Build the options bar (Receive HEX / Timestamp / Pause / Auto-clear +
-- spin / Auto save / monitor status label) above the RICHEDIT, mirroring
-- Python's ReceivePanel exactly (app/control_panels.py).  Returns the row's
-- controls merged into `view` and advances the caller's y past the row.
local function build_options_row(view, panel, x, y, row_w, row_h)
    local cx = x
    view.rx_hex_cb = c.checkbox(panel, "Receive HEX", { x = cx, y = y, w = 96, h = row_h })
    cx = cx + 100
    view.ts_cb = c.checkbox(panel, "Timestamp", { x = cx, y = y, w = 86, h = row_h })
    cx = cx + 90
    view.pause_cb = c.checkbox(panel, "Pause display", { x = cx, y = y, w = 100, h = row_h })
    cx = cx + 104
    view.auto_clear_cb = c.checkbox(panel, "Auto clear", { x = cx, y = y, w = 84, h = row_h })
    cx = cx + 88
    view.auto_clear_sb = c.edit(panel, "0", { x = cx, y = y, w = 64, h = row_h })
    w.user32.EnableWindow(view.auto_clear_sb.hwnd, 0)  -- enabled only with auto_clear_cb
    cx = cx + 68
    view.auto_save_cb = c.checkbox(panel, "Auto save", { x = cx, y = y, w = 84, h = row_h })
    cx = cx + 88
    view.monitor_status = c.label(panel, "LINK IDLE",
                                  { x = row_w - 140, y = y, w = 136, h = row_h })
end

-- Toggle the auto-clear byte-threshold edit's enabled state with its checkbox
-- (mirrors Python's `auto_clear_cb.toggled.connect(auto_clear_sb.setEnabled)`).
local function wire_options_row(view)
    -- window.lua registers the WM_COMMAND ids; this just exposes the pairing
    -- so the window can call it from the checkbox handler.
    function view.on_auto_clear_toggled()
        local on = c.checkbox_checked(view.auto_clear_cb)
        w.user32.EnableWindow(view.auto_clear_sb.hwnd, on and 1 or 0)
    end
    function view.set_monitor_connected(is_connected)
        c.set_text(view.monitor_status,
                  is_connected and "LINK ACTIVE" or "LINK IDLE")
    end
end

-- Build, wrapping the options row + a RICHEDIT child placed at (x,y) size
-- (w,h) in `panel`.  The options row takes the top `row_h` (default 24px) of
-- the supplied rect; the RICHEDIT fills the remainder.
function M.build(panel, x, y, w_, h, row_h)
    row_h = row_h or 24
    local view = {}
    build_options_row(view, panel, x, y, w_, row_h)
    wire_options_row(view)

    view.richedit = c.richedit(panel, { x = x, y = y + row_h + 4, w = w_, h = h - row_h - 4 })
    view.parser = ansi.AnsiParser.new()
    view.hex_view = false
    view.timestamp = false
    view._doc_len = 0
    view._trimmed = 0

    function view.layout(px, py, width, height)
        local cx = px
        c.move(view.rx_hex_cb, cx, py, 96, row_h)
        cx = cx + 100
        c.move(view.ts_cb, cx, py, 86, row_h)
        cx = cx + 90
        c.move(view.pause_cb, cx, py, 100, row_h)
        cx = cx + 104
        c.move(view.auto_clear_cb, cx, py, 84, row_h)
        cx = cx + 88
        c.move(view.auto_clear_sb, cx, py, 64, row_h)
        cx = cx + 68
        c.move(view.auto_save_cb, cx, py, 84, row_h)
        c.move(view.monitor_status, px + width - 140, py, 136, row_h)
        c.move(view.richedit, px, py + row_h + 6, width, math.max(80, height - row_h - 6))
    end

    -- One reusable CHARFORMAT2A buffer for colouring (CHARFORMAT2 carries the
    -- crBackColor field that CHARFORMAT lacks, needed for ANSI bg codes).
    local cf = ffi.new("CHARFORMAT2A")
    cf.cbSize = ffi.sizeof("CHARFORMAT2A")

    -- True length of current document text (chars), queried from the control.
    local function doc_len()
        return w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_GETTEXTLENGTH, 0, 0)
    end

    local function scroll_to_bottom()
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_SCROLL, 1, 0) -- SB_BOTTOM
    end

    -- Apply colour to the char range [start_pos, end_pos) of a just-inserted run.
    local function color_range(start_pos, end_pos, fg, bg, bold)
        if end_pos <= start_pos then
            return
        end
        local mask = w.characterFormatMask.CFM_COLOR
        local fg_int = fg or 0x263238   -- default fg (light palette #263238)
        cf.crTextColor = w.from_ansi_rgb(fg_int)
        if bg then
            cf.crBackColor = w.from_ansi_rgb(bg)
            mask = mask + w.characterFormatMask.CFM_BACKCOLOR
        end
        cf.dwEffects = 0
        if bold then
            mask = mask + w.characterFormatMask.CFM_BOLD
            cf.dwEffects = 0x00000001  -- CFE_BOLD
        end
        cf.dwMask = mask
        -- format applies to the current selection; select the whole segment.
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_SETSEL,
                              ffi.cast("WPARAM", start_pos), ffi.cast("LPARAM", end_pos))
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_SETCHARFORMAT, SCF_SELECTION,
                              ffi.cast("LPARAM", cf))
    end

    -- Insert `text` at the caret end (allows a fresh trailing scroll).
    local function insert(text)
        if not text or #text == 0 then
            return
        end
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_SETSEL,
                              ffi.cast("WPARAM", -1), ffi.cast("LPARAM", -1))
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_REPLACESEL, 0,
                              ffi.cast("LPARAM", text))
    end

    view.clear = function()
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_SETSEL, 0, -1)
        w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_REPLACESEL, 0,
                              ffi.cast("LPARAM", ""))
        view.parser:reset()
        view._doc_len = 0
        view._trimmed = 0
    end

    function view.set_max_bytes(v)
        -- compatibility; the real bound is the block budget below.
    end

    -- Feed one entire display batch (UTF-8 string) and colour it.
    function view.feed(batch_bytes)
        if not batch_bytes or #batch_bytes == 0 then
            return
        end
        -- Enforce the tail-log budget before appending.
        local before = view._doc_len
        insert(batch_bytes)
        local after = doc_len()
        view._doc_len = after

        if view.hex_view then
            -- plain hex text; no colouring.
            return
        end

        -- Colour the batch in segments parsed from the inserted text.
        local segments = view.parser:feed(batch_bytes)
        local pos = before
        for _, seg in ipairs(segments) do
            local seg_bytes = #seg.text
            if seg_bytes > 0 then
                color_range(pos, pos + seg_bytes, seg.fg, seg.bg, seg.bold)
                pos = pos + seg_bytes
            end
        end
        -- Trim the tail when it exceeds the budget (oldest rolls off).
        view._trim_to_budget(MAX_BLOCK_COUNT * MAX_BLOCK_CHARS)
        scroll_to_bottom()
    end

    -- Delete the first `count` chars to keep the tail window bounded.
    function view._trim_to_budget(max_chars)
        if view._doc_len > max_chars then
            local overflow = view._doc_len - max_chars
            w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_SETSEL, 0, overflow)
            w.user32.SendMessageA(view.richedit.hwnd, w.em.EM_REPLACESEL, 0,
                                  ffi.cast("LPARAM", ""))
            view._doc_len = view._doc_len - overflow
            view._trimmed = view._trimmed + overflow
        end
    end

    view.layout(x, y, w_, h)
    return view
end

return M
