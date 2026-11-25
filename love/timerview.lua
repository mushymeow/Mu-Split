-- The timer + split list.
--
-- Data (from the engine) and drawing are separate: a "view state" holds the latest
-- snapshot, the smooth clock and the animations. The real timer uses V.main; the
-- Customise window's preview draws V.demo, a fake run that splits every few seconds.
--
-- Everything visual follows theme.style (layout switches, effects, sizes); every
-- animation is time-based (exponential damping / timers), so it's smooth at any FPS.

local theme = require("theme")
local ui = require("ui")

local V = {}
local lg = love.graphics
local damp = ui.damp

local function newState()
  return {
    S = nil,
    clock = { base = 0, offset = nil, running = false, key = nil, shown = 0 },
    anim = { hlY = 0, hlA = 0, scroll = 0, flash = {}, sparked = {}, timerCol = nil, progress = 0,
             intro = 1, roll = {}, sig = nil, ended = false, shine = 0 },
    fx = {},                -- particles
    lastPhase = nil, lastIndex = nil, recvMs = nil,
  }
end
V.main = newState()
V.demo = newState()

local function clamp(v, a, b) return v < a and a or (v > b and b or v) end
local function easeOut(t) t = clamp(t, 0, 1) return 1 - (1 - t) ^ 3 end
local function nowMs() return love.timer.getTime() * 1000 end

---------------------------------------------------------------------------
-- formatting
---------------------------------------------------------------------------
function V.fmtTime(ms, dec)
  if ms == nil then return "-" end
  dec = dec or 2
  local neg = ms < 0
  ms = math.abs(ms)
  local total = ms / 1000
  local h = math.floor(total / 3600)
  local m = math.floor(total / 60) % 60
  local factor = 10 ^ dec
  local s = math.floor((total % 60) * factor) / factor  -- truncate, never round up to 60
  local sPad = dec > 0 and ("%0" .. (dec + 3) .. "." .. dec .. "f") or "%02d"
  local str
  if h > 0 then str = string.format("%d:%02d:" .. sPad, h, m, s)
  elseif m > 0 then str = string.format("%d:" .. sPad, m, s)
  else str = string.format("%." .. dec .. "f", s) end
  return (neg and "-" or "") .. str
end
local fmtTime = V.fmtTime

local function fmtDelta(ms)
  if ms == nil then return "" end
  return (ms < 0 and "-" or "+") .. fmtTime(math.abs(ms), 1)
end
V.fmtDelta = fmtDelta

local function deltaColor(delta, prevDelta)
  local ahead = delta < 0
  -- (not "a and b or c": when ahead is false that falls through to comparing with nil)
  local gaining
  if prevDelta == nil then gaining = ahead else gaining = delta < prevDelta end
  if ahead then return gaining and theme.aheadGain or theme.aheadLose end
  return gaining and theme.behindGain or theme.behindLose
end

-- digits in fixed-width cells so numbers never wobble
local function monoWidth(font, text)
  local dw, w = font:getWidth("0"), 0
  for ch in text:gmatch(".") do w = w + (ch:match("%d") and dw or font:getWidth(ch)) end
  return w
end
V.monoWidth = monoWidth

-- text shadow (Layout → Text shadow): while the timer view draws, every lg.print and
-- drawMono draws a soft offset copy first, in a colour that suits the look
local shadowOn, shadowCol = false, { 0, 0, 0, 0.6 }
local rawPrint = lg.print
local function sPrint(text, x, y, ...)
  if shadowOn then
    local r, g, b, a = lg.getColor()
    lg.setColor(shadowCol[1], shadowCol[2], shadowCol[3], shadowCol[4] * a)
    rawPrint(text, x + 1, y + 1, ...)
    lg.setColor(r, g, b, a)
  end
  rawPrint(text, x, y, ...)
end

local function drawMono(font, text, xRight, y)
  lg.setFont(font)
  local dw = font:getWidth("0")
  local x = xRight - monoWidth(font, text)
  local left = x
  for ch in text:gmatch(".") do
    local cw = ch:match("%d") and dw or font:getWidth(ch)
    sPrint(ch, math.floor(x + (cw - font:getWidth(ch)) / 2), math.floor(y))
    x = x + cw
  end
  return left
end
V.drawMono = drawMono

---------------------------------------------------------------------------
-- clock: the engine owns the time, we only display it.
-- Each snapshot gives the engine's time; (our clock - its time) is the offset plus
-- network delay. The smallest offset seen is the least-delayed one, so we track
-- that: the display never jitters and never runs backwards.
---------------------------------------------------------------------------
function V.onState(s)
  local st = V.main
  local c = st.clock
  local running = s.phase == "Running" and not (s.method == "game" and s.gameTimePaused)
  local base = s.time or 0
  local key = tostring(s.phase) .. "|" .. tostring(s.method) .. "|" .. tostring(s.gameTimePaused)

  if running then
    local o = nowMs() - base
    if not c.running or c.key ~= key or c.offset == nil then
      c.offset = o                                   -- start / resume / switched timing method
      c.shown = base
    elseif math.abs(o - c.offset) > 60 then
      c.offset = o                                   -- the time jumped (offset edit, undo pauses...)
      if base < c.shown then c.shown = base end
    elseif o < c.offset then
      c.offset = o                                   -- a less delayed sample
    else
      c.offset = c.offset + math.min(o - c.offset, 0.02)   -- creep for clock drift
    end
  end
  c.base, c.running, c.key = base, running, key
  st.recvMs = nowMs()

  if s.event == "split" and s.index then st.anim.flash[s.index] = 1 end  -- row just completed (1-based)

  -- sounds (main.lua sets V.onEvent): gold split / split / personal best / reset
  if V.onEvent then
    if s.event == "split" and s.index and s.segments then
      local rows, info = V.buildRows(s, base)   -- (defined below)
      if s.phase == "Ended" and (info.finalComp == nil or (info.finalSplit and info.finalSplit < info.finalComp)) then
        V.onEvent("pb")
      elseif rows[s.index] and rows[s.index].gold then V.onEvent("gold")
      else V.onEvent("split") end
    elseif st.lastPhase and st.lastPhase ~= "NotRunning" and s.phase == "NotRunning" then
      V.onEvent("reset")
    end
  end
  if st.lastPhase and st.lastPhase ~= "NotRunning" and s.phase == "NotRunning" then st.anim.intro = 0 end
  if st.lastPhase == "NotRunning" and s.phase == "Running" then st.anim.scroll = 0 end
  st.lastPhase, st.lastIndex = s.phase, s.index
  st.S = s
  V.S = s
  if V.onStateHook then V.onStateHook(s) end
