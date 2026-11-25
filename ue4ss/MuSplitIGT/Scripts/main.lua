-- Mu Split IGT — an in-game speedrun timer for Poppy Playtime: Chapter 4 (UE4SS Lua mod)
--
-- Like SpeedRunIGT (Minecraft) and Menzo's SpeedrunTimer (Hello Neighbor): the timer is
-- drawn in the game, starts by itself, takes pauses and loads out of IGT, splits on
-- checkpoints and items, and keeps your personal bests. Everything is configurable from
-- the in-game menu (Tab), and saved.
--
-- Start / split / load rules come from the LiveSplit autosplitter by TheDementedSalad &
-- Lox (PoppyPlaytimeCh4.asl), reading the same game values by name (see game.lua).

---------------------------------------------------------------------------
-- LOOK & FEEL: tweak these
---------------------------------------------------------------------------
-- Animation and style constants. Colours are { r, g, b } from 0 to 1.
-- Everything that also has a menu setting (backdrop, accent bar, second timer
-- mode...) is in DEFAULTS further down; those are only the first-run values,
-- after that the in-game menu (Tab) and settings.lua win.
local THEME = {
  slideTime     = 0.25,               -- seconds: old split slides up/out, new one slides up/in
  slideDistance = 15,                 -- px the splits slide
  popTime       = 0.45,               -- seconds for the hit "pop" to settle (ease-out cubic)
  popScale      = 1.12,               -- how big the new split pops on the frame it triggers
  flashColor    = { 1, 0.94, 0.72 },  -- bright white/gold flash, eases back to the split colour
  labelDim      = 0.6,                -- labels (IGT / RTA / SPLIT) = digit colour x this
  labelScale    = 0.42,               -- main timer label size = main timer size x this
  digitWidth    = 0.64,               -- digit width / font size, for the no-jitter digit box
}

local R = require("reflect")
local HUD = require("hud")
local Store = require("store")
local SPLITS = require("ch4_splits")
local Game = require("game")

local log, logOnce, startsWith = Game.log, Game.logOnce, Game.startsWith
log("loading (mod folder: %s)", Store.dir)

---------------------------------------------------------------------------
-- settings
---------------------------------------------------------------------------
-- every keyboard key UE4SS knows is listened to, so any key can be bound in the menu
-- (mouse buttons are left alone). Menu navigation keys are fixed:
local NAV = { UP_ARROW = true, DOWN_ARROW = true, LEFT_ARROW = true, RIGHT_ARROW = true,
  RETURN = true, PAGE_UP = true, PAGE_DOWN = true, BACKSPACE = true }
local BINDS = { "menuKey", "resetKey", "splitKey", "pauseKey", "hideKey" }   -- the bindable actions

