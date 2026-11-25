-- Every colour, font and size the UI uses comes from here.
--
-- The look is a *style*: plain data (colours as "#rrggbb", fonts by name, sizes,
-- layout switches, effects) that presets.lua saves, loads and shares. theme.apply(style)
-- turns it into the T.* values the rest of the app reads (T.bg, T.accent, T.fonts...).
--
-- Colours glide to a new style instead of snapping: theme.update(dt) eases every
-- colour table *in place*, so code holding a reference (theme.accent) sees it move.

local T = {}

local function hex(s, a)
  s = tostring(s or "#ffffff"):gsub("#", "")
  if #s == 3 then s = s:sub(1, 1):rep(2) .. s:sub(2, 2):rep(2) .. s:sub(3, 3):rep(2) end
  local r, g, b = tonumber(s:sub(1, 2), 16), tonumber(s:sub(3, 4), 16), tonumber(s:sub(5, 6), 16)
  return { (r or 255) / 255, (g or 255) / 255, (b or 255) / 255, a or 1 }
end
T.hex = hex

function T.toHex(c)
  local function b(v) return math.max(0, math.min(255, math.floor(v * 255 + 0.5))) end
  return string.format("#%02x%02x%02x", b(c[1]), b(c[2]), b(c[3]))
end

local function mix(a, b, t)
  return { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, a[3] + (b[3] - a[3]) * t, (a[4] or 1) + ((b[4] or 1) - (a[4] or 1)) * t }
end
T.mix = mix

local function luminance(c) return 0.2126 * c[1] + 0.7152 * c[2] + 0.0722 * c[3] end
T.luminance = luminance

local function withAlpha(c, a) return { c[1], c[2], c[3], a } end

---------------------------------------------------------------------------
-- the default style (presets.lua has the rest). Every key a style can have is
-- here, so a preset only needs the keys it changes.
---------------------------------------------------------------------------
T.DEFAULT_STYLE = {
  name = "Mu",
  colors = {
    bg = "#121215", surface = "#1b1b20",
    text = "#ececf1", textDim = "#9a9aa8",
    accent = "#d65db1", accent2 = "#8f6bff",
    ahead = "#2ed573", behind = "#f0434f", gold = "#ffc83d", idle = "#9b9ba6",
  },
  background = {
    mode = "aurora",          -- solid | gradient | aurora
    top = "#1a1420", bottom = "#0e0e12",
    intensity = 0.55,         -- aurora glow strength
    motion = 0.5,             -- how fast the aurora drifts
    vignette = 0.35,
    imageDim = 0.55,
    particles = 0,            -- floating particles (0 = off)          -- your own picture (background.image, in the save folder): how much the colours cover it
  },
  fonts = { ui = "Segoe UI", timer = "Segoe UI", timerBold = true, bold = false },
  sizes = { timer = 56, row = 14, rowH = 30, title = 17, segment = 18 },
  layout = {
    header = true, progress = true, stripes = true, separators = false,
    segmentTimer = true, comparison = true, prevSegment = true, timingMethod = true,
    statusBar = true, timerAlign = "right", decimals = 2, roundness = 8,
    sumOfBest = false, bestPossible = false,
    textShadow = true,        -- a soft 1px shadow behind the timer's text (readable over pictures)
    autosplitterStatus = true, -- status bar: waiting for game / connected / error
    timeSave = false,          -- footer: possible time save (current split, and the whole run)
    subsplits = true,          -- group "-Name" / "{Section} Name" splits into sections
    subsplitsExpand = false,   -- show every section open (not just the current one)
  },
  effects = {
    highlight = "pill",       -- pill | bar | underline | glow | none
    timerGlow = 0.55,
    digitRoll = true,
    splitPop = true,
    sparks = true,            -- gold split sparks
    confetti = true,          -- new personal best
    livePulse = true,
    rowIntro = true,          -- rows slide in after a reset
    speed = 1.0,              -- every animation's speed
  },
  post = {},                  -- shader effects (postfx.lua): bloom, grain, crt... 0 = off
  sounds = { enabled = false, volume = 0.6, pack = "soft", split = true, gold = true, pb = true, reset = false },
}

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deepcopy(v) end
  return c
