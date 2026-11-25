-- Extra widgets for the Customise window, on top of ui.lua:
--   W.slider, W.switch, W.colorButton (+ HSV picker popup), W.tabs, W.card, W.section
-- Same rules as ui.lua: immediate mode, unique ids, return (value, changed).

local theme = require("theme")
local ui = require("ui")

local W = {}
local lg = love.graphics
local damp = ui.damp
local anim = ui.getAnim

local function clamp(v, a, b) return v < a and a or (v > b and b or v) end
W.clamp = clamp

---------------------------------------------------------------------------
-- colour maths
---------------------------------------------------------------------------
function W.hsvToRgb(h, s, v)
  h = (h % 1) * 6
  local i = math.floor(h)
  local f = h - i
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v else return v, p, q end
end

function W.rgbToHsv(r, g, b)
  local mx, mn = math.max(r, g, b), math.min(r, g, b)
  local d = mx - mn
  local h = 0
  if d > 0 then
    if mx == r then h = ((g - b) / d) % 6 elseif mx == g then h = (b - r) / d + 2 else h = (r - g) / d + 4 end
    h = h / 6
  end
  return h, mx > 0 and d / mx or 0, mx
end

---------------------------------------------------------------------------
-- section title with a thin accent line
---------------------------------------------------------------------------
function W.section(text, x, y, w)
  ui.label(text:upper(), x, y, { font = theme.fonts.label, color = theme.textDim })
  local tw = theme.fonts.label:getWidth(text:upper())
  ui.color(theme.border) lg.rectangle("fill", x + tw + 10, y + 7, math.max(0, w - tw - 10), 1)
  return y + 22
end

---------------------------------------------------------------------------
-- slider: value, changed
--   opt: step, format(v) -> string, label (drawn left), labelW
---------------------------------------------------------------------------
function W.slider(id, value, min, max, x, y, w, opt)
  opt = opt or {}
  local h = 26
  local labelW = opt.label and (opt.labelW or 150) or 0
  if opt.label then ui.label(opt.label, x, y, { h = h, color = theme.text }) end
  local valueW = 46
  local tx, tw = x + labelW, w - labelW - valueW - 8
  local hov = ui.interact(id, tx - 6, y, tw + 12, h)
  local a = anim(id)
  local dragging = ui.active == id and ui.down
  a.hover = damp(a.hover, (hov or dragging) and 1 or 0, theme.speedHover, ui.dt)
  if hov or dragging then ui.cursor = "hand" end
  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end

  local changed = false
  if dragging then
    local t = clamp((ui.mx - tx) / tw, 0, 1)
    local v = min + (max - min) * t
    if opt.step then v = math.floor(v / opt.step + 0.5) * opt.step end
    v = clamp(v, min, max)
    if v ~= value then value, changed = v, true end
  end
  local t = (max > min) and clamp((value - min) / (max - min), 0, 1) or 0
  a.t = (a.t == 0 and t) or damp(a.t, t, 30, ui.dt)
  local cy = y + h / 2
  ui.color(theme.input) ui.rect("fill", tx, cy - 2, tw, 4, 2)
  -- filled part: accent → accent2
  local fw = tw * a.t
  if fw > 1 then
    ui.color(theme.accent) ui.rect("fill", tx, cy - 2, fw, 4, 2)
    ui.color(theme.accent2, 0.6) ui.rect("fill", tx + fw * 0.5, cy - 2, fw * 0.5, 4, 2)
  end
  local kx = tx + fw
  local kr = 6 + 2 * a.hover
  if a.hover > 0.01 then ui.color(theme.accent, 0.18 * a.hover) lg.circle("fill", kx, cy, kr + 6) end
  ui.color(theme.text) lg.circle("fill", kx, cy, kr)
  ui.color(theme.accent) lg.circle("fill", kx, cy, kr - 3)

  local txt = opt.format and opt.format(value) or (opt.step and opt.step >= 1 and tostring(math.floor(value + 0.5))
    or string.format("%.2f", value))
  ui.label(txt, x + w - valueW, y, { h = h, w = valueW, align = "right", color = theme.textDim })
  return value, changed
end

