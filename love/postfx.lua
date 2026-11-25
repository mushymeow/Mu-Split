-- Shader effects (bloom, film grain, chromatic aberration, CRT, scanlines, light rays,
-- pixelate, posterize, colour grading, Game Boy) over the timer, using moonshine
-- (https://github.com/vrld/moonshine, MIT; build.bat downloads it into love\moonshine).
--
-- Settings live in the look: theme.style.post. Every number is "0 = off", so a look
-- only lists what it uses. Only the timer view and the Customise preview get effects;
-- menus and windows stay sharp (and clickable where you see them).
--
--   postfx.wrap(key, x, y, w, h, drawFn, light)
--     draws drawFn(0, 0, w, h) through the effects at (x, y). key = "main" / "preview"
--     (each has its own canvases). light = { x, y } in 0..1, for the light rays.

local theme = require("theme")
local ui = require("ui")

local P = { available = false, broken = false, chains = {} }
local lg = love.graphics

local okLib, moonshine = pcall(require, "moonshine")
P.available = okLib and type(moonshine) == "table" and moonshine.effects ~= nil
P.disabled = {}          -- effects that failed on this graphics card (the rest keep working)

-- Graphics drivers remove shader variables a shader doesn't use, and LÖVE errors when
-- moonshine then sets one ("Shader uniform 'direction' does not exist"). Setting a
-- variable that isn't there is harmless, so skip it instead of failing.
do
  local ok, probe = pcall(lg.newShader, "vec4 effect(vec4 c, Image t, vec2 tc, vec2 sc) { return Texel(t, tc) * c; }")
  if ok and probe then
    local mt = getmetatable(probe)
    local methods = mt and mt.__index
    if type(methods) == "table" and methods.send and methods.hasUniform and not methods.__musplitSafeSend then
      local send, has = methods.send, methods.hasUniform
      methods.send = function(self, name, ...)
        if not has(self, name) then return end
        return send(self, name, ...)
      end
      methods.__musplitSafeSend = true
    end
    pcall(probe.release, probe)
  end
end

-- order matters: colour work first, then light, then lens/screen effects, grain on top
local ORDER = { "pixelate", "posterize", "dmg", "desaturate", "colorgradesimple", "godsray", "glow",
                "chromasep", "scanlines", "crt", "filmgrain" }

P.DEFAULTS = {
  bloom = 0, bloomThreshold = 0.55,
  rays = 0,
  grain = 0, grainSize = 1,
  chroma = 0,
  warmth = 0, desaturate = 0,
  crt = 0, scanlines = 0, scanlineWidth = 2,
  pixelate = 0, posterize = 0,
  gameboy = "off",
}

P.LOOKS = {
  { name = "None", post = {} },
  { name = "Soft Bloom", post = { bloom = 2.5, bloomThreshold = 0.6 } },
  { name = "Cinematic", post = { bloom = 3, bloomThreshold = 0.55, grain = 0.12, chroma = 0.8, warmth = 0.25 } },
  { name = "Dreamy", post = { bloom = 6, bloomThreshold = 0.35, desaturate = 0.15, warmth = 0.15, rays = 0.35 } },
  { name = "Retro CRT", post = { crt = 0.6, scanlines = 0.45, scanlineWidth = 2, chroma = 1.2, bloom = 3, bloomThreshold = 0.5, grain = 0.08 } },
  { name = "VHS", post = { chroma = 2.4, grain = 0.25, grainSize = 2, scanlines = 0.2, warmth = 0.2, desaturate = 0.2 } },
  { name = "Noir", post = { desaturate = 1, grain = 0.2, bloom = 2, bloomThreshold = 0.6 } },
  { name = "Pixel", post = { pixelate = 3, posterize = 6 } },
  { name = "Game Boy", post = { gameboy = "default", pixelate = 2 } },
}

P.PALETTES = { "off", "default", "dark_yellow", "light_yellow", "green", "greyscale", "stark_bw", "pocket" }

local function settings()
  local s = theme.style and theme.style.post or {}
  local out = {}
  for k, v in pairs(P.DEFAULTS) do out[k] = s[k] == nil and v or s[k] end
  return out
end

-- which effects a set of settings turns on
local function wanted(s)
  local w = {
    glow = s.bloom > 0,
    godsray = s.rays > 0,
    filmgrain = s.grain > 0,
    chromasep = s.chroma > 0,
    colorgradesimple = s.warmth ~= 0,
    desaturate = s.desaturate > 0,
    crt = s.crt > 0,
    scanlines = s.scanlines > 0,
    pixelate = s.pixelate >= 1,
    posterize = s.posterize >= 2,
    dmg = s.gameboy ~= "off" and s.gameboy ~= nil,
  }
  for name in pairs(P.disabled) do w[name] = false end
  return w
end

function P.active()
  if not P.available or P.broken then return false end
  for _, on in pairs(wanted(settings())) do if on then return true end end
  return false
end

---------------------------------------------------------------------------
-- chains: one per key, holding ONLY the effects in use (each effect is a shader to
-- compile and canvases to keep, so unused ones cost nothing). Rebuilt when the set of
-- effects changes; resized with the area.
---------------------------------------------------------------------------
local function build(w, h, want)
  local chain, names = nil, {}
  for _, name in ipairs(ORDER) do
    if want[name] then
      local ok, res = pcall(function()
        local eff = moonshine.effects[name]
        if chain then return chain.chain(eff) end
        return moonshine(w, h, eff)
      end)
      if ok and res then chain = res names[#names + 1] = name
      else print("[postfx] couldn't load " .. name .. ": " .. tostring(res)) end
    end
  end
  if not chain then return nil end
  return { chain = chain, names = names, sig = table.concat(names, ","), w = w, h = h, out = lg.newCanvas(w, h) }
end

local function signature(want)
  local t = {}
  for _, name in ipairs(ORDER) do if want[name] then t[#t + 1] = name end end
  return table.concat(t, ",")
end

local function getChain(key, w, h, want)
  w, h = math.max(1, math.floor(w)), math.max(1, math.floor(h))
  local c = P.chains[key]
  if not c or c.sig ~= signature(want) then
    c = build(w, h, want)
    P.chains[key] = c
    if not c then return nil end
  elseif c.w ~= w or c.h ~= h then
    pcall(c.chain.resize, w, h)
    c.out = lg.newCanvas(w, h)
    c.w, c.h = w, h
  end
  return c
end

-- free a chain's canvases (the Customise preview, when the window closes)
function P.release(key)
  P.chains[key] = nil
  collectgarbage("step", 200)
end

local function set(c, effect, param, value)
  local e = c.chain[effect]
  if not e then return end
  pcall(function() e[param] = value end)
end

-- push the slider values into the shaders
local function sync(c, s, want, light)
  local t = love.timer.getTime()
  local speed = (theme.style and theme.style.effects.speed) or 1
  if want.glow then
    set(c, "glow", "strength", s.bloom)
    set(c, "glow", "min_luma", s.bloomThreshold)
  end
  if want.godsray then
    set(c, "godsray", "weight", math.min(1, 0.45 * s.rays))
    set(c, "godsray", "decay", 0.94)
    set(c, "godsray", "density", 0.12)
    set(c, "godsray", "light_position", { light and light.x or 0.75, light and light.y or 0.85 })
  end
  if want.filmgrain then
    set(c, "filmgrain", "opacity", s.grain)
    set(c, "filmgrain", "size", s.grainSize)
  end
  if want.chromasep then
    set(c, "chromasep", "radius", s.chroma)
    set(c, "chromasep", "angle", math.sin(t * 0.4 * speed) * 0.6)   -- drifts a little
  end
  if want.colorgradesimple then
    local w = s.warmth
    set(c, "colorgradesimple", "factors", { 1 + 0.14 * w, 1 + 0.02 * w, 1 - 0.14 * w })
  end
  if want.desaturate then set(c, "desaturate", "strength", math.min(1, s.desaturate)) end
  if want.crt then
    set(c, "crt", "distortionFactor", { 1 + 0.10 * s.crt, 1 + 0.11 * s.crt })
    set(c, "crt", "feather", 0.01 + 0.02 * s.crt)
  end
  if want.scanlines then
    set(c, "scanlines", "opacity", s.scanlines)
    set(c, "scanlines", "width", s.scanlineWidth)
    set(c, "scanlines", "phase", t * 2 * speed)                   -- slow roll
  end
  if want.pixelate then set(c, "pixelate", "size", { s.pixelate, s.pixelate }) end
  if want.posterize then set(c, "posterize", "num_bands", math.floor(s.posterize)) end
  if want.dmg then set(c, "dmg", "palette", s.gameboy) end
end

---------------------------------------------------------------------------
-- draw
---------------------------------------------------------------------------
function P.wrap(key, x, y, w, h, drawFn, light)
  if not P.available or P.broken then drawFn(x, y, w, h) return end
  local s = settings()
  local want = wanted(s)
  if signature(want) == "" then
    if P.chains[key] then P.release(key) end
    drawFn(x, y, w, h)
    return
  end
  local c = getChain(key, w, h, want)
  if not c then drawFn(x, y, w, h) return end
  sync(c, s, want, light)

  -- Run the chain at the origin, into our own canvas (moonshine draws its passes with
  -- whatever transform is active, so a translate would push them off its canvases),
  -- then put that canvas where it belongs.
  local depth = lg.getStackDepth()
  local savedClip = ui.clip
  ui.clip = {}                          -- clips inside are in canvas coordinates
  lg.push("all")
  lg.origin()
  lg.setScissor()
  lg.setCanvas(c.out)
  lg.clear(0, 0, 0, 0)
  lg.setColor(1, 1, 1, 1)               -- moonshine presents in the colour set now
  local ok, err = pcall(c.chain.draw, function() drawFn(0, 0, w, h) end)
  while lg.getStackDepth() > depth do lg.pop() end
  ui.clip = savedClip
  if #ui.clip > 0 then local cl = ui.clip[#ui.clip] lg.setScissor(cl[1], cl[2], cl[3], cl[4]) else lg.setScissor() end

  if ok then
    lg.setBlendMode("alpha", "premultiplied")
    lg.setColor(1, 1, 1, 1)
    lg.draw(c.out, x, y)
    lg.setBlendMode("alpha")
    return
  end

  -- an effect this graphics card can't run: switch just that one off and carry on
  err = tostring(err)
  local bad = err:match("moonshine[/%.\\]([%w_]+)%.lua") or err:match("moonshine[/%.\\]([%w_]+)")
  lg.setCanvas()
  lg.setShader()
  if bad and want[bad] then
    P.disabled[bad] = true
    P.failed = (P.failed and (P.failed .. ", ") or "") .. bad
  else
    P.broken = true
  end
  P.error = err
  P.chains = {}
  print("[postfx] " .. (bad and ("turned off " .. bad) or "turned off") .. ": " .. err)
  drawFn(x, y, w, h)
end

return P
