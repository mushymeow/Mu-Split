# Mu Split on Linux

The timer window runs natively on Linux (LÖVE). Only the engine, the Windows part that runs
autosplitters, runs under Wine/Proton.

## Run it

1. On Windows, run `build.ps1`, then copy the whole Mu Split folder to your Linux PC.
2. Install LÖVE 11.4 or newer (`love` package, or the AppImage from love2d.org) and Wine
   (or just have Steam with Proton; [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher) works too).
3. Run `./run-linux.sh`.

Mu Split starts its engine in its own Wine prefix (`~/.local/share/musplit/wine`). The first
start can take a minute while Wine sets up (it may offer to install Wine Mono: say yes).

## Autosplitters

Right-click > **Autosplitters on Linux…**, pick your game, and copy the launch option into
the game's Steam properties. When you start the game, Steam starts the Mu Split engine inside
the game's Proton prefix (the only place that can see the game's memory), and Mu Split
switches to it by itself. The status line turns green.

- Keep the Mu Split folder somewhere in your home folder: Steam runs games in a container that may not see other drives.
- Save your splits before starting the game: the switch reopens them from the file.
- If the engine doesn't start in the game, its prefix may need .NET once:
  `protontricks <appid> -q dotnet48` (the window has a copy button).
- Engine logs: `engine/engine.log` and `~/.local/share/musplit/engine-wine.log`.

## Not yet

- Global hotkeys: keys work while Mu Split has focus; the autosplitter does the rest.
- Overlay mode (in-game) is Windows only.
