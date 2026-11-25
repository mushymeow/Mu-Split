-- Splits Editor: the same editing LiveSplit's editor does (it runs inside
-- LiveSplit through the bridge), drawn here. Every change is sent as an op and
-- the bridge answers with the updated run.

local theme = require("theme")
local ui = require("ui")
local net = require("net")
local menu = require("menu")
local dialogs = require("dialogs")
local windows = require("windows")
local fmt = require("timerview").fmtTime

local editor = {}
local lg = love.graphics

local E = nil            -- latest editor snapshot from the bridge
local st = {}            -- view state (selection, editing, ...)

local function reset()
  st = {
    selRow = 1, selCol = 2, rows = { [1] = true }, anchor = 1,
    editing = nil, optimistic = nil, gridActive = true,
    error = nil, errorTime = 0,
  }
end

local function op(t) net.send("editor_op", t) end

function editor.onSnapshot(msg)
  E = msg
  st.optimistic = nil
  if msg.error then st.error, st.errorTime = msg.error, love.timer.getTime() end
  local n = #(E.segments or {})
  if st.selRow > n then st.selRow = math.max(1, n) end
  for r in pairs(st.rows) do if r > n then st.rows[r] = nil end end
end

---------------------------------------------------------------------------
-- columns
---------------------------------------------------------------------------
local function columns(totalW)
  local cols = {
    { key = "#", label = "", w = 36 },
    { key = "name", label = "Split", flex = true, min = 160 },
    { key = "pbSplit", label = "PB Split", w = 104, time = true },
    { key = "pbSegment", label = "PB Segment", w = 104, time = true },
    { key = "best", label = "Gold Segment", w = 112, time = true },
  }
  for _, c in ipairs(E.comparisons or {}) do
    if c ~= "Personal Best" then
      cols[#cols + 1] = { key = "comp:" .. c, label = c, w = 104, time = true, comp = c }
    end
  end
  local fixed = 0
  for _, c in ipairs(cols) do if not c.flex then fixed = fixed + c.w end end
  for _, c in ipairs(cols) do if c.flex then c.w = math.max(c.min, totalW - fixed) end end
  local x = 0
  for _, c in ipairs(cols) do c.x = x x = x + c.w end
  return cols, x
end

local function cellValue(seg, col)
  if col.key == "name" then return seg.name or "" end
  if col.comp then return seg.comps and seg.comps[col.comp] and fmt(seg.comps[col.comp]) or "" end
  local v = seg[col.key]
  return v and fmt(v) or ""
end

---------------------------------------------------------------------------
-- actions
---------------------------------------------------------------------------
local function beginEdit(row, colIdx, initial, cols)
  local col = cols[colIdx]
  if not col or col.key == "#" then return end
  local seg = E.segments[row]
  if not seg then return end
  local text = initial or cellValue(seg, col)
  st.editing = { row = row, col = colIdx, key = col.key, text = text, started = false, selectAll = initial == nil }
end

local function commitEdit(ed, text)
  if ed.key == "name" then
    op({ op = "name", i = ed.row - 1, value = text })
  else
    op({ op = "time", i = ed.row - 1, col = ed.key, value = text })
  end
  st.optimistic = { row = ed.row, key = ed.key, text = text }
end

local function selectedIndices()
  local list = {}
  for r in pairs(st.rows) do list[#list + 1] = r - 1 end
  if #list == 0 then list[1] = st.selRow - 1 end
  return list
end

local function selectRow(r, ctrl, shift)
  local n = #E.segments
  r = math.max(1, math.min(n, r))
  if shift then
    st.rows = {}
    local a, b = math.min(st.anchor, r), math.max(st.anchor, r)
    for i = a, b do st.rows[i] = true end
  elseif ctrl then
    st.rows[r] = not st.rows[r] or nil
    st.anchor = r
  else
    st.rows = { [r] = true }
    st.anchor = r
  end
  st.selRow = r
  st.wantScroll = true
end

---------------------------------------------------------------------------
-- subsplits (LiveSplit's naming: "-Name" is a subsplit, "{Section} Name" ends the section)
---------------------------------------------------------------------------
local function isSub(name) return (name or ""):sub(1, 1) == "-" end
local function sectionOf(name) return (name or ""):match("^%-?{(.-)}") end
local function bareName(name)
  name = (name or ""):gsub("^%-", "")
  return (name:gsub("^{.-}%s*", ""))
end
local function rename(row, name) op({ op = "name", i = row - 1, value = name }) end

-- the split that ends the section row r is in (the first non-subsplit at or below it)
local function sectionEnd(r)
  local segs = E.segments
  while r <= #segs and isSub(segs[r].name) do r = r + 1 end
  return r <= #segs and r or nil
end

-- what the Subsplit button does with the selected rows:
--   one ordinary split   -> it becomes a subsplit of the section ending at the next ordinary split
--   one subsplit         -> back to an ordinary split
--   several splits       -> they become one section; the last one ends it
-- a section without a name gets one (asked for).
local function subsplitAction()
  if not E then return end
  local segs = E.segments
  local sel = selectedIndices()
  table.sort(sel)
  local first, last = sel[1] + 1, sel[#sel] + 1

  local function nameSection(endRow, rows)
    local cur = sectionOf(segs[endRow].name)
    if cur then return end
    -- default section name: the splits' own names joined, or "Section"
    dialogs.input({ title = "Name This Section", label = "Section name (shown when it's folded):",
      text = bareName(segs[endRow].name), okLabel = "OK",
      onOk = function(sec)
        if sec == "" then return end
        rename(endRow, "{" .. sec .. "} " .. bareName(segs[endRow].name))
      end })
  end

  if first == last then
    local name = segs[first].name or ""
    if isSub(name) then rename(first, name:sub(2)) return end
    local endRow = sectionEnd(first + 1)
    if not endRow then
      st.error, st.errorTime = "The last split can't be a subsplit: a section needs a split after it to end it.", love.timer.getTime()
      return
    end
    rename(first, "-" .. bareName(name))
    nameSection(endRow)
  else
    for r = first, last - 1 do
      if not isSub(segs[r].name) then rename(r, "-" .. bareName(segs[r].name)) end
    end
    if isSub(segs[last].name) then rename(last, segs[last].name:sub(2)) end
    nameSection(last)
  end
end
editor.subsplitAction = subsplitAction
function editor.select(r, ctrl, shift) selectRow(r, ctrl, shift) end

local function addComparison()
  dialogs.input({ title = "New Comparison", label = "Comparison name:", okLabel = "Add",
    onOk = function(name) op({ op = "comp_add", name = name }) end })
end

local function comparisonMenu(name, x, y)
  menu.open({
    { label = "Rename “" .. name .. "”…", action = function()
      dialogs.input({ title = "Rename Comparison", label = "New name:", text = name, okLabel = "Rename",
        onOk = function(new) op({ op = "comp_rename", old = name, new = new }) end })
    end },
    { label = "Remove “" .. name .. "”", action = function()
      dialogs.message({ title = "Remove Comparison", text = "Remove the comparison “" .. name .. "”? Its times will be deleted.",
        buttons = { { label = "Remove", primary = true, action = function() op({ op = "comp_remove", name = name }) end },
                    { label = "Cancel" } } })
    end },
    { separator = true },
    { label = "Add Comparison…", action = addComparison },
  }, x, y)
end

---------------------------------------------------------------------------
-- window
---------------------------------------------------------------------------
local win = { title = "Splits Editor", w = 980, h = 740 }

function editor.open()
  E = nil
  reset()
  net.send("editor_begin")
  windows.push(win)
end

function editor.isOpen()
  for _, w in ipairs(windows.stack) do if w == win then return true end end
  return false
end

-- for Auto Splits (aslwindow.lua)
function editor.op(t) op(t) end
function editor.canChangeSegments() return E ~= nil and E.canChangeSegments end
function editor.segmentNames()
  local out = {}
  for i, seg in ipairs((E and E.segments) or {}) do out[i] = seg.name or "" end
  return out
end

function win:onClose()
  net.send("editor_cancel")
  windows.pop(win)
end

local function finishOk()
  net.send("editor_ok")
  windows.pop(win)
end

function win:keypressed(key)
  if not E or st.editing or ui.wantsKeyboard() or not st.gridActive then return false end
  local cols = st.cols
  if not cols then return false end
  local ctrl = love.keyboard.isDown("lctrl", "rctrl")
  local shift = love.keyboard.isDown("lshift", "rshift")
  if key == "up" then selectRow(st.selRow - 1, false, shift) return true
  elseif key == "down" then selectRow(st.selRow + 1, false, shift) return true
  elseif key == "left" then st.selCol = math.max(2, st.selCol - 1) return true
  elseif key == "right" or key == "tab" then st.selCol = math.min(#cols, st.selCol + 1) return true
  elseif key == "return" or key == "f2" or key == "kpenter" then beginEdit(st.selRow, st.selCol, nil, cols) return true
  elseif key == "delete" then
    local col = cols[st.selCol]
    if col and col.time then op({ op = "time", i = st.selRow - 1, col = col.key, value = "" }) end
    return true
  elseif key == "a" and ctrl then
    st.rows = {}
    for i = 1, #E.segments do st.rows[i] = true end
    return true
  end
  return false
end

function win:draw(x, y, w, h, dt)
  local pad = 16
  local F = theme.fonts
  if not E then
    ui.label("Loading…", x, y + h / 2 - 10, { w = w, align = "center", color = theme.textDim })
    return
  end

  -- typing on a selected cell starts editing it (like a spreadsheet)
  if not st.editing and st.gridActive and not ui.wantsKeyboard() and #ui.texts > 0 and st.cols and not dialogs.isOpen() and not menu.isOpen() then
    beginEdit(st.selRow, st.selCol, table.concat(ui.texts), st.cols)
    ui.texts = {}
  end

  ---------------------------------------------------------------- form
  local fy = y + 14
  local labelW = 84
  local fieldW = math.floor((w - pad * 3) / 2) - labelW
  local col2 = x + pad + labelW + fieldW + pad

  local function field(id, label, value, fx, fyy, fw, key, opt)
    ui.label(label, fx, fyy, { h = theme.controlH, color = theme.textDim })
    local v, _, committed = ui.textbox(id, value, fx + labelW, fyy, fw, theme.controlH, opt)
    if ui.focus == id then st.gridActive = false end
    if committed and tostring(v) ~= tostring(value) then op({ op = "set", field = key, value = v }) end
  end

  field("ed:game", "Game", E.game or "", x + pad, fy, fieldW, "game")
  field("ed:category", "Category", E.category or "", col2, fy, fieldW, "category")
  fy = fy + theme.controlH + 10
  field("ed:attempts", "Attempts", tostring(E.attempts or 0), x + pad, fy, 120, "attempts", { numeric = true })
  field("ed:offset", "Offset", fmt(E.offset or 0, 3), x + pad + labelW + 120 + pad + 10, fy, 120, "offset")
  ui.label("Timing", col2, fy, { h = theme.controlH, color = theme.textDim })
  local m, changed = ui.segmented("ed:method", { { label = "Real Time", value = "real" }, { label = "Game Time", value = "game" } },
    E.method, col2 + labelW, fy, 220, theme.controlH)
  if changed then op({ op = "method", value = m }) E.method = m end

  ---------------------------------------------------------------- autosplitter
  fy = fy + theme.controlH + 14
  local asb = E.autosplitter or {}
  local boxH = 48
  ui.color(theme.panelAlt) ui.rect("fill", x + pad, fy, w - pad * 2, boxH, theme.radiusSmall)
  ui.color(theme.border) ui.rect("line", x + pad + 0.5, fy + 0.5, w - pad * 2 - 1, boxH - 1, theme.radiusSmall)
  local dot = asb.running and theme.aheadGain or (asb.enabled and theme.gold or theme.textFaint)
  ui.color(dot) lg.circle("fill", x + pad + 16, fy + boxH / 2, 4)
  local desc
  if not asb.available then desc = "No autosplitter available for this game name."
  else
    desc = asb.description or "Autosplitter available"
    if asb.pending and asb.enabled then desc = desc .. "  (starts when you press OK)" end
  end
  local btnW = 104
  ui.label(ui.ellipsize(F.ui, desc, w - pad * 2 - 40 - btnW * 3 - 38), x + pad + 30, fy, { h = boxH })
  local bx = x + w - pad - 12 - btnW * 2 - 8
  if ui.button("ed:asl:auto", "Auto Splits", bx - btnW - 8, fy + 10, btnW, theme.controlH,
    { disabled = not (asb.running and asb.asl) or not E.canChangeSegments,
      tooltip = "Make your splits from the autosplitter options that are turned on" }) then
    require("aslwindow").openAutoSplits()
  end
  if ui.button("ed:asl:toggle", asb.enabled and "Deactivate" or "Activate", bx, fy + 10, btnW, theme.controlH,
    { disabled = not asb.available, primary = asb.available and not asb.enabled }) then
    net.send("asl_toggle", E.game or "")
  end
  if ui.button("ed:asl:settings", "Settings", bx + btnW + 8, fy + 10, btnW, theme.controlH,
    { disabled = not (asb.running and (asb.asl or asb.hasSettings)) }) then
    if asb.asl then require("aslwindow").open()
    else require("filedialog").allowForeground() net.send("asl_native") end
  end

  ---------------------------------------------------------------- grid
  fy = fy + boxH + 14
  local bottomH = 96
  local gx, gy, gw = x + pad, fy, w - pad * 2
  local gh = y + h - bottomH - gy
  local headerH, rowH = 28, theme.tableRowH
  local cols, contentW = columns(gw)
  st.cols = cols

  ui.color(theme.input, 0.5) ui.rect("fill", gx, gy, gw, gh, theme.radiusSmall)
  ui.color(theme.border) ui.rect("line", gx + 0.5, gy + 0.5, gw - 1, gh - 1, theme.radiusSmall)

  -- header
  ui.color(theme.panelAlt) lg.rectangle("fill", gx + 1, gy + 1, gw - 2, headerH - 1)
  ui.color(theme.border) lg.rectangle("fill", gx, gy + headerH, gw, 1)
  ui.pushClip(gx, gy, gw, headerH)
  for i, c in ipairs(cols) do
    local cx = gx + c.x
    if i > 1 then ui.color(theme.border) lg.rectangle("fill", cx, gy + 6, 1, headerH - 12) end
    ui.label(ui.ellipsize(F.header, c.label, c.w - 12), cx + 8, gy, { h = headerH, font = F.header, color = theme.textDim })
    if c.comp then
      local hov = ui.hoverable(cx, gy, c.w, headerH)
      if hov then
        ui.setTooltip("ed:colh:" .. c.comp, "Right-click to rename or remove")
        if ui.rightPressed then comparisonMenu(c.comp, ui.mx, ui.my) end
      end
    end
  end
  ui.popClip()

  -- rows
  local n = #E.segments
  local listY, listH = gy + headerH + 1, gh - headerH - 2
  local oy = ui.beginScroll("ed:grid", gx, listY, gw, listH, n * rowH)
  local firstRow = math.max(1, math.floor(oy / rowH) + 1)
  local lastRow = math.min(n, math.ceil((oy + listH) / rowH) + 1)
  lg.setFont(F.ui)
  for r = firstRow, lastRow do
    local seg = E.segments[r]
    local ry = listY + (r - 1) * rowH - oy
    if r % 2 == 0 then ui.color(theme.panelAlt, 0.6) lg.rectangle("fill", gx + 1, ry, gw - 2, rowH) end
    if st.rows[r] then ui.color(theme.selection) lg.rectangle("fill", gx + 1, ry, gw - 2, rowH) end

    for ci, c in ipairs(cols) do
      local cx = gx + c.x
      local isSel = r == st.selRow and ci == st.selCol
      local editingHere = st.editing and st.editing.row == r and st.editing.col == ci

      if editingHere then
        local ed = st.editing
        local id = "ed:cell"
        if not ed.started then ui.focusText(id, ed.text, ed.selectAll) ed.started = true end
        -- Tab / Enter commit and move, like a spreadsheet
        local tab = ui.focus == id and ui.consumeKey("tab")
        local text, _, committed = ui.textbox(id, ed.text, cx + 1, ry + 1, c.w - 2, rowH - 2,
          { align = c.time and "right" or "left", blurOnEnter = true })
        ed.text = text
        if tab then
          commitEdit(ed, text) st.editing = nil ui.setFocus(nil) ui.blurred[id] = nil
          st.selCol = math.min(#cols, ci + 1)
        elseif committed then
          commitEdit(ed, text) st.editing = nil
          if love.keyboard.isDown("return", "kpenter") then selectRow(r + 1) end
        elseif ui.focus ~= id and ui.blurred[id] == nil then
          st.editing = nil   -- Escape: cancelled
        end
      else
        local value
        if c.key == "#" then value = tostring(r)
        elseif st.optimistic and st.optimistic.row == r and st.optimistic.key == c.key then value = st.optimistic.text
        else value = cellValue(seg, c) end
        local color = c.key == "#" and theme.textFaint or theme.text
        if c.key == "best" and value ~= "" then color = theme.gold end
        ui.pushClip(cx, ry, c.w, rowH)
        lg.setFont(F.ui)
        ui.color(color)
        local ty = math.floor(ry + (rowH - F.ui:getHeight()) / 2)
        if c.time then lg.printf(value, cx, ty, c.w - 10, "right")
        elseif c.key == "#" then lg.printf(value, cx, ty, c.w - 8, "right")
        else lg.print(ui.ellipsize(F.ui, value, c.w - 16), cx + 8, ty) end
        ui.popClip()
        if isSel and st.gridActive then
          ui.color(theme.accent) ui.rect("line", cx + 1.5, ry + 1.5, c.w - 3, rowH - 3, 3)
        end

        -- mouse
        local hov, clicked = ui.interact("ed:c:" .. r .. ":" .. ci, cx, ry, c.w, rowH)
        if hov and ui.pressed and not ui.swallowClick then
          st.gridActive = true
          if st.editing then
            -- clicking another cell finishes the edit in progress
            commitEdit(st.editing, st.editing.text)
            st.editing = nil
          end
          if ui.focus then ui.setFocus(nil) end
          ui.blurred["ed:cell"] = nil
          local ctrl = love.keyboard.isDown("lctrl", "rctrl")
          local shift = love.keyboard.isDown("lshift", "rshift")
          if ui.doubleClick and r == st.selRow and ci == st.selCol then
            beginEdit(r, ci, nil, cols)
          else
            selectRow(r, ctrl, shift)
            if ci > 1 then st.selCol = ci end
          end
        end
        if hov and ui.rightPressed then
          if not st.rows[r] then selectRow(r) end
          if ci > 1 then st.selCol = ci end
          editor.rowMenu(ui.mx, ui.my)
        end
      end
      if ci > 1 then ui.color(theme.border, 0.5) lg.rectangle("fill", cx, ry, 1, rowH) end
    end
  end
  ui.endScroll()
  if st.wantScroll then
    ui.scrollTo("ed:grid", (st.selRow - 1) * rowH, st.selRow * rowH)
    st.wantScroll = false
  end

  ---------------------------------------------------------------- buttons
  local by = gy + gh + 12
  local bw, gap = 104, 8
  local can = E.canChangeSegments
  local bxx = x + pad
  -- left row (6 buttons) shrinks to stay clear of the right-hand ones
  local rightStart = x + w - pad - bw * 3 - gap * 2 - 32
  local lbw = math.max(70, math.min(bw, math.floor((rightStart - gap * 2 - bxx) / 6) - gap))
  local function btn(id, label, fn, opt)
    if ui.button(id, label, bxx, by, lbw, theme.controlH, opt) then fn() end
    bxx = bxx + lbw + gap
  end
  btn("ed:insA", "Insert Above", function() op({ op = "insert", i = st.selRow - 1, where = "above" }) end, { disabled = not can })
  btn("ed:insB", "Insert Below", function()
    op({ op = "insert", i = st.selRow - 1, where = "below" })
    selectRow(st.selRow + 1)
  end, { disabled = not can })
  btn("ed:remove", "Remove", function() op({ op = "remove", indices = selectedIndices() }) end,
    { disabled = not can or n <= 1 })
  btn("ed:up", "Move Up", function()
    if st.selRow > 1 then op({ op = "move", i = st.selRow - 1, dir = -1 }) selectRow(st.selRow - 1) end
  end, { disabled = not can or st.selRow <= 1 })
  btn("ed:down", "Move Down", function()
    if st.selRow < n then op({ op = "move", i = st.selRow - 1, dir = 1 }) selectRow(st.selRow + 1) end
  end, { disabled = not can or st.selRow >= n })
  local selSub = n > 0 and isSub(E.segments[st.selRow] and E.segments[st.selRow].name)
  local multi = #selectedIndices() > 1
  btn("ed:subsplit", multi and "Make Section" or (selSub and "Not Subsplit" or "Subsplit"), subsplitAction,
    { tooltip = multi and "Group the selected splits into a collapsible section (the last one ends it)"
      or (selSub and "Turn this back into an ordinary split"
      or "Make this a subsplit: it's grouped with the splits below it, up to the next ordinary split") })

  local rx = x + w - pad - bw
  if ui.button("ed:clearTimes", "Clear Times", rx, by, bw, theme.controlH) then
    dialogs.message({ title = "Clear Times", text = "This removes all times, including your Personal Best and best segments. Continue?",
      buttons = { { label = "Clear", primary = true, action = function() op({ op = "clear_times" }) end }, { label = "Cancel" } } })
  end
  rx = rx - bw - gap
  if ui.button("ed:clearHistory", "Clear History", rx, by, bw, theme.controlH) then
    dialogs.message({ title = "Clear History", text = "This removes your attempt history and segment history. Continue?",
      buttons = { { label = "Clear", primary = true, action = function() op({ op = "clear_history" }) end }, { label = "Cancel" } } })
  end
  rx = rx - bw - gap - 16
  if ui.button("ed:addComp", "Add Comparison", rx - 16, by, bw + 16, theme.controlH) then addComparison() end

  -- footer
  local fy2 = y + h - 44
  ui.color(theme.border) lg.rectangle("fill", x, fy2 - 8, w, 1)
  local errAge = love.timer.getTime() - st.errorTime
  if st.error and errAge < 6 then
    ui.label(st.error, x + pad, fy2, { h = theme.controlH, color = theme.danger })
  elseif not can then
    ui.label("Splits can't be added, removed or moved during a run.", x + pad, fy2, { h = theme.controlH, color = theme.textDim })
  else
    ui.label(E.hasChanged and "Changes apply when you press OK." or "No changes.", x + pad, fy2, { h = theme.controlH, color = theme.textDim })
  end
  if ui.button("ed:ok", "OK", x + w - pad - 92, fy2, 92, theme.controlH, { primary = true }) then finishOk() end
  if ui.button("ed:cancel", "Cancel", x + w - pad - 92 * 2 - 8, fy2, 92, theme.controlH) then win:onClose() end
end

function editor.rowMenu(mx, my)
  local can = E and E.canChangeSegments
  menu.open({
    { label = "Insert Above", disabled = not can, action = function() op({ op = "insert", i = st.selRow - 1, where = "above" }) end },
    { label = "Insert Below", disabled = not can, action = function() op({ op = "insert", i = st.selRow - 1, where = "below" }) selectRow(st.selRow + 1) end },
    { label = "Remove", disabled = not can or #E.segments <= 1, action = function() op({ op = "remove", indices = selectedIndices() }) end },
    { separator = true },
    { label = "Move Up", disabled = not can or st.selRow <= 1, action = function() op({ op = "move", i = st.selRow - 1, dir = -1 }) selectRow(st.selRow - 1) end },
    { label = "Move Down", disabled = not can or st.selRow >= #E.segments, action = function() op({ op = "move", i = st.selRow - 1, dir = 1 }) selectRow(st.selRow + 1) end },
    { separator = true },
    { label = #selectedIndices() > 1 and "Make Section"
        or (isSub(E.segments[st.selRow] and E.segments[st.selRow].name) and "Make Ordinary Split" or "Make Subsplit"),
      action = subsplitAction },
  }, mx, my)
end

reset()
return editor
