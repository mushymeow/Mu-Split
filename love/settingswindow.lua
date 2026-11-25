-- The Settings window, two tabs:
--  * Timer: LiveSplit's settings (hotkey profiles and hotkeys, global hotkeys, reset warning,
--    sum of best, refresh rate, generated comparisons). Edits a local copy; OK sends it to the
--    engine, which saves settings.cfg.
--  * Mu Split: our own settings (Discord status, window, races, the in-game overlay). These
--    apply and save as soon as you change them.

local theme = require("theme")
local ui = require("ui")
local net = require("net")
local windows = require("windows")
local dialogs = require("dialogs")
local W = require("widgets")

local sw = {}
local lg = love.graphics
local D = nil          -- working copy
local waiting = false

local HOTKEYS = {
  { "split", "Start / Split" }, { "reset", "Reset" }, { "undo", "Undo Split" }, { "skip", "Skip Split" },
  { "pause", "Pause" }, { "toggleGlobal", "Toggle Global Hotkeys" },
  { "comparePrev", "Previous Comparison" }, { "compareNext", "Next Comparison" },
}

local function deepcopy(t)
  if type(t) ~= "table" then return t end
  local c = {}
  for k, v in pairs(t) do c[k] = deepcopy(v) end
  return c
end

function sw.onSnapshot(msg)
  sw.latest = msg                     -- main.lua also uses this for local hotkeys
  if waiting then
    D = deepcopy(msg)
    D.viewProfile = msg.profile
    waiting = false
  end
end

local win = { title = "Settings", w = 820, h = 680 }
local tab = "timer"

---------------------------------------------------------------------------
-- the Mu Split tab
---------------------------------------------------------------------------
local OVERLAY_KEYS = { "tab", "`", "insert", "home", "pageup", "scrolllock", "pause",
  "f6", "f7", "f8", "f9", "f10", "f11", "f12" }