---------------------------------------------------------------------------
-- switch (animated toggle): on, changed
---------------------------------------------------------------------------
function W.switch(id, on, x, y, opt)
  opt = opt or {}
  local f = theme.fonts.ui
  local sw, sh = 34, 18
  local labelW = opt.label and (opt.labelW or f:getWidth(opt.label) + 12) or 0
  local w = labelW + sw
  local h = 26
  local hov, clicked = ui.interact(id, x, y, opt.w or w, h)
  if opt.disabled then hov, clicked = false, false end
  local a = anim(id)
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
  if clicked then on = not on end
  a.check = damp(a.check, on and 1 or 0, theme.speedHover, ui.dt)
  if hov then ui.cursor = "hand" end
  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end

  if opt.label then ui.label(opt.label, x, y, { h = h, color = opt.disabled and theme.textFaint or theme.text }) end
  local bx = opt.w and (x + opt.w - sw) or (x + labelW)
  local by = y + (h - sh) / 2
  local track = ui.mix(ui.mix(theme.input, theme.inputHover, a.hover), theme.accent, a.check)
  ui.color(track, opt.disabled and 0.5 or 1) ui.rect("fill", bx, by, sw, sh, sh / 2)
  ui.color(theme.borderLight, (1 - a.check) * 0.8) ui.rect("line", bx + 0.5, by + 0.5, sw - 1, sh - 1, sh / 2)
  local kx = bx + sh / 2 + (sw - sh) * a.check
  ui.color({ 0, 0, 0 }, 0.25) lg.circle("fill", kx, by + sh / 2 + 1, sh / 2 - 2)
  ui.color({ 1, 1, 1 }, opt.disabled and 0.6 or 1) lg.circle("fill", kx, by + sh / 2, sh / 2 - 3 + a.hover * 0.6)
  return on, clicked
end

---------------------------------------------------------------------------
-- vertical tabs with a sliding indicator: selected, changed
--   items = { { value =, label =, icon = "glyph" } }
---------------------------------------------------------------------------
function W.tabs(id, items, selected, x, y, w, itemH)
  local a = anim(id)
  local selIdx = 1
  for i, it in ipairs(items) do if it.value == selected then selIdx = i end end
  a.t = (a.t == 0 and selIdx) or damp(a.t, selIdx, theme.speedOpen, ui.dt)

  local iy = y + (a.t - 1) * itemH
  ui.color(theme.accentSoft) ui.rect("fill", x, iy + 2, w, itemH - 4, theme.radiusSmall + 2)
  ui.color(theme.accent) ui.rect("fill", x, iy + 8, 3, itemH - 16, 1.5)

  local changed = false
  for i, it in ipairs(items) do
    local ty = y + (i - 1) * itemH
    local hov, clicked = ui.interact(id .. ":" .. i, x, ty, w, itemH)
    local ia = anim(id .. ":" .. i)
    ia.hover = damp(ia.hover, hov and 1 or 0, theme.speedHover, ui.dt)
    if hov then ui.cursor = "hand" end
    if ia.hover > 0.01 and i ~= selIdx then ui.color(theme.hover, ia.hover * 0.7) ui.rect("fill", x, ty + 2, w, itemH - 4, theme.radiusSmall + 2) end
    if clicked and it.value ~= selected then selected, changed = it.value, true end
    local f = i == selIdx and theme.fonts.uiBold or theme.fonts.ui
    ui.label(it.label, x + 16 + ia.hover * 2, ty, { h = itemH, font = f, color = i == selIdx and theme.text or theme.textDim })
  end
  return selected, changed
end

---------------------------------------------------------------------------
-- card: a clickable panel that lifts on hover. Returns hovered, clicked, anim
-- (draw your content after it, offset by -anim.hover * 2 for the lift)
---------------------------------------------------------------------------
function W.card(id, x, y, w, h, selected)
  local hov, clicked = ui.interact(id, x, y, w, h)
  local a = anim(id)
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
  a.check = damp(a.check, selected and 1 or 0, theme.speedHover, ui.dt)
  if hov then ui.cursor = "hand" end
  local lift = a.hover * 3
  local r = theme.radius + 2
  ui.color(theme.shadow, 0.5 + a.hover * 0.5) ui.rect("fill", x + 1, y + 3 + lift * 0.3, w, h, r)
  ui.color(theme.panelAlt) ui.rect("fill", x, y - lift, w, h, r)
  if a.check > 0.01 then
    lg.setLineWidth(2)
    ui.color(theme.accent, a.check) ui.rect("line", x - 1, y - lift - 1, w + 2, h + 2, r + 1)
    lg.setLineWidth(1)
  else
    ui.color(ui.mix(theme.border, theme.borderLight, a.hover)) ui.rect("line", x + 0.5, y - lift + 0.5, w - 1, h - 1, r)
  end
  return hov, clicked, a, lift
