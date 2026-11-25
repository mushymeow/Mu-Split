#!/usr/bin/env bash
# Mu Split on Linux. The window runs natively with LÖVE; the engine (Windows) runs under
# Wine/Proton, started automatically. Needs: LÖVE 11.4+ (e.g. `sudo apt install love`,
# `sudo pacman -S love`, or the AppImage from love2d.org) and Wine or Steam with Proton.
# Copy the whole Mu Split folder over from Windows after running build.ps1 there
# (it needs love/ and vendor/engine/ or engine/).
cd "$(dirname "$(readlink -f "$0")")"
LOVE="${LOVE:-$(command -v love || command -v love2d || true)}"
if [ -z "$LOVE" ]; then
  for f in ./love-*.AppImage "$HOME"/Applications/love-*.AppImage; do [ -x "$f" ] && LOVE="$f" && break; done
fi
if [ -z "$LOVE" ]; then
  echo "LÖVE isn't installed: install the 'love' package, or put love-11.5-x86_64.AppImage next to this script."
  exit 1
fi
if [ ! -e engine/MuSplitEngine.exe ] && [ ! -e vendor/engine/MuSplitEngine.exe ]; then
  echo "The engine is missing: run build.ps1 on Windows first, then copy the whole folder here."
  exit 1
fi
exec "$LOVE" love "$@"
