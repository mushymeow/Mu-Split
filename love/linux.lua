-- Linux support. The Mu Split window runs natively; only the engine runs under Wine/Proton.
--
--  * Mu Split starts a "private" engine in its own Wine prefix, so the timer works anywhere
--    (umu-run, wine, or Steam's Proton, whichever you have).
--  * For autosplitters the engine has to be inside the game's Proton prefix (that's the only
--    place it can see the game). The Linux Autosplitters window gives you a Steam launch
--    option for that; when the game starts, its engine takes over from the private one
--    (engine/EngineLinux.cs), and Mu Split just reconnects.
--
-- Also: file paths are translated between Linux (/home/...) and Wine (Z:\home\...).

local S = require("steam")
local L = { info = nil, isLinux = love.system.getOS() == "Linux" }
local q = S.q

function L.toWin(p) if p:sub(1, 1) == "/" then return "Z:" .. p:gsub("/", "\\") end return p end
function L.fromWin(p)
  local rest = p:match("^[Zz]:[\\/](.*)$")
  if rest then return "/" .. rest:gsub("\\", "/") end
  return p
end

local function sh(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return "" end
  local o = p:read("*a") or ""
  p:close()
  return o
end
local function which(name) local o = sh("command -v " .. name):gsub("%s+$", "") return o ~= "" and o or nil end

local HOME = os.getenv("HOME") or "/tmp"
L.dataDir = HOME .. "/.local/share/musplit"

function L.engineExe()
  local base = love.filesystem.getSourceBaseDirectory()
  for _, p in ipairs({ base .. "/engine/MuSplitEngine.exe", base .. "/vendor/engine/MuSplitEngine.exe" }) do
    if S.exists(p) then return p end
  end
end

-- a space-free path to the engine for Steam's launch option (Proton splits that command on spaces)
function L.engineLink()
  local exe = L.engineExe()
  if not exe then return nil end
  local dir = exe:match("^(.*)/[^/]+$")
  local link = L.dataDir .. "/engine"
  os.execute("mkdir -p " .. q(L.dataDir) .. " && ln -sfn " .. q(dir) .. " " .. q(link))
  return link .. "/MuSplitEngine.exe"
end

function L.launchOption()
  local p = L.engineLink()
  if not p then return nil end
  return 'PROTON_REMOTE_DEBUG_CMD="' .. p .. '" %command%'
end

---------------------------------------------------------------------------
-- starting the private engine
---------------------------------------------------------------------------
L.lastLaunch = -100
L.method = nil

function L.launch()
  local exe = L.engineExe()
  if not exe then return false, "The Mu Split engine wasn't found next to Mu Split (engine/MuSplitEngine.exe)." end
  local dir = exe:match("^(.*)/[^/]+$")
  local prefix = L.dataDir .. "/wine"
  os.execute("mkdir -p " .. q(prefix))
  local env = "MUSPLIT_PRIVATE=1 MUSPLIT_HIDDEN=1 WINEDEBUG=-all "
  local cmd
  if which("umu-run") then
    L.method = "umu-run"
    cmd = env .. "WINEPREFIX=" .. q(prefix .. "/pfx") .. " GAMEID=umu-default umu-run " .. q(exe)
  elseif which("wine") then
    L.method = "wine"
    cmd = env .. "WINEPREFIX=" .. q(prefix .. "/pfx") .. " wine " .. q(exe)
  else
    local proton, root = S.newestProton()
    if not proton then return false, "To run the engine, install Wine, or Steam with Proton." end
    L.method = proton:match("[^/]+$")
    cmd = env .. "STEAM_COMPAT_DATA_PATH=" .. q(prefix) .. " STEAM_COMPAT_CLIENT_INSTALL_PATH=" .. q(root)
      .. " " .. q(proton .. "/proton") .. " run " .. q(exe)
  end
  L.lastLaunch = love.timer.getTime()
  os.execute("cd " .. q(dir) .. " && (" .. cmd .. ") > " .. q(L.dataDir .. "/engine-wine.log") .. " 2>&1 &")
  return true
end

function L.engineRunning() return sh("pgrep -f MuSplitEngine.exe"):match("%d") ~= nil end

---------------------------------------------------------------------------
-- every frame
---------------------------------------------------------------------------
local racenet = require("racenet")
local net = require("net")
local lastPing, disconnectedSince = -100, nil

-- the engine says who it is when we connect: private, or inside a game (appid)
racenet.on.hello = function(m) L.info = m end

if L.isLinux then
  -- file paths for the engine are Windows paths (Wine's Z: drive is /)
  local send = net.send
  net.send = function(cmd, arg)
    if (cmd == "open" or cmd == "save") and type(arg) == "string" and arg:sub(1, 1) == "/" then arg = L.toWin(arg) end
    return send(cmd, arg)
  end
end

function L.update(dt)
  if not L.isLinux then return end
  local now = love.timer.getTime()
  -- keep talking to the engine (the private one quits 30 s after we stop: we closed)
  if now - lastPing > 5 then lastPing = now racenet.raw("ping") end
  -- no engine (the game closed and took its engine with it): start the private one again
  if net.connected then disconnectedSince = nil
  else
    disconnectedSince = disconnectedSince or now
    if now - disconnectedSince > 6 and now - L.lastLaunch > 20 and not L.engineRunning() then L.launch() end
  end
end

-- for the status line: "private" | "game" | nil
function L.engineKind()
  if not L.info then return nil end
  if L.info.private then return "private" end
  return "game", L.info.appid
end

return L
