-- Sounds for split / gold split / personal best / reset.
--
-- Every sound is synthesised here (no audio files), in three packs: Soft (sine chimes),
-- Retro (square-wave blips) and Glass (bell tones). Settings live in the look:
-- theme.style.sounds = { enabled, volume, pack, split, gold, pb, reset }.

local theme = require("theme")

local S = { cache = {} }
local RATE = 44100

local function make(duration, fn)
  local n = math.floor(duration * RATE)
  local data = love.sound.newSoundData(n, RATE, 16, 1)
  for i = 0, n - 1 do
    local v = fn(i / RATE, duration)
    data:setSample(i, math.max(-1, math.min(1, v)))
  end
  return love.audio.newSource(data, "static")
end

local TAU = math.pi * 2
local function env(t, attack, decay) -- quick attack, exponential decay
  if t < attack then return t / attack end
  return math.exp(-(t - attack) * decay)
end

-- one voice per pack: (frequency, time) -> sample
local VOICES = {
  soft = function(f, t) return math.sin(TAU * f * t) * 0.8 + math.sin(TAU * f * 2 * t) * 0.12 end,
  retro = function(f, t) return (math.sin(TAU * f * t) >= 0 and 0.45 or -0.45) end,
  glass = function(f, t)
    return math.sin(TAU * f * t) * 0.6 + math.sin(TAU * f * 2.76 * t) * 0.25 * math.exp(-t * 6)
         + math.sin(TAU * f * 5.4 * t) * 0.12 * math.exp(-t * 12)
  end,
}
local DECAY = { soft = 9, retro = 14, glass = 5 }

-- notes: { { freq, start, length } }
local function notes(pack, list, total)
  local voice, decay = VOICES[pack] or VOICES.soft, DECAY[pack] or 9
  return make(total, function(t)
    local v = 0
    for _, nt in ipairs(list) do
      local lt = t - nt[2]
      if lt >= 0 and lt < nt[3] then v = v + voice(nt[1], lt) * env(lt, 0.004, decay) end
    end
    return v * 0.5
  end)
end

local DESIGNS = {
  split = function(p) return notes(p, { { 880, 0, 0.18 } }, 0.2) end,
  gold = function(p) return notes(p, { { 1046.5, 0, 0.35 }, { 1568, 0.07, 0.4 } }, 0.5) end,
  pb = function(p)
    return notes(p, { { 523.25, 0, 0.5 }, { 659.25, 0.11, 0.5 }, { 783.99, 0.22, 0.5 }, { 1046.5, 0.33, 0.9 },
      { 1318.5, 0.33, 0.9 } }, 1.3)
  end,
  reset = function(p)
    local voice, decay = VOICES[p] or VOICES.soft, DECAY[p] or 9
    return make(0.32, function(t)                 -- a little falling sweep
      local f = 520 - 300 * (t / 0.32)
      return voice(f, t) * env(t, 0.004, decay * 0.7) * 0.4
    end)
  end,
}

local function source(pack, name)
  local key = pack .. ":" .. name
  if not S.cache[key] then
    local ok, src = pcall(DESIGNS[name], pack)
    S.cache[key] = ok and src or false
  end
  return S.cache[key] or nil
end

-- play an event's sound if the look has sounds on (preview = play even if switched off)
function S.play(name, preview)
  if not love.audio or not DESIGNS[name] then return end
  local cfg = theme.style and theme.style.sounds or {}
  if not preview and (not cfg.enabled or cfg[name] == false) then return end
  local src = source(cfg.pack or "soft", name)
  if not src then return end
  local s = src:clone()
  s:setVolume(math.max(0, math.min(1, cfg.volume or 0.6)))
  s:play()
end

S.PACKS = { { value = "soft", label = "Soft" }, { value = "retro", label = "Retro" }, { value = "glass", label = "Glass" } }

return S
