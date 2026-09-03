--!nonstrict
-- panel.luau — Touchpad Settings main UI panel (Noctalia v5, API 28).
--
-- A settings-style panel: build a declarative ui.* tree and hand it to
-- panel.render(). Render on onOpen and again from any callback that changes
-- state. Value callbacks arrive as strings; toggles as "true"/"false".
--
-- Sections: Header, Touchpad, Devices, Presets, Preview, Advanced, Reset.
-- Every control updates Niri live (no logout) and persists to the durable
-- data file in pluginDataDir().

local Settings = require("./settings.luau")
local Service = require("./service.luau")
local Preview = require("./preview.luau")

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local cfg = nil                       -- normalized config (source of truth)
local liveSensitivity = 0              -- preview-only pointer value during drag

local accelProfile = Settings.DEFAULTS.accel_profile
local naturalScroll = Settings.DEFAULTS.natural_scroll
local scrollSpeed = Settings.DEFAULTS.scroll_speed
local tapToClick = Settings.DEFAULTS.tap_to_click

local devices = {}
local hasDevices = false
local libinputMissing = false

local selectedPreset = nil
local expandedDevice = nil             -- device name whose page is open
local showResetConfirm = false

local ACCEL_LABELS = { "Adaptive", "Flat", "Custom" }
local ACCEL_VALUES = { "adaptive", "flat", "custom" }

local PRESETS = {
  { id = "productivity", title = "Productivity", detail = "Adaptive · 0.35 · 80" },
  { id = "gaming", title = "Gaming", detail = "Flat · 0.20 · 60" },
  { id = "precision", title = "Precision Design", detail = "Adaptive · -0.20 · 40" },
}

-- ---------------------------------------------------------------------------
-- Toast + helpers
-- ---------------------------------------------------------------------------

local function notify(title, body)
  if noctalia.notify then noctalia.notify(title, body) end
end

local function clampSpeed(v)
  return math.max(Settings.SPEED_MIN, math.min(Settings.SPEED_MAX, tonumber(v) or 0))
end

local function clampScroll(v)
  return math.max(Settings.SCROLL_MIN, math.min(Settings.SCROLL_MAX, tonumber(v) or Settings.SCROLL_MIN))
end

-- Syncs UI state back from cfg (used after presets/reset).
local function syncFromCfg()
  accelProfile = Settings.accelProfile(cfg)
  naturalScroll = Settings.naturalScroll(cfg)
  scrollSpeed = Settings.scrollSpeed(cfg)
  tapToClick = cfg.tap_to_click
  liveSensitivity = Settings.pointerSpeed(cfg)
  devices = cfg.devices or {}
end

-- Persists + writes to Niri + reloads, with toast + one retry on failure.
local function commitAndReload(message)
  local function onSuccess()
    if message then notify("Touchpad Settings", message) end
  end
  local function onError(reason)
    notify("Touchpad Settings", "Could not apply settings: " .. tostring(reason))
    if noctalia.setTimeout then
      noctalia.setTimeout(function()
        Service.commit(cfg)
      end, 800)
    end
  end
  Service.commit(cfg, onSuccess, onError)
end

-- ---------------------------------------------------------------------------
-- Control handlers
-- ---------------------------------------------------------------------------

function Panel_pointerSpeedChange(value)
  liveSensitivity = clampSpeed(value)
  render()
end

function Panel_pointerSpeedEnd()
  Service.setPointerSpeed(cfg, liveSensitivity)
  cfg.pointer_speed = liveSensitivity
  commitAndReload("Pointer speed updated")
end

function Panel_scrollSpeedChange(value)
  scrollSpeed = clampScroll(value)
  render()
end

function Panel_scrollSpeedEnd()
  Service.setScrollSpeed(cfg, scrollSpeed)
  commitAndReload("Scroll speed updated")
end

function Panel_accelChange(index, _text)
  accelProfile = ACCEL_VALUES[tonumber(index) or 1] or "adaptive"
  Service.setAccelerationProfile(cfg, accelProfile)
  commitAndReload("Acceleration profile updated")
  render()
end

function Panel_naturalScrollChange(value)
  naturalScroll = value == "true"
  Service.setNaturalScroll(cfg, naturalScroll)
  commitAndReload(naturalScroll and "Natural scrolling enabled" or "Natural scrolling disabled")
