--[[--------------------------------------------------------------------------
core/device_profiles.lua - static USB-UART bridge capability table.

Pure Lua, module-level read-only data, linear scan.  There is deliberately no
factory, pool, registry or abstraction layer: the table is a compile-time
constant and `resolve` is a first-match walk over it.  The module must be
requireable on Linux with no DLL so the resolution rules are unit-testable.

Capability model (see docs/design-device-profiles.md):

  PROFILES entries are keyed by the bridge's STABLE identity, not by COMx
  (re-enumeration renumbers the port).  Resolution priority:

      per-key custom override  >  hardware_id prefix  >  description  >  default

  `hwid` is the Windows `USB\VID_xxxx&PID_xxxx` string (SetupAPI
  SPDRP_HARDWAREID, XcomPortInfo.hardware_id, added by design step 6).  Until
  that lands the key degrades to the SERIALCOMM description heuristic.

Profile shape:

  id                  stable selector, also the user override-id
  match               { hwid_prefix = "USB\\VID_....", desc_find = "CH340" }
  reset               { mode = "auto"|"manual"|"none",
                        edges = { {rts=1}, {dtr=1, delay=120}, ... },
                        reenumerates = bool, settle_ms = ms }
  flow_control        "ok" | "warn" | "unsupported"
  silent_warn_ms      link-silent threshold for the recovery overlay
  manual_instructions on-screen prompt for reset.mode == "manual"

reset.edges is interpreted as: each edge's `delay` is the wait BEFORE that
edge, measured from the previous edge (the first edge with no delay fires
immediately).  core/reset_sequencer.lua consumes it that way.
------------------------------------------------------------------------]]--

local config = require("config")

local M = {}

-- Uppercase hex VID/PID, verified against the USB ID database and the Linux
-- kernel drivers (ch341, cp210x, ftdi_sio):
--   CH340/CH341  1A86:7523  (0x5523 is a CH341 in EPP/MEM mode)
--   CP210x       10C4:EA60
--   FT232R       0403:6001  (6010/6011 are the dual/quad FT2232/FT4232)
M.PROFILES = {
    { id = "ch340",
      match = { hwid_prefix = "USB\\VID_1A86&PID_7523", desc_find = "CH340" },
      reset = { mode = "auto",
                edges = { { rts = 1 }, { dtr = 1, delay = 120 },
                          { rts = 0, delay = 60 }, { dtr = 0, delay = 50 } },
                reenumerates = true, settle_ms = 3000 },
      flow_control = "warn",
      silent_warn_ms = 5000,
      manual_instructions = "Hold BOOT, tap RST, release BOOT" },

    -- Doc leaves CP210x/FT232R abbreviated; both expose DTR/RTS the same way
    -- as the CH340, so they get the identical auto sequence and only differ in
    -- their stable key.  Real behaviour is unverified without hardware.
    { id = "cp2102",
      match = { hwid_prefix = "USB\\VID_10C4&PID_EA60", desc_find = "CP210" },
      reset = { mode = "auto",
                edges = { { rts = 1 }, { dtr = 1, delay = 120 },
                          { rts = 0, delay = 60 }, { dtr = 0, delay = 50 } },
                reenumerates = true, settle_ms = 3000 },
      flow_control = "warn",
      silent_warn_ms = 5000,
      manual_instructions = "Hold BOOT, tap RST, release BOOT" },

    { id = "ft232r",
      match = { hwid_prefix = "USB\\VID_0403&PID_6001", desc_find = "FT232" },
      reset = { mode = "auto",
                edges = { { rts = 1 }, { dtr = 1, delay = 120 },
                          { rts = 0, delay = 60 }, { dtr = 0, delay = 50 } },
                reenumerates = true, settle_ms = 3000 },
      flow_control = "warn",
      silent_warn_ms = 5000,
      manual_instructions = "Hold BOOT, tap RST, release BOOT" },

    -- Native USB CDC-ACM has no controllable BOOT/EN wiring in general;
    -- hwid_prefix "USB\VID_" is the catch-all for any USB bridge not matched
    -- above (it is LAST of the identity entries on purpose).
    { id = "cdc_acm",
      match = { hwid_prefix = "USB\\VID_", desc_find = "USB Serial" },
      reset = { mode = "manual", reenumerates = true },
      flow_control = "warn",
      silent_warn_ms = 5000,
      manual_instructions = "Hold BOOT, tap RST, release BOOT" },

    { id = "default",
      match = {},
      reset = { mode = "manual" },
      flow_control = "ok",
      silent_warn_ms = 5000,
      manual_instructions = "Reset the board manually, then reconnect" },
}

-- ---------------------------------------------------------------------------
-- matching helpers
-- ---------------------------------------------------------------------------

