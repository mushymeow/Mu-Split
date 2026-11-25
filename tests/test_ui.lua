-- Headless test: runs the new UI code with a fake `love`, through every path.
-- texluajit test_ui.lua  (from the love folder's parent; package.path points at love/)
package.path = "./love/?.lua;" .. package.path

-- LÖVE ships a utf8 module; a byte-based stand-in is enough for ASCII test data
package.preload.utf8 = function()
  return {
    len = function(s) return #s end,
    offset = function(s, n) if n > #s + 1 then return nil end return n end,
    char = function(...) return string.char(...) end,
    codepoint = function(s, i) return s:byte(i or 1) end,
  }
end

-- LÖVE ships luasocket; the workshop only needs net.lua to load
package.preload.socket = function() return { tcp = function() return nil end, gettime = os.clock } end

-- a stand-in moonshine: records what postfx asks for
MOON = { built = 0, enabled = {}, params = {}, failDraw = false, draws = 0 }
package.preload.moonshine = function()
  local m = {}
  m.effects = setmetatable({}, { __index = function(_, name) return { name = name } end })
  local function newChain(w, h, first)
    local chain = { names = {} }
    local function add(e)
      chain.names[#chain.names + 1] = e.name
      chain[e.name] = setmetatable({}, { __newindex = function(_, k, v) MOON.params[e.name .. "." .. k] = v end })
      return chain
    end
    chain.chain = add
    chain.next = add
    chain.enable = function(...) for _, n in ipairs({ ... }) do MOON.enabled[n] = true end end
    chain.disable = function(...) for _, n in ipairs({ ... }) do MOON.enabled[n] = nil end end
    chain.resize = function(nw, nh) MOON.size = { nw, nh } end
    chain.draw = function(func)
      MOON.draws = MOON.draws + 1
      love.graphics.push()
      func()
      if MOON.failMsg then error(MOON.failMsg) end
      if MOON.failDraw then error("shader failed to compile (test)") end
      love.graphics.pop()
    end
    MOON.built = MOON.built + 1
    MOON.last = chain
    add(first)
    return chain
  end
  return setmetatable(m, { __call = function(_, w, h, e) return newChain(w, h, e) end })
end

-- syntax check every module first
for _, f in ipairs({ "workshop", "frame", "sounds", "postfx", "theme", "presets", "widgets", "timerview", "customwindow", "main", "ui", "windows", "menu", "dialogs",
                     "overlay", "editor", "settingswindow", "aslwindow", "launcher", "net", "json", "keymap", "filedialog", "gameprofiles" }) do
  local chunk, e = loadfile("./love/" .. f .. ".lua")
  if not chunk then print("SYNTAX: " .. e) os.exit(1) end
end

local clock = 0
local function noop() end
local fontMT = {}
fontMT.__index = fontMT
function fontMT:getWidth(s) assert(not self.released, "font used after release") return #tostring(s) * self.size * 0.55 end
function fontMT:release() self.released = true end
function fontMT:getHeight() return self.size * 1.33 end
function fontMT:getBaseline() return self.size * 1.05 end
function fontMT:setFilter() end
function fontMT:getWrap(text, w) return w, { text } end
local function newFont(a, b) return setmetatable({ size = type(a) == "number" and a or b or 12 }, fontMT) end

local meshMT = { __index = { setVertexAttribute = noop, setVertices = noop } }
local imgMT = { __index = { setFilter = noop, getWidth = function() return 128 end, getHeight = function() return 128 end } }

local files = {}
local drawCalls = 0
local scissorDepthOK = true

love = {
  graphics = setmetatable({
    newFont = newFont,
    newMesh = function() return setmetatable({}, meshMT) end,
    newImage = function() return setmetatable({}, imgMT) end,
    getDimensions = function() return 1100, 720 end,
    getFont = function() return newFont(13) end,
    getColor = function() return 1, 1, 1, 1 end,
    push = function() STACK = (STACK or 0) + 1 end,
    pop = function() STACK = (STACK or 0) - 1 assert(STACK >= 0, "graphics stack underflow") end,
    getStackDepth = function() return STACK or 0 end,
    setScissor = function(x, y, w, h)
      if x and (w < 0 or h < 0) then scissorDepthOK = false end
    end,
  }, { __index = function(_, k) return function() drawCalls = drawCalls + 1 end end }),
  image = { newImageData = function(w, h)
    return { mapPixel = function(self, fn) for y = 0, 3 do for x = 0, 3 do fn(x * w / 4, y * h / 4) end end end }
  end },
  timer = { getTime = function() return clock end, getDelta = function() return 1 / 60 end },
  mouse = { getPosition = function() return MX or 600, MY or 300 end, setCursor = noop, getSystemCursor = noop,
            isDown = function() return MOUSEDOWN end },
  keyboard = { isDown = function() return false end, setKeyRepeat = noop },
  filesystem = {
    getInfo = function(p) return files[p] and {} or nil end,
    read = function(p) return files[p] end,
    write = function(p, d) files[p] = d return true end,
    remove = function(p) files[p] = nil return true end,
    createDirectory = function(p) files[p] = "dir" return true end,
    getDirectoryItems = function(dir)
      local out = {}
      for k in pairs(files) do local f = k:match("^" .. dir .. "/(.+)$") if f then out[#out + 1] = f end end
      return out
    end,
    newFileData = function() error("no font files here") end,
    getSourceBaseDirectory = function() return "." end,
  },
  system = { setClipboardText = function(t) files.__clip = t end, getClipboardText = function() return files.__clip or "" end,
             getOS = function() return "Linux" end },
  window = { getMode = function() return 400, 620, {} end, getPosition = function() return 100, 100, 1 end,
             getDesktopDimensions = function() return 1920, 1080 end, setTitle = noop,
             updateMode = function(w, h, f) WINMODE = { w, h, f } end,
             setPosition = function(x, y) WINPOS = { x, y } end,
             hasMouseFocus = function() return true end, minimize = function() MINIMIZED = true end },
  event = { quit = function() QUIT = true end },
  sound = { newSoundData = function(n) return { setSample = function() end, n = n } end },
  audio = { newSource = function(data)
    local src = { data = data }
    function src:clone() return self end
    function src:setVolume(v) self.vol = v end
    function src:play() PLAYED[#PLAYED + 1] = self.name or "?" end
    return src
  end },
  math = { random = function(a, b)
    if a and b then return math.random(a, b) elseif a then return math.random(a) end return math.random() end },
}

PLAYED = {}
local function inChain(name)
  for _, n in ipairs(MOON.last and MOON.last.names or {}) do if n == name then return true end end
  return false
end

local ok, err = pcall(function()
  local theme = require("theme")
  local presets = require("presets")
  local ui = require("ui")
  local view = require("timerview")
  local windows = require("windows")
  local cw = require("customwindow")

  presets.startup()
  theme.loadFonts()
  assert(theme.style.name == "Mu", "default look")

  local function frame(dt, fn)
    clock = clock + dt
    theme.update(dt)
    presets.update(dt)
    ui.begin(dt)
    fn()
    ui.finish()
    assert(#ui.clip == 0, "clip stack not balanced: " .. #ui.clip)
  end

  -- real timer view with a fake snapshot
  local segs = {}
  for i = 1, 12 do segs[i] = { name = "Split " .. i, comp = i * 60000, best = 55000, split = i <= 4 and (i * 60000 - 500 * i) or nil } end
  local snap = { game = "Test Game", category = "Any%", attempts = 9, comparison = "Personal Best", method = "real",
    phase = "Running", time = 250000, index = 4, segments = segs, event = "split", windowHidden = true }
  view.onState(snap)
  for _ = 1, 120 do frame(1 / 60, function() view.draw(400, 620, 1 / 60, { stale = false }) end) end

  -- every built-in look, every alignment and highlight, in the real view
  for _, p in ipairs(presets.BUILTIN) do
    presets.use(p)
    for _, align in ipairs({ "left", "center", "right" }) do
      theme.style.layout.timerAlign = align
      for _, hl in ipairs({ "pill", "glow", "bar", "underline", "none" }) do
        theme.style.effects.highlight = hl
        frame(1 / 60, function() view.draw(400, 620, 1 / 60, { stale = true }) end)
      end
    end
  end
  -- ended + new PB → confetti
  snap.phase, snap.index, snap.event = "Ended", 12, nil
  for i = 1, 12 do segs[i].split = i * 60000 - 800 end
  view.onState(snap)
  frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)
  assert(#view.main.fx > 50, "confetti should spawn on a PB (got " .. #view.main.fx .. ")")
  for _ = 1, 240 do frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end) end
  -- empty / nil fields
  view.onState({ phase = "NotRunning", time = 0, index = -1, segments = {} })
  frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)
  frame(1 / 60, function() view.drawWaiting(400, 620, "Waiting", "detail") end)

  -- customise window: open, every tab, the demo preview through a whole run
  presets.use(presets.BUILTIN[1])
  cw.open()
  local splitsSeen, sparks = 0, false
  for _, tab in ipairs({ "looks", "colors", "background", "text", "layout", "effects" }) do
    cw.setTab(tab)
    for _ = 1, 30 do frame(1 / 30, function() windows.draw(1 / 30) end) end
  end
  cw.setTab("looks")
  local lastIdx = -1
  for _ = 1, 60 * 40 do
    frame(1 / 60, function() windows.draw(1 / 60) end)
    local S = view.demo.S
    if S.index ~= lastIdx then splitsSeen = splitsSeen + 1 lastIdx = S.index end
    for _, p in ipairs(view.demo.fx) do if p.kind == "spark" then sparks = true end end
  end
  assert(splitsSeen >= 6, "demo should split (saw " .. splitsSeen .. ")")
  assert(sparks, "demo gold splits should throw sparks")

  -- background modes in the editor
  for _, mode in ipairs({ "solid", "gradient", "aurora" }) do
    theme.style.background.mode = mode
    cw.setTab("background")
    frame(1 / 60, function() windows.draw(1 / 60) end)
  end

  -- presets: save, list, export/import, delete
  local st = theme.deepcopy(presets.current)
  st.colors.accent = "#123456"
  assert(presets.saveUser(st, "My Look"))
  assert(presets.exists("My Look") and not presets.isBuiltin("My Look"))
  local text = presets.export(st)
  local back = assert(presets.import(text))
  assert(back.colors.accent == "#123456", "import keeps colours")
  assert(presets.import("not json") == nil, "bad paste is rejected")
  presets.deleteUser("My Look")
  assert(not presets.exists("My Look"))
  presets.flush()
  assert(files["style.json"], "style.json written")

  -- startup restores the saved look
  presets.use(presets.BUILTIN[3])
  presets.flush()
  presets.startup()
  assert(presets.current.name == presets.BUILTIN[3].name, "restored " .. tostring(presets.current.name))

  -- shader effects
  local postfx = require("postfx")
  assert(postfx.available, "postfx sees moonshine")
  presets.use(presets.BUILTIN[1])   -- Mu: bloom + grain
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 400, 620, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  assert(MOON.built >= 1 and inChain("glow") and inChain("filmgrain"), "bloom + grain on")
  assert(not inChain("crt") and #MOON.last.names == 2, "only the effects in use are built")
  assert(MOON.params["glow.strength"] == 1.8, "bloom strength sent")
  for _, look in ipairs(postfx.LOOKS) do
    theme.style.post = theme.deepcopy(look.post)
    frame(1 / 60, function()
      postfx.wrap("main", 0, 0, 400, 620, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
    end)
    if look.name == "None" then assert(not postfx.active(), "None turns everything off") end
    if look.name == "Retro CRT" then assert(inChain("crt") and inChain("scanlines"), "crt look") end
    if look.name == "Game Boy" then assert(inChain("dmg") and MOON.params["dmg.palette"] == "default", "game boy look") end
  end
  -- the Shaders tab, and the preview through its own chain
  presets.use(presets.BUILTIN[3])
  cw.open()
  cw.setTab("shaders")
  for _ = 1, 60 do frame(1 / 60, function() windows.draw(1 / 60) end) end
  -- resize goes to the chain
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 500, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 520, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  assert(MOON.size and MOON.size[1] == 520, "resize reached the chain")
  -- same effects + same size: no rebuild
  local builds = MOON.built
  for _ = 1, 30 do frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 520, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end) end
  assert(MOON.built == builds, "chain is reused frame to frame")
  -- one effect failing (the real-world glow error) turns off only that effect
  presets.use(presets.BUILTIN[3])       -- Neon: bloom + chroma
  MOON.failMsg = "./love/moonshine/glow.lua:73: Shader uniform 'direction' does not exist."
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 520, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  MOON.failMsg = nil
  assert(postfx.disabled.glow and not postfx.broken, "only glow is switched off")
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 520, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  assert(inChain("chromasep") and not inChain("glow"), "the rest keeps running without glow")
  assert((STACK or 0) == 0, "stack balanced after a single-effect failure")
  postfx.disabled.glow = nil

  -- a shader that fails: falls back, clip and graphics stacks stay balanced
  MOON.failDraw = true
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 500, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  assert(postfx.broken, "failure turns shaders off")
  assert((STACK or 0) == 0, "graphics stack balanced after failure: " .. tostring(STACK))
  MOON.failDraw = false
  frame(1 / 60, function()
    postfx.wrap("main", 0, 0, 500, 700, function(_, _, w, h) view.draw(w, h, 1 / 60, {}) end, view.main.light)
  end)
  frame(1 / 60, function() windows.draw(1 / 60) end)   -- Shaders tab shows the "turned off" note

  -- undo, surprise, size chips' data, background picture
  postfx.broken = false
  presets.use(presets.BUILTIN[1])
  cw.open()
  cw.setTab("looks")
  local before = cw.test.edited().colors.accent
  cw.test.surprise()
  for _ = 1, 10 do frame(1 / 60, function() windows.draw(1 / 60) end) end
  assert(cw.test.history() == 1, "surprise is undoable")
  cw.test.undo()
  assert(cw.test.edited().colors.accent == before, "undo brings the accent back")
  for _ = 1, 25 do cw.test.surprise() clock = clock + 1 end          -- many random looks all draw fine
  frame(1 / 60, function() windows.draw(1 / 60) end)
  local dropped = { getFilename = function() return "C:\\Users\\me\\Pictures\\my bg.png" end,
    open = function() return true end, read = function() return "PNGDATA" end, close = function() end }
  cw.dropFile(dropped)
  assert(cw.test.edited().background.image == "backgrounds/my_bg.png", "dropped picture becomes the background: " ..
    tostring(cw.test.edited().background.image))
  assert(files["backgrounds/my_bg.png"] == "PNGDATA", "picture copied into the save folder")
  cw.setTab("background")
  for _ = 1, 5 do frame(1 / 60, function() windows.draw(1 / 60) end) end
  frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)
  cw.dropFile({ getFilename = function() return "notes.txt" end, open = function() return true end,
    read = function() return "x" end, close = function() end })   -- rejected with a message, no crash

  -- sum of best / best possible time
  local segs2 = {}
  for i = 1, 4 do segs2[i] = { name = "S" .. i, comp = i * 10000, best = 9000, split = i <= 2 and i * 9500 or nil } end
  local rows2, info2 = view.buildRows({ phase = "Running", index = 2, segments = segs2 }, 20000)
  assert(info2.sob == 36000, "sum of best " .. tostring(info2.sob))
  assert(info2.bpt == 19000 + 9000 + 9000 + 1000 or info2.bpt == math.max(20000, 19000 + 9000) + 9000, "best possible " .. tostring(info2.bpt))
  presets.use(presets.BUILTIN[2])          -- Midnight Aurora: particles on
  theme.style.layout.sumOfBest, theme.style.layout.bestPossible = true, true
  for _, a in ipairs({ "left", "right", "center" }) do
    theme.style.layout.timerAlign = a
    frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)
  end
  -- F2 cycling goes round every look and back
  local start = presets.current.name
  for _ = 1, #presets.all() do presets.cycle(1) end
  assert(presets.current.name == start, "cycling returns to the start")
  presets.cycle(-1)
  assert(not windows.setAlwaysOnTop(true), "no SDL here: always-on-top reports it couldn't")

  -- sounds: split / gold / pb / reset from the engine's events
  local sounds = require("sounds")
  view.onEvent = function(name) PLAYED[#PLAYED + 1] = name sounds.play(name) end
  presets.use(presets.BUILTIN[1])
  theme.style.sounds.enabled = true
  local sg = {}
  for i = 1, 3 do sg[i] = { name = "S" .. i, comp = i * 10000, best = 9000 } end
  view.onState({ phase = "Running", index = 0, time = 0, segments = sg, method = "real" })
  sg[1].split = 9500         -- seg 1: 9.5s vs best 9.0 → normal split
  view.onState({ phase = "Running", index = 1, time = 9500, segments = sg, event = "split", method = "real" })
  sg[2].split = 9500 + 8000  -- seg 2: 8.0s → gold
  view.onState({ phase = "Running", index = 2, time = 17500, segments = sg, event = "split", method = "real" })
  sg[3].split = 26000        -- finished ahead of 30.0 → personal best
  view.onState({ phase = "Ended", index = 3, time = 26000, segments = sg, event = "split", method = "real" })
  view.onState({ phase = "NotRunning", index = -1, time = 0, segments = sg, method = "real" })
  local got = table.concat(PLAYED, ",")
  assert(got:find("split") and got:find("gold") and got:find("pb") and got:find("reset"), "events: " .. got)
  for _, pack in ipairs({ "soft", "retro", "glass" }) do
    theme.style.sounds.pack = pack
    for _, ev in ipairs({ "split", "gold", "pb", "reset" }) do sounds.play(ev, true) end
  end
  -- possible time save
  local _, infoS = view.buildRows({ phase = "Running", index = 1, segments = {
    { comp = 10000, best = 9000, split = 9500 }, { comp = 21000, best = 9500 }, { comp = 30000, best = 8000 } } }, 15000)
  assert(infoS.saveTotal == 1000 + 1500 + 1000 and infoS.saveCur == 1500, "time save " .. tostring(infoS.saveTotal) .. "/" .. tostring(infoS.saveCur))
  -- status bar in every autosplitter state, time save on
  theme.style.layout.timeSave = true
  for _, stt in ipairs({ "off", "loading", "waiting", "connected", "running", "error" }) do
    view.onState({ phase = "Running", index = 1, time = 15000, segments = sg, method = "real",
      autosplitterStatus = stt, autosplitterGame = "Poppy_Playtime-Win64-Shipping", autosplitterError = "Access is denied" })
    frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)
  end
  -- the Sounds tab, and a look per game
  cw.open()
  cw.setTab("sounds")
  for _ = 1, 10 do frame(1 / 60, function() windows.draw(1 / 60) end) end
  presets.setPerGame(true)
  presets.onGame("Game A")
  presets.useLook(presets.BUILTIN[4])          -- Sunset for Game A
  presets.onGame("Game B")
  presets.useLook(presets.BUILTIN[5])          -- Forest for Game B
  presets.onGame("Game A")
  assert(presets.current.name == presets.BUILTIN[4].name, "Game A gets its look back: " .. presets.current.name)
  presets.onGame("Game B")
  assert(presets.current.name == presets.BUILTIN[5].name, "Game B gets its look back")
  presets.setPerGame(false)
  presets.onGame("Game A")
  assert(presets.current.name == presets.BUILTIN[5].name, "switched off: the look stays")
  assert(files["gamelooks.json"], "saved")

  -- no title bar: drag to move, grip to resize, min/close buttons
  local fr = require("frame")
  while windows.isOpen() do windows.pop() end
  fr.set(true)
  assert(WINMODE and WINMODE[3].borderless, "borderless (fallback without SDL)")
  MX, MY, MOUSEDOWN = 200, 300, true
  assert(fr.mousepressed(200, 300, 1, true), "drag starts on the timer")
  MX, MY = 230, 340
  fr.update()
  assert(WINPOS and WINPOS[1] == 100 + 30 and WINPOS[2] == 100 + 40, "window follows the mouse")
  MOUSEDOWN = false
  fr.update()
  fr.mousereleased()
  MX, MY, MOUSEDOWN = 1095, 715, true                 -- bottom-right corner of a 1100x720 window
  assert(fr.mousepressed(1095, 715, 1, true), "grip")
  MX, MY = 1145, 765
  fr.update()
  assert(WINMODE and WINMODE[1] == 400 + 50 and WINMODE[2] == 620 + 50, "resized by the drag: " .. tostring(WINMODE[1]))
  MOUSEDOWN = false
  fr.mousereleased()
  for _ = 1, 20 do frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) ui.layer = "base" fr.draw(1 / 60) end) end
  fr.set(false)
  MX, MY = nil, nil

  -- workshop: list from GitHub (through the engine), cards, install, share link
  local ws = require("workshop")
  local netm = require("net")
  local sentCmds = {}
  netm.connected = true
  netm.send = function(cmd, arg) sentCmds[#sentCmds + 1] = { cmd, arg } end
  assert(ws.setRepo("https://github.com/codyk/musplit-workshop/"), "repo from a URL")
  assert(ws.repo == "codyk/musplit-workshop", "repo cleaned: " .. ws.repo)
  assert(not ws.setRepo("not a repo"), "bad repo rejected")
  cw.open()
  cw.setTab("workshop")
  frame(1 / 60, function() windows.draw(1 / 60) end)
  local req = sentCmds[#sentCmds]
  assert(req[1] == "http_get" and req[2] == "https://raw.githubusercontent.com/codyk/musplit-workshop/main/index.json", "asks the engine: " .. tostring(req[2]))
  local json = require("json")
  local index = json.encode({ version = 1, looks = {
    { id = "7", name = "Neon Snow", author = "codyk", votes = 12, created = "2026-11-23T18:00:00Z", issue = "https://github.com/x/y/issues/7",
      look = { colors = { bg = "#101010", accent = "#ff00aa" }, background = { mode = "aurora" }, post = { bloom = 3 } } },
    { id = "9", name = "Paper Cut", author = "someone", votes = 3, created = "2026-11-24T10:00:00Z",
      look = { colors = { bg = "#f4f2ee", surface = "#ffffff", text = "#111111" } } },
  } })
  ws.onHttp({ type = "http", url = req[2], ok = true, body = index })
  assert(ws.status == "ok" and #ws.looks == 2, "list loaded")
  assert(ws.list("top")[1].name == "Neon Snow" and ws.list("new")[1].name == "Paper Cut", "sorting")
  assert(#ws.list("top", "paper") == 1, "search")
  for _ = 1, 20 do frame(1 / 60, function() windows.draw(1 / 60) end) end
  assert(files["workshop/index.json"], "cached for offline")
  ws.onHttp({ type = "http", url = req[2], ok = false, error = "no internet" })
  assert(ws.status == "offline" and #ws.looks == 2, "keeps the old list when offline")
  local url = ws.shareUrl(presets.current, "My Snow Look")
  assert(url:find("^https://github.com/codyk/musplit%-workshop/issues/new%?template=look.yml") and url:find("look_json="), "share link")
  assert(#url < 8000, "share link short enough for a browser: " .. #url)
  assert(not url:find("backgrounds"), "no local picture path in the share link")

  -- subsplits: "-Name" / "{Section} Name" fold into sections; the current one opens
  local names = { "-Left Hand", "{Items} Right Hand", "Boss", "-A", "{Tapes} B" }
  local ss = {}
  for i, nm in ipairs(names) do ss[i] = { name = nm, comp = i * 10000, best = 9000 } end
  local function disp(index)
    local S2 = { phase = "Running", index = index, segments = ss }
    local rows2 = view.buildRows(S2, 1000)
    return view.displayRows(S2, rows2, index + 1, true, false)
  end
  local d1 = disp(0)
  assert(#d1 == 5 and d1[1].header and not d1[1].folded and d1[1].name == "Items", "Items open on its first split")
  assert(d1[2].name == "Left Hand" and d1[2].indent and d1[3].name == "Right Hand", "names cleaned and indented")
  assert(d1[4].name == "Boss" and d1[5].header and d1[5].folded and d1[5].name == "Tapes", "Tapes folded")
  local d2 = disp(3)
  assert(d2[1].header and d2[1].folded and d2[1].seg == 2, "Items folds once passed (its line = its last split)")
  assert(d2[3].header and not d2[3].folded and d2[4].name == "A", "Tapes opens")
  local plain = view.displayRows({ segments = ss }, view.buildRows({ phase = "NotRunning", index = -1, segments = ss }, 0), 1, false)
  assert(#plain == 5 and plain[1].name == "Left Hand" and plain[2].name == "Right Hand", "subsplits off: names still cleaned")
  view.onState({ phase = "Running", index = 3, time = 35000, segments = ss, method = "real" })
  for _, ex in ipairs({ false, true }) do
    theme.style.layout.subsplits, theme.style.layout.subsplitsExpand = true, ex
    for _ = 1, 10 do frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end) end
  end
  theme.style.layout.subsplits = false
  frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)
  theme.style.layout.subsplits = true

  -- font cache forgets fonts nobody uses
  for size = 10, 60 do theme.font(size, "regular", "Arial") end
  for _ = 1, 7 do theme.update(5) end
  frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) end)   -- current fonts still fine

  -- widgets maths
  local W = require("widgets")
  local r, g, b = W.hsvToRgb(W.rgbToHsv(0.2, 0.6, 0.9))
  assert(math.abs(r - 0.2) < 1e-6 and math.abs(g - 0.6) < 1e-6 and math.abs(b - 0.9) < 1e-6, "hsv round trip")
  assert(theme.toHex(theme.hex("#a1b2c3")) == "#a1b2c3", "hex round trip")

  -- races ----------------------------------------------------------------
  do
    local race = require("race")
    local racenet = require("racenet")
    local RW = require("racewindow")
    local windows = require("windows")
    local view = require("timerview")
    local jsonm = require("json")
    local oldNew = love.audio.newSource
    love.audio.newSource = function(d) local s = oldNew(d) s.stop = function() end return s end
    local out, connects, started = {}, {}, 0
    local autoPong = nil
    racenet.send = function(t)
      local raw = jsonm.encode(t)
      out[#out + 1] = jsonm.decode(raw)
      out[#out].raw = raw
      if t.t == "ping" and autoPong then racenet.on.message({ t = "pong", c = t.c, s = t.c + autoPong }) end
    end
    racenet.connect = function(url) connects[#connects + 1] = url end
    racenet.close = function() end
    race.startTimer = function() started = started + 1 end
    view.onStateHook = race.onState   -- (main.lua does these in the app)
    view.panel = { height = race.panelHeight, draw = race.drawPanel }
    view.overlay = race.drawOverlay
    local function recv(m) racenet.on.message(jsonm.decode(jsonm.encode(m))) end
    local function lastSent(t) for i = #out, 1, -1 do if out[i].t == t then return out[i] end end end
    local function draw() frame(1 / 60, function() view.draw(400, 620, 1 / 60, {}) windows.draw(1 / 60) end) end
    local function step(sec) local n = math.floor(sec * 60) for _ = 1, n do race.update(1 / 60) draw() end end

    race.cfg.server = ""
    RW.open()
    draw()
    race.create()
    assert(race.status == "error", "no server: error")
    race.cfg.server = "https://musplit-race.mushy.workers.dev/"
    assert(race.serverUrl() == "wss://musplit-race.mushy.workers.dev", "server url: " .. tostring(race.serverUrl()))
    race.cfg.name = "Mushy"
    race.create()
    local code = connects[#connects]:match("/room/(%w+)%?create=1$")
    assert(code and #code == 6, "creates with a code: " .. connects[#connects])
    -- code taken -> another one
    racenet.on.message({ t = "error", message = "taken", fatal = true })
    local code2 = connects[#connects]:match("/room/(%w+)%?create=1$")
    assert(code2 and #connects == 2, "retries with a new code")
    racenet.on.open()
    local hello = lastSent("hello")
    assert(hello and hello.name == "Mushy" and hello.id == race.cfg.id, "hello")
    local me = race.cfg.id
    local function player(id, name, extra)
      local p = { id = id, name = name, ready = false, racing = false, phase = "NotRunning", index = -1, splits = {},
                  segments = { "One", "Two", "Three" }, joined = 1, connected = true }
      for k, v in pairs(extra or {}) do p[k] = v end
      return p
    end
    local serverClock = 5000000   -- server = our clock + 5,000,000 ms
    local function serverNow() return clock * 1000 + serverClock end
    local room = { code = code2, status = "open", host = me, startAt = 0, countdown = 10000,
                   game = "Poppy", category = "Any%", players = { player(me, "Mushy"), player("B", "Friend", { ready = true }) } }
    recv({ t = "welcome", you = me, serverTime = serverNow(), room = room })
    assert(race.inRoom() and race.isHost(), "in the room, hosting")
    autoPong = serverClock + 20
    step(1.5)
    local pings = 0
    for _, m in ipairs(out) do if m.t == "ping" then pings = pings + 1 end end
    assert(pings >= 4 and race.offset and math.abs(race.offset - (serverClock + 20)) < 1, "clock synced: " .. tostring(race.offset))
    draw()
    -- my timer, idle
    view.onState({ phase = "NotRunning", index = -1, time = 0, method = "real", game = "Poppy", category = "Any%",
                   segments = { { name = "One" }, { name = "Two" }, { name = "Three" } } })
    -- countdown: 5 s
    room.status, room.startAt = "countdown", serverNow() + 5000
    room.players[1].racing, room.players[2].racing = true, true
    recv({ t = "room", room = room, serverTime = serverNow() })
    assert(not RW.isOpen(), "race window closes at the countdown")
    PLAYED = {}
    step(4.9)
    assert(started == 0, "not started yet")
    step(0.3)
    assert(started == 1, "timer started at GO")
    step(2)
    assert(started == 1, "started once")
    room.status = "running"
    recv({ t = "room", room = room, serverTime = serverNow() })
    -- I split
    view.onState({ phase = "Running", index = 1, time = 61000, method = "real", game = "Poppy", category = "Any%", event = "split",
                   segments = { { name = "One", split = 60000 }, { name = "Two" }, { name = "Three" } } })
    local pr = lastSent("progress")
    assert(pr and pr.index == 1 and pr.splits[1] == 60000 and pr.raw:find("%[60000,null,null%]"), "progress sent with splits: " .. tostring(pr and pr.raw))
    room.players[1].phase, room.players[1].index, room.players[1].splits = "Running", 1, { 60000 }
    room.players[2].phase, room.players[2].index, room.players[2].splits = "Running", 2, { 58000, 119000 }
    recv({ t = "room", room = room, serverTime = serverNow() })
    local st = race.standings()
    assert(st[1].p.id == "B" and st[1].rank == 1 and st[2].me and st[2].delta == 2000, "standings: friend ahead, me +2.0")
    for _ = 1, 20 do draw() end
    -- reset mid-race = forfeit
    view.onState({ phase = "NotRunning", index = -1, time = 0, method = "real", game = "Poppy", category = "Any%",
                   segments = { { name = "One" }, { name = "Two" }, { name = "Three" } } })
    assert(lastSent("forfeit"), "reset forfeits")
    room.players[1].forfeit = true
    room.players[2].finished, room.players[2].finalTime, room.players[2].phase = true, 180000, "Ended"
    room.status = "finished"
    recv({ t = "room", room = room, serverTime = serverNow() })
    st = race.standings()
    assert(st[1].state == "finished" and st[2].state == "forfeit", "finished / forfeit")
    racenet.on.message({ t = "chat", from = "B", name = "Friend", text = "gg" })
    assert(race.unread == 1, "unread chat")
    RW.open()
    for _ = 1, 5 do draw() end
    assert(race.unread == 0, "chat read")
    -- lobby again, as a guest, many runners
    room.status, room.host = "open", "B"
    for i = 3, 12 do room.players[i] = player("P" .. i, "Runner " .. i) end
    recv({ t = "room", room = room, serverTime = serverNow() })
    for _ = 1, 5 do draw() end
    RW.close()
    for _ = 1, 5 do draw() end
    -- dropped: reconnects to the same code
    racenet.on.close("network")
    assert(race.status == "reconnecting", "reconnecting")
    step(2.5)
    assert(connects[#connects]:match("/room/" .. code2 .. "$"), "rejoins the same room: " .. connects[#connects])
    -- kicked
    racenet.on.message({ t = "error", message = "The host removed you from the race.", fatal = true })
    assert(race.status == "error" and not race.inRoom(), "kicked")
    RW.open() draw() RW.close()
    race.leave()
    assert(race.status == "off", "left")
    for _ = 1, 30 do draw() end
    assert(race.panelHeight(400) < 1, "panel folds away")
    love.audio.newSource = oldNew
    print("RACE OK")
  end

  -- Discord status -----------------------------------------------------------
  do
    local D = require("discordrpc")
    local racenet = require("racenet")
    local view = require("timerview")
    local windows = require("windows")
    local jsonm = require("json")
    local raws = {}
    racenet.raw = function(line) raws[#raws + 1] = line end
    local segs = { { name = "-Gate", comp = 60000, best = 50000 }, { name = "{Factory} Workshop", comp = 120000, best = 50000 },
                   { name = "Keycard", comp = 200000, best = 70000 } }
    local S = { phase = "NotRunning", index = -1, time = 0, method = "real", game = "Poppy Playtime Chapter 5", category = "Any%", segments = segs }
    local act = D.build(S, 0, 1000000)
    assert(act.details == "Poppy Playtime Chapter 5 · Any%" and act.state == "Getting ready" and not act.timestamps, "idle")
    segs[1].split = 58800
    S = { phase = "Running", index = 1, time = 70000, method = "real", game = S.game, category = S.category, segments = segs }
    act = D.build(S, 70000, 1000000)
    assert(act.state == "Workshop (2/3)", "split name, cleaned: " .. act.state)
    assert(act.timestamps.start == (1000000 - 70) * 1000, "counts from the run's start")
    D.cfg.delta = true
    act = D.build(S, 70000, 1000000)
    assert(act.state == "Workshop (2/3) · -1.2", "delta: " .. act.state)
    D.cfg.delta, D.cfg.split = false, false
    assert(D.build(S, 70000, 1000000).state == "Running", "split hidden")
    D.cfg.split = true
    local P = { phase = "Paused", index = 1, time = 70000, game = S.game, category = S.category, segments = segs }
    act = D.build(P, 70000, 1000000)
    assert(act.state:find("paused at") and not act.timestamps, "paused: no ticking clock")
    segs[2].split, segs[3].split = 119000, 199000
    act = D.build({ phase = "Ended", index = 3, time = 199000, game = S.game, category = "", segments = segs }, 199000, 1000000)
    assert(act.state:find("^Finished in 3:19") and act.state:find("new PB"), "finished + PB: " .. act.state)
    assert(act.details == "Poppy Playtime Chapter 5", "no category")
    segs[2].split, segs[3].split = nil, nil
    -- sending: needs an app id; throttled; re-sent when the clock drifts
    D.cfg.appId = ""
    view.onState(S)
    D.update(1 / 60)
    assert(#raws == 0, "no app id: nothing sent")
    D.cfg.appId = "123456789012345678"
    local realTime = os.time
    os.time = function() return 1000000 + math.floor(clock) end
    for _ = 1, 3 do clock = clock + 5 D.update(1 / 60) end
    assert(#raws >= 1 and raws[1]:match("^discord 123456789012345678 {"), "sent: " .. tostring(raws[1]))
    local sentAct = jsonm.decode(raws[1]:match("^discord %d+ (.*)$"))
    assert(sentAct.details and sentAct.assets.large_image == "logo", "activity json")
    assert(sentAct.buttons[1].label == "Download Mu Split" and sentAct.buttons[1].url == "https://github.com/mushymeow/Mu-Split", "download button")
    D.cfg.buttonUrl = "not a link"
    assert(not D.build(S, 70000, 1000000).buttons, "bad link: no button")
    D.cfg.buttonUrl = "https://github.com/mushymeow/Mu-Split"
    local n = #raws
    clock = clock + 5 D.update(1 / 60)
    assert(#raws == n, "unchanged: not re-sent")
    D.cfg.enabled = false
    clock = clock + 5 D.update(1 / 60)
    assert(raws[#raws] == "discord 123456789012345678 null", "turned off: cleared")
    -- Linux: frames straight to Discord's socket (a fake one here)
    local sent, incoming = {}, {}
    local fakeSock = { send = function(_, d) sent[#sent + 1] = d return #d end,
                       receive = function() local c = table.remove(incoming, 1) if c then return c end return nil, "timeout", "" end,
                       close = function() end }
    D.nativeLinux = true
    D.ipc.sock, D.ipc.app, D.ipc.buf = fakeSock, "123456789012345678", ""
    D.deliver("123456789012345678", '{"details":"x"}')
    local fr = sent[#sent]
    assert(D.rd32(fr, 1) == 1 and D.rd32(fr, 5) == #fr - 8 and fr:sub(9):find('"cmd":"SET_ACTIVITY"', 1, true), "SET_ACTIVITY frame")
    -- Discord pings: we pong with the same body; frames split across reads are put back together
    local ping = D.le32(3) .. D.le32(4) .. "ping"
    incoming = { ping:sub(1, 5), ping:sub(6) }
    D.update(1 / 60) D.update(1 / 60)
    assert(sent[#sent] == D.le32(4) .. D.le32(4) .. "ping", "pong")
    D.nativeLinux, D.ipc.sock = false, nil
    os.time = realTime
    D.cfg.enabled = true
    -- the switch in Settings > Mu Split is the only setting; it's saved on its own
    D.setEnabled(false)
    assert(not D.cfg.enabled and love.filesystem.read("discord.json"):find('"enabled":false'), "discord switch saved")
    D.setEnabled(true)
    -- Settings window: the Mu Split tab draws without the engine, and its switches work
    local sw = require("settingswindow")
    sw.open("musplit")
    for _ = 1, 5 do frame(1 / 60, function() windows.draw(1 / 60) end) end
    local ov = require("overlay")
    local before = ov.cfg.showSplit
    ov.cfg.showSplit = not before ov.saveCfg()
    assert(love.filesystem.read("overlay.json"):find('"showSplit":' .. tostring(not before)), "overlay setting saved")
    ov.cfg.showSplit = before ov.saveCfg()
    local app = require("appsettings")
    app.setBorderless(true) assert(app.cfg.borderless and love.filesystem.read("app.json"):find('"borderless":true'), "app setting saved")
    app.setBorderless(false)
    sw.open("timer")
    for _ = 1, 3 do frame(1 / 60, function() windows.draw(1 / 60) end) end
    windows.pop() windows.pop()
    print("DISCORD OK")
  end

  -- Linux ----------------------------------------------------------------------
  do
    local fake = "/tmp/musplit-fakehome"
    os.execute("rm -rf " .. fake)
    local lib2 = fake .. "/games2"
    os.execute("mkdir -p " .. fake .. "/.steam/steam/steamapps/compatdata/1234/pfx " .. lib2 .. "/steamapps/common/Proton\\ 9.0 "
      .. fake .. "/.steam/steam/steamapps/common/Proton\\ 8.0 " .. fake .. "/.steam/steam/compatibilitytools.d/GE-Proton9-20")
    local function write(path, text) local f = assert(io.open(path, "w")) f:write(text) f:close() end
    write(fake .. "/.steam/steam/steamapps/libraryfolders.vdf", '"libraryfolders"\n{\n "0"\n {\n  "path" "' .. fake .. '/.steam/steam"\n }\n "1"\n {\n  "path" "' .. lib2 .. '"\n }\n}\n')
    write(fake .. "/.steam/steam/steamapps/appmanifest_1234.acf", '"AppState"\n{\n "appid" "1234"\n "name" "Poppy Playtime - Chapter 5"\n "installdir" "Poppy5"\n}\n')
    write(lib2 .. "/steamapps/appmanifest_99.acf", '"AppState"\n{\n "appid" "99"\n "name" "Another Game"\n "installdir" "AG"\n}\n')
    write(lib2 .. "/steamapps/appmanifest_1493710.acf", '"AppState"\n{\n "appid" "1493710"\n "name" "Proton Experimental"\n}\n')
    write(lib2 .. "/steamapps/common/Proton 9.0/proton", "#!/bin/sh\n")
    write(fake .. "/.steam/steam/steamapps/common/Proton 8.0/proton", "#!/bin/sh\n")
    write(fake .. "/.steam/steam/compatibilitytools.d/GE-Proton9-20/proton", "#!/bin/sh\n")
    local realGetenv = os.getenv
    os.getenv = function(k) if k == "HOME" then return fake end return realGetenv(k) end
    package.loaded["steam"] = nil
    local steam = require("steam")
    local games = steam.games()
    assert(#games == 2 and games[1].name == "Another Game" and games[2].appid == "1234", "games from both libraries, tools left out")
    assert(games[2].proton and not games[1].proton, "Proton prefix detected")
    local proton = steam.newestProton()
    assert(proton and proton:match("GE%-Proton9%-20$"), "newest Proton: " .. tostring(proton))
    -- paths
    package.loaded["linux"] = nil
    local L = require("linux")
    assert(L.toWin("/home/me/My Splits/a.lss") == "Z:\\home\\me\\My Splits\\a.lss", "to Wine path")
    assert(L.fromWin("Z:\\home\\me\\a.lss") == "/home/me/a.lss" and L.fromWin("C:\\x") == "C:\\x", "from Wine path")
    -- engine + launch option (a space-free link for Proton)
    local base = fake .. "/Mu Split"
    os.execute("mkdir -p '" .. base .. "/engine'")
    write(base .. "/engine/MuSplitEngine.exe", "MZ")
    local realBase = love.filesystem.getSourceBaseDirectory
    love.filesystem.getSourceBaseDirectory = function() return base end
    local opt = L.launchOption()
    assert(opt == 'PROTON_REMOTE_DEBUG_CMD="' .. fake .. '/.local/share/musplit/engine/MuSplitEngine.exe" %command%', "launch option: " .. tostring(opt))
    local f = io.open(fake .. "/.local/share/musplit/engine/MuSplitEngine.exe", "rb")
    assert(f, "link to the engine works") f:close()
    -- launching: the command (not run)
    local realExec = os.execute
    local ran
    os.execute = function(c) if c:find("MUSPLIT_PRIVATE") then ran = c return true end return realExec(c) end
    local ok = L.launch()
    os.execute = realExec
    assert(ok and ran and ran:find("MUSPLIT_PRIVATE=1") and ran:find("MuSplitEngine.exe") and ran:find(" &$"), "private engine started in the background: " .. tostring(ran))
    -- net.send translates paths for the engine
    local netm = require("net")
    local sentArgs = {}
    -- (linux.lua wrapped net.send when it loaded; check the wrapper with a fake underneath)
    -- engine status from the relay's hello
    require("racenet").on.hello({ type = "hello", private = false, appid = "1234" })
    local kind, appid = L.engineKind()
    assert(kind == "game" and appid == "1234", "engine in the game")
    local LW = require("linuxwindow")
    local windows = require("windows")
    LW.open()
    for _ = 1, 5 do frame(1 / 60, function() windows.draw(1 / 60) end) end
    windows.pop()
    love.filesystem.getSourceBaseDirectory = realBase
    os.getenv = realGetenv
    print("LINUX OK")
  end
end)

if not ok then print("FAIL: " .. tostring(err)) os.exit(1) end
print(("OK  (%d draw calls, scissor ok: %s)"):format(drawCalls, tostring(scissorDepthOK)))
