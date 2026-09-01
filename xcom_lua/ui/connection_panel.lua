--[[--------------------------------------------------------------------------
ui/connection_panel.lua - serial connection controls (right, ~160px).

Port combo + refresh, Baud/Data/Parity/Stop/Flow combos, DTR/RTS checkboxes,
Open/Close/Clear/Save buttons.  Coordinates are supplied at build time; the
window lays this panel into the right-hand column of the top split.
------------------------------------------------------------------------]]--

local c = require("controls")

local M = {}

local BAUD_RATES = {
    "1200", "2400", "4800", "9600", "19200", "38400", "57600", "74880", "115200",
    "230400", "460800", "921600", "1000000", "1500000", "2000000", "3000000",
    "4000000", "4500000",
}
local DATA_BITS = { "5", "6", "7", "8" }
local STOP_BITS = { "1", "1.5", "2" }
local PARITY = { "None", "Odd", "Even", "Mark", "Space" }
local FLOW = { "None", "HW (RTS/CTS)", "SW (XON/XOFF)" }

-- combo(panel, items, x, y, w, drop_h)
local function combo(panel, items, x, y, w, drop_h)
    return c.combo(panel, items, {
        x = x, y = y, w = w or 110, h = drop_h or 200,
    })
end

-- build(parent, x, y, w) -> panel record (all controls as fields).  `parent`
-- is the child-owning HWND (the main window); controls are created on it.
function M.build(parent, x, y, w)
    local panel = {}
    local col_w = w or 160
    local label_w = 42
    local row_h = 26
    local row_gap = 7
    local ctrl_w = col_w - label_w - 12
    local cy = y + 8

    panel.labels = {}
    local function label(title, opts)
        local ctl = c.label(parent, title, opts)
        panel.labels[#panel.labels + 1] = ctl
        return ctl
    end
    local function label_row(title, ctl)
        label(title, { x = x + 4, y = cy, w = label_w, h = row_h })
        ctl.y = cy
        cy = cy + row_h + row_gap
        return ctl
    end

    -- Port: combo + little refresh button on the same line.
    label("Port", { x = x + 4, y = cy, w = label_w, h = row_h })
    panel.port = combo(parent, {}, x + 4 + label_w + 2, cy, ctrl_w - 22, 200)
    panel.refresh = c.button(parent, "R", { x = x + 4 + label_w + 2 + ctrl_w - 22, y = cy, w = 20, h = row_h })
    cy = cy + row_h + row_gap

    panel.baud = label_row("Baud", combo(parent, BAUD_RATES, x + 4 + label_w + 2, cy, ctrl_w))
    panel.data = label_row("Data", combo(parent, DATA_BITS, x + 4 + label_w + 2, cy, ctrl_w))
    panel.parity = label_row("Parity", combo(parent, PARITY, x + 4 + label_w + 2, cy, ctrl_w))
    panel.stop = label_row("Stop", combo(parent, STOP_BITS, x + 4 + label_w + 2, cy, ctrl_w))
    panel.flow = label_row("Flow", combo(parent, FLOW, x + 4 + label_w + 2, cy, ctrl_w))

    -- DTR / RTS side by side.
    label("Line", { x = x + 4, y = cy, w = label_w, h = row_h })
    panel.dtr = c.checkbox(parent, "DTR", { x = x + 4 + label_w + 2, y = cy, w = 46, h = 20 })
    panel.rts = c.checkbox(parent, "RTS", { x = x + 4 + label_w + 2 + 50, y = cy, w = 46, h = 20 })
    cy = cy + row_h + row_gap

    -- Open / Close.
    panel.open = c.button(parent, "Open", { x = x + 6, y = cy, w = (col_w - 18) / 2, h = 30 })
    panel.close = c.button(parent, "Close", { x = x + 6 + (col_w - 18) / 2, y = cy, w = (col_w - 18) / 2, h = 30 })
    cy = cy + 30 + row_gap

    -- Clear / Save.
    panel.clear = c.button(parent, "Clear", { x = x + 6, y = cy, w = (col_w - 18) / 2, h = 30 })
    panel.save = c.button(parent, "Save...", { x = x + 6 + (col_w - 18) / 2, y = cy, w = (col_w - 18) / 2, h = 30 })

    panel.hwnd = parent

    -- The connection panel lives in the right column.  Keeping its geometry
    -- in one place makes that fact survive window resizes.
    function panel.layout(px, py, width)
        local panel_width = width or col_w
        local control_width = panel_width - label_w - 12
        local label_x, control_x = px + 4, px + label_w + 6
        local row_y = py + 8
        local label_index = 1
        local function move_label()
            c.move(panel.labels[label_index], label_x, row_y, label_w, row_h)
            label_index = label_index + 1
        end
        move_label()
        c.move(panel.port, control_x, row_y, control_width - 22, 200)
        c.move(panel.refresh, control_x + control_width - 22, row_y, 20, row_h)
        row_y = row_y + row_h + row_gap
        for _, ctl in ipairs({ panel.baud, panel.data, panel.parity, panel.stop, panel.flow }) do
            move_label()
            c.move(ctl, control_x, row_y, control_width, 200)
            row_y = row_y + row_h + row_gap
        end
        move_label()
        c.move(panel.dtr, control_x, row_y, 46, 20)
        c.move(panel.rts, control_x + 50, row_y, 46, 20)
        row_y = row_y + row_h + row_gap
        local button_width = math.floor((panel_width - 18) / 2)
        c.move(panel.open, px + 6, row_y, button_width, 30)
        c.move(panel.close, px + 10 + button_width, row_y, button_width, 30)
        row_y = row_y + 30 + row_gap
        c.move(panel.clear, px + 6, row_y, button_width, 30)
        c.move(panel.save, px + 10 + button_width, row_y, button_width, 30)
    end
    panel.layout(x, y, col_w)
    return panel
end

return M
