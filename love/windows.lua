-- LÖVE has one OS window, so "windows" (Splits Editor, Settings, Autosplitter
-- Settings) take over the app: the OS window grows to fit, and shrinks back to
-- the timer when they close. They stack: Autosplitter Settings opens on top of
-- the Splits Editor and returns to it.
--
--   win = { title=, w=, h=, draw = function(self, x, y, w, h, dt) end,
--           onClose = function(self) end }   -- onClose runs for the X button / Esc

local theme = require("theme")
local ui = require("ui")

local windows = { stack = {} }
local lg = love.graphics
local damp = ui.damp
local TITLE_H = 40

function windows.isOpen() return #windows.stack > 0 end
function windows.top() return windows.stack[#windows.stack] end

local function currentGeometry()
  local w, h, flags = love.window.getMode()
  local x, y, display = love.window.getPosition()
  return { w = w, h = h, x = x, y = y, display = display or 1, flags = flags }
end

-- Fast resize: ask SDL (which LÖVE runs on) to resize the OS window directly. LÖVE's
-- love.window.updateMode can rebuild the whole graphics context, reloading every font,
-- canvas and shader, which is what made windows slow to open. Falls back to it.
local sdl, sdlWindow
do
  local ok, ffi = pcall(require, "ffi")
  if ok then
    pcall(ffi.cdef, [[
      typedef struct SDL_Window SDL_Window;
      SDL_Window* SDL_GL_GetCurrentWindow(void);
      void SDL_SetWindowSize(SDL_Window* window, int w, int h);
      void SDL_SetWindowMinimumSize(SDL_Window* window, int min_w, int min_h);
      void SDL_SetWindowAlwaysOnTop(SDL_Window* window, int on_top);
      void SDL_SetWindowBordered(SDL_Window* window, int bordered);
    ]])
    local okLib, lib = false, nil
    -- Linux: LÖVE's own SDL (a second copy loaded by name wouldn't know LÖVE's window)
    if jit and jit.os ~= "Windows" and pcall(function() return ffi.C.SDL_GL_GetCurrentWindow end) then
      okLib, lib = true, ffi.C
    end
    if not okLib then okLib, lib = pcall(ffi.load, "SDL2") end
    if not okLib then okLib, lib = pcall(ffi.load, "libSDL2-2.0.so.0") end
    if okLib then sdl = lib end
  end
end

local function isNull(p)
  if p == nil then return true end
  local s = tostring(p)
  return s:find("NULL", 1, true) ~= nil or s:find("(nil)", 1, true) ~= nil or s:match(": 0x0+$") ~= nil
end

local function fastResize(w, h, minw, minh)
  if not sdl then return false end
  local ok = pcall(function()
    if isNull(sdlWindow) then sdlWindow = sdl.SDL_GL_GetCurrentWindow() end
    if isNull(sdlWindow) then sdlWindow = nil error("no window") end
    sdl.SDL_SetWindowMinimumSize(sdlWindow, minw, minh)
    sdl.SDL_SetWindowSize(sdlWindow, w, h)
  end)
  if not ok then sdl = nil end
  return ok
end

-- with or without the title bar (SDL directly, so nothing gets reloaded)
function windows.setBordered(on)
  local ok = sdl and pcall(function()
    if isNull(sdlWindow) then sdlWindow = sdl.SDL_GL_GetCurrentWindow() end
    if isNull(sdlWindow) then sdlWindow = nil error("no window") end
    sdl.SDL_SetWindowBordered(sdlWindow, on and 1 or 0)
  end)
  if not ok then
    local w, h, flags = love.window.getMode()
    flags.borderless = not on
    pcall(love.window.updateMode, w, h, flags)
  end
end

-- size without going through LÖVE's mode change (for the resize grip)
function windows.resizeWindow(w, h)
  local _, _, flags = love.window.getMode()
  local mw, mh = flags.minwidth or 300, flags.minheight or 360
  w, h = math.max(mw, math.floor(w)), math.max(mh, math.floor(h))
  if not fastResize(w, h, mw, mh) then
    flags.minwidth, flags.minheight = mw, mh
    love.window.updateMode(w, h, flags)
  end
end

-- keep Mu Split above other windows (your game); false if this SDL can't
function windows.setAlwaysOnTop(on)
  if not sdl then return false end
  return pcall(function()
    if isNull(sdlWindow) then sdlWindow = sdl.SDL_GL_GetCurrentWindow() end
    if isNull(sdlWindow) then sdlWindow = nil error("no window") end
    sdl.SDL_SetWindowAlwaysOnTop(sdlWindow, on and 1 or 0)
  end)
end

local function resizeTo(w, h, keepCenterOf)
  local g = currentGeometry()
  local dw, dh = love.window.getDesktopDimensions(g.display)
  w, h = math.min(w, dw - 40), math.min(h, dh - 80)
  if g.w == w and g.h == h then return end
  local flags = g.flags
  flags.minwidth = math.min(flags.minwidth or 1, w)
  flags.minheight = math.min(flags.minheight or 1, h)
  local cx = (keepCenterOf or g).x + (keepCenterOf or g).w / 2
  local cy = (keepCenterOf or g).y + (keepCenterOf or g).h / 2
  if not fastResize(w, h, flags.minwidth, flags.minheight) then love.window.updateMode(w, h, flags) end
  local nx = math.max(0, math.min(dw - w, math.floor(cx - w / 2)))
  local ny = math.max(30, math.min(dh - h, math.floor(cy - h / 2)))
  love.window.setPosition(nx, ny, g.display)
end

function windows.push(win)
  win.open = 0
  win.saved = currentGeometry()
  local g = win.saved
  if g.w < win.w or g.h < win.h or #windows.stack == 0 then
    resizeTo(math.max(win.w, #windows.stack > 0 and g.w or 0), math.max(win.h, #windows.stack > 0 and g.h or 0))
  end
  windows.stack[#windows.stack + 1] = win
  if win.onOpen then win:onOpen() end
end

function windows.pop(win)
  win = win or windows.top()
  for i = #windows.stack, 1, -1 do
    if windows.stack[i] == win then
      table.remove(windows.stack, i)
      break
    end
  end
  if ui.focus then ui.setFocus(nil) end
  ui.popup = nil
  local g = win.saved
  if g then
    local flags = g.flags
    if not fastResize(g.w, g.h, flags.minwidth or 1, flags.minheight or 1) then love.window.updateMode(g.w, g.h, flags) end
    love.window.setPosition(g.x, g.y, g.display)
  end
end

-- X button / Escape
function windows.requestClose()
  local win = windows.top()
  if not win then return end
  if win.onClose then win:onClose() else windows.pop(win) end
end

function windows.keypressed(key)
  if not windows.isOpen() then return false end
  if key == "escape" and not ui.wantsKeyboard() and not ui.popup then
    windows.requestClose()
    return true
  end
  local win = windows.top()
  if win.keypressed then return win:keypressed(key) end
  return false
end

function windows.draw(dt)
  local win = windows.top()
  if not win then return end
  local W, H = lg.getDimensions()
  ui.layer = "window"
  win.open = damp(win.open, 1, theme.speedOpen, dt)

  ui.color(theme.panel) lg.rectangle("fill", 0, 0, W, H)
  ui.color(theme.panelAlt) lg.rectangle("fill", 0, 0, W, TITLE_H)
  ui.color(theme.border) lg.rectangle("fill", 0, TITLE_H - 1, W, 1)

  -- breadcrumb title for stacked windows ("Splits Editor  ›  Autosplitter Settings")
  local parts = {}
  for _, w in ipairs(windows.stack) do parts[#parts + 1] = w.title end
  ui.label(table.concat(parts, "  ›  "), 16, 0, { font = theme.fonts.title, h = TITLE_H })

  -- close (X)
  local bx, by, bs = W - TITLE_H, 0, TITLE_H
  local hov, clicked = ui.interact("win:close", bx, by, bs, bs)
  local a = ui.getAnim("win:close")
  a.hover = damp(a.hover, hov and 1 or 0, theme.speedHover, dt)
  if a.hover > 0.01 then ui.color(theme.danger, a.hover * 0.85) lg.rectangle("fill", bx, by, bs, bs - 1) end
  ui.color(theme.text)
  lg.setLineWidth(1.5)
  local cx, cy = bx + bs / 2, by + bs / 2
  lg.line(cx - 5, cy - 5, cx + 5, cy + 5)
  lg.line(cx + 5, cy - 5, cx - 5, cy + 5)
  lg.setLineWidth(1)

  win:draw(0, TITLE_H, W, H - TITLE_H, dt)
  -- fade in (no transforms: they'd throw off clipping and the mouse)
  if win.open < 0.99 then ui.color(theme.panel, 1 - win.open) lg.rectangle("fill", 0, 0, W, H) end
  ui.layer = "base"

  if clicked then windows.requestClose() end
end

return windows
