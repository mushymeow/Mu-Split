-- Looks: the built-in presets, your saved ones, and the one in use.
--
-- A preset is a style (see theme.lua) saved as JSON, so it can be shared as text:
-- "Copy" puts it on the clipboard, "Paste" reads one back. Files live in LÖVE's save
-- folder (%APPDATA%\LOVE\musplit):
--   style.json          the look in use (restored on start)
--   presets\<name>.json your saved presets

local theme = require("theme")
local json = require("json")

local P = { user = {}, current = nil }

---------------------------------------------------------------------------
-- built-in presets (only what differs from theme.DEFAULT_STYLE)
---------------------------------------------------------------------------
P.BUILTIN = {
  { name = "Mu",
    colors = { bg = "#110f10", surface = "#1b1718", text = "#fff3e6", textDim = "#a8988f",
               accent = "#ff5a1f", accent2 = "#ff2d3f", ahead = "#33d17a", behind = "#ff4d6d",
               gold = "#ffc23d", idle = "#a8988f" },
    background = { mode = "aurora", top = "#26130f", bottom = "#0c0a0b", intensity = 0.5, motion = 0.45,
                   vignette = 0.4, particles = 0.15 },
    effects = { highlight = "pill", timerGlow = 0.65 },
    post = { bloom = 1.8, bloomThreshold = 0.6, grain = 0.05 } },

  { name = "Midnight Aurora",
    colors = { bg = "#0b0e1a", surface = "#141a2b", text = "#e7ecff", textDim = "#8d97b8",
               accent = "#5b8cff", accent2 = "#b26bff", idle = "#8d97b8" },
    background = { mode = "aurora", top = "#121a33", bottom = "#070912", intensity = 0.75, motion = 0.6, vignette = 0.45, particles = 0.5 },
    effects = { highlight = "glow", timerGlow = 0.8 },
    post = { bloom = 3, bloomThreshold = 0.5, grain = 0.06, rays = 0.25 } },

  { name = "Neon",
    colors = { bg = "#07070b", surface = "#101018", text = "#f2f7ff", textDim = "#7e8aa3",
               accent = "#00e5ff", accent2 = "#ff2bd6", ahead = "#39ff88", behind = "#ff3b6b", gold = "#ffe14d" },
    background = { mode = "aurora", top = "#0b0b16", bottom = "#050508", intensity = 0.9, motion = 0.9, vignette = 0.5 },
    fonts = { timer = "Bahnschrift" },
    effects = { highlight = "glow", timerGlow = 1.0 },
    post = { bloom = 5, bloomThreshold = 0.45, chroma = 1.0 } },

  { name = "Sunset",
    colors = { bg = "#170d10", surface = "#22141a", text = "#fff1ea", textDim = "#b89a94",
               accent = "#ff7a45", accent2 = "#ff3d77", idle = "#b89a94" },
    background = { mode = "gradient", top = "#3a1622", bottom = "#120a0d", vignette = 0.4 },
    effects = { highlight = "pill", timerGlow = 0.6 },
    post = { bloom = 2.5, warmth = 0.35, grain = 0.08 } },

  { name = "Forest",
    colors = { bg = "#0c120e", surface = "#141d17", text = "#e8f3ea", textDim = "#8fa596",
               accent = "#4cd38a", accent2 = "#b5e655", idle = "#8fa596" },
    background = { mode = "gradient", top = "#16261b", bottom = "#090d0a", vignette = 0.4 },
    effects = { highlight = "bar", timerGlow = 0.4 } },

  { name = "Sakura",
    colors = { bg = "#fff5f8", surface = "#ffffff", text = "#3a2a33", textDim = "#9a7f8c",
               accent = "#ff6fa8", accent2 = "#c38bff", ahead = "#1fb86a", behind = "#e23d5c", gold = "#e0a100", idle = "#b49aa6" },
    background = { mode = "gradient", top = "#ffe9f1", bottom = "#fff9fb", vignette = 0 },
    effects = { highlight = "pill", timerGlow = 0.25 } },

  { name = "Paper",
    colors = { bg = "#f4f2ee", surface = "#fbfaf7", text = "#1f1f1f", textDim = "#7c7a75",
               accent = "#2f6bff", accent2 = "#2f6bff", ahead = "#13a35a", behind = "#d93a3a", gold = "#c98a00", idle = "#8c8a85" },
    background = { mode = "solid", vignette = 0 },
    layout = { stripes = false, separators = true, roundness = 4 },
    effects = { highlight = "underline", timerGlow = 0, sparks = false } },

  { name = "Mono",
    colors = { bg = "#000000", surface = "#0d0d0d", text = "#ffffff", textDim = "#8a8a8a",
               accent = "#ffffff", accent2 = "#9a9a9a", ahead = "#ffffff", behind = "#9a9a9a", gold = "#ffffff", idle = "#8a8a8a" },
    background = { mode = "solid", vignette = 0 },
    layout = { stripes = false, progress = false, roundness = 0 },
    effects = { highlight = "bar", timerGlow = 0, sparks = false, confetti = false } },

  { name = "Terminal",
    colors = { bg = "#030803", surface = "#071107", text = "#b6ffb6", textDim = "#4f9a4f",
               accent = "#39ff14", accent2 = "#00c853", ahead = "#39ff14", behind = "#ff5555", gold = "#ffd75f", idle = "#4f9a4f" },
    background = { mode = "gradient", top = "#062006", bottom = "#020502", vignette = 0.6 },
    fonts = { ui = "Consolas", timer = "Consolas", timerBold = true },
    layout = { roundness = 0, stripes = false },
    effects = { highlight = "bar", timerGlow = 0.9 },
    post = { crt = 0.55, scanlines = 0.4, scanlineWidth = 2, bloom = 3, bloomThreshold = 0.45, chroma = 0.8, grain = 0.06 } },

  { name = "GreenSplit",
    colors = { bg = "#121212", surface = "#1b1b1b", text = "#e8e8e8", textDim = "#9b9b9b",
               accent = "#d65db1", accent2 = "#d65db1", idle = "#9b9b9b" },
    background = { mode = "solid", vignette = 0 },
    layout = { roundness = 6 },
    effects = { highlight = "bar", timerGlow = 0, digitRoll = false } },

  { name = "Ocean",
    colors = { bg = "#06141a", surface = "#0c1f27", text = "#e3f6fb", textDim = "#7fa6b2",
               accent = "#22d3ee", accent2 = "#3b82f6", idle = "#7fa6b2" },
    background = { mode = "aurora", top = "#0b2a36", bottom = "#040c10", intensity = 0.6, motion = 0.35, vignette = 0.4, particles = 0.4 },
    effects = { highlight = "pill", timerGlow = 0.6 } },

  { name = "Royal",
    colors = { bg = "#0f0a17", surface = "#1a1226", text = "#f4ecff", textDim = "#a493bd",
               accent = "#ffc83d", accent2 = "#a855f7", gold = "#ffe08a", idle = "#a493bd" },
    background = { mode = "aurora", top = "#24153a", bottom = "#0a0710", intensity = 0.5, motion = 0.3, vignette = 0.5, particles = 0.35 },
    fonts = { timer = "Georgia" },
    effects = { highlight = "pill", timerGlow = 0.5 },
    post = { bloom = 2.5, bloomThreshold = 0.55, grain = 0.1, rays = 0.3 } },
}

