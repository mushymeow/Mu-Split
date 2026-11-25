-- Small immediate-mode UI kit.
--
--   ui.begin(dt)  ... widgets ...  ui.finish()
--
-- Every widget takes a unique id and returns its new value; nothing is retained
-- between frames except focus, text-edit state and hover animations.
-- Layers: only the layer named in ui.mouseLayer receives the mouse, so a menu or
-- dialog on top blocks whatever is underneath. Dropdown popups sit above everything.

local theme = require("theme")
local utf8 = require("utf8")

local ui = {
  mx = 0, my = 0,
  down = false, pressed = false, released = false, doubleClick = false,
  rightPressed = false,
  wheel = 0,
  hot = nil, active = nil, focus = nil,
  layer = "base", mouseLayer = "base",
  anim = {}, keys = {}, texts = {},
  clip = {},
  popup = nil, drawingPopup = false,
  edit = nil, blurred = {}, claimedFocus = false,
  tabOrder = {}, tabRequest = nil,
  tooltip = nil, tooltipTimer = 0, tooltipId = nil,
  cursor = "arrow", lastCursor = nil,
  dt = 0, time = 0,
  lastClickTime = 0, lastClickX = 0, lastClickY = 0,
}

---------------------------------------------------------------------------
-- helpers
---------------------------------------------------------------------------
local lg = love.graphics

local function damp(a, b, rate, dt) return a + (b - a) * (1 - math.exp(-rate * dt)) end
ui.damp = damp

function ui.color(c, alphaMul)
  lg.setColor(c[1], c[2], c[3], (c[4] or 1) * (alphaMul or 1))
end

function ui.mix(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t }
end

function ui.rect(mode, x, y, w, h, r)
  r = r or 0
  lg.rectangle(mode, x, y, w, h, r, r, r > 0 and 6 or nil)
end

function ui.inside(x, y, w, h, px, py)
  px, py = px or ui.mx, py or ui.my
  return px >= x and px < x + w and py >= y and py < y + h
end

local function anim(id)
  local a = ui.anim[id]
  if not a then a = { hover = 0, press = 0, focus = 0, check = 0, t = 0 } ui.anim[id] = a end
  a.seen = true
  return a
end
ui.getAnim = anim

local function ctrl() return love.keyboard.isDown("lctrl", "rctrl") end
local function shift() return love.keyboard.isDown("lshift", "rshift") end