local function has_prefix(hwid, prefix)
    return hwid:sub(1, #prefix):upper() == prefix:upper()
end

local function has_substr(description, find)
    return description:upper():find(find:upper(), 1, true) ~= nil
end

local function by_id(id)
    for _, p in ipairs(M.PROFILES) do
        if p.id == id then
            return p
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- resolve(hwid, description, override_id) -> profile, source
--
-- source is one of "override" | "hardware_id" | "description" | "default".
-- A device the identity table cannot name degrades to the `default` profile
-- (manual reset), never to a wrong auto sequence.
-- ---------------------------------------------------------------------------
function M.resolve(hwid, description, override_id)
    -- 1. an explicitly chosen profile id outranks any inferred match
    if override_id ~= nil and override_id ~= "" then
        local chosen = by_id(override_id)
        if chosen ~= nil then
            return chosen, "override"
        end
    end
    -- 2. hardware_id prefix: identity is trusted over the description text
    if hwid ~= nil and hwid ~= "" then
        for _, p in ipairs(M.PROFILES) do
            if p.match.hwid_prefix ~= nil and has_prefix(hwid, p.match.hwid_prefix) then
                return p, "hardware_id"
            end
        end
    end
    -- 3. description substring (fallback when no hardware_id is available)
    if description ~= nil and description ~= "" then
        for _, p in ipairs(M.PROFILES) do
            if p.match.desc_find ~= nil and has_substr(description, p.match.desc_find) then
                return p, "description"
            end
        end
    end
    -- 4. default
    return by_id("default") or M.PROFILES[#M.PROFILES], "default"
end

-- ---------------------------------------------------------------------------
-- custom-override plumbing
--
-- `[profile.custom]` is a flat table (flat key = value, per docs) whose keys
-- may be dotted paths into the profile shape: "reset.mode", "flow_control", ...
-- ---------------------------------------------------------------------------

local function flatten_into(prefix, tbl, out)
    for k, v in pairs(tbl) do
        local path
        if prefix == "" then
            path = tostring(k)
        else
            path = prefix .. "." .. tostring(k)
        end
        if type(v) == "table" then
            flatten_into(path, v, out)
        else
            out[path] = v
        end
    end
end

local function deep_copy(v)
    if type(v) ~= "table" then
        return v
    end
    local copy = {}
    for k, sub in pairs(v) do
        copy[k] = deep_copy(sub)
    end
    return copy
end

local function set_path(tbl, path, value)
    local node = tbl
    local key = nil
    for part in (path .. "."):gmatch("(.-)%.") do
        if key ~= nil and node[key] == nil then
            node[key] = {}
        end
        if key ~= nil then
            node = node[key]
        end
        key = part
    end
    if key ~= nil then
        node[key] = value
    end
end

-- A custom entry is bound to one stable key (though only one custom entry fits
-- per config file; multi-board users must hand-edit `key`, a known limitation).
-- An empty/absent recorded key applies unconditionally.
local function key_matches(recorded, hwid, description)
    if recorded == nil or recorded == "" then
        return true
    end
    local current
    if hwid ~= nil and hwid ~= "" then
        current = hwid
    else
        current = description
    end
    if current == nil then
        return false
    end
    return tostring(recorded):upper() == tostring(current):upper()
end

-- ---------------------------------------------------------------------------
-- for_config(cfg_data, port_info) -> profile, source
--
-- Reads the `[profile]` / `[profile.custom]` sections (config.lua) and applies
-- the per-key custom override on top of the resolved profile.  port_info is an
-- XcomPortInfo-shaped { hardware_id?, description } table.
-- ---------------------------------------------------------------------------
function M.for_config(cfg_data, port_info)
    local sec, custom = config.get_profile(cfg_data or {})
    local hwid = nil
    local description = nil
    if port_info ~= nil then
        hwid = port_info.hardware_id or port_info.hwid
        description = port_info.description
    end
    local profile, source = M.resolve(hwid, description, nil)
    if sec.mode == "custom" and key_matches(sec.key, hwid, description) then
        local patched = deep_copy(profile)
        for path, value in pairs(custom) do
            set_path(patched, path, value)
        end
        return patched, "custom"
    end
    return profile, source
end

-- ---------------------------------------------------------------------------
-- set_override(cfg_data, key, patch) -> cfg_data
--
-- Records a custom override into the config blob.  `patch` may be nested
-- ({ reset = { mode = "manual" } }) or already flat ({ ["reset.mode"] = ... });
-- it is flattened so a save/load round trip yields the documented `[profile]`
-- / `[profile.custom]` shape.
-- ---------------------------------------------------------------------------
function M.set_override(cfg_data, key, patch)
    local flat = {}
    if patch ~= nil then
        flatten_into("", patch, flat)
    end
    config.set_profile(cfg_data, key, "custom", flat)
    return cfg_data
end

return M