---------------------------------------------------------------------------
-- files
---------------------------------------------------------------------------
local fs = love.filesystem
local DIR = "presets"

local function safeName(name)
  local s = tostring(name or "Preset"):gsub("[^%w%-%_ ]", ""):gsub("^%s+", ""):gsub("%s+$", "")
  return s ~= "" and s or "Preset"
end

local function readJson(path)
  if not fs.getInfo(path) then return nil end
  local ok, data = pcall(fs.read, path)
  if not ok or not data then return nil end
  local ok2, t = pcall(json.decode, data)
  return ok2 and type(t) == "table" and t or nil
end

local function writeJson(path, t)
  local ok, err = pcall(fs.write, path, json.encode(t))
  return ok, err
end

function P.loadUser()
  P.user = {}
  P.cache = nil
  if not fs.getInfo(DIR) then fs.createDirectory(DIR) end
  for _, file in ipairs(fs.getDirectoryItems(DIR)) do
    if file:match("%.json$") then
      local t = readJson(DIR .. "/" .. file)
      if t then
        t.name = t.name or file:gsub("%.json$", "")
        P.user[#P.user + 1] = t
      end
    end
  end
  table.sort(P.user, function(a, b) return a.name:lower() < b.name:lower() end)
end

function P.isBuiltin(name)
  for _, p in ipairs(P.BUILTIN) do if p.name == name then return true end end
  return false
end

function P.exists(name)
  for _, p in ipairs(P.user) do if p.name == name then return true end end
  return P.isBuiltin(name)
end

-- every preset (built-ins first), each a full style
function P.all()
  if P.cache then return P.cache end
  local out = {}
  for _, p in ipairs(P.BUILTIN) do out[#out + 1] = { style = theme.complete(p), builtin = true } end
  for _, p in ipairs(P.user) do out[#out + 1] = { style = theme.complete(p), builtin = false } end
  P.cache = out
  return out
end

function P.saveUser(style, name)
  local s = theme.deepcopy(style)
  s.name = name
  local ok, err = writeJson(DIR .. "/" .. safeName(name) .. ".json", s)
  P.loadUser()
  return ok, err
end

function P.deleteUser(name)
  fs.remove(DIR .. "/" .. safeName(name) .. ".json")
  P.loadUser()
end

---------------------------------------------------------------------------
-- the look in use
---------------------------------------------------------------------------
function P.use(style, instant)
  P.current = theme.complete(style)
  theme.apply(P.current, instant)
  P.dirty = true
  P.saveTimer = 0.6        -- write style.json shortly after the last change
end

function P.update(dt)
  if P.dirty then
    P.saveTimer = P.saveTimer - dt
    if P.saveTimer <= 0 then
      writeJson("style.json", P.current)
      P.dirty = false
    end
  end
end

-- switch to another look, keeping your background picture
function P.useLook(style)
  local pic, dim = P.current and P.current.background.image, P.current and P.current.background.imageDim
  local s = theme.deepcopy(style)
  if pic then s.background = s.background or {} s.background.image, s.background.imageDim = pic, dim end
  P.use(s)
  P.rememberForGame()
end

-- F2: the next look in the list (built-ins, then yours)
function P.cycle(dir)
  local all = P.all()
  local idx = 0
  for i, p in ipairs(all) do if p.style.name == (P.current and P.current.name) then idx = i end end
  local nxt = all[((idx - 1 + (dir or 1)) % #all) + 1]
  if nxt then P.useLook(nxt.style) end
  return nxt and nxt.style.name
end

---------------------------------------------------------------------------
-- a look per game (optional): the look you pick while a game's splits are open is
-- remembered for that game, and comes back when you open them again
---------------------------------------------------------------------------
P.gameLooks = { enabled = false, games = {} }
P.currentGame = nil

local function saveGameLooks() writeJson("gamelooks.json", P.gameLooks) end

function P.setPerGame(on)
  P.gameLooks.enabled = on and true or false
  if on then P.rememberForGame() end
  saveGameLooks()
end

function P.rememberForGame()
  local g = P.currentGame
  if not P.gameLooks.enabled or not g or g == "" or not P.current then return end
  P.gameLooks.games[g] = theme.deepcopy(P.current)
  saveGameLooks()
end

-- main.lua: the open splits' game changed
function P.onGame(game)
  if game == P.currentGame then return end
  P.currentGame = game
  if not P.gameLooks.enabled or not game or game == "" then return end
  local st = P.gameLooks.games[game]
  if st then P.use(st) end
end

function P.flush()
  if P.dirty and P.current then writeJson("style.json", P.current) P.dirty = false end
end

function P.startup()
  P.loadUser()
  local gl = readJson("gamelooks.json")
  if gl then P.gameLooks.enabled, P.gameLooks.games = gl.enabled and true or false, gl.games or {} end
  local saved = readJson("style.json")
  P.current = theme.complete(saved or P.BUILTIN[1])
  theme.apply(P.current, true)
end

---------------------------------------------------------------------------
-- sharing (clipboard text; the workshop will use the same format)
---------------------------------------------------------------------------
function P.export(style)
  local s = theme.deepcopy(style)
  s.musplit = 1
  local text = json.encode(s)
  pcall(love.system.setClipboardText, text)
  return text
end

function P.import(text)
  text = text or (love.system.getClipboardText and love.system.getClipboardText()) or ""
  local ok, t = pcall(json.decode, text)
  if not ok or type(t) ~= "table" or (t.colors == nil and t.background == nil and t.effects == nil) then
    return nil, "The clipboard doesn't hold a Mu Split look"
  end
  t.musplit = nil
  t.name = t.name or "Imported"
  return theme.complete(t)
end

return P
