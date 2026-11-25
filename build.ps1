# Builds Mu Split into dist\
#
#   dist\
#     MuSplit.exe        <- the app (LÖVE + our Lua fused together)
#     *.dll              <- LÖVE runtime
#     engine\            <- MuSplitEngine.exe + LiveSplit's libraries (no LiveSplit.exe)
#
# First run downloads LiveSplit (for its libraries) and LÖVE into vendor\ (cached after that).
# Needs: Windows, PowerShell 5+, .NET SDK (https://dotnet.microsoft.com/download)

param(
  [switch]$Clean    # wipe vendor\ and re-download everything
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"   # makes Invoke-WebRequest ~10x faster
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
Add-Type -AssemblyName System.IO.Compression.FileSystem

$root    = $PSScriptRoot
$vendor  = Join-Path $root "vendor"
$dist    = Join-Path $root "dist"
$tmp     = Join-Path $root "build-tmp"
$lsDir   = Join-Path $vendor "LiveSplit"
$loveDir = Join-Path $vendor "love"
$loveVersion = "11.5"

function Step($msg) { Write-Host "`n== $msg" -ForegroundColor Cyan }

# Download a zip and extract the folder that contains $marker (zips differ in nesting).
function Get-ZipFolder($url, $marker, $dest) {
  if (Test-Path $tmp) { Remove-Item $tmp -Recurse -Force }
  New-Item -ItemType Directory $tmp | Out-Null
  $zip = Join-Path $tmp "download.zip"
  Write-Host "   downloading $url"
  Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
  $out = Join-Path $tmp "x"
  [IO.Compression.ZipFile]::ExtractToDirectory($zip, $out)
  $found = Get-ChildItem $out -Recurse -Filter $marker | Select-Object -First 1
  if (-not $found) { throw "$marker not found in $url" }
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  Move-Item $found.DirectoryName $dest
  Remove-Item $tmp -Recurse -Force
}

if ($Clean -and (Test-Path $vendor)) { Remove-Item $vendor -Recurse -Force }
New-Item -ItemType Directory $vendor -Force | Out-Null

# ---------------------------------------------------------------- tools
Step "Checking for .NET SDK"
if (-not (Get-Command dotnet -ErrorAction SilentlyContinue)) {
  throw ".NET SDK not found. Install it from https://dotnet.microsoft.com/download and run this again."
}
Write-Host "   dotnet $(dotnet --version)"

# ---------------------------------------------------------------- LiveSplit
Step "LiveSplit"
if (-not (Test-Path (Join-Path $lsDir "LiveSplit.exe"))) {
  $rel = Invoke-RestMethod "https://api.github.com/repos/LiveSplit/LiveSplit/releases/latest" -UseBasicParsing
  $asset = $rel.assets | Where-Object { $_.name -match '^LiveSplit_.*\.zip$' } | Select-Object -First 1
  if (-not $asset) { throw "Couldn't find a LiveSplit zip in the latest GitHub release" }
  Write-Host "   latest is $($rel.tag_name)"
  Get-ZipFolder $asset.browser_download_url "LiveSplit.exe" $lsDir
} else {
  Write-Host "   using cached vendor\LiveSplit"
}

# ---------------------------------------------------------------- LÖVE
Step "LOVE $loveVersion"
if (-not (Test-Path (Join-Path $loveDir "love.exe"))) {
  Get-ZipFolder "https://github.com/love2d/love/releases/download/$loveVersion/love-$loveVersion-win64.zip" "love.exe" $loveDir
} else {
  Write-Host "   using cached vendor\love"
}

# ---------------------------------------------------------------- moonshine (shader effects)
Step "moonshine"
$moonDir = Join-Path $root "love\moonshine"
if (-not (Test-Path (Join-Path $moonDir "init.lua"))) {
  try {
    Get-ZipFolder "https://github.com/vrld/moonshine/archive/refs/heads/master.zip" "chromasep.lua" $moonDir
    Write-Host "   downloaded into love\moonshine"
  } catch {
    Write-Host "   couldn't download moonshine (shader effects stay off): $_" -ForegroundColor Yellow
  }
} else {
  Write-Host "   using love\moonshine"
}

# ---------------------------------------------------------------- engine
Step "Building the engine"
$proj = Join-Path $root "engine\MuSplit.Engine.csproj"
dotnet build $proj -c Release -nologo -v quiet "-p:LiveSplitDir=$lsDir"
if ($LASTEXITCODE -ne 0) { throw "Engine build failed (see errors above)" }
$engineOut = Join-Path $root "engine\bin\Release\net481"

# vendor\engine = LiveSplit's libraries + components, without LiveSplit itself
$engineDir = Join-Path $vendor "engine"
$keepEngine = @{}
foreach ($f in @("settings.cfg", "LiveSplit.AutoSplitters.xml")) {
  $p = Join-Path $engineDir $f
  if (Test-Path $p) { $keepEngine[$f] = [IO.File]::ReadAllBytes($p) }
}
if (Test-Path $engineDir) { Remove-Item $engineDir -Recurse -Force }
Copy-Item $lsDir $engineDir -Recurse
foreach ($f in @("LiveSplit.exe", "LiveSplit.exe.config", "LiveSplit.Register.exe", "LiveSplit.Register.exe.config", "Components\LiveSplit.MuSplit.dll")) {
  $p = Join-Path $engineDir $f
  if (Test-Path $p) { Remove-Item $p -Force }
}
Copy-Item (Join-Path $engineOut "MuSplitEngine.exe") $engineDir -Force
Copy-Item (Join-Path $engineOut "MuSplitEngine.pdb") $engineDir -Force -ErrorAction SilentlyContinue
# same assembly binding redirects LiveSplit.exe uses for its libraries
Copy-Item (Join-Path $lsDir "LiveSplit.exe.config") (Join-Path $engineDir "MuSplitEngine.exe.config") -Force
foreach ($k in $keepEngine.Keys) { [IO.File]::WriteAllBytes((Join-Path $engineDir $k), $keepEngine[$k]) }
Write-Host "   MuSplitEngine.exe -> vendor\engine"

# ---------------------------------------------------------------- package
Step "Packaging dist\"
# a running Mu Split / engine keeps its files locked, so close them first
$running = Get-Process -Name "MuSplit", "MuSplitEngine" -ErrorAction SilentlyContinue
if ($running) {
  Write-Host "   closing the running Mu Split so dist\ can be replaced"
  $running | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Milliseconds 800
}
# keep the engine's settings (hotkeys, recent splits) across rebuilds; the first time,
# take them from the old bundled LiveSplit so nothing is lost
$savedCfg = $null
$cfg = Join-Path $dist "engine\settings.cfg"
$oldCfg = Join-Path $dist "LiveSplit\settings.cfg"
if (Test-Path $cfg) { $savedCfg = [IO.File]::ReadAllBytes($cfg) }
elseif (Test-Path $oldCfg) { $savedCfg = [IO.File]::ReadAllBytes($oldCfg) }
if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory $dist | Out-Null

# .love file = zip of the love\ folder
$lovefile = Join-Path $root "MuSplit.love"
if (Test-Path $lovefile) { Remove-Item $lovefile -Force }
[IO.Compression.ZipFile]::CreateFromDirectory((Join-Path $root "love"), $lovefile)

# Fuse: love.exe + MuSplit.love = MuSplit.exe
$exeBytes  = [IO.File]::ReadAllBytes((Join-Path $loveDir "love.exe"))
$loveBytes = [IO.File]::ReadAllBytes($lovefile)
$fs = [IO.File]::Create((Join-Path $dist "MuSplit.exe"))
$fs.Write($exeBytes, 0, $exeBytes.Length)
$fs.Write($loveBytes, 0, $loveBytes.Length)
$fs.Close()
Remove-Item $lovefile -Force

Copy-Item (Join-Path $loveDir "*.dll") $dist
Copy-Item (Join-Path $loveDir "license.txt") (Join-Path $dist "LOVE-license.txt") -ErrorAction SilentlyContinue
Copy-Item $engineDir (Join-Path $dist "engine") -Recurse
if ($savedCfg) { [IO.File]::WriteAllBytes($cfg, $savedCfg) }

# ---------------------------------------------------------------- release zip
# MuSplit.zip: dist\ without anything personal (your hotkeys and recent splits in
# settings.cfg, logs) or debug files. This is the file to put on GitHub Releases.
Step "Making MuSplit.zip"
$stage = Join-Path $root "build-tmp\MuSplit"
if (Test-Path (Join-Path $root "build-tmp")) { Remove-Item (Join-Path $root "build-tmp") -Recurse -Force }
New-Item -ItemType Directory $stage -Force | Out-Null
Copy-Item (Join-Path $dist "*") $stage -Recurse
Get-ChildItem $stage -Recurse -Include "settings.cfg", "*.log", "*.pdb" | Remove-Item -Force -ErrorAction SilentlyContinue
$zip = Join-Path $root "MuSplit.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
[IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip, [IO.Compression.CompressionLevel]::Optimal, $true)
Remove-Item (Join-Path $root "build-tmp") -Recurse -Force

Step "Done"
Write-Host "   $dist\MuSplit.exe" -ForegroundColor Green
Write-Host "   $zip  (for GitHub Releases: nothing personal in it)" -ForegroundColor Green
