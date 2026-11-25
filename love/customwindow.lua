-- Customise: the look of Mu Split, with a live animated preview.
--
-- Simple first: pick a look (preset card) and an accent colour, done. Everything else
-- (every colour, background, fonts and sizes, layout, effects) is one tab away.
-- Changes apply to the whole app as you make them (colours glide over); Cancel puts
-- back what you had, Done keeps it. Looks can be saved as presets and shared as text.

local theme = require("theme")
local ui = require("ui")
local W = require("widgets")
local windows = require("windows")
local dialogs = require("dialogs")
local presets = require("presets")
local view = require("timerview")
local postfx = require("postfx")
local filedialog = require("filedialog")
local sounds = require("sounds")
local workshop = require("workshop")

local cw = {}
local lg = love.graphics
local damp = ui.damp

local win = { title = "Customise", w = 1100, h = 720 }
local E, original = nil, nil      -- the style being edited, and the one to go back to
local tab = "looks"
local toast = { text = nil, t = 0 }

local TABS = {
  { value = "looks", label = "Looks" },
  { value = "workshop", label = "Workshop" },
  { value = "colors", label = "Colours" },
  { value = "background", label = "Background" },
  { value = "text", label = "Text & Sizes" },
  { value = "layout", label = "Layout" },
  { value = "effects", label = "Effects" },
  { value = "shaders", label = "Shaders" },
  { value = "sounds", label = "Sounds" },
}

local QUICK_ACCENTS = {
  { "#d65db1", "#8f6bff" }, { "#ff6fa8", "#c38bff" }, { "#5b8cff", "#b26bff" }, { "#00e5ff", "#ff2bd6" },
  { "#22d3ee", "#3b82f6" }, { "#4cd38a", "#b5e655" }, { "#ffc83d", "#ff7a45" }, { "#ff7a45", "#ff3d77" },
  { "#f0434f", "#ff9f43" }, { "#ffffff", "#9a9a9a" },
}

local function say(text) toast.text, toast.t = text, 2.2 end

-- undo: the look before each change (a slider drag counts as one change)
local history, lastSnap, lastPush = {}, nil, -1

