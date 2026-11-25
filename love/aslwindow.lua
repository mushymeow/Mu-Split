-- Autosplitter (ASL) settings: Start/Split/Reset plus the script's own settings tree.
-- Changes apply immediately inside LiveSplit and get saved into the splits file,
-- exactly like ticking them in LiveSplit's settings dialog.
--
-- asl.drawPanel(x, y, w, h, dt) draws it anywhere (the overlay uses it too).

local theme = require("theme")
local ui = require("ui")
local net = require("net")
local windows = require("windows")
local dialogs = require("dialogs")

local asl = { A = nil }
local lg = love.graphics
local collapsed = {}
local filter = ""
local lastRequest = -10
local wantAutoSplits = false     -- open Auto Splits once the script's options arrive

-- Auto Splits setting: group the script's sections (Items, Keys...) into subsplits
local json = require("json")
asl.autoSubsplits = true
do
  local ok, t = pcall(function() return json.decode(love.filesystem.read("autosplits.json")) end)
  if ok and type(t) == "table" and t.subsplits ~= nil then asl.autoSubsplits = t.subsplits and true or false end
end
local function saveAutoSettings()
  pcall(love.filesystem.write, "autosplits.json", json.encode({ subsplits = asl.autoSubsplits }))
end

function asl.onSnapshot(msg)
  asl.A = msg
  if msg.error then dialogs.error(msg.error) end
  if wantAutoSplits and msg.available and msg.loaded and #(msg.custom or {}) > 0 then
    wantAutoSplits = false
    asl.autoSplits()
  end
end

function asl.request()
  lastRequest = love.timer.getTime()
  net.send("asl_get")
end

local win = { title = "Autosplitter Settings", w = 640, h = 640 }

function asl.open()
  asl.A = nil
  asl.request()
  windows.push(win)
end

function win:onClose() windows.pop(win) end


local function set(t)
  net.send("asl_set", t)
end

-- parent/child structure of the script's settings
local function tree(A)
  local children, byId = {}, {}
  for _, s in ipairs(A.custom or {}) do byId[s.id] = s end
  for _, s in ipairs(A.custom or {}) do
    local p = s.parent or ""
    if p ~= "" and not byId[p] then p = "" end   -- unknown parent: show at top level
    children[p] = children[p] or {}
    table.insert(children[p], s)
  end
  return children, byId
end

