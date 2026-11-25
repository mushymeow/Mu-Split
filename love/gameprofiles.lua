-- One-click setups for specific games. Each entry:
--   game          exact name in LiveSplit's autosplitter list (that's how the script gets found)
--   category      used if your splits don't have one yet
--   method        "game" for load-removed time
--   finalSegment  a split the script always does at the end, whatever the settings say
--   skip          setting ids that aren't real splits

local net = require("net")
local view = require("timerview")
local dialogs = require("dialogs")
local aslwindow = require("aslwindow")

local profiles = { list = {} }

profiles.list[#profiles.list + 1] = {
  game = "Poppy Playtime: Chapter 4",
  category = "Any%",
  method = "game",
  blurb = "Load remover + checkpoint and item splits by TheDementedSalad & Lox. Set Up switches to Game Time, " ..
    "names your splits for this game and turns the autosplitter on. Then tick the splits you want in the Autosplitter tab " ..
    "and press Build Splits From Settings.",
  finalSegment = "Fallen Down the Hole",   -- the script always splits here (TheLabsEntrance.2 + item used)
  skip = { FinalSplit = true },            -- just a label in the settings list
}

-- Game Time first: asl-help asks "switch to Game Time?" in a popup if the script
-- starts while the timer is on Real Time.
function profiles.setup(p, menuInfo)
  local S = view.S or {}
  net.send("timing", p.method or "game")
  if S.game ~= p.game or (S.category or "") == "" then
    net.send("editor_begin")
    net.send("editor_op", { op = "set", field = "game", value = p.game })
    if (S.category or "") == "" then net.send("editor_op", { op = "set", field = "category", value = p.category }) end
    net.send("editor_ok")
  end
  net.send("asl_enable", p.game)   -- downloads the script + its files the first time
  net.send("menu")
end

local function build(p, names, clearTimes)
  local S = view.S or {}
  local c = S.segments and #S.segments or 0
  local n = #names
  net.send("editor_begin")
  if c > n then
    local idx = {}
    for i = n, c - 1 do idx[#idx + 1] = i end
    net.send("editor_op", { op = "remove", indices = idx })
  end
  for k = 0, n - math.max(c, 1) - 1 do
    net.send("editor_op", { op = "insert", i = math.max(c, 1) - 1 + k, where = "below" })
  end
  for i, name in ipairs(names) do
    net.send("editor_op", { op = "name", i = i - 1, value = name })
  end
  if clearTimes then net.send("editor_op", { op = "clear_times" }) end
  net.send("editor_ok")
end

function profiles.buildSplits(p)
  local S = view.S or {}
  if S.phase ~= "NotRunning" then dialogs.error("Reset the timer first.") return end
  if not aslwindow.A or not aslwindow.A.available or not aslwindow.A.custom or #aslwindow.A.custom == 0 then
    aslwindow.request()
    dialogs.error("The autosplitter's options haven't loaded yet. Open the Autosplitter tab, wait a moment, then try again.")
    return
  end

  local names = {}
  for _, s in ipairs(aslwindow.enabledLeaves(p.skip)) do names[#names + 1] = s.label end
  if p.finalSegment then names[#names + 1] = p.finalSegment end
  if #names == 0 or (p.finalSegment and #names == 1) then
    dialogs.error("Tick the splits you want in the Autosplitter tab first.")
    return
  end

  local current = S.segments and #S.segments or 0
  dialogs.message({
    title = "Build Splits",
    text = ("Make %d splits from your autosplitter settings (you have %d now)? They follow the order of the settings list, " ..
      "so check the order in Edit Splits if you mix checkpoint and item splits.\n\nExisting times stay on their rows, " ..
      "so if the splits changed you'll probably want to clear them."):format(#names, current),
    buttons = {
      { label = "Build + Clear Times", action = function() build(p, names, true) end },
      { label = "Build", primary = true, action = function() build(p, names, false) end },
      { label = "Cancel" },
    },
  })
end

return profiles
