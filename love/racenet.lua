-- The race connection's plumbing. Love can't open secure WebSockets (wss://) itself, so the
-- engine does it for us (engine/RaceRelay.cs) and we talk to it on 127.0.0.1:16851 in lines:
--   us -> engine:  "connect <url>"   "send <json>"   "close"
--                  "discord <appId> <activity json>"   (Discord status, see discordrpc.lua)
--   engine -> us:  {"type":"open"}   {"type":"msg","data":"<json>"}   {"type":"close","reason":"..."}

local socket = require("socket")
local json = require("json")

local R = {
  host = "127.0.0.1", port = 16851,
  sock = nil, buf = "", nextTry = 0,
  pending = {},     -- lines waiting for the engine connection
  on = {},          -- on.open(), on.message(tbl), on.close(reason)
}

local function rawSend(line)
  if not R.sock then
    R.pending[#R.pending + 1] = line
    if #R.pending > 50 then table.remove(R.pending, 1) end
    return
  end
  local ok = R.sock:send(line .. "\n")
  if not ok then R.drop() R.pending[#R.pending + 1] = line end
end

function R.drop()
  if R.sock then pcall(function() R.sock:close() end) end
  R.sock, R.buf = nil, ""
  R.nextTry = love.timer.getTime() + 1
end

local function tryConnect(now)
  local s = socket.tcp()
  s:settimeout(0.05)
  local ok = s:connect(R.host, R.port)
  if not ok then s:close() R.nextTry = now + 1 return false end
  s:settimeout(0)
  s:setoption("tcp-nodelay", true)
  R.sock = s
  local p = R.pending
  R.pending = {}
  for _, line in ipairs(p) do rawSend(line) end
  return true
end

function R.connect(url) rawSend("connect " .. url) end
function R.send(tbl) rawSend("send " .. json.encode(tbl)) end
function R.close() rawSend("close") end
function R.raw(line) rawSend(line) end
function R.engineUp() return R.sock ~= nil end

function R.update()
  local now = love.timer.getTime()
  if not R.sock then
    if #R.pending > 0 and now >= R.nextTry then tryConnect(now) end
    return
  end
  for _ = 1, 200 do
    local line, err, partial = R.sock:receive("*l")
    if line then
      line = R.buf .. line
      R.buf = ""
      local ok, msg = pcall(json.decode, line)
      if ok and type(msg) == "table" then
        if msg.type == "hello" then if R.on.hello then R.on.hello(msg) end
        elseif msg.type == "open" and R.on.open then R.on.open()
        elseif msg.type == "close" and R.on.close then R.on.close(msg.reason or "")
        elseif msg.type == "msg" and R.on.message then
          local ok2, m = pcall(json.decode, msg.data or "")
          if ok2 and type(m) == "table" then R.on.message(m) end
        end
      end
    elseif err == "timeout" then
      R.buf = R.buf .. (partial or "")
      break
    else
      -- the engine went away (restarting?): the race connection is gone with it
      R.drop()
      if R.on.close then R.on.close("engine stopped") end
      break
    end
  end
end

return R
