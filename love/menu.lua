-- Right-click context menu with cascading submenus.
--
--   menu.open(items, x, y)
--   item = { label = "Save Splits", action = fn, disabled = bool, checked = bool,
--            submenu = items | function() return items end, hint = "Ctrl+S" }
--        | { separator = true }

local theme = require("theme")
local ui = require("ui")

local menu = { levels = {}, closing = {} }
local lg = love.graphics
local damp = ui.damp

local ITEM_H, SEP_H, PAD = theme.menuItemH, 9, 5

local function resolve(sub) return type(sub) == "function" and sub() or sub end

local function measure(items)
  local f = theme.fonts.ui
  local w, h = 150, PAD * 2
  for _, it in ipairs(items) do
    if it.separator then h = h + SEP_H
    else
      h = h + ITEM_H
      local lw = f:getWidth(it.label or "") + 58 + (it.hint and (theme.fonts.small:getWidth(it.hint) + 16) or 0)
      w = math.max(w, lw)
    end
  end
  return math.min(w, 360), h
end

local function placeLevel(items, x, y, parentW, parentX)
  local W, H = lg.getDimensions()
  local w, h = measure(items)
  if parentW then
    -- submenu: open to the right, flip left if it doesn't fit
    if x + w > W - 4 then x = parentX - w + 4 end
  else
    if x + w > W - 4 then x = W - w - 4 end
  end
  x = math.max(4, x)
  local maxH = H - 8
  local scrollable = h > maxH
  if scrollable then h = maxH end
  if y + h > H - 4 then y = H - h - 4 end
  y = math.max(4, y)
  return { items = items, x = x, y = y, w = w, h = h, open = 0, hover = nil, hoverTime = 0,
           scroll = 0, scrollable = scrollable, anim = {} }
end

function menu.open(items, x, y)
  menu.levels = { placeLevel(items, x, y) }
  menu.justOpened = true
end

function menu.isOpen() return #menu.levels > 0 end

