-- The on-screen timer and the settings menu, built from UMG widgets in Lua.
--
-- Layout of the timer (top to bottom, inside a rounded translucent box with an accent
-- bar down its left edge):
--   IGT   0:12.345        main timer   (dim label, bright tabular digits)
--   SPLIT 0:01.23         second row   (RTA, segment timer, or hidden)
--   Reach the Prison  +1.2  0:12.34    split ticker (one split, slides + pops on a split)
--   status / PB / attempts / checkpoint lines
--
-- UE4SS 3.0.1 on this game hands struct arguments to UFunctions as zeros, so nothing
-- here passes a struct to a function:
--   * layout, brushes and colours are written into widget properties before the
--     widget is shown (Slate is built from them);
--   * text colour at run time: write ColorAndOpacity, then SetOpacity(a), which
--     re-sends the whole colour;
--   * movement/scale at run time: write RenderTransform, then SetRenderTransformAngle(0),
--     which re-sends the whole transform;
--   * fading: SetRenderOpacity(a) (a plain number).

local H = {
  widget = nil, el = {}, menu = {}, menuLines = 16, cache = {},
  colors = {}, texts = {},            -- remembered so a rebuild comes back the same
  ticker = { id = nil, front = 1 },   -- the split currently shown
  liveColors = true, wantRebuild = false,
}

local COLLAPSED, HIT_TEST_INVISIBLE = 1, 3
local H_FILL, H_LEFT, H_CENTER, H_RIGHT = 0, 1, 2, 3
local V_FILL, V_CENTER = 0, 2
local DRAW_ROUNDED_BOX, FIXED_RADIUS = 4, 1

H.PALETTE = {
  { "White", { 1, 1, 1 } }, { "Light grey", { 0.78, 0.78, 0.8 } }, { "Grey", { 0.5, 0.5, 0.53 } },
  { "Black", { 0.02, 0.02, 0.03 } }, { "Ink", { 10 / 255, 10 / 255, 14 / 255 } },
  { "Yellow", { 1, 0.9, 0.3 } }, { "Gold", { 1, 0.78, 0.22 } }, { "Orange", { 1, 0.6, 0.25 } },
  { "Red", { 0.95, 0.3, 0.33 } }, { "Pink", { 1, 0.5, 0.78 } }, { "Lavender", { 0.78, 0.64, 1 } },
  { "Purple", { 0.7, 0.5, 1 } }, { "Blue", { 0.38, 0.58, 1 } }, { "Cyan", { 0.4, 0.88, 1 } },
  { "Green", { 0.35, 0.92, 0.5 } }, { "Lime", { 0.7, 1, 0.35 } },
}
local byName = {}
for _, c in ipairs(H.PALETTE) do byName[c[1]] = c[2] end
function H.color(name) return byName[name] or byName.White end
function H.colorNames()
  local t = {}
  for _, c in ipairs(H.PALETTE) do t[#t + 1] = c[1] end
  return t
end

local CORNERS = {
  ["top-left"] = { 0, 0 }, ["top"] = { 0.5, 0 }, ["top-right"] = { 1, 0 },
  ["left"] = { 0, 0.5 }, ["center"] = { 0.5, 0.5 }, ["right"] = { 1, 0.5 },
  ["bottom-left"] = { 0, 1 }, ["bottom"] = { 0.5, 1 }, ["bottom-right"] = { 1, 1 },
}
H.CORNER_ORDER = { "top-left", "top", "top-right", "left", "center", "right", "bottom-left", "bottom", "bottom-right" }

---------------------------------------------------------------------------
-- small helpers
---------------------------------------------------------------------------
local function class(path)
  local c = StaticFindObject(path)
  if not c or not c:IsValid() then error("missing class " .. path) end
  return c
end
local function new(path, outer) return StaticConstructObject(class(path), outer) end
local function put(fn) return pcall(fn) end

local function lin(c) return c ^ 2.2 end   -- UMG colours are linear, settings are sRGB
local function writeLinear(dst, rgb, a)
  dst.R, dst.G, dst.B, dst.A = lin(rgb[1]), lin(rgb[2]), lin(rgb[3]), a or 1
end
local function writeMargin(dst, l, t, r, b) dst.Left, dst.Top, dst.Right, dst.Bottom = l, t, r, b end
local function scaleRgb(rgb, f) return { rgb[1] * f, rgb[2] * f, rgb[3] * f } end
local function mix(a, b, t) return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t } end
local function easeOut(t) t = math.max(0, math.min(1, t)) return 1 - (1 - t) ^ 3 end   -- ease-out cubic
local function colorKey(rgb) return string.format("%.3f,%.3f,%.3f", rgb[1], rgb[2], rgb[3]) end

