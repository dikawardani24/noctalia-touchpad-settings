--!nonstrict
-- settings.luau — Touchpad Settings persistence + value logic.
--
-- Owns the durable configuration data model: defaults, clamping/validation,
-- presets and the JSON file store (persisted in noctalia.pluginDataDir() so
-- values survive reboots and plugin updates). Reads any existing config on
-- startup; the manifest [[setting]] defaults are used only on first run.
--
-- Data model (stored as JSON):
--   pointer_speed    = 0.35
--   accel_profile    = "adaptive"
--   natural_scroll   = false
--   scroll_speed     = 80
--   tap_to_click     = true
--   devices = [ { name, pointer_speed, accel_profile, natural_scroll,
--                 scroll_speed, tap_to_click } ... ]

local Settings = {}

-- ---------------------------------------------------------------------------
-- Defaults
-- ---------------------------------------------------------------------------

Settings.DEFAULTS = {
  pointer_speed = 0.0,
  accel_profile = "adaptive",
  natural_scroll = false,
  scroll_speed = 80,
  tap_to_click = true,
}

Settings.KIND_MOUSE = "mouse"
Settings.KIND_TOUCHPAD = "touchpad"

Settings.SPEED_MIN = -1.0
Settings.SPEED_MAX = 1.0
Settings.SPEED_STEP = 0.05

Settings.SCROLL_MIN = 10
Settings.SCROLL_MAX = 200

local VALID_PROFILES = { adaptive = true, flat = true, custom = true }

-- ---------------------------------------------------------------------------
-- Clamping / validation
-- ---------------------------------------------------------------------------

local function clamp(value, min, max)
  value = tonumber(value)
  if value == nil then value = min end
  if value < min then return min end
  if value > max then return max end
  return value
end

local function sanitizeProfile(profile)
  if type(profile) == "string" and VALID_PROFILES[profile] then
    return profile
  end
  return Settings.DEFAULTS.accel_profile
end

-- ---------------------------------------------------------------------------
-- Construction
-- ---------------------------------------------------------------------------

-- Builds a clean config table from a possibly-invalid raw source.
function Settings.normalize(raw)
  raw = raw or {}
  local cfg = {
    pointer_speed = clamp(raw.pointer_speed, Settings.SPEED_MIN, Settings.SPEED_MAX),
    accel_profile = sanitizeProfile(raw.accel_profile),
    natural_scroll = raw.natural_scroll == true,
    scroll_speed = clamp(raw.scroll_speed, Settings.SCROLL_MIN, Settings.SCROLL_MAX),
    tap_to_click = raw.tap_to_click ~= false,
    devices = {},
  }
  if type(raw.devices) == "table" then
    for _, d in ipairs(raw.devices) do
      if type(d) == "table" and d.name then
        table.insert(cfg.devices, {
          kind = Settings.KIND_TOUCHPAD,
          name = tostring(d.name),
          pointer_speed = clamp(d.pointer_speed, Settings.SPEED_MIN, Settings.SPEED_MAX),
          accel_profile = sanitizeProfile(d.accel_profile),
          natural_scroll = d.natural_scroll == true,
          scroll_speed = clamp(d.scroll_speed, Settings.SCROLL_MIN, Settings.SCROLL_MAX),
          tap_to_click = d.tap_to_click ~= false,
        })
      end
    end
  end
  return cfg
end

-- Accessors on a normalized config table.
function Settings.pointerSpeed(cfg) return cfg.pointer_speed end
function Settings.accelProfile(cfg) return cfg.accel_profile end
function Settings.naturalScroll(cfg) return cfg.natural_scroll end
function Settings.scrollSpeed(cfg) return cfg.scroll_speed end

-- ---------------------------------------------------------------------------
-- Presets
-- ---------------------------------------------------------------------------

-- Applies a named preset's values onto a mutable config table. Returns true
-- on success, false for an unknown preset.
function Settings.applyPresetValues(cfg, presetName)
  if presetName == "productivity" then
    cfg.accel_profile = "adaptive"
    cfg.pointer_speed = 0.35
    cfg.scroll_speed = 80
    cfg.natural_scroll = false
    return true
  elseif presetName == "gaming" then
    cfg.accel_profile = "flat"
    cfg.pointer_speed = 0.20
    cfg.scroll_speed = 60
    cfg.natural_scroll = false
    return true
  elseif presetName == "precision" then
    cfg.accel_profile = "adaptive"
    cfg.pointer_speed = -0.20
    cfg.scroll_speed = 40
    cfg.natural_scroll = false
    return true
  end
  return false
end

-- Resets a mutable config table to factory defaults.
function Settings.resetValues(cfg)
  cfg.pointer_speed = Settings.DEFAULTS.pointer_speed
  cfg.accel_profile = Settings.DEFAULTS.accel_profile
  cfg.natural_scroll = Settings.DEFAULTS.natural_scroll
  cfg.scroll_speed = Settings.DEFAULTS.scroll_speed
  cfg.tap_to_click = Settings.DEFAULTS.tap_to_click
end

-- ---------------------------------------------------------------------------
-- Durable store (JSON file in noctalia.pluginDataDir())
-- ---------------------------------------------------------------------------

local CONFIG_FILE = "touchpad-config.json"

-- Resolves the durable config file path. Returns a path string, or nil + err.
function Settings.configPath()
  local dir, err = noctalia.pluginDataDir()
  if not dir then
    return nil, err or "pluginDataDir unavailable"
  end
  return dir .. "/" .. CONFIG_FILE
end

-- Reads existing config on startup. Falls back to manifest defaults seeded by
-- the host (passed in as `defaults`) when no file exists. Never errors.
function Settings.load(defaults)
  local cfg = Settings.normalize(defaults or Settings.DEFAULTS)
  local path = Settings.configPath()
  if path then
    local contents = noctalia.readFile(path)
    if contents then
      local decoded, err = noctalia.json.decode(contents)
      if decoded and type(decoded) == "table" then
        cfg = Settings.normalize(decoded)
      else
        noctalia.log("Touchpad Settings: invalid config file (" .. tostring(err) .. "); using defaults")
      end
    end
  end
  return cfg
end

-- Writes the config table to disk. Returns true, or false + err.
function Settings.save(cfg)
  local path, err = Settings.configPath()
  if not path then return false, err end
  local encoded, encErr = noctalia.json.encode(Settings.normalize(cfg), true)
  if not encoded then return false, tostring(encErr) end
  local ok, writeErr = noctalia.writeFile(path, encoded)
  if not ok then return false, tostring(writeErr) end
  return true
end

return Settings