end

---------------------------------------------------------------------------
-- colour button + HSV picker popup: hexString, changed
---------------------------------------------------------------------------
local SWATCHES = {
  "#ffffff", "#c8c8d0", "#7a7a86", "#2a2a32", "#121215", "#000000",
  "#ff4d6d", "#ff7a45", "#ffc83d", "#b5e655", "#2ed573", "#22d3ee",
  "#5b8cff", "#8f6bff", "#b26bff", "#d65db1", "#ff6fa8", "#ff2bd6",
}

local hueMesh, svCache
local function hueBar()
  if hueMesh then return hueMesh end
  local verts = {}
  for i = 0, 6 do
    local r, g, b = W.hsvToRgb(i / 6, 1, 1)
    verts[#verts + 1] = { 0, i / 6, 0, 0, r, g, b, 1 }
    verts[#verts + 1] = { 1, i / 6, 0, 0, r, g, b, 1 }
  end
  hueMesh = lg.newMesh(verts, "strip", "static")
  return hueMesh
end

local function drawSV(x, y, w, h, hue)
  local r, g, b = W.hsvToRgb(hue, 1, 1)
  if not svCache then
    svCache = {
      horiz = lg.newMesh({ { 0, 0, 0, 0, 1, 1, 1, 1 }, { 1, 0, 0, 0, 1, 1, 1, 1 }, { 1, 1, 0, 0, 1, 1, 1, 1 }, { 0, 1, 0, 0, 1, 1, 1, 1 } }, "fan", "dynamic"),
      vert = lg.newMesh({ { 0, 0, 0, 0, 0, 0, 0, 0 }, { 1, 0, 0, 0, 0, 0, 0, 0 }, { 1, 1, 0, 0, 0, 0, 0, 1 }, { 0, 1, 0, 0, 0, 0, 0, 1 } }, "fan", "static"),
    }
  end
  svCache.horiz:setVertexAttribute(2, 3, r, g, b, 1)
  svCache.horiz:setVertexAttribute(3, 3, r, g, b, 1)
  lg.setColor(1, 1, 1, 1)
  lg.draw(svCache.horiz, x, y, 0, w, h)
  lg.draw(svCache.vert, x, y, 0, w, h)
end

function W.colorButton(id, value, x, y, w, h, opt)
  opt = opt or {}
  local hov, clicked = ui.interact(id, x, y, w, h)
  local a = anim(id)
  local open = ui.popup and ui.popup.id == id
  a.hover = damp(a.hover, (hov or open) and 1 or 0, theme.speedHover, ui.dt)
  if hov then ui.cursor = "hand" end
  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end

  local c = theme.hex(value)
  ui.color(ui.mix(theme.input, theme.inputHover, a.hover)) ui.rect("fill", x, y, w, h, theme.radiusSmall)
  ui.color(open and theme.accent or theme.border) ui.rect("line", x + 0.5, y + 0.5, w - 1, h - 1, theme.radiusSmall)
  local sw = h - 8
  ui.color(c) ui.rect("fill", x + 4, y + 4, sw, sw, math.max(2, theme.radiusSmall - 1))
  ui.color({ 1, 1, 1 }, 0.25) ui.rect("line", x + 4.5, y + 4.5, sw - 1, sw - 1, math.max(2, theme.radiusSmall - 1))
  if w > h + 20 then
    ui.label(value:upper(), x + sw + 12, y, { h = h, font = theme.fonts.small, color = theme.textDim })
  end

  if clicked and not open then
    local pw, ph = 236, 292
    local WW, HH = lg.getDimensions()
    local px = math.max(6, math.min(WW - pw - 6, x))
    local py = y + h + 6
    if py + ph > HH - 6 then py = math.max(6, y - ph - 6) end
    local hh, ss, vv = W.rgbToHsv(c[1], c[2], c[3])
    ui.popup = {
      id = id, x = px, y = py, w = pw, h = ph, open = 0, h_ = hh, s_ = ss, v_ = vv, value = value,
      draw = function(p)
        p.open = damp(p.open, 1, theme.speedOpen, ui.dt)
        local oy = (1 - p.open) * -8
        local X, Y = p.x, p.y + oy
        ui.color(theme.shadow, p.open) ui.rect("fill", X + 2, Y + 5, p.w, p.h, theme.radius + 2)
        ui.color(theme.panel, p.open) ui.rect("fill", X, Y, p.w, p.h, theme.radius + 2)
        ui.color(theme.border, p.open) ui.rect("line", X + 0.5, Y + 0.5, p.w - 1, p.h - 1, theme.radius + 2)

        local pad = 12
        local svx, svy, svw, svh = X + pad, Y + pad, p.w - pad * 3 - 14, 150
        local hx = svx + svw + pad
        drawSV(svx, svy, svw, svh, p.h_)
        lg.setColor(1, 1, 1, 1)
        lg.draw(hueBar(), hx, svy, 0, 14, svh)

        local svHov = ui.interact(id .. ":sv", svx, svy, svw, svh)
        local hueHov = ui.interact(id .. ":hue", hx - 2, svy, 18, svh)
        if svHov or hueHov then ui.cursor = "crosshair" end
        local changed = false
        if ui.active == id .. ":sv" and ui.down then
          p.s_ = clamp((ui.mx - svx) / svw, 0, 1)
          p.v_ = 1 - clamp((ui.my - svy) / svh, 0, 1)
          changed = true
        end
        if ui.active == id .. ":hue" and ui.down then
          p.h_ = clamp((ui.my - svy) / svh, 0, 0.9999)
          changed = true
        end
        -- markers
        local mx, my = svx + p.s_ * svw, svy + (1 - p.v_) * svh
        lg.setLineWidth(2)
        lg.setColor(0, 0, 0, 0.6) lg.circle("line", mx, my, 7)
        lg.setColor(1, 1, 1, 1) lg.circle("line", mx, my, 6)
        local hy = svy + p.h_ * svh
        lg.setColor(1, 1, 1, 1) lg.rectangle("line", hx - 2, hy - 3, 18, 6, 2)
        lg.setLineWidth(1)

        -- swatches
        local sy = svy + svh + 12
        local ssz, gap = 28, 6
        local cols = 6
        for i, sh in ipairs(SWATCHES) do
          local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
          local sx = X + pad + col * (ssz + gap)
          local syy = sy + row * (ssz * 0.62 + gap)
          local shov, sclick = ui.interact(id .. ":sw" .. i, sx, syy, ssz, ssz * 0.62)
          if shov then ui.cursor = "hand" end
          ui.color(theme.hex(sh), p.open) ui.rect("fill", sx, syy - (shov and 1 or 0), ssz, ssz * 0.62, 4)
          if shov then ui.color(theme.text) ui.rect("line", sx - 0.5, syy - 1.5, ssz + 1, ssz * 0.62 + 1, 4) end
          if sclick then
            local sc = theme.hex(sh)
            p.h_, p.s_, p.v_ = W.rgbToHsv(sc[1], sc[2], sc[3])
            changed = true
          end
        end

        local r, g, b = W.hsvToRgb(p.h_, p.s_, p.v_)
        if changed then
          p.value = theme.toHex({ r, g, b })
          ui.colorResult = { id = id, value = p.value }
        end
        -- preview + hex + copy/paste
        local by = Y + p.h - 34
        ui.color({ r, g, b }) ui.rect("fill", X + pad, by, 40, 24, 4)
        ui.label(p.value:upper(), X + pad + 50, by, { h = 24, font = theme.fonts.uiBold, color = theme.text })
        local bw = 46
        if ui.button(id .. ":copy", "Copy", X + p.w - pad - bw * 2 - 6, by, bw, 24, { font = theme.fonts.small }) then
          pcall(love.system.setClipboardText, p.value)
        end
        if ui.button(id .. ":paste", "Paste", X + p.w - pad - bw, by, bw, 24, { font = theme.fonts.small }) then
          local txt = (love.system.getClipboardText() or ""):match("#?%x%x%x%x%x%x")
          if txt then
            local pc = theme.hex(txt)
            p.h_, p.s_, p.v_ = W.rgbToHsv(pc[1], pc[2], pc[3])
            p.value = theme.toHex(pc)
            ui.colorResult = { id = id, value = p.value }
          end
        end
      end,
    }
  end

  if ui.colorResult and ui.colorResult.id == id then
    local v = ui.colorResult.value
    ui.colorResult = nil
    if v ~= value then return v, true end
  end
  return value, false
end

return W