local function isValid(o)
  if o == nil then return false end
  local ok, r = pcall(function() return o:IsValid() end)
  return ok and r == true
end

-- text colour at run time (see the top of the file)
local function paint(t, rgb)
  local ok = pcall(function()
    writeLinear(t.ColorAndOpacity.SpecifiedColor, rgb, 1)
    t.ColorAndOpacity.ColorUseRule = 0
    t:SetOpacity(1)
  end)
  if not ok then H.liveColors = false end
  return ok
end

-- move / scale at run time
local function transform(w, y, s)
  pcall(function()
    local rt = w.RenderTransform
    rt.Translation.X, rt.Translation.Y = 0, y
    rt.Scale.X, rt.Scale.Y = s, s
    w:SetRenderTransformAngle(0)
  end)
end
local function fade(w, a) pcall(function() w:SetRenderOpacity(a) end) end

---------------------------------------------------------------------------
-- building blocks
---------------------------------------------------------------------------
local monoFont = nil   -- RobotoMono if this build ships it (otherwise Roboto: its digits are tabular)
local function findMono()
  if monoFont ~= nil then return monoFont or nil end
  monoFont = false
  for _, p in ipairs({ "/Engine/EngineFonts/RobotoMono.RobotoMono", "/Engine/EngineFonts/DroidSansMono.DroidSansMono" }) do
    local f = StaticFindObject(p)
    if f and isValid(f) then monoFont = f break end
  end
  print(string.format("[MuSplitIGT] digit font: %s\n",
    monoFont and monoFont:GetFullName() or "Roboto (tabular digits; no monospace font in this build)"))
  return monoFont or nil
end

-- o: size, key, rgb, justify, mono, style (cfg)
local function textBlock(tree, o)
  local cfg = o.style
  local t = new("/Script/UMG.TextBlock", tree)
  put(function() t.Font.Size = o.size end)
  local mono = o.mono and cfg.monoDigits and findMono() or nil
  if mono then
    put(function() t.Font.FontObject = mono t.Font.TypefaceFontName = FName("Regular") end)
  elseif cfg.fontStyle and cfg.fontStyle ~= "Default" then
    put(function() t.Font.TypefaceFontName = FName(cfg.fontStyle) end)
  end
  if (cfg.outline or 0) > 0 then put(function() t.Font.OutlineSettings.OutlineSize = cfg.outline end) end
  if cfg.shadow then
    put(function() t.ShadowOffset.X = cfg.shadowOffset t.ShadowOffset.Y = cfg.shadowOffset end)
    put(function() writeLinear(t.ShadowColorAndOpacity, H.color(cfg.shadowColor), 0.8) end)
  else
    put(function() t.ShadowColorAndOpacity.A = 0 end)
  end
  if o.justify then put(function() t.Justification = o.justify end) end
  local c = (o.key and H.colors[o.key]) or o.rgb or { 1, 1, 1 }
  put(function()
    writeLinear(t.ColorAndOpacity.SpecifiedColor, c, 1)
    t.ColorAndOpacity.ColorUseRule = 0
  end)
  if o.key then H.cache[o.key] = { text = H.texts[o.key] or "", color = colorKey(c) } end
  t:SetText(FText(o.key and H.texts[o.key] or ""))
  return t
end

local function slotPad(slot, l, t, r, b) put(function() writeMargin(slot.Padding, l or 0, t or 0, r or 0, b or 0) end) end
local function slotAlign(slot, h, v)
  if h then put(function() slot.HorizontalAlignment = h end) end
  if v then put(function() slot.VerticalAlignment = v end) end