function menu.close()
  for _, l in ipairs(menu.levels) do menu.closing[#menu.closing + 1] = l end
  menu.levels = {}
end

local function inAnyLevel(px, py)
  for _, l in ipairs(menu.levels) do
    if ui.inside(l.x, l.y, l.w, l.h, px, py) then return true end
  end
  return false
end

function menu.keypressed(key)
  if key == "escape" and #menu.levels > 0 then
    menu.levels[#menu.levels] = nil
    return true
  end
  return false
end

local function drawLevel(l, li, dt, alive)
  local f = theme.fonts.ui
  l.open = damp(l.open, alive and 1 or 0, theme.speedOpen, dt)
  local a = l.open
  if a < 0.01 and not alive then return false end
  local oy = (1 - a) * -5

  -- panel
  ui.color(theme.shadow, a * 0.9) ui.rect("fill", l.x + 2, l.y + 5 + oy, l.w, l.h, theme.radius)
  ui.color(theme.panel, a) ui.rect("fill", l.x, l.y + oy, l.w, l.h, theme.radius)
  ui.color(theme.border, a) ui.rect("line", l.x + 0.5, l.y + 0.5 + oy, l.w - 1, l.h - 1, theme.radius)

  if alive and l.scrollable and ui.inside(l.x, l.y, l.w, l.h) then
    local _, full = measure(l.items)
    l.scroll = math.max(0, math.min(full - l.h, l.scroll - ui.wheel * 40))
  end

  ui.pushClip(l.x, l.y + oy + 1, l.w, l.h - 2)
  local y = l.y + PAD + oy - l.scroll
  local hoveredIdx = nil
  for i, it in ipairs(l.items) do
    if it.separator then
      ui.color(theme.border, a)
      lg.rectangle("fill", l.x + 10, math.floor(y + SEP_H / 2), l.w - 20, 1)
      y = y + SEP_H
    else
      local id = "menu" .. li .. ":" .. i
      local hov, clicked = false, false
      if alive then hov, clicked = ui.interact(id, l.x + 4, y, l.w - 8, ITEM_H) end
      if it.disabled then clicked = false end
      if hov then hoveredIdx = i end
      local open = menu.levels[li + 1] and l.hover == i
      local ha = l.anim[i] or 0
      ha = damp(ha, ((hov and not it.disabled) or open) and 1 or 0, theme.speedHover, dt)
      l.anim[i] = ha
      if ha > 0.01 then
        ui.color(theme.hover, ha * a)
        ui.rect("fill", l.x + 4, y, l.w - 8, ITEM_H, theme.radiusSmall)
      end

      local ty = math.floor(y + (ITEM_H - f:getHeight()) / 2)
      if it.checked then
        ui.color(theme.accent, a)
        lg.setLineWidth(1.8)
        local cx, cy = l.x + 15, y + ITEM_H / 2
        lg.line(cx - 4, cy, cx - 1, cy + 3, cx + 4, cy - 3)
        lg.setLineWidth(1)
      end
      lg.setFont(f)
      ui.color(it.disabled and theme.textFaint or theme.text, a)
      lg.print(ui.ellipsize(f, it.label or "", l.w - 70), math.floor(l.x + 28), ty)

      if it.hint then
        lg.setFont(theme.fonts.small)
        ui.color(theme.textFaint, a)
        lg.printf(it.hint, l.x, math.floor(y + (ITEM_H - theme.fonts.small:getHeight()) / 2), l.w - (it.submenu and 28 or 14), "right")
      end
      if it.submenu then
        ui.color(it.disabled and theme.textFaint or theme.textDim, a)
        local cx, cy = l.x + l.w - 16, y + ITEM_H / 2
        lg.setLineWidth(1.5)
        lg.line(cx - 2, cy - 4, cx + 2, cy, cx - 2, cy + 4)
        lg.setLineWidth(1)
      end

      if alive and clicked then
        if it.submenu then
          l.hover, l.hoverTime = i, 1   -- open right away
        elseif it.action then
          menu.close()
          it.action()
          ui.popClip()
          return true
        end
      end
      it._y = y
      y = y + ITEM_H
    end
  end
  ui.popClip()

  -- hovering an item for a moment opens its submenu (or closes a sibling's)
  if alive and hoveredIdx then
    if l.hover ~= hoveredIdx then l.hover, l.hoverTime = hoveredIdx, 0 end
    l.hoverTime = l.hoverTime + dt
  end
  if alive and l.hover and l.hoverTime > 0.12 then
    local it = l.items[l.hover]
    local child = menu.levels[li + 1]
    if it and it.submenu and not it.disabled then
      if not child or child.parentIndex ~= l.hover then
        for k = #menu.levels, li + 1, -1 do menu.closing[#menu.closing + 1] = menu.levels[k] menu.levels[k] = nil end
        local sub = resolve(it.submenu) or {}
        if #sub == 0 then sub = { { label = "(empty)", disabled = true } } end
        local nl = placeLevel(sub, l.x + l.w - 4, (it._y or l.y) - PAD, l.w, l.x)
        nl.parentIndex = l.hover
        menu.levels[li + 1] = nl
      end
    elseif child and hoveredIdx then
      for k = #menu.levels, li + 1, -1 do menu.closing[#menu.closing + 1] = menu.levels[k] menu.levels[k] = nil end
    end
  end
  return true
end

function menu.draw(dt)
  ui.layer = "menu"
  -- click outside every level closes the menu
  if menu.justOpened then
    menu.justOpened = false
  elseif #menu.levels > 0 and (ui.pressed or ui.rightPressed) and not inAnyLevel(ui.mx, ui.my) then
    menu.close()
    ui.swallowClick = true
  end

  for i = #menu.closing, 1, -1 do
    if not drawLevel(menu.closing[i], 0, dt, false) then table.remove(menu.closing, i) end
  end
  local li = 1
  while menu.levels[li] do
    local l = menu.levels[li]
    drawLevel(l, li, dt, true)
    if menu.levels[li] ~= l then break end   -- closed by an action
    li = li + 1
  end
  ui.layer = "base"
end

return menu