end

function Panel_tapToClickChange(value)
  tapToClick = value == "true"
  cfg.tap_to_click = tapToClick
  commitAndReload(tapToClick and "Tap to click enabled" or "Tap to click disabled")
end

local PRESET_NAMES = { productivity = "Productivity", gaming = "Gaming", precision = "Precision Design" }

function Panel_presetClick(presetId)
  selectedPreset = presetId
  Service.applyPreset(cfg, presetId, function()
    syncFromCfg()
    render()
    notify("Touchpad Settings", (PRESET_NAMES[presetId] or presetId) .. " preset applied")
  end, function(reason)
    notify("Touchpad Settings", tostring(reason))
  end)
end

function Panel_deviceToggle(name)
  expandedDevice = (expandedDevice == name) and nil or name
  render()
end

-- Generic per-device control change (value arrives as string).
function Panel_deviceChanged(name, key, value)
  for _, d in ipairs(devices) do
    if d.name == name then
      if key == "pointer_speed" then
        d.pointer_speed = clampSpeed(value)
      elseif key == "scroll_speed" then
        d.scroll_speed = clampScroll(value)
      elseif key == "accel_profile" then
        d.accel_profile = value
      elseif key == "natural_scroll" then
        d.natural_scroll = value == "true"
      elseif key == "tap_to_click" then
        d.tap_to_click = value == "true"
      end
    end
  end
  cfg.devices = devices
  commitAndReload()
  render()
end

function Panel_reloadNow()
  Service.commit(cfg,
    function() notify("Touchpad Settings", "Niri input configuration reloaded") end,
    function(reason) notify("Touchpad Settings", tostring(reason)) end)
end

function Panel_requestReset()
  showResetConfirm = true
  render()
end

function Panel_cancelReset()
  showResetConfirm = false
  render()
end

function Panel_confirmReset()
  showResetConfirm = false
  Service.resetAll(cfg, function()
    syncFromCfg()
    notify("Touchpad Settings", "Settings reset successfully")
    render()
  end, function(reason)
    notify("Touchpad Settings", tostring(reason))
  end)
end

-- Syncs UI state back from cfg after presets/reset.
function Panel_sync()
  syncFromCfg()
end

-- ---------------------------------------------------------------------------
-- UI construction
-- ---------------------------------------------------------------------------

local function accelIndex()
  for i, v in ipairs(ACCEL_VALUES) do
    if v == accelProfile then return i - 1 end
  end
  return 0
end

-- A labelled section: heading above a filled card.
local function section(ui, title, child)
  return ui.column({ gap = 8 }, {
    ui.label({ text = title, fontWeight = "medium", color = "on_surface_variant" }),
    ui.column({ gap = 14, fill = "surface", radius = 12, padding = 14, border = "outline", borderWidth = 1 }, child),
  })
end

-- A labeled control row: label on the left, control on the right.
local function controlRow(ui, label, control)
  return ui.row({ gap = 14, align = "center" }, {
    ui.label({ text = label, color = "on_surface", flexGrow = 1 }),
    control,
  })
end

local function renderPointer(ui)
  return section(ui, "Pointer", {
    controlRow(ui, "Pointer speed  " .. string.format("%.2f", liveSensitivity), ui.column({ gap = 6 }, {
      ui.slider({
        min = Settings.SPEED_MIN,
        max = Settings.SPEED_MAX,
        step = Settings.SPEED_STEP,
        value = liveSensitivity,
        onChange = Panel_pointerSpeedChange,
        onDragEnd = Panel_pointerSpeedEnd,
      }),
    })),
    controlRow(ui, "Acceleration profile",
      ui.select({
        options = ACCEL_LABELS,
        selectedIndex = accelIndex(),
        onChange = Panel_accelChange,
      })),
  })
end