end

local function canvasSlot(canvas, child, ax, ay, x, y)
  local slot = canvas:AddChildToCanvas(child)
  put(function() slot.bAutoSize = true end)
  put(function()
    local L = slot.LayoutData
    L.Anchors.Minimum.X, L.Anchors.Minimum.Y = ax, ay
    L.Anchors.Maximum.X, L.Anchors.Maximum.Y = ax, ay
    L.Alignment.X, L.Alignment.Y = ax, ay
    L.Offsets.Left, L.Offsets.Top = x, y
  end)
  return slot
end

local function roundBrush(brush, radius)
  put(function()
    brush.DrawAs = DRAW_ROUNDED_BOX
    local o = brush.OutlineSettings
    o.CornerRadii.X, o.CornerRadii.Y, o.CornerRadii.Z, o.CornerRadii.W = radius, radius, radius, radius
    o.RoundingType = FIXED_RADIUS
    o.Width = 0
  end)
end

local function sizeBox(tree, content, minWidth, hAlign)
  local sizer = new("/Script/UMG.SizeBox", tree)
  put(function() sizer.MinDesiredWidth = minWidth sizer.bOverride_MinDesiredWidth = true end)
  local inner = sizer:SetContent(content)
  if inner and hAlign then slotAlign(inner, hAlign, V_CENTER) end
  return sizer
end

-- "IGT  0:12.345": a dim label, and the digits right-aligned in a box that never
-- shrinks, so nothing moves sideways as the digits change
local function timeRow(tree, cfg, key, size, labelSize, minWidth)
  local row = new("/Script/UMG.HorizontalBox", tree)
  local label = textBlock(tree, { size = labelSize, key = key .. "_l", style = cfg })
  local digits = textBlock(tree, { size = size, key = key, style = cfg, justify = 2, mono = true })
  local ls = row:AddChildToHorizontalBox(label)
  slotAlign(ls, nil, V_CENTER)
  slotPad(ls, 0, 0, math.floor(size * 0.3), 0)
  slotAlign(row:AddChildToHorizontalBox(sizeBox(tree, digits, minWidth, H_RIGHT)), nil, V_CENTER)
  H.el[key .. "_l"], H.el[key] = label, digits
  return row
end

-- one line of the split ticker: name on the left, delta + time on the right
local function tickerLine(tree, cfg, n, size)
  local row = new("/Script/UMG.HorizontalBox", tree)
  local name = textBlock(tree, { size = size, key = "tk" .. n .. "n", style = cfg })
  local value = textBlock(tree, { size = size, key = "tk" .. n .. "v", style = cfg, justify = 2, mono = true })
  local ns = row:AddChildToHorizontalBox(name)
  slotPad(ns, 0, 0, math.floor(size * 1.2), 0)
  slotAlign(ns, nil, V_CENTER)
  slotAlign(row:AddChildToHorizontalBox(value), nil, V_CENTER)
  put(function() row.RenderTransformPivot.X, row.RenderTransformPivot.Y = 0.5, 0.5 end)
  return { box = row, name = name, value = value, n = n }
end

---------------------------------------------------------------------------
-- life cycle
---------------------------------------------------------------------------
local function drop()
  H.widget, H.el, H.menu, H.menuBorder, H.box, H.border = nil, {}, {}, nil, nil, nil
  H.lines, H.anim = nil, nil
  H.cache = {}
end

function H.destroy()
  if isValid(H.widget) then pcall(function() H.widget:RemoveFromParent() end) end
  drop()
end

-- the game deletes viewport widgets on level changes: never call into a deleted one
function H.alive()
  if not H.widget then return false end
  if not (isValid(H.widget) and isValid(H.box) and isValid(H.menuBorder)) then drop() return false end
  return true
end