-- Leaf settings that are on (their whole parent chain too), in script order.
-- This is what will actually split.
function asl.enabledLeaves(skip)
  local A = asl.A
  if not A or not A.custom then return {} end
  local children = tree(A)
  local out = {}
  local function walk(parent, enabled)
    for _, s in ipairs(children[parent] or {}) do
      local on = enabled and s.value
      if children[s.id] then walk(s.id, on)
      elseif on and not (skip and skip[s.id]) then out[#out + 1] = s end
    end
  end
  walk("", true)
  return out
end

---------------------------------------------------------------------------
-- Auto Splits: turn the options that are on into splits (names from the script,
-- in the script's order). The user is told it may need fixing by hand.
---------------------------------------------------------------------------
-- options that are on but look like settings rather than splits
local SETTING_WORDS = { "start", "reset", "load", "remov", "option", "setting", "debug", "timer", "igt",
                        "game time", "pause", "autostart", "auto start", "auto reset", "log" }

local function looksLikeSetting(s, byId)
  local node, guard = s, 0
  while node and guard < 20 do
    local l = (node.label or node.id or ""):lower()
    for _, w in ipairs(SETTING_WORDS) do
      if w == "log" then
        if l:find("^log") or l:find("%slog") then return true end
      elseif l:find(w, 1, true) then return true end
    end
    node = node.parent and byId[node.parent] or nil
    guard = guard + 1
  end
  return false
end

function asl.autoSplits()
  local editor = require("editor")
  local A = asl.A
  if not (A and A.available and A.loaded) then dialogs.error("The autosplitter hasn't loaded yet. Try again in a moment.") return end
  if not editor.isOpen() then dialogs.error("Open Auto Splits from the Splits Editor.") return end
  if not editor.canChangeSegments() then dialogs.error("Splits can't be changed during a run. Reset first.") return end

  local _, byId = tree(A)
  local leaves, skipped = {}, 0
  for _, s in ipairs(asl.enabledLeaves()) do
    if looksLikeSetting(s, byId) then skipped = skipped + 1 else leaves[#leaves + 1] = s end
  end
  local function label(s) return (s.label and s.label ~= "") and s.label or s.id end

  -- names; with subsplits, each run of options from the same group becomes a section:
  -- "-First", "-Second", ..., "{Group} Last" (LiveSplit's subsplit naming)
  local picked, sections = {}, 0
  local i = 1
  while i <= #leaves do
    local parent = leaves[i].parent
    local j = i
    while j + 1 <= #leaves and leaves[j + 1].parent == parent do j = j + 1 end
    local group = parent and byId[parent] and label(byId[parent]) or nil
    if asl.autoSubsplits and group and j > i then
      sections = sections + 1
      for k = i, j - 1 do picked[#picked + 1] = "-" .. label(leaves[k]) end
      picked[#picked + 1] = "{" .. group .. "} " .. label(leaves[j])
    else
      for k = i, j do picked[#picked + 1] = label(leaves[k]) end
    end
    i = j + 1
  end
  if #picked == 0 then
    dialogs.message({ title = "Auto Splits",
      text = "None of the options that are turned on look like splits.\nTick the splits you want in Autosplitter Settings first." })
    return
  end

  local existing = editor.segmentNames()
  local blank = #existing == 0 or (#existing == 1 and existing[1] == "")
  local have = {}
  -- compare without subsplit markers ("-Name", "{Section} Name")
  local function bare(n) n = n:gsub("^%-", "") return (n:gsub("^{.-}%s*", "")) end
  for _, n in ipairs(existing) do have[bare(n)] = true end

  local function insertAll(names, after)
    for k, name in ipairs(names) do
      editor.op({ op = "insert", i = after + k - 1, where = "below", name = name })
    end
  end
  local function replace()
    local n0 = #existing
    insertAll(picked, n0 - 1)
    local old = {}
    for i = 0, n0 - 1 do old[#old + 1] = i end
    editor.op({ op = "remove", indices = old })
    if windows.top() == win then windows.pop(win) end
  end
  local function append()
    local add = {}
    for _, n in ipairs(picked) do if not have[bare(n)] then add[#add + 1] = n end end
    if #add == 0 then dialogs.message({ title = "Auto Splits", text = "All of these splits are already in your list." }) return end
    insertAll(add, #existing - 1)
    if windows.top() == win then windows.pop(win) end
  end

  local text = ("Make %d split%s from the autosplitter options that are turned on, in the order the script lists them."):format(
    #picked, #picked == 1 and "" or "s")
  if sections > 0 then
    text = text .. ("\nThey're grouped into %d subsplit section%s (Items, Keys...): turn that off with “Group into subsplits”."):format(
      sections, sections == 1 and "" or "s")
  end
  if skipped > 0 then
    text = text .. ("\n(%d option%s that look%s like settings rather than splits %s left out.)"):format(
      skipped, skipped == 1 and "" or "s", skipped == 1 and "s" or "", skipped == 1 and "was" or "were")
  end
  text = text .. "\n\nManual correction may be needed: the order might not match your route, some names may need " ..
    "tidying, and the script might split on things you don't want as splits. Check them in the Splits Editor."
  if not blank then text = text .. "\n\nReplace removes your current splits and their times." end

  local buttons
  if blank then
    buttons = { { label = "Make Splits", primary = true, action = replace }, { label = "Cancel" } }
  else
    buttons = { { label = "Add to the End", primary = true, action = append },
                { label = "Replace My Splits", action = replace },
                { label = "Cancel" } }
  end
  dialogs.message({ title = "Auto Splits", text = text, buttons = buttons })
end

-- from the Splits Editor: open the settings and offer Auto Splits once they've loaded
function asl.openAutoSplits()
  wantAutoSplits = true
  asl.open()
end

-- flatten the tree into visible rows, honouring collapsed groups and the search box
local function buildRows(A)
  local children = tree(A)
  local q = filter:lower()
  local rows = {}

  local function matches(s)
    if q == "" then return true end
    return (s.label or ""):lower():find(q, 1, true) or (s.id or ""):lower():find(q, 1, true)
  end
  -- with a search, keep a group if anything inside it matches
  local function anyMatch(id)
    for _, c in ipairs(children[id] or {}) do
      if matches(c) or anyMatch(c.id) then return true end
    end
    return false
  end

  local function walk(parent, depth, enabled)
    for _, s in ipairs(children[parent] or {}) do
      local hasKids = children[s.id] ~= nil
      local show = matches(s) or (hasKids and anyMatch(s.id))
      if show then
        rows[#rows + 1] = { s = s, depth = depth, hasKids = hasKids, enabled = enabled }
        local open = q ~= "" or not collapsed[s.id]
        if hasKids and open then walk(s.id, depth + 1, enabled and s.value) end
      end
    end
  end
  walk("", 0, true)
  return rows
end

function asl.drawPanel(x, y, w, h, dt)
  local pad = 16
  local A = asl.A
  if not A then
    if love.timer.getTime() - lastRequest > 1.5 then asl.request() end
    ui.label("Loading…", x, y + h / 2 - 10, { w = w, align = "center", color = theme.textDim })
    return
  end
  if not A.available then
    ui.label(A.native and "This autosplitter has its own settings window." or "No ASL autosplitter is running.",
      x, y + h / 2 - 30, { w = w, align = "center", color = theme.textDim })
    if A.native and ui.button("asl:native", "Open Settings", x + w / 2 - 70, y + h / 2, 140, theme.controlH, { primary = true }) then
      require("filedialog").allowForeground()
      net.send("asl_native")
    end
    if love.timer.getTime() - lastRequest > 2 then asl.request() end
    return
  end
  -- the script compiles a moment after it's activated: keep asking until its options show up
  if (not A.loaded or #(A.custom or {}) == 0) and love.timer.getTime() - lastRequest > 1 then asl.request() end

  local cy = y + 14
  -- Start / Split / Reset
  ui.label("Timer control", x + pad, cy, { font = theme.fonts.header, color = theme.textDim })
  cy = cy + 22
  local cx = x + pad
  for _, b in ipairs(A.basic or {}) do
    local tip = not b.present and "This script doesn't do " .. b.id:lower() .. " automatically" or nil
    local v, clicked, cw = ui.checkbox("asl:basic:" .. b.id, b.id, b.value, cx, cy, { disabled = not b.present, tooltip = tip })
    if clicked then b.value = v set({ id = b.id, value = v, basic = true }) end
    cx = cx + cw + 28
  end
  cy = cy + 32

  ui.label("Options", x + pad, cy, { font = theme.fonts.header, color = theme.textDim, h = theme.controlH })
  if require("editor").isOpen() then
    local v, clicked = ui.checkbox("asl:subsplits", "Group into subsplits", asl.autoSubsplits, x + pad + 80, cy + 6,
      { tooltip = "Auto Splits makes each group of options (Items, Keys...) a collapsible section of subsplits" })
    if clicked then asl.autoSubsplits = v saveAutoSettings() end
  end
  local searchW = math.min(260, w - pad * 2 - 90)
  filter = ui.textbox("asl:search", filter, x + w - pad - searchW, cy, searchW, theme.controlH, { placeholder = "Search…" })
  cy = cy + theme.controlH + 8

  local footer = 52
  local listH = y + h - footer - cy
  local rows = buildRows(A)
  local rowH = 26
  ui.color(theme.input, 0.5) ui.rect("fill", x + pad, cy, w - pad * 2, listH, theme.radiusSmall)
  ui.color(theme.border) ui.rect("line", x + pad + 0.5, cy + 0.5, w - pad * 2 - 1, listH - 1, theme.radiusSmall)

  if #rows == 0 then
    local msg = filter ~= "" and "Nothing matches “" .. filter .. "”." or
      (A.loaded and "This script has no options." or "The script hasn't loaded yet…")
    ui.label(msg, x + pad, cy, { w = w - pad * 2, h = listH, align = "center", color = theme.textFaint })
  else
    local oy = ui.beginScroll("asl:list", x + pad, cy + 4, w - pad * 2, listH - 8, #rows * rowH)
    for i, r in ipairs(rows) do
      local ry = cy + 4 + (i - 1) * rowH - oy
      if ry > cy - rowH and ry < cy + listH then
        local rx = x + pad + 10 + r.depth * 22
        if r.hasKids then
          local hov, clicked = ui.interact("asl:fold:" .. r.s.id, rx, ry, 18, rowH)
          if clicked then collapsed[r.s.id] = not collapsed[r.s.id] end
          ui.color(hov and theme.text or theme.textDim)
          lg.setLineWidth(1.5)
          local ccx, ccy = rx + 7, ry + rowH / 2
          if collapsed[r.s.id] and filter == "" then lg.line(ccx - 2, ccy - 4, ccx + 2, ccy, ccx - 2, ccy + 4)
          else lg.line(ccx - 4, ccy - 2, ccx, ccy + 2, ccx + 4, ccy - 2) end
          lg.setLineWidth(1)
        end
        local tip = r.s.tooltip
        if not r.enabled then tip = (tip and tip .. "\n\n" or "") .. "Off because a setting above it is off." end
        local v, clicked = ui.checkbox("asl:c:" .. r.s.id, r.s.label, r.s.value, rx + 20, ry + 4,
          { tooltip = tip, font = r.hasKids and theme.fonts.uiBold or theme.fonts.ui })
        if not r.enabled then
          ui.color(theme.panel, 0.45) lg.rectangle("fill", rx + 20, ry, w - (rx - x) - pad * 2 - 20, rowH)
        end
        if clicked then r.s.value = v set({ id = r.s.id, value = v }) end
      end
    end
    ui.endScroll()
  end

  local by = y + h - footer + 12
  if ui.button("asl:defaults", "Reset to Defaults", x + pad, by, 140, theme.controlH) then
    dialogs.message({ title = "Reset to Defaults", text = "Set every option back to what the script author chose?",
      buttons = { { label = "Reset", primary = true, action = function() set({ reset = true }) end }, { label = "Cancel" } } })
  end
  local n = #asl.enabledLeaves()
  ui.label(n .. (n == 1 and " split turned on" or " splits turned on"), x + pad + 152, by,
    { h = theme.controlH, color = theme.textDim })
  return by
end

function win:draw(x, y, w, h, dt)
  local by = asl.drawPanel(x, y, w, h, dt)
  if by and ui.button("asl:done", "Done", x + w - 16 - 92, by, 92, theme.controlH, { primary = true }) then win:onClose() end
  local editorOpen = require("editor").isOpen()
  if by and ui.button("asl:auto", "Auto Splits", x + w - 16 - 92 - 8 - 110, by, 110, theme.controlH,
      { disabled = not editorOpen or not (asl.A and asl.A.loaded),
        tooltip = editorOpen and "Make your splits from the options that are turned on (you may need to fix them up)"
          or "Open Autosplitter Settings from the Splits Editor to use this" }) then
    asl.autoSplits()
  end
end

return asl
