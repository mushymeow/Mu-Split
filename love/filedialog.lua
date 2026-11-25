-- Native Windows Open / Save dialogs (LÖVE 11 has none of its own).
-- Blocking: the app pauses while the dialog is open, same as any Windows program.

local M = {}

if love.system.getOS() ~= "Windows" then
  -- Linux: zenity (GNOME and most desktops) or kdialog (KDE)
  local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end
  local function has(cmd)
    local p = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if not p then return false end
    local o = p:read("*a") p:close()
    return (o or ""):match("%S") ~= nil
  end
  local function run(save, opt)
    opt = opt or {}
    local ext = opt.defExt or "lss"
    local title = opt.title or (save and "Save Splits As" or "Open Splits")
    local dir = opt.dir
    if dir then local L = package.loaded["linux"] if L then dir = L.fromWin(dir) end end
    local start = (dir or os.getenv("HOME") or ".") .. "/" .. (opt.filename or "")
    local pat = (ext == "png" or ext == "jpg") and "*.png *.jpg *.jpeg *.bmp" or ("*." .. ext)
    local cmd
    if has("zenity") then
      cmd = "zenity --file-selection --title=" .. q(title) .. (save and " --save --confirm-overwrite" or "")
        .. " --filename=" .. q(start) .. " --file-filter=" .. q(pat) .. " --file-filter=" .. q("All files | *")
    elseif has("kdialog") then
      cmd = "kdialog --title " .. q(title) .. (save and " --getsavefilename " or " --getopenfilename ") .. q(start) .. " " .. q(pat)
    else
      return nil
    end
    local p = io.popen(cmd .. " 2>/dev/null")
    if not p then return nil end
    local out = (p:read("*a") or ""):gsub("[\r\n]+$", "")
    p:close()
    if out == "" then return nil end
    if save and not out:match("%.%w+$") then out = out .. "." .. ext end
    return out
  end
  function M.open(opt) return run(false, opt) end
  function M.save(opt) return run(true, opt) end
  function M.allowForeground() end
  return M
end

local ffi = require("ffi")
ffi.cdef [[
typedef struct {
  uint32_t lStructSize; void* hwndOwner; void* hInstance;
  const wchar_t* lpstrFilter; wchar_t* lpstrCustomFilter; uint32_t nMaxCustFilter; uint32_t nFilterIndex;
  wchar_t* lpstrFile; uint32_t nMaxFile; wchar_t* lpstrFileTitle; uint32_t nMaxFileTitle;
  const wchar_t* lpstrInitialDir; const wchar_t* lpstrTitle; uint32_t Flags;
  uint16_t nFileOffset; uint16_t nFileExtension; const wchar_t* lpstrDefExt;
  intptr_t lCustData; void* lpfnHook; const wchar_t* lpTemplateName;
  void* pvReserved; uint32_t dwReserved; uint32_t FlagsEx;
} MUSPLIT_OPENFILENAMEW;

int GetOpenFileNameW(MUSPLIT_OPENFILENAMEW* ofn);
int GetSaveFileNameW(MUSPLIT_OPENFILENAMEW* ofn);
void* GetActiveWindow(void);
int AllowSetForegroundWindow(uint32_t pid);
int WideCharToMultiByte(unsigned int CodePage, uint32_t dwFlags, const wchar_t* w, int cchWide,
                        char* mb, int cbMultiByte, const char* defChar, int* usedDef);
]]

-- MultiByteToWideChar is declared by launcher.lua; declare again only if needed
pcall(ffi.cdef, [[
int MultiByteToWideChar(unsigned int CodePage, uint32_t dwFlags, const char* lpMultiByteStr,
                        int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
]])

local C = ffi.C
local comdlg = ffi.load("comdlg32")
local CP_UTF8 = 65001
local MAX = 32768

local OFN_OVERWRITEPROMPT = 0x2
local OFN_NOCHANGEDIR = 0x8
local OFN_PATHMUSTEXIST = 0x800
local OFN_FILEMUSTEXIST = 0x1000
local OFN_EXPLORER = 0x80000

-- UTF-8 -> wide, keeping embedded NULs (filters use them as separators)
local function wideRaw(s)
  local n = C.MultiByteToWideChar(CP_UTF8, 0, s, #s, nil, 0)
  local buf = ffi.new("wchar_t[?]", n + 2)   -- zero-filled, so double-NUL terminated
  C.MultiByteToWideChar(CP_UTF8, 0, s, #s, buf, n)
  return buf
end

local function narrow(w)
  local n = C.WideCharToMultiByte(CP_UTF8, 0, w, -1, nil, 0, nil, nil)
  if n <= 1 then return "" end
  local buf = ffi.new("char[?]", n)
  C.WideCharToMultiByte(CP_UTF8, 0, w, -1, buf, n, nil, nil)
  return ffi.string(buf)
end

local FILTER = "LiveSplit Splits (*.lss)\0*.lss\0All files (*.*)\0*.*\0"

local function run(save, opt)
  opt = opt or {}
  local ofn = ffi.new("MUSPLIT_OPENFILENAMEW")
  local file = ffi.new("wchar_t[?]", MAX)
  if opt.filename and opt.filename ~= "" then
    local w = wideRaw(opt.filename)
    local len = math.min(C.MultiByteToWideChar(CP_UTF8, 0, opt.filename, #opt.filename, nil, 0), MAX - 1)
    ffi.copy(file, w, len * ffi.sizeof("wchar_t"))
  end

  local filter = wideRaw(opt.filter or FILTER)       -- opt.filter: "Name\0*.ext;*.ext\0"
  local title = wideRaw(opt.title or (save and "Save Splits As" or "Open Splits"))
  local dir = opt.dir and wideRaw(opt.dir:gsub("/", "\\")) or nil
  local defExt = wideRaw(opt.defExt or "lss")

  ofn.lStructSize = ffi.sizeof(ofn)
  ofn.hwndOwner = C.GetActiveWindow()
  ofn.lpstrFilter = filter
  ofn.nFilterIndex = 1
  ofn.lpstrFile = file
  ofn.nMaxFile = MAX
  ofn.lpstrTitle = title
  ofn.lpstrInitialDir = dir
  ofn.lpstrDefExt = defExt
  ofn.Flags = OFN_EXPLORER + OFN_NOCHANGEDIR + OFN_PATHMUSTEXIST + (save and OFN_OVERWRITEPROMPT or OFN_FILEMUSTEXIST)

  local ok = save and comdlg.GetSaveFileNameW(ofn) or comdlg.GetOpenFileNameW(ofn)
  if ok == 0 then return nil end
  return narrow(file)
end

function M.open(opt) return run(false, opt) end
function M.save(opt) return run(true, opt) end

-- Let LiveSplit's process bring its own window (e.g. a DLL autosplitter's settings) to the front.
function M.allowForeground()
  C.AllowSetForegroundWindow(0xFFFFFFFF)
end

return M
