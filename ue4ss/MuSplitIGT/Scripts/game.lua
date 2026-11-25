-- Everything specific to Poppy Playtime: Chapter 4, by name.
--
-- These are the same values the LiveSplit autosplitter (TheDementedSalad & Lox) reads
-- by memory offset, found in this game build through UE4SS:
--   checkpoint   CheckpointSubsystem.CurrentCheckpointId  (GameplayTag, ASL: World→subsystem +0x34)
--   inventory    Player.InventoryManagerComponent.InventoryList.Items[i].Instance
--                (ASL: pawn +0xAF8 → +0x1B0, item +0x78 id, +0x68 used)
--   pause        GEngine.TransitionType                    (ASL: GEngine +0xB93)
--   player       BP_PPPlayerController_C / BP_PPPlayerCharacter_C
--
-- Rule for UE4SS 3.0.1: never "try" a call on the wrong type. Every failed call prints
-- an error and can leave things unstable, so types are checked before reading.

local R = require("reflect")

local G = {}

local function log(fmt, ...) print("[MuSplitIGT] " .. string.format(fmt, ...) .. "\n") end
G.log = log

local logged = {}
local function logOnce(key, fmt, ...)
  if logged[key] then return end
  logged[key] = true
  log(fmt, ...)
end
G.logOnce = logOnce

