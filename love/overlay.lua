-- In-game overlay mode.
--
-- The Mu Split window turns into a small borderless, always-on-top, click-through
-- timer over your game (run the game in Borderless / Windowed Fullscreen; nothing
-- can draw over exclusive fullscreen). LiveSplit keeps running the real autosplitter
-- underneath, so load removal and splits behave exactly like in LiveSplit.
--
-- Press the overlay hotkey (Tab by default) anywhere, even in the game, to open the
-- settings panel; press it again (or Esc) to go back to the game.

local theme = require("theme")
local ui = require("ui")
local net = require("net")
local json = require("json")
local view = require("timerview")
local dialogs = require("dialogs")
local aslwindow = require("aslwindow")
local profiles = require("gameprofiles")

local overlay = { active = false, panel = false, tab = "timer" }
local lg = love.graphics
local damp = ui.damp
local isWindows = love.system.getOS() == "Windows"

---------------------------------------------------------------------------
-- settings (saved to overlay.json in Mu Split's save folder)
---------------------------------------------------------------------------
local DEFAULTS = {
  hotkey = "tab",
  corner = "top-right", dx = 24, dy = 24, display = 1,
  scale = 1, opacity = 1, plate = true,
  showSplit = true, showDelta = true, showCounter = true, showRta = false, showLoading = true,
  startInOverlay = false,
}
local cfg = {}
for k, v in pairs(DEFAULTS) do cfg[k] = v end
overlay.cfg = cfg

local function loadCfg()
  local data = love.filesystem.getInfo("overlay.json") and love.filesystem.read("overlay.json")
  if not data then return end
  local ok, t = pcall(json.decode, data)
  if ok and type(t) == "table" then
    for k, v in pairs(t) do if DEFAULTS[k] ~= nil and type(v) == type(DEFAULTS[k]) then cfg[k] = v end end
  end
end

local function saveCfg()
  pcall(love.filesystem.write, "overlay.json", json.encode(cfg))
end
overlay.saveCfg = saveCfg

loadCfg()

---------------------------------------------------------------------------
-- Win32: window styles, focus, global key polling
---------------------------------------------------------------------------
local win32 = {}
if isWindows then
  local ffi = require("ffi")
  pcall(ffi.cdef, [[
    typedef intptr_t MUSPLIT_LONG_PTR;
    void* FindWindowW(const wchar_t* cls, const wchar_t* title);
    MUSPLIT_LONG_PTR GetWindowLongPtrW(void* hwnd, int index);
    MUSPLIT_LONG_PTR SetWindowLongPtrW(void* hwnd, int index, MUSPLIT_LONG_PTR value);
    int SetLayeredWindowAttributes(void* hwnd, uint32_t colorKey, uint8_t alpha, uint32_t flags);
    int SetWindowPos(void* hwnd, void* after, int x, int y, int cx, int cy, uint32_t flags);
    void* GetForegroundWindow(void);
    int SetForegroundWindow(void* hwnd);
    int BringWindowToTop(void* hwnd);
    int ShowWindow(void* hwnd, int cmd);
    uint32_t GetWindowThreadProcessId(void* hwnd, uint32_t* pid);
    int AttachThreadInput(uint32_t attach, uint32_t attachTo, int doAttach);
    uint32_t GetCurrentThreadId(void);
    short GetAsyncKeyState(int vk);
  ]])
  pcall(ffi.cdef, [[
    int MultiByteToWideChar(unsigned int CodePage, uint32_t dwFlags, const char* lpMultiByteStr,
                            int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
  ]])
  local C = ffi.C

  local function wide(s)
    local n = C.MultiByteToWideChar(65001, 0, s, -1, nil, 0)
    local buf = ffi.new("wchar_t[?]", n)
    C.MultiByteToWideChar(65001, 0, s, -1, buf, n)
    return buf
  end

  local GWL_EXSTYLE = -20
  local WS_EX_TOPMOST, WS_EX_TRANSPARENT, WS_EX_TOOLWINDOW = 0x8, 0x20, 0x80
  local WS_EX_APPWINDOW, WS_EX_LAYERED, WS_EX_NOACTIVATE = 0x40000, 0x80000, 0x08000000
  local LWA_COLORKEY, LWA_ALPHA = 0x1, 0x2
  local SWP_NOSIZE, SWP_NOMOVE, SWP_NOACTIVATE, SWP_FRAMECHANGED = 0x1, 0x2, 0x10, 0x20
  local HWND_TOPMOST = ffi.cast("void*", -1)
  local HWND_NOTOPMOST = ffi.cast("void*", -2)

  -- the colour that becomes see-through (never used by the UI itself)
  win32.KEY = { 1 / 255, 0, 1 / 255 }
  local KEYREF = 1 + 0 * 256 + 1 * 65536

  local hwnd, originalEx

  function win32.hwnd()
    if hwnd then return hwnd end
    -- find our own window by giving it a unique title for a moment
    local old = love.window.getTitle()
    local tag = "MuSplit-find-" .. tostring(os.time()) .. "-" .. tostring(math.random(1e6))
    love.window.setTitle(tag)
    hwnd = C.FindWindowW(nil, wide(tag))
    love.window.setTitle(old)
    if hwnd == nil then hwnd = nil end
    -- remember the normal style only the first time (later it's already ours)
    if hwnd and not originalEx then originalEx = C.GetWindowLongPtrW(hwnd, GWL_EXSTYLE) end
    return hwnd
  end

  -- LÖVE may recreate the OS window when its mode changes: look it up again
  function win32.refresh() hwnd = nil end

  -- passive: see-through + click-through; interactive: normal clicks/keys
  function win32.apply(clickThrough, opacity)
    local h = win32.hwnd()
    if not h then return false end
    local ex = tonumber(originalEx or 0)
    ex = bit.bor(bit.band(ex, bit.bnot(WS_EX_APPWINDOW)), WS_EX_LAYERED, WS_EX_TOPMOST, WS_EX_TOOLWINDOW)
    if clickThrough then ex = bit.bor(ex, WS_EX_TRANSPARENT, WS_EX_NOACTIVATE) end
    C.SetWindowLongPtrW(h, GWL_EXSTYLE, ex)
    local a = math.floor(math.max(0.2, math.min(1, opacity or 1)) * 255 + 0.5)
    C.SetLayeredWindowAttributes(h, KEYREF, a, bit.bor(LWA_COLORKEY, LWA_ALPHA))
    C.SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, bit.bor(SWP_NOMOVE, SWP_NOSIZE, SWP_NOACTIVATE, SWP_FRAMECHANGED))
    return true
  end

  function win32.restore()
    local h = win32.hwnd()
    if not h or not originalEx then return end
    C.SetWindowLongPtrW(h, GWL_EXSTYLE, originalEx)
    C.SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, bit.bor(SWP_NOMOVE, SWP_NOSIZE, SWP_FRAMECHANGED))
  end

  function win32.foreground() return C.GetForegroundWindow() end

  -- Windows only lets the foreground app hand focus around; borrowing its input
  -- queue for a moment is the standard way to take focus from the game politely.
  function win32.focus(target)
    target = target or win32.hwnd()
    if not target then return end
    local fg = C.GetForegroundWindow()
    local fgThread = fg ~= nil and C.GetWindowThreadProcessId(fg, nil) or 0
    local me = C.GetCurrentThreadId()
    if fgThread ~= 0 and fgThread ~= me then C.AttachThreadInput(me, fgThread, 1) end
    C.BringWindowToTop(target)
    C.SetForegroundWindow(target)
    if fgThread ~= 0 and fgThread ~= me then C.AttachThreadInput(me, fgThread, 0) end
  end

  function win32.keyDown(vk) return vk and bit.band(C.GetAsyncKeyState(vk), 0x8000) ~= 0 end
else
  win32.KEY = { 0, 0, 0 }
  function win32.hwnd() return nil end
  function win32.refresh() end
  function win32.apply() return false end
  function win32.restore() end
  function win32.foreground() return nil end
  function win32.focus() end
  function win32.keyDown() return false end
end

-- LÖVE key names -> Windows virtual-key codes (for the global hotkey)
local VK = {
  tab = 0x09, insert = 0x2D, delete = 0x2E, home = 0x24, ["end"] = 0x23, pageup = 0x21, pagedown = 0x22,
  ["`"] = 0xC0, capslock = 0x14, pause = 0x13, scrolllock = 0x91, numlock = 0x90,
  ["kp+"] = 0x6B, ["kp-"] = 0x6D, ["kp*"] = 0x6A, ["kp/"] = 0x6F, ["kp."] = 0x6E,
  rctrl = 0xA3, ralt = 0xA5, rshift = 0xA1, ["["] = 0xDB, ["]"] = 0xDD, ["\\"] = 0xDC,
}
for i = 0, 9 do VK[tostring(i)] = 0x30 + i VK["kp" .. i] = 0x60 + i end
for i = 1, 24 do VK["f" .. i] = 0x6F + i end
for c = string.byte("a"), string.byte("z") do VK[string.char(c)] = c - 32 end

local function keyLabel(k)
  if not k then return "None" end
  local names = { tab = "Tab", insert = "Insert", delete = "Delete", home = "Home", ["end"] = "End",
    pageup = "Page Up", pagedown = "Page Down", capslock = "Caps Lock", pause = "Pause",
    scrolllock = "Scroll Lock", numlock = "Num Lock", rctrl = "Right Ctrl", ralt = "Right Alt", rshift = "Right Shift" }
  if names[k] then return names[k] end
  if k:match("^kp") then return "Num " .. k:sub(3) end
  return k:upper()
end
overlay.keyLabel = keyLabel

---------------------------------------------------------------------------
-- geometry
---------------------------------------------------------------------------
local saved = nil        -- normal window geometry to go back to
local prevForeground = nil
local lastSize = nil
local capturingKey = false
local hotkeyWasDown = false

local function F(size, kind) return theme.font(math.max(6, math.floor(size * cfg.scale + 0.5)), kind) end

-- content size of the timer box, from settings only (so it doesn't resize while running)
local function timerSize()
  local s = cfg.scale
  local w = math.floor(280 * s)
  local h = math.floor(18 * s) + F(46, "semibold"):getHeight()
  if cfg.showSplit or cfg.showDelta then h = h + F(15):getHeight() + math.floor(4 * s) end
  if cfg.showCounter or cfg.showRta then h = h + F(12):getHeight() + math.floor(2 * s) end
  return w, h + math.floor(10 * s)
end

local PANEL_W, PANEL_H = 820, 640

local function placeWindow(w, h)
  local display = math.max(1, math.min(cfg.display, love.window.getDisplayCount()))
  local dw, dh = love.window.getDesktopDimensions(display)
  local x, y
  if overlay.panel then
    w, h = math.min(w, dw - 40), math.min(h, dh - 60)
    x, y = math.floor((dw - w) / 2), math.floor((dh - h) / 2)
  else
    local c = cfg.corner
    x = c:find("left") and cfg.dx or (c:find("right") and dw - w - cfg.dx or math.floor((dw - w) / 2))
    y = c:find("top") and cfg.dy or dh - h - cfg.dy
    x = math.max(0, math.min(dw - w, x))
    y = math.max(0, math.min(dh - h, y))
  end
  local key = table.concat({ w, h, x, y, display, tostring(overlay.panel) }, ",")
  if key == lastSize then return end
  lastSize = key
  love.window.updateMode(w, h, {
    borderless = true, resizable = false, vsync = 1, display = display, x = x, y = y,
    minwidth = 1, minheight = 1, highdpi = true,
  })
  -- SDL may reset extended styles (or the whole window) when the mode changes, so always re-apply ours
  win32.refresh()
  win32.apply(not overlay.panel, overlay.panel and 1 or cfg.opacity)
end

local function relayout()
  if not overlay.active then return end
  if overlay.panel then placeWindow(PANEL_W, PANEL_H)
  else placeWindow(timerSize()) end
end

---------------------------------------------------------------------------
-- enter / leave
---------------------------------------------------------------------------
function overlay.enter()
  if overlay.active then return end
  if not isWindows then
    dialogs.error("Overlay mode needs Windows.")
    return
  end
  local w, h, flags = love.window.getMode()
  local x, y, display = love.window.getPosition()
  saved = { w = w, h = h, flags = flags, x = x, y = y, display = display }
  win32.hwnd()
  overlay.active, overlay.panel = true, false
  lastSize = nil
  relayout()
end

function overlay.exit()
  if not overlay.active then return end
  overlay.active, overlay.panel = false, false
  if saved then
    local f = saved.flags
    f.borderless, f.resizable = false, true
    f.minwidth, f.minheight = 300, 360
    love.window.updateMode(saved.w, saved.h, f)
    love.window.setPosition(saved.x, saved.y, saved.display)
  end
  win32.refresh()
  win32.restore()
  lastSize = nil
  if ui.focus then ui.setFocus(nil) end
end

function overlay.openPanel()
  if overlay.panel then return end
  prevForeground = win32.foreground()
  overlay.panel = true
  relayout()
  win32.focus()
  if overlay.tab == "autosplitter" then aslwindow.request() end
  net.send("menu")
end

function overlay.closePanel()
  if not overlay.panel then return end
  if ui.focus then ui.setFocus(nil) end
  capturingKey = false
  overlay.panel = false
  saveCfg()
  relayout()
  -- hand focus back to the game
  if prevForeground ~= nil then win32.focus(prevForeground) end
end

function overlay.startup()
  if cfg.startInOverlay then overlay.enter() end
end

---------------------------------------------------------------------------
-- per frame
---------------------------------------------------------------------------
function overlay.update(dt)
  if not overlay.active then return end
  -- global hotkey: polled, so it works while the game has focus
  local down = win32.keyDown(VK[cfg.hotkey])
  if down and not hotkeyWasDown and not capturingKey then
    if overlay.panel then overlay.closePanel() else overlay.openPanel() end
  end
  hotkeyWasDown = down
  -- a question popped up (e.g. "save splits?") while click-through: make it answerable
  if dialogs.isOpen() and not overlay.panel then overlay.openPanel() end
end

function overlay.keypressed(key)
  if not overlay.active then return false end
  if capturingKey then
    if key == "escape" then capturingKey = false
    elseif VK[key] then cfg.hotkey = key capturingKey = false hotkeyWasDown = true saveCfg() end
    return true
  end
  if key == "escape" and overlay.panel and not ui.wantsKeyboard() and not ui.popup and not dialogs.isOpen() then
    overlay.closePanel()
    return true
  end
  return false
end

---------------------------------------------------------------------------
-- the timer box
---------------------------------------------------------------------------
local timerCol = nil

local function outlinedText(text, font, x, y, color, alignW, align)
  lg.setFont(font)
  if not cfg.plate then
    -- no background: dark outline keeps it readable on bright scenes
    lg.setColor(0.04, 0.04, 0.05, 1)
    for ox = -1, 1 do for oy = -1, 1 do
      if ox ~= 0 or oy ~= 0 then
        if alignW then lg.printf(text, x + ox, y + oy, alignW, align) else lg.print(text, x + ox, y + oy) end
      end
    end end
  end
  ui.color(color)
  if alignW then lg.printf(text, x, y, alignW, align) else lg.print(text, x, y) end
end

local function drawTimer(W, H, dt)
  local S = view.S
  local s = cfg.scale
  local pad = math.floor(12 * s)

  if cfg.plate then
    ui.color(theme.panel) ui.rect("fill", 0, 0, W, H, math.floor(theme.radius * s + 2))
    ui.color(theme.border) ui.rect("line", 0.5, 0.5, W - 1, H - 1, math.floor(theme.radius * s + 2))
  end

  if not S or not net.connected then
    outlinedText(net.connected and "Waiting…" or "Starting LiveSplit…", F(14), pad, pad, theme.textDim)
    return
  end

  local now = view.liveTime()
  local rows, info = view.buildRows(S, now)
  local target = view.timerColor(S, now, info)
  timerCol = timerCol or { target[1], target[2], target[3] }
  for k = 1, 3 do timerCol[k] = damp(timerCol[k], target[k], theme.speedTimer, dt) end

  local loading = S.method == "game" and S.gameTimePaused and S.phase == "Running"
  local col = { timerCol[1], timerCol[2], timerCol[3], (loading and cfg.showLoading) and 0.55 or 1 }

  -- big time: whole part big, decimals smaller, fixed-width digits
  local big, dec = F(46, "semibold"), F(28, "semibold")
  local tstr = view.fmtTime(math.max(0, now), 2)
  local whole, decs = tstr:match("^(.-)(%.%d+)$")
  whole, decs = whole or tstr, decs or ""
  local ty = math.floor(6 * s)
  if not cfg.plate then
    -- outline for the big digits too
    lg.setColor(0.04, 0.04, 0.05, 1)
    for _, o in ipairs({ { -1, 0 }, { 1, 0 }, { 0, -1 }, { 0, 1 }, { 1, 1 } }) do
      local dx2 = view.drawMono(dec, decs, W - pad + o[1], ty + o[2] + big:getBaseline() - dec:getBaseline())
      view.drawMono(big, whole, dx2, ty + o[2])
    end
  end
  ui.color(col)
  local decX = view.drawMono(dec, decs, W - pad, ty + big:getBaseline() - dec:getBaseline())
  view.drawMono(big, whole, decX, ty)

  if loading and cfg.showLoading then
    outlinedText("LOADING", F(10, "semibold"), pad, ty + math.floor(4 * s), theme.textDim)
  end

  local y = ty + big:getHeight() + math.floor(2 * s)

  -- current split + live delta
  if cfg.showSplit or cfg.showDelta then
    local f = F(15)
    local idx = (S.index or -1) + 1
    local seg = S.segments and S.segments[math.max(1, math.min(#S.segments, idx))]
    local row = rows[math.max(1, math.min(#rows, idx))]
    local deltaText, deltaCol = "", theme.textDim
    if cfg.showDelta then
      if row and row.live and row.delta ~= "" then deltaText, deltaCol = row.delta, row.deltaCol
      elseif info.lastDelta then deltaText, deltaCol = view.fmtDelta(info.lastDelta), info.lastDelta < 0 and theme.aheadGain or theme.behindLose end
    end
    local dw = deltaText ~= "" and f:getWidth(deltaText) + math.floor(10 * s) or 0
    if cfg.showSplit and seg and S.phase ~= "NotRunning" then
      local name = S.phase == "Ended" and "Finished" or (seg.name ~= "" and seg.name or ("Split " .. idx))
      outlinedText(ui.ellipsize(f, name, W - pad * 2 - dw), f, pad, y, theme.text)
    elseif cfg.showSplit then
      outlinedText(S.game ~= "" and S.game or "Ready", f, pad, y, theme.textDim)
    end
    if deltaText ~= "" then outlinedText(deltaText, f, pad, y, deltaCol, W - pad * 2, "right") end
    y = y + f:getHeight() + math.floor(4 * s)
  end

  -- split counter / real time
  if cfg.showCounter or cfg.showRta then
    local f = F(12)
    if cfg.showCounter and S.segments then
      local done = S.phase == "Ended" and #S.segments or math.max(0, S.index or 0)
      outlinedText(("Split %d / %d"):format(math.min(done + (S.phase == "Running" and 1 or 0), #S.segments), #S.segments),
        f, pad, y, theme.textDim)
    end
    if cfg.showRta then
      local other = S.method == "game" and ("RTA " .. view.fmtTime(view.realTimeLive(), 2)) or
        ("IGT " .. view.fmtTime(S.gameTime or 0, 2))
      outlinedText(other, f, pad, y, theme.textDim, W - pad * 2, "right")
    end
  end
end

---------------------------------------------------------------------------
-- the settings panel
---------------------------------------------------------------------------
local function row(label, y, x, w)
  ui.label(label, x, y, { h = theme.controlH, color = theme.text })
end

local function drawTimerTab(x, y, w, h)
  local S = view.S or {}
  local M = overlay.menuInfo or {}
  local pad = 20
  local colW = math.floor((w - pad * 3) / 2)
  local lx, rx = x + pad, x + pad * 2 + colW
  local labelW = 120
  local cy = y + 16

  ui.label("Timing", lx, cy, { font = theme.fonts.header, color = theme.textDim })
  cy = cy + 24
  row("Show", cy, lx)
  local m, mchg = ui.segmented("ov:method", { { label = "Game Time (IGT)", value = "game" }, { label = "Real Time", value = "real" } },
    S.method or "game", lx + labelW, cy, colW - labelW, theme.controlH)
  if mchg then net.send("timing", m) end
  cy = cy + theme.controlH + 10

  row("Compare to", cy, lx)
  local comps = {}
  for _, c in ipairs(M.customComparisons or {}) do comps[#comps + 1] = c end
  for _, c in ipairs(M.generatedComparisons or {}) do comps[#comps + 1] = c end
  if #comps == 0 then comps = { S.comparison or "Personal Best" } end
  local c, cchg = ui.dropdown("ov:comp", comps, S.comparison, lx + labelW, cy, colW - labelW, theme.controlH)
  if cchg then net.send("compare", c) end
  cy = cy + theme.controlH + 18

  ui.label("Show on the overlay", lx, cy, { font = theme.fonts.header, color = theme.textDim })
  cy = cy + 24
  local function check(id, label, key, tip)
    local _, clicked = ui.checkbox(id, label, cfg[key], lx, cy, { tooltip = tip })
    if clicked then cfg[key] = not cfg[key] end
    cy = cy + 26
  end
  check("ov:split", "Current split name", "showSplit")
  check("ov:delta", "Delta against the comparison", "showDelta")
  check("ov:count", "Split counter", "showCounter")
  check("ov:rta", "The other time (RTA / IGT) in small", "showRta")
  check("ov:loading", "Dim the timer during loads", "showLoading", "The autosplitter's load remover pauses game time")
  check("ov:plate", "Background box", "plate", "Off: just outlined text over the game")

  cy = cy + 10
  local by = y + h - 50
  if ui.button("ov:reset", "Reset Timer", lx, by, 120, theme.controlH, { disabled = S.phase == "NotRunning" }) then
    overlay.actions.reset()
  end
  if ui.button("ov:start", S.phase == "NotRunning" and "Start Timer" or "Split", lx + 128, by, 120, theme.controlH,
    { disabled = S.phase == "Ended" }) then
    net.send("splitorstart")
  end

  -- right column: placement
  cy = y + 16
  ui.label("Overlay", rx, cy, { font = theme.fonts.header, color = theme.textDim })
  cy = cy + 24
  row("Hotkey", cy, rx)
  local hkText = capturingKey and "Press a key…" or keyLabel(cfg.hotkey)
  if ui.button("ov:hotkey", hkText, rx + labelW, cy, colW - labelW, theme.controlH,
    { primary = capturingKey, tooltip = "Opens this panel from inside the game. Click, then press a key." }) then
    capturingKey = not capturingKey
  end
  cy = cy + theme.controlH + 10

  row("Position", cy, rx)
  local corners = {
    { label = "Top left", value = "top-left" }, { label = "Top centre", value = "top-center" },
    { label = "Top right", value = "top-right" }, { label = "Bottom left", value = "bottom-left" },
    { label = "Bottom centre", value = "bottom-center" }, { label = "Bottom right", value = "bottom-right" },
  }
  local corner, cornerChg = ui.dropdown("ov:corner", corners, cfg.corner, rx + labelW, cy, colW - labelW, theme.controlH)
  if cornerChg then cfg.corner = corner end
  cy = cy + theme.controlH + 10

  row("Offset X / Y", cy, rx)
  local half = math.floor((colW - labelW - 8) / 2)
  local dxv, _, dxc = ui.textbox("ov:dx", tostring(cfg.dx), rx + labelW, cy, half, theme.controlH, { numeric = true })
  if dxc then cfg.dx = tonumber(dxv) or cfg.dx end
  local dyv, _, dyc = ui.textbox("ov:dy", tostring(cfg.dy), rx + labelW + half + 8, cy, half, theme.controlH, { numeric = true })
  if dyc then cfg.dy = tonumber(dyv) or cfg.dy end
  cy = cy + theme.controlH + 10

  row("Size", cy, rx)
  local sizes = { { label = "75%", value = 0.75 }, { label = "100%", value = 1 }, { label = "125%", value = 1.25 },
    { label = "150%", value = 1.5 }, { label = "200%", value = 2 } }
  local sc, scChg = ui.dropdown("ov:scale", sizes, cfg.scale, rx + labelW, cy, colW - labelW, theme.controlH)
  if scChg then cfg.scale = sc end
  cy = cy + theme.controlH + 10

  row("Opacity", cy, rx)
  local ops = {}
  for _, v in ipairs({ 1, 0.9, 0.8, 0.7, 0.6, 0.5, 0.4 }) do ops[#ops + 1] = { label = math.floor(v * 100) .. "%", value = v } end
  local op, opChg = ui.dropdown("ov:opacity", ops, cfg.opacity, rx + labelW, cy, colW - labelW, theme.controlH)
  if opChg then cfg.opacity = op end
  cy = cy + theme.controlH + 10

  row("Monitor", cy, rx)
  local displays = {}
  for i = 1, love.window.getDisplayCount() do
    local n = love.window.getDisplayName and love.window.getDisplayName(i) or ("Display " .. i)
    displays[#displays + 1] = { label = i .. ": " .. n, value = i }
  end
  local d, dChg = ui.dropdown("ov:display", displays, cfg.display, rx + labelW, cy, colW - labelW, theme.controlH)
  if dChg then cfg.display = d end
  cy = cy + theme.controlH + 14

  local _, sio = ui.checkbox("ov:startin", "Start Mu Split in overlay mode", cfg.startInOverlay, rx, cy)
  if sio then cfg.startInOverlay = not cfg.startInOverlay end
  cy = cy + 30
  ui.label("Run the game in Borderless or Windowed mode: nothing can draw over exclusive fullscreen.",
    rx, cy, { w = colW, font = theme.fonts.small, color = theme.textFaint })

  if ui.button("ov:exit", "Leave Overlay Mode", x + w - pad - 160, by, 160, theme.controlH) then
    saveCfg()
    overlay.exit()
  end
end

local function drawSplitsTab(x, y, w, h)
  local S = view.S or {}
  local M = overlay.menuInfo or {}
  local actions = overlay.actions
  local pad = 20
  local cy = y + 16
  local bw = 150

  ui.label("Current splits", x + pad, cy, { font = theme.fonts.header, color = theme.textDim })
  cy = cy + 24
  local title = (S.game and S.game ~= "") and (S.game .. ((S.category or "") ~= "" and (" - " .. S.category) or "")) or "No splits loaded"
  ui.label(title, x + pad, cy, { font = theme.fonts.title })
  cy = cy + 24
  local file = S.filePath and S.filePath ~= "" and S.filePath or "Not saved yet"
  ui.label(ui.ellipsize(theme.fonts.ui, file .. (S.hasChanged and "   (unsaved changes)" or ""), w - pad * 2),
    x + pad, cy, { color = theme.textDim })
  cy = cy + 22
  ui.label(("%d splits   ·   %d attempts   ·   autosplitter %s"):format(S.segments and #S.segments or 0, S.attempts or 0,
    S.autosplitterRunning and "on" or "off"), x + pad, cy, { color = theme.textDim })
  cy = cy + 34

  local bx = x + pad
  local function btn(id, label, fn, opt)
    if ui.button(id, label, bx, cy, bw, theme.controlH, opt) then fn() end
    bx = bx + bw + 8
  end
  btn("ov:open", "Open Splits…", actions.openFromFile)
  btn("ov:save", "Save Splits", function() actions.save(true) end)
  btn("ov:saveas", "Save As…", function() actions.saveAs() end)
  btn("ov:edit", "Edit Splits…", function()
    -- the editor needs a normal window
    overlay.exit()
    require("editor").open()
  end, { tooltip = "Leaves overlay mode to open the full editor" })
  cy = cy + theme.controlH + 12

  if M.recent and #M.recent > 0 then
    ui.label("Recent", x + pad, cy, { font = theme.fonts.header, color = theme.textDim })
    cy = cy + 22
    for i = 1, math.min(5, #M.recent) do
      local r = M.recent[i]
      local label = (r.game or "") ~= "" and (r.game .. ((r.category or "") ~= "" and (" - " .. r.category) or "")) or (r.path:match("[^/\\]+$") or r.path)
      if ui.button("ov:recent" .. i, label, x + pad, cy, w - pad * 2, theme.controlH - 2,
        { tooltip = r.path }) then actions.openPath(r.path) end
      cy = cy + theme.controlH + 2
    end
    cy = cy + 12
  end

  -- game presets (Poppy Playtime Chapter 4, ...)
  for _, p in ipairs(profiles.list) do
    ui.color(theme.panelAlt) ui.rect("fill", x + pad, cy, w - pad * 2, 132, theme.radiusSmall)
    ui.color(theme.border) ui.rect("line", x + pad + 0.5, cy + 0.5, w - pad * 2 - 1, 131, theme.radiusSmall)
    ui.label(p.game, x + pad + 14, cy + 12, { font = theme.fonts.title })
    ui.label(p.blurb, x + pad + 14, cy + 36, { w = w - pad * 2 - 28, color = theme.textDim, font = theme.fonts.ui })
    local isThis = S.game == p.game
    if ui.button("ov:preset:" .. p.game, isThis and "Set Up Again" or "Set Up", x + pad + 14, cy + 88, 140, theme.controlH,
      { primary = not isThis, disabled = S.phase ~= "NotRunning", tooltip = "Game Time, game name, autosplitter on (downloads the script the first time)" }) then
      profiles.setup(p, overlay.menuInfo)
      overlay.tab = "autosplitter"
      aslwindow.request()
    end
    if ui.button("ov:build:" .. p.game, "Build Splits From Settings", x + pad + 162, cy + 88, 220, theme.controlH,
      { disabled = not isThis or S.phase ~= "NotRunning",
        tooltip = "One split for every option you turned on in the Autosplitter tab" .. (p.finalSegment and ", plus the final split" or "") }) then
      profiles.buildSplits(p)
    end
    cy = cy + 144
  end
end

local function drawPanel(W, H, dt)
  ui.color(theme.panel) ui.rect("fill", 0, 0, W, H, theme.radius)
  ui.color(theme.border) ui.rect("line", 0.5, 0.5, W - 1, H - 1, theme.radius)

  -- header: title, tabs, close
  local headH = 52
  ui.color(theme.panelAlt) lg.rectangle("fill", 1, 1, W - 2, headH - 1)
  ui.color(theme.border) lg.rectangle("fill", 0, headH, W, 1)
  ui.label("Mu Split", 18, 0, { font = theme.fonts.title, h = headH })
  local tabs = { { label = "Timer", value = "timer" }, { label = "Splits", value = "splits" }, { label = "Autosplitter", value = "autosplitter" } }
  local t, tchg = ui.segmented("ov:tabs", tabs, overlay.tab, 110, 12, 360, theme.controlH)
  if tchg then
    overlay.tab = t
    if t == "autosplitter" then aslwindow.request() end
    net.send("menu")
  end
  ui.label(keyLabel(cfg.hotkey) .. " or Esc to go back to the game", 0, 0,
    { w = W - 56, h = headH, align = "right", font = theme.fonts.small, color = theme.textFaint })
  if ui.button("ov:close", "×", W - 44, 12, 30, theme.controlH, { font = theme.fonts.title }) then overlay.closePanel() end

  local cy, ch = headH + 1, H - headH - 1
  if overlay.tab == "timer" then drawTimerTab(0, cy, W, ch)
  elseif overlay.tab == "splits" then drawSplitsTab(0, cy, W, ch)
  else
    local by = aslwindow.drawPanel(0, cy, W, ch, dt)
    if by and ui.button("ov:aslback", "Done", W - 16 - 92, by, 92, theme.controlH, { primary = true }) then overlay.closePanel() end
  end
end

function overlay.draw(dt)
  local W, H = lg.getDimensions()
  local key = win32.KEY
  lg.clear(key[1], key[2], key[3], 1)
  relayout()
  ui.layer = "base"
  if overlay.panel then drawPanel(W, H, dt) else drawTimer(W, H, dt) end
end

return overlay
