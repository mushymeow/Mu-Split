-- No title bar ("Hide Title Bar" in the right-click menu): Mu Split moves, resizes
-- and closes itself.
--   * drag anywhere on the timer (or a window's header) to move it
--   * drag the grip in the bottom-right corner to resize
--   * minimise / close buttons fade in at the top-right while the mouse is over it

local theme = require("theme")
local ui = require("ui")
local windows = require("windows")

local F = { borderless = false, drag = nil, hover = 0 }
local lg = love.graphics
local GRIP = 16
local BTN = 30

function F.set(on)
  F.borderless = on and true or false
  windows.setBordered(not F.borderless)
end

local function buttonsRect(W)
  return W - BTN * 2 - 6, 4, BTN * 2 + 2, BTN - 6
end

-- main.lua: a left click that nothing else wanted. true = we took it
function F.mousepressed(x, y, button, onTimer)
  if not F.borderless or button ~= 1 then return false end
  local W, H = lg.getDimensions()
  local bx, by, bw, bh = buttonsRect(W)
  if onTimer and ui.inside(bx, by, bw, bh, x, y) then return false end   -- the buttons handle it
  if x >= W - GRIP and y >= H - GRIP then
    local w, h = love.window.getMode()
    local wx, wy = love.window.getPosition()
    F.drag = { kind = "resize", sx = wx + x, sy = wy + y, w = w, h = h }
    return true
  end
  local header = windows.isOpen() and y < 40 and x < W - 40
  if onTimer or header then
    F.drag = { kind = "move", ox = x, oy = y }
    return true
  end
  return false
end

function F.mousereleased() F.drag = nil end

function F.update()
  local d = F.drag
  if not d then return end
  if not love.mouse.isDown(1) then F.drag = nil return end
  local mx, my = love.mouse.getPosition()
  local wx, wy, display = love.window.getPosition()
  if d.kind == "move" then
    if mx ~= d.ox or my ~= d.oy then love.window.setPosition(wx + mx - d.ox, wy + my - d.oy, display) end
  else
    -- the window doesn't move while resizing, so its position + mouse = screen position
    windows.resizeWindow(d.w + (wx + mx - d.sx), d.h + (wy + my - d.sy))
  end
end

-- drawn on top of the timer view
function F.draw(dt)
  if not F.borderless then return end
  local W, H = lg.getDimensions()
  local focused = love.window.hasMouseFocus and love.window.hasMouseFocus()
  F.hover = ui.damp(F.hover, (focused or F.drag) and 1 or 0, 10, dt)
  if F.hover < 0.02 then return end
  local a = F.hover

  -- resize grip: three short diagonal lines
  ui.color(theme.textDim, 0.55 * a)
  lg.setLineWidth(1)
  for i = 1, 3 do
    local o = i * 4
    lg.line(W - o - 2, H - 2, W - 2, H - o - 2)
  end

  -- minimise / close
  local bx, by = buttonsRect(W)
  local items = {
    { id = "frame:min", glyph = "min", action = function() love.window.minimize() end },
    { id = "frame:close", glyph = "close", action = function() love.event.quit() end },
  }
  for i, it in ipairs(items) do
    local x = bx + (i - 1) * (BTN + 2)
    local hov, clicked = ui.interact(it.id, x, by, BTN, BTN - 6)
    local an = ui.getAnim(it.id)
    an.hover = ui.damp(an.hover, hov and 1 or 0, theme.speedHover, dt)
    if hov then ui.cursor = "hand" end
    local bg = it.glyph == "close" and theme.danger or theme.hover
    ui.color(theme.panel, 0.55 * a) ui.rect("fill", x, by, BTN, BTN - 6, theme.radiusSmall)
    if an.hover > 0.01 then ui.color(bg, 0.9 * an.hover * a) ui.rect("fill", x, by, BTN, BTN - 6, theme.radiusSmall) end
    ui.color(theme.text, a)
    lg.setLineWidth(1.4)
    local cx, cy = x + BTN / 2, by + (BTN - 6) / 2
    if it.glyph == "min" then lg.line(cx - 5, cy, cx + 5, cy)
    else lg.line(cx - 4, cy - 4, cx + 4, cy + 4) lg.line(cx + 4, cy - 4, cx - 4, cy + 4) end
    lg.setLineWidth(1)
    if clicked then it.action() end
  end
end

return F
