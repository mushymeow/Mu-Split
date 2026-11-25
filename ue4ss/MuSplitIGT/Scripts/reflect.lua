-- Follows the LiveSplit autosplitter's pointer chains, but through Unreal's
-- reflection instead of raw memory reads.
--
-- The ASL says e.g. "GEngine +0xA58 +0x78 +0x830 +0x158 +0x34". Here, each offset is
-- matched to the property that lives at that offset in the object's class (worked
-- out once per class, at runtime), and followed by name. Same data, same game
-- version, but read the safe way from inside the game.

local R = {}

local layouts = {}   -- class full name -> { [offset] = { name = string, prop = Property } }

local function addressOf(lightuserdata)
  -- ContainerPtrToValuePtr gives a light userdata; its tostring holds the address
  local hex = tostring(lightuserdata):match("0x(%x+)") or tostring(lightuserdata):match("(%x+)$")
  return hex and tonumber(hex, 16) or nil
end

local function valid(obj)
  if obj == nil or type(obj) ~= "userdata" then return false end
  local ok, r = pcall(function() return obj:IsValid() end)
  return ok and r == true
end
R.valid = valid

-- offset -> property for this object's class (including parent classes)
function R.layout(obj)
  local cls = obj:GetClass()
  local key = cls:GetFullName()
  local map = layouts[key]
  if map then return map end
  map = {}
  local base = obj:GetAddress()
  local s = cls
  while s and s:IsValid() do
    s:ForEachProperty(function(p)
      local ok, ptr = pcall(function() return p:ContainerPtrToValuePtr(obj, 0) end)
      local a = ok and addressOf(ptr)
      if a then
        local off = a - base
        if map[off] == nil then
          map[off] = { name = p:GetFName():ToString(), prop = p }
        end
      end
    end)
    s = s:GetSuperStruct()
  end
  layouts[key] = map
  return map
end

-- name of the property at an offset (for logging / debugging)
function R.nameAt(obj, offset)
  local e = R.layout(obj)[offset]
  return e and e.name
end

local function isA(prop, typeName)
  local ok, r = pcall(function() return prop:IsA(PropertyTypes[typeName]) end)
  return ok and r
end
R.isA = isA

-- Follow offsets like an ASL MemoryWatcher. Every step but the last must be an
-- object pointer (or an array of them); the last one is the value we want.
-- Returns value, or nil + a reason.
function R.follow(obj, offsets)
  local cur = obj
  local i = 1
  while i <= #offsets do
    if not valid(cur) then return nil, "broken at step " .. i end
    local off = offsets[i]
    local e = R.layout(cur)[off]
    if not e then return nil, string.format("no property at 0x%X in %s", off, cur:GetClass():GetFName():ToString()) end
    local v = cur[e.name]
    if i == #offsets then return v, e.name end

    if isA(e.prop, "ArrayProperty") then
      -- the next offset indexes into the array's data (8-byte object pointers)
      i = i + 1
      local idx = math.floor(offsets[i] / 8) + 1
      if i == #offsets then
        local ok, el = pcall(function() return v[idx] end)
        return ok and el or nil, e.name .. "[" .. idx .. "]"
      end
      local ok, el = pcall(function() return v[idx] end)
      cur = ok and el or nil
    else
      cur = v
    end
    i = i + 1
  end
  return cur
end

-- Like follow(), but returns the chain as property names (resolved once, then reused by name:
-- faster per frame, and it shows up readably in the log).
function R.resolve(obj, offsets)
  local names = {}
  local cur = obj
  local i = 1
  while i <= #offsets do
    if not valid(cur) then return nil, "broken at step " .. i end
    local e = R.layout(cur)[offsets[i]]
    if not e then return nil, string.format("no property at 0x%X in %s", offsets[i], cur:GetClass():GetFName():ToString()) end
    if isA(e.prop, "ArrayProperty") and i < #offsets then
      local idx = math.floor(offsets[i + 1] / 8) + 1
      names[#names + 1] = { e.name, idx }
      local ok, el = pcall(function() return cur[e.name][idx] end)
      cur = ok and el or nil
      i = i + 2
    else
      names[#names + 1] = e.name
      if i < #offsets then cur = cur[e.name] end
      i = i + 1
    end
  end
  return names
end

-- read along a resolved chain of names
function R.read(obj, names)
  local cur = obj
  for _, step in ipairs(names) do
    if not valid(cur) then return nil end
    if type(step) == "table" then
      local ok, el = pcall(function() return cur[step[1]][step[2]] end)
      if not ok then return nil end
      cur = el
    else
      local ok, v = pcall(function() return cur[step] end)
      if not ok then return nil end
      cur = v
    end
  end
  return cur
end

function R.chainText(names)
  if not names then return "?" end
  local parts = {}
  for _, s in ipairs(names) do parts[#parts + 1] = type(s) == "table" and (s[1] .. "[" .. s[2] .. "]") or s end
  return table.concat(parts, ".")
end

-- FName / FString / FText -> Lua string
function R.str(v)
  if v == nil then return nil end
  if type(v) == "string" then return v end
  local ok, s = pcall(function() return v:ToString() end)
  if ok and type(s) == "string" then return s end
  return nil
end

-- object's own name, e.g. "BP_PPPlayerController_C_0"
function R.objName(obj)
  if not valid(obj) then return "" end
  local ok, s = pcall(function() return obj:GetFName():ToString() end)
  return ok and s or ""
end

-- property type, e.g. "NameProperty", "StructProperty", "ArrayProperty"
function R.typeOf(prop)
  local ok, n = pcall(function() return prop:GetClass():GetFName():ToString() end)
  return ok and n or "?"
end

-- Like layout()[offset], but also looks inside structs: returns a list of names to
-- follow (e.g. { "Inventory", "Items" }) for a value nested in a struct property.
function R.pathAt(obj, offset)
  local map = R.layout(obj)
  if map[offset] then return { map[offset].name }, map[offset].prop end
  local base = obj:GetAddress()
  -- find the struct property that covers this offset
  local bestOff, best = -1, nil
  for off, e in pairs(map) do
    if off < offset and off > bestOff and R.typeOf(e.prop) == "StructProperty" then bestOff, best = off, e end
  end
  if not best then return nil end
  local found, foundProp
  pcall(function()
    best.prop:GetStruct():ForEachProperty(function(p)
      -- ContainerPtrToValuePtr only adds the property's offset, so pass the object
      -- and subtract: this gives the field's offset inside the struct
      local ptr = p:ContainerPtrToValuePtr(obj, 0)
      local a = addressOf(ptr)
      if a and bestOff + (a - base) == offset then found, foundProp = p:GetFName():ToString(), p return true end
    end)
  end)
  if found then return { best.name, found }, foundProp end
  return nil
end

-- read obj.a.b.c for a list of names
function R.get(obj, names)
  local cur = obj
  for _, n in ipairs(names) do
    local ok, v = pcall(function() return cur[n] end)
    if not ok then return nil end
    cur = v
  end
  return cur
end

-- one line per property: offset, name, type (for working out a class's layout)
function R.describe(obj, max)
  local rows = {}
  for off, e in pairs(R.layout(obj)) do rows[#rows + 1] = { off, e.name, R.typeOf(e.prop) } end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  local out = {}
  for i, r in ipairs(rows) do
    if max and i > max then out[#out + 1] = "…" break end
    out[#out + 1] = string.format("0x%X %s (%s)", r[1], r[2], r[3])
  end
  return table.concat(out, ", ")
end

function R.clearCache() layouts = {} end

return R
