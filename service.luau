--!nonstrict
-- service.luau — Touchpad Settings service layer.
--
-- Owns everything that isn't the UI: device detection, the public helper API
-- required by the spec, and orchestrating commit (persist + Niri reload).

local Settings = require("./settings.luau")
local Libinput = require("./libinput.luau")

local Service = {}
Service.Settings = Settings
Service.Libinput = Libinput

-- ---------------------------------------------------------------------------
-- Device detection
-- ---------------------------------------------------------------------------

local KNOWN_VENDORS = {
  { pattern = "logitech", label = "Logitech" },
  { pattern = "razer", label = "Razer" },
  { pattern = "steelseries", label = "SteelSeries" },
  { pattern = "mx master", label = "MX Master" },
}

-- Labels a raw libinput device name with a friendly vendor name.
local function friendlyLabel(rawName)
  local lower = string.lower(tostring(rawName))
  for _, vendor in ipairs(KNOWN_VENDORS) do
    if string.find(lower, vendor.pattern, 1, true) then
      return vendor.label
    end
  end
  return "Generic USB Mouse"
end

-- Classifies a device as mouse or touchpad from its raw libinput name.
-- This touchpad plugin only manages touchpads, so every detected device is
-- treated as a touchpad for this plugin's purposes.
local function classifyKind(rawName, capabilities)
  return Settings.KIND_TOUCHPAD
end

-- Queries libinput for pointer devices. onResult receives a list of device
-- records (raw name + kind) when detection succeeds. The command is run
-- asynchronously. When libinput is unavailable, onResult({}) fires.
-- Detects connected pointer devices via `libinput list-devices` and reports
-- them to onResult(devices, unavailable). When libinput is missing (or the
-- command otherwise cannot run), devices is empty and `unavailable` is true so
-- the panel can show an install hint instead of a bare "no devices" message.
function Service.detectDevices(onResult)
  local function report(none, unavailable)
    if onResult then onResult(none or {}, unavailable == true) end
  end
  local ok = noctalia.runAsync("libinput list-devices", function(result)
    local devices = {}
    local ps = result and result.stderr or ""
    local cannotRun = (not result)
      or (result.stdout == nil or result.stdout == "")
      or string.find(ps or "", "not found", 1, true)
      or string.find(ps or "", "No such file", 1, true)
    if result and result.stdout and not cannotRun then
      local content = result.stdout
      local currentName = nil
      local capabilities = ""
      for line in (content .. "\n"):gmatch("([^\n]*)\n") do
        local name = string.match(line, "Device:%s*(.+)")
        if name then
          if currentName and currentName ~= "" then
            table.insert(devices, {
              rawName = currentName,
              kind = classifyKind(currentName, capabilities),
            })
          end
          currentName = name
          capabilities = ""
        elseif string.find(line, "Capabilities:", 1, true) then
          capabilities = line
        end
      end
      if currentName and currentName ~= "" then
        table.insert(devices, {
          rawName = currentName,
          kind = classifyKind(currentName, capabilities),
        })
      end
    end
    report(devices, cannotRun)
  end)
  if not ok then
    report({}, true)
  end
end

-- Rehydrates the raw detected device records into device configuration using
-- stored values. Each record gets a friendly label and carries its kind.
function Service.devicesForNames(cfg, records)
  local result = {}
  local storedByName = {}
  if type(cfg.devices) == "table" then
    for _, d in ipairs(cfg.devices) do
      storedByName[d.name] = d
    end
  end
  for _, rec in ipairs(records or {}) do
    local label = friendlyLabel(rec.rawName)
    local kind = rec.kind or Settings.KIND_MOUSE
    local stored = storedByName[label]
    local record = stored or {
      kind = kind,
      name = label,
      pointer_speed = Settings.DEFAULTS.pointer_speed,
      accel_profile = Settings.DEFAULTS.accel_profile,
      natural_scroll = Settings.DEFAULTS.natural_scroll,
      scroll_speed = Settings.DEFAULTS.scroll_speed,
      tap_to_click = Settings.DEFAULTS.tap_to_click,
    }
    if not stored then
      record.kind = kind
      record.name = label
    end
    table.insert(result, record)
  end
  return result, #result > 0