local function apply()
  local now = love.timer.getTime()
  if lastSnap and now - lastPush > 0.6 then
    history[#history + 1] = lastSnap
    if #history > 80 then table.remove(history, 1) end
  end
  lastPush = now
  presets.use(E)
  lastSnap = theme.deepcopy(E)
end

local function undo()
  if #history == 0 then return end
  E = table.remove(history)
  presets.use(E)
  lastSnap, lastPush = theme.deepcopy(E), -1
  say("Undone")
end

function cw.open()
  original = theme.deepcopy(presets.current)
  E = theme.deepcopy(presets.current)
  history, lastSnap, lastPush = {}, theme.deepcopy(E), -1
  presets.loadUser()
  view.demo.demoT = 0
  windows.push(win)
end

function win:keypressed(key)
  if key == "z" and love.keyboard.isDown("lctrl", "rctrl") and not ui.wantsKeyboard() then undo() return true end
  return false
end

---------------------------------------------------------------------------
-- your own background picture: drag one onto the window, or "Choose picture…"
---------------------------------------------------------------------------
local IMAGE_EXT = { png = true, jpg = true, jpeg = true, bmp = true, tga = true }

local function usePicture(name, data)
  local ext = (name:match("%.(%w+)$") or ""):lower()
  if not IMAGE_EXT[ext] then dialogs.error("That isn't a picture Mu Split can use (PNG, JPG, BMP or TGA).") return end
  love.filesystem.createDirectory("backgrounds")
  local safe = name:gsub("[^%w%-%_%.]", "_")
  local path = "backgrounds/" .. safe
  love.filesystem.write(path, data)
  local ok = pcall(love.graphics.newImage, path)
  if not ok then dialogs.error("That picture couldn't be opened.") return end
  if windows.top() == win and E then
    E.background.image = path
    apply()
  else
    local st = theme.deepcopy(presets.current)
    st.background.image = path
    presets.use(st)
  end
  say("Background picture set")
end

-- love.filedropped (main.lua): works anywhere, not only in this window
function cw.dropFile(file)
  local name = (file:getFilename() or "picture.png"):match("[^/\\]+$") or "picture.png"
  local okOpen = pcall(file.open, file, "r")
  if not okOpen then return end
  local data = file:read()
  file:close()
  usePicture(name, data)
end

local function choosePicture()
  local path = filedialog.open({ title = "Choose a background picture", defExt = "png",
    filter = "Pictures (*.png;*.jpg;*.jpeg;*.bmp)\0*.png;*.jpg;*.jpeg;*.bmp\0All files (*.*)\0*.*\0" })
  if not path then return end
  local f = io.open(path, "rb")
  if not f then dialogs.error("Couldn't read that file.") return end
  local data = f:read("*a")
  f:close()
  usePicture(path:match("[^/\\]+$") or "picture.png", data)
end

---------------------------------------------------------------------------
-- "Surprise me": a random look that still looks good
---------------------------------------------------------------------------
local function surprise()
  local r = love.math.random
  local function pick(t) return t[r(#t)] end
  local function hsv(h, s, v) return theme.toHex({ W.hsvToRgb(h % 1, s, v) }) end
  local h = r()
  local keepPic = E.background.image
  E = theme.complete(theme.deepcopy(E))
  E.name = "Surprise"
  local c, b = E.colors, E.background
  c.accent, c.accent2 = hsv(h, 0.62, 1), hsv(h + 0.1 + r() * 0.25, 0.58, 1)
  if r() < 0.8 then
    c.bg, c.surface = hsv(h, 0.35, 0.06), hsv(h, 0.22, 0.11)
    c.text, c.textDim, c.idle = hsv(h, 0.04, 0.95), hsv(h, 0.12, 0.66), hsv(h, 0.12, 0.66)
    b.top, b.bottom = hsv(h, 0.45, 0.14), hsv(h + 0.05, 0.4, 0.04)
  else
    c.bg, c.surface = hsv(h, 0.06, 0.98), "#ffffff"
    c.text, c.textDim, c.idle = hsv(h, 0.3, 0.18), hsv(h, 0.15, 0.55), hsv(h, 0.15, 0.6)
    b.top, b.bottom = hsv(h, 0.12, 1), hsv(h, 0.03, 0.98)
  end
  b.mode = pick({ "aurora", "aurora", "gradient" })
  b.intensity, b.motion, b.vignette = 0.4 + r() * 0.5, 0.3 + r() * 0.6, r() * 0.5
  b.image = keepPic
  E.effects.highlight = pick({ "pill", "glow", "bar", "pill" })
  E.effects.timerGlow = 0.2 + r() * 0.7
  local look = pick({ "None", "Soft Bloom", "Soft Bloom", "Cinematic", "Dreamy" })
  for _, l in ipairs(postfx.LOOKS) do if l.name == look then E.post = theme.deepcopy(l.post) E.post.look = l.name end end
  apply()
  say("Surprise!")
end

local SIZES = {
  { name = "Compact", sizes = { timer = 42, row = 13, rowH = 25, title = 15, segment = 15 } },
  { name = "Normal",  sizes = { timer = 56, row = 14, rowH = 30, title = 17, segment = 18 } },
  { name = "Big",     sizes = { timer = 78, row = 17, rowH = 37, title = 21, segment = 23 } },
}

-- a rounded "chip" button; returns clicked, width
local function chip(id, label, x, y, selected, opt)
  opt = opt or {}
  local f = opt.font or theme.fonts.ui
  local bw = opt.w or (f:getWidth(label) + 26)
  local hov, clicked = ui.interact(id, x, y, bw, 28)
  local a = ui.getAnim(id)
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
  a.check = damp(a.check, selected and 1 or 0, theme.speedHover, ui.dt)
  if hov then ui.cursor = "hand" end
  if opt.tooltip and hov then ui.setTooltip(id, opt.tooltip) end
  ui.color(ui.mix(ui.mix(theme.input, theme.inputHover, a.hover), theme.accent, a.check * 0.85))
  ui.rect("fill", x, y, bw, 28, 14)
  if opt.outline then ui.color(theme.accent, 0.8) ui.rect("line", x + 0.5, y + 0.5, bw - 1, 27, 14) end
  ui.label(label, x, y, { w = bw, h = 28, align = "center", font = f, color = selected and { 1, 1, 1, 1 } or theme.text })
  return clicked, bw
end

function cw.setTab(v) tab = v end    -- (tests)


function win:onClose()      -- X / Esc = cancel
  presets.use(original)
  postfx.release("preview")
  windows.pop(win)
end

local function done()
  presets.use(E)
  presets.rememberForGame()
  presets.flush()
  postfx.release("preview")
  windows.pop(win)
end

---------------------------------------------------------------------------
-- mini preview of a style for the preset cards
---------------------------------------------------------------------------
local function drawMini(style, x, y, w, h, t)
  local c = style.colors
  local bgs = style.background
  local top, bottom = theme.hex(bgs.top or c.bg), theme.hex(bgs.bottom or c.bg)
  if bgs.mode == "solid" then top, bottom = theme.hex(c.bg), theme.hex(c.bg) end
  ui.pushClip(x, y, w, h)
  view.gradientRect(x, y, w, h, top, bottom)
  local acc, acc2 = theme.hex(c.accent), theme.hex(c.accent2 or c.accent)
  if bgs.mode == "aurora" then
    view.glow(x + w * (0.3 + 0.1 * math.sin(t * 0.7)), y + h * 0.3, w * 1.2, h * 1.4, acc, 0.25 * (bgs.intensity or 0.5))
    view.glow(x + w * 0.85, y + h * (0.7 + 0.1 * math.cos(t * 0.6)), w, h * 1.2, acc2, 0.22 * (bgs.intensity or 0.5))
  end
  -- three split rows, the middle one highlighted
  local rx, rw, rh = x + 10, w - 20, 9
  local textDim, text = theme.hex(c.textDim), theme.hex(c.text)
  for i = 0, 2 do
    local ry = y + 12 + i * 15
    if i == 1 then
      ui.color(acc, 0.25) ui.rect("fill", rx - 4, ry - 3, rw + 8, rh + 6, 4)
      ui.color(acc, 0.9) lg.rectangle("fill", rx - 4, ry - 3, 2, rh + 6)
    end
    ui.color(i == 0 and text or textDim, 0.75) ui.rect("fill", rx, ry + 2, rw * (0.42 + 0.1 * i), 4, 2)
    ui.color(i == 0 and theme.hex(c.ahead) or textDim, 0.75) ui.rect("fill", rx + rw - 28, ry + 2, 28, 4, 2)
  end
  -- the big timer
  local f = theme.font(24, style.fonts.timerBold and "semibold" or "regular", style.fonts.timer)
  local ahead = theme.hex(c.ahead)
  if (style.effects.timerGlow or 0) > 0 then view.glow(x + w - 44, y + h - 22, 110, 40, ahead, 0.2 * style.effects.timerGlow) end
  ui.color(ahead)
  lg.setFont(f)
  lg.print("1:23", math.floor(x + w - 12 - f:getWidth("1:23")), math.floor(y + h - f:getHeight() - 6))
  ui.popClip()
end

---------------------------------------------------------------------------
-- tabs
---------------------------------------------------------------------------
local function rowLabel(text, x, y, opt)
  ui.label(text, x, y, { h = 26, color = (opt and opt.color) or theme.text })
end

local function colorRow(label, tbl, key, x, y, w, tip)
  rowLabel(label, x, y)
  local v, changed = W.colorButton("cw:col:" .. key, tbl[key], x + w - 150, y, 150, 26, { tooltip = tip })
  if changed then tbl[key] = v apply() end
  return y + 34
end

local function switchRow(label, tbl, key, x, y, w, tip)
  local v, changed = W.switch("cw:sw:" .. key, tbl[key], x, y, { label = label, w = w, tooltip = tip })
  if changed then tbl[key] = v apply() end
  return y + 32
end

local function sliderRow(label, tbl, key, min, max, x, y, w, opt)
  opt = opt or {}
  opt.label = label
  opt.labelW = opt.labelW or 170
  local v, changed = W.slider("cw:sl:" .. key, tbl[key], min, max, x, y, w, opt)
  if changed then tbl[key] = v apply() end
  return y + 34
end

local function segmentedRow(label, tbl, key, options, x, y, w)
  rowLabel(label, x, y)
  local sw = math.min(w - 170, #options * 92)
  local v, changed = ui.segmented("cw:seg:" .. key, options, tbl[key], x + w - sw, y - 1, sw, 28)
  if changed then tbl[key] = v apply() end
  return y + 38
end

local function dropdownRow(label, tbl, key, items, x, y, w)
  rowLabel(label, x, y)
  local v, changed = ui.dropdown("cw:dd:" .. key, items, tbl[key], x + w - 200, y - 1, 200, 28)
  if changed then tbl[key] = v apply() end
  return y + 38
end

local tabDraw = {}

function tabDraw.looks(x, y, w, t)
  -- quick accent
  y = W.section("Accent", x, y, w)
  local sz, gap = 30, 10
  for i, pair in ipairs(QUICK_ACCENTS) do
    local sx = x + (i - 1) * (sz + gap)
    if sx + sz > x + w then break end
    local id = "cw:qa:" .. i
    local hov, clicked = ui.interact(id, sx, y, sz, sz)
    local a = ui.getAnim(id)
    a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
    if hov then ui.cursor = "hand" end
    local selected = E.colors.accent:lower() == pair[1]
    local r = sz / 2 + a.hover * 1.5
    if selected then ui.color(theme.text) lg.circle("line", sx + sz / 2, y + sz / 2, r + 3) end
    -- two-tone swatch
    ui.color(theme.hex(pair[2])) lg.circle("fill", sx + sz / 2, y + sz / 2, r)
    ui.color(theme.hex(pair[1])) lg.arc("fill", sx + sz / 2, y + sz / 2, r, math.pi * 0.75, math.pi * 1.75)
    if clicked then E.colors.accent, E.colors.accent2 = pair[1], pair[2] apply() end
  end
  y = y + sz + 22

  -- size + surprise
  y = W.section("Size", x, y, w)
  local cx = x
  for i, sset in ipairs(SIZES) do
    local same = true
    for k, v in pairs(sset.sizes) do if E.sizes[k] ~= v then same = false end end
    local clicked, bw = chip("cw:size:" .. i, sset.name, cx, y, same)
    if clicked then for k, v in pairs(sset.sizes) do E.sizes[k] = v end apply() end
    cx = cx + bw + 8
  end
  local sw = theme.fonts.uiBold:getWidth("Surprise me") + 30
  if chip("cw:surprise", "Surprise me", x + w - sw, y, false,
      { w = sw, font = theme.fonts.uiBold, outline = true, tooltip = "A random look: click again for another" }) then
    surprise()
  end
  y = y + 46

  -- preset gallery
  y = W.section("Looks", x, y, w)
  local all = presets.all()
  local cols = 3
  local cgap = 14
  local cardW = math.floor((w - cgap * (cols - 1)) / cols)
  local miniH = 92
  local cardH = miniH + 34
  for i, p in ipairs(all) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local cx, cy = x + col * (cardW + cgap), y + row * (cardH + cgap)
    local selected = p.style.name == E.name
    local _, clicked, _, lift = W.card("cw:card:" .. i, cx, cy, cardW, cardH, selected)
    drawMini(p.style, cx + 6, cy + 6 - lift, cardW - 12, miniH - 6, t + i)
    local nameW = p.builtin and (cardW - 20) or (cardW - 60)
    local nf = theme.fonts.uiBold:getWidth(p.style.name) <= nameW and theme.fonts.uiBold or theme.fonts.ui
    ui.label(ui.ellipsize(nf, p.style.name, nameW), cx + 10, cy + miniH - lift, { h = 30, font = nf })
    if not p.builtin then
      ui.label("yours", cx + cardW - 50, cy + miniH - lift, { h = 30, w = 40, align = "right", font = theme.fonts.small, color = theme.accent })
    end
    if clicked then
      local pic, dim = E.background.image, E.background.imageDim
      E = theme.deepcopy(p.style)
      E.background.image, E.background.imageDim = pic, dim or E.background.imageDim   -- your picture stays
      apply()
    end
  end
  local rowsN = math.ceil(#all / cols)
  y = y + rowsN * (cardH + cgap) + 6

  -- actions
  y = W.section("Save & share", x, y, w)
  local bw, bh = 132, 30
  if ui.button("cw:save", "Save as preset…", x, y, bw, bh, { primary = true }) then
    local suggested = presets.isBuiltin(E.name) and (E.name .. " (mine)") or E.name
    dialogs.input({ title = "Save Look", label = "Preset name:", text = suggested, okLabel = "Save",
      onOk = function(name)
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then dialogs.error("Give the preset a name.") return end
        if presets.isBuiltin(name) then dialogs.error("That's a built-in look's name. Pick another.") return end
        local ok = presets.saveUser(E, name)
        if ok then E.name = name apply() say("Saved “" .. name .. "”") else dialogs.error("Couldn't save the preset.") end
      end })
  end
  if ui.button("cw:copy", "Copy look", x + bw + 8, y, 104, bh, { tooltip = "Copies this look as text, to share or keep" }) then
    presets.export(E)
    say("Look copied to the clipboard")
  end
  if ui.button("cw:paste", "Paste look", x + bw + 120, y, 104, bh, { tooltip = "Uses a look someone shared (copied text)" }) then
    local st, err = presets.import()
    if st then E = st apply() say("Pasted “" .. (st.name or "look") .. "”") else dialogs.error(err) end
  end
  if ui.button("cw:share", "Share to workshop…", x, y + bh + 8, 160, bh,
      { tooltip = "Opens a ready-filled form on GitHub: press Submit and it goes into the workshop" }) then
    local suggested = (presets.isBuiltin(E.name) or E.name == "Surprise") and "" or E.name
    dialogs.input({ title = "Share to the Workshop", label = "Name for your look:", text = suggested, okLabel = "Open GitHub",
      onOk = function(name)
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" then dialogs.error("Give your look a name.") return end
        local ok = workshop.share(E, name)
        if ok then say("Opened GitHub: press Submit there") else dialogs.error("Couldn't open your browser.") end
      end })
  end
  local userSel = presets.exists(E.name) and not presets.isBuiltin(E.name)
  if ui.button("cw:del", "Delete", x + w - 90, y, 90, bh, { disabled = not userSel, tooltip = "Delete this saved preset" }) then
    local name = E.name
    dialogs.message({ title = "Delete Preset", text = "Delete your preset “" .. name .. "”? The look stays on until you pick another.",
      buttons = { { label = "Delete", primary = true, action = function() presets.deleteUser(name) say("Deleted “" .. name .. "”") end },
                  { label = "Cancel" } } })
  end
  y = y + bh * 2 + 18
  ui.label("Saved looks live in %APPDATA%\\LOVE\\musplit\\presets", x, y, { font = theme.fonts.small, color = theme.textFaint })
  y = y + 30
  y = W.section("Per game", x, y, w)
  local on, changed = W.switch("cw:pergame", presets.gameLooks.enabled, x, y, { label = "Remember a look for each game", w = w,
    tooltip = "The look you choose while a game's splits are open comes back whenever you open that game's splits" })
  if changed then presets.setPerGame(on) say(on and "Looks are now remembered per game" or "One look for every game") end
  y = y + 30
  if presets.gameLooks.enabled then
    local g = presets.currentGame
    ui.label(g and g ~= "" and ("This look will be used for “" .. g .. "”.") or "Open a game's splits to give it its own look.",
      x, y, { color = theme.textDim })
    y = y + 24
  end
  return y
end

function tabDraw.colors(x, y, w)
  local c = E.colors
  y = W.section("Interface", x, y, w)
  y = colorRow("Background", c, "bg", x, y, w, "Behind everything (also the solid background)")
  y = colorRow("Panels", c, "surface", x, y, w, "Windows, menus, cards; buttons and borders are shaded from it")
  y = colorRow("Text", c, "text", x, y, w)
  y = colorRow("Dim text", c, "textDim", x, y, w, "Labels, future splits")
  y = colorRow("Accent", c, "accent", x, y, w, "Highlights, toggles, the progress bar")
  y = colorRow("Accent 2", c, "accent2", x, y, w, "The other end of every accent gradient")
  y = y + 6
  y = W.section("Timer", x, y, w)
  y = colorRow("Ahead", c, "ahead", x, y, w, "Ahead of the comparison (gaining; losing time is a softer shade)")
  y = colorRow("Behind", c, "behind", x, y, w, "Behind the comparison (losing; gaining back is a softer shade)")
  y = colorRow("Best segment", c, "gold", x, y, w, "A gold split, and a finished run that beat the comparison")
  y = colorRow("Not running", c, "idle", x, y, w, "The timer before you start")
  return y
end

function tabDraw.background(x, y, w)
  local b = E.background
  y = W.section("Background", x, y, w)
  y = segmentedRow("Style", b, "mode", {
    { value = "solid", label = "Solid" }, { value = "gradient", label = "Gradient" }, { value = "aurora", label = "Aurora" } }, x, y, w)
  if b.mode == "solid" then
    y = colorRow("Colour", E.colors, "bg", x, y, w)
  else
    y = colorRow("Top", b, "top", x, y, w)
    y = colorRow("Bottom", b, "bottom", x, y, w)
  end
  if b.mode == "aurora" then
    y = y + 4
    y = W.section("Aurora", x, y, w)
    y = sliderRow("Glow", b, "intensity", 0, 1, x, y, w, { format = function(v) return math.floor(v * 100) .. "%" end,
      tooltip = "How bright the drifting accent lights are" })
    y = sliderRow("Motion", b, "motion", 0, 2, x, y, w, { format = function(v) return string.format("%.1fx", v) end,
      tooltip = "How fast they drift (0 = still)" })
  end
  y = sliderRow("Floating particles", b, "particles", 0, 1, x, y, w, { format = function(v) return v <= 0 and "off" or (math.floor(v * 100) .. "%") end,
    tooltip = "Soft specks of light drifting up the background" })
  y = y + 4
  y = W.section("Picture", x, y, w)
  if b.image then
    local pic = view.picture(b.image)
    if pic then
      local th = 54
      local tw = math.floor(th * pic:getWidth() / pic:getHeight())
      tw = math.min(tw, 120)
      ui.pushClip(x, y, tw, th)
      local sc = math.max(tw / pic:getWidth(), th / pic:getHeight())
      lg.setColor(1, 1, 1, 1)
      lg.draw(pic, x, y, 0, sc, sc)
      ui.popClip()
      ui.color(theme.border) ui.rect("line", x + 0.5, y + 0.5, tw - 1, th - 1, 3)
      ui.label(ui.ellipsize(theme.fonts.ui, (b.image:match("[^/]+$") or b.image), w - tw - 130), x + tw + 12, y + 4)
    end
    if ui.button("cw:picrm", "Remove", x + w - 100, y + 12, 100, 28) then b.image = nil apply() end
    y = y + 66
    y = sliderRow("Colour over it", b, "imageDim", 0, 1, x, y, w, { format = function(v) return math.floor(v * 100) .. "%" end,
      tooltip = "How much of the look's background colour covers the picture" })
  else
    if ui.button("cw:picadd", "Choose picture…", x, y, 150, 28) then choosePicture() end
    ui.label("or drag an image onto the window", x + 162, y, { h = 28, color = theme.textDim })
    y = y + 40
  end
  y = y + 4
  y = W.section("Edges", x, y, w)
  y = sliderRow("Vignette", b, "vignette", 0, 1, x, y, w, { format = function(v) return math.floor(v * 100) .. "%" end,
    tooltip = "Darkens the corners" })
  return y
end

function tabDraw.text(x, y, w)
  local f, s, L = E.fonts, E.sizes, E.layout
  local names = theme.fontNames()
  y = W.section("Fonts", x, y, w)
  y = dropdownRow("Interface & splits", f, "ui", names, x, y, w)
  y = dropdownRow("Timer", f, "timer", names, x, y, w)
  y = switchRow("Bold timer", f, "timerBold", x, y, w)
  y = switchRow("Bold text", f, "bold", x, y, w, "Split names, times and info in bold: easier to read")
  y = switchRow("Text shadow", L, "textShadow", x, y, w, "A soft shadow behind the timer's text, so it stands out from busy backgrounds")
  y = y + 4
  y = W.section("Sizes", x, y, w)
  local px = function(v) return math.floor(v + 0.5) .. " px" end
  y = sliderRow("Timer", s, "timer", 28, 120, x, y, w, { step = 1, format = px })
  y = sliderRow("Segment timer", s, "segment", 10, 36, x, y, w, { step = 1, format = px })
  y = sliderRow("Split names", s, "row", 10, 26, x, y, w, { step = 1, format = px })
  y = sliderRow("Split row height", s, "rowH", 20, 56, x, y, w, { step = 1, format = px })
  y = sliderRow("Game title", s, "title", 11, 30, x, y, w, { step = 1, format = px })
  y = y + 4
  y = W.section("Time", x, y, w)
  y = segmentedRow("Timer decimals", L, "decimals", {
    { value = 0, label = "0:00" }, { value = 1, label = ".0" }, { value = 2, label = ".00" }, { value = 3, label = ".000" } }, x, y, w)
  return y
end

function tabDraw.layout(x, y, w)
  local L = E.layout
  y = W.section("Show", x, y, w)
  y = switchRow("Game title & category", L, "header", x, y, w)
  y = switchRow("Run progress bar", L, "progress", x, y, w, "A bar that fills as you go through your splits")
  y = switchRow("Segment timer", L, "segmentTimer", x, y, w, "Time in the current split, under the main timer")
  y = switchRow("Comparison name", L, "comparison", x, y, w)
  y = switchRow("Previous segment", L, "prevSegment", x, y, w)
  y = switchRow("Timing method", L, "timingMethod", x, y, w)
  y = switchRow("Sum of best", L, "sumOfBest", x, y, w, "Your best segments added up")
  y = switchRow("Best possible time", L, "bestPossible", x, y, w, "The best finish still possible from where you are")
  y = switchRow("Possible time save", L, "timeSave", x, y, w, "How much faster this split (and the whole run) could be, going by your best segments")
  y = switchRow("Autosplitter status", L, "autosplitterStatus", x, y, w, "Status bar: waiting for the game, connected, or the script's error")
  y = switchRow("Status bar", L, "statusBar", x, y, w)
  y = y + 4
  y = W.section("Splits", x, y, w)
  y = switchRow("Striped rows", L, "stripes", x, y, w)
  y = switchRow("Row separators", L, "separators", x, y, w)
  y = switchRow("Subsplits", L, "subsplits", x, y, w,
    "Splits named -Name are grouped under the next split named {Section} Name, like LiveSplit's Subsplits")
  if L.subsplits then y = switchRow("    Always open every section", L, "subsplitsExpand", x, y, w) end
  y = y + 4
  y = W.section("Shape", x, y, w)
  y = segmentedRow("Timer position", L, "timerAlign", {
    { value = "left", label = "Left" }, { value = "center", label = "Centre" }, { value = "right", label = "Right" } }, x, y, w)
  y = sliderRow("Corner roundness", L, "roundness", 0, 16, x, y, w, { step = 1, format = function(v) return math.floor(v) .. " px" end })
  return y
end

function tabDraw.effects(x, y, w)
  local fx = E.effects
  y = W.section("Current split", x, y, w)
  y = dropdownRow("Highlight", fx, "highlight", {
    { value = "pill", label = "Pill" }, { value = "glow", label = "Glow" }, { value = "bar", label = "Bar" },
    { value = "underline", label = "Underline" }, { value = "none", label = "None" } }, x, y, w)
  y = switchRow("Pulse while live", fx, "livePulse", x, y, w, "The highlight and live delta breathe gently")
  y = y + 4
  y = W.section("Timer", x, y, w)
  y = sliderRow("Glow", fx, "timerGlow", 0, 1, x, y, w, { format = function(v) return math.floor(v * 100) .. "%" end })
  y = switchRow("Rolling digits", fx, "digitRoll", x, y, w, "Each digit rolls up when it changes")
  y = y + 4
  y = W.section("Moments", x, y, w)
  y = switchRow("Split pop", fx, "splitPop", x, y, w, "The new delta pops in and a shine sweeps the row")
  y = switchRow("Gold sparks", fx, "sparks", x, y, w, "Sparks fly on a best segment")
  y = switchRow("Confetti on a personal best", fx, "confetti", x, y, w)
  y = switchRow("Rows slide in after a reset", fx, "rowIntro", x, y, w)
  y = y + 4
  y = W.section("Motion", x, y, w)
  y = sliderRow("Animation speed", fx, "speed", 0.25, 2.5, x, y, w, { format = function(v) return string.format("%.2fx", v) end,
    tooltip = "Speeds up or slows down every animation" })
  return y
end

function tabDraw.shaders(x, y, w)
  E.post = E.post or {}
  local p = E.post
  for k, v in pairs(postfx.DEFAULTS) do if p[k] == nil then p[k] = v end end

  if not postfx.available then
    y = W.section("Shaders", x, y, w)
    ui.label("Shader effects use moonshine, which build.bat downloads into love\\moonshine.\nRun build.bat once, then come back here.",
      x, y, { w = w, color = theme.textDim })
    return y + 50
  end
  if postfx.broken then
    ui.label("Shaders were turned off because your graphics card couldn't run them:\n" .. tostring(postfx.error or ""),
      x, y, { w = w, color = theme.behindLose })
    y = y + 50
  elseif postfx.failed then
    ui.label("Your graphics card couldn't run: " .. postfx.failed .. ". Everything else still works.",
      x, y, { w = w, color = theme.textDim })
    y = y + 30
  end

  -- one-click shader looks
  y = W.section("Shader look", x, y, w)
  local cx, cy = x, y
  local anyOn = postfx.active()
  for i, look in ipairs(postfx.LOOKS) do
    local f = theme.fonts.ui
    local bw = f:getWidth(look.name) + 26
    if cx + bw > x + w then cx, cy = x, cy + 36 end
    local selected = (p.look == look.name) or (look.name == "None" and not anyOn)
    local id = "cw:fxl:" .. i
    local hov, clicked = ui.interact(id, cx, cy, bw, 28)
    local a = ui.getAnim(id)
    a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, ui.dt)
    a.check = damp(a.check, selected and 1 or 0, theme.speedHover, ui.dt)
    if hov then ui.cursor = "hand" end
    ui.color(ui.mix(ui.mix(theme.input, theme.inputHover, a.hover), theme.accent, a.check * 0.85))
    ui.rect("fill", cx, cy, bw, 28, 14)
    ui.label(look.name, cx, cy, { w = bw, h = 28, align = "center", color = selected and { 1, 1, 1, 1 } or theme.text })
    if clicked then
      local np = theme.deepcopy(look.post)
      for k, v in pairs(postfx.DEFAULTS) do if np[k] == nil then np[k] = v end end
      np.look = look.name
      E.post = np
      p = np
      apply()
    end
    cx = cx + bw + 8
  end
  y = cy + 46

  -- fine tuning: 0 = off; the extra knob for an effect only shows once it's on
  local function fx(label, key, min, max, opt)
    opt = opt or {}
    opt.label, opt.labelW = label, 170
    local v, changed = W.slider("cw:fx:" .. key, p[key], min, max, x, y, w, opt)
    if changed then p[key] = v p.look = nil apply() end
    y = y + 34
  end
  local pct = function(v) return v <= 0 and "off" or (math.floor(v * 100 + 0.5) .. "%") end
  local num = function(v) return v <= 0 and "off" or string.format("%.1f", v) end

  y = W.section("Light", x, y, w)
  fx("Bloom", "bloom", 0, 10, { format = num, tooltip = "Bright things glow: the timer, deltas, highlights" })
  if p.bloom > 0 then fx("    Glow from", "bloomThreshold", 0.1, 0.95, { format = function(v) return math.floor(v * 100) .. "% bright" end,
    tooltip = "Lower = more of the screen glows" }) end
  fx("Light rays", "rays", 0, 1, { format = pct, tooltip = "Soft rays shining out from the timer" })
  y = y + 4

  y = W.section("Film", x, y, w)
  fx("Film grain", "grain", 0, 0.6, { format = pct })
  if p.grain > 0 then fx("    Grain size", "grainSize", 1, 4, { format = function(v) return string.format("%.1f", v) end }) end
  fx("Chromatic aberration", "chroma", 0, 4, { format = function(v) return v <= 0 and "off" or string.format("%.1f px", v) end,
    tooltip = "Colour fringes, like a lens" })
  fx("Warmth", "warmth", -1, 1, { format = function(v)
    if math.abs(v) < 0.02 then return "off" end
    return (v > 0 and "warm " or "cool ") .. math.floor(math.abs(v) * 100 + 0.5) .. "%" end })
  fx("Desaturate", "desaturate", 0, 1, { format = pct })
  y = y + 4

  y = W.section("Retro", x, y, w)
  fx("CRT curve", "crt", 0, 1, { format = pct, tooltip = "Bends the picture like an old monitor" })
  fx("Scanlines", "scanlines", 0, 1, { format = pct })
  if p.scanlines > 0 then fx("    Line width", "scanlineWidth", 1, 4, { step = 1, format = function(v) return math.floor(v) .. " px" end }) end
  fx("Pixelate", "pixelate", 0, 8, { step = 1, format = function(v) return v < 1 and "off" or (math.floor(v) .. " px") end })
  fx("Posterize", "posterize", 0, 12, { step = 1, format = function(v) return v < 2 and "off" or (math.floor(v) .. " levels") end })
  rowLabel("Game Boy palette", x, y)
  local pal = {}
  for _, name in ipairs(postfx.PALETTES) do pal[#pal + 1] = { value = name, label = name == "off" and "Off" or name:gsub("_", " ") } end
  local v, changed = ui.dropdown("cw:fx:gb", pal, p.gameboy, x + w - 200, y - 1, 200, 28)
  if changed then p.gameboy = v p.look = nil apply() end
  y = y + 40
  return y
end

local wsSort, wsQuery, wsSelected = "top", "", nil

function tabDraw.workshop(x, y, w, t)
  if not cw.wsOpened then cw.wsOpened = true workshop.open() end

  -- search / sort / refresh
  local sw = math.min(240, w - 330)
  wsQuery = ui.textbox("cw:ws:q", wsQuery, x, y, sw, 28, { placeholder = "Search looks or authors…" })
  local sel, ch = ui.segmented("cw:ws:sort", { { value = "top", label = "Top" }, { value = "new", label = "New" } }, wsSort,
    x + sw + 10, y, 140, 28)
  if ch then wsSort = sel end
  if ui.button("cw:ws:refresh", workshop.status == "loading" and "Loading…" or "Refresh", x + w - 100, y, 100, 28,
      { disabled = workshop.status == "loading" }) then workshop.refresh() end
  y = y + 40

  -- status
  local note
  if workshop.status == "loading" and not workshop.looks then note = "Loading the workshop…"
  elseif workshop.status == "error" then note = workshop.error or "Couldn't reach the workshop."
  elseif workshop.status == "offline" then note = "Showing the list from last time (" .. (workshop.error or "offline") .. ")." end
  if note then
    ui.label(note, x, y, { w = w, color = workshop.status == "error" and theme.behindLose or theme.textDim })
    y = y + 26
  end

  -- cards
  local list = workshop.list(wsSort, wsQuery)
  if workshop.looks and #list == 0 then
    ui.label(wsQuery ~= "" and ("Nothing matches “" .. wsQuery .. "”.") or "No looks shared yet: be the first! (Looks tab → Share to workshop)",
      x, y, { w = w, color = theme.textFaint })
    y = y + 30
  end
  local cols, cgap = 3, 14
  local cardW = math.floor((w - cgap * (cols - 1)) / cols)
  local miniH, cardH = 92, 92 + 50
  for i, e in ipairs(list) do
    local col, row = (i - 1) % cols, math.floor((i - 1) / cols)
    local cx, cy = x + col * (cardW + cgap), y + row * (cardH + cgap)
    local selected = wsSelected == e.id
    local _, clicked, _, lift = W.card("cw:ws:card:" .. e.id, cx, cy, cardW, cardH, selected)
    drawMini(e.style, cx + 6, cy + 6 - lift, cardW - 12, miniH - 6, t + i)
    local nf = theme.fonts.uiBold:getWidth(e.name) <= cardW - 20 and theme.fonts.uiBold or theme.fonts.ui
    ui.label(ui.ellipsize(nf, e.name, cardW - 20), cx + 10, cy + miniH - lift, { h = 24, font = nf })
    ui.label(ui.ellipsize(theme.fonts.small, "by " .. e.author, cardW - 60), cx + 10, cy + miniH + 20 - lift,
      { h = 18, font = theme.fonts.small, color = theme.textDim })
    ui.label("♥ " .. e.votes, cx + cardW - 54, cy + miniH + 20 - lift, { h = 18, w = 44, align = "right", font = theme.fonts.small, color = theme.accent })
    if clicked then
      wsSelected = e.id
      local pic, dim = E.background.image, E.background.imageDim
      E = theme.deepcopy(e.style)
      E.background.image, E.background.imageDim = pic, dim or E.background.imageDim   -- your picture stays
      apply()
    end
  end
  y = y + math.ceil(#list / cols) * (cardH + cgap)

  -- the selected look
  local chosen
  for _, e in ipairs(list) do if e.id == wsSelected then chosen = e end end
  if chosen then
    y = W.section("Selected", x, y + 4, w)
    ui.label(chosen.name .. "  ·  by " .. chosen.author .. "  ·  ♥ " .. chosen.votes, x, y, { h = 30, w = w - 290 })
    if ui.button("cw:ws:install", "Save to my looks", x + w - 280, y, 150, 30, { primary = true }) then
      local name = chosen.name
      if presets.isBuiltin(name) or presets.exists(name) then name = name .. " (" .. chosen.author .. ")" end
      if presets.saveUser(chosen.style, name) then say("Saved “" .. name .. "” to your looks") end
    end
    if chosen.page and ui.button("cw:ws:page", "Vote / page", x + w - 120, y, 120, 30,
        { tooltip = "Opens its GitHub page: a 👍 there is a vote" }) then
      pcall(love.system.openURL, chosen.page)
    end
    y = y + 44
  end

  -- where the workshop lives (a setting)
  y = W.section("Workshop source", x, y + 4, w)
  ui.label("GitHub repo", x, y, { h = 28 })
  local v, _, committed = ui.textbox("cw:ws:repo", workshop.repo, x + 120, y, w - 120, 28, { placeholder = "owner/musplit-workshop" })
  if committed and v ~= workshop.repo then
    if workshop.setRepo(v) then workshop.refresh() say("Workshop source changed") else dialogs.error("Use the form owner/repo, e.g. you/musplit-workshop") end
  end
  y = y + 36
  ui.label("Looks are shared and voted on through GitHub (free). Pictures aren't shared, only colours, effects and layout.",
    x, y, { w = w, font = theme.fonts.small, color = theme.textFaint })
  return y + 30
end

function tabDraw.sounds(x, y, w)
  E.sounds = E.sounds or theme.deepcopy(theme.DEFAULT_STYLE.sounds)
  local snd = E.sounds
  y = W.section("Sounds", x, y, w)
  y = switchRow("Play sounds", snd, "enabled", x, y, w, "Short sounds when you split, get a gold, a personal best, or reset")
  if not snd.enabled then
    ui.label("Turn sounds on to choose them. You can still try them with the play buttons below.", x, y, { color = theme.textDim })
    y = y + 26
  end
  y = sliderRow("Volume", snd, "volume", 0, 1, x, y, w, { format = function(v) return math.floor(v * 100) .. "%" end })
  y = segmentedRow("Sound pack", snd, "pack", sounds.PACKS, x, y, w)
  y = y + 4
  y = W.section("When to play", x, y, w)
  local rows = {
    { "split", "Split" }, { "gold", "Gold split (best segment)" }, { "pb", "Personal best" }, { "reset", "Reset" },
  }
  for _, r in ipairs(rows) do
    local key, label = r[1], r[2]
    if ui.button("cw:play:" .. key, "Play", x, y - 1, 56, 28, { tooltip = "Hear it" }) then
      presets.use(E)
      sounds.play(key, true)
    end
    local v, changed = W.switch("cw:snd:" .. key, snd[key], x + 66, y, { label = label, w = w - 66 })
    if changed then snd[key] = v apply() end
    y = y + 34
  end
  return y
end

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------
function win:draw(x, y, w, h, dt)
  if not E then return end
  local t = love.timer.getTime()
  local pad = 18
  local navW = 170
  local previewW = math.min(380, math.floor(w * 0.34))
  local footerH = 56

  -- left: tabs
  ui.color(theme.panelAlt) lg.rectangle("fill", x, y, navW, h)
  ui.color(theme.border) lg.rectangle("fill", x + navW - 1, y, 1, h)
  local sel, changed = W.tabs("cw:tabs", TABS, tab, x + 10, y + 14, navW - 20, 38)
  if changed then tab = sel end
  -- current look name at the bottom of the nav
  ui.label("CURRENT LOOK", x + 18, y + h - footerH - 40, { font = theme.fonts.label, color = theme.textFaint })
  ui.label(ui.ellipsize(theme.fonts.uiBold, E.name or "Custom", navW - 30), x + 18, y + h - footerH - 24,
    { font = theme.fonts.uiBold, color = theme.accent })

  -- middle: the tab's settings (scrolls)
  local mx = x + navW + pad
  local mw = w - navW - previewW - pad * 3
  local mh = h - footerH - 10
  self.contentH = self.contentH or {}
  local oy = ui.beginScroll("cw:scroll:" .. tab, mx - 4, y + 6, mw + 12, mh, (self.contentH[tab] or mh) + 20)
  local endY = tabDraw[tab](mx, y + 18 - oy, mw, t)
  self.contentH[tab] = (endY + oy) - (y + 18)
  ui.endScroll()

  -- right: live preview of a demo run
  local px = x + w - previewW - pad
  local py, ph = y + 18, h - footerH - 28
  ui.label("LIVE PREVIEW", px, py - 2, { font = theme.fonts.label, color = theme.textFaint })
  py = py + 16
  ph = ph - 16
  local r = theme.radius + 4
  ui.color(theme.shadow) ui.rect("fill", px + 2, py + 6, previewW, ph, r)
  postfx.wrap("preview", px, py, previewW, ph, function(x2, y2, w2, h2) view.drawPreview(x2, y2, w2, h2, dt) end, view.demo.light)
  lg.setLineWidth(1)
  ui.color(theme.borderLight) ui.rect("line", px + 0.5, py + 0.5, previewW - 1, ph - 1, r)

  -- footer
  local fy = y + h - footerH
  ui.color(theme.border) lg.rectangle("fill", x + navW, fy, w - navW, 1)
  local by = fy + 13
  if ui.button("cw:done", "Done", x + w - pad - 100, by, 100, 30, { primary = true }) then done() end
  if ui.button("cw:cancel", "Cancel", x + w - pad - 208, by, 100, 30, { tooltip = "Go back to the look you had" }) then win:onClose() end
  if ui.button("cw:undo", "Undo", x + navW + pad + 108, by, 80, 30, { disabled = #history == 0, tooltip = "Ctrl+Z" }) then undo() end
  if ui.button("cw:reset", "Reset tab", x + navW + pad, by, 100, 30, { tooltip = "Put this tab back to the look's defaults" }) then
    local base = theme.DEFAULT_STYLE
    for _, p in ipairs(presets.BUILTIN) do if p.name == E.name then base = theme.complete(p) end end
    for _, u in ipairs(presets.user) do if u.name == E.name then base = theme.complete(u) end end
    local map = { colors = "colors", background = "background", effects = "effects", layout = "layout", shaders = "post", sounds = "sounds" }
    if tab == "text" then E.fonts, E.sizes = theme.deepcopy(base.fonts), theme.deepcopy(base.sizes) E.layout.decimals = base.layout.decimals
    elseif map[tab] then E[map[tab]] = theme.deepcopy(base[map[tab]]) end
    apply()
  end

  -- toast
  if toast.t > 0 then
    toast.t = toast.t - dt
    local a = math.min(1, toast.t * 3) * math.min(1, (2.2 - toast.t) * 6)
    local f = theme.fonts.uiBold
    local tw = f:getWidth(toast.text) + 28
    local tx, ty = x + navW + (w - navW - tw) / 2, fy - 44 + (1 - a) * 8
    ui.color(theme.shadow, a) ui.rect("fill", tx + 1, ty + 3, tw, 30, 15)
    ui.color(theme.accent, a) ui.rect("fill", tx, ty, tw, 30, 15)
    ui.label(toast.text, tx, ty, { w = tw, h = 30, align = "center", font = f, color = { 1, 1, 1, a } })
  end
end

-- (tests)
cw.test = { surprise = surprise, undo = undo, history = function() return #history end, edited = function() return E end }

return cw