local DEFAULTS = {
  -- what's shown
  hudVisible = true, mainMethod = "IGT", showLabels = true,
  labelIGT = "IGT", labelRTA = "RTA",
  -- SecondaryTimerMode: what the second row shows
  --   "RTA"    total real time (or IGT, if the main timer is set to RTA)
  --   "SPLIT"  segment time: IGT since the last split, back to 0:00.00 on every split
  --   "HIDDEN" no second row
  secondaryMode = "RTA",
  showSplit = true,          -- the single-split ticker under the timers
  animateSplits = true,      -- slide / pop / flash when a split triggers
  showStatus = true, showDelta = true, showPB = false, showAttempts = false,
  showCheckpoint = false, showHint = true, paceColour = false,
  -- layout
  corner = "top-right", offsetX = 0, offsetY = 0, margin = 28, align = "auto",
  mainSize = 34, secondSize = 20, splitSize = 16, infoSize = 14, lineGap = 2,
  -- backdrop: RGBA(10, 10, 14, 0.45) ("Ink" at 45%), rounded corners, 12 px padding
  background = true, bgColor = "Ink", bgOpacity = 0.45, padding = 12, cornerRadius = 10,
  -- thin accent bar down the left edge
  accentBar = true, accentColor = "Lavender", accentWidth = 3,
  monoDigits = true,         -- monospace digits if the game ships one (else Roboto's tabular digits)
  fontStyle = "Default", outline = 0, shadow = true, shadowOffset = 2, shadowColor = "Black",
  -- colours
  colorMain = "White", colorIdle = "Light grey", colorFinished = "Gold", colorPaused = "Grey",
  colorLoading = "Grey", colorSecondary = "Light grey", colorSplits = "Pink",
  colorAhead = "Green", colorBehind = "Red", colorGold = "Gold", colorInfo = "Light grey",
  -- time format
  decimals = 3, decimalsSecondary = 2, decimalsSplits = 2, leadingZero = false, alwaysHours = false,
  -- timer behaviour
  autoStart = true, autoFinish = true, autoResetMenu = false,
  removePauses = true, removeLoadScreens = true, removeHitches = true, hitchMs = 250, pauseInMenu = false,
  -- keys
  menuKey = "BACKSPACE", resetKey = "F5", splitKey = "NONE", pauseKey = "NONE", hideKey = "NONE",
  -- splits
  enabled = {},
  styleVersion = 3,
}
local LAYOUT_KEYS = {   -- changing these rebuilds the widget
  secondaryMode = true, showSplit = true, showStatus = true, showPB = true, showAttempts = true, showCheckpoint = true,
  cornerRadius = true, accentBar = true, accentColor = true, accentWidth = true, monoDigits = true,
  decimals = true, decimalsSecondary = true, leadingZero = true, alwaysHours = true,
  corner = true, offsetX = true, offsetY = true, margin = true, align = true, mainSize = true, secondSize = true,
  splitSize = true, infoSize = true, lineGap = true, background = true, bgColor = true, bgOpacity = true, padding = true,
  fontStyle = true, outline = true, shadow = true, shadowOffset = true, shadowColor = true, hudVisible = true,
}

local saved = Store.load("settings.lua")
local cfg = Store.merge(saved, DEFAULTS)
-- settings saved before the new look: switch the backdrop on once (it's in the menu after)
if saved and (saved.styleVersion or 1) < 2 then
  cfg.background, cfg.bgColor, cfg.bgOpacity, cfg.padding = true, "Ink", 0.45, 12
end
-- the menu moved from Tab to Backspace (once; it's changeable under Keys)
if saved and (saved.styleVersion or 1) < 3 and cfg.menuKey == "TAB" then cfg.menuKey = "BACKSPACE" end
if saved and (saved.styleVersion or 1) < 3 then
  cfg.styleVersion = 3
  Store.save("settings.lua", cfg)
end

local records = Store.merge(Store.load("records.lua"), {
  attempts = 0, finished = 0, pbIgt = nil, pbRta = nil, pbSplits = {}, bestSplits = {}, history = {},
})

local needsRebuild = true
local function saveSettings() Store.save("settings.lua", cfg) end
local function saveRecords() Store.save("records.lua", records) end
local function color(name) return HUD.color(name) end

---------------------------------------------------------------------------
-- split options (from the autosplitter's settings file)
---------------------------------------------------------------------------
local FINAL_ID = "FinalSplit"
local FINAL_LABEL = "Fallen Down the Hole"
local labels = {}
local function index(list)
  for _, n in ipairs(list) do
    labels[n.id] = n.label
    if n.children then index(n.children) end
  end
end
index(SPLITS)
labels[FINAL_ID] = FINAL_LABEL

local function leaves(node, out)
  out = out or {}
  if node.children then for _, c in ipairs(node.children) do leaves(c, out) end
  elseif node.id ~= FINAL_ID then out[#out + 1] = node end
  return out
end
local function countOn(node)
  local on, total = 0, 0
  for _, l in ipairs(leaves(node)) do
    total = total + 1
    if cfg.enabled[l.id] then on = on + 1 end
  end
  return on, total
end
local function findNode(id, list)
  for _, n in ipairs(list or SPLITS) do
    if n.id == id then return n end
    if n.children then local f = findNode(id, n.children) if f then return f end end
  end
end

-- the raw tag may or may not carry a prefix: match it to the autosplitter's ids
local function checkpointId(raw)
  if not raw then return nil end
  if labels[raw] then return raw end
  local i = raw:find(".", 1, true)
  local rest = i and raw:sub(i + 1) or raw
  if labels[rest] then return rest end
  return raw:match("(Checkpoint%..+)$") or rest
end

---------------------------------------------------------------------------
-- formatting
---------------------------------------------------------------------------
local function fmt(sec, decimals)
  if sec == nil then return "-" end
  decimals = decimals or cfg.decimals
  local neg = sec < 0
  sec = math.abs(sec)
  local factor = 10 ^ decimals
  local total = math.floor(sec * factor) / factor   -- truncate, never round up
  local h = math.floor(total / 3600)
  local m = math.floor(total / 60) % 60
  local s = total % 60
  local sfmt = decimals > 0 and ("%0" .. (decimals + 3) .. "." .. decimals .. "f") or "%02d"
  local mfmt = cfg.leadingZero and "%02d" or "%d"
  local out
  if h > 0 or cfg.alwaysHours then out = string.format("%d:%02d:" .. sfmt, h, m, s)
  else out = string.format(mfmt .. ":" .. sfmt, m, s) end
  return (neg and "-" or "") .. out
end

local function fmtDelta(sec)
  if sec == nil then return "" end
  local sign = sec < 0 and "-" or "+"
  sec = math.abs(sec)
  if sec < 60 then return sign .. string.format("%.1f", math.floor(sec * 10) / 10) end
  return sign .. fmt(sec, 1)
end

local KEY_NAMES = { TAB = "Tab", INS = "Insert", DEL = "Delete", NONE = "None", OEM_THREE = "`",
  PAUSE = "Pause", SCROLL_LOCK = "Scroll Lock", DECIMAL = "Num .", ADD = "Num +", SUBTRACT = "Num -",
  MULTIPLY = "Num *", DIVIDE = "Num /", RETURN = "Enter", ESCAPE = "Esc", BACKSPACE = "Backspace",
  SPACE = "Space", CAPS_LOCK = "Caps Lock", PAGE_UP = "Page Up", PAGE_DOWN = "Page Down",
  OEM_ONE = ";", OEM_TWO = "/", OEM_FOUR = "[", OEM_FIVE = "\\", OEM_SIX = "]", OEM_SEVEN = "'",
  OEM_PLUS = "=", OEM_MINUS = "-", OEM_COMMA = ",", OEM_PERIOD = ".",
  UP_ARROW = "Up", DOWN_ARROW = "Down", LEFT_ARROW = "Left", RIGHT_ARROW = "Right" }
local NUMS = { "ZERO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE" }
for i, n in ipairs(NUMS) do
  KEY_NAMES["NUM_" .. n] = "Num " .. (i - 1)
  KEY_NAMES[n] = tostring(i - 1)
end
local function keyName(k)
  if not k then return "None" end
  if KEY_NAMES[k] then return KEY_NAMES[k] end
  -- LEFT_SHIFT -> Left Shift
  return (k:lower():gsub("_", " "):gsub("(%a)([%w]*)", function(a, b) return a:upper() .. b end))
end

---------------------------------------------------------------------------
-- run state
---------------------------------------------------------------------------
local run = {
  phase = "idle",          -- idle | running | finished
  igt = 0, rta = 0, manualPause = false, lastSplitIgt = 0,
  splits = {}, completed = {}, toComplete = {}, inventory = {},
  lastCheckpoint = nil, lastItemCount = nil,
  loading = false, paused = false, newPb = false, manualCount = 0,
}

local function resetRun()
  run.phase, run.igt, run.rta, run.manualPause, run.lastSplitIgt = "idle", 0, 0, false, 0
  run.splits, run.completed, run.toComplete, run.inventory = {}, {}, {}, {}
  run.newPb, run.lastItemCount, run.manualCount = false, nil, 0
  log("timer reset")
end

local function startRun()
  resetRun()
  run.phase = "running"
  records.attempts = (records.attempts or 0) + 1
  saveRecords()
  log("timer started (attempt %d)", records.attempts)
end

local function addSplit(id, label)
  label = label or labels[id] or id
  local s = { id = id, label = label, igt = run.igt, rta = run.rta }
  run.splits[#run.splits + 1] = s
  run.lastSplitIgt = run.igt   -- the SPLIT (segment) timer starts again from here
  local best = records.bestSplits[id]
  if not best or run.igt < best then records.bestSplits[id] = run.igt s.best = best ~= nil end
  log("split: %s at %s", label, fmt(run.igt))
end

local function finishRun()
  run.phase = "finished"
  records.finished = (records.finished or 0) + 1
  if not records.pbIgt or run.igt < records.pbIgt then
    run.newPb = true
    records.pbIgt, records.pbRta = run.igt, run.rta
    records.pbSplits = {}
    for _, s in ipairs(run.splits) do records.pbSplits[s.id] = s.igt end
  end
  table.insert(records.history, 1, { igt = run.igt, rta = run.rta, date = os.date("%Y-%m-%d %H:%M"), splits = #run.splits })
  while #records.history > 50 do table.remove(records.history) end
  saveRecords()
  log("finished: IGT %s, RTA %s%s", fmt(run.igt), fmt(run.rta), run.newPb and " (new PB)" or "")
end

local function manualSplit()
  if run.phase == "idle" then startRun() return end
  if run.phase ~= "running" then return end
  run.manualCount = run.manualCount + 1
  addSplit("manual:" .. run.manualCount, "Split " .. run.manualCount)
end

---------------------------------------------------------------------------
-- ASL split {}: checkpoint + item splits, and the fixed final split
---------------------------------------------------------------------------
local function anyItemSplitOn()
  for id in pairs(cfg.enabled) do if id:sub(1, 3) == "[+]" then return true end end
  return false
end

local T   -- per-frame state, set up further down
local lastItemRead = -1e9
local function checkSplits(pawn, now)
  local cp = checkpointId(Game.checkpoint(now, T.worldObj))

  -- checkpoint splits
  if cp and cp ~= run.lastCheckpoint then
    -- lastCheckpoint only ever holds a real checkpoint, so a brief "None" while a
    -- level streams in doesn't count as reaching it again
    if cfg.enabled[cp] and not run.completed[cp] then
      run.completed[cp] = true
      addSplit(cp)
    end
    run.lastCheckpoint = cp
  end

  -- items: only read when something needs them (item splits on, or near the end)
  local atEnd = cp == "Checkpoint.TheLabsEntrance.2"
  if not (atEnd or anyItemSplitOn()) or now - lastItemRead < 0.1 then return end
  lastItemRead = now
  if not Game.isPlayer(pawn) then return end
  local items, n = Game.items(pawn)
  if not items then return end

  for _, it in ipairs(items) do
    local setting
    local old = run.inventory[it.id]
    if old ~= nil then
      if old < it.used then setting = string.format("[+] %s (%d)", it.id, it.used) end
    else
      setting = string.format("[+] %s (!)", it.id)
    end
    run.inventory[it.id] = it.used
    if setting then
      run.toComplete[setting] = true
      if cfg.enabled[setting] and not run.completed[setting] then
        run.completed[setting] = true
        addSplit(setting)
        break   -- one split per check, like the ASL
      end
    end
  end

  -- final split: in "The Labs Entrance 2" and an item gets used up
  if atEnd and run.lastItemCount and n == run.lastItemCount - 1 then
    addSplit(FINAL_ID)
    if cfg.autoFinish then finishRun() end
  end
  run.lastItemCount = n
end

---------------------------------------------------------------------------
-- display
---------------------------------------------------------------------------
local function hudLayout()
  local info = {}
  if cfg.showStatus then info[#info + 1] = { key = "status", size = cfg.infoSize } end
  if cfg.showPB then info[#info + 1] = { key = "pb", size = cfg.infoSize } end
  if cfg.showAttempts then info[#info + 1] = { key = "attempts", size = cfg.infoSize } end
  if cfg.showCheckpoint then info[#info + 1] = { key = "cp", size = cfg.infoSize } end
  local theme = {}
  for k, v in pairs(THEME) do theme[k] = v end
  theme.animate = cfg.animateSplits
  return {
    theme = theme,
    mainChars = #fmt(3599.999, cfg.decimals),   -- room for up to 59:59 without the box growing
    second = cfg.secondaryMode ~= "HIDDEN" and { size = cfg.secondSize, chars = #fmt(3599.999, cfg.decimalsSecondary) } or nil,
    ticker = cfg.showSplit and { size = cfg.splitSize } or nil,
    info = info,
  }
end

local hintUntil = nil

local function label(text) return (cfg.showLabels and text) or "" end

local function updateHud(now, lastCp)
  HUD.setHudVisible(cfg.hudVisible)

  local main = color(cfg.colorMain)
  local last = run.splits[#run.splits]
  local lastDelta = last and records.pbSplits[last.id] and (last.igt - records.pbSplits[last.id]) or nil
  if run.phase == "idle" then main = color(cfg.colorIdle)
  elseif run.phase == "finished" then main = run.newPb and color(cfg.colorFinished) or color(cfg.colorMain)
  elseif run.manualPause or run.paused then main = color(cfg.colorPaused)
  elseif run.loading then main = color(cfg.colorLoading)
  elseif cfg.paceColour and lastDelta then main = lastDelta < 0 and color(cfg.colorAhead) or color(cfg.colorBehind) end

  -- main timer
  local mainIsIgt = cfg.mainMethod == "IGT"
  HUD.setTime("main", label(mainIsIgt and cfg.labelIGT or cfg.labelRTA),
    fmt(mainIsIgt and run.igt or run.rta, cfg.decimals), main)

  -- second row: RTA (the other timer) or the segment timer
  if cfg.secondaryMode == "SPLIT" then
    HUD.setTime("second", label("SPLIT"), fmt(math.max(0, run.igt - run.lastSplitIgt), cfg.decimalsSecondary),
      color(cfg.colorSecondary))
  elseif cfg.secondaryMode == "RTA" then
    HUD.setTime("second", label(mainIsIgt and cfg.labelRTA or cfg.labelIGT),
      fmt(mainIsIgt and run.rta or run.igt, cfg.decimalsSecondary), color(cfg.colorSecondary))
  end

  local status = ""
  if run.phase == "running" then
    if run.manualPause then status = "PAUSED"
    elseif run.paused then status = "GAME PAUSED"
    elseif run.loading then status = "LOADING" end
  elseif run.phase == "finished" then
    if run.newPb then status = "FINISHED  ·  NEW PERSONAL BEST"
    elseif records.pbIgt then status = "FINISHED  ·  " .. fmtDelta(run.igt - records.pbIgt) .. " vs PB"
    else status = "FINISHED" end
  elseif cfg.showHint and hintUntil and now < hintUntil then
    status = keyName(cfg.menuKey) .. ": timer settings"
  end
  HUD.set("status", status, color(cfg.colorInfo))

  -- the split ticker: only the latest split (a new one slides in with a pop)
  if last then
    local name = last.label
    if #name > 30 then name = name:sub(1, 29) .. "…" end
    local value, vcol = fmt(last.igt, cfg.decimalsSplits), color(cfg.colorSplits)
    local pb = records.pbSplits[last.id]
    if cfg.showDelta and pb and not (run.newPb and run.phase == "finished") then
      local d = last.igt - pb
      value = fmtDelta(d) .. "   " .. value
      vcol = last.best and color(cfg.colorGold) or (d < 0 and color(cfg.colorAhead) or color(cfg.colorBehind))
    elseif last.best then
      vcol = color(cfg.colorGold)
    end
    HUD.showSplit({ id = (records.attempts or 0) .. ":" .. #run.splits, name = name, value = value,
      nameRgb = color(cfg.colorSplits), valueRgb = vcol })
  else
    HUD.showSplit(nil)
  end

  HUD.set("pb", "PB  " .. fmt(records.pbIgt, cfg.decimalsSplits), color(cfg.colorInfo))
  HUD.set("attempts", string.format("Attempt %d  ·  %d finished", records.attempts or 0, records.finished or 0), color(cfg.colorInfo))
  HUD.set("cp", lastCp and (labels[lastCp] or lastCp) or "-", color(cfg.colorInfo))
end

---------------------------------------------------------------------------
-- settings menu: pages you move through with the arrow keys
---------------------------------------------------------------------------
local menu = { open = false, stack = {}, confirm = nil, expanded = {} }
local pages = {}

local function cycle(list, value, dir)
  local idx = 1
  for i, v in ipairs(list) do if v == value then idx = i end end
  return list[((idx - 1 + dir) % #list) + 1]
end
local function onOff(b) return b and "On" or "Off" end

-- helpers to make rows
local function setKey(key, value)
  cfg[key] = value
  if LAYOUT_KEYS[key] then needsRebuild = true end
  saveSettings()
end
local function toggle(label, key, tip)
  return { label = label, value = onOff(cfg[key]), tip = tip, change = function() setKey(key, not cfg[key]) end }
end
local function choice(label, key, list, names)
  local shown = names and names[cfg[key]] or tostring(cfg[key])
  return { label = label, value = shown, change = function(dir) setKey(key, cycle(list, cfg[key], dir)) end }
end
local function number(label, key, step, lo, hi, unit)
  local v = cfg[key]
  local shown = (math.floor(v) == v) and tostring(v) or string.format("%.2f", v)
  return { label = label, value = shown .. (unit or ""), change = function(dir)
    local nv = math.max(lo, math.min(hi, v + step * dir))
    nv = math.floor(nv * 100 + 0.5) / 100
    setKey(key, nv)
  end }
end
local function colorRow(label, key) return choice(label, key, HUD.colorNames()) end
local function link(label, page) return { label = label, value = "›", page = page } end
local function header(t) return { label = t, header = true } end
local function info(t, v) return { label = t, value = v, info = true } end
local function action(label, fn, confirm) return { label = label, action = fn, confirm = confirm } end

pages.main = function()
  local rows = {
    link("Display", "display"),
    link("Layout & size", "layout"),
    link("Colours", "colours"),
    link("Time format", "format"),
    link("Timer behaviour", "timer"),
    link("Splits", "splits"),
    link("Keys", "keys"),
    link("Records", "records"),
    header("Quick actions"),
    action("Reset timer", resetRun),
  }
  if run.phase == "idle" then rows[#rows + 1] = action("Start timer now", startRun)
  elseif run.phase == "running" then
    rows[#rows + 1] = action(run.manualPause and "Resume timer" or "Pause timer", function() run.manualPause = not run.manualPause end)
    rows[#rows + 1] = action("Finish run now", function() addSplit("manual:end", "Finished (manual)") finishRun() end, true)
  end
  rows[#rows + 1] = action(cfg.hudVisible and "Hide timer" or "Show timer", function() setKey("hudVisible", not cfg.hudVisible) end)
  rows[#rows + 1] = action("Reset all settings to default", function()
    local keep = cfg.enabled
    for k, v in pairs(DEFAULTS) do cfg[k] = type(v) == "table" and {} or v end
    cfg.enabled = keep
    needsRebuild = true
    saveSettings()
  end, true)
  return "Mu Split IGT  ·  Poppy Playtime Chapter 4", rows
end

pages.display = function()
  return "Display", {
    choice("Main timer", "mainMethod", { "IGT", "RTA" }, { IGT = "In-game time (IGT)", RTA = "Real time (RTA)" }),
    choice("Second timer", "secondaryMode", { "RTA", "SPLIT", "HIDDEN" },
      { RTA = "RTA (total real time)", SPLIT = "SPLIT (segment time)", HIDDEN = "Hidden" }),
    toggle("Labels (IGT / RTA)", "showLabels"),
    choice("IGT label", "labelIGT", { "IGT", "In-Game", "Game Time", "Time", "" }, { [""] = "(none)" }),
    choice("RTA label", "labelRTA", { "RTA", "Real", "Real Time", "" }, { [""] = "(none)" }),
    toggle("Status line (LOADING, FINISHED…)", "showStatus"),
    toggle("Split ticker (latest split)", "showSplit"),
    toggle("Split animations (slide, pop, flash)", "animateSplits"),
    toggle("Delta to personal best", "showDelta"),
    toggle("Colour the timer by pace", "paceColour"),
    toggle("Personal best line", "showPB"),
    toggle("Attempt counter", "showAttempts"),
    toggle("Current checkpoint name", "showCheckpoint"),
    toggle("\"Tab: settings\" hint at start", "showHint"),
  }
end

pages.layout = function()
  local cornerNames = { ["top-left"] = "Top left", top = "Top", ["top-right"] = "Top right", left = "Left",
    center = "Centre", right = "Right", ["bottom-left"] = "Bottom left", bottom = "Bottom", ["bottom-right"] = "Bottom right" }
  return "Layout & size", {
    choice("Position", "corner", HUD.CORNER_ORDER, cornerNames),
    number("Move left / right", "offsetX", 10, -3000, 3000, " px"),
    number("Move up / down", "offsetY", 10, -3000, 3000, " px"),
    number("Distance from the edge", "margin", 4, 0, 200, " px"),
    choice("Text alignment", "align", { "auto", "left", "center", "right" }, { auto = "Auto", left = "Left", center = "Centre", right = "Right" }),
    number("Main timer size", "mainSize", 2, 10, 120),
    number("Other timer size", "secondSize", 2, 8, 80),
    number("Split text size", "splitSize", 1, 8, 60),
    number("Info text size", "infoSize", 1, 8, 60),
    number("Line spacing", "lineGap", 1, 0, 30, " px"),
    choice("Font style", "fontStyle", { "Default", "Regular", "Bold", "Light", "Italic", "BoldItalic" }, { BoldItalic = "Bold italic" }),
    number("Text outline", "outline", 1, 0, 6),
    toggle("Text shadow", "shadow"),
    number("Shadow distance", "shadowOffset", 1, 1, 6, " px"),
    colorRow("Shadow colour", "shadowColor"),
    toggle("Background box", "background"),
    colorRow("Background colour", "bgColor"),
    number("Background opacity", "bgOpacity", 0.05, 0, 1),
    number("Background padding", "padding", 2, 0, 60, " px"),
    number("Corner rounding", "cornerRadius", 1, 0, 30, " px"),
    toggle("Accent bar", "accentBar"),
    colorRow("Accent colour", "accentColor"),
    number("Accent bar width", "accentWidth", 1, 1, 10, " px"),
    toggle("Monospace digits (if available)", "monoDigits"),
  }
end

pages.colours = function()
  return "Colours", {
    colorRow("Timer (running)", "colorMain"),
    colorRow("Timer (not started)", "colorIdle"),
    colorRow("Timer (finished, new PB)", "colorFinished"),
    colorRow("Timer (paused)", "colorPaused"),
    colorRow("Timer (loading)", "colorLoading"),
    colorRow("Other timer", "colorSecondary"),
    colorRow("Splits", "colorSplits"),
    colorRow("Ahead of PB", "colorAhead"),
    colorRow("Behind PB", "colorBehind"),
    colorRow("Best split ever", "colorGold"),
    colorRow("Info lines", "colorInfo"),
    colorRow("Accent bar", "accentColor"),
  }
end

pages.format = function()
  return "Time format", {
    number("Main timer decimals", "decimals", 1, 0, 3),
    number("Other timer decimals", "decimalsSecondary", 1, 0, 3),
    number("Split decimals", "decimalsSplits", 1, 0, 3),
    toggle("Leading zero (00:00 instead of 0:00)", "leadingZero"),
    toggle("Always show hours", "alwaysHours"),
    info("Example", fmt(754.3219)),
  }
end

pages.timer = function()
  local hitch = { 0, 100, 150, 250, 400, 600 }
  return "Timer behaviour", {
    toggle("Start automatically", "autoStart", "When the run starts, like the autosplitter"),
    toggle("Stop at the final split", "autoFinish"),
    toggle("Reset when back at the main menu", "autoResetMenu"),
    toggle("Take pauses out of IGT", "removePauses"),
    toggle("Take loading screens out of IGT", "removeLoadScreens"),
    { label = "Take load hitches out of IGT", value = cfg.removeHitches and ("over " .. cfg.hitchMs .. " ms") or "Off",
      change = function(dir)
        local cur = cfg.removeHitches and cfg.hitchMs or 0
        local nxt = cycle(hitch, cur, dir)
        cfg.removeHitches = nxt > 0
        if nxt > 0 then cfg.hitchMs = nxt end
        saveSettings()
      end },
    toggle("Pause the game while this menu is open", "pauseInMenu"),
    info("RTA always counts everything."),
  }
end

pages.splits = function()
  local rows = {}
  local allOn, allTotal = 0, 0
  for _, g in ipairs(SPLITS) do local on, t = countOn(g) allOn, allTotal = allOn + on, allTotal + t end
  rows[#rows + 1] = info("Turned on", string.format("%d of %d", allOn, allTotal))
  rows[#rows + 1] = action("All checkpoints on", function()
    for _, l in ipairs(leaves(findNode("Checkpoint"))) do cfg.enabled[l.id] = true end
    saveSettings()
  end)
  rows[#rows + 1] = action("Key items on", function()
    for _, l in ipairs(leaves(findNode("Items"))) do cfg.enabled[l.id] = true end
    saveSettings()
  end)
  rows[#rows + 1] = action("Turn every split off", function() cfg.enabled = {} saveSettings() end, true)
  rows[#rows + 1] = header("Enter opens a group  ·  → all on  ·  ← all off")

  local function addNode(node, depth)
    local pad = string.rep("   ", depth)
    if node.children then
      local on, total = countOn(node)
      local open = menu.expanded[node.id]
      rows[#rows + 1] = {
        label = pad .. (open and "▾ " or "▸ ") .. node.label, value = on .. "/" .. total,
        action = function() menu.expanded[node.id] = not menu.expanded[node.id] end,
        change = function(dir)
          for _, l in ipairs(leaves(node)) do cfg.enabled[l.id] = dir > 0 or nil end
          saveSettings()
        end,
      }
      if open then for _, c in ipairs(node.children) do addNode(c, depth + 1) end end
    elseif node.id == FINAL_ID then
      rows[#rows + 1] = info(pad .. "   " .. FINAL_LABEL, "always on")
    else
      local flip = function() cfg.enabled[node.id] = (not cfg.enabled[node.id]) or nil saveSettings() end
      rows[#rows + 1] = { label = pad .. "   " .. node.label, value = cfg.enabled[node.id] and "On" or "Off",
        valueColor = cfg.enabled[node.id] and color("Green") or color("Grey"), action = flip, change = flip }
    end
  end
  for _, g in ipairs(SPLITS) do addNode(g, 0) end
  return "Splits", rows
end

pages.keys = function()
  local function keyRow(label, key)
    local listening = menu.listening == key
    return {
      label = label,
      value = listening and "press a key…" or keyName(cfg[key]),
      valueColor = listening and { 1, 0.86, 0.32 } or nil,
      tip = key == "menuKey" and "Enter, then press any key" or "Enter, then press any key  ·  ← or → clears it",
      action = function() menu.listening, menu.listenAt = key, os.clock() end,
      change = function() if key ~= "menuKey" then setKey(key, "NONE") end end,
    }
  end
  return "Keys", {
    keyRow("Open / close this menu", "menuKey"),
    keyRow("Reset timer", "resetKey"),
    keyRow("Split (or start)", "splitKey"),
    keyRow("Pause / resume timer", "pauseKey"),
    keyRow("Hide / show timer", "hideKey"),
    info("Menu: ↑↓ move, ←→ change, Enter select, Backspace back"),
  }
end

pages.records = function()
  local rows = {
    info("Personal best (IGT)", fmt(records.pbIgt)),
    info("Personal best (RTA)", fmt(records.pbRta)),
    info("Attempts", tostring(records.attempts or 0)),
    info("Finished runs", tostring(records.finished or 0)),
    header("Recent runs"),
  }
  for i = 1, math.min(8, #records.history) do
    local h = records.history[i]
    rows[#rows + 1] = info(h.date or "?", fmt(h.igt, 2) .. " IGT  ·  " .. fmt(h.rta, 2) .. " RTA")
  end
  if #records.history == 0 then rows[#rows + 1] = info("No finished runs yet") end
  rows[#rows + 1] = header("")
  rows[#rows + 1] = action("Clear personal best", function()
    records.pbIgt, records.pbRta, records.pbSplits, records.bestSplits = nil, nil, {}, {}
    saveRecords()
  end, true)
  rows[#rows + 1] = action("Clear run history and attempts", function()
    records.history, records.attempts, records.finished = {}, 0, 0
    saveRecords()
  end, true)
  return "Records", rows
end

local function selectable(r) return r and not r.header and not r.info end
local function current() return menu.stack[#menu.stack] end

local function build()
  local page = current()
  local title, rows = pages[page.name]()
  return title, rows
end

local function moveCursor(rows, dir, steps)
  local p = current()
  local c = p.cursor
  for _ = 1, steps or 1 do
    local n = c
    repeat n = n + dir until n < 1 or n > #rows or selectable(rows[n])
    if n >= 1 and n <= #rows then c = n end
  end
  p.cursor = c
  menu.confirm = nil
end

local function openPage(name)
  menu.stack[#menu.stack + 1] = { name = name, cursor = 1, top = 1 }
  local _, rows = build()
  if not selectable(rows[1]) then moveCursor(rows, 1) end
end

local function setMenuOpen(open, world, gs)
  menu.open = open
  menu.confirm = nil
  if open and #menu.stack == 0 then openPage("main") end
  if cfg.pauseInMenu and R.valid(world) and R.valid(gs) then
    pcall(function() gs:SetGamePaused(world, open) end)
  end
end

local function drawMenu()
  local title, rows = build()
  local p = current()
  local visible = HUD.menuLines
  if p.cursor < p.top then p.top = p.cursor end
  if p.cursor > p.top + visible - 1 then p.top = p.cursor - visible + 1 end
  p.top = math.max(1, math.min(p.top, math.max(1, #rows - visible + 1)))

  local accent = { 0.84, 0.36, 0.69 }
  local out = {}
  for i = p.top, math.min(#rows, p.top + visible - 1) do
    local r = rows[i]
    local sel = i == p.cursor
    local col = r.header and accent or (sel and { 1, 0.86, 0.32 } or (r.info and { 0.7, 0.7, 0.74 } or { 1, 1, 1 }))
    out[#out + 1] = {
      label = (sel and "›  " or "    ") .. (r.label or ""),
      value = r.value or "",
      color = col,
      valueColor = sel and col or r.valueColor or (r.info and { 0.7, 0.7, 0.74 } or { 0.85, 0.85, 0.9 }),
    }
  end
  local crumbs = {}
  for _, s in ipairs(menu.stack) do crumbs[#crumbs + 1] = s.name == "main" and "Settings" or pages[s.name]() end
  local where = #menu.stack > 1 and table.concat(crumbs, "  ›  ") or title
  local scroll = #rows > visible and string.format("   ·   %d/%d", p.cursor, #rows) or ""
  local selected = rows[p.cursor]
  if menu.notice and not menu.listening then
    local n = menu.notice
    menu.notice = nil
    menu.noticeText, menu.noticeUntil = n, os.clock() + 3
  end
  local notice = menu.noticeUntil and os.clock() < menu.noticeUntil and menu.noticeText or nil
  local footer = notice or menu.listening and "Press the key you want  ·  Esc cancels" or
    menu.confirm and "Press Enter again to confirm" or (selected and selected.tip) or
    "Splits & load removal from TheDementedSalad & Lox's autosplitter"
  HUD.setMenu(true, where,
    "↑↓ move    ←→ change    Enter select    Backspace back" ..
      (cfg.menuKey ~= "BACKSPACE" and ("    " .. keyName(cfg.menuKey) .. " close") or ""),
    out, footer .. scroll)
end

local function menuKey(key, world, gs)
  local _, rows = build()
  local p = current()
  local r = rows[p.cursor]
  if key == "BACKSPACE" then
    if #menu.stack > 1 then menu.stack[#menu.stack] = nil menu.confirm = nil
    else setMenuOpen(false, world, gs) end
  elseif key == "UP_ARROW" then moveCursor(rows, -1)
  elseif key == "DOWN_ARROW" then moveCursor(rows, 1)
  elseif key == "PAGE_UP" then moveCursor(rows, -1, 8)
  elseif key == "PAGE_DOWN" then moveCursor(rows, 1, 8)
  elseif key == "LEFT_ARROW" or key == "RIGHT_ARROW" then
    if r and r.change then r.change(key == "RIGHT_ARROW" and 1 or -1) end
    menu.confirm = nil
  elseif key == "RETURN" then
    if not r then return end
    if r.page then openPage(r.page) return end
    if r.confirm and menu.confirm ~= p.cursor then menu.confirm = p.cursor return end
    menu.confirm = nil
    if r.action then r.action()
    elseif r.change then r.change(1) end
  end
end

---------------------------------------------------------------------------
-- keys (UE4SS calls these on its own thread; they're handled in the game thread tick)
---------------------------------------------------------------------------
local keyQueue = {}

-- bind `key` to the action `target`; a key used by another action moves here
-- (the menu key can't be taken away, so nothing is left without a way into the menu)
local function assignKey(target, key)
  if target ~= "menuKey" and key == cfg.menuKey then
    menu.notice = keyName(key) .. " opens the menu: pick another key"
    return
  end
  for _, f in ipairs(BINDS) do
    if f ~= target and cfg[f] == key then cfg[f] = (f == "menuKey") and cfg[target] or "NONE" end
  end
  cfg[target] = key
  saveSettings()
  log("%s bound to %s", target, key)
end

local function processKey(key, world, gs)
  -- waiting for a new key binding: the next key press is it (Esc cancels)
  if menu.listening then
    local target = menu.listening
    menu.listening = nil
    if key ~= "ESCAPE" then assignKey(target, key) end
    return
  end
  if menu.open then
    -- navigation first (so Backspace goes back a page, and closes on the first page)
    if NAV[key] then menuKey(key, world, gs) return end
    if key == cfg.menuKey then setMenuOpen(false, world, gs) end
    return
  end
  if key == cfg.menuKey then setMenuOpen(true, world, gs)
  elseif key == cfg.resetKey then resetRun()
  elseif key == cfg.splitKey then manualSplit()
  elseif key == cfg.pauseKey then if run.phase == "running" then run.manualPause = not run.manualPause end
  elseif key == cfg.hideKey then setKey("hudVisible", not cfg.hudVisible) end
end

---------------------------------------------------------------------------
-- per frame
---------------------------------------------------------------------------
T = {
  lastReal = nil, lastWall = nil, world = nil, worldChangedAt = 0, lastZ = nil,
  hudWorld = nil, hudTry = -1e9, notInGameSince = nil, lastCp = nil,
}

local function tick()
  local now = os.clock()
  local engine = Game.engine()
  if not engine then return end

  local pc = Game.playerController(engine)
  local world = pc and pc:GetWorld() or nil
  if not R.valid(world) then world = nil end
  local gs = Game.statics()
  local inGame = Game.inGame(pc)

  -- level changes: let things settle before touching game objects
  local wAddr = world and world:GetAddress() or nil
  T.worldObj = world
  if wAddr ~= T.world then
    T.world, T.worldChangedAt = wAddr, now
    Game.forget()
  end
  local settled = wAddr ~= nil and now - T.worldChangedAt > 2

  -- frame time: the engine's real-time clock (the wall clock across level changes)
  local wall = now
  local dWall = T.lastWall and math.max(0, wall - T.lastWall) or 0
  T.lastWall = wall
  local real = (world and gs) and gs:GetRealTimeSeconds(world) or nil
  local dReal, fresh = dWall, false
  if real and T.lastReal and real >= T.lastReal and wAddr == T.realWorld then dReal = real - T.lastReal
  else fresh = true end
  T.lastReal, T.realWorld = real, wAddr

  -- ASL isLoading {} plus loading screens and hitches
  local loading = fresh or not inGame
  local paused = false
  if cfg.removePauses then
    if Game.pauseTransition(engine) then paused = true end
    if world and gs and gs:IsGamePaused(world) then paused = true end
  end
  if cfg.removeLoadScreens and Game.loadingScreenUp() then loading = true end
  if cfg.removeHitches and dReal * 1000 > cfg.hitchMs then loading = true end
  run.loading, run.paused = loading, paused

  if run.phase == "running" and not run.manualPause then
    run.rta = run.rta + dReal
    if not loading and not paused then run.igt = run.igt + dReal end
  end

  -- auto reset at the main menu
  if inGame then T.notInGameSince = nil else T.notInGameSince = T.notInGameSince or now end
  if cfg.autoResetMenu and run.phase ~= "idle" and T.notInGameSince and now - T.notInGameSince > 3 then resetRun() end

  local pawn = (settled and inGame) and pc.AcknowledgedPawn or nil
  if not R.valid(pawn) then pawn = nil end

  -- ASL start {}: the player's height starts changing below 8544 in the persistent level
  local z
  if pawn then
    local loc = pawn:K2_GetActorLocation()
    z = loc and loc.Z or nil
  end
  if run.phase == "idle" and cfg.autoStart and z and T.lastZ and z < 8544 and z ~= T.lastZ and Game.isPlayer(pawn) then
    local wname = world:GetFullName()
    if wname:find("00_Persistent", 1, true) then startRun() end
  end
  T.lastZ = z

  if pawn then
    if run.phase == "running" then
      checkSplits(pawn, now)
    else
      -- keep the baseline fresh so a new run doesn't split on an old checkpoint
      run.lastCheckpoint = checkpointId(Game.checkpoint(now, T.worldObj)) or run.lastCheckpoint
    end
    T.lastCp = run.lastCheckpoint
  end

  if menu.listening and now - (menu.listenAt or now) > 8 then menu.listening = nil end
  while #keyQueue > 0 do processKey(table.remove(keyQueue, 1), world, gs) end

  -- display (a new level drops the old widget, so build one there once it's settled)
  if wAddr and T.hudWorld ~= wAddr then needsRebuild = true end
  local hudOk = HUD.alive()
  -- a colour changed and this UE4SS can't recolour live: rebuild (at most every 0.4 s)
  if HUD.wantRebuild and hudOk and settled and now - T.hudTry > 0.4 then needsRebuild = true end
  if (needsRebuild or not hudOk) and settled and now - T.hudTry > 0.4 then
    T.hudTry = now
    local outer = engine.GameInstance
    if not R.valid(outer) then outer = pc end
    if R.valid(outer) then
      local ok, err = pcall(HUD.build, cfg, hudLayout(), outer, pc)
      if ok then
        needsRebuild, hudOk = false, true
        T.hudWorld = wAddr
        hintUntil = hintUntil or (now + 20)
        logOnce("hud", "timer display created")
      else
        logOnce("hudfail" .. tostring(err), "couldn't create the timer display: %s", tostring(err))
      end
    end
  end
  if hudOk and not needsRebuild then
    updateHud(now, T.lastCp)
    HUD.animate(dWall)   -- frame-time based, so it looks the same at any FPS
    if menu.open then drawMenu() else HUD.setMenu(false) end
  end
end

---------------------------------------------------------------------------
-- hook everything up
---------------------------------------------------------------------------
local registered = {}
local function bind(name)
  if registered[name] or not Key or Key[name] == nil then return end
  registered[name] = true
  RegisterKeyBind(Key[name], function() keyQueue[#keyQueue + 1] = name end)
end
local function bindable(name)
  return type(name) == "string" and not name:find("MOUSE", 1, true) and not name:find("XBUTTON", 1, true)
end
local count = 0
if type(Key) == "table" then
  for name in pairs(Key) do
    if bindable(name) then bind(name) count = count + 1 end
  end
end
for name in pairs(NAV) do bind(name) end
log("listening to %d keys", count)

Game.installHooks(function() needsRebuild = true end)

local function safeTick()
  local ok, err = pcall(tick)
  if not ok then logOnce("tick" .. tostring(err), "error: %s", tostring(err)) end
end

if LoopInGameThreadWithDelay then
  LoopInGameThreadWithDelay(10, safeTick)
else
  -- UE4SS 3.0.x
  LoopAsync(10, function()
    ExecuteInGameThread(safeTick)
    return false
  end)
end

log("ready. %s opens the settings.", keyName(cfg.menuKey))
