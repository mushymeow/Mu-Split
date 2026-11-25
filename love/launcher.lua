-- Starts the Mu Split engine in the background (Windows only).
--
-- The engine (MuSplitEngine.exe) is our own program built on LiveSplit's libraries:
-- timer, splits files, autosplitters and global hotkeys, with no window. Looks for:
--   <exe folder>\engine\MuSplitEngine.exe            (release build, dist\)
--   <project folder>\vendor\engine\MuSplitEngine.exe  (dev: `love love` after build.bat)
-- and falls back to a bundled LiveSplit.exe (the old way) if there's no engine.
--
-- The bridge reads two env vars we pass down:
--   MUSPLIT_HIDDEN=1         keep LiveSplit's window invisible
--   MUSPLIT_PARENT_PID=<us>  LiveSplit closes itself when we exit, even if we crash

local launcher = { proc = nil, exePath = nil, error = nil }

-- what we start (for the status screen): "the engine" or "LiveSplit"
function launcher.name()
  if launcher.exePath and launcher.exePath:find("LiveSplit.exe", 1, true) then return "LiveSplit" end
  return "the engine"
end

if love.system.getOS() ~= "Windows" then
  -- Linux: the engine runs under Wine/Proton (linux.lua; required late: it needs net.lua)
  function launcher.launch()
    local okL, L = pcall(require, "linux")
    if not okL or not L.isLinux then launcher.error = "auto-launch only works on Windows and Linux" return false end
    local ok, err = L.launch()
    launcher.error, launcher.exePath = err, L.engineExe()
    return ok
  end
  function launcher.running()
    local okL, L = pcall(require, "linux")
    return okL and L.isLinux and L.engineRunning() or false
  end
  function launcher.owns() return false end
  return launcher
end

local ffi = require("ffi")
ffi.cdef [[
typedef struct {
  uint32_t cb; void* lpReserved; void* lpDesktop; void* lpTitle;
  uint32_t dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
  uint16_t wShowWindow, cbReserved2; void* lpReserved2;
  void* hStdInput; void* hStdOutput; void* hStdError;
} MUSPLIT_STARTUPINFOW;

typedef struct { void* hProcess; void* hThread; uint32_t dwProcessId, dwThreadId; } MUSPLIT_PROCESS_INFORMATION;

int CreateProcessW(const wchar_t* app, wchar_t* cmdLine, void* procAttr, void* threadAttr,
                   int inheritHandles, uint32_t flags, void* env, const wchar_t* cwd,
                   MUSPLIT_STARTUPINFOW* si, MUSPLIT_PROCESS_INFORMATION* pi);
int SetEnvironmentVariableW(const wchar_t* name, const wchar_t* value);
uint32_t GetFileAttributesW(const wchar_t* path);
uint32_t GetCurrentProcessId(void);
uint32_t WaitForSingleObject(void* handle, uint32_t ms);
int CloseHandle(void* handle);
]]
-- shared with filedialog.lua, so declare it only once
pcall(ffi.cdef, [[
int MultiByteToWideChar(unsigned int CodePage, uint32_t dwFlags, const char* lpMultiByteStr,
                        int cbMultiByte, wchar_t* lpWideCharStr, int cchWideChar);
]])

local C = ffi.C
local CP_UTF8 = 65001
local INVALID_FILE_ATTRIBUTES = 0xFFFFFFFF
local STARTF_USESHOWWINDOW = 0x1
local SW_SHOWMINNOACTIVE = 7     -- start minimized, don't steal focus (no flash before the bridge hides it)
local WAIT_TIMEOUT = 258

local function wide(s)
  local n = C.MultiByteToWideChar(CP_UTF8, 0, s, -1, nil, 0)
  local buf = ffi.new("wchar_t[?]", n)
  C.MultiByteToWideChar(CP_UTF8, 0, s, -1, buf, n)
  return buf
end

local function exists(path)
  return C.GetFileAttributesW(wide(path)) ~= INVALID_FILE_ATTRIBUTES
end

local function findLiveSplit()
  local base = love.filesystem.getSourceBaseDirectory():gsub("/", "\\")
  local candidates = {
    base .. "\\engine\\MuSplitEngine.exe",
    base .. "\\vendor\\engine\\MuSplitEngine.exe",
    base .. "\\LiveSplit\\LiveSplit.exe",
    base .. "\\vendor\\LiveSplit\\LiveSplit.exe",
  }
  for _, p in ipairs(candidates) do
    if exists(p) then return p end
  end
  return nil, "The Mu Split engine wasn't found next to Mu Split (run build.bat first)"
end

function launcher.launch()
  if launcher.running() then return true end

  local exe, err = findLiveSplit()
  if not exe then launcher.error = err return false end
  local dir = exe:match("^(.*)\\[^\\]+$")

  -- Child processes inherit our environment, so set these on ourselves first.
  C.SetEnvironmentVariableW(wide("MUSPLIT_HIDDEN"), wide("1"))
  C.SetEnvironmentVariableW(wide("MUSPLIT_PARENT_PID"), wide(tostring(C.GetCurrentProcessId())))

  local si = ffi.new("MUSPLIT_STARTUPINFOW")
  si.cb = ffi.sizeof(si)
  si.dwFlags = STARTF_USESHOWWINDOW
  si.wShowWindow = SW_SHOWMINNOACTIVE
  local pi = ffi.new("MUSPLIT_PROCESS_INFORMATION")
  local cmd = wide('"' .. exe .. '"')   -- CreateProcessW may write to this buffer, so it must be ours

  if C.CreateProcessW(nil, cmd, nil, nil, 0, 0, nil, wide(dir), si, pi) == 0 then
    launcher.error = "couldn't start " .. exe
    return false
  end

  C.CloseHandle(pi.hThread)
  launcher.proc, launcher.exePath, launcher.error = pi.hProcess, exe, nil
  return true
end

function launcher.running()
  if launcher.proc == nil then return false end
  if C.WaitForSingleObject(launcher.proc, 0) == WAIT_TIMEOUT then return true end
  C.CloseHandle(launcher.proc)
  launcher.proc = nil
  return false
end

-- true if we started the LiveSplit we're talking to (so we may close it on exit)
function launcher.owns() return launcher.proc ~= nil end

return launcher