---------------------------------------------------------------------------
-- build
---------------------------------------------------------------------------
-- L (from main.lua): { theme, mainChars, second = { size, chars } | nil,
--                      ticker = { size } | nil, info = { { key, size }, ... } }
function H.build(cfg, L, outer, owner)
  H.destroy()
  H.wantRebuild = false
  H.theme = L.theme
  local th = L.theme
  local widget = new("/Script/UMG.UserWidget", outer)
  local tree = new("/Script/UMG.WidgetTree", widget)
  widget.WidgetTree = tree
  local canvas = new("/Script/UMG.CanvasPanel", tree)
  tree.RootWidget = canvas

  local corner = CORNERS[cfg.corner] or CORNERS["top-right"]
  local align = cfg.align
  if align == "auto" then align = corner[1] == 1 and "right" or (corner[1] == 0.5 and "center" or "left") end
  local justify = align == "right" and 2 or (align == "center" and 1 or 0)
  local hAlign = align == "right" and H_RIGHT or (align == "center" and H_CENTER or H_LEFT)

  ---------------------------------------------------------------- backdrop
  local border = new("/Script/UMG.Border", tree)
  local bgA = cfg.background and cfg.bgOpacity or 0
  put(function() writeLinear(border.BrushColor, H.color(cfg.bgColor), bgA) end)
  roundBrush(border.Background, cfg.cornerRadius or 10)
  local pad = cfg.background and cfg.padding or 0
  put(function() writeMargin(border.Padding, pad, pad, pad, pad) end)
  local mx = corner[1] == 1 and -cfg.margin or (corner[1] == 0 and cfg.margin or 0)
  local my = corner[2] == 1 and -cfg.margin or (corner[2] == 0 and cfg.margin or 0)
  canvasSlot(canvas, border, corner[1], corner[2], mx + cfg.offsetX, my + cfg.offsetY)

  local outerRow = new("/Script/UMG.HorizontalBox", tree)
  border:SetContent(outerRow)

  -- accent bar down the left edge
  if cfg.accentBar and (cfg.accentWidth or 0) > 0 then
    local bar = new("/Script/UMG.Image", tree)
    put(function()
      bar.Brush.ImageSize.X, bar.Brush.ImageSize.Y = cfg.accentWidth, 4
      writeLinear(bar.ColorAndOpacity, H.color(cfg.accentColor), 1)
    end)
    roundBrush(bar.Brush, cfg.accentWidth / 2)
    local bs = outerRow:AddChildToHorizontalBox(bar)
    slotAlign(bs, nil, V_FILL)
    slotPad(bs, 0, 0, math.max(8, pad), 0)
  end

  local box = new("/Script/UMG.VerticalBox", tree)
  outerRow:AddChildToHorizontalBox(box)
  H.box = box
  H.el = {}

  local function add(w, gap)
    local s = box:AddChildToVerticalBox(w)
    slotAlign(s, hAlign)
    if gap and gap > 0 then slotPad(s, 0, gap, 0, 0) end
    return s
  end
  local charW = th.digitWidth

  add(timeRow(tree, cfg, "main", cfg.mainSize, math.max(10, math.floor(cfg.mainSize * th.labelScale)),
    math.floor(cfg.mainSize * charW * L.mainChars)))
  if L.second then
    add(timeRow(tree, cfg, "second", L.second.size, math.max(9, math.floor(L.second.size * 0.6)),
      math.floor(L.second.size * charW * L.second.chars)), cfg.lineGap)
  end

  -- split ticker: two lines stacked in an overlay, swapped on each split
  if L.ticker then
    local ov = new("/Script/UMG.Overlay", tree)
    H.lines = {}
    for n = 1, 2 do
      local line = tickerLine(tree, cfg, n, L.ticker.size)
      slotAlign(ov:AddChildToOverlay(line.box), hAlign, V_CENTER)
      H.lines[n] = line
    end
    local minW = math.floor(L.mainChars * cfg.mainSize * charW)
    add(sizeBox(tree, ov, minW, H_FILL), cfg.lineGap + math.floor(L.ticker.size * 0.35))
    -- the front line shows the current split (if any), the other waits hidden
    local tk = H.ticker
    for n = 1, 2 do
      local shown = n == tk.front and tk.id ~= nil
      put(function() H.lines[n].box.RenderOpacity = shown and 1 or 0 end)
    end
  end

  for _, r in ipairs(L.info) do
    local t = textBlock(tree, { size = r.size, key = r.key, style = cfg, justify = justify })
    H.el[r.key] = t
    add(t, cfg.lineGap)
  end

  H.border = border
  put(function() border.Visibility = cfg.hudVisible and HIT_TEST_INVISIBLE or COLLAPSED end)
  H.cache.hudVis = cfg.hudVisible and "v" or "h"

  ---------------------------------------------------------------- menu
  local mborder = new("/Script/UMG.Border", tree)
  put(function() writeLinear(mborder.BrushColor, H.color("Ink"), 0.92) end)
  -- the settings menu keeps a plain square backdrop
  put(function() writeMargin(mborder.Padding, 26, 20, 26, 20) end)
  canvasSlot(canvas, mborder, 0.5, 0.5, 0, 0)

  local mbox = new("/Script/UMG.VerticalBox", tree)
  mborder:SetContent(mbox)
  local plain = { shadow = true, shadowOffset = 1, shadowColor = "Black" }
  H.menuTitle = textBlock(tree, { size = 22, key = "mt", style = plain })
  mbox:AddChildToVerticalBox(H.menuTitle)
  H.menuHint = textBlock(tree, { size = 13, key = "mh", rgb = { 0.6, 0.6, 0.66 }, style = plain })
  slotPad(mbox:AddChildToVerticalBox(H.menuHint), 0, 2, 0, 0)
  H.menu = {}
  for i = 1, H.menuLines do
    local row = new("/Script/UMG.HorizontalBox", tree)
    local a = textBlock(tree, { size = 17, key = "ml" .. i, style = plain })
    local b = textBlock(tree, { size = 17, key = "mv" .. i, style = plain, justify = 2 })
    slotPad(row:AddChildToHorizontalBox(a), 0, 0, 40, 0)
    row:AddChildToHorizontalBox(b)
    slotPad(mbox:AddChildToVerticalBox(row), 0, i == 1 and 12 or 2, 0, 0)
    H.menu[i] = { label = a, value = b }
  end
  H.menuFooter = textBlock(tree, { size = 13, key = "mf", rgb = { 0.6, 0.6, 0.66 }, style = plain })
  slotPad(mbox:AddChildToVerticalBox(H.menuFooter), 0, 12, 0, 0)
  H.menuBorder = mborder
  local menuOpen = H.menuOpen == true
  put(function() mborder.Visibility = menuOpen and HIT_TEST_INVISIBLE or COLLAPSED end)
  H.cache.menuVis = menuOpen and "v" or "h"

  put(function() canvas.Visibility = HIT_TEST_INVISIBLE end)
  put(function() widget.Visibility = HIT_TEST_INVISIBLE end)
  if owner then pcall(function() widget:SetOwningPlayer(owner) end) end
  widget:AddToViewport(10000)
  H.widget = widget
  return true
