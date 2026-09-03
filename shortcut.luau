--!nonstrict
-- Control-center shortcut entry: a quick-toggle tile that opens the
-- Touchpad Settings panel.

local panelId = "dika/touchpad-settings:touchpad-settings"

local function render()
  shortcut.setLabel("Touchpad Settings")
  shortcut.setIcon("hand-finger")
  shortcut.setActive(false)
  shortcut.setEnabled(true)
end

render()

function onClick()
  noctalia.togglePanel(panelId)
end
