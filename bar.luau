--!nonstrict
-- Bar widget entry: a touchpad glyph in the bar that opens the Touchpad
-- Settings panel on click.

local panelId = "dika/touchpad-settings:touchpad-settings"

local function render()
  barWidget.setGlyph("hand-finger")
  barWidget.setTooltip("Touchpad Settings — click to open")
end

function update()
  noctalia.setUpdateInterval(60000)
  render()
end

function onClick()
  noctalia.togglePanel(panelId)
end
