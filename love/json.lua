-- Minimal JSON decoder + encoder.
-- JSON null becomes Lua nil. Encoding: tables with [1] are arrays, others objects.
local json = {}

local escapes = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }

local function err(str, i, msg)
  error(("json: %s at char %d near '%s'"):format(msg, i, str:sub(i, i + 10)), 0)
end

local function skip(str, i)
  return str:find("[^ \t\r\n]", i) or #str + 1
end

local function utf8char(cp)
  if cp < 0x80 then return string.char(cp)
  elseif cp < 0x800 then return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  elseif cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  else
    return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
      0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
end

local parse

local function parseString(str, i)
  local out, j = {}, i + 1
  while true do
    local c = str:sub(j, j)
    if c == "" then err(str, i, "unterminated string") end
    if c == '"' then return table.concat(out), j + 1 end
    if c == "\\" then
      local e = str:sub(j + 1, j + 1)
      if e == "u" then
        local hex = str:sub(j + 2, j + 5)
        local cp = tonumber(hex, 16) or err(str, j, "bad \\u escape")
        j = j + 6
        -- surrogate pair
        if cp >= 0xD800 and cp <= 0xDBFF and str:sub(j, j + 1) == "\\u" then
          local lo = tonumber(str:sub(j + 2, j + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            j = j + 6
          end
        end
        out[#out + 1] = utf8char(cp)
      else
        out[#out + 1] = escapes[e] or err(str, j, "bad escape")
        j = j + 2
      end
    else
      local k = str:find('["\\]', j) or #str + 1
      out[#out + 1] = str:sub(j, k - 1)
      j = k
    end
  end
end

local function parseNumber(str, i)
  local s, e = str:find("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if not s then err(str, i, "bad number") end
  return tonumber(str:sub(s, e)), e + 1
end

parse = function(str, i)
  i = skip(str, i)
  local c = str:sub(i, i)
  if c == "{" then
    local obj = {}
    i = skip(str, i + 1)
    if str:sub(i, i) == "}" then return obj, i + 1 end
    while true do
      i = skip(str, i)
      if str:sub(i, i) ~= '"' then err(str, i, "expected key") end
      local key; key, i = parseString(str, i)
      i = skip(str, i)
      if str:sub(i, i) ~= ":" then err(str, i, "expected ':'") end
      local val; val, i = parse(str, i + 1)
      obj[key] = val
      i = skip(str, i)
      local d = str:sub(i, i)
      if d == "}" then return obj, i + 1 end
      if d ~= "," then err(str, i, "expected ',' or '}'") end
      i = i + 1
    end
  elseif c == "[" then
    local arr, n = {}, 0
    i = skip(str, i + 1)
    if str:sub(i, i) == "]" then return arr, i + 1 end
    while true do
      local val; val, i = parse(str, i)
      n = n + 1; arr[n] = val
      i = skip(str, i)
      local d = str:sub(i, i)
      if d == "]" then return arr, i + 1 end
      if d ~= "," then err(str, i, "expected ',' or ']'") end
      i = i + 1
    end
  elseif c == '"' then return parseString(str, i)
  elseif c == "-" or c:match("%d") then return parseNumber(str, i)
  elseif str:sub(i, i + 3) == "true" then return true, i + 4
  elseif str:sub(i, i + 4) == "false" then return false, i + 5
  elseif str:sub(i, i + 3) == "null" then return nil, i + 4
  end
  err(str, i, "unexpected character")
end

function json.decode(str)
  local val, i = parse(str, 1)
  i = skip(str, i)
  if i <= #str then err(str, i, "trailing garbage") end
  return val
end

local escMap = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function encodeString(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escMap[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local encode
encode = function(v)
  local t = type(v)
  if v == nil or v == json.null then return "null"
  elseif t == "boolean" then return v and "true" or "false"
  elseif t == "number" then
    if v ~= v or v == math.huge or v == -math.huge then return "null" end
    if math.floor(v) == v and math.abs(v) < 1e15 then return string.format("%d", v) end
    return string.format("%.14g", v)
  elseif t == "string" then return encodeString(v)
  elseif t == "table" then
    if rawget(v, 1) ~= nil or next(v) == nil and getmetatable(v) == json.arrayMeta then
      local out = {}
      for i = 1, #v do out[i] = encode(v[i]) end
      return "[" .. table.concat(out, ",") .. "]"
    end
    local out = {}
    for k, val in pairs(v) do out[#out + 1] = encodeString(tostring(k)) .. ":" .. encode(val) end
    return "{" .. table.concat(out, ",") .. "}"
  end
  error("json: can't encode " .. t)
end

json.null = setmetatable({}, { __tostring = function() return "null" end })
json.arrayMeta = {}
function json.array(t) return setmetatable(t or {}, json.arrayMeta) end
json.encode = function(v) return encode(v) end

return json
