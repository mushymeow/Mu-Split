@echo off
rem Puts the Mu Split race server online (free Cloudflare Worker), then writes its address
rem into love\raceserver.lua so every Mu Split you build connects to it.
cd /d "%~dp0"
title Mu Split race server

where node >nul 2>nul
if errorlevel 1 (
  echo Node.js is needed for this one-time setup. Get the LTS version from https://nodejs.org
  echo then run this again.
  pause
  exit /b 1
)

echo.
echo  1/2  Sign in to Cloudflare (a browser opens; make a free account if you don't have one)
echo.
call npx --yes wrangler@4 login
if errorlevel 1 goto failed

echo.
echo  2/2  Uploading the race server
echo       (first time only: it may ask you to pick a workers.dev name, that's your address)
echo.
call npx --yes wrangler@4 deploy
if errorlevel 1 goto failed

echo.
echo  Done! Above it says something like:   https://musplit-race.YOURNAME.workers.dev
set /p URL=" Paste that address here and press Enter: "
if "%URL%"=="" goto nourl
> "..\love\raceserver.lua" echo return "%URL%"
echo.
echo  Saved. Run build.ps1 and Mu Split (and the copies you send friends) use this server.
pause
exit /b 0

:nourl
echo  No address given. You can type it in Mu Split instead: right-click ^> Race... ^> Race server.
pause
exit /b 0

:failed
echo.
echo  Something went wrong (see above).
pause
exit /b 1
