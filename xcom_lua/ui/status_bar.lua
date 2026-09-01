--[[--------------------------------------------------------------------------
ui/status_bar.lua - bottom status line: port state, RX/TX, drops, clock.

A single child static child label strip drawn as several text fields placed on
a thin bar across the bottom of the main window.  Values are refreshed by the
window's status timer via set_* methods.
------------------------------------------------------------------------]]--

local ffi = require("ffi")
local w = require("win32")
local c = require("controls")

local M = {}

-- `make` never used a bar-total-width parameter (each label carries its own
-- min_w and lays out left-to-right), so it does not take one.
local function make(parent, label_counts, height, y)
    -- label_counts: list of { text=, min_w= } to place left-to-right.
    local labels = {}
    local x = 8
    for _, lc in ipairs(label_counts or {}) do
        local lab = c.label(parent, lc.text or "", {
            x = x, y = y, w = lc.min_w or 100, h = height,
        })
        labels[#labels + 1] = lab
        x = x + (lc.min_w or 100) + 6
    end
    return { labels = labels }
end

function M.create(parent, opts)
    opts = opts or {}
    local height = opts.height or 22
    local bar = make(parent, {
        { text = "CLOSED", min_w = 90 },
        { text = "RX 0  TX 0", min_w = 110 },
        { text = "drops: 0", min_w = 140 },
        { text = "", min_w = 160 },
    }, height, opts.y or 0)

    function bar.set_port(text)
        c.set_text(bar.labels[1], text)
    end

    function bar.set_rxtx(text)
        c.set_text(bar.labels[2], text)
    end

    function bar.set_drops(text)
        c.set_text(bar.labels[3], text)
    end

    function bar.set_clock(text)
        c.set_text(bar.labels[4], text)
    end

    function bar.layout(width, y)
        local x = 16
        local widths = { 96, 132, math.max(180, width - 520), 150 }
        for i, label in ipairs(bar.labels) do
            c.move(label, x, y + 5, widths[i], height - 8)
            x = x + widths[i] + 10
        end
    end

    return bar
end

return M
