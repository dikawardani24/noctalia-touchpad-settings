--!nonstrict
-- preview.luau — Touchpad Settings test area (API 28, no graph pointer events).
--
-- An interactive preview box built from a grid of small ui.box elements. Each
-- box has an onHover callback whose key encodes its grid position. When the
-- user hovers cells, they light up to form a trail; movement speed is computed
-- from the distance and time between consecutive hover events.

local Preview = {}

-- Grid dimensions.
local COLS = 16
local ROWS = 8
local CELL_SIZE = 30 -- px

-- Rolling trail: array of { col, row } positions. Oldest removed when full.
local trail = {}
local MAX_TRAIL = 80

-- Speed tracking: distance (in grid units) / time between hovers.
local lastCol, lastRow, lastT = nil, nil, 0
local speed = 0 -- grid-units per ms

-- ---------------------------------------------------------------------------
-- Hover tracking
-- ---------------------------------------------------------------------------

-- Parses a cell key "c3r5" into col, row (1-based). Returns nil on bad input.
local function parseKey(key)
  local c, r = string.match(tostring(key), "^c(%d+)r(%d+)$")
  if c and r then
    return tonumber(c), tonumber(r)
  end
  return nil, nil
end

-- Called by each grid box's onHover. `state` is "true" on enter, "false" on leave.
-- `key` is the cell's key like "c3r5".
function Preview.onGridHover(state, key)
  if state ~= "true" then return end
  local col, row = parseKey(key)
  if not col then return end

  local now = noctalia.nowMs()

  -- Speed: Euclidean distance in grid cells / time delta.
  if lastCol and lastT then
    local dx = col - lastCol
    local dy = row - lastRow
    local dist = math.sqrt(dx * dx + dy * dy)
    local dt = math.max(1, now - lastT)
    speed = dist / dt -- grid-cells per ms
  end

  lastCol, lastRow, lastT = col, row, now

  -- Append to trail, cap length.
  table.insert(trail, { col = col, row = row })
  if #trail > MAX_TRAIL then
    table.remove(trail, 1)
  end
end

function Preview.reset()
  trail = {}
  lastCol, lastRow, lastT = nil, nil, 0
  speed = 0
end

-- Builds a set (table keyed by "col,row") of currently-lit cells for quick lookup.
local function litSet()
  local s = {}
  for i, p in ipairs(trail) do
    local key = p.col .. "," .. p.row
    -- Later entries (newer) are brighter; we keep only the latest index per cell.
    s[key] = i
  end
  return s
end

-- Returns 0..1 fraction for the speed meter. Empirically, fast mouse movement
-- produces speed around 0.5-2 grid/ms; scale so 1.0 ~ 1.5.
function Preview.speedFraction()
  return math.min(1, speed / 1.5)
end

-- ---------------------------------------------------------------------------
-- Rendering
-- ---------------------------------------------------------------------------

-- Resolves the sensitivity value to display.
local function displaySensitivity(cfg, sensitivity)
  local value = sensitivity
  if value == nil and cfg then value = cfg.pointer_speed end
  value = tonumber(value)
  if value == nil then value = 0 end
  return value
end

-- Builds the grid of colored boxes. Returns a list of ui.box nodes.
local function buildGrid(ui, lit)
  local cells = {}
  for row = 1, ROWS do
    local boxes = {}
    for col = 1, COLS do
      local key = "c" .. col .. "r" .. row
      local idx = lit[key]
      local alpha
      if idx then
        -- Brighter for newer entries; fade from 0.15 (oldest) to 0.65 (newest).
        alpha = 0.15 + (idx / MAX_TRAIL) * 0.50
      end
      table.insert(boxes, ui.box({
        key = key,
        width = CELL_SIZE,
        height = CELL_SIZE,
        radius = 3,
        fill = idx and ("primary/" .. string.format("%.2f", alpha)) or "surface",
        onHover = function(state, k) Preview.onGridHover(state, k) end,
      }))
    end
    table.insert(cells, ui.row({ gap = 1 }, boxes))
  end
  return cells
end

-- Renders the test-area section. `cfg` is the live config (used only to
-- display the current sensitivity). Returns a ui.* tree.
function Preview.render(ui, cfg, sensitivity)
  local frac = displaySensitivity(cfg, sensitivity)
  local meterFrac = Preview.speedFraction()
  local lit = litSet()
  local grid = buildGrid(ui, lit)

  return ui.column({ gap = 8 }, {
    ui.label({ text = "Test Area", fontWeight = "medium", color = "on_surface_variant" }),
    ui.label({ text = "Move your cursor inside to preview sensitivity. Nothing is saved here.", fontSize = 12, color = "on_surface_variant" }),

    ui.column({ gap = 10, fill = "surface", radius = 12, padding = 12 }, {
      -- The grid of hover-detecting boxes.
      ui.column({ gap = 1 }, grid),

      -- Live readout row: sensitivity + movement speed meter.
      ui.row({ gap = 12, align = "center" }, {
        ui.label({ text = string.format("Sensitivity %.2f", frac), color = "on_surface", flexGrow = 1 }),
        ui.progress({
          progress = meterFrac,
          width = 120,
          height = 8,
          radius = 4,
          fill = "primary",
          track = "surface_variant",
        }),
        ui.label({ text = string.format("%d%%", math.floor(meterFrac * 100)), fontSize = 12, color = "on_surface_variant" }),
      }),
    }),
  })
end

return Preview
