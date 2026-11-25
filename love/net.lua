-- Connection to the Mu Split Bridge inside LiveSplit.
--   bridge -> us : one JSON object per line, dispatched by its "type" to net.on[type]
--   us -> bridge : one command per line: "cmd" or "cmd argument" (argument may be JSON)

local socket = require("socket")
local json = require("json")
local launcher = require("launcher")

local net = {
  host = "127.0.0.1", port = 16850,
  sock = nil, buf = "", connected = false,
  nextTry = 0, lastMsg = 0, launchTried = false,
  on = {},          -- handlers: net.on.state = function(msg) ... end
}

function net.send(cmd, arg)
  if not net.sock then return false end
  local line = cmd
  if type(arg) == "table" then line = cmd .. " " .. json.encode(arg)
  elseif arg ~= nil then line = cmd .. " " .. tostring(arg) end
  local ok = net.sock:send(line .. "\n")
  return ok ~= nil
end

function net.disconnect()
  if net.sock then net.sock:close() end
  net.sock, net.connected, net.buf = nil, false, ""
  net.nextTry = love.timer.getTime() + 0.5
  if net.on.disconnected then net.on.disconnected() end
end

local function tryConnect(now)
  local sock = socket.tcp()
  sock:settimeout(0.1)
  local ok = sock:connect(net.host, net.port)
  if ok then
    sock:settimeout(0)
    sock:setoption("tcp-nodelay", true)
    net.sock, net.connected, net.lastMsg = sock, true, now
    if net.on.connected then net.on.connected() end
  else
    sock:close()
    net.nextTry = now + 0.5
    -- Nobody listening on the first try: start our bundled LiveSplit.
    -- (If you already have LiveSplit open with the bridge, we just use that one.)
    if not net.launchTried then
      net.launchTried = true
      launcher.launch()
    end
  end
end

function net.update()
  local now = love.timer.getTime()
  if not net.sock then
    if now >= net.nextTry then tryConnect(now) end
    return
  end

  for _ = 1, 500 do  -- drain everything waiting this frame
    local line, err, partial = net.sock:receive("*l")
    if line then
      line = net.buf .. line
      net.buf = ""
      net.lastMsg = now
      local ok, msg = pcall(json.decode, line)
      if ok and type(msg) == "table" and msg.type then
        local h = net.on[msg.type]
        if h then h(msg) end
      end
    elseif err == "timeout" then
      net.buf = net.buf .. (partial or "")
      break
    else
      net.disconnect()
      break
    end
  end
end

function net.stale()
  return love.timer.getTime() - net.lastMsg > 0.5
end

return net
