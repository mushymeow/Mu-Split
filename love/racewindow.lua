-- The Race window: make or join a race, see who's in, get ready, start, chat.
-- It closes by itself when the countdown starts, so you see your timer; the race panel
-- in the timer shows the standings from then on. Reopen it any time (right-click > Race).

local theme = require("theme")
local ui = require("ui")
local W = require("widgets")
local windows = require("windows")
local race = require("race")

local RW = {}
local lg = love.graphics
local win = { title = "Race", w = 560, h = 640 }
local joinCode, chatText = "", ""

function RW.open()
  if windows.top() == win then return end
  race.unread = 0
  windows.push(win)
end
function RW.isOpen() for _, w in ipairs(windows.stack) do if w == win then return true end end return false end
function RW.close() if RW.isOpen() then windows.pop(win) end end

-- the countdown started: show the timer
race.onCountdown = function() RW.close() end

local function setting(label, key, x, y, w, tip)
  local v, changed = W.switch("race:cfg:" .. key, race.cfg[key], x, y, { label = label, w = w, tooltip = tip })
  if changed then race.cfg[key] = v race.saveCfg() end
  return y + 30
end

local function textRow(label, id, value, x, y, w, opt)
  ui.label(label, x, y, { h = theme.controlH, color = theme.textDim })
  local lw = 110
  local text, changed, committed = ui.textbox(id, value, x + lw, y, w - lw, theme.controlH, opt)
  return text, changed, committed, y + theme.controlH + 10
end

