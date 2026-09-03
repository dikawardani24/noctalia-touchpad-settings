--!nonstrict
-- libinput.luau — Niri input configuration service.
--
-- Translates the plugin's high-level touchpad settings into the actual Niri
-- input configuration and reloads Niri live (no restart/logout). The plugin
-- writes a sidecar KDL file that Niri includes, then runs
-- `niri msg action load-config-file`.

local Libinput = {}
Libinput.DEFAULTS = {
  pointer_speed = 0.0,
  accel_profile = "adaptive",
  natural_scroll = false,
  scroll_speed = 80,
}

-- ---------------------------------------------------------------------------
-- Paths
-- ---------------------------------------------------------------------------

-- ~/.config/niri/config.kdl
local function niriConfigDir()
  local home = noctalia.expandPath("~/")
  return home .. ".config/niri/"
end

local function niriConfigPath()
  return niriConfigDir() .. "config.kdl"
end

-- Sidecar KDL file holding the touchpad section we generate.
local function niriTouchpadFilePath()
  return niriConfigDir() .. "noctalia-touchpad.kdl"
end

-- ---------------------------------------------------------------------------
-- KDL generation
-- ---------------------------------------------------------------------------

-- Niri input config only accepts "adaptive" or "flat"; "custom" maps to the
-- accelerated adaptive profile.
local function libinputAccelProfile(profile)
  if profile == "flat" then return "flat" end
  return "adaptive"
end

-- accel-speed is a bare number in [-1.0, 1.0] (NOT a quoted string).
local function libinputAccelSpeed(pointerSpeed)
  return string.format("%.2f", tonumber(pointerSpeed) or 0)
end

-- Maps the plugin's scroll_speed (10-200 "lines") to a Niri scroll-factor
-- multiplier (1.0 at the default 80).
local function libinputScrollFactor(scrollSpeed)
  local v = tonumber(scrollSpeed) or 80
  if v == 0 then return "1.0" end
  return string.format("%.2f", v / 80)
end

-- Emits the body of the `touchpad {}` block from the global config.
-- natural-scroll and tap are flags: they are emitted only when enabled and
-- omitted otherwise (Niri rejects `natural-scroll false`).
local function blockLines(cfg)
  local lines = {}
  table.insert(lines, "    touchpad {")
  table.insert(lines, "        accel-speed " .. libinputAccelSpeed(cfg.pointer_speed))
  table.insert(lines, '        accel-profile "' .. libinputAccelProfile(cfg.accel_profile) .. '"')
  if cfg.natural_scroll then
    table.insert(lines, "        natural-scroll")
  end
  if cfg.tap_to_click then
    table.insert(lines, "        tap")
  end
  if cfg.scroll_speed ~= Libinput.DEFAULTS.scroll_speed then
    table.insert(lines, "        scroll-factor " .. libinputScrollFactor(cfg.scroll_speed))
  end
  table.insert(lines, "    }")
  return lines
end

-- Builds the KDL excerpt: a global `input { touchpad {} }` block. Niri (as of
-- v26) applies these settings to every touchpad; it does not yet support
-- per-device `match` overrides, so the plugin drives the global pointer
-- settings and keeps per-device records for UI only.
local function buildKdl(cfg)
  local out = {}
  table.insert(out, "input {")
  for _, line in ipairs(blockLines(cfg)) do
    table.insert(out, line)
  end
  table.insert(out, "}")
  return table.concat(out, "\n")
end

-- ---------------------------------------------------------------------------
-- Config file writing
-- ---------------------------------------------------------------------------

-- Writes the generated KDL to the sidecar. Returns true, or false + err.
local function writeSidecar(content)
  local ok, err = noctalia.writeFile(niriTouchpadFilePath(), content)
  if not ok then
    return false, tostring(err or "write failed")
  end
  return true
end

-- Ensures the main config.kdl includes the sidecar exactly once, using Niri
-- v26's `include` keyword (older "import" is not accepted). Any pre-existing
-- `import "noctalia-touchpad.kdl"` or duplicate `include` lines from older plugin
-- versions are removed and collapsed into a single include at the end of the
-- file. Non-fatal — returns (false, reason) if it cannot.
local INCLUDE_LINE = 'include "noctalia-touchpad.kdl"'

local function ensureImportInConfig()
  local mainPath = niriConfigPath()
  if not noctalia.fileExists(mainPath) then
    return false, "config.kdl missing; plugin will write it on first run"
  end
  local contents = noctalia.readFile(mainPath)
  if not contents then return false, "cannot read config.kdl" end

  -- Strip every existing touchpad-sidecar include/import line (and their extra
  -- surrounding blank lines) so we never accumulate duplicates.
  local cleaned = {}
  for line in (contents .. "\n"):gmatch("([^\n]*)\n") do
    local trimmed = line:match("^%s*(.-)%s*$")
    if trimmed ~= 'import "noctalia-touchpad.kdl"' and trimmed ~= INCLUDE_LINE then
      table.insert(cleaned, line)
    end
  end
  local cleanedText = table.concat(cleaned, "\n")
  -- Collapse runs of blank lines to at most one, and trim trailing newlines.
  cleanedText = cleanedText:gsub("\n\n\n+", "\n\n"):gsub("\n\n+$", "\n")

  -- Add the include at the end of the file if it isn't already present.
  if not string.find(cleanedText, "noctalia%-touchpad", 1, true) then
    cleanedText = cleanedText:gsub("\n+$", "") .. "\n\n" .. INCLUDE_LINE .. "\n"
  end

  if cleanedText ~= contents then
    local ok, err = noctalia.writeFile(mainPath, cleanedText)
    if not ok then return false, tostring(err or "write failed") end
  end
  return true
end

-- ---------------------------------------------------------------------------
-- Reload
-- ---------------------------------------------------------------------------

-- Reloads Niri's configuration live. Uses `load-config-file` (Niri ≥ 25.06)
-- with a fallback to the older `reload-config` for older Niri builds.
-- Calls onSuccess() if the command was accepted, else onError(reason).
-- Returns true when accepted.
function Libinput.reloadInputConfig(onSuccess, onError)
  local function callback(result)
    if result and result.exitCode == 0 then
      if onSuccess then onSuccess() end
    else
      if onError then
        onError("Niri reload failed (exit " .. tostring(result and result.exitCode) .. ")")
      end
    end
  end
  local ok = noctalia.runAsync("niri msg action load-config-file", callback)
  if not ok then
    -- Fallback: try older command name.
    ok = noctalia.runAsync("niri msg action reload-config", callback)
  end
  return ok
end

-- ---------------------------------------------------------------------------
-- Apply / public API
-- ---------------------------------------------------------------------------

-- Writes the touchpad KDL, ensures the include, and reloads Niri. Returns true
-- on success, or (nil, reason) on failure. onSuccess/onError fire for the reload.
function Libinput.applySensitive(cfg, onSuccess, onError)
  local ok, err = writeSidecar(buildKdl(cfg))
  if not ok then
    if onError then onError(err) end
    return nil, err
  end
  ensureImportInConfig()
  if not Libinput.reloadInputConfig(onSuccess, onError) then
    if onError then onError("could not run niri msg action reload-config") end
    return nil, "reload not dispatched"
  end
  return true
end

-- Convenience alias matching the service layer's naming.
function Libinput.apply(cfg, onSuccess, onError)
  return Libinput.applySensitive(cfg, onSuccess, onError)
end

return Libinput
