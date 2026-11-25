-- Mu Split
-- LiveSplit (hidden, via the bridge) owns the timer, splits files, autosplitters
-- and hotkeys. This app draws everything and replaces LiveSplit's menus/windows.

local theme = require("theme")
local ui = require("ui")
local net = require("net")
local launcher = require("launcher")
local view = require("timerview")
local menu = require("menu")
local dialogs = require("dialogs")
local windows = require("windows")
local editor = require("editor")
local aslwindow = require("aslwindow")
local settingswindow = require("settingswindow")
local filedialog = require("filedialog")
local keymap = require("keymap")
local overlay = require("overlay")
local presets = require("presets")
local customwindow = require("customwindow")
local postfx = require("postfx")
local sounds = require("sounds")
local frame = require("frame")
local workshop = require("workshop")
local race = require("race")
local racewindow = require("racewindow")
local discord = require("discordrpc")
local linux = require("linux")
local linuxwindow = require("linuxwindow")
local json = require("json")

-- app settings that aren't part of a look
local appsettings = require("appsettings")
local app = appsettings.cfg
local function loadApp() appsettings.load() end

local M = nil              -- latest "menu" info (recent files, comparisons, profiles…)
local quitting = false
local afterResult = {}     -- cmd -> function(ok) to run when LiveSplit confirms
local lastTitle = nil

local function S() return view.S end
local actions = {}         -- filled in below