end

---------------------------------------------------------------------------
-- updates (only touch Slate when something changed)
---------------------------------------------------------------------------
local function set(t, key, text, rgb)
  if not t then return end
  local c = H.cache[key]
  if not c then c = {} H.cache[key] = c end
  if text ~= nil and c.text ~= text then t:SetText(FText(text)) c.text = text H.texts[key] = text end
  if rgb then
    H.colors[key] = rgb
    local ck = colorKey(rgb)
    if c.color ~= ck then
      if H.liveColors and paint(t, rgb) then c.color = ck else H.wantRebuild = true end
    end
  end
end

function H.set(key, text, rgb) set(H.el[key], key, text, rgb) end

-- a timer row: dim label + bright digits
function H.setTime(key, label, digits, rgb)
  if not H.el[key] then return end
  set(H.el[key .. "_l"], key .. "_l", label, scaleRgb(rgb, H.theme.labelDim))
  set(H.el[key], key, digits, rgb)
end
function H.has(key) return H.el[key] ~= nil end

---------------------------------------------------------------------------
-- split ticker
---------------------------------------------------------------------------
local function fillLine(line, s, colours)
  set(line.name, "tk" .. line.n .. "n", s.name, colours and s.nameRgb or nil)
  set(line.value, "tk" .. line.n .. "v", s.value, colours and s.valueRgb or nil)
end

