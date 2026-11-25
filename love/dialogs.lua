-- Modal prompts: replaces LiveSplit's message boxes ("Save splits?", "Update times?")
-- and its little input boxes ("New comparison name").
--
--   dialogs.message{ title=, text=, buttons = { {label=, primary=, action=fn}, ... } }
--   dialogs.input{ title=, label=, text=, okLabel=, onOk = function(text) end }

local theme = require("theme")
local ui = require("ui")

local dialogs = { stack = {} }
local lg = love.graphics
local damp = ui.damp

function dialogs.isOpen() return #dialogs.stack > 0 end

function dialogs.message(d)
  d.kind = "message"
  d.open = 0
  d.buttons = d.buttons or { { label = "OK", primary = true } }
  dialogs.stack[#dialogs.stack + 1] = d
end

function dialogs.input(d)
  d.kind = "input"
  d.open = 0
  d.value = d.text or ""
  d.focusNext = true
  dialogs.stack[#dialogs.stack + 1] = d
end

function dialogs.error(text)
  dialogs.message({ title = "Error", text = text })
end

local function close(d, action, ...)
  for i, x in ipairs(dialogs.stack) do if x == d then table.remove(dialogs.stack, i) break end end
  if ui.focus and tostring(ui.focus):find("^dlg") then ui.setFocus(nil) end
  if action then action(...) end
end

function dialogs.keypressed(key)
  local d = dialogs.stack[#dialogs.stack]
  if not d then return false end
  if d.kind == "message" then
    if key == "escape" then
      local cancel = d.buttons[#d.buttons]
      close(d, cancel.action)
      return true
    elseif key == "return" or key == "kpenter" then
      for _, b in ipairs(d.buttons) do
        if b.primary then close(d, b.action) return true end
      end
      close(d, d.buttons[1].action)
      return true
    end
  end
  return false   -- input dialogs handle keys through their text box
end

function dialogs.draw(dt)
  local d = dialogs.stack[#dialogs.stack]
  if not d then return end
  local W, H = lg.getDimensions()
  ui.layer = "dialog"
  d.open = damp(d.open, 1, theme.speedOpen, dt)
  local a = d.open

  -- dim everything underneath
  ui.color({ 0, 0, 0, 0.5 * a })
  lg.rectangle("fill", 0, 0, W, H)

  local f = theme.fonts.ui
  local w = math.min(460, W - 32)
  local textW = w - 40
  local _, lines = f:getWrap(d.text or d.label or "", textW)
  local textH = #lines * f:getHeight()
  local h = 58 + textH + 56 + (d.kind == "input" and 40 or 0)
  local x = math.floor((W - w) / 2)
  local y = math.floor((H - h) / 2 + (1 - a) * 12)

  ui.color(theme.shadow, a) ui.rect("fill", x + 3, y + 6, w, h, theme.radius)
  ui.color(theme.panel, a) ui.rect("fill", x, y, w, h, theme.radius)
  ui.color(theme.border, a) ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radius)

  ui.label(d.title or "", x + 20, y + 18, { font = theme.fonts.title, color = theme.text })
  ui.color(theme.textDim, a)
  lg.setFont(f)
  lg.printf(d.text or d.label or "", x + 20, y + 48, textW, "left")

  local by = y + h - 46
  if d.kind == "message" then
    local gap = 8
    local widths, total = {}, 0
    for i, b in ipairs(d.buttons) do
      widths[i] = math.max(92, f:getWidth(b.label) + 28)
      total = total + widths[i] + (i > 1 and gap or 0)
    end
    local bx = x + w - 20 - total
    for i, b in ipairs(d.buttons) do
      if ui.button("dlgbtn" .. i, b.label, bx, by, widths[i], theme.controlH, { primary = b.primary }) then
        close(d, b.action)
        break
      end
      bx = bx + widths[i] + gap
    end
  else
    local id = "dlginput"
    if d.focusNext then ui.focusText(id, d.value, true) d.focusNext = false end
    local value, _, committed = ui.textbox(id, d.value, x + 20, y + 48 + textH + 10, w - 40, theme.controlH)
    d.value = value
    -- Enter commits and blurs the box; a click elsewhere also commits, but shouldn't submit
    local enterPressed = committed and ui.focus == nil and love.keyboard.isDown("return", "kpenter")
    local okClicked = ui.button("dlgok", d.okLabel or "OK", x + w - 20 - 92, by, 92, theme.controlH, { primary = true })
    local cancelClicked = ui.button("dlgcancel", "Cancel", x + w - 20 - 92 - 8 - 92, by, 92, theme.controlH)
    if okClicked or enterPressed then
      close(d, d.onOk, d.value)
    elseif cancelClicked or (love.keyboard.isDown("escape") and ui.focus == nil) then
      close(d, d.onCancel)
    end
  end
  ui.layer = "base"
end

return dialogs