end
T.deepcopy = deepcopy

-- missing keys come from the default, so old/partial presets always work
function T.complete(style)
  local out = deepcopy(T.DEFAULT_STYLE)
  local function merge(dst, src)
    for k, v in pairs(src or {}) do
      if type(v) == "table" and type(dst[k]) == "table" then merge(dst[k], v) else dst[k] = deepcopy(v) end
    end
  end
  merge(out, style)
  return out
end

---------------------------------------------------------------------------
-- palette: a style's handful of colours → every colour the UI uses
---------------------------------------------------------------------------
local COLOR_KEYS = {
  "bg", "panel", "panelAlt", "input", "inputHover", "border", "borderLight", "hover", "press",
  "selection", "text", "textDim", "textFaint", "accent", "accent2", "accentSoft", "danger", "shadow",
  "aheadGain", "aheadLose", "behindGain", "behindLose", "gold", "notRunning", "paused",
  "bgTop", "bgBottom",
}

local function derive(style)
  local c = style.colors
  local surface, bg = hex(c.surface), hex(c.bg)
  local light = luminance(surface) > 0.5
  local toward = light and { 0, 0, 0, 1 } or { 1, 1, 1, 1 }
  local function shade(amount) return mix(surface, toward, amount) end
  local text, textDim, accent = hex(c.text), hex(c.textDim), hex(c.accent)
  local ahead, behind = hex(c.ahead), hex(c.behind)

  return {
    bg = bg,
    panel = surface,
    panelAlt = shade(0.035),
    input = shade(0.07),
    inputHover = shade(0.11),
    border = shade(0.16),
    borderLight = shade(0.26),
    hover = shade(0.09),
    press = shade(0.14),
    selection = mix(surface, accent, 0.28),
    text = text,
    textDim = textDim,
    textFaint = mix(textDim, surface, 0.45),
    accent = accent,
    accent2 = hex(c.accent2 or c.accent),
    accentSoft = withAlpha(accent, 0.18),
    danger = hex("#e5484d"),
    shadow = { 0, 0, 0, light and 0.18 or 0.45 },
    aheadGain = ahead,
    aheadLose = mix(ahead, text, 0.38),
    behindGain = mix(behind, text, 0.38),
    behindLose = behind,
    gold = hex(c.gold),
    notRunning = hex(c.idle or c.textDim),
    paused = mix(textDim, surface, 0.35),
    bgTop = hex(style.background.top or c.bg),
    bgBottom = hex(style.background.bottom or c.bg),
  }
end

-- the live colour tables (everyone holds references to these)
for _, k in ipairs(COLOR_KEYS) do T[k] = { 0, 0, 0, 1 } end
local target = {}