local function renderScrolling(ui)
  return section(ui, "Touchpad", {
    controlRow(ui, "Natural scroll",
      ui.toggle({
        checked = naturalScroll,
        onChange = Panel_naturalScrollChange,
      })),
    controlRow(ui, "Tap to click",
      ui.toggle({
        checked = tapToClick,
        onChange = Panel_tapToClickChange,
      })),
    controlRow(ui, "Scroll speed  " .. tostring(scrollSpeed),
      ui.slider({
        min = Settings.SCROLL_MIN,
        max = Settings.SCROLL_MAX,
        value = scrollSpeed,
        onChange = Panel_scrollSpeedChange,
        onDragEnd = Panel_scrollSpeedEnd,
      })),
  })
end

local function renderDevices(ui)
  if not hasDevices or #devices == 0 then
    if libinputMissing then
      return section(ui, "Devices", {
        ui.column({ gap = 4, align = "center", paddingV = 16 }, {
          ui.label({ text = "Could not list touchpads.", color = "on_surface" }),
          ui.label({ text = "Install libinput to detect and configure per-device settings.", fontSize = 12, color = "on_surface_variant" }),
        }),
      })
    end
    return section(ui, "Devices", {
      ui.column({ gap = 4, align = "center", paddingV = 16 }, {
        ui.label({ text = "No touchpad detected.", color = "on_surface" }),
        ui.label({ text = "Connect or enable a touchpad to configure device-specific settings.", fontSize = 12, color = "on_surface_variant" }),
      }),
    })
  end

  local rows = {}
  for _, device in ipairs(devices) do
    local isOpen = expandedDevice == device.name
    local isTouchpad = device.kind == "touchpad"
    table.insert(rows, ui.row({ gap = 12, align = "center" }, {
      ui.glyph({ name = "hand-finger", size = 16, color = "on_surface_variant" }),
      ui.column({ gap = 0, flexGrow = 1 }, {
        ui.label({ text = device.name, color = "on_surface" }),
        ui.label({ text = isTouchpad and "Touchpad" or "Mouse", fontSize = 11, color = "on_surface_variant" }),
      }),
      ui.button({
        text = isOpen and "Collapse" or "Configure",
        variant = isOpen and "secondary" or "outline",
        controlSize = "sm",
        onClick = function() Panel_deviceToggle(device.name) end,
      }),
    }))

    if isOpen then
      local controls = {
        controlRow(ui, "Pointer speed " .. string.format("%.2f", device.pointer_speed),
          ui.slider({
            min = Settings.SPEED_MIN,
            max = Settings.SPEED_MAX,
            step = Settings.SPEED_STEP,
            value = device.pointer_speed,
            onChange = function(v) Panel_deviceChanged(device.name, "pointer_speed", v) end,
          })),
        controlRow(ui, "Acceleration profile",
          ui.select({
            options = ACCEL_LABELS,
            selectedIndex = deviceAccelIndex(device.accel_profile),
            onChange = function(i, _t) Panel_deviceChanged(device.name, "accel_profile", ACCEL_VALUES[tonumber(i) or 1]) end,
          })),
        controlRow(ui, "Natural scroll",
          ui.toggle({
            checked = device.natural_scroll,
            onChange = function(v) Panel_deviceChanged(device.name, "natural_scroll", v) end,
          })),
      }
      if isTouchpad then
        table.insert(controls, controlRow(ui, "Tap to click",
          ui.toggle({
            checked = device.tap_to_click,
            onChange = function(v) Panel_deviceChanged(device.name, "tap_to_click", v) end,
          })))
      end
      table.insert(controls, controlRow(ui, "Scroll speed " .. tostring(device.scroll_speed),
        ui.slider({
          min = Settings.SCROLL_MIN,
          max = Settings.SCROLL_MAX,
          value = device.scroll_speed,
          onChange = function(v) Panel_deviceChanged(device.name, "scroll_speed", v) end,
        })))
      table.insert(rows, ui.column({ gap = 12, paddingH = 4 }, controls))
    end
  end

  return section(ui, "Devices", {
    ui.label({ text = "Niri applies one pointer profile to all touchpads, so these overrides feed the global touchpad settings.", fontSize = 11, color = "on_surface_variant" }),
    rows,
  })
end

local function deviceAccelIndex(profile)
  for i, v in ipairs(ACCEL_VALUES) do
    if v == profile then return i - 1 end
  end
  return 0
end

