-- Converts LÖVE key names to .NET System.Windows.Forms.Keys names, which is what
-- LiveSplit stores for hotkeys ("NumPad1", "D1, Control", "Oemplus", ...), and
-- turns those back into something readable for the settings window.

local M = {}

local toNet = {
  ["return"] = "Return", kpenter = "Return", escape = "Escape", backspace = "Back", tab = "Tab", space = "Space",
  up = "Up", down = "Down", left = "Left", right = "Right",
  home = "Home", ["end"] = "End", pageup = "PageUp", pagedown = "Next", insert = "Insert", delete = "Delete",
  kp0 = "NumPad0", kp1 = "NumPad1", kp2 = "NumPad2", kp3 = "NumPad3", kp4 = "NumPad4",
  kp5 = "NumPad5", kp6 = "NumPad6", kp7 = "NumPad7", kp8 = "NumPad8", kp9 = "NumPad9",
  ["kp+"] = "Add", ["kp-"] = "Subtract", ["kp*"] = "Multiply", ["kp/"] = "Divide", ["kp."] = "Decimal",
  [";"] = "OemSemicolon", ["="] = "Oemplus", [","] = "Oemcomma", ["-"] = "OemMinus", ["."] = "OemPeriod",
  ["/"] = "OemQuestion", ["`"] = "Oemtilde", ["["] = "OemOpenBrackets", ["\\"] = "OemPipe",
  ["]"] = "OemCloseBrackets", ["'"] = "OemQuotes",
  pause = "Pause", scrolllock = "Scroll", numlock = "NumLock", capslock = "Capital", printscreen = "PrintScreen",
  application = "Apps", menu = "Apps",
}
for i = 0, 9 do toNet[tostring(i)] = "D" .. i end
for i = 1, 24 do toNet["f" .. i] = "F" .. i end
for c = string.byte("a"), string.byte("z") do toNet[string.char(c)] = string.char(c):upper() end

local modifiers = { lctrl = true, rctrl = true, lshift = true, rshift = true, lalt = true, ralt = true, lgui = true, rgui = true }
function M.isModifier(key) return modifiers[key] == true end

function M.toDotNet(key, ctrl, shift, alt)
  local base = toNet[key]
  if not base then return nil end
  local parts = { base }
  if shift then parts[#parts + 1] = "Shift" end
  if ctrl then parts[#parts + 1] = "Control" end
  if alt then parts[#parts + 1] = "Alt" end
  return table.concat(parts, ", ")
end

-- readable names for the .NET ones
local pretty = {
  Return = "Enter", Back = "Backspace", Next = "Page Down", PageUp = "Page Up", Prior = "Page Up",
  Add = "Num +", Subtract = "Num -", Multiply = "Num *", Divide = "Num /", Decimal = "Num .",
  OemSemicolon = ";", Oem1 = ";", Oemplus = "=", Oemcomma = ",", OemMinus = "-", OemPeriod = ".",
  OemQuestion = "/", Oem2 = "/", Oemtilde = "`", Oem3 = "`", OemOpenBrackets = "[", Oem4 = "[",
  OemPipe = "\\", Oem5 = "\\", OemCloseBrackets = "]", Oem6 = "]", OemQuotes = "'", Oem7 = "'",
  Scroll = "Scroll Lock", Capital = "Caps Lock", Apps = "Menu", Escape = "Esc", Snapshot = "Print Screen",
  PrintScreen = "Print Screen", NumLock = "Num Lock",
}

function M.display(net)
  if net == nil or net == "" then return "None" end
  -- gamepad buttons come through as "Button1 Controller Name"
  if net:find(" ") and not net:find(", ") then return net end
  local parts = {}
  for p in net:gmatch("[^,%s]+") do parts[#parts + 1] = p end
  local mods, key = {}, nil
  for _, p in ipairs(parts) do
    if p == "Control" then mods[#mods + 1] = "Ctrl"
    elseif p == "Shift" then mods[#mods + 1] = "Shift"
    elseif p == "Alt" then mods[#mods + 1] = "Alt"
    else
      key = pretty[p] or p:gsub("^NumPad(%d)$", "Num %1"):gsub("^D(%d)$", "%1")
    end
  end
  table.sort(mods, function(a, b)
    local order = { Ctrl = 1, Shift = 2, Alt = 3 }
    return order[a] < order[b]
  end)
  mods[#mods + 1] = key or "?"
  return table.concat(mods, " + ")
end

return M