---------------------------------------------------------------------------
-- shape and motion (shape follows the style's roundness)
---------------------------------------------------------------------------
T.radius       = 6
T.radiusSmall  = 4
T.pad          = 12
T.rowH         = 30
T.menuItemH    = 26
T.menuW        = 210
T.controlH     = 28
T.tableRowH    = 26

-- higher = snappier; everything eases with exponential damping (frame-rate independent)
T.speedHover  = 18
T.speedOpen   = 22
T.speedScroll = 16
T.speedTimer  = 14
T.speedTheme  = 9     -- colour cross-fade when the style changes

---------------------------------------------------------------------------
-- fonts: Windows fonts by family name, LÖVE's default font as the fallback
---------------------------------------------------------------------------
local FONT_DIR = "C:/Windows/Fonts/"
T.FONT_FAMILIES = {
  { name = "Segoe UI",        regular = { "segoeui.ttf" },  bold = { "seguisb.ttf", "segoeuib.ttf" } },
  { name = "Bahnschrift",     regular = { "bahnschrift.ttf" }, bold = { "bahnschrift.ttf" } },
  { name = "Consolas",        regular = { "consola.ttf" },  bold = { "consolab.ttf" } },
  { name = "Cascadia",        regular = { "CascadiaMono.ttf", "CascadiaCode.ttf", "consola.ttf" },
                              bold = { "CascadiaMono.ttf", "CascadiaCode.ttf", "consolab.ttf" } },
  { name = "Arial",           regular = { "arial.ttf" },    bold = { "arialbd.ttf" } },
  { name = "Verdana",         regular = { "verdana.ttf" },  bold = { "verdanab.ttf" } },
  { name = "Trebuchet",       regular = { "trebuc.ttf" },   bold = { "trebucbd.ttf" } },
  { name = "Tahoma",          regular = { "tahoma.ttf" },   bold = { "tahomabd.ttf" } },
  { name = "Georgia",         regular = { "georgia.ttf" },  bold = { "georgiab.ttf" } },
  { name = "Franklin Gothic", regular = { "framd.ttf" },    bold = { "framd.ttf" } },
  { name = "Impact",          regular = { "impact.ttf" },   bold = { "impact.ttf" } },
  { name = "Lucida Console",  regular = { "lucon.ttf" },    bold = { "lucon.ttf" } },
  { name = "Comic Sans",      regular = { "comic.ttf" },    bold = { "comicbd.ttf" } },
  { name = "Default",         regular = {},                 bold = {} },
}
local familyByName = {}
for _, f in ipairs(T.FONT_FAMILIES) do familyByName[f.name] = f end
function T.fontNames()
  local t = {}
  for _, f in ipairs(T.FONT_FAMILIES) do t[#t + 1] = f.name end
  return t
end

local fileCache = {}     -- path -> FileData | false
local function fileData(path)
  if fileCache[path] ~= nil then return fileCache[path] or nil end
  local fd = false
  local f = io.open(path, "rb")
  if f then
    local data = f:read("*a")
    f:close()
    local ok, res = pcall(love.filesystem.newFileData, data, path:match("[^/]+$"))
    if ok then fd = res end
  end
  fileCache[path] = fd
  return fd or nil
end

-- Linux: the same fonts if they're installed (ttf-mscorefonts...), else close matches
local LINUX_FALLBACK = {
  sans = { regular = { "NotoSans-Regular.ttf", "Inter-Regular.ttf", "Cantarell-Regular.otf", "DejaVuSans.ttf", "LiberationSans-Regular.ttf" },
           bold = { "NotoSans-SemiBold.ttf", "NotoSans-Bold.ttf", "Inter-SemiBold.ttf", "Cantarell-Bold.otf", "DejaVuSans-Bold.ttf", "LiberationSans-Bold.ttf" } },
  mono = { regular = { "DejaVuSansMono.ttf", "NotoSansMono-Regular.ttf", "LiberationMono-Regular.ttf" },
           bold = { "DejaVuSansMono-Bold.ttf", "NotoSansMono-Bold.ttf", "LiberationMono-Bold.ttf" } },
  serif = { regular = { "DejaVuSerif.ttf", "NotoSerif-Regular.ttf", "LiberationSerif-Regular.ttf" },
            bold = { "DejaVuSerif-Bold.ttf", "NotoSerif-Bold.ttf", "LiberationSerif-Bold.ttf" } },
}
local LINUX_KIND = { Consolas = "mono", Cascadia = "mono", ["Lucida Console"] = "mono", Georgia = "serif" }
local linuxFonts   -- file name -> full path, from fc-list
local function linuxFontPath(file)
  if not linuxFonts then
    linuxFonts = {}
    local p = io.popen("fc-list --format '%{file}\\n' 2>/dev/null")
    if p then
      for path in p:lines() do local n = path:match("[^/]+$") if n and not linuxFonts[n] then linuxFonts[n] = path end end
      p:close()
    end
  end
  return linuxFonts[file]
end

local function familyData(family, bold)
  local fam = familyByName[family] or familyByName["Segoe UI"]
  if fam.name == "Default" then return nil end
  if love.system.getOS() ~= "Windows" then
    local files = {}
    for _, f in ipairs(bold and fam.bold or fam.regular) do files[#files + 1] = f end
    local fb = LINUX_FALLBACK[LINUX_KIND[fam.name] or "sans"]
    for _, f in ipairs(bold and fb.bold or fb.regular) do files[#files + 1] = f end
    for _, f in ipairs(files) do
      local path = linuxFontPath(f)
      local fd = path and fileData(path)
      if fd then return fd end
    end
    return nil
  end
  for _, file in ipairs(bold and fam.bold or fam.regular) do
    local fd = fileData(FONT_DIR .. file)
    if fd then return fd end
  end
  if fam.name ~= "Segoe UI" then return familyData("Segoe UI", bold) end
  return nil
end

-- Fonts are textures, and LÖVE rebuilds every texture when the OS window changes size
-- (which windows.lua does), so fonts nobody has asked for in a while are let go.
local fontCache, fontUsed = {}, {}
local fontClock = 0
-- T.font(size, kind, family): kind "regular" | "semibold"/"bold"
function T.font(size, kind, family)
  family = family or (T.style and T.style.fonts.ui) or "Segoe UI"
  local bold = kind == "semibold" or kind == "bold"
  size = math.max(4, math.floor(size + 0.5))
  local key = family .. (bold and "|b|" or "|r|") .. size
  fontUsed[key] = fontClock
  if fontCache[key] then return fontCache[key] end
  local fd = familyData(family, bold)
  local ok, font = false, nil
  if fd then ok, font = pcall(love.graphics.newFont, fd, size) end
  if not ok or not font then font = love.graphics.newFont(size) end
  font:setFilter("linear", "linear")
  fontCache[key] = font
  return font
end

function T.loadFonts()
  local st = T.style or T.complete({})
  local ui, tf, sz = st.fonts.ui, st.fonts.timer, st.sizes
  local tk = st.fonts.timerBold and "semibold" or "regular"
  local tx = st.fonts.bold and "semibold" or "regular"     -- "Bold text": splits, category, info
  T.fonts = {
    ui       = T.font(13, "regular", ui),
    uiBold   = T.font(13, "semibold", ui),
    small    = T.font(11, "regular", ui),
    title    = T.font(15, "semibold", ui),
    header   = T.font(12, "semibold", ui),
    -- timer view
    game     = T.font(sz.title, "semibold", ui),
    category = T.font(12, tx, ui),
    row      = T.font(sz.row, tx, ui),
    rowBold  = T.font(sz.row, "semibold", ui),
    big      = T.font(sz.timer, tk, tf),
    bigDec   = T.font(math.floor(sz.timer * 0.6), tk, tf),
    seg      = T.font(sz.segment, tx, tf),
    label    = T.font(10, "semibold", ui),
  }
end

---------------------------------------------------------------------------
-- apply / animate
---------------------------------------------------------------------------
T.revision = 0          -- bumps on every apply (cached gradients etc. rebuild)

function T.apply(style, instant)
  T.style = T.complete(style)
  local pal = derive(T.style)
  for _, k in ipairs(COLOR_KEYS) do
    target[k] = pal[k]
    if instant then for i = 1, 4 do T[k][i] = pal[k][i] or 1 end end
  end
  local r = T.style.layout.roundness or 6
  T.radius = math.max(0, math.min(16, r))
  T.radiusSmall = math.max(0, math.min(12, math.floor(r * 0.6 + 0.5)))
  T.rowH = T.style.sizes.rowH
  T.revision = T.revision + 1
  if love and love.graphics and love.graphics.newFont then T.loadFonts() end
end

local sweepTimer = 0
local function sweepFonts(dt)
  fontClock = fontClock + dt
  sweepTimer = sweepTimer + dt
  if sweepTimer < 5 then return end
  sweepTimer = 0
  local keep = {}
  for _, f in pairs(T.fonts or {}) do keep[f] = true end
  local dropped = false
  for key, font in pairs(fontCache) do
    if not keep[font] and fontClock - (fontUsed[key] or 0) > 20 then
      font:release()
      fontCache[key], fontUsed[key] = nil, nil
      dropped = true
    end
  end
  if dropped then collectgarbage("step", 200) end
end

-- eases every colour toward the style's; true while still moving
function T.update(dt)
  sweepFonts(dt)
  local k = 1 - math.exp(-T.speedTheme * dt)
  local moving = false
  for name, tgt in pairs(target) do
    local cur = T[name]
    for i = 1, 4 do
      local want = tgt[i] or 1
      local d = want - cur[i]
      if d > 0.0005 or d < -0.0005 then cur[i] = cur[i] + d * k moving = true else cur[i] = want end
    end
  end
  return moving
end

T.apply(T.DEFAULT_STYLE, true)

return T