---------------------------------------------------------------------------
-- bridge messages
---------------------------------------------------------------------------
net.on.state = function(msg)
  view.onState(msg)
  presets.onGame(msg.game)        -- a look per game (if that's switched on)
end
view.onEvent = sounds.play        -- split / gold / pb / reset sounds (if the look has them on)
-- races: your splits go to the race, the standings panel and the countdown go in the timer
view.onStateHook = race.onState
view.panel = { height = race.panelHeight, draw = race.drawPanel }
view.overlay = race.drawOverlay
race.startTimer = function() if net.connected then net.send("splitorstart") end end
net.on.menu = function(msg) M = msg overlay.menuInfo = msg end
net.on.editor = function(msg) editor.onSnapshot(msg) end
net.on.asl = function(msg) aslwindow.onSnapshot(msg) end
net.on.settings = function(msg) settingswindow.onSnapshot(msg) end
net.on.http = function(msg) workshop.onHttp(msg) end

net.on.connected = function()
  net.send("settings_get")   -- needed for hotkeys while Mu Split has focus
  net.send("menu")
  net.send("hotkeys_resume") -- in case we went away while the Settings window had them paused
end

net.on.disconnected = function()
  while windows.isOpen() do windows.pop() end
  menu.close()
end

net.on.result = function(msg)
  local after = afterResult[msg.cmd]
  afterResult[msg.cmd] = nil
  if msg.ok then
    if after then after(true) end
  elseif msg.error == "needs_path" then
    -- saving splits that were never saved: ask where
    actions.saveAs(after)
  elseif msg.error then
    dialogs.error(msg.error)
  end
end

---------------------------------------------------------------------------
-- actions (the same flow LiveSplit uses, with our prompts instead of its message boxes)
---------------------------------------------------------------------------
local function dirOf(path) return path and path:match("^(.*)[/\\][^/\\]*$") or nil end

local function suggestedName()
  local s = S()
  if not s then return "Splits.lss" end
  local parts = {}
  if s.game and s.game ~= "" then parts[#parts + 1] = s.game end
  if s.category and s.category ~= "" then parts[#parts + 1] = s.category end
  local name = #parts > 0 and table.concat(parts, " - ") or "Splits"
  return (name:gsub('[<>:"/\\|%?%*]', "")) .. ".lss"
end

function actions.saveAs(after)
  local s = S()
  local path = filedialog.save({ filename = suggestedName(), dir = s and dirOf(s.filePath) })
  if not path then return end
  afterResult.save = after
  net.send("save", path)
end

function actions.save(promptPB, after)
  local s = S()
  if not s then return end
  if not s.filePath or s.filePath == "" then return actions.saveAs(after) end
  if promptPB and s.savePrompt then
    dialogs.message({
      title = "Save as Personal Best?",
      text = "This run did not beat your current splits. Would you like to save this run as a Personal Best?",
      buttons = {
        { label = "Yes", action = function() afterResult.save_pb = after net.send("save_pb") end },
        { label = "No", primary = true, action = function() afterResult.save = after net.send("save") end },
        { label = "Cancel" },
      },
    })
  else
    afterResult.save = after
    net.send("save")
  end
end

-- "Your splits have been updated but not yet saved" before anything that replaces them
function actions.ensureSaved(continue)
  local s = S()
  if not s or not s.hasChanged or s.timerOnly then return continue() end
  dialogs.message({
    title = "Save Splits?",
    text = "Your splits have been updated but not yet saved.\nDo you want to save your splits now?",
    buttons = {
      { label = "Yes", primary = true, action = function() actions.save(false, function() continue() end) end },
      { label = "No", action = function() net.send("discard_changes") continue() end },
      { label = "Cancel" },
    },
  })
end

function actions.openPath(path)
  actions.ensureSaved(function() net.send("open", path) end)
end

function actions.openFromFile()
  actions.ensureSaved(function()
    local s = S()
    local recentDir = M and M.recent and M.recent[1] and dirOf(M.recent[1].path)
    local path = filedialog.open({ dir = (s and dirOf(s.filePath)) or recentDir })
    if path then net.send("open", path) end
  end)
end

function actions.close()
  actions.ensureSaved(function() net.send("close") end)
end

function actions.reset()
  local s = S()
  if not s or s.phase == "NotRunning" then return end
  if s.resetPrompt then
    dialogs.message({
      title = "Update Times?",
      text = "You have beaten some of your best times.\nDo you want to update them?",
      buttons = {
        { label = "Yes", primary = true, action = function() net.send("reset") end },
        { label = "No", action = function() net.send("reset_discard") end },
        { label = "Cancel" },
      },
    })
  else
    net.send("reset")
  end
end

function actions.exit()
  actions.ensureSaved(function()
    quitting = true
    love.event.quit()
  end)
end

overlay.actions = actions

---------------------------------------------------------------------------
-- right-click menu (mirrors LiveSplit's)
---------------------------------------------------------------------------
local function fileName(path) return path and path:match("[^/\\]+$") or path end

local function buildMenu()
  local s = S() or {}
  local m = M or {}
  local phase = s.phase or "NotRunning"
  local running = phase == "Running" or phase == "Paused"
  local nSeg = s.segments and #s.segments or 0

  local function openSub()
    local items = {}
    for _, r in ipairs(m.recent or {}) do
      local label
      if (r.game or "") ~= "" then
        label = r.game .. ((r.category or "") ~= "" and (" - " .. r.category) or "")
      else
        label = fileName(r.path)
      end
      items[#items + 1] = { label = label, checked = r.path == s.filePath, action = function() actions.openPath(r.path) end }
    end
    if #items > 0 then items[#items + 1] = { separator = true } end
    items[#items + 1] = { label = "From File…", action = actions.openFromFile }
    return items
  end

  local function controlSub()
    local splitLabel = phase == "NotRunning" and "Start" or (phase == "Paused" and "Resume" or "Split")
    local items = {
      { label = splitLabel, disabled = phase == "Ended", action = function() net.send("splitorstart") end },
      { label = "Reset", disabled = phase == "NotRunning", action = actions.reset },
      { label = "Undo Split", disabled = not (running or phase == "Ended") or (s.index or 0) <= 0, action = function() net.send("undo") end },
      { label = "Skip Split", disabled = phase ~= "Running" or (s.index or 0) >= nSeg - 1, action = function() net.send("skip") end },
      { label = "Pause", disabled = phase ~= "Running", action = function() net.send("pause") end },
      { label = "Undo All Pauses", disabled = not s.canUndoPauses, action = function() net.send("undo_pauses") end },
      { separator = true },
      { label = "Global Hotkeys", checked = m.globalHotkeys, action = function() net.send("global_hotkeys") net.send("settings_get") end },
    }
    if m.profiles and #m.profiles > 1 then
      items[#items + 1] = { label = "Hotkey Profile", submenu = function()
        local sub = {}
        for _, p in ipairs(m.profiles) do
          sub[#sub + 1] = { label = p, checked = p == m.profile, action = function() net.send("profile", p) net.send("settings_get") end }
        end
        return sub
      end }
    end
    return items
  end

  local function compareSub()
    local items = {}
    for _, c in ipairs(m.customComparisons or {}) do
      items[#items + 1] = { label = c, checked = c == s.comparison, action = function() net.send("compare", c) end }
    end
    if m.generatedComparisons and #m.generatedComparisons > 0 then
      items[#items + 1] = { separator = true }
      for _, c in ipairs(m.generatedComparisons) do
        items[#items + 1] = { label = c, checked = c == s.comparison, action = function() net.send("compare", c) end }
      end
    end
    items[#items + 1] = { separator = true }
    items[#items + 1] = { label = "Real Time", checked = s.method == "real", action = function() net.send("timing", "real") end }
    items[#items + 1] = { label = "Game Time", checked = s.method == "game", action = function() net.send("timing", "game") end }
    return items
  end

  local asb = m.autosplitter or {}
  local items = {
    { label = "Edit Splits…", action = editor.open },
    { label = "Open Splits", submenu = openSub },
    { label = "Save Splits", disabled = s.timerOnly, action = function() actions.save(true) end },
    { label = "Save Splits As…", disabled = s.timerOnly, action = function() actions.saveAs() end },
    { label = "Close Splits", disabled = s.timerOnly, action = actions.close },
    { separator = true },
    { label = "Control", submenu = controlSub },
    { label = "Compare Against", submenu = compareSub },
    { separator = true },
    { label = "Autosplitter Settings…", disabled = not asb.running or not (asb.asl or asb.hasSettings), action = function()
      if asb.asl then aslwindow.open() else filedialog.allowForeground() net.send("asl_native") end
    end },
    { label = "Settings…", action = settingswindow.open },
    { label = "Look", submenu = function()
      local items = {}
      for _, p in ipairs(presets.all()) do
        items[#items + 1] = { label = p.style.name, checked = presets.current and presets.current.name == p.style.name,
          action = function() presets.useLook(p.style) end }
      end
      items[#items + 1] = { separator = true }
      items[#items + 1] = { label = "Customise…", hint = "F1", action = customwindow.open }
      items[#items + 1] = { label = "Next Look", hint = "F2", action = function() presets.cycle(1) end }
      return items
    end },
    { label = "Customise Look…", hint = "F1", action = customwindow.open },
    { label = "Always on Top", checked = app.alwaysOnTop, action = function() appsettings.setAlwaysOnTop(not app.alwaysOnTop) end },
    { label = "Hide Title Bar", checked = app.borderless, action = function() appsettings.setBorderless(not app.borderless) end },
    { separator = true },
    { label = race.inRoom() and ("Race  ·  " .. (race.code or "") .. (race.unread > 0 and ("  (" .. race.unread .. " new)") or "") .. "…")
        or "Race…", action = racewindow.open },
    { label = "Autosplitters on Linux…", action = linuxwindow.open, linuxOnly = true },
    { label = "Overlay Mode (In-Game)", action = function() overlay.enter() overlay.openPanel() end },
    { label = "Show LiveSplit Window", checked = s.windowHidden == false, standaloneHidden = true,
      action = function() net.send("window", s.windowHidden and "show" or "hide") end },
    { separator = true },
    { label = "Exit", action = actions.exit },
  }
  if not linux.isLinux then
    for i = #items, 1, -1 do if items[i].linuxOnly then table.remove(items, i) end end
  end
  -- the standalone engine has no LiveSplit window to show
  if s.standalone then
    for i = #items, 1, -1 do if items[i].standaloneHidden then table.remove(items, i) end end
  end
  return items
end

---------------------------------------------------------------------------
-- hotkeys while Mu Split has focus
-- With global hotkeys on, LiveSplit sees every key itself. With them off,
-- LiveSplit only listens while *its* window is focused (never, it's hidden),
-- so we forward the profile's hotkeys from here instead.
---------------------------------------------------------------------------
local function normKey(k)
  if not k or k == "" then return nil end
  local parts = {}
  for p in k:gmatch("[^,%s]+") do parts[#parts + 1] = p:lower() end
  table.sort(parts)
  return table.concat(parts, ",")
end

local function localHotkey(key)
  local cfg = settingswindow.latest
  if not cfg or not cfg.profiles then return end
  local p = cfg.profiles[cfg.profile]
  if not p or p.global then return end
  local pressed = normKey(keymap.toDotNet(key, love.keyboard.isDown("lctrl", "rctrl"),
    love.keyboard.isDown("lshift", "rshift"), love.keyboard.isDown("lalt", "ralt")))
  if not pressed then return end
  if pressed == normKey(p.split) then net.send("splitorstart")
  elseif pressed == normKey(p.reset) then actions.reset()
  elseif pressed == normKey(p.undo) then net.send("undo")
  elseif pressed == normKey(p.skip) then net.send("skip")
  elseif pressed == normKey(p.pause) then net.send("pause")
  elseif pressed == normKey(p.comparePrev) then net.send("compare_prev")
  elseif pressed == normKey(p.compareNext) then net.send("compare_next")
  elseif pressed == normKey(p.toggleGlobal) then net.send("global_hotkeys") net.send("settings_get")
  end
end

---------------------------------------------------------------------------
-- LÖVE callbacks
---------------------------------------------------------------------------
function love.load()
  love.graphics.setDefaultFilter("linear", "linear")
  love.keyboard.setKeyRepeat(true)   -- for text editing; hotkeys ignore repeats
  presets.startup()                  -- your last look (style.json), or the default
  loadApp()
  if app.alwaysOnTop then windows.setAlwaysOnTop(true) end
  if app.borderless then frame.set(true) end
  theme.loadFonts()
  overlay.startup()
end

function love.update(dt)
  frame.update()                     -- moving / resizing without a title bar
  theme.update(dt)                   -- colours glide when the look changes
  presets.update(dt)                 -- saves the look shortly after a change
  net.update()
  race.update(dt)
  discord.update(dt)
  linux.update(dt)
  overlay.update(dt)
end

function love.mousepressed(x, y, button)
  ui.mousepressed(x, y, button)
  if not overlay.active and not dialogs.isOpen() and not menu.isOpen() then
    frame.mousepressed(x, y, button, not windows.isOpen())   -- drag to move / resize (no title bar)
  end
  if button == 2 and not overlay.active and not windows.isOpen() and not dialogs.isOpen() and net.connected and S() then
    menu.open(buildMenu(), x, y)
  end
end

function love.mousereleased(x, y, button) ui.mousereleased(x, y, button) frame.mousereleased() end
function love.filedropped(file) customwindow.dropFile(file) end   -- drop a picture: it becomes the background
function love.wheelmoved(x, y) ui.wheelmoved(x, y) end
function love.textinput(t) ui.textinput(t) end

function love.keypressed(key, scancode, isrepeat)
  ui.keypressed(key)
  if key == "escape" and ui.popup then ui.popup = nil return end
  if dialogs.isOpen() then dialogs.keypressed(key) return end
  if overlay.keypressed(key) then return end
  if overlay.active then return end
  if menu.keypressed(key) then return end
  if windows.keypressed(key) then return end
  if windows.isOpen() or menu.isOpen() or ui.wantsKeyboard() or isrepeat then return end

  if key == "f1" then customwindow.open() return end   -- works before the engine connects too
  if key == "f2" then presets.cycle(love.keyboard.isDown("lshift", "rshift") and -1 or 1) return end
  if key == "l" and not net.connected then launcher.launch() return end
  if net.connected then localHotkey(key) end
end

function love.draw()
  local W, H = love.graphics.getDimensions()
  local dt = love.timer.getDelta()
  ui.begin(dt)

  if overlay.active then
    ui.mouseLayer = dialogs.isOpen() and "dialog" or "base"
    overlay.draw(dt)
    dialogs.draw(dt)
    ui.finish()
    return
  end

  ui.mouseLayer = dialogs.isOpen() and "dialog" or (menu.isOpen() and "menu" or (windows.isOpen() and "window" or "base"))
  love.graphics.clear(theme.bg[1], theme.bg[2], theme.bg[3], 1)

  if windows.isOpen() then
    windows.draw(dt)
  elseif not net.connected or not S() then
    local title, detail
    if launcher.error then
      title, detail = "Couldn't start " .. launcher.name(), launcher.error .. "\nPress L to try again"
    elseif launcher.running() then
      title, detail = "Starting " .. launcher.name(), "this takes a few seconds the first time"
    elseif net.launchTried and launcher.exePath then
      title, detail = launcher.name():gsub("^%l", string.upper) .. " closed", "Press L to start it again"
    else
      title, detail = "Waiting for " .. launcher.name(), ("Mu Split Bridge on %s:%d"):format(net.host, net.port)
    end
    ui.layer = "base"
    view.drawWaiting(W, H, title, detail)
  else
    ui.layer = "base"
    local status = { stale = net.stale() }
    postfx.wrap("main", 0, 0, W, H, function(_, _, w, h) view.draw(w, h, dt, status) end, view.main.light)
  end

  if not windows.isOpen() then ui.layer = "base" frame.draw(dt) end   -- grip + min/close (no title bar)
  menu.draw(dt)
  dialogs.draw(dt)
  ui.finish()

  -- window title follows the open splits file
  local s = S()
  local title = "Mu Split"
  if s and s.filePath and s.filePath ~= "" then title = fileName(s.filePath):gsub("%.lss$", "") .. (s.hasChanged and " *" or "") .. " - Mu Split" end
  if title ~= lastTitle then love.window.setTitle(title) lastTitle = title end
end

function love.quit()
  presets.flush()
  local s = S()
  if not quitting and s and s.hasChanged and not s.timerOnly and net.connected then
    actions.exit()     -- ask about saving first
    return true        -- don't quit yet
  end
  -- close the LiveSplit we started (if we crash instead, the bridge closes it anyway)
  if launcher.owns() and net.sock then
    net.sock:settimeout(0.2)
    net.send("quit")
  end
  return false
end