-- s = { id, name, value, nameRgb, valueRgb }, or nil for "no split yet".
-- A new id slides the old split out and the new one in, with a pop and a flash.
function H.showSplit(s)
  if not H.lines then return end
  local tk = H.ticker
  local id = s and s.id or nil
  if id == tk.id then
    if s and not H.anim then fillLine(H.lines[tk.front], s, true) end
    return
  end
  local out, inn = H.lines[tk.front], H.lines[3 - tk.front]
  tk.id = id
  H.anim = nil
  if not s then   -- run reset: clear the ticker
    fade(out.box, 0) fade(inn.box, 0)
    return
  end
  tk.front = inn.n
  if H.theme.animate then
    fillLine(inn, s, false)
    set(inn.name, "tk" .. inn.n .. "n", nil, H.theme.flashColor)
    set(inn.value, "tk" .. inn.n .. "v", nil, H.theme.flashColor)
    transform(inn.box, H.theme.slideDistance, H.theme.popScale)
    fade(inn.box, 0)
    H.anim = { t = 0, pop = 0, out = out, inn = inn, s = s }
  else
    fillLine(inn, s, true)
    transform(inn.box, 0, 1) fade(inn.box, 1)
    transform(out.box, 0, 1) fade(out.box, 0)
  end
end

-- call every frame with the frame time in seconds (everything is time-based, not frames)
function H.animate(dt)
  local a = H.anim
  if not a or not H.lines then return end
  local th = H.theme
  dt = math.min(dt, 0.1)   -- a long hitch shouldn't skip the whole animation
  a.t = math.min(1, a.t + dt / math.max(0.01, th.slideTime))
  a.pop = math.min(1, a.pop + dt / math.max(0.01, th.popTime))
  local e, p = easeOut(a.t), easeOut(a.pop)
  -- outgoing: slides up and fades out
  transform(a.out.box, -th.slideDistance * e, 1)
  fade(a.out.box, 1 - e)
  -- incoming: slides up from below, fades in, pops from popScale back to 1
  transform(a.inn.box, th.slideDistance * (1 - e), th.popScale + (1 - th.popScale) * p)
  fade(a.inn.box, e)
  -- flash colour eases back to the normal colours
  set(a.inn.name, "tk" .. a.inn.n .. "n", nil, mix(th.flashColor, a.s.nameRgb, p))
  set(a.inn.value, "tk" .. a.inn.n .. "v", nil, mix(th.flashColor, a.s.valueRgb, p))
  if a.t >= 1 and a.pop >= 1 then
    transform(a.out.box, 0, 1) fade(a.out.box, 0)
    transform(a.inn.box, 0, 1) fade(a.inn.box, 1)
    fillLine(a.inn, a.s, true)
    H.anim = nil
  end
end

function H.setHudVisible(v)
  if not H.border then return end
  local k = v and "v" or "h"
  if H.cache.hudVis ~= k then
    H.border:SetVisibility(v and HIT_TEST_INVISIBLE or COLLAPSED)
    H.cache.hudVis = k
  end
end

-- lines: { label = "", value = "", color = rgb, valueColor = rgb }
function H.setMenu(visible, title, hint, lines, footer)
  if not H.menuBorder then return end
  H.menuOpen = visible
  local vk = visible and "v" or "h"
  if H.cache.menuVis ~= vk then
    H.menuBorder:SetVisibility(visible and HIT_TEST_INVISIBLE or COLLAPSED)
    H.cache.menuVis = vk
  end
  if not visible then return end
  local live = H.liveColors   -- without live colours the › marks the row
  set(H.menuTitle, "mt", title, live and { 1, 1, 1 } or nil)
  set(H.menuHint, "mh", hint)
  for i = 1, H.menuLines do
    local l = lines[i]
    local row = H.menu[i]
    set(row.label, "ml" .. i, l and l.label or "", live and (l and l.color or { 1, 1, 1 }) or nil)
    set(row.value, "mv" .. i, l and l.value or "", live and (l and (l.valueColor or l.color) or { 1, 1, 1 }) or nil)
  end
  set(H.menuFooter, "mf", footer or "")
end

return H