local function drawSetup(x, y, w)
  y = W.section("You", x, y, w)
  local name, changed, committed
  name, changed, committed, y = textRow("Your name", "race:name", race.cfg.name, x, y, w,
    { placeholder = "shown to the other runners", maxLength = 32 })
  if changed or committed then race.cfg.name = name race.saveCfg() end

  y = y + 6
  y = W.section("Race", x, y, w)
  local noServer = race.serverUrl() == nil
  local half = math.floor((w - 10) / 2)
  if ui.button("race:create", "Make a Race", x, y, half, theme.controlH + 6,
      { primary = true, disabled = noServer or race.status == "connecting",
        tooltip = "Makes a race and gives you a code to send to the others" }) then
    race.create()
  end
  local jx = x + half + 10
  local code, _, enter = ui.textbox("race:code", joinCode, jx, y + 3, half - 70, theme.controlH,
    { placeholder = "code", maxLength = 8 })
  joinCode = code:upper()
  if (ui.button("race:join", "Join", jx + half - 62, y + 3, 62, theme.controlH,
      { disabled = noServer or #joinCode < 4 or race.status == "connecting" }) or (enter and #joinCode >= 4)) then
    race.join(joinCode)
  end
  y = y + theme.controlH + 18

  if race.status == "connecting" then
    ui.label("Connecting…", x, y, { color = theme.textDim }) y = y + 24
  elseif race.error then
    lg.setFont(theme.fonts.ui)
    ui.color(theme.danger)
    lg.printf(race.error, x, y, w)
    local _, lines = theme.fonts.ui:getWrap(race.error, w)
    y = y + #lines * theme.fonts.ui:getHeight() + 10
  end
  return y
end

local function drawRoom(x, y, w, dt)
  local room = race.room
  local F = theme.fonts
  -- the code, big, with Copy
  y = W.section("Race code", x, y, w)
  lg.setFont(F.game)
  ui.color(theme.accent)
  lg.print(room.code or "", math.floor(x), math.floor(y))
  local cw = F.game:getWidth(room.code or "")
  if ui.button("race:copy", "Copy", x + cw + 14, y + (F.game:getHeight() - theme.controlH) / 2, 64, theme.controlH,
      { tooltip = "Copy the code to send to the others" }) then
    love.system.setClipboardText(room.code or "")
    race.toast("Code copied")
  end
  local status = ({ open = "In the lobby", countdown = "Starting…", running = "Racing", finished = "Finished" })[room.status] or ""
  if race.status == "reconnecting" then status = "Reconnecting…" end
  ui.label(status, x, y, { w = w, align = "right", h = F.game:getHeight(), color = theme.textDim })
  y = y + F.game:getHeight() + 6
  local game = (room.game ~= "" and room.game or "No game") .. ((room.category or "") ~= "" and ("  ·  " .. room.category) or "")
  ui.label(ui.ellipsize(F.ui, game, w), x, y, { color = theme.textDim })
  y = y + 26

  -- runners
  y = W.section("Runners", x, y, w)
  local list = race.standings()
  local host = race.isHost()
  for _, e in ipairs(list) do
    local p = e.p
    if e.me then ui.color(theme.accent, 0.10) ui.rect("fill", x - 6, y - 2, w + 12, 26, theme.radiusSmall) end
    -- dot / rank
    if room.status == "open" then
      ui.color(p.ready and theme.aheadGain or theme.textFaint)
      lg.circle(p.ready and "fill" or "line", x + 5, y + 11, 4)
    elseif e.rank then
      ui.label(tostring(e.rank), x, y, { h = 22, color = e.rank == 1 and theme.gold or theme.textDim, font = F.uiBold })
    end
    local name = (p.name or "?") .. (e.me and "  (you)" or "") .. (room.host == p.id and "  · host" or "")
    if p.connected == false then name = name .. "  · offline" end
    ui.label(ui.ellipsize(F.ui, name, w - 220), x + 20, y, { h = 22, font = e.me and F.uiBold or F.ui })
    local right
    if room.status == "open" then right = p.ready and "ready" or "not ready"
    elseif e.state == "finished" then right = (e.time and package.loaded["timerview"].fmtTime(e.time, 2) or "-") .. (e.delta and e.delta > 0 and ("  " .. race.fmtDelta(e.delta)) or "")
    elseif e.state == "racing" then right = ("split %d/%d"):format(e.done, e.total)
    elseif e.state == "forfeit" then right = "forfeited"
    else right = "watching" end
    local kickW = (host and not e.me and room.status == "open") and 58 or 0
    ui.label(right, x, y, { h = 22, w = w - kickW - (kickW > 0 and 8 or 0), align = "right", color = theme.textDim })
    if kickW > 0 and ui.button("race:kick:" .. p.id, "Remove", x + w - kickW, y, kickW, 22) then
      race.send({ t = "kick", id = p.id })
    end
    y = y + 28
  end
  y = y + 6

  -- what you can do now
  local bh = theme.controlH + 4
  local me = race.me()
  if room.status == "open" then
    local ready = me and me.ready
    if ui.button("race:ready", ready and "Not Ready" or "Ready", x, y, 120, bh, { primary = not ready }) then
      race.send({ t = "ready", ready = not ready })
    end
    if host then
      ui.label("Countdown", x + 140, y, { h = bh, color = theme.textDim })
      local cd, changed = ui.segmented("race:cd", { { value = 5, label = "5s" }, { value = 10, label = "10s" },
        { value = 15, label = "15s" }, { value = 30, label = "30s" } }, race.cfg.countdown, x + 214, y, 180, bh)
      if changed then race.cfg.countdown = cd race.saveCfg() end
      if ui.button("race:start", "Start Race", x + w - 120, y, 120, bh, { primary = true,
          tooltip = "Everyone in the room races. Everyone's timer starts when the countdown ends." }) then
        race.send({ t = "setup", countdown = race.cfg.countdown * 1000 })
        race.send({ t = "start" })
      end
    else
      ui.label("The host starts the race.", x + 140, y, { h = bh, color = theme.textFaint })
    end
  elseif room.status == "countdown" then
    if host and ui.button("race:cancel", "Cancel Countdown", x, y, 160, bh) then race.send({ t = "cancel" }) end
  elseif room.status == "running" then
    if me and me.racing and not me.finished and not me.forfeit then
      if ui.button("race:forfeit", "Forfeit", x, y, 120, bh) then race.send({ t = "forfeit" }) end
    end
  elseif room.status == "finished" then
    if host then
      if ui.button("race:rematch", "Rematch", x, y, 120, bh, { primary = true,
          tooltip = "Same room, same runners: everyone gets ready again" }) then race.send({ t = "rematch" }) end
    else
      ui.label("The host can start a rematch.", x, y, { h = bh, color = theme.textFaint })
    end
  end
  if ui.button("race:leave", "Leave", x + w - 120, y + (room.status == "open" and host and bh + 10 or 0), 120, bh) then
    race.leave()
  end
  y = y + bh + (room.status == "open" and host and bh + 10 or 0) + 16

  -- chat
  y = W.section("Chat", x, y, w)
  local chatBottom = y + 6 * 20
  local lines = {}
  for i = math.max(1, #race.chat - 5), #race.chat do lines[#lines + 1] = race.chat[i] end
  local cy = y
  for _, c in ipairs(lines) do
    lg.setFont(F.uiBold)
    ui.color(c.mine and theme.accent or theme.text)
    local nm = c.name .. ": "
    lg.print(nm, math.floor(x), math.floor(cy))
    lg.setFont(F.ui)
    ui.color(theme.text)
    lg.print(ui.ellipsize(F.ui, c.text, w - F.uiBold:getWidth(nm)), math.floor(x + F.uiBold:getWidth(nm)), math.floor(cy))
    cy = cy + 20
  end
  if #lines == 0 then ui.label("No messages yet.", x, y, { color = theme.textFaint }) end
  y = chatBottom
  local text, _, committed = ui.textbox("race:chat", chatText, x, y, w - 70, theme.controlH,
    { placeholder = "say something", maxLength = 200, blurOnEnter = false })
  chatText = text
  local send = ui.button("race:send", "Send", x + w - 62, y, 62, theme.controlH, { disabled = chatText == "" })
  if (send or (committed and ui.focus == "race:chat")) and chatText:match("%S") then
    race.send({ t = "chat", text = chatText })
    chatText = ""
    if ui.focus == "race:chat" then ui.focusText("race:chat", "") end
  end
  race.unread = 0
  return y + theme.controlH + 14
end

function win:draw(x, y, w, h, dt)
  local pad = 22
  local cx, cw = x + pad, w - pad * 2
  local cy = y + 18
  local inRoom = race.room ~= nil and (race.status == "in" or race.status == "reconnecting")
  if inRoom then cy = drawRoom(cx, cy, cw, dt) else cy = drawSetup(cx, cy, cw) end

  cy = cy + 4
  cy = W.section("Settings", cx, cy, cw)
  local half = math.floor((cw - 20) / 2)
  local y1 = setting("Start my timer at GO", "autoStart", cx, cy, half,
    "When the countdown ends, your timer starts by itself")
  y1 = setting("Countdown beeps", "beeps", cx, y1, half)
  local y2 = setting("Race panel in the timer", "panel", cx + half + 20, cy, half,
    "Standings between your splits and the big timer")
  y2 = setting("Reset = forfeit", "forfeitOnReset", cx + half + 20, y2, half,
    "Resetting your timer mid-race forfeits it")
  cy = math.max(y1, y2) + 4
  if not inRoom then
    local server, changed, committed
    server, changed, committed, cy = textRow("Race server", "race:server", race.cfg.server, cx, cy, cw,
      { placeholder = "https://musplit-race.<you>.workers.dev" })
    if changed or committed then race.cfg.server = server race.saveCfg() end
  end
end

function win:onClose() windows.pop(win) end

return RW