end

function V.liveTime(st)
  st = st or V.main
  local c = st.clock
  if not c.running then return c.base end
  local t = nowMs() - c.offset
  if t < c.shown then t = c.shown end                -- monotonic while running
  c.shown = t
  return t
end

-- real time (RTA) for when the main display shows game time
function V.realTimeLive()
  local S = V.main.S
  if not S or not S.realTime then return 0 end
  if S.phase ~= "Running" or not V.main.recvMs then return S.realTime end
  return S.realTime + (nowMs() - V.main.recvMs)
end

---------------------------------------------------------------------------
-- derived rows
---------------------------------------------------------------------------
local function buildRows(S, now)
  local rows = {}
  if not S or not S.segments then return rows, {} end
  local idx = S.index or -1
  local active = S.phase == "Running" or S.phase == "Paused"
  local prevSplit, prevValid, prevDelta, lastDelta, lastSegDelta = 0, true, nil, nil, nil
  local prevComp = 0

  for i, seg in ipairs(S.segments) do
    local r = { name = seg.name or "", time = "-", delta = "", deltaCol = theme.textDim, gold = false }
    local done = (i - 1) < idx
    if done then
      if seg.split then
        r.time = fmtTime(seg.split)
        if seg.comp then
          local d = seg.split - seg.comp
          r.delta, r.deltaCol = fmtDelta(d), deltaColor(d, prevDelta)
          lastSegDelta = prevDelta and (d - prevDelta) or d
          prevDelta, lastDelta = d, d
        end
        if prevValid and seg.best and (seg.split - prevSplit) < seg.best then r.gold, r.deltaCol = true, theme.gold end
        prevSplit, prevValid = seg.split, true
      else
        r.time, prevValid = "-", false   -- skipped
      end
    else
      r.time = fmtTime(seg.comp)
      if (i - 1) == idx and active and seg.comp and now > seg.comp then
        local d = now - seg.comp
        r.delta, r.deltaCol, r.live = fmtDelta(d), deltaColor(d, prevDelta), true
      end
    end
    if (i - 1) == idx then r.compSeg = seg.comp and (seg.comp - prevComp) or nil end
    prevComp = seg.comp or prevComp
    rows[i] = r
  end

  -- possible time save: how much each split's PB segment is slower than your best segment
  local saveTotal, saveCur, prevC = 0, nil, 0
  local saveOk = true
  for i, seg in ipairs(S.segments) do
    if seg.comp and seg.best then
      local save = math.max(0, (seg.comp - prevC) - seg.best)
      saveTotal = saveTotal + save
      if (i - 1) == idx then saveCur = save end
    else
      saveOk = false
    end
    prevC = seg.comp or prevC
  end

  -- sum of best, and the best time still possible from here
  local sob, allBest = 0, true
  for _, seg in ipairs(S.segments) do if seg.best then sob = sob + seg.best else allBest = false end end
  local bpt
  if S.phase == "NotRunning" then
    bpt = allBest and sob or nil
  elseif S.phase == "Ended" then
    local last = S.segments[#S.segments]
    bpt = last and last.split
  elseif allBest then
    local base = prevValid and prevSplit or nil
    local curSeg = S.segments[idx + 1]
    if base and curSeg then
      local t = math.max(now, base + curSeg.best)
      for k = idx + 2, #S.segments do t = t + S.segments[k].best end
      bpt = t
    end
  end

  return rows, {
    saveTotal = saveOk and saveTotal or nil,
    saveCur = saveCur,
    sob = allBest and sob or nil,
    bpt = bpt,
    lastDelta = lastDelta,
    prevSeg = lastSegDelta,
    segStart = prevValid and prevSplit or nil,
    currentComp = S.segments[idx + 1] and S.segments[idx + 1].comp,
    finalComp = S.segments[#S.segments] and S.segments[#S.segments].comp,
    finalSplit = S.segments[#S.segments] and S.segments[#S.segments].split,
  }
end
V.buildRows = buildRows

-- LiveSplit subsplit names: "-Name" is a subsplit; "{Section} Name" closes the section
local function cleanName(name)
  name = name or ""
  local sub = name:sub(1, 1) == "-"
  if sub then name = name:sub(2) end
  local section, rest = name:match("^{(.-)}%s*(.*)$")
  if section then return (rest ~= "" and rest or section), sub, section end
  return name, sub, nil
end
V.cleanName = cleanName

-- rows (one per split) -> rows to draw:
--   { r = row, seg = split index, name, header = bool, folded = bool, indent = bool }
function V.displayRows(S, rows, curSeg, subsplits, expandAll)
  local out = {}
  local segs = S.segments or {}
  if not subsplits then
    for i, r in ipairs(rows) do out[#out + 1] = { r = r, seg = i, name = (cleanName(r.name)) } end
    return out
  end
  local i = 1
  while i <= #rows do
    local name, sub = cleanName(segs[i] and segs[i].name or rows[i].name)
    if not sub then
      -- an ordinary split, or a lone "{Section} Name"
      out[#out + 1] = { r = rows[i], seg = i, name = name }
      i = i + 1
    else
      -- a section: subsplits up to (and including) the split that closes it
      local j = i
      while j <= #rows and select(2, cleanName(segs[j] and segs[j].name or "")) do j = j + 1 end
      local last = math.min(j, #rows)
      local lastName, _, section = cleanName(segs[last] and segs[last].name or "")
      section = section or lastName
      local open = expandAll or (curSeg >= i and curSeg <= last)
      out[#out + 1] = { r = rows[last], seg = last, name = section, header = true, folded = not open }
      if open then
        for k = i, last do
          out[#out + 1] = { r = rows[k], seg = k, name = (cleanName(segs[k] and segs[k].name or "")), indent = true }
        end
      end
      i = last + 1
    end
  end
  return out
end

local function timerColor(S, now, info)
  if not S or S.phase == "NotRunning" then return theme.notRunning end
  if S.phase == "Paused" then return theme.paused end
  if S.phase == "Ended" then
    if info.finalComp == nil or now < info.finalComp then return theme.gold end
    return theme.behindLose
  end
  if info.currentComp and now > info.currentComp then return theme.behindLose end
  if info.lastDelta then return info.lastDelta < 0 and theme.aheadGain or theme.behindLose end
  return theme.aheadGain
end
V.timerColor = timerColor

---------------------------------------------------------------------------
-- drawing helpers: gradients, soft glows, particles
---------------------------------------------------------------------------
local quad4, radialImg, vignetteImg

local function gradientRect(x, y, w, h, c1, c2, horizontal, a1, a2)
  if not quad4 then
    quad4 = lg.newMesh({ { 0, 0, 0, 0 }, { 1, 0, 1, 0 }, { 1, 1, 1, 1 }, { 0, 1, 0, 1 } }, "fan", "dynamic")
  end
  a1, a2 = a1 or (c1[4] or 1), a2 or (c2[4] or 1)
  if horizontal then
    quad4:setVertexAttribute(1, 3, c1[1], c1[2], c1[3], a1)
    quad4:setVertexAttribute(2, 3, c2[1], c2[2], c2[3], a2)
    quad4:setVertexAttribute(3, 3, c2[1], c2[2], c2[3], a2)
    quad4:setVertexAttribute(4, 3, c1[1], c1[2], c1[3], a1)
  else
    quad4:setVertexAttribute(1, 3, c1[1], c1[2], c1[3], a1)
    quad4:setVertexAttribute(2, 3, c1[1], c1[2], c1[3], a1)
    quad4:setVertexAttribute(3, 3, c2[1], c2[2], c2[3], a2)
    quad4:setVertexAttribute(4, 3, c2[1], c2[2], c2[3], a2)
  end
  lg.setColor(1, 1, 1, 1)
  lg.draw(quad4, x, y, 0, w, h)
end
V.gradientRect = gradientRect

-- white disc with a soft edge, tinted when drawn: glows and aurora blobs
local function radial()
  if radialImg then return radialImg end
  local n = 128
  local d = love.image.newImageData(n, n)
  d:mapPixel(function(px, py)
    local dx, dy = (px + 0.5) / n * 2 - 1, (py + 0.5) / n * 2 - 1
    local r = math.sqrt(dx * dx + dy * dy)
    local a = clamp(1 - r, 0, 1)
    return 1, 1, 1, a * a * (3 - 2 * a)
  end)
  radialImg = lg.newImage(d)
  radialImg:setFilter("linear", "linear")
  return radialImg
end

local function vignette()
  if vignetteImg then return vignetteImg end
  local n = 128
  local d = love.image.newImageData(n, n)
  d:mapPixel(function(px, py)
    local dx, dy = (px + 0.5) / n * 2 - 1, (py + 0.5) / n * 2 - 1
    local r = math.sqrt(dx * dx * 0.8 + dy * dy * 0.8)
    local a = clamp((r - 0.45) / 0.75, 0, 1)
    return 0, 0, 0, a * a
  end)
  vignetteImg = lg.newImage(d)
  vignetteImg:setFilter("linear", "linear")
  return vignetteImg
end

local function glow(cx, cy, w, h, c, a)
  if a <= 0.002 then return end
  ui.color(c, a)
  local img = radial()
  lg.draw(img, cx - w / 2, cy - h / 2, 0, w / img:getWidth(), h / img:getHeight())
end
V.glow = glow

-- particles -----------------------------------------------------------------
local function spawnSparks(st, x, y, c, n)
  for _ = 1, n do
    local ang = love.math.random() * math.pi * 2
    local sp = 60 + love.math.random() * 160
    st.fx[#st.fx + 1] = { kind = "spark", x = x, y = y, vx = math.cos(ang) * sp, vy = math.sin(ang) * sp - 40,
      life = 0.5 + love.math.random() * 0.5, age = 0, c = c, size = 1.5 + love.math.random() * 1.5 }
  end
end

local function spawnConfetti(st, x, y, w)
  local cols = { theme.accent, theme.accent2, theme.gold, theme.aheadGain, theme.text }
  for _ = 1, 110 do
    st.fx[#st.fx + 1] = { kind = "confetti", x = x + love.math.random() * w, y = y - love.math.random() * 60,
      vx = (love.math.random() - 0.5) * 80, vy = 40 + love.math.random() * 120,
      rot = love.math.random() * 6.28, vr = (love.math.random() - 0.5) * 10,
      life = 2.2 + love.math.random() * 1.6, age = 0, c = cols[love.math.random(#cols)],
      size = 3 + love.math.random() * 4, wob = love.math.random() * 6.28 }
  end
end

local function updateDrawFx(st, dt, x, y, w, h)
  local fx = st.fx
  local i = 1
  while i <= #fx do
    local p = fx[i]
    p.age = p.age + dt
    if p.age >= p.life or #fx > 400 then
      fx[i] = fx[#fx]
      fx[#fx] = nil
    else
      if p.kind == "spark" then
        p.vy = p.vy + 260 * dt
        p.vx, p.vy = p.vx * (1 - 2 * dt), p.vy * (1 - 2 * dt)
      else
        p.vy = math.min(p.vy + 90 * dt, 180)
        p.wob = p.wob + dt * 4
        p.rot = p.rot + p.vr * dt
      end
      p.x, p.y = p.x + p.vx * dt + (p.kind == "confetti" and math.sin(p.wob) * 20 * dt or 0), p.y + p.vy * dt
      i = i + 1
    end
  end
  if #fx == 0 then return end
  ui.pushClip(x, y, w, h)
  for _, p in ipairs(fx) do
    local a = 1 - (p.age / p.life) ^ 2
    if p.kind == "spark" then
      ui.color(p.c, a)
      lg.setLineWidth(p.size)
      lg.line(p.x, p.y, p.x - p.vx * 0.04, p.y - p.vy * 0.04)
    else
      ui.color(p.c, a)
      lg.push()
      lg.translate(p.x, p.y)
      lg.rotate(p.rot)
      lg.rectangle("fill", -p.size / 2, -p.size * 0.3, p.size, p.size * 0.6 * math.abs(math.cos(p.wob)) + 0.5)
      lg.pop()
    end
  end
  lg.setLineWidth(1)
  ui.popClip()
end

---------------------------------------------------------------------------
-- background
---------------------------------------------------------------------------
-- your own background picture, loaded once per path (from LÖVE's save folder)
local pictures = {}
function V.picture(path)
  if not path or path == "" then return nil end
  local p = pictures[path]
  if p == nil then
    local ok, img = pcall(lg.newImage, path)
    p = ok and img or false
    if p then p:setFilter("linear", "linear") end
    pictures[path] = p
  end
  return p or nil
end

function V.drawBackground(x, y, w, h, t)
  local bgs = theme.style.background
  local fx = theme.style.effects
  local pic = V.picture(bgs.image)
  if pic then
    -- cover the area (crop, keep proportions), then the look's colours over it
    local iw, ih = pic:getWidth(), pic:getHeight()
    local sc = math.max(w / iw, h / ih)
    ui.pushClip(x, y, w, h)
    lg.setColor(1, 1, 1, 1)
    lg.draw(pic, x + (w - iw * sc) / 2, y + (h - ih * sc) / 2, 0, sc, sc)
    ui.popClip()
    local dim = bgs.imageDim or 0.55
    if bgs.mode == "solid" then ui.color(theme.bg, dim) lg.rectangle("fill", x, y, w, h)
    else gradientRect(x, y, w, h, theme.bgTop, theme.bgBottom, false, dim, math.min(1, dim + 0.15)) end
  elseif bgs.mode == "solid" then
    ui.color(theme.bg) lg.rectangle("fill", x, y, w, h)
  else
    gradientRect(x, y, w, h, theme.bgTop, theme.bgBottom)
  end
  if bgs.mode ~= "solid" then
    if bgs.mode == "aurora" then
      local m = t * (bgs.motion or 0.5) * (fx.speed or 1)
      local inten = bgs.intensity or 0.5
      local big = math.max(w, h)
      local light = theme.luminance(theme.panel) > 0.5
      local amul = light and 0.35 or 0.55
      glow(x + w * (0.22 + 0.18 * math.sin(m * 0.31)), y + h * (0.18 + 0.12 * math.cos(m * 0.23)),
        big * 1.25, big * 0.95, theme.accent, inten * 0.42 * amul)
      glow(x + w * (0.82 + 0.14 * math.cos(m * 0.27)), y + h * (0.55 + 0.2 * math.sin(m * 0.19)),
        big * 1.1, big * 1.2, theme.accent2, inten * 0.38 * amul)
      glow(x + w * (0.45 + 0.3 * math.sin(m * 0.17 + 2)), y + h * (0.95 + 0.06 * math.cos(m * 0.29)),
        big * 1.0, big * 0.6, ui.mix(theme.accent, theme.accent2, 0.5), inten * 0.3 * amul)
    end
  end
  -- floating particles: drift up slowly, sway, twinkle (positions come from the index,
  -- so there's nothing to store and they look the same every frame)
  local amount = bgs.particles or 0
  if amount > 0 then
    local n = math.floor(70 * amount)
    local m = t * (0.4 + (bgs.motion or 0.5)) * (fx.speed or 1)
    local cols = { theme.accent, theme.accent2, theme.text }
    for i = 1, n do
      local s1, s2, s3 = math.sin(i * 12.9898) * 43758.5453, math.sin(i * 78.233) * 12345.678, math.sin(i * 37.719) * 9876.54
      local r1, r2, r3 = s1 - math.floor(s1), s2 - math.floor(s2), s3 - math.floor(s3)
      local speed = 0.012 + r3 * 0.03
      local py = (r2 - m * speed) % 1.1 - 0.05
      local px = r1 + math.sin(m * (0.3 + r3) + i) * 0.02
      local size = 1 + r3 * 2.2
      local tw = 0.45 + 0.55 * math.sin(m * (1 + r1 * 2) + i * 3)
      local c = cols[(i % 3) + 1]
      local cx, cy = x + px * w, y + py * h
      glow(cx, cy, size * 7, size * 7, c, 0.10 * tw)
      ui.color(c, 0.5 * tw)
      lg.circle("fill", cx, cy, size * 0.6)
    end
  end

  local vig = bgs.vignette or 0
  if vig > 0 then
    lg.setColor(1, 1, 1, vig)
    local img = vignette()
    lg.draw(img, x, y, 0, w / img:getWidth(), h / img:getHeight())
  end
end

---------------------------------------------------------------------------
-- rolling digits for the big timer: a changed digit slides up out of its cell
-- while the new one slides in from below
---------------------------------------------------------------------------
local function drawRolling(st, font, text, xRight, y, rate)
  lg.setFont(font)
  local dw, fh = font:getWidth("0"), font:getHeight()
  local roll = st.anim.roll
  local x = xRight - monoWidth(font, text)
  local left = x
  local n = #text
  local r, g, b, a = lg.getColor()
  for i = 1, n do
    local ch = text:sub(i, i)
    local key = n - i + 1                       -- position from the right
    local isDigit = ch:match("%d") ~= nil
    local cw = isDigit and dw or font:getWidth(ch)
    local cell = roll[key]
    if not cell then cell = { cur = ch, prev = ch, t = 1 } roll[key] = cell end
    if cell.cur ~= ch then cell.prev, cell.cur, cell.t = cell.cur, ch, 0 end
    cell.t = math.min(1, cell.t + ui.dt * rate)
    if cell.t >= 1 or not isDigit then
      sPrint(ch, math.floor(x + (cw - font:getWidth(ch)) / 2), math.floor(y))
    else
      local e = easeOut(cell.t)
      ui.pushClip(x - 2, y, cw + 4, fh)
      lg.setColor(r, g, b, a * (1 - e))
      sPrint(cell.prev, math.floor(x + (cw - font:getWidth(cell.prev)) / 2), math.floor(y - e * fh * 0.75))
      lg.setColor(r, g, b, a * e)
      sPrint(ch, math.floor(x + (cw - font:getWidth(ch)) / 2), math.floor(y + (1 - e) * fh * 0.75))
      lg.setColor(r, g, b, a)
      ui.popClip()
    end
    x = x + cw
  end
  for k in pairs(roll) do if k > n then roll[k] = nil end end
  return left
end

---------------------------------------------------------------------------
-- the whole view, drawn into (ox, oy, W, H) from view state st
---------------------------------------------------------------------------
local function render(st, ox, oy, W, H, dt, status)
  local L0 = theme.style.layout
  shadowOn = L0.textShadow and true or false
  if theme.luminance(theme.panel) > 0.5 then shadowCol = { 1, 1, 1, 0.75 } else shadowCol = { 0, 0, 0, 0.65 } end
  local rawPrintf = lg.printf
  -- route lg.print/printf (used by ui.label too) through the shadow for this draw only
  lg.print = sPrint
  lg.printf = function(text, x, y, ...)
    if shadowOn then
      local r, g, b, a = lg.getColor()
      lg.setColor(shadowCol[1], shadowCol[2], shadowCol[3], shadowCol[4] * a)
      rawPrintf(text, x + 1, y + 1, ...)
      lg.setColor(r, g, b, a)
    end
    rawPrintf(text, x, y, ...)
  end
  local ok, err = pcall(V._render, st, ox, oy, W, H, dt, status)
  lg.print, lg.printf = rawPrint, rawPrintf
  shadowOn = false
  if not ok then error(err, 0) end
end

function V._render(st, ox, oy, W, H, dt, status)
  local S = st.S
  local style = theme.style
  local L, FX = style.layout, style.effects
  local sp = FX.speed or 1
  local F = theme.fonts
  local A = st.anim
  local t = love.timer.getTime()
  local pad = 16
  local rowH = style.sizes.rowH
  local radius = theme.radius

  ui.pushClip(ox, oy, W, H)
  V.drawBackground(ox, oy, W, H, t)

  local now = V.liveTime(st)
  local rows, info = buildRows(S, now)
  local n = #rows
  local idx = S.index or -1
  local active = S.phase == "Running" or S.phase == "Paused"

  -- rows slide in again after a reset or when other splits are opened
  local sig = (S.game or "") .. "|" .. (S.category or "") .. "|" .. n
  if A.sig ~= sig then A.sig, A.intro = sig, 0 end
  A.intro = math.min(1, A.intro + dt * 1.4 * sp)
  if not FX.rowIntro then A.intro = 1 end

  ---------------------------------------------------------------- layout
  local headerH = 0
  if L.header then headerH = 14 + F.game:getHeight() + 2 + F.category:getHeight() + 12 end
  local statusH = L.statusBar and 22 or 0
  local bigH = F.big:getHeight()
  local segH = L.segmentTimer and (F.seg:getHeight() + 2) or 0
  local centered = L.timerAlign == "center"
  local infoItems = {}
  if L.comparison then infoItems[#infoItems + 1] = "comparison" end
  if L.prevSegment then infoItems[#infoItems + 1] = "prev" end
  if L.timingMethod then infoItems[#infoItems + 1] = "method" end
  if L.sumOfBest then infoItems[#infoItems + 1] = "sob" end
  if L.bestPossible then infoItems[#infoItems + 1] = "bpt" end
  if L.timeSave then infoItems[#infoItems + 1] = "save" end
  local footerH = 12 + bigH + segH + 10
  if centered and #infoItems > 0 then footerH = footerH + F.category:getHeight() + 8 end
  footerH = math.max(footerH, (not centered) and (#infoItems * 30 + 20) or 0)
  local listTop = oy + headerH
  local listBottom = oy + H - footerH - statusH
  local listH = listBottom - listTop
  -- a panel between the splits and the big timer (races: race.lua sets V.panel)
  local panelH = 0
  if st == V.main and V.panel then
    local okP, h = pcall(V.panel.height, W)
    if okP and h and h > 0 then panelH = math.floor(math.min(h, listH * 0.7)) end
  end
  listBottom = listBottom - panelH
  listH = listBottom - listTop

  ---------------------------------------------------------------- header
  if L.header then
    local cx = ox + W / 2
    ui.color(theme.text)
    lg.setFont(F.game)
    local title = ui.ellipsize(F.game, (S.game and S.game ~= "") and S.game or "Untitled", W - pad * 2)
    lg.printf(title, ox + pad, oy + 14, W - pad * 2, "center")
    -- category + attempts pill
    lg.setFont(F.category)
    local cat = (S.category and S.category ~= "") and S.category or "No category"
    local att = "#" .. tostring(S.attempts or 0)
    local pillW = F.label:getWidth(att) + 14
    local catW = math.min(F.category:getWidth(cat), W - pad * 2 - pillW - 10)
    local total = catW + 8 + pillW
    local cy = oy + 14 + F.game:getHeight() + 2
    local cxs = cx - total / 2
    ui.color(theme.textDim)
    lg.print(ui.ellipsize(F.category, cat, catW + 1), math.floor(cxs), math.floor(cy))
    local px, ph = cxs + catW + 8, F.label:getHeight() + 4
    local py = cy + (F.category:getHeight() - ph) / 2
    ui.color(theme.accent, 0.18) ui.rect("fill", px, py, pillW, ph, ph / 2)
    ui.color(theme.accent) ui.label(att, px, py, { font = F.label, w = pillW, h = ph, align = "center", color = theme.accent })
    if S.hasChanged then glow(px + pillW + 8, py + ph / 2, 14, 14, theme.gold, 0.9) end

    -- divider: accent gradient that fades out at both ends, with a travelling shine
    local dy = oy + headerH - 1
    gradientRect(ox, dy, W / 2, 1, theme.accent, theme.accent, true, 0, 0.55)
    gradientRect(ox + W / 2, dy, W / 2, 1, theme.accent2, theme.accent2, true, 0.55, 0)
    local shx = ox + ((t * 0.18 * sp) % 1.4 - 0.2) * W
    glow(shx, dy, 120, 10, theme.accent, 0.35)
  end

  ---------------------------------------------------------------- progress bar
  if L.progress and n > 0 then
    local done = math.max(0, math.min(n, idx))
    local frac = done / n
    if S.phase == "Ended" then frac = 1 end
    if active and rows[idx + 1] and rows[idx + 1].compSeg and info.segStart then
      local part = clamp((now - info.segStart) / math.max(1, rows[idx + 1].compSeg), 0, 0.97)
      frac = frac + part / n
    end
    if S.phase == "NotRunning" then frac = 0 end
    A.progress = damp(A.progress, frac, 6 * sp, dt)
    local by, bh = listTop, 3
    ui.color(theme.textFaint, 0.18) lg.rectangle("fill", ox, by, W, bh)
    local fw = W * A.progress
    if fw > 0.5 then
      gradientRect(ox, by, fw, bh, theme.accent, theme.accent2, true)
      glow(ox + fw, by + 1, 26, 14, theme.accent2, 0.8)
    end
    listTop = listTop + bh
    listH = listBottom - listTop
  end

  ---------------------------------------------------------------- split list
  -- Display rows: with subsplits (LiveSplit's naming: "-Name" is a subsplit, "{Section} Name"
  -- closes a section) the section you're in opens, the others fold into one line.
  local curSeg = math.max(1, math.min(n, idx + 1))
  local disp = V.displayRows(S, rows, curSeg, L.subsplits, L.subsplitsExpand)
  local nd = #disp
  local curRow = 1
  for k, e in ipairs(disp) do if e.seg == curSeg and not e.header then curRow = k end end
  for k, e in ipairs(disp) do if e.seg == curSeg and e.header and e.folded then curRow = k end end

  local visible = math.max(1, math.floor(listH / rowH))
  local targetFirst = math.max(0, math.min(nd - visible, curRow - visible + 1))
  if S.phase == "NotRunning" then targetFirst = 0 end
  A.scroll = damp(A.scroll, targetFirst, 12 * sp, dt)

  local showHl = active
  A.hlY = damp(A.hlY, (curRow - 1) * rowH, 16 * sp, dt)
  A.hlA = damp(A.hlA, showHl and 1 or 0, 10 * sp, dt)
  for k, v in pairs(A.flash) do
    v = v - dt * 1.4 * sp
    if v > 0 then A.flash[k] = v else A.flash[k], A.sparked[k] = nil, nil end
  end

  local y0 = listTop - A.scroll * rowH
  local timeColW = monoWidth(F.row, "00:00.00") + 14
  local deltaColW = monoWidth(F.row, "+0:00.0") + 12
  local textY = math.floor((rowH - F.row:getHeight()) / 2)
  local indentW = 16

  ui.pushClip(ox, listTop, W, listH)
  -- row backgrounds (stripes, separators, split flash)
  for i, e in ipairs(disp) do
    local y = y0 + (i - 1) * rowH
    if y > listTop - rowH and y < listBottom then
      if L.stripes and i % 2 == 0 then ui.color(theme.panelAlt, 0.45) lg.rectangle("fill", ox, y, W, rowH) end
      if e.header and not e.folded then ui.color(theme.accent, 0.06) lg.rectangle("fill", ox, y, W, rowH) end
      if L.separators then ui.color(theme.border, 0.6) lg.rectangle("fill", ox + pad, y + rowH - 1, W - pad * 2, 1) end
      local f = (not e.header or e.folded) and A.flash[e.seg] or nil
      if f then
        local fc = e.r.gold and theme.gold or theme.accent
        ui.color(fc, 0.18 * f) lg.rectangle("fill", ox, y, W, rowH)
        if FX.splitPop then
          -- a bright sweep across the row
          local sx = ox + (1 - f) * (W + 160) - 80
          gradientRect(sx - 80, y, 80, rowH, fc, fc, true, 0, 0.35 * f)
          gradientRect(sx, y, 80, rowH, fc, fc, true, 0.35 * f, 0)
        end
      end
    end
  end

  -- current split highlight, gliding between rows
  if A.hlA > 0.01 and FX.highlight ~= "none" then
    local hy = y0 + A.hlY
    local hl = FX.highlight
    local a = A.hlA
    local pulse = FX.livePulse and (0.85 + 0.15 * math.sin(t * 3 * sp)) or 1
    if hl == "pill" then
      local inset = 6
      gradientRect(ox + inset, hy + 3, W - inset * 2, rowH - 6, theme.accent, theme.accent2, true, 0.22 * a, 0.10 * a)
      lg.setLineWidth(1)
      ui.color(theme.accent, 0.55 * a * pulse) ui.rect("line", ox + inset + 0.5, hy + 3.5, W - inset * 2 - 1, rowH - 7, math.min(radius + 2, (rowH - 6) / 2))
    elseif hl == "glow" then
      glow(ox + W / 2, hy + rowH / 2, W * 1.1, rowH * 2.6, theme.accent, 0.30 * a * pulse)
      gradientRect(ox, hy + rowH - 2, W, 2, theme.accent, theme.accent2, true, 0, 0.9 * a)
    elseif hl == "underline" then
      gradientRect(ox + pad, hy + rowH - 2, W - pad * 2, 2, theme.accent, theme.accent2, true, a, a)
    else -- bar
      ui.color(theme.accent, 0.14 * a) lg.rectangle("fill", ox, hy, W, rowH)
      ui.color(theme.accent, 0.95 * a) lg.rectangle("fill", ox, hy, 3, rowH)
    end
  end

  -- row text
  local first = math.floor(A.scroll)
  for i, e in ipairs(disp) do
    local r = e.r
    local y = y0 + (i - 1) * rowH
    if y > listTop - rowH and y < listBottom then
      local done = (e.seg - 1) < idx
      local isCur = i == curRow and showHl
      local intro = easeOut(A.intro * 1.8 - (i - first - 1) * 0.07)
      local slide = (1 - intro) * 26
      local alpha = intro
      local f = (not e.header or e.folded) and A.flash[e.seg] or nil
      local indent = e.indent and indentW or 0

      -- section headers: a small chevron, bold name
      local nameX = ox + pad + slide + indent + (isCur and 4 * A.hlA or 0)
      if e.header then
        ui.color(theme.accent, alpha)
        lg.setLineWidth(1.5)
        local cx, cy = ox + pad + slide + 4, y + rowH / 2
        if e.folded then lg.line(cx - 2, cy - 4, cx + 2, cy, cx - 2, cy + 4)
        else lg.line(cx - 4, cy - 2, cx, cy + 2, cx + 4, cy - 2) end
        lg.setLineWidth(1)
        nameX = nameX + 14
      end

      local nameFont = (isCur or e.header) and F.rowBold or F.row
      local base = (done or isCur or e.header) and theme.text or theme.textDim
      ui.color(base, alpha)
      lg.setFont(nameFont)
      lg.print(ui.ellipsize(nameFont, e.name, W - pad * 2 - timeColW - deltaColW - indent - (e.header and 14 or 0)),
        math.floor(nameX), math.floor(y + textY))

      -- an open section's header shows no times (they're on its rows below)
      if not (e.header and not e.folded) then
        ui.color(done and theme.text or theme.textDim, alpha)
        drawMono(F.row, r.time, ox + W - pad + slide, y + textY)

        if r.delta ~= "" then
          local dx = ox + W - pad - timeColW + slide
          local da = alpha * (r.live and FX.livePulse and (0.75 + 0.25 * math.sin(t * 5)) or 1)
          if f and FX.splitPop then
            -- pop: the new delta lands big and bright, then settles
            local sc = 1 + 0.35 * f * f
            local tw = monoWidth(F.row, r.delta)
            local cx, cy = dx - tw / 2, y + rowH / 2
            lg.push()
            lg.translate(cx, cy)
            lg.scale(sc, sc)
            lg.translate(-cx, -cy)
            ui.color(ui.mix(r.deltaCol, { 1, 1, 1, 1 }, 0.5 * f), da)
            drawMono(F.row, r.delta, dx, y + textY)
            lg.pop()
            if r.gold and FX.sparks and not A.sparked[e.seg] then
              A.sparked[e.seg] = true
              spawnSparks(st, cx, cy, theme.gold, 26)
            end
          else
            ui.color(r.deltaCol, da)
            drawMono(F.row, r.delta, dx, y + textY)
          end
        end
      end
    end
  end
  ui.popClip()
  n = nd   -- (the edge fades below count display rows)

  -- soft fade at the list's top/bottom edge when it scrolls
  if A.scroll > 0.05 then gradientRect(ox, listTop, W, 18, theme.bgTop, theme.bgTop, false, 0.7, 0) end
  if A.scroll < n - visible - 0.05 then gradientRect(ox, listBottom - 18, W, 18, theme.bgBottom, theme.bgBottom, false, 0, 0.7) end

  if panelH > 0 then
    ui.pushClip(ox, listBottom, W, panelH)
    local okP, err = pcall(V.panel.draw, ox, listBottom, W, panelH, dt)
    ui.popClip()
    if not okP then print("[panel] " .. tostring(err)) end
  end

  ---------------------------------------------------------------- footer: the big timer
  local fy = listBottom + panelH
  ui.color(theme.border, 0.7) lg.rectangle("fill", ox, fy, W, 1)

  local target = timerColor(S, now, info)
  A.timerCol = A.timerCol or { target[1], target[2], target[3], 1 }
  for k = 1, 3 do A.timerCol[k] = damp(A.timerCol[k], target[k], theme.speedTimer * sp, dt) end

  local tstr = fmtTime(math.max(0, now), L.decimals or 2)
  local whole, dec = tstr:match("^(.-)(%.%d+)$")
  whole, dec = whole or tstr, dec or ""
  local timerY = fy + 12
  local bigW = monoWidth(F.big, whole) + monoWidth(F.bigDec, dec)
  local timerRight
  if centered then timerRight = ox + W / 2 + bigW / 2
  elseif L.timerAlign == "left" then timerRight = ox + pad + bigW
  else timerRight = ox + W - pad end
  local decY = timerY + F.big:getBaseline() - F.bigDec:getBaseline()
  st.light = { x = (timerRight - bigW / 2 - ox) / W, y = (timerY + bigH / 2 - oy) / H }   -- light rays start here

  -- glow behind the digits
  local g = FX.timerGlow or 0
  if g > 0 then
    local breathe = active and (0.9 + 0.1 * math.sin(t * 2 * sp)) or 0.8
    glow(timerRight - bigW / 2, timerY + bigH / 2, bigW * 1.7, bigH * 2.0, A.timerCol, 0.22 * g * breathe)
    -- a soft halo: the text itself, faint, a few px around
    local rad = 2.5 * g
    local wasShadow = shadowOn
    shadowOn = false
    for k = 0, 7 do
      local ang = k / 8 * math.pi * 2
      ui.color(A.timerCol, 0.06 * g)
      local dxo, dyo = math.cos(ang) * rad, math.sin(ang) * rad
      local decX = drawMono(F.bigDec, dec, timerRight + dxo, decY + dyo)
      drawMono(F.big, whole, decX, timerY + dyo)
    end
    shadowOn = wasShadow
  end

  ui.color(A.timerCol)
  local decX = drawMono(F.bigDec, dec, timerRight, decY)
  if FX.digitRoll then drawRolling(st, F.big, whole, decX, timerY, 7 * sp)
  else drawMono(F.big, whole, decX, timerY) end

  -- segment timer
  if L.segmentTimer then
    local segY = timerY + bigH + 2
    local segTime = info.segStart and (now - info.segStart) or nil
    if S.phase == "NotRunning" then segTime = 0 end
    ui.color(theme.textDim)
    drawMono(F.seg, fmtTime(segTime and math.max(0, segTime) or nil, 2), timerRight, segY)
  end

  -- info: comparison / previous segment / timing method
  local function infoValue(item)
    if item == "comparison" then return "Comparing against", S.comparison or "-", theme.text end
    if item == "prev" then
      local c = info.prevSeg and (info.prevSeg < 0 and theme.aheadGain or theme.behindLose) or theme.textFaint
      return "Previous segment", info.prevSeg and fmtDelta(info.prevSeg) or "-", c
    end
    if item == "sob" then return "Sum of best", info.sob and fmtTime(info.sob) or "-", theme.gold end
    if item == "bpt" then return "Best possible time", info.bpt and fmtTime(info.bpt) or "-", theme.text end
    if item == "save" then
      local v = "-"
      if info.saveCur and active then v = fmtTime(info.saveCur, 1) .. "  ·  " .. (info.saveTotal and fmtTime(info.saveTotal, 1) or "-") .. " total"
      elseif info.saveTotal then v = fmtTime(info.saveTotal, 1) .. " total" end
      return "Possible time save", v, theme.gold
    end
    return "Timing", (S.method == "game" and "Game Time" or "Real Time") ..
      (S.method == "game" and S.gameTimePaused and "  (loading)" or ""), theme.textDim
  end
  if centered then
    if #infoItems > 0 then
      local parts, cols = {}, {}
      for _, it in ipairs(infoItems) do
        local _, v, c = infoValue(it)
        parts[#parts + 1], cols[#cols + 1] = v, c
      end
      lg.setFont(F.category)
      local sep = "   ·   "
      local tw = 0
      for k, p in ipairs(parts) do tw = tw + F.category:getWidth(p) + (k > 1 and F.category:getWidth(sep) or 0) end
      local x = ox + W / 2 - tw / 2
      local iy = fy + footerH - F.category:getHeight() - 10
      for k, p in ipairs(parts) do
        if k > 1 then ui.color(theme.textFaint) lg.print(sep, math.floor(x), iy) x = x + F.category:getWidth(sep) end
        ui.color(cols[k]) lg.print(p, math.floor(x), iy)
        x = x + F.category:getWidth(p)
      end
    end
  else
    local leftSide = L.timerAlign ~= "left"
    local iy = fy + 14
    local maxW = W - bigW - pad * 3
    for _, it in ipairs(infoItems) do
      local label, value, c = infoValue(it)
      local align = leftSide and "left" or "right"
      local ix = leftSide and (ox + pad) or (ox + W - pad - maxW)
      ui.label(label:upper(), ix, iy, { font = F.label, w = maxW, align = align, color = theme.textFaint })
      ui.label(ui.ellipsize(F.category, value, maxW), ix, iy + 13, { font = F.category, w = maxW, align = align, color = c })
      iy = iy + 30
    end
  end

  ---------------------------------------------------------------- celebrations
  if S.phase == "Ended" then
    if not A.ended then
      A.ended = true
      local pb = info.finalComp == nil or (info.finalSplit and info.finalSplit < info.finalComp)
      if pb and FX.confetti then spawnConfetti(st, ox, oy, W) end
    end
  else
    A.ended = false
  end
  updateDrawFx(st, dt, ox, oy, W, H)

  ---------------------------------------------------------------- status bar
  if L.statusBar then
    local sy = oy + H - statusH
    ui.color(theme.panel, 0.55) lg.rectangle("fill", ox, sy, W, statusH)
    ui.color(theme.border, 0.7) lg.rectangle("fill", ox, sy, W, 1)
    local live = not status.stale
    local dotC = live and theme.aheadGain or theme.behindLose
    if live then glow(ox + pad + 3, sy + statusH / 2, 14, 14, dotC, 0.5 + 0.3 * math.sin(t * 3)) end
    ui.color(dotC) lg.circle("fill", ox + pad + 3, sy + statusH / 2, 3)
    lg.setFont(F.small)
    ui.color(theme.textFaint)
    local left = live and "live" or "stalled"
    local aslText, aslCol
    if L.autosplitterStatus and S.autosplitterStatus and S.autosplitterStatus ~= "off" then
      local st2 = S.autosplitterStatus
      if st2 == "connected" then aslText, aslCol = "connected" .. (S.autosplitterGame and (" to " .. S.autosplitterGame) or ""), theme.aheadGain
      elseif st2 == "waiting" then aslText, aslCol = "waiting for the game", theme.gold
      elseif st2 == "loading" then aslText, aslCol = "autosplitter loading…", theme.accent
      elseif st2 == "error" then aslText, aslCol = "autosplitter error" .. (S.autosplitterError and (": " .. S.autosplitterError) or ""), theme.behindLose
      else aslText, aslCol = "autosplitter on", theme.textFaint end
    elseif S.autosplitterRunning then
      left = left .. "   ·   autosplitter on"
    end
    if S.windowHidden == false and not S.standalone then left = left .. "   ·   LiveSplit visible" end
    local ty = math.floor(sy + (statusH - F.small:getHeight()) / 2)
    lg.print(left, math.floor(ox + pad + 12), ty)
    if aslText then
      local ax = ox + pad + 12 + F.small:getWidth(left) + 14
      ui.color(aslCol)
      lg.circle("fill", ax, sy + statusH / 2, 2.5)
      lg.print(ui.ellipsize(F.small, aslText, W - (ax - ox) - 130), math.floor(ax + 7), ty)
      ui.color(theme.textFaint)
    end
    lg.printf("right-click for menu", ox, math.floor(sy + (statusH - F.small:getHeight()) / 2), W - pad, "right")
  end

  ui.popClip()
end

function V.draw(W, H, dt, status)
  render(V.main, 0, 0, W, H, dt, status or {})
  -- drawn over everything (race countdown)
  if V.overlay then
    local ok, err = pcall(V.overlay, W, H, dt)
    if not ok then print("[overlay] " .. tostring(err)) end
  end
end

---------------------------------------------------------------------------
-- demo run for the Customise preview: splits every few seconds, golds, a PB
---------------------------------------------------------------------------
local DEMO_START = 754000      -- 12:34.00 into the run, so the big digits roll
local DEMO = {
  names = { "Toy Graveyard", "Prison Cell Blocks", "Doctor's Domain", "Containment Zone", "Safe Haven", "The Labs" },
  pbSeg = { 4300, 4900, 4500, 5200, 4200, 5500 },
  delta = { -1100, -600, 900, -2600, -2250, -4000 },
}

local function demoSnapshot(st, dt)
  st.demoT = (st.demoT or 0) + dt
  local T = st.demoT
  local idle, tail = 1.5, 4.5
  local comps, cum = {}, DEMO_START
  for i, l in ipairs(DEMO.pbSeg) do cum = cum + l comps[i] = cum end
  local splits = {}
  for i = 1, #comps do splits[i] = comps[i] + DEMO.delta[i] end
  local runEnd = splits[#splits] - DEMO_START
  local runT = (T - idle) * 1000
  if runT > runEnd + tail * 1000 then st.demoT = 0 T = 0 runT = -idle * 1000 end

  local phase, time, index = "NotRunning", DEMO_START, 0
  if runT >= 0 then
    phase = "Running"
    time = DEMO_START + math.min(runT, runEnd)
    for i = 1, #splits do if splits[i] <= time then index = i end end
    if runT >= runEnd then phase, index, time = "Ended", #splits, splits[#splits] end
  end
  if phase == "NotRunning" then time = 0 end

  local segs = {}
  for i, name in ipairs(DEMO.names) do
    segs[i] = { name = name, comp = comps[i], best = DEMO.pbSeg[i] - 300, split = (i <= index) and splits[i] or nil }
  end
  if st.lastIndex and index > st.lastIndex and index > 0 then st.anim.flash[index] = 1 end
  if st.lastPhase and st.lastPhase ~= "NotRunning" and phase == "NotRunning" then st.anim.intro = 0 end
  st.lastPhase, st.lastIndex = phase, index

  st.S = { game = "Poppy Playtime: Chapter 4", category = "Any%", attempts = 142, comparison = "Personal Best",
    method = "real", phase = phase, time = time, index = phase == "Running" and index or (phase == "Ended" and #segs or -1),
    segments = segs, autosplitterRunning = true, windowHidden = true, standalone = true }
  st.clock.running, st.clock.base = false, time
end

function V.drawPreview(x, y, w, h, dt)
  demoSnapshot(V.demo, dt)
  render(V.demo, x, y, w, h, dt, { stale = false })
end

---------------------------------------------------------------------------
-- waiting screen
---------------------------------------------------------------------------
function V.drawWaiting(W, H, title, detail)
  local t = love.timer.getTime()
  V.drawBackground(0, 0, W, H, t)
  glow(W / 2, H / 2 + 44, 160, 60, theme.accent, 0.25 + 0.1 * math.sin(t * 2))
  ui.color(theme.text)
  lg.setFont(theme.fonts.title)
  lg.printf(title, 0, H / 2 - 30, W, "center")
  ui.color(theme.textDim)
  lg.setFont(theme.fonts.ui)
  lg.printf(detail, 16, H / 2 - 4, W - 32, "center")
  for i = 0, 2 do
    local a = 0.25 + 0.75 * math.max(0, math.sin(t * 4 - i * 0.7))
    local c = ui.mix(theme.accent, theme.accent2, i / 2)
    glow(W / 2 - 14 + i * 14, H / 2 + 44, 18, 18, c, a * 0.6)
    ui.color(c, a)
    lg.circle("fill", W / 2 - 14 + i * 14, H / 2 + 44, 3.5)
  end
end

return V