end

-- ---------------------------------------------------------------------------
-- Public spec-required helper API (operates on the in-memory cfg table)
-- ---------------------------------------------------------------------------

function Service.getMouseDevices(cfg)
  local _, hasAny = Service.devicesForNames(cfg, {})
  -- We cannot detect synchronously; return the stored device list plus a
  -- flag. Detection is run by refreshDevices() which fills cfg.devices and
  -- calls back the panel.
  return cfg.devices or {}, hasAny
end

function Service.getPointerSpeed(cfg)
  return Settings.pointerSpeed(cfg)
end

function Service.getAccelProfile(cfg)
  return Settings.accelProfile(cfg)
end

function Service.getNaturalScroll(cfg)
  return Settings.naturalScroll(cfg)
end

function Service.getScrollSpeed(cfg)
  return Settings.scrollSpeed(cfg)
end

function Service.setPointerSpeed(cfg, value)
  cfg.pointer_speed = Service.clampSpeed(value)
end

function Service.setAccelerationProfile(cfg, profile)
  cfg.accel_profile = profile
end

function Service.setNaturalScroll(cfg, enabled)
  cfg.natural_scroll = enabled == true
end

function Service.setScrollSpeed(cfg, value)
  cfg.scroll_speed = Service.clampScroll(value)
end

-- Clamping helpers.
function Service.clampSpeed(value)
  value = tonumber(value)
  if value == nil then return Settings.DEFAULTS.pointer_speed end
  return math.max(Settings.SPEED_MIN, math.min(Settings.SPEED_MAX, value))
end

function Service.clampScroll(value)
  value = tonumber(value)
  if value == nil then return Settings.DEFAULTS.scroll_speed end
  return math.max(Settings.SCROLL_MIN, math.min(Settings.SCROLL_MAX, value))
end

-- ---------------------------------------------------------------------------
-- Commit / presets / reset
-- ---------------------------------------------------------------------------

-- Writes the current config to disk, applies it to Niri and reloads.
-- onSuccess/onError fire for the reload result.
function Service.commit(cfg, onSuccess, onError)
  Settings.save(cfg)
  return Libinput.apply(cfg, onSuccess, onError)
end

-- Applies a named preset to the global config and commits.
function Service.applyPreset(cfg, presetName, onSuccess, onError)
  if not Settings.applyPresetValues(cfg, presetName) then
    if onError then onError("Unknown preset: " .. tostring(presetName)) end
    return false
  end
  Service.commit(cfg, onSuccess, onError)
  return true
end

-- Applies a preset to an individual device record.
function Service.applyPresetToDevice(device, presetName)
  return Settings.applyPresetValues(device, presetName)
end

-- Resets global + device settings to defaults and commits.
function Service.resetAll(cfg, onSuccess, onError)
  Settings.resetValues(cfg)
  if type(cfg.devices) == "table" then
    for _, d in ipairs(cfg.devices) do
      Settings.resetValues(d)
    end
  end
  Service.commit(cfg, onSuccess, onError)
  return true
end

-- ---------------------------------------------------------------------------
-- Hotplug / refresh
-- ---------------------------------------------------------------------------

-- Asynchronously re-detects touchpads, merges into cfg.devices, then calls the
-- panel's callback with the new device list and whether libinput was available.
function Service.refreshDevices(cfg, onAsyncDone)
  Service.detectDevices(function(names, unavailable)
    local devices = Service.devicesForNames(cfg, names)
    cfg.devices = devices
    if onAsyncDone then onAsyncDone(devices, #names > 0, unavailable) end
  end)
end

return Service