local function renderPresets(ui)
  local cards = {}
  for _, preset in ipairs(PRESETS) do
    local selected = selectedPreset == preset.id
    table.insert(cards, ui.button({
      text = preset.title,
      variant = selected and "primary" or "outline",
      selected = selected,
      flexGrow = 1,
      tooltip = preset.detail,
      onClick = function() Panel_presetClick(preset.id) end,
    }))
  end
  return section(ui, "Presets", {
    ui.label({ text = "Apply a preset instantly.", fontSize = 12, color = "on_surface_variant" }),
    ui.row({ gap = 10 }, cards),
  })
end

local function renderPreview(ui)
  return ui.column({ gap = 8 }, {
    Preview.render(ui, cfg, liveSensitivity),
  })
end

local function renderAdvanced(ui)
  return section(ui, "Advanced", {
    controlRow(ui, "Reload Niri input configuration",
      ui.button({ text = "Reload now", variant = "secondary", controlSize = "sm", onClick = Panel_reloadNow })),
    ui.label({ text = "Changes are written to Niri's input config and applied without logging out.", fontSize = 12, color = "on_surface_variant" }),
  })
end

local function renderReset(ui)
  local body
  if showResetConfirm then
    body = {
      ui.label({ text = "Reset all touchpad settings to defaults?", color = "on_surface" }),
      ui.row({ gap = 10, justify = "end" }, {
        ui.button({ text = "Cancel", variant = "ghost", controlSize = "sm", onClick = Panel_cancelReset }),
        ui.button({ text = "Reset", variant = "destructive", controlSize = "sm", onClick = Panel_confirmReset }),
      }),
    }
  else
    body = {
      ui.label({ text = "Restore speed, acceleration, natural scroll and scroll speed to factory defaults.", fontSize = 12, color = "on_surface_variant" }),
      ui.row({ gap = 10, justify = "end" }, {
        ui.button({ text = "Reset to Default", variant = "destructive", controlSize = "sm", onClick = Panel_requestReset }),
      }),
    }
  end
  return section(ui, "Reset", body)
end

-- ---------------------------------------------------------------------------
-- Render
-- ---------------------------------------------------------------------------

function render()
  if not cfg then
    panel.render(ui.label({ text = "Touchpad Settings: initializing…", color = "on_surface_variant" }))
    return
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16 }, {
    -- Header.
    ui.row({ align = "center", justify = "space_between", gap = 8 }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = "Touchpad Settings", fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = "Pointer, scrolling and per-device touchpad settings.", fontSize = 12, color = "on_surface_variant" }),
      }),
      ui.button({ glyph = "close", onClick = function() panel.close() end }),
    }),

    -- Body.
    ui.scroll({ flexGrow = 1, gap = 16 }, {
      renderPointer(ui),
      renderScrolling(ui),
      renderDevices(ui),
      renderPresets(ui),
      renderPreview(ui),
      renderAdvanced(ui),
      renderReset(ui),
    }),
  }))
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

-- Seeds config from manifest defaults (honoring any the user set in
-- Settings → Plugins), then refreshes devices.
function onOpen(_context)
  local defaults = {
    pointer_speed = noctalia.getConfig("pointer_speed") or Settings.DEFAULTS.pointer_speed,
    accel_profile = noctalia.getConfig("accel_profile") or Settings.DEFAULTS.accel_profile,
    natural_scroll = noctalia.getConfig("natural_scroll") ~= nil and (noctalia.getConfig("natural_scroll") == true or noctalia.getConfig("natural_scroll") == "true")
      or Settings.DEFAULTS.natural_scroll,
    scroll_speed = noctalia.getConfig("scroll_speed") or Settings.DEFAULTS.scroll_speed,
    tap_to_click = noctalia.getConfig("tap_to_click") ~= nil and (noctalia.getConfig("tap_to_click") == true or noctalia.getConfig("tap_to_click") == "true")
      or Settings.DEFAULTS.tap_to_click,
  }
  cfg = Settings.load(defaults)
  syncFromCfg()
  Preview.reset()

  -- Detect touchpads asynchronously; re-render once the list is ready.
  Service.refreshDevices(cfg, function(list, any, unavailable)
    devices = list
    cfg.devices = list
    hasDevices = any
    libinputMissing = unavailable == true
    render()
  end)

  render()
end

function onClose()
  -- Nothing to tear down; saves happen per-control.
end
