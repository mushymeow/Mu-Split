-- "Autosplitters on Linux": pick your game, paste one launch option into Steam, done.
-- When the game starts, Steam also starts the Mu Split engine inside the game's Proton prefix
-- (the only place it can read the game's memory), and Mu Split switches over to it.

local theme = require("theme")
local ui = require("ui")
local W = require("widgets")
local windows = require("windows")
local steam = require("steam")
local L = require("linux")

local LW = {}
local lg = love.graphics
local win = { title = "Autosplitters on Linux", w = 640, h = 680 }
local games, search, selected, copied = nil, "", nil, 0
local rowH = 30

function LW.open()
  games = steam.games()
  if windows.top() ~= win then windows.push(win) end
end
function win:onClose() windows.pop(win) end

local function gameName(appid)
  for _, g in ipairs(games or {}) do if g.appid == appid then return g.name end end
  return "game " .. tostring(appid)
end

local function copy(text) love.system.setClipboardText(text) copied = love.timer.getTime() end

function win:draw(x, y, w, h, dt)
  local F = theme.fonts
  local pad = 22
  x, w = x + pad, w - pad * 2
  y = y + 16

  -- which engine are we talking to?
  local kind, appid = L.engineKind()
  local status, col
  if kind == "game" then status, col = "Engine running inside " .. gameName(appid) .. ": autosplitters work", theme.aheadGain
  elseif kind == "private" then status, col = "Engine running in Mu Split's own Wine prefix: timer only (no autosplitter)", theme.gold
  else status, col = "Starting the engine…", theme.textDim end
  ui.color(col) lg.circle("fill", x + 5, y + 10, 4)
  ui.label(ui.ellipsize(F.ui, status, w - 20), x + 16, y, { h = 20, color = theme.text })
  y = y + 34

  y = W.section("1. Pick your game", x, y, w)
  local s = ui.textbox("lw:search", search, x, y, w, theme.controlH, { placeholder = "search your Steam games" })
  search = s
  y = y + theme.controlH + 8
  local list = {}
  for _, g in ipairs(games or {}) do
    if search == "" or g.name:lower():find(search:lower(), 1, true) then list[#list + 1] = g end
  end
  local listH = 6 * rowH
  ui.color(theme.input) ui.rect("fill", x, y, w, listH, theme.radiusSmall)
  ui.beginScroll("lw:list", x, y, w, listH, #list * rowH)
  for i, g in ipairs(list) do
    local ry = y + (i - 1) * rowH
    local hov, clicked = ui.interact("lw:g:" .. g.appid, x, ry, w, rowH)
    if selected and selected.appid == g.appid then ui.color(theme.accent, 0.22) lg.rectangle("fill", x, ry, w, rowH)
    elseif hov then ui.color(theme.inputHover) lg.rectangle("fill", x, ry, w, rowH) end
    ui.label(ui.ellipsize(F.ui, g.name, w - 150), x + 10, ry, { h = rowH })
    ui.label(g.proton and "Proton" or "not run with Proton yet", x, ry, { h = rowH, w = w - 10, align = "right",
      font = F.small, color = g.proton and theme.textFaint or theme.gold })
    if clicked then selected = g end
  end
  if #list == 0 then
    ui.label(games and #games == 0 and "No Steam games found." or "No matches.", x + 10, y + 8, { color = theme.textFaint })
  end
  ui.endScroll()
  y = y + listH + 16

  y = W.section("2. Add this to its launch options in Steam", x, y, w)
  local opt = L.launchOption()
  if not opt then
    ui.label("The engine wasn't found next to Mu Split (engine/MuSplitEngine.exe).", x, y, { color = theme.danger })
    return
  end
  lg.setFont(F.small)
  ui.color(theme.textDim)
  local howTo = "In Steam: right-click " .. (selected and selected.name or "the game")
    .. " > Properties > General > Launch Options. Paste this (keep anything else you had before %command%):"
  lg.printf(howTo, x, y, w)
  local _, wrapped = F.small:getWrap(howTo, w)
  y = y + #wrapped * F.small:getHeight() + 8
  ui.textbox("lw:opt", opt, x, y, w - 90, theme.controlH, { readonly = true })
  local justCopied = love.timer.getTime() - copied < 2
  if ui.button("lw:copy", justCopied and "Copied" or "Copy", x + w - 82, y, 82, theme.controlH, { primary = true }) then copy(opt) end
  y = y + theme.controlH + 18

  y = W.section("3. Start the game from Steam", x, y, w)
  local tips = {
    "Mu Split switches to the game's engine by itself (the status line above turns green). Save your splits first: the switch reopens them from the file.",
    "Load your splits and turn on the autosplitter as usual.",
  }
  if selected and not selected.proton then
    tips[#tips + 1] = "This game hasn't been run with Proton yet: in its Properties > Compatibility, tick \"Force the use of a specific Steam Play compatibility tool\"."
  end
  tips[#tips + 1] = "If the engine doesn't start in the game, the game's prefix may need .NET (one time):"
  for _, t in ipairs(tips) do
    lg.setFont(F.small)
    ui.color(theme.textDim)
    lg.printf("• " .. t, x, y, w)
    local _, wr = F.small:getWrap("• " .. t, w)
    y = y + #wr * F.small:getHeight() + 6
  end
  local fix = "protontricks " .. (selected and selected.appid or "<appid>") .. " -q dotnet48"
  ui.textbox("lw:fix", fix, x, y, w - 90, theme.controlH, { readonly = true, font = F.small })
  if ui.button("lw:copyfix", "Copy", x + w - 82, y, 82, theme.controlH, { disabled = not selected }) then copy(fix) end
end

return LW