---------------------------------------------------------------------------
-- clipping (scroll areas) — mouse outside the clip can't hover
---------------------------------------------------------------------------
function ui.pushClip(x, y, w, h)
  local c = ui.clip[#ui.clip]
  if c then
    local nx, ny = math.max(x, c[1]), math.max(y, c[2])
    local nx2, ny2 = math.min(x + w, c[1] + c[3]), math.min(y + h, c[2] + c[4])
    x, y, w, h = nx, ny, math.max(0, nx2 - nx), math.max(0, ny2 - ny)
  end
  w, h = math.max(0, w), math.max(0, h)
  ui.clip[#ui.clip + 1] = { x, y, w, h }
  lg.setScissor(math.floor(x), math.floor(y), math.ceil(w), math.ceil(h))
end

function ui.popClip()
  ui.clip[#ui.clip] = nil
  local c = ui.clip[#ui.clip]
  if c then lg.setScissor(math.floor(c[1]), math.floor(c[2]), math.ceil(c[3]), math.ceil(c[4])) else lg.setScissor() end
end

-- can the widget at this rect receive the mouse right now?
function ui.hoverable(x, y, w, h)
  if ui.popup and not ui.drawingPopup then return false end
  if not ui.drawingPopup and ui.layer ~= ui.mouseLayer then return false end
  if not ui.inside(x, y, w, h) then return false end
  local c = ui.clip[#ui.clip]
  if c and not ui.inside(c[1], c[2], c[3], c[4]) then return false end
  return true
end

---------------------------------------------------------------------------
-- frame
---------------------------------------------------------------------------
function ui.begin(dt)
  ui.dt, ui.time = dt, ui.time + dt
  ui.mx, ui.my = love.mouse.getPosition()
  ui.hot = nil
  ui.cursor = "arrow"
  ui.claimedFocus = false
  ui.tabOrder = {}
  ui.tooltipCandidate = nil
  for _, a in pairs(ui.anim) do a.seen = false end
end

function ui.finish()
  -- popup (dropdown list) above everything
  if ui.popup then
    ui.drawingPopup = true
    local ok, err = pcall(ui.popup.draw, ui.popup)
    ui.drawingPopup = false
    if not ok then ui.popup = nil error(err) end
    -- click outside closes it
    if ui.popup and ui.pressed and not ui.inside(ui.popup.x, ui.popup.y, ui.popup.w, ui.popup.h) then
      ui.popup = nil
      ui.swallowClick = true
    end
  end

  -- clicking empty space drops keyboard focus (and commits text)
  if ui.pressed and ui.focus and not ui.claimedFocus then ui.setFocus(nil) end

  -- tab moves focus through text boxes in the order they were drawn
  if ui.tabRequest then
    local order, idx = ui.tabOrder, nil
    for i, id in ipairs(order) do if id == ui.tabRequest.from then idx = i end end
    if idx and #order > 0 then
      local nextIdx = ((idx - 1 + ui.tabRequest.dir) % #order) + 1
      ui.setFocus(order[nextIdx])
    end
    ui.tabRequest = nil
  end

  -- tooltip after hovering still for a moment
  if ui.tooltipCandidate and ui.tooltipCandidate.id == ui.tooltipId then
    ui.tooltipTimer = ui.tooltipTimer + ui.dt
  else
    ui.tooltipId = ui.tooltipCandidate and ui.tooltipCandidate.id
    ui.tooltipTimer = 0
  end
  if ui.tooltipCandidate and ui.tooltipTimer > 0.45 then ui.drawTooltip(ui.tooltipCandidate.text) end

  -- fade out animations of widgets that weren't drawn this frame
  for id, a in pairs(ui.anim) do
    if not a.seen then
      a.hover = damp(a.hover, 0, theme.speedHover, ui.dt)
      if a.hover < 0.01 and ui.focus ~= id then ui.anim[id] = nil end
    end
  end

  if ui.cursor ~= ui.lastCursor then
    pcall(function() love.mouse.setCursor(love.mouse.getSystemCursor(ui.cursor)) end)
    ui.lastCursor = ui.cursor
  end

  if ui.released then ui.active = nil end
  ui.pressed, ui.released, ui.doubleClick, ui.rightPressed = false, false, false, false
  ui.wheel = 0
  ui.keys, ui.texts = {}, {}
  ui.swallowClick = false
end

-- forward LÖVE input here --------------------------------------------------
function ui.mousepressed(x, y, button)
  if button == 1 then
    local now = love.timer.getTime()
    ui.doubleClick = (now - ui.lastClickTime) < 0.35 and math.abs(x - ui.lastClickX) < 4 and math.abs(y - ui.lastClickY) < 4
    ui.lastClickTime, ui.lastClickX, ui.lastClickY = now, x, y
    ui.pressed, ui.down = true, true
  elseif button == 2 then
    ui.rightPressed = true
  end
end
function ui.mousereleased(x, y, button)
  if button == 1 then ui.released, ui.down = true, false end   -- ui.active clears at the end of the frame
end
function ui.wheelmoved(_, y) ui.wheel = ui.wheel + y end
function ui.keypressed(key) ui.keys[#ui.keys + 1] = key end
function ui.textinput(t) ui.texts[#ui.texts + 1] = t end

-- true while a widget wants the keyboard (app shortcuts should stay quiet)
function ui.wantsKeyboard() return ui.focus ~= nil end

function ui.setFocus(id)
  if ui.focus == id then return end
  if ui.focus and ui.edit and ui.edit.id == ui.focus then
    ui.blurred[ui.focus] = ui.edit.text   -- commit happens next time that widget draws
  end
  ui.focus = id
  ui.edit = nil
end

local function consumeKey(k)
  for i, key in ipairs(ui.keys) do
    if key == k then table.remove(ui.keys, i) return true end
  end
  return false
end
ui.consumeKey = consumeKey

---------------------------------------------------------------------------
-- basic interaction: returns hovered, clicked
---------------------------------------------------------------------------
function ui.interact(id, x, y, w, h)
  local hov = ui.hoverable(x, y, w, h)
  if hov then ui.hot = id end
  local clicked = false
  if hov and ui.pressed and not ui.swallowClick then ui.active = id end
  if ui.active == id and ui.released and hov then clicked = true end
  return hov, clicked
end

function ui.setTooltip(id, text)
  if text and text ~= "" then ui.tooltipCandidate = { id = id, text = text } end
end

function ui.drawTooltip(text)
  local f = theme.fonts.small
  local W, H = lg.getDimensions()
  local maxW = math.min(320, W - 20)
  local _, lines = f:getWrap(text, maxW - 16)
  local w = 16
  for _, l in ipairs(lines) do w = math.max(w, f:getWidth(l) + 16) end
  local h = #lines * f:getHeight() + 10
  local x = math.min(ui.mx + 12, W - w - 6)
  local y = ui.my + 20
  if y + h > H - 6 then y = ui.my - h - 8 end
  ui.color(theme.shadow) ui.rect("fill", x + 1, y + 2, w, h, theme.radiusSmall)
  ui.color(theme.panelAlt) ui.rect("fill", x, y, w, h, theme.radiusSmall)
  ui.color(theme.border) ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)
  ui.color(theme.text)
  lg.setFont(f)
  lg.printf(text, x + 8, y + 5, w - 16, "left")
end

---------------------------------------------------------------------------
-- label
---------------------------------------------------------------------------
function ui.label(text, x, y, opt)
  opt = opt or {}
  local f = opt.font or theme.fonts.ui
  lg.setFont(f)
  ui.color(opt.color or theme.text)
  if opt.w then
    local ty = opt.h and math.floor(y + (opt.h - f:getHeight()) / 2) or y
    lg.printf(text, math.floor(x), ty, opt.w, opt.align or "left")
  else
    local ty = opt.h and math.floor(y + (opt.h - f:getHeight()) / 2) or y
    lg.print(text, math.floor(x), ty)
  end
end

function ui.ellipsize(font, text, maxW)
  text = tostring(text or "")
  if font:getWidth(text) <= maxW then return text end
  local n = utf8.len(text) or #text
  while n > 0 do
    local cut = text:sub(1, (utf8.offset(text, n + 1) or (#text + 1)) - 1)
    if font:getWidth(cut .. "…") <= maxW then return cut .. "…" end
    n = n - 1
  end
  return "…"
end

---------------------------------------------------------------------------
-- button
---------------------------------------------------------------------------
function ui.button(id, label, x, y, w, h, opt)
  opt = opt or {}
  local disabled = opt.disabled
  local hov, clicked = ui.interact(id, x, y, w, h)
  if disabled then hov, clicked = false, false end
  local a = anim(id)
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
  a.press = damp(a.press, (ui.active == id and hov) and 1 or 0, theme.speedHover * 1.5, ui.dt)
  if hov then ui.cursor = "hand" end
  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end

  local bg = ui.mix(theme.input, theme.inputHover, a.hover)
  bg = ui.mix(bg, theme.press, a.press)
  ui.color(bg, disabled and 0.6 or 1)
  ui.rect("fill", x, y, w, h, theme.radiusSmall)
  local border = opt.primary and theme.accent or ui.mix(theme.borderLight, theme.textFaint, a.hover)
  ui.color(border, disabled and 0.5 or 1)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)

  lg.setFont(opt.font or theme.fonts.ui)
  ui.color(disabled and theme.textFaint or theme.text)
  local f = lg.getFont()
  lg.printf(ui.ellipsize(f, label, w - 10), math.floor(x), math.floor(y + (h - f:getHeight()) / 2), w, "center")
  return clicked
end

---------------------------------------------------------------------------
-- checkbox
---------------------------------------------------------------------------
function ui.checkbox(id, label, checked, x, y, opt)
  opt = opt or {}
  local box = 16
  local f = opt.font or theme.fonts.ui
  local w = box + 8 + (label and f:getWidth(label) or 0)
  local h = math.max(box, f:getHeight())
  local hov, clicked = ui.interact(id, x, y, w, h)
  if opt.disabled then hov, clicked = false, false end
  local a = anim(id)
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
  if clicked then checked = not checked end
  a.check = damp(a.check, checked and 1 or 0, theme.speedHover * 1.4, ui.dt)
  if hov then ui.cursor = "hand" end
  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end

  local bx, by = x, math.floor(y + (h - box) / 2)
  ui.color(ui.mix(theme.input, theme.inputHover, a.hover), opt.disabled and 0.5 or 1)
  ui.rect("fill", bx, by, box, box, 3)
  if a.check > 0.01 then
    ui.color(theme.accent, a.check * (opt.disabled and 0.5 or 1))
    ui.rect("fill", bx, by, box, box, 3)
    lg.setLineWidth(2)
    ui.color({ 1, 1, 1 }, a.check)
    local s = a.check
    lg.line(bx + 4, by + 8.5, bx + 4 + 3 * s, by + 8.5 + 3 * s, bx + 4 + 3 * s + 5 * s, by + 8.5 + 3 * s - 7 * s)
    lg.setLineWidth(1)
  end
  ui.color(theme.borderLight, (1 - a.check) * (opt.disabled and 0.5 or 1))
  ui.rect("line", bx + 0.5, by + 0.5, box - 1, box - 1, 3)

  if label then
    lg.setFont(f)
    ui.color(opt.disabled and theme.textFaint or theme.text)
    lg.print(label, math.floor(x + box + 8), math.floor(y + (h - f:getHeight()) / 2))
  end
  return checked, clicked, w
end

---------------------------------------------------------------------------
-- segmented control (e.g. Real Time | Game Time)
---------------------------------------------------------------------------
function ui.segmented(id, options, selected, x, y, w, h)
  local n = #options
  local segW = w / n
  local a = anim(id)
  local selIdx = 1
  for i, o in ipairs(options) do if o.value == selected then selIdx = i end end
  a.t = a.t == 0 and selIdx or damp(a.t, selIdx, theme.speedOpen, ui.dt)

  ui.color(theme.input) ui.rect("fill", x, y, w, h, theme.radiusSmall)
  ui.color(theme.accentSoft) ui.rect("fill", x + (a.t - 1) * segW + 2, y + 2, segW - 4, h - 4, theme.radiusSmall - 1)
  ui.color(theme.accent) ui.rect("fill", x + (a.t - 1) * segW + 8, y + h - 3, segW - 16, 2, 1)
  ui.color(theme.border) ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)

  local changed = false
  lg.setFont(theme.fonts.ui)
  for i, o in ipairs(options) do
    local sx = x + (i - 1) * segW
    local hov, clicked = ui.interact(id .. ":" .. i, sx, y, segW, h)
    if hov then ui.cursor = "hand" end
    if clicked and o.value ~= selected then selected, changed = o.value, true end
    ui.color(i == selIdx and theme.text or theme.textDim)
    lg.printf(o.label, math.floor(sx), math.floor(y + (h - theme.fonts.ui:getHeight()) / 2), segW, "center")
  end
  return selected, changed
end

---------------------------------------------------------------------------
-- text box
--   returns text, changed, committed
--   committed is true once when the user presses Enter or the box loses focus
---------------------------------------------------------------------------
local function charToByte(s, ci) return (utf8.offset(s, ci + 1) or (#s + 1)) - 1 end
local function ulen(s) return utf8.len(s) or #s end
local function usub(s, i, j) -- character indices, inclusive, 1-based
  local b1 = utf8.offset(s, i) or (#s + 1)
  local b2 = (utf8.offset(s, j + 1) or (#s + 1)) - 1
  return s:sub(b1, b2)
end

local function cursorFromX(font, text, relX)
  local n = ulen(text)
  local best, bestD = 0, math.huge
  for i = 0, n do
    local w = font:getWidth(usub(text, 1, i))
    local d = math.abs(w - relX)
    if d < bestD then best, bestD = i, d end
  end
  return best
end

local function wordLeft(text, c)
  while c > 0 and usub(text, c, c):match("%s") do c = c - 1 end
  while c > 0 and not usub(text, c, c):match("%s") do c = c - 1 end
  return c
end
local function wordRight(text, c)
  local n = ulen(text)
  while c < n and not usub(text, c + 1, c + 1):match("%s") do c = c + 1 end
  while c < n and usub(text, c + 1, c + 1):match("%s") do c = c + 1 end
  return c
end

function ui.textbox(id, text, x, y, w, h, opt)
  opt = opt or {}
  text = tostring(text or "")
  local f = opt.font or theme.fonts.ui
  local committed, changed = false, false
  ui.tabOrder[#ui.tabOrder + 1] = id

  -- a blur from last frame commits the edited text
  if ui.blurred[id] ~= nil then
    local t = ui.blurred[id]
    ui.blurred[id] = nil
    if t ~= text then text, changed = t, true end
    committed = true
  end

  local hov = ui.hoverable(x, y, w, h)
  if hov then ui.hot = id ui.cursor = opt.readonly and "arrow" or "ibeam" end
  local a = anim(id)
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)

  local padX = 8
  if hov and ui.pressed and not opt.readonly and not ui.swallowClick then
    ui.claimedFocus = true
    if ui.focus ~= id then ui.setFocus(id) end
    if not ui.edit then ui.edit = { id = id, text = text, original = text, cursor = 0, anchor = 0, scroll = 0 } end
    local c = cursorFromX(f, ui.edit.text, ui.mx - (x + padX) + ui.edit.scroll)
    if ui.doubleClick then
      ui.edit.anchor, ui.edit.cursor = 0, ulen(ui.edit.text)  -- double click selects all
    else
      ui.edit.cursor = c
      if not shift() then ui.edit.anchor = c end
    end
    ui.active = id
  end

  local focused = ui.focus == id
  if focused and not ui.edit then
    -- focus arrived by Tab or programmatically: select everything
    ui.edit = { id = id, text = text, original = text, cursor = ulen(text), anchor = 0, scroll = 0 }
  end
  if focused then ui.claimedFocus = ui.claimedFocus or (ui.pressed and hov) end
  a.focus = damp(a.focus, focused and 1 or 0, theme.speedOpen, ui.dt)

  local e = focused and ui.edit or nil
  if e then
    -- drag to select
    if ui.active == id and ui.down and not ui.pressed then
      e.cursor = cursorFromX(f, e.text, ui.mx - (x + padX) + e.scroll)
    end

    local function hasSel() return e.cursor ~= e.anchor end
    local function selRange() return math.min(e.cursor, e.anchor), math.max(e.cursor, e.anchor) end
    local function deleteSel()
      local s1, s2 = selRange()
      e.text = usub(e.text, 1, s1) .. usub(e.text, s2 + 1, ulen(e.text))
      e.cursor, e.anchor = s1, s1
    end
    local function insert(str)
      if opt.numeric then str = str:gsub("[^%d]", "") end
      if opt.maxLength and ulen(e.text) - (select(2, selRange()) - select(1, selRange())) + ulen(str) > opt.maxLength then return end
      if hasSel() then deleteSel() end
      e.text = usub(e.text, 1, e.cursor) .. str .. usub(e.text, e.cursor + 1, ulen(e.text))
      e.cursor = e.cursor + ulen(str)
      e.anchor = e.cursor
    end

    for _, t in ipairs(ui.texts) do insert(t) end

    local remaining = {}
    for _, key in ipairs(ui.keys) do
      local n = ulen(e.text)
      local move = function(to)
        e.cursor = math.max(0, math.min(n, to))
        if not shift() then e.anchor = e.cursor end
      end
      if key == "left" then
        if hasSel() and not shift() then local s1 = selRange() e.cursor, e.anchor = s1, s1
        else move(ctrl() and wordLeft(e.text, e.cursor) or e.cursor - 1) end
      elseif key == "right" then
        if hasSel() and not shift() then local _, s2 = selRange() e.cursor, e.anchor = s2, s2
        else move(ctrl() and wordRight(e.text, e.cursor) or e.cursor + 1) end
      elseif key == "home" then move(0)
      elseif key == "end" then move(n)
      elseif key == "backspace" then
        if hasSel() then deleteSel()
        elseif e.cursor > 0 then
          local from = ctrl() and wordLeft(e.text, e.cursor) or e.cursor - 1
          e.text = usub(e.text, 1, from) .. usub(e.text, e.cursor + 1, n)
          e.cursor, e.anchor = from, from
        end
      elseif key == "delete" then
        if hasSel() then deleteSel()
        elseif e.cursor < n then
          local to = ctrl() and wordRight(e.text, e.cursor) or e.cursor + 1
          e.text = usub(e.text, 1, e.cursor) .. usub(e.text, to + 1, n)
        end
      elseif key == "a" and ctrl() then e.anchor, e.cursor = 0, n
      elseif (key == "c" or key == "x") and ctrl() then
        if hasSel() then
          local s1, s2 = selRange()
          love.system.setClipboardText(usub(e.text, s1 + 1, s2))
          if key == "x" then deleteSel() end
        end
      elseif key == "v" and ctrl() then
        insert((love.system.getClipboardText() or ""):gsub("[\r\n]+", " "))
      elseif key == "return" or key == "kpenter" then
        committed = true
        e.original = e.text
        if opt.blurOnEnter ~= false then ui.focus = nil ui.edit = nil end
      elseif key == "escape" then
        e.text = e.original
        ui.focus = nil
        ui.edit = nil
      elseif key == "tab" then
        ui.tabRequest = { from = id, dir = shift() and -1 or 1 }
      else
        remaining[#remaining + 1] = key
      end
    end
    ui.keys = remaining
    if e.text ~= text then text, changed = e.text, true end
    if committed then text = e.text end
  end

  -- draw
  ui.color(ui.mix(theme.input, theme.inputHover, math.max(a.hover * 0.6, a.focus * 0.3)))
  ui.rect("fill", x, y, w, h, theme.radiusSmall)
  ui.color(theme.border)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)
  -- underline grows from the centre on focus (GreenSplit style)
  if a.focus > 0.01 then
    ui.color(opt.error and theme.danger or theme.accent, a.focus)
    local uw = (w - 2) * a.focus
    lg.rectangle("fill", x + (w - uw) / 2, y + h - 2, uw, 2)
  elseif opt.error then
    ui.color(theme.danger)
    lg.rectangle("fill", x + 1, y + h - 2, w - 2, 2)
  end

  ui.pushClip(x + 2, y, w - 4, h)
  lg.setFont(f)
  local shown = e and e.text or text
  local ty = math.floor(y + (h - f:getHeight()) / 2)
  local scroll = 0
  if e then
    local cx = f:getWidth(usub(e.text, 1, e.cursor))
    local inner = w - padX * 2
    if cx - e.scroll > inner then e.scroll = cx - inner end
    if cx - e.scroll < 0 then e.scroll = cx end
    e.scroll = math.max(0, math.min(e.scroll, math.max(0, f:getWidth(e.text) - inner)))
    scroll = e.scroll
  end
  local tx = math.floor(x + padX - scroll)
  if opt.align == "right" and not e then tx = math.floor(x + w - padX - f:getWidth(shown)) end

  if e and e.cursor ~= e.anchor then
    local s1, s2 = math.min(e.cursor, e.anchor), math.max(e.cursor, e.anchor)
    local sx1 = f:getWidth(usub(e.text, 1, s1))
    local sx2 = f:getWidth(usub(e.text, 1, s2))
    ui.color(theme.accent, 0.35)
    lg.rectangle("fill", tx + sx1, ty, sx2 - sx1, f:getHeight())
  end

  if shown == "" and opt.placeholder then
    ui.color(theme.textFaint)
    lg.print(opt.placeholder, math.floor(x + padX), ty)
  else
    ui.color(opt.readonly and theme.textDim or theme.text)
    lg.print(shown, tx, ty)
  end

  if e then
    local blink = (math.floor((love.timer.getTime() - (e.blinkStart or 0)) * 1.8) % 2 == 0) and 1 or 0.15
    ui.color(theme.text, blink)
    local cx = tx + f:getWidth(usub(e.text, 1, e.cursor))
    lg.rectangle("fill", cx, ty + 1, 1, f:getHeight() - 2)
  end
  ui.popClip()

  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end
  return text, changed, committed
end

-- focus a text box programmatically (e.g. to start editing a table cell)
function ui.focusText(id, text, selectAll)
  ui.setFocus(id)
  local n = ulen(text or "")
  ui.edit = { id = id, text = text or "", original = text or "", cursor = n, anchor = selectAll and 0 or n, scroll = 0 }
end

---------------------------------------------------------------------------
-- dropdown
---------------------------------------------------------------------------
function ui.dropdown(id, items, selected, x, y, w, h, opt)
  opt = opt or {}
  local hov, clicked = ui.interact(id, x, y, w, h)
  local a = anim(id)
  local open = ui.popup and ui.popup.id == id
  a.hover = damp(a.hover, (hov or open) and 1 or 0, theme.speedHover, ui.dt)
  if hov then ui.cursor = "hand" end

  local label = "-"
  for i, it in ipairs(items) do
    local v = type(it) == "table" and it.value or it
    if v == selected then label = type(it) == "table" and it.label or tostring(it) end
  end

  ui.color(ui.mix(theme.input, theme.inputHover, a.hover))
  ui.rect("fill", x, y, w, h, theme.radiusSmall)
  ui.color(open and theme.accent or theme.border)
  ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)
  lg.setFont(theme.fonts.ui)
  ui.color(theme.text)
  lg.print(ui.ellipsize(theme.fonts.ui, label, w - 30), math.floor(x + 8), math.floor(y + (h - theme.fonts.ui:getHeight()) / 2))
  -- chevron
  ui.color(theme.textDim)
  local cx, cy = x + w - 14, y + h / 2
  lg.setLineWidth(1.5)
  lg.line(cx - 4, cy - 2, cx, cy + 2, cx + 4, cy - 2)
  lg.setLineWidth(1)

  local changedTo = nil
  if clicked and not open then
    local itemH = 24
    local W, H = lg.getDimensions()
    local ph = math.min(#items * itemH + 8, 320)
    local py = y + h + 4
    if py + ph > H - 6 then py = math.max(6, y - ph - 4) end
    ui.popup = {
      id = id, x = x, y = py, w = math.max(w, 140), h = ph, items = items, selected = selected,
      scroll = 0, open = 0, itemH = itemH,
      draw = function(p)
        p.open = damp(p.open, 1, theme.speedOpen, ui.dt)
        local maxScroll = math.max(0, #p.items * p.itemH + 8 - p.h)
        if ui.inside(p.x, p.y, p.w, p.h) then p.scroll = math.max(0, math.min(maxScroll, p.scroll - ui.wheel * 40)) end
        local oy = (1 - p.open) * -6
        ui.color(theme.shadow, p.open) ui.rect("fill", p.x + 2, p.y + 4 + oy, p.w, p.h, theme.radius)
        ui.color(theme.panel, p.open) ui.rect("fill", p.x, p.y + oy, p.w, p.h, theme.radius)
        ui.color(theme.border, p.open) ui.rect("line", p.x + 0.5, p.y + 0.5 + oy, p.w - 1, p.h - 1, theme.radius)
        ui.pushClip(p.x, p.y + 4 + oy, p.w, p.h - 8)
        lg.setFont(theme.fonts.ui)
        for i, it in ipairs(p.items) do
          local v = type(it) == "table" and it.value or it
          local lbl = type(it) == "table" and it.label or tostring(it)
          local iy = p.y + 4 + (i - 1) * p.itemH - p.scroll + oy
          local ih, ic = ui.interact(id .. ":opt:" .. i, p.x + 4, iy, p.w - 8, p.itemH)
          local ia = anim(id .. ":opt:" .. i)
          ia.hover = damp(ia.hover, ih and 1 or 0, theme.speedHover, ui.dt)
          if ia.hover > 0.01 then ui.color(theme.hover, ia.hover * p.open) ui.rect("fill", p.x + 4, iy, p.w - 8, p.itemH, theme.radiusSmall) end
          if v == p.selected then ui.color(theme.accent, p.open) lg.rectangle("fill", p.x + 6, iy + 6, 2, p.itemH - 12) end
          ui.color(theme.text, p.open)
          lg.print(ui.ellipsize(theme.fonts.ui, lbl, p.w - 28), math.floor(p.x + 14), math.floor(iy + (p.itemH - theme.fonts.ui:getHeight()) / 2))
          if ic then ui.dropResult = { id = id, value = v } ui.popup = nil end
        end
        ui.popClip()
      end,
    }
  end
  -- the popup reports its pick here (it draws after this widget, so it lands next frame)
  if ui.dropResult and ui.dropResult.id == id then
    changedTo = ui.dropResult.value
    ui.dropResult = nil
  end

  if changedTo ~= nil and changedTo ~= selected then return changedTo, true end
  return selected, false
end

---------------------------------------------------------------------------
-- hotkey capture box: click, then press a key (Esc cancels, Backspace clears)
-- returns newValue (string or nil), changed
---------------------------------------------------------------------------
local keymap = require("keymap")

function ui.hotkey(id, value, x, y, w, h)
  local hov, clicked = ui.interact(id, x, y, w, h)
  local a = anim(id)
  local capturing = ui.focus == id
  if clicked and not capturing then
    ui.setFocus(id) capturing = true
  end
  if capturing then ui.claimedFocus = ui.claimedFocus or (ui.pressed and hov) end
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
  a.focus = damp(a.focus, capturing and 1 or 0, theme.speedOpen, ui.dt)
  if hov then ui.cursor = "hand" end

  local changed, newValue = false, value
  if capturing then
    for i, key in ipairs(ui.keys) do
      if key == "escape" then ui.setFocus(nil) break
      elseif key == "backspace" or key == "delete" then newValue, changed = nil, true ui.setFocus(nil) break
      elseif not keymap.isModifier(key) then
        local k = keymap.toDotNet(key, love.keyboard.isDown("lctrl", "rctrl"), love.keyboard.isDown("lshift", "rshift"), love.keyboard.isDown("lalt", "ralt"))
        if k then newValue, changed = k, true ui.setFocus(nil) break end
      end
    end
    ui.keys = {}
  end

  ui.color(ui.mix(theme.input, theme.inputHover, a.hover))
  ui.rect("fill", x, y, w, h, theme.radiusSmall)
  ui.color(theme.border) ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)
  if a.focus > 0.01 then
    ui.color(theme.accent, a.focus)
    local uw = (w - 2) * a.focus
    lg.rectangle("fill", x + (w - uw) / 2, y + h - 2, uw, 2)
  end
  lg.setFont(theme.fonts.ui)
  local text = capturing and "Press a key…" or keymap.display(newValue)
  ui.color(capturing and theme.textDim or (newValue and theme.text or theme.textFaint))
  lg.print(ui.ellipsize(theme.fonts.ui, text, w - 16), math.floor(x + 8), math.floor(y + (h - theme.fonts.ui:getHeight()) / 2))
  return newValue, changed
end

---------------------------------------------------------------------------
-- smooth scroll area
--   local oy = ui.beginScroll(id, x, y, w, h, contentH)  ... draw at y - oy ...  ui.endScroll()
---------------------------------------------------------------------------
local scrolls = {}
ui.scrolls = scrolls

function ui.beginScroll(id, x, y, w, h, contentH)
  local s = scrolls[id]
  if not s then s = { target = 0, pos = 0 } scrolls[id] = s end
  local maxScroll = math.max(0, contentH - h)
  if ui.wheel ~= 0 and ui.hoverable(x, y, w, h) then
    s.target = s.target - ui.wheel * 48
  end
  s.target = math.max(0, math.min(maxScroll, s.target))
  s.pos = damp(s.pos, s.target, theme.speedScroll, ui.dt)
  if math.abs(s.pos - s.target) < 0.3 then s.pos = s.target end
  s.x, s.y, s.w, s.h, s.content = x, y, w, h, contentH
  ui.pushClip(x, y, w, h)
  ui._scrollStack = ui._scrollStack or {}
  ui._scrollStack[#ui._scrollStack + 1] = id
  return math.floor(s.pos + 0.5)
end

function ui.endScroll()
  local id = table.remove(ui._scrollStack)
  local s = scrolls[id]
  ui.popClip()
  -- thin scrollbar
  if s.content > s.h then
    local barH = math.max(24, s.h * s.h / s.content)
    local barY = s.y + (s.h - barH) * (s.pos / (s.content - s.h))
    local hov = ui.hoverable(s.x + s.w - 10, s.y, 10, s.h)
    ui.color(theme.textFaint, hov and 0.9 or 0.5)
    ui.rect("fill", s.x + s.w - 6, barY + 2, 4, barH - 4, 2)
  end
end

-- keep a row visible (for keyboard navigation in tables)
function ui.scrollTo(id, top, bottom)
  local s = scrolls[id]
  if not s or not s.h then return end
  if top < s.target then s.target = top end
  if bottom > s.target + s.h then s.target = bottom - s.h end
end

return ui
