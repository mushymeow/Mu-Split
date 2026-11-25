-- Races: race your friends live, with your own splits.
--
-- Someone makes a race and gets a code (like K7QF2M); everyone else joins with it. The host
-- starts a countdown, everyone's timer starts at the same moment, and each split you make is
-- sent to the others, so the timer shows who's ahead, by how much, at every split.
--
-- Your timer still runs on your PC: the race server (server/worker.js, a free Cloudflare
-- Worker) only passes split times around. Connection: racenet.lua (through the engine).
--
-- Settings (race.json): name, server, autoStart, beeps, panel, forfeitOnReset, panelRows.

local json = require("json")
local theme = require("theme")
local ui = require("ui")
local racenet = require("racenet")

local race = {
  status = "off",     -- off | connecting | in | reconnecting | error
  code = nil, room = nil, you = nil,
  error = nil, chat = {}, unread = 0,
  offset = nil,       -- server clock minus ours (ms)
  toastText = nil, toastAt = 0,
}

local lg = love.graphics
local function mono() return love.timer.getTime() * 1000 end
local CODE_CHARS = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------
local function randomId(n, chars)
  chars = chars or "abcdefghijklmnopqrstuvwxyz0123456789"
  local t = {}
  for i = 1, n do local k = love.math.random(1, #chars) t[i] = chars:sub(k, k) end
  return table.concat(t)
end

local DEFAULT_SERVER = ""
do
  local ok, s = pcall(require, "raceserver")   -- deploy.bat writes this file
  if ok and type(s) == "string" then DEFAULT_SERVER = s end
end

race.cfg = { name = "", id = "", server = DEFAULT_SERVER, autoStart = true, beeps = true,
             panel = true, forfeitOnReset = true, panelRows = 6, countdown = 10 }
do
  local ok, t = pcall(function() return json.decode(love.filesystem.read("race.json")) end)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do if race.cfg[k] ~= nil and type(v) == type(race.cfg[k]) then race.cfg[k] = v end end
  end
  if race.cfg.id == "" then race.cfg.id = randomId(16) end
  if race.cfg.server == "" then race.cfg.server = DEFAULT_SERVER end
end
function race.saveCfg() pcall(love.filesystem.write, "race.json", json.encode(race.cfg)) end
race.saveCfg()

-- "https://musplit-race.you.workers.dev/" -> "wss://musplit-race.you.workers.dev"
function race.serverUrl()
  local s = (race.cfg.server or ""):gsub("%s+", ""):gsub("/+$", "")
  if s == "" then return nil end
  if not s:match("^%a+://") then s = "https://" .. s end
  s = s:gsub("^https://", "wss://"):gsub("^http://", "ws://")
  return s
end

---------------------------------------------------------------------------
-- talking to the server
---------------------------------------------------------------------------
local wanted = false          -- we want to be in a room (reconnect if dropped)
local creating = false
local createTries = 0
local reconnectAt = nil
local pings = {}              -- { at = mono } when to send the next clock pings
local samples = {}            -- clock samples { rtt, off }
local lastProgressSig, lastProgressAt = nil, 0
local helloSig = nil
local prevPhase = nil

function race.send(t) racenet.send(t) end

function race.toast(text) race.toastText, race.toastAt = text, love.timer.getTime() end

local function myPlayer()
  if not race.room or not race.you then return nil end
  for _, p in ipairs(race.room.players or {}) do if p.id == race.you then return p end end
end
race.me = myPlayer

function race.isHost() return race.room and race.you and race.room.host == race.you end
function race.inRoom() return race.status == "in" and race.room ~= nil end

local function open(code, create)
  local base = race.serverUrl()
  if not base then race.status, race.error = "error", "Set the race server first." return end
  race.code = code
  race.status = (race.status == "in" or race.status == "reconnecting") and "reconnecting" or "connecting"
  race.error = nil
  creating = create
  racenet.connect(base .. "/room/" .. code .. (create and "?create=1" or ""))
end

function race.create()
  wanted, createTries = true, 1
  race.room, race.you, race.chat, race.unread = nil, nil, {}, 0
  open(randomId(6, CODE_CHARS), true)
end

function race.join(code)
  code = (code or ""):upper():gsub("[^A-Z0-9]", "")
  if #code < 4 then race.status, race.error = "error", "That code is too short." return end
  wanted = true
  race.room, race.you, race.chat, race.unread = nil, nil, {}, 0
  open(code, false)
end

function race.leave()
  if race.status == "in" then race.send({ t = "leave" }) end
  wanted = false
  racenet.close()
  race.status, race.room, race.you, race.code, race.error = "off", nil, nil, nil, nil
  reconnectAt = nil
end

local function segNames(S)
  local t = {}
  for i, seg in ipairs((S and S.segments) or {}) do t[i] = seg.name or "" end
  return json.array(t)
end

local function sendHello()
  local S = race.S or {}
  local name = race.cfg.name ~= "" and race.cfg.name or "Runner"
  race.send({ t = "hello", id = race.cfg.id, name = name, game = S.game or "", category = S.category or "",
              method = S.method or "real", segments = segNames(S) })
  helloSig = (S.game or "") .. "|" .. (S.category or "") .. "|" .. #((S and S.segments) or {}) .. "|" .. name
end
race.sendHello = sendHello

racenet.on.open = function() sendHello() end

racenet.on.close = function(reason)
  if race.status == "error" then return end
  if wanted and race.code and not creating then
    race.status = "reconnecting"
    reconnectAt = love.timer.getTime() + 2
  elseif not wanted then
    race.status = "off"
  else
    race.status, race.error = "error", "Couldn't reach the race server" .. (reason ~= "" and (": " .. reason) or ".")
    wanted = false
  end
end

local function onRoom(room)
  local old = race.room
  race.room = room
  -- the countdown started: close the race window so the timer shows
  if room.status == "countdown" and (not old or old.status ~= "countdown") then
    if race.onCountdown then race.onCountdown() end
    local me = myPlayer()
    if me and me.racing and race.S and race.S.phase ~= "NotRunning" then
      race.toast("Reset your timer before the start!")
    end
  end
  if room.status == "finished" and old and old.status == "running" then
    race.toast("Race over!")
  end
end

racenet.on.message = function(m)
  if m.t == "welcome" then
    race.you, race.status, creating, reconnectAt = m.you, "in", false, nil
    onRoom(m.room)
    -- clock sync: 5 quick pings now, then one every 30 s
    local now = love.timer.getTime()
    pings = { now, now + 0.3, now + 0.6, now + 0.9, now + 1.2 }
    lastProgressSig = nil   -- (re)send our progress
  elseif m.t == "room" then
    onRoom(m.room)
  elseif m.t == "pong" and type(m.c) == "number" and type(m.s) == "number" then
    local now = mono()
    local rtt = now - m.c
    samples[#samples + 1] = { rtt = rtt, off = m.s - (m.c + rtt / 2) }
    if #samples > 10 then table.remove(samples, 1) end
    local best = samples[1]
    for _, s in ipairs(samples) do if s.rtt < best.rtt then best = s end end
    race.offset, race.rtt = best.off, best.rtt
  elseif m.t == "chat" then
    race.chat[#race.chat + 1] = { name = m.name or "?", text = m.text or "", mine = m.from == race.you }
    if #race.chat > 60 then table.remove(race.chat, 1) end
    if m.from ~= race.you then race.unread = race.unread + 1 end
  elseif m.t == "error" then
    if creating and m.message == "taken" and createTries < 5 then
      createTries = createTries + 1
      open(randomId(6, CODE_CHARS), true)       -- that code exists: pick another
      return
    end
    race.error = m.message or "Error"
    if m.fatal then
      wanted = false
      race.status = "error"
      race.room = nil
      racenet.close()
    end
  end
end

---------------------------------------------------------------------------
-- your timer -> the race
---------------------------------------------------------------------------
-- timerview calls this with every snapshot from the engine (V.onStateHook)
function race.onState(S)
  race.S = S
  if race.status ~= "in" then prevPhase = S.phase return end
  local me = myPlayer()
  local room = race.room

  -- you reset mid-race: that's a forfeit
  if prevPhase and prevPhase ~= "NotRunning" and S.phase == "NotRunning" and me and me.racing
     and room.status == "running" and not me.finished and not me.forfeit and race.cfg.forfeitOnReset then
    race.send({ t = "forfeit" })
    race.toast("You reset, so you've forfeited.")
  end
  prevPhase = S.phase

  -- new splits / game: tell the room who we are again
  local name = race.cfg.name ~= "" and race.cfg.name or "Runner"
  local hs = (S.game or "") .. "|" .. (S.category or "") .. "|" .. #(S.segments or {}) .. "|" .. name
  if hs ~= helloSig then sendHello() end

  local splits, filled, last = {}, 0, 0
  for i, seg in ipairs(S.segments or {}) do
    if seg.split then splits[i] = seg.split filled = filled + 1 last = seg.split else splits[i] = json.null end
  end
  local sig = tostring(S.phase) .. "|" .. tostring(S.index) .. "|" .. filled .. "|" .. last .. "|" .. tostring(S.method)
  local now = love.timer.getTime()
  local running = S.phase == "Running"
  if sig ~= lastProgressSig or (running and now - lastProgressAt > 10) then
    lastProgressSig, lastProgressAt = sig, now
    race.send({ t = "progress", phase = S.phase, index = S.index or -1, time = S.time or 0,
                method = S.method or "real", splits = json.array(splits) })
  end
end

---------------------------------------------------------------------------
-- countdown beeps (made here, like sounds.lua: no audio files)
---------------------------------------------------------------------------
local beepCache = {}
local function beep(go)
  if not race.cfg.beeps then return end
  local key = go and "go" or "tick"
  if not beepCache[key] then
    local ok, src = pcall(function()
      local rate, dur, f = 44100, go and 0.42 or 0.13, go and 988 or 660
      local n = math.floor(dur * rate)
      local d = love.sound.newSoundData(n, rate, 16, 1)
      for i = 0, n - 1 do
        local t = i / rate
        local e = math.min(1, t / 0.005) * math.exp(-t * (go and 5 or 18))
        d:setSample(i, (math.sin(2 * math.pi * f * t) * 0.7 + math.sin(4 * math.pi * f * t) * 0.15) * e)
      end
      return love.audio.newSource(d, "static")
    end)
    if not ok then return end
    beepCache[key] = src
  end
  local s = beepCache[key]
  local vol = (theme.style.sounds and theme.style.sounds.volume) or 0.6
  s:stop()
  s:setVolume(vol)
  s:play()
end

---------------------------------------------------------------------------
-- every frame
---------------------------------------------------------------------------
local lastBeepSec, startedFor = nil, nil

-- ms until the race starts (negative once it has), or nil
function race.startsIn()
  local r = race.room
  if not r or not race.offset or not r.startAt or r.startAt == 0 then return nil end
  if r.status ~= "countdown" and r.status ~= "running" then return nil end
  return (r.startAt - race.offset) - mono()
end

-- how long the race has been going (server clock), or nil
function race.raceClock()
  local left = race.startsIn()
  if not left or left > 0 then return nil end
  return -left
end

function race.update(dt)
  racenet.update()
  local now = love.timer.getTime()
  if reconnectAt and now >= reconnectAt then
    reconnectAt = nil
    if wanted and race.code then open(race.code, false) end
  end
  if race.status == "in" then
    if pings[1] and now >= pings[1] then
      table.remove(pings, 1)
      race.send({ t = "ping", c = mono() })
      if #pings == 0 then pings[1] = now + 30 end
    end
  end

  -- countdown: beeps on 3, 2, 1 and GO, and your timer starts
  local me = myPlayer()
  local left = race.startsIn()
  if left and me and me.racing and race.room.status ~= "finished" then
    local sec = math.ceil(left / 1000)
    if left > 0 and sec <= 3 and sec ~= lastBeepSec then lastBeepSec = sec beep(false) end
    if left <= 0 and startedFor ~= race.room.startAt then
      startedFor = race.room.startAt
      lastBeepSec = nil
      -- (joining or reconnecting long after the start doesn't start your timer)
      if left > -3000 then
        beep(true)
        if race.cfg.autoStart and race.S and race.S.phase == "NotRunning" and race.startTimer then race.startTimer() end
      end
    end
  end
end

---------------------------------------------------------------------------
-- standings
---------------------------------------------------------------------------
local function fmt(ms)
  if not ms then return "-" end
  local V = package.loaded["timerview"]
  if V and V.fmtTime then return V.fmtTime(ms, 1) end
  return string.format("%.1f", ms / 1000)
end
local function fmtDelta(ms)
  if not ms then return "" end
  local sign = ms < 0 and "-" or "+"
  ms = math.abs(ms)
  local s = ms / 1000
  if s < 60 then return string.format("%s%.1f", sign, s) end
  return string.format("%s%d:%04.1f", sign, math.floor(s / 60), s % 60)
end
race.fmtDelta = fmtDelta

-- completed splits of a player: their index (Ended means all of them)
local function segCount(p) return p.segCount or (p.segments and #p.segments) or 0 end
local function doneCount(p)
  local n = segCount(p)
  if p.phase == "Ended" then return n end
  return math.max(0, p.index or 0)
end

-- players in race order: { p, rank, done, total, time, delta, state }
--   state: finished | racing | forfeit | waiting (lobby) | watching
function race.standings()
  local room = race.room
  if not room then return {} end
  local list = {}
  local inRace = room.status ~= "open"
  for _, p in ipairs(room.players or {}) do
    local e = { p = p, done = doneCount(p), total = segCount(p), me = p.id == race.you }
    if not inRace then e.state = "waiting"
    elseif not p.racing then e.state = "watching"
    elseif p.forfeit then e.state = "forfeit"
    elseif p.finished then e.state = "finished" e.time = p.finalTime
    else
      e.state = "racing"
      local splits = p.splits or {}
      e.time = e.done > 0 and splits[e.done] or nil
    end
    list[#list + 1] = e
  end
  local order = { finished = 1, racing = 2, waiting = 2, forfeit = 3, watching = 4 }
  table.sort(list, function(a, b)
    if order[a.state] ~= order[b.state] then return order[a.state] < order[b.state] end
    if a.state == "finished" then return (a.time or math.huge) < (b.time or math.huge) end
    if a.state == "racing" then
      if a.done ~= b.done then return a.done > b.done end
      return (a.time or math.huge) < (b.time or math.huge)
    end
    return (a.p.joined or 0) < (b.p.joined or 0)
  end)
  -- delta: your time at your latest split minus the best anyone did at that split
  local best = {}
  for _, e in ipairs(list) do
    if e.p.racing and not e.p.forfeit then
      for k, v in pairs(e.p.splits or {}) do
        if type(k) == "number" and type(v) == "number" and (not best[k] or v < best[k]) then best[k] = v end
      end
    end
  end
  local rank = 0
  for _, e in ipairs(list) do
    if e.state == "finished" or e.state == "racing" then
      rank = rank + 1
      e.rank = rank
      local k = e.state == "finished" and e.total or e.done
      local mine = e.p.splits and e.p.splits[k]
      if k > 0 and mine and best[k] then e.delta = mine - best[k] end
    end
  end
  return list
end

---------------------------------------------------------------------------
-- the race panel in the timer (between the splits and the big timer)
---------------------------------------------------------------------------
local ROW_H, HEAD_H = 20, 24

local function visibleRows()
  local list = race.standings()
  local max = math.max(2, race.cfg.panelRows or 6)
  if #list <= max then return list, 0 end
  -- the top ones, and always you
  local out, meShown, myEntry = {}, false, nil
  for i, e in ipairs(list) do
    if i <= max - 1 then out[#out + 1] = e if e.me then meShown = true end end
    if e.me then myEntry = e end
  end
  if not meShown and myEntry then out[#out + 1] = myEntry else out[#out + 1] = list[max] end
  return out, #list - #out
end

local panelAnim = 0
function race.panelHeight(W)
  local show = race.cfg.panel and (race.status == "in" or race.status == "reconnecting") and race.room ~= nil
  panelAnim = ui.damp(panelAnim, show and 1 or 0, 10, love.timer.getDelta())
  if panelAnim < 0.01 then return 0 end
  local rows = visibleRows()
  return (HEAD_H + #rows * ROW_H + 6) * panelAnim
end

function race.drawPanel(x, y, w, h, dt)
  local F = theme.fonts
  local pad = 16
  ui.color(theme.panelAlt or theme.panel, 0.55) lg.rectangle("fill", x, y, w, h)
  ui.color(theme.border, 0.7) lg.rectangle("fill", x, y, w, 1)
  local room = race.room
  if not room then return end

  -- header: RACE K7QF2M ............ 12:34.5 / starts in 7 / lobby
  local t = love.timer.getTime()
  local live = race.status == "in"
  ui.color(live and theme.accent or theme.gold)
  lg.circle("fill", x + pad + 3, y + HEAD_H / 2, 3)
  lg.setFont(F.label)
  ui.color(theme.textDim)
  lg.print("RACE  " .. (room.code or ""), math.floor(x + pad + 12), math.floor(y + (HEAD_H - F.label:getHeight()) / 2))

  local right
  local left = race.startsIn()
  if race.status == "reconnecting" then right = "reconnecting…"
  elseif room.status == "open" then
    local ready, n = 0, 0
    for _, p in ipairs(room.players or {}) do n = n + 1 if p.ready then ready = ready + 1 end end
    right = ("lobby · %d/%d ready"):format(ready, n)
  elseif room.status == "countdown" and left and left > 0 then right = ("starts in %d"):format(math.ceil(left / 1000))
  elseif room.status == "finished" then right = "finished"
  else right = fmt(race.raceClock()) end
  if race.toastText and t - race.toastAt < 4 then right = race.toastText end
  lg.setFont(F.small)
  ui.color(theme.text)
  lg.printf(right, x, math.floor(y + (HEAD_H - F.small:getHeight()) / 2), w - pad, "right")

  -- rows
  local rows = visibleRows()
  local ry = y + HEAD_H
  local timeW = F.row:getWidth("00:00:00.0") + 6
  local deltaW = F.small:getWidth("+00:00.0") + 10
  for _, e in ipairs(rows) do
    if e.me then ui.color(theme.accent, 0.12) lg.rectangle("fill", x, ry, w, ROW_H) end
    local cy = math.floor(ry + (ROW_H - F.small:getHeight()) / 2)
    -- rank / state badge
    lg.setFont(F.small)
    if e.state == "waiting" then
      -- lobby: a dot, filled once they're ready
      ui.color(e.p.ready and theme.aheadGain or theme.textFaint)
      lg.circle(e.p.ready and "fill" or "line", x + pad + 4, ry + ROW_H / 2, 3.5)
    else
      local badge = e.rank and tostring(e.rank) or (e.state == "forfeit" and "x" or "-")
      ui.color(e.rank == 1 and theme.gold or (e.state == "forfeit" and theme.behindLose or theme.textFaint))
      lg.printf(badge, x + pad - 4, cy, 16, "center")
    end
    -- name (+ progress)
    local nameF = e.me and (F.rowBold or F.row) or F.row
    lg.setFont(nameF)
    ui.color(e.state == "forfeit" and theme.textFaint or theme.text)
    local name = e.p.name or "?"
    if room.host == e.p.id and room.status == "open" then name = name .. "  (host)" end
    local prog = ""
    if e.state == "racing" then prog = ("%d/%d"):format(e.done, e.total)
    elseif e.state == "forfeit" then prog = "forfeit"
    elseif e.state == "watching" then prog = "watching"
    elseif e.state == "waiting" then prog = e.p.ready and "ready" or "not ready" end
    local nameW = w - pad * 2 - 18 - timeW - deltaW - F.small:getWidth(prog) - 8
    lg.print(ui.ellipsize(nameF, name, nameW), math.floor(x + pad + 16), math.floor(ry + (ROW_H - nameF:getHeight()) / 2))
    lg.setFont(F.small)
    ui.color(theme.textFaint)
    lg.print(prog, math.floor(x + pad + 16 + math.min(nameW, nameF:getWidth(name)) + 8), cy)
    -- time and delta
    if e.time then
      lg.setFont(F.row)
      ui.color(e.state == "finished" and (e.rank == 1 and theme.gold or theme.text) or theme.text)
      lg.printf(fmt(e.time), x, math.floor(ry + (ROW_H - F.row:getHeight()) / 2), w - pad, "right")
    end
    if e.delta and e.delta > 0 then
      lg.setFont(F.small)
      ui.color(theme.behindLose)
      lg.printf(fmtDelta(e.delta), x, cy, w - pad - timeW, "right")
    elseif e.delta then
      lg.setFont(F.small)
      ui.color(theme.aheadGain)
      lg.printf("lead", x, cy, w - pad - timeW, "right")
    end
    ry = ry + ROW_H
  end
end

---------------------------------------------------------------------------
-- the big countdown over the timer
---------------------------------------------------------------------------
function race.drawOverlay(W, H, dt)
  local left = race.startsIn()
  if not left then return end
  local me = myPlayer()
  if not me or not me.racing then return end
  local text, a, pop
  if left > 0 and left <= 10000 then
    local sec = math.ceil(left / 1000)
    local frac = (left % 1000) / 1000          -- 1 at the start of each second, 0 at its end
    text, a, pop = tostring(sec), 0.35 + 0.65 * frac, 1 + 0.35 * frac * frac
  elseif left <= 0 and left > -1200 then
    local k = -left / 1200
    text, a, pop = "GO!", 1 - k, 1 + 0.5 * (1 - k)
  else
    return
  end
  local F = theme.fonts
  local font = F.big
  local cx, cy = W / 2, H * 0.42
  ui.color({ 0, 0, 0 }, 0.35 * a) lg.rectangle("fill", 0, 0, W, H)
  lg.push()
  lg.translate(cx, cy)
  lg.scale(pop * 1.6, pop * 1.6)
  lg.setFont(font)
  local tw, th = font:getWidth(text), font:getHeight()
  ui.color({ 0, 0, 0 }, 0.5 * a)
  lg.print(text, -tw / 2 + 2, -th / 2 + 2)
  ui.color(text == "GO!" and theme.aheadGain or theme.text, a)
  lg.print(text, -tw / 2, -th / 2)
  lg.pop()
  if left > 0 then
    lg.setFont(F.category)
    ui.color(theme.textDim, a)
    lg.printf("race starts in", 0, cy - th * 1.1 - 10, W, "center")
  end
end

return race