local function drawMuSplit(x, y, w, h)
  local pad = 18
  local colW = math.floor((w - pad * 3) / 2)
  local lx, rx = x + pad, x + pad * 2 + colW
  local F = theme.fonts
  local function switch(id, label, on, cx, cy, tip)
    local v, changed = W.switch(id, on, cx, cy, { label = label, w = colW, tooltip = tip })
    return v, changed, cy + 30
  end

  ---------------------------------------------------------------- left
  local cy = y + 12
  local discord = require("discordrpc")
  cy = W.section("Discord", lx, cy, colW)
  local v, ch
  v, ch, cy = switch("mu:discord", "Show what I'm running on Discord", discord.cfg.enabled, lx, cy,
    "Your game, current split and time on your Discord profile")
  if ch then discord.setEnabled(v) end
  if not discord.validApp() then
    ui.label("Discord status isn't set up in this build yet.", lx, cy - 4, { font = F.small, color = theme.textFaint })
    cy = cy + 18
  end

  cy = cy + 8
  local app = require("appsettings")
  cy = W.section("Window", lx, cy, colW)
  v, ch, cy = switch("mu:top", "Always on top", app.cfg.alwaysOnTop, lx, cy, "Keep Mu Split above your game")
  if ch then app.setAlwaysOnTop(v) end
  v, ch, cy = switch("mu:border", "Hide title bar", app.cfg.borderless, lx, cy, "Drag the timer to move it; resize from its edges")
  if ch then app.setBorderless(v) end

  cy = cy + 8
  local race = require("race")
  cy = W.section("Races", lx, cy, colW)
  for _, r in ipairs({
    { "autoStart", "Start my timer at GO", "When the countdown ends, your timer starts by itself" },
    { "beeps", "Countdown beeps" },
    { "panel", "Race panel in the timer", "Standings between your splits and the big timer" },
    { "forfeitOnReset", "Reset = forfeit", "Resetting your timer mid-race forfeits it" },
  }) do
    v, ch, cy = switch("mu:race:" .. r[1], r[2], race.cfg[r[1]], lx, cy, r[3])
    if ch then race.cfg[r[1]] = v race.saveCfg() end
  end

  ---------------------------------------------------------------- right: overlay
  local ov = require("overlay")
  local oc = ov.cfg
  cy = y + 12
  cy = W.section("In-game overlay", rx, cy, colW)
  local labelW = 120
  local function drop(id, label, items, value, onChange)
    ui.label(label, rx, cy, { h = theme.controlH })
    local sel, changed = ui.dropdown(id, items, value, rx + labelW, cy, colW - labelW, theme.controlH)
    if changed then onChange(sel) ov.saveCfg() end
    cy = cy + theme.controlH + 8
  end
  local keys, haveKey = {}, false
  for _, k in ipairs(OVERLAY_KEYS) do
    keys[#keys + 1] = { label = ov.keyLabel(k), value = k }
    if k == oc.hotkey then haveKey = true end
  end
  if not haveKey and oc.hotkey then table.insert(keys, 1, { label = ov.keyLabel(oc.hotkey), value = oc.hotkey }) end
  drop("mu:ov:key", "Overlay key", keys, oc.hotkey, function(k) oc.hotkey = k end)
  drop("mu:ov:corner", "Position", {
    { label = "Top left", value = "top-left" }, { label = "Top centre", value = "top-center" },
    { label = "Top right", value = "top-right" }, { label = "Bottom left", value = "bottom-left" },
    { label = "Bottom centre", value = "bottom-center" }, { label = "Bottom right", value = "bottom-right" },
  }, oc.corner, function(c) oc.corner = c end)
  drop("mu:ov:scale", "Size", { { label = "75%", value = 0.75 }, { label = "100%", value = 1 }, { label = "125%", value = 1.25 },
    { label = "150%", value = 1.5 }, { label = "200%", value = 2 } }, oc.scale, function(c) oc.scale = c end)
  local ops = {}
  for _, o in ipairs({ 1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4 }) do ops[#ops + 1] = { label = math.floor(o * 100) .. "%", value = o } end
  drop("mu:ov:opacity", "Opacity", ops, oc.opacity, function(c) oc.opacity = c end)
  local displays = {}
  for i = 1, (love.window.getDisplayCount and love.window.getDisplayCount() or 1) do
    local n = love.window.getDisplayName and love.window.getDisplayName(i) or ("Display " .. i)
    displays[#displays + 1] = { label = i .. ": " .. n, value = i }
  end
  drop("mu:ov:display", "Monitor", displays, oc.display, function(c) oc.display = c end)
  cy = cy + 4
  for _, r in ipairs({
    { "showSplit", "Current split name" }, { "showDelta", "Delta against the comparison" },
    { "showCounter", "Split counter" }, { "showRta", "The other time (RTA / IGT) in small" },
    { "showLoading", "Dim the timer during loads" }, { "plate", "Background box", "Off: just outlined text over the game" },
    { "startInOverlay", "Start Mu Split in overlay mode" },
  }) do
    local nv, changed = W.switch("mu:ov:" .. r[1], oc[r[1]], rx, cy, { label = r[2], w = colW, tooltip = r[3] })
    if changed then oc[r[1]] = nv ov.saveCfg() end
    cy = cy + 28
  end
  cy = cy + 6
  if ui.button("mu:ov:enter", "Enter Overlay Mode", rx, cy, 170, theme.controlH,
      { tooltip = "Run your game in Borderless or Windowed mode: nothing can draw over exclusive fullscreen" }) then
    win:onClose()
    ov.enter()
  end
end

function sw.open(whichTab)
  tab = whichTab or tab
  D = nil
  waiting = true
  net.send("settings_get")
  net.send("hotkeys_suspend")   -- so pressing a key to set a hotkey doesn't also split
  windows.push(win)
end

function win:onClose()
  net.send("hotkeys_resume")
  windows.pop(win)
end

local function apply()
  local out = {
    profile = D.viewProfile, profileOrder = D.profileOrder, profiles = D.profiles,
    warnOnReset = D.warnOnReset, simpleSumOfBest = D.simpleSumOfBest,
    refreshRate = tonumber(D.refreshRate) or 40, serverPort = tonumber(D.serverPort) or 16834,
    hcpHistorySize = tonumber(D.hcpHistorySize) or 10, hcpNBestRuns = tonumber(D.hcpNBestRuns) or 20,
    generators = D.generators,
  }
  -- empty hotkeys must be sent as "" so the JSON keeps the key
  for _, p in pairs(out.profiles) do
    for _, hk in ipairs(HOTKEYS) do if p[hk[1]] == nil then p[hk[1]] = "" end end
  end
  net.send("settings_apply", out)   -- re-registers the hotkeys itself
  windows.pop(win)
end

local function uniqueName(base)
  local name, n = base, 2
  while D.profiles[name] do name = base .. " " .. n n = n + 1 end
  return name
end

function win:draw(x, y, w, h, dt)
  local pad = 18
  local F = theme.fonts
  -- tabs: LiveSplit's timer settings, and Mu Split's own
  local newTab = ui.segmented("set:tab", { { value = "timer", label = "Timer" }, { value = "musplit", label = "Mu Split" } },
    tab, x + pad, y + 12, 260, theme.controlH + 4)
  tab = newTab
  y, h = y + theme.controlH + 26, h - theme.controlH - 26
  ui.color(theme.border) lg.rectangle("fill", x, y - 8, w, 1)
  if tab == "musplit" then
    drawMuSplit(x, y, w, h)
    local by = y + h - 46
    ui.color(theme.border) lg.rectangle("fill", x, by - 10, w, 1)
    ui.label("These apply right away.", x + pad, by, { h = theme.controlH, color = theme.textFaint })
    if ui.button("set:close", "Close", x + w - pad - 92, by, 92, theme.controlH, { primary = true }) then win:onClose() end
    return
  end
  if not D then
    ui.label("Loading…", x, y + h / 2 - 10, { w = w, align = "center", color = theme.textDim })
    return
  end

  local colW = math.floor((w - pad * 3) / 2)
  local lx, rx = x + pad, x + pad * 2 + colW
  local cy = y + 16

  ---------------------------------------------------------------- hotkeys (left)
  ui.label("Hotkeys", lx, cy, { font = F.header, color = theme.textDim })
  cy = cy + 24
  local profItems = {}
  for _, n in ipairs(D.profileOrder) do profItems[#profItems + 1] = n end
  local sel, changed = ui.dropdown("set:profile", profItems, D.viewProfile, lx, cy, colW - 3 * 70 - 12, theme.controlH)
  if changed then D.viewProfile = sel end
  local pbx = lx + colW - 3 * 70 - 4
  if ui.button("set:pnew", "New", pbx, cy, 66, theme.controlH, { tooltip = "Copy this profile into a new one" }) then
    dialogs.input({ title = "New Hotkey Profile", label = "Profile name:", text = uniqueName(D.viewProfile), okLabel = "Create",
      onOk = function(name)
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == "" or D.profiles[name] then dialogs.error("That name is empty or already used.") return end
        local copy = deepcopy(D.profiles[D.viewProfile])
        copy.from = nil
        D.profiles[name] = copy
        table.insert(D.profileOrder, name)
        D.viewProfile = name
      end })
  end
  if ui.button("set:pren", "Rename", pbx + 70, cy, 66, theme.controlH) then
    local old = D.viewProfile
    dialogs.input({ title = "Rename Hotkey Profile", label = "New name:", text = old, okLabel = "Rename",
      onOk = function(name)
        name = (name or ""):gsub("^%s+", ""):gsub("%s+$", "")
        if name == old then return end
        if name == "" or D.profiles[name] then dialogs.error("That name is empty or already used.") return end
        local p = D.profiles[old]
        p.from = p.from or old
        D.profiles[old] = nil
        D.profiles[name] = p
        for i, n in ipairs(D.profileOrder) do if n == old then D.profileOrder[i] = name end end
        D.viewProfile = name
      end })
  end
  if ui.button("set:pdel", "Remove", pbx + 140, cy, 66, theme.controlH, { disabled = #D.profileOrder <= 1 }) then
    local old = D.viewProfile
    dialogs.message({ title = "Remove Hotkey Profile", text = "Remove the profile “" .. old .. "”?",
      buttons = { { label = "Remove", primary = true, action = function()
        D.profiles[old] = nil
        for i, n in ipairs(D.profileOrder) do if n == old then table.remove(D.profileOrder, i) break end end
        D.viewProfile = D.profileOrder[#D.profileOrder]
      end }, { label = "Cancel" } } })
  end
  cy = cy + theme.controlH + 14

  local p = D.profiles[D.viewProfile]
  local labelW = 160
  for _, hk in ipairs(HOTKEYS) do
    ui.label(hk[2], lx, cy, { h = theme.controlH, color = theme.text })
    local v, ch = ui.hotkey("set:hk:" .. hk[1], p[hk[1]], lx + labelW, cy, colW - labelW, theme.controlH)
    if ch then p[hk[1]] = v end
    cy = cy + theme.controlH + 6
  end
  ui.label("Click a box, then press a key. Backspace clears it.", lx, cy, { font = F.small, color = theme.textFaint })
  cy = cy + 24

  local _, gclick = ui.checkbox("set:global", "Global hotkeys", p.global, lx, cy,
    { tooltip = "Hotkeys work while other programs (your game) have focus" })
  if gclick then p.global = not p.global if not p.global then p.deactivateOthers = false end end
  cy = cy + 26
  local _, dclick = ui.checkbox("set:deact", "Don't send hotkeys to other programs", p.deactivateOthers, lx, cy,
    { disabled = not p.global, tooltip = "The game won't see the key when you press a hotkey" })
  if dclick then p.deactivateOthers = not p.deactivateOthers end
  cy = cy + 26
  local _, tclick = ui.checkbox("set:double", "Double tap prevention", p.doubleTap, lx, cy,
    { tooltip = "Ignore a second press of split/undo/skip within a short time" })
  if tclick then p.doubleTap = not p.doubleTap end
  cy = cy + 26
  local _, padclick = ui.checkbox("set:pads", "Allow gamepads as hotkeys", p.gamepads, lx, cy)
  if padclick then p.gamepads = not p.gamepads end
  cy = cy + 30
  ui.label("Hotkey delay (seconds)", lx, cy, { h = theme.controlH })
  local dv, _, dcommit = ui.textbox("set:delay", tostring(p.delay or 0), lx + labelW, cy, 90, theme.controlH)
  if dcommit then p.delay = math.max(0, tonumber(dv) or 0) end

  ---------------------------------------------------------------- general (right)
  cy = y + 16
  ui.label("General", rx, cy, { font = F.header, color = theme.textDim })
  cy = cy + 24
  local _, wclick = ui.checkbox("set:warn", "Ask before resetting when it would update times", D.warnOnReset, rx, cy)
  if wclick then D.warnOnReset = not D.warnOnReset end
  cy = cy + 26
  local _, sclick = ui.checkbox("set:sob", "Simple sum of best", D.simpleSumOfBest, rx, cy,
    { tooltip = "Sum of best from best segments only, not from segment history" })
  if sclick then D.simpleSumOfBest = not D.simpleSumOfBest end
  cy = cy + 34

  local function numberRow(id, label, key, tip)
    ui.label(label, rx, cy, { h = theme.controlH })
    local v, _, commit = ui.textbox(id, tostring(D[key] or ""), rx + colW - 100, cy, 100, theme.controlH,
      { numeric = true, tooltip = tip })
    if commit then D[key] = tonumber(v) or D[key] end
    cy = cy + theme.controlH + 8
  end
  numberRow("set:refresh", "Refresh rate (per second)", "refreshRate",
    "How often LiveSplit checks hotkeys and runs the autosplitter (20–300)")
  numberRow("set:port", "LiveSplit server port", "serverPort", "For tools that talk to LiveSplit's own server")

  cy = cy + 10
  ui.label("Comparisons to generate", rx, cy, { font = F.header, color = theme.textDim })
  cy = cy + 24
  local listH = y + h - 70 - cy - 2 * (theme.controlH + 8) - 8
  local gens = D.generators or {}
  ui.color(theme.input, 0.5) ui.rect("fill", rx, cy, colW, listH, theme.radiusSmall)
  ui.color(theme.border) ui.rect("line", rx + 0.5, cy + 0.5, colW - 1, listH - 1, theme.radiusSmall)
  local oy = ui.beginScroll("set:gens", rx, cy + 4, colW, listH - 8, #gens * 26 + 4)
  for i, g in ipairs(gens) do
    local _, c = ui.checkbox("set:gen:" .. g.name, g.name, g.enabled, rx + 10, cy + 6 + (i - 1) * 26 - oy)
    if c then g.enabled = not g.enabled end
  end
  ui.endScroll()
  cy = cy + listH + 8
  numberRow("set:hcpsize", "Balanced PB: history size", "hcpHistorySize")
  numberRow("set:hcpn", "Balanced PB: best runs used", "hcpNBestRuns")

  ---------------------------------------------------------------- footer
  local by = y + h - 46
  ui.color(theme.border) lg.rectangle("fill", x, by - 10, w, 1)
  if ui.button("set:ok", "OK", x + w - pad - 92, by, 92, theme.controlH, { primary = true }) then apply() end
  if ui.button("set:cancel", "Cancel", x + w - pad - 92 * 2 - 8, by, 92, theme.controlH) then win:onClose() end
end

return sw
