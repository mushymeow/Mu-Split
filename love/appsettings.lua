-- Mu Split's own settings that aren't part of a look (app.json in the save folder):
-- always on top, hide title bar. main.lua applies them at start; the Settings window's
-- Mu Split tab and the right-click menu change them.

local json = require("json")
local A = { cfg = { alwaysOnTop = false, borderless = false } }

function A.load()
  local ok, t = pcall(function() return json.decode(love.filesystem.read("app.json")) end)
  if ok and type(t) == "table" then for k, v in pairs(t) do A.cfg[k] = v end end
end
function A.save() pcall(love.filesystem.write, "app.json", json.encode(A.cfg)) end

function A.setAlwaysOnTop(on)
  A.cfg.alwaysOnTop = on
  require("windows").setAlwaysOnTop(on)
  A.save()
end
function A.setBorderless(on)
  A.cfg.borderless = on
  require("frame").set(on)
  A.save()
end

return A
