-- The workshop: looks other people shared, from a free GitHub repo.
--
--   browsing  index.json in the repo lists every look (with its data), so cards are drawn
--             here from the look itself: no images to host. The engine downloads it
--             (LÖVE can't do HTTPS); a copy is kept for when you're offline.
--   sharing   "Share your look" opens a pre-filled GitHub form in your browser; a GitHub
--             Action checks the look and adds it (see the workshop\ folder in the project).
--   votes     each look's GitHub issue is its page; 👍 / ❤️ reactions are its votes.
--
-- The repo is a setting (Customise → Workshop), saved in workshop.json.

local json = require("json")
local net = require("net")
local theme = require("theme")

local W = {
  repo = "mushymeow/musplit-workshop", -- owner/name on GitHub (changeable in the Workshop tab)
  branch = "main",
  looks = nil,                          -- list from index.json
  status = "idle",                      -- idle | loading | ok | error | offline
  error = nil, updated = nil, cached = false,
}

local fs = love.filesystem

local function loadSettings()
  if not fs.getInfo("workshop.json") then return end
  local ok, t = pcall(function() return json.decode(fs.read("workshop.json")) end)
  if ok and type(t) == "table" then
    W.repo = type(t.repo) == "string" and t.repo or W.repo
    W.branch = type(t.branch) == "string" and t.branch or W.branch
  end
end

function W.saveSettings()
  pcall(fs.write, "workshop.json", json.encode({ repo = W.repo, branch = W.branch }))
end

function W.setRepo(repo)
  repo = tostring(repo or ""):gsub("^%s+", ""):gsub("%s+$", ""):gsub("^https?://github.com/", ""):gsub("/$", "")
  if not repo:match("^[%w%-%_%.]+/[%w%-%_%.]+$") then return false end
  W.repo = repo
  W.saveSettings()
  W.looks, W.status = nil, "idle"
  return true
end

local function indexUrl()
  return ("https://raw.githubusercontent.com/%s/%s/index.json"):format(W.repo, W.branch)
end

local function useIndex(body, fromCache)
  local ok, t = pcall(json.decode, body)
  if not ok or type(t) ~= "table" or type(t.looks) ~= "table" then return false end
  local out = {}
  for _, e in ipairs(t.looks) do
    if type(e) == "table" and type(e.look) == "table" then
      local style = theme.complete(e.look)
      style.name = tostring(e.name or style.name or "Look")
      style.background.image = nil          -- pictures aren't shared (they're local files)
      out[#out + 1] = {
        id = tostring(e.id or #out + 1), name = style.name, author = tostring(e.author or "someone"),
        votes = tonumber(e.votes) or 0, created = tostring(e.created or ""), page = e.issue, style = style,
      }
    end
  end
  W.looks, W.updated, W.cached = out, t.updated, fromCache
  return true
end

-- the list we had last time, until a fresh one arrives
local function loadCache()
  local path = "workshop/index.json"
  if fs.getInfo(path) then useIndex(fs.read(path), true) end
end

function W.refresh()
  if W.status == "loading" then return end
  if not net.connected then
    W.status = W.looks and "offline" or "error"
    W.error = "The workshop downloads through the engine, which isn't running yet."
    return
  end
  W.status, W.error = "loading", nil
  W.requested = indexUrl()
  net.send("http_get", W.requested)
end

-- main.lua: net.on.http
function W.onHttp(msg)
  if msg.url ~= W.requested then return end
  if not msg.ok then
    W.status, W.error = W.looks and "offline" or "error", msg.error or "Couldn't reach the workshop"
    return
  end
  if useIndex(msg.body or "", false) then
    W.status = "ok"
    fs.createDirectory("workshop")
    pcall(fs.write, "workshop/index.json", msg.body)
  else
    W.status, W.error = "error", "The workshop's list couldn't be read."
  end
end

function W.open()
  loadSettings()
  if not W.looks then loadCache() end
  if W.status ~= "ok" and W.status ~= "loading" then W.refresh() end
end

-- sorted + searched view
function W.list(sort, query)
  local out = {}
  query = (query or ""):lower()
  for _, e in ipairs(W.looks or {}) do
    if query == "" or e.name:lower():find(query, 1, true) or e.author:lower():find(query, 1, true) then out[#out + 1] = e end
  end
  if sort == "new" then table.sort(out, function(a, b) return a.created > b.created end)
  else table.sort(out, function(a, b) if a.votes ~= b.votes then return a.votes > b.votes end return a.created > b.created end) end
  return out
end

---------------------------------------------------------------------------
-- sharing: a pre-filled GitHub issue form (the repo's .github/ISSUE_TEMPLATE/look.yml)
---------------------------------------------------------------------------
local function urlencode(s)
  return (tostring(s):gsub("[^%w%-%_%.%~]", function(c) return string.format("%%%02X", c:byte()) end))
end

function W.shareUrl(style, name)
  local s = theme.deepcopy(style)
  s.name = name
  if s.background then s.background.image = nil end   -- a local file; can't be shared this way
  s.musplit = 1
  return ("https://github.com/%s/issues/new?template=look.yml&title=%s&name=%s&look_json=%s"):format(
    W.repo, urlencode("Look: " .. name), urlencode(name), urlencode(json.encode(s)))
end

function W.share(style, name)
  local url = W.shareUrl(style, name)
  local ok = pcall(love.system.openURL, url)
  return ok, url
end

loadSettings()
return W
