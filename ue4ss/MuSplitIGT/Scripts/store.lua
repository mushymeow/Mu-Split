-- Saves settings and personal bests as small Lua files next to the mod.

local S = {}

-- the mod's own folder (…\Mods\MuSplitIGT\), from where this script lives
local function modDir()
  local ok, info = pcall(debug.getinfo, 1, "S")
  local src = ok and info and info.source or ""
  src = src:gsub("^@", "")
  local dir = src:match("^(.*)[/\\][Ss]cripts[/\\][^/\\]+$")
  return dir or "."
end
-- UE4SS's working directory is its own folder, so fall back to the usual mod paths
local function exists(path)
  local f = io.open(path, "r")
  if f then f:close() return true end
  return false
end
do
  local candidates = { modDir(), "Mods/MuSplitIGT", "ue4ss/Mods/MuSplitIGT", "." }
  S.dir = "."
  for _, d in ipairs(candidates) do
    if d and exists(d .. "/Scripts/main.lua") then S.dir = d break end
  end
end

local function serialize(v, indent)
  indent = indent or ""
  local t = type(v)
  if t == "number" then
    if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
    return string.format("%.17g", v)
  elseif t == "boolean" then return tostring(v)
  elseif t == "string" then return string.format("%q", v)
  elseif t == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      if type(a) == type(b) then return tostring(a) < tostring(b) end
      return type(a) == "number"
    end)
    local inner = indent .. "  "
    local out = { "{" }
    for _, k in ipairs(keys) do
      local key = type(k) == "string" and k:match("^[%a_][%w_]*$") and k or ("[" .. serialize(k) .. "]")
      out[#out + 1] = inner .. key .. " = " .. serialize(v[k], inner) .. ","
    end
    out[#out + 1] = indent .. "}"
    return table.concat(out, "\n")
  end
  return "nil"
end

function S.save(name, data)
  local path = S.dir .. "/" .. name
  local f = io.open(path .. ".tmp", "w")
  if not f then return false end
  f:write("-- Mu Split IGT: written automatically\nreturn ", serialize(data), "\n")
  f:close()
  os.remove(path)
  os.rename(path .. ".tmp", path)
  return true
end

function S.load(name)
  local path = S.dir .. "/" .. name
  local f = io.open(path, "r")
  if not f then return nil end
  local src = f:read("*a")
  f:close()
  local chunk = load(src, "=" .. name, "t", {})   -- data only, no access to anything
  if not chunk then return nil end
  local ok, data = pcall(chunk)
  return ok and type(data) == "table" and data or nil
end

-- fill missing keys from defaults (so new settings appear after updates)
function S.merge(data, defaults)
  data = type(data) == "table" and data or {}
  for k, v in pairs(defaults) do
    if data[k] == nil then
      if type(v) == "table" then
        local c = {}
        for kk, vv in pairs(v) do c[kk] = vv end
        data[k] = c
      else
        data[k] = v
      end
    end
  end
  return data
end

return S