local function startsWith(s, p) return type(s) == "string" and s:sub(1, #p) == p end
G.startsWith = startsWith

---------------------------------------------------------------------------
-- engine objects
---------------------------------------------------------------------------
local cache = { engine = nil, gs = nil, checkpoint = nil, cpTry = -1e9 }

function G.engine()
  if not R.valid(cache.engine) then cache.engine = FindFirstOf("GameEngine") end
  return R.valid(cache.engine) and cache.engine or nil
end

function G.statics()
  if not R.valid(cache.gs) then cache.gs = StaticFindObject("/Script/Engine.Default__GameplayStatics") end
  return R.valid(cache.gs) and cache.gs or nil
end

function G.playerController(engine)
  local gi = engine.GameInstance
  if not R.valid(gi) then return nil end
  local players = gi.LocalPlayers
  if not players or #players < 1 then return nil end
  local lp = players[1]
  if not R.valid(lp) then return nil end
  local pc = lp.PlayerController
  return R.valid(pc) and pc or nil
end

function G.inGame(pc) return startsWith(R.objName(pc), "BP_PPPlayerController_C") end
function G.isPlayer(pawn) return startsWith(R.objName(pawn), "BP_PPPlayerCharacter_C") end

-- GEngine.TransitionType == 1 means the game is paused (the ASL's pause removal)
local transitionName = nil
function G.pauseTransition(engine)
  if transitionName == nil then
    transitionName = R.nameAt(engine, 0xB93) or false
    log("pause flag: %s", transitionName and ("GEngine." .. transitionName) or "not found")
  end
  if not transitionName then return false end
  return engine[transitionName] == 1
end

---------------------------------------------------------------------------
-- checkpoint
---------------------------------------------------------------------------
-- There can be one CheckpointSubsystem per world (the main menu's can still be around
-- after the level loads), so take the one whose outer is the current world.
local function addr(o)
  local ok, a = pcall(function() return o:GetAddress() end)
  return ok and a or nil
end

local function checkpointSubsystem(now, world)
  local want = world and addr(world) or nil
  if R.valid(cache.checkpoint) and (want == nil or cache.cpWorld == want) then return cache.checkpoint end
  cache.checkpoint = nil
  if now - cache.cpTry < 1 then return nil end
  cache.cpTry = now
  local all = FindAllOf and FindAllOf("CheckpointSubsystem") or nil
  if not all then
    local one = FindFirstOf("CheckpointSubsystem")
    all = one and { one } or {}
  end
  local pick, n = nil, 0
  for _, s in ipairs(all) do
    if R.valid(s) and not startsWith(R.objName(s), "Default__") then
      n = n + 1
      local outer = nil
      pcall(function() outer = s:GetOuter() end)
      if want and outer and addr(outer) == want then pick = s break end
      pick = pick or s
    end
  end
  if pick then
    cache.checkpoint, cache.cpWorld = pick, want
    log("checkpoint subsystem: %s (%d found)", pick:GetFullName(), n)
  end
  return cache.checkpoint
end

-- raw checkpoint tag text, e.g. "Checkpoint.ToyGraveyard.1" (nil if unknown)
local lastRaw = false
function G.checkpoint(now, world)
  local s = checkpointSubsystem(now, world)
  if not s then return nil end
  local tag = s.CurrentCheckpointId          -- FGameplayTag struct
  if tag == nil then return nil end
  local name = tag.TagName                   -- FName
  if name == nil then return nil end
  local text = name:ToString()
  if text ~= lastRaw then
    log("checkpoint is now: %s", tostring(text))
    lastRaw = text
  end
  if type(text) ~= "string" or text == "" or text == "None" then return nil end
  return text
end

-- call on a level change: the old world's subsystem is on its way out
function G.forget()
  cache.checkpoint = nil
  cache.cpTry = -1e9
  lastRaw = false
end

---------------------------------------------------------------------------
-- inventory
---------------------------------------------------------------------------
local inv = nil   -- { idPath = {...}, idType = "NameProperty"/"StructProperty", usedName = "bUsed", instanceClass = "" }

-- read a resolved id field (FName or GameplayTag) as text
local function idText(obj, path, ty)
  local v = R.get(obj, path)
  if v == nil then return nil end
  if ty == "StructProperty" then
    local n = v.TagName
    if n == nil then return nil end
    return n:ToString()
  elseif ty == "NameProperty" or ty == "StrProperty" or ty == "TextProperty" then
    return v:ToString()
  end
  return nil
end

local function resolveItemFields(instance)
  local cls = instance:GetClass():GetFullName()
  if inv and inv.instanceClass == cls then return inv end
  local idPath, idProp = R.pathAt(instance, 0x78)
  local usedPath = R.pathAt(instance, 0x68)
  local idType = idProp and R.typeOf(idProp) or nil
  if idType ~= "NameProperty" and idType ~= "StructProperty" and idType ~= "StrProperty" then idPath = nil end
  inv = { instanceClass = cls, idPath = idPath, idType = idType, usedPath = usedPath }
  if idPath then
    log("item id: Instance.%s (%s), used: %s", table.concat(idPath, "."), idType,
      usedPath and table.concat(usedPath, ".") or "?")
  else
    -- show the layout once so the id field can be found by hand
    log("item id field not found at +0x78 (type %s). Item layout: %s", tostring(idType), R.describe(instance, 60))
  end
  return inv
end

-- list of { id = "RedHand", used = 0/1 }, and the item count; nil if unavailable
function G.items(pawn)
  local comp = pawn.InventoryManagerComponent
  if not R.valid(comp) then return nil end
  local list = comp.InventoryList
  if list == nil then return nil end
  local arr = list.Items
  if arr == nil then return nil end
  local n = #arr
  local out = {}
  for i = 1, n do
    local entry = arr[i]
    local instance = entry and entry.Instance
    if R.valid(instance) then
      local f = resolveItemFields(instance)
      local id = f.idPath and idText(instance, f.idPath, f.idType) or nil
      local used = 0
      if f.usedPath then
        local u = R.get(instance, f.usedPath)
        if u == true then used = 1 elseif type(u) == "number" then used = u end
      end
      if id then
        logOnce("item:" .. id, "item in inventory: %s (used %d)", id, used)
        out[#out + 1] = { id = id:match("([^%./]*)$") or id, used = used }   -- ASL FNameToShortString
      end
    end
  end
  return out, n
end

---------------------------------------------------------------------------
-- loading screens: any widget with "Load" in its class name while it's up
---------------------------------------------------------------------------
local loadingWidgets = {}   -- address -> widget

function G.installHooks(onRestart)
  pcall(function()
    RegisterHook("/Script/UMG.UserWidget:Construct", function(ctx)
      local w = ctx:get()
      if not R.valid(w) then return end
      local name = w:GetClass():GetFName():ToString()
      if name:lower():find("load") then
        loadingWidgets[w:GetAddress()] = w
        logOnce("lw" .. name, "loading screen widget: %s", name)
      end
    end)
    RegisterHook("/Script/UMG.UserWidget:Destruct", function(ctx)
      local w = ctx:get()
      if not R.valid(w) then return end
      loadingWidgets[w:GetAddress()] = nil
    end)
  end)
  -- after every load the player is (re)possessed: a good moment to rebuild the timer
  pcall(function()
    RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
      if onRestart then onRestart() end
    end)
  end)
end

-- true while a loading widget is on screen. Entries the game deleted (or took off
-- the screen) without a Destruct are dropped, so a stale one can't freeze IGT.
function G.loadingScreenUp()
  local up = false
  for key, w in pairs(loadingWidgets) do
    if R.valid(w) and w:IsInViewport() then up = true
    else loadingWidgets[key] = nil end
  end
  return up
end
function G.clearLoadingScreens() loadingWidgets = {} end

return G
