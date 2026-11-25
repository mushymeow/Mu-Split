-- Reads your Steam library on Linux: which games are installed, which run through Proton,
-- and which Proton versions you have. Only reads Steam's files; never changes them.

local S = {}

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
S.q = q

local function lines(cmd)
  local p = io.popen(cmd .. " 2>/dev/null")
  if not p then return {} end
  local out = {}
  for l in p:lines() do out[#out + 1] = l end
  p:close()
  return out
end
local function exists(path) local f = io.open(path, "rb") if f then f:close() return true end return false end
local function isDir(path) return #lines("test -d " .. q(path) .. " && echo y") > 0 end
local function readAll(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end
S.exists, S.isDir = exists, isDir

-- Valve's text format: "key"  "value", nested in { }. Flat key/value pairs are enough here.
function S.vdfPairs(text)
  local out = {}
  for k, v in (text or ""):gmatch('"([^"]+)"%s+"([^"]*)"') do out[#out + 1] = { k = k, v = v:gsub("\\\\", "\\") } end
  return out
end

-- Steam's own folder (native or Flatpak)
function S.root()
  local home = os.getenv("HOME") or ""
  for _, r in ipairs({ home .. "/.steam/steam", home .. "/.local/share/Steam", home .. "/.steam/root",
                       home .. "/.var/app/com.valvesoftware.Steam/.local/share/Steam" }) do
    if isDir(r .. "/steamapps") then return r end
  end
end

-- every library folder (games can be on other drives)
function S.libraries(root)
  root = root or S.root()
  if not root then return {} end
  local libs, seen = {}, {}
  local function add(p)
    p = p:gsub("/+$", "")
    if not seen[p] and isDir(p .. "/steamapps") then seen[p] = true libs[#libs + 1] = p end
  end
  add(root)
  for _, kv in ipairs(S.vdfPairs(readAll(root .. "/steamapps/libraryfolders.vdf"))) do
    if kv.k == "path" then add(kv.v) end
  end
  return libs
end

local NOT_GAMES = { "^Proton", "^Steam Linux Runtime", "^Steamworks Common", "^SteamVR", "^Steam Audio" }

-- installed games: { appid, name, installdir, library, proton = has a Proton prefix }
function S.games()
  local root = S.root()
  local games = {}
  for _, lib in ipairs(S.libraries(root)) do
    for _, f in ipairs(lines("ls -1 " .. q(lib .. "/steamapps"))) do
      local t = {}
      if f:match("^appmanifest_%d+%.acf$") then
        for _, kv in ipairs(S.vdfPairs(readAll(lib .. "/steamapps/" .. f))) do
          if t[kv.k] == nil then t[kv.k] = kv.v end
        end
      end
      local skip = not t.appid or not t.name
      for _, pat in ipairs(NOT_GAMES) do if t.name and t.name:match(pat) then skip = true end end
      if not skip then
        games[#games + 1] = { appid = t.appid, name = t.name, installdir = t.installdir, library = lib,
                              proton = isDir(lib .. "/steamapps/compatdata/" .. t.appid .. "/pfx") }
      end
    end
  end
  table.sort(games, function(a, b) return a.name:lower() < b.name:lower() end)
  return games
end

-- the newest Proton (official or custom, like GE-Proton): its folder, or nil
function S.newestProton()
  local root = S.root()
  if not root then return nil end
  local found = {}
  for _, lib in ipairs(S.libraries(root)) do
    for _, d in ipairs(lines("ls -1d " .. q(lib .. "/steamapps/common") .. "/Proton*")) do
      if exists(d .. "/proton") then found[#found + 1] = d end
    end
  end
  for _, d in ipairs(lines("ls -1d " .. q(root .. "/compatibilitytools.d") .. "/*")) do
    if exists(d .. "/proton") then found[#found + 1] = d end
  end
  -- "Proton 9.0", "Proton Experimental", "GE-Proton9-20": prefer numbered ones, highest first
  local function ver(d)
    local name = d:match("[^/]+$")
    local a, b = name:match("(%d+)[%.%-](%d+)")
    return (tonumber(a) or tonumber(name:match("(%d+)")) or 0) * 1000 + (tonumber(b) or 0)
  end
  table.sort(found, function(x, y) return ver(x) > ver(y) end)
  return found[1], root
end

return S
