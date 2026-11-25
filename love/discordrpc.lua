-- Discord status ("Rich Presence"): your friends see what you're running.
--
--   Playing Mu Split
--   Poppy Playtime Chapter 5 · Any%
--   Keycard (3/12) · -4.2
--   05:40 elapsed
--
-- The engine talks to Discord (engine/DiscordPresence.cs); we build the status here and send
-- it through racenet's connection when it changes (at most every 4 s: Discord's limit is 5
-- updates per 20 s). discord.json keeps the on/off switch.
--
-- Discord needs an "application" for the name ("Playing Mu Split") and the picture: its id is
-- in love/discordapp.lua (made at https://discord.com/developers/applications). People only
-- get an on/off switch, in Settings > Mu Split.

local json = require("json")
local theme = require("theme")
local ui = require("ui")
local racenet = require("racenet")

local D = {}

local DEFAULT_APP = ""
do
  local ok, s = pcall(require, "discordapp")
  if ok and type(s) == "string" then DEFAULT_APP = s end
end

-- the button under your status (other people see it, not you): where to get Mu Split
local DOWNLOAD_URL = "https://github.com/mushymeow/Mu-Split"

D.cfg = { enabled = true, appId = DEFAULT_APP, game = true, split = true, time = true, delta = false,
          race = true, image = "logo",
          button = true, buttonLabel = "Download Mu Split", buttonUrl = DOWNLOAD_URL }
do
  local ok, t = pcall(function() return json.decode(love.filesystem.read("discord.json")) end)
  -- only the on/off switch is yours (Settings > Mu Split); the rest is how Mu Split shows itself
  if ok and type(t) == "table" and type(t.enabled) == "boolean" then D.cfg.enabled = t.enabled end
end
function D.saveCfg() pcall(love.filesystem.write, "discord.json", json.encode({ enabled = D.cfg.enabled })) end
function D.setEnabled(on) D.cfg.enabled = on D.saveCfg() end

local function validApp() return (D.cfg.appId or ""):match("^%d+$") ~= nil and #D.cfg.appId >= 15 end
D.validApp = validApp

local function ordinal(n)
  local s = ({ "st", "nd", "rd" })[n % 10]
  if not s or (n % 100 >= 11 and n % 100 <= 13) then s = "th" end
  return n .. s
end

---------------------------------------------------------------------------
-- what to show
---------------------------------------------------------------------------
-- -> activity table (or nil for no status), and a key that changes when it should be re-sent
function D.build(S, liveMs, nowSec)
  local V = package.loaded["timerview"]
  if not S or not S.phase then return nil, "none" end
  local c = D.cfg
  local game = (S.game and S.game ~= "") and S.game or "Speedrunning"
  local details = c.game and game or "Speedrunning"
  if c.game and S.category and S.category ~= "" then details = details .. " · " .. S.category end

  local segs = S.segments or {}
  local n = #segs
  local idx = S.index or -1
  local state
  local timestamps
  local fmt = (V and V.fmtTime) or function(ms) return string.format("%.1f", ms / 1000) end

  if S.phase == "NotRunning" then
    state = "Getting ready"
  elseif S.phase == "Ended" then
    local last = segs[n] and segs[n].split or S.time or 0
    state = "Finished in " .. fmt(last, 2)
    local comp = segs[n] and segs[n].comp
    if comp == nil or last < comp then state = state .. " · new PB!" end
  else
    local parts = {}
    if c.split and segs[idx + 1] then
      local name = V and V.cleanName and (V.cleanName(segs[idx + 1].name)) or segs[idx + 1].name or ""
      parts[#parts + 1] = ("%s (%d/%d)"):format(name, idx + 1, n)
    end
    if c.delta and V and V.buildRows then
      local _, info = V.buildRows(S, liveMs)
      local d = info and info.lastDelta
      if d then
        local race = package.loaded["race"]
        local fd = race and race.fmtDelta and race.fmtDelta(d) or tostring(math.floor(d / 100) / 10)
        parts[#parts + 1] = fd
      end
    end
    if S.phase == "Paused" then parts[#parts + 1] = "paused at " .. fmt(liveMs, 0) end
    state = #parts > 0 and table.concat(parts, " · ") or "Running"
    -- Discord counts the time itself from a start moment, so it ticks without updates
    if c.time and S.phase == "Running" then
      timestamps = { start = (nowSec - math.floor(liveMs / 1000)) * 1000 }
    end
  end

  -- racing: "Racing · 2nd of 4" goes on the picture's tooltip and the details line
  local race = package.loaded["race"]
  local largeText = "Mu Split"
  if c.race and race and race.inRoom and race.inRoom() and race.room and race.room.status ~= "open" then
    local list = race.standings()
    local racers, mine = 0, nil
    for _, e in ipairs(list) do
      if e.rank then racers = racers + 1 end
      if e.me then mine = e end
    end
    local r = mine and mine.rank and ("Racing · " .. ordinal(mine.rank) .. " of " .. racers) or "Racing"
    details = r .. " · " .. details
    largeText = r
  end

  local act = { details = details:sub(1, 120), state = state:sub(1, 120), instance = false }
  if timestamps then act.timestamps = timestamps end
  if c.image ~= "" then act.assets = { large_image = c.image, large_text = largeText } end
  -- Discord only takes http(s) links, and labels up to 32 characters
  local url = (c.buttonUrl or ""):gsub("%s", "")
  if c.button and url:match("^https?://.+%..+") and (c.buttonLabel or "") ~= "" then
    act.buttons = { { label = c.buttonLabel:sub(1, 32), url = url:sub(1, 512) } }
  end
  -- re-send when the text changes, or when Discord's clock would be off by 2 s or more
  -- (game time pauses during loads; a split undone...)
  local key = act.details .. "|" .. act.state .. "|" .. largeText .. "|" .. (act.buttons and act.buttons[1].url or "")
  return act, key, timestamps and timestamps.start or nil
end

---------------------------------------------------------------------------
-- Linux: Discord is a native program there (its socket is $XDG_RUNTIME_DIR/discord-ipc-N),
-- which the engine under Wine can't reach, so we talk to it ourselves (LÖVE's socket.unix).
-- Same frames as on Windows: [int32 op][int32 length][JSON], little-endian.
---------------------------------------------------------------------------
local ipc = { sock = nil, buf = "", app = nil, nextTry = 0, want = nil }
D.ipc = ipc
local unixLib
if love.system.getOS() == "Linux" then
  local ok, m = pcall(require, "socket.unix")
  if ok then unixLib = m end
end
D.nativeLinux = unixLib ~= nil

local function le32(n)
  n = n % 4294967296
  return string.char(n % 256, math.floor(n / 256) % 256, math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
end
local function rd32(s, i)
  local a, b, c, d = s:byte(i, i + 3)
  return a + b * 256 + c * 65536 + d * 16777216
end
D.le32, D.rd32 = le32, rd32

local function ipcSend(op, body)
  if not ipc.sock then return false end
  local ok = ipc.sock:send(le32(op) .. le32(#body) .. body)
  if not ok then pcall(function() ipc.sock:close() end) ipc.sock = nil return false end
  return true
end

local function linuxPid()
  local f = io.open("/proc/self/stat", "r")
  if not f then return 0 end
  local s = f:read("*l") or ""
  f:close()
  return tonumber(s:match("^(%d+)")) or 0
end

local function ipcConnect(app)
  local rt = os.getenv("XDG_RUNTIME_DIR") or ("/run/user/" .. tostring(os.getenv("UID") or ""))
  local dirs = { rt, rt .. "/app/com.discordapp.Discord", rt .. "/snap.discord", os.getenv("TMPDIR") or "/tmp" }
  local make = type(unixLib) == "table" and (unixLib.stream or unixLib.tcp) or unixLib
  for _, dir in ipairs(dirs) do
    for i = 0, 9 do
      local okS, s = pcall(make)
      if okS and s then
        s:settimeout(0.05)
        if s:connect(dir .. "/discord-ipc-" .. i) then
          s:settimeout(0)
          ipc.sock, ipc.buf, ipc.app = s, "", app
          ipcSend(0, json.encode({ v = 1, client_id = app }))
          return true
        end
        pcall(function() s:close() end)
      end
    end
  end
  return false
end

-- read Discord's replies (they'd fill the socket otherwise), answer pings
local function ipcPump()
  if not ipc.sock then return end
  for _ = 1, 20 do
    local data, err, part = ipc.sock:receive(4096)
    local chunk = data or part
    if chunk and #chunk > 0 then ipc.buf = ipc.buf .. chunk end
    if err == "closed" then pcall(function() ipc.sock:close() end) ipc.sock = nil return end
    if not data then break end
  end
  while #ipc.buf >= 8 do
    local op, len = rd32(ipc.buf, 1), rd32(ipc.buf, 5)
    if #ipc.buf < 8 + len then break end
    local body = ipc.buf:sub(9, 8 + len)
    ipc.buf = ipc.buf:sub(9 + len)
    if op == 3 then ipcSend(4, body)
    elseif op == 2 then pcall(function() ipc.sock:close() end) ipc.sock = nil return end
  end
end

-- send a status (activity json, or "null") to Discord the right way for this OS
local function deliver(app, activityJson)
  if not D.nativeLinux then
    racenet.raw("discord " .. app .. " " .. activityJson)
    return
  end
  ipc.want = { app = app, json = activityJson }
  if ipc.sock and ipc.app ~= app then pcall(function() ipc.sock:close() end) ipc.sock = nil end
  if not ipc.sock then
    if love.timer.getTime() < ipc.nextTry then return end
    if not ipcConnect(app) then ipc.nextTry = love.timer.getTime() + 15 return end
  end
  ipcSend(1, '{"cmd":"SET_ACTIVITY","args":{"pid":' .. linuxPid() .. ',"activity":' .. activityJson
    .. '},"nonce":"' .. tostring(love.timer.getTime()):gsub("%.", "") .. '"}')
end
D.deliver = deliver

---------------------------------------------------------------------------
-- every frame
---------------------------------------------------------------------------
local lastKey, lastStart, lastSent, lastResend = nil, nil, -100, -100
local cleared = true

function D.update(dt)
  local now = love.timer.getTime()
  ipcPump()
  -- (Linux) Discord started after us, or restarted: send the status again once it's back
  if D.nativeLinux and not ipc.sock and ipc.want and now >= ipc.nextTry then deliver(ipc.want.app, ipc.want.json) end
  local V = package.loaded["timerview"]
  if not D.cfg.enabled or not validApp() or not V then
    if not cleared and validApp() then deliver(D.cfg.appId, "null") end
    cleared, lastKey = true, nil
    return
  end
  local act, key, start = D.build(V.S, V.liveTime and V.liveTime() or 0, os.time())
  local changed = key ~= lastKey or (start == nil) ~= (lastStart == nil)
    or (start and lastStart and math.abs(start - lastStart) >= 2000)
  -- (and once a minute anyway: Discord may have been restarted)
  if (changed or now - lastResend > 60) and now - lastSent >= 4 then
    lastKey, lastStart, lastSent, lastResend = key, start, now, now
    cleared = false
    deliver(D.cfg.appId, act and json.encode(act) or "null")
  end
end

return D
