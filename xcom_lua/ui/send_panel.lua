--[[--------------------------------------------------------------------------
ui/send_panel.lua - send workspace: single-send and multi-send sections.

A lightweight tab strip (two buttons: "Single" / "Multi") toggles which
control group is visible — avoiding a dependency on SysTabControl32.  Mirrors
xcom_client's SendPanel feature set for the two practical tabs:

* Single: one multi-line edit + HEX / newline / auto-cycle checkboxes + a
  period edit, plus a Send button.
* Multi: up to 8 enabling-checkbox + text + number-button rows, page navigation
  (Remove/Add page, First/Prev/Next/Last, Page spin + Go), "Send enabled",
  HEX/CRLF flags, and an Auto-cycle period.

All state is plain Lua; the owning window reads/writes it via the returned
record's fields.  Rows use editable edits; the Send action is delegated to the
window (which owns the ABI handle).
------------------------------------------------------------------------]]--

local w = require("win32")
local c = require("controls")

local M = {}

local MAX_MULTI = 8

-- build(panel, x, y, w, h) -> send panel record.
function M.build(panel, x, y, panel_w, h)
    local sp = {}
    local cy = y + 4
    local row_h = 24

    -- Tab strip.
    sp.tab_single = c.button(panel, "Single", { x = x, y = cy, w = 64, h = 22 })
    sp.tab_multi = c.button(panel, "Multi", { x = x + 68, y = cy, w = 64, h = 22 })
    cy = cy + 26

    -- ---- single-send group ----
    sp.single_edit = c.edit(panel, "", { x = x, y = cy, w = panel_w - 110, h = 70, multiline = true, wantreturn = true })
    sp.single_send = c.button(panel, "Send", { x = x + panel_w - 98, y = cy, w = 90, h = 70 })
    cy = cy + 74
    sp.single_hex = c.checkbox(panel, "HEX", { x = x, y = cy, w = 46, h = 20 })
    sp.single_crlf = c.checkbox(panel, "NEWLINE", { x = x + 50, y = cy, w = 104, h = 20 })
    sp.single_auto = c.checkbox(panel, "AUTO", { x = x + 158, y = cy, w = 90, h = 20 })
    sp.single_period = c.edit(panel, "1000", { x = x + panel_w - 120, y = cy, w = 56, h = 20 })
    sp.single_ms = c.label(panel, "ms", { x = x + panel_w - 60, y = cy, w = 30, h = 20 })
    cy = cy + 26
    local single_group = { edit = sp.single_edit, send = sp.single_send,
                           hex = sp.single_hex, crlf = sp.single_crlf,
                           auto = sp.single_auto, period = sp.single_period, ms = sp.single_ms }

    -- ---- multi-send group ----
    local entries = {}
    for i = 0, MAX_MULTI - 1 do
        local ey = cy + (i % 4) * row_h
        local ex = x + math.floor(i / 4) * (panel_w / 2)
        local chk = c.checkbox(panel, "", { x = ex + 2, y = ey, w = 18, h = 18 })
        local edt = c.edit(panel, "", { x = ex + 24, y = ey, w = (panel_w / 2) - 78, h = 20 })
        local num = c.button(panel, tostring(i + 1), { x = ex + (panel_w / 2) - 52, y = ey, w = 24, h = 20 })
        entries[#entries + 1] = { idx = i, chk = chk, edt = edt, num = num }
    end
    cy = cy + 4 * row_h + 4

    -- multi options: crlf / hex / keypad / auto-cycle + period
    sp.multi_crlf = c.checkbox(panel, "Send newline", { x = x, y = cy, w = 104, h = 20 })
    sp.multi_hex = c.checkbox(panel, "HEX send", { x = x + 108, y = cy, w = 84, h = 20 })
    sp.multi_keypad = c.checkbox(panel, "Bind number keys", { x = x + 196, y = cy, w = 120, h = 20 })
    sp.multi_auto = c.checkbox(panel, "Auto cycle", { x = x + panel_w - 220, y = cy, w = 90, h = 20 })
    sp.multi_period = c.edit(panel, "1000", { x = x + panel_w - 122, y = cy, w = 56, h = 20 })
    sp.multi_ms = c.label(panel, "ms", { x = x + panel_w - 62, y = cy, w = 30, h = 20 })
    cy = cy + 26

    -- multi footer: page nav buttons + page spin + Go + Send enabled
    local fw = panel_w / 6
    local bx = x
    sp.page_label = c.label(panel, "Page 1/1", { x = bx, y = cy, w = 64, h = 22 })
    bx = bx + 68
    sp.btn_remove = c.button(panel, "Remove", { x = bx, y = cy, w = 44, h = 22 }); bx = bx + 48
    sp.btn_add = c.button(panel, "Add", { x = bx, y = cy, w = 34, h = 22 }); bx = bx + 38
    sp.btn_first = c.button(panel, "First", { x = bx, y = cy, w = 40, h = 22 }); bx = bx + 44
    sp.btn_prev = c.button(panel, "Prev", { x = bx, y = cy, w = 40, h = 22 }); bx = bx + 44
    sp.btn_next = c.button(panel, "Next", { x = bx, y = cy, w = 40, h = 22 }); bx = bx + 44
    sp.btn_last = c.button(panel, "Last", { x = bx, y = cy, w = 40, h = 22 }); bx = bx + 44
    c.label(panel, "Page", { x = bx, y = cy, w = 34, h = 22 }); bx = bx + 38
    sp.page_spin = c.edit(panel, "1", { x = bx, y = cy, w = 30, h = 22 }); bx = bx + 34
    sp.btn_go = c.button(panel, "Go", { x = bx, y = cy, w = 28, h = 22 }); bx = bx + 32
    sp.btn_send_enabled = c.button(panel, "Send enabled", { x = x + panel_w - 110, y = cy, w = 102, h = 22 })

    local multi_group = {
        entries = entries,
        crlf = sp.multi_crlf, hex = sp.multi_hex, keypad = sp.multi_keypad,
        auto = sp.multi_auto, period = sp.multi_period, ms = sp.multi_ms,
        page_label = sp.page_label, btn_remove = sp.btn_remove, btn_add = sp.btn_add,
        btn_first = sp.btn_first, btn_prev = sp.btn_prev, btn_next = sp.btn_next,
        btn_last = sp.btn_last, page_spin = sp.page_spin, btn_go = sp.btn_go,
        btn_send_enabled = sp.btn_send_enabled,
    }

    -- ---- tab switching + visibility ----
    local function set_visible(grp, on)
        for _, ctl in pairs(grp) do
            if type(ctl) == "table" and ctl.hwnd then
                w.user32.ShowWindow(ctl.hwnd, on and w.style.SW_SHOW or w.style.SW_HIDE)
            elseif type(ctl) == "table" then
                -- `entries` is a list of row records; recurse so inactive
                -- tabs cannot leave their controls painted over the active tab.
                set_visible(ctl, on)
            end
        end
    end

    function sp.show_single()
        set_visible(single_group, true)
        set_visible(multi_group, false)
    end

    function sp.show_multi()
        set_visible(single_group, false)
        set_visible(multi_group, true)
    end

    sp.state = {
        pages = { { text = {}, enabled = {} } },
        page_index = 1,
    }

    sp.single = single_group
    sp.multi = multi_group
    sp.show_single()

    -- page helpers -------------------------------------------------------
    function sp.current_page()
        return sp.state.pages[sp.state.page_index]
    end

    function sp.entry_text(i)
        local p = sp.current_page()
        return p.text[i] or ""
    end

    function sp.entry_enabled(i)
        local p = sp.current_page()
        return p.enabled[i] == true
    end

    return sp
end

return M
