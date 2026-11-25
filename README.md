<p align="center">
  <img src="assets/logo.png" alt="Mu Split" width="640">
</p>

<p align="center">
  <b>A speedrun timer that looks as good as your runs.</b><br>
  LiveSplit's timing and autosplitters, with a smooth, animated, fully customisable timer, built-in races and Discord status.
</p>

<p align="center">
  <a href="https://github.com/mushymeow/Mu-Split/releases/latest"><img src="https://img.shields.io/github/v/release/mushymeow/Mu-Split?label=download&style=for-the-badge&color=ff4b14" alt="Download"></a>
  <img src="https://img.shields.io/badge/Windows-supported-1f6feb?style=for-the-badge" alt="Windows">
  <img src="https://img.shields.io/badge/Linux-beta-f0a020?style=for-the-badge" alt="Linux beta">
  <a href="LICENSE"><img src="https://img.shields.io/github/license/mushymeow/Mu-Split?style=for-the-badge&color=444" alt="License"></a>
</p>

---

## Download

1. Grab the latest **`MuSplit.zip`** from [Releases](https://github.com/mushymeow/Mu-Split/releases/latest).
2. Unzip it anywhere and run **`MuSplit.exe`**.
3. Right-click the timer for everything: open your splits, customise, race.

Your LiveSplit splits (`.lss`) work as they are.

## Why Mu Split

- **Same timing as LiveSplit.** Mu Split's engine is built on LiveSplit's own open-source code, so times, splits files and autosplitters behave exactly the same.
- **Smooth.** The timer is drawn on your graphics card every frame: rolling digits, gliding highlight, split pops, sparks and confetti for golds and PBs.
- **Simple.** One Customise window (F1) with a live preview instead of layout editors.

## Features

**Looks**
- 12 built-in looks, a *Surprise me* button, and every colour, font, size and effect as a setting
- Background pictures (drag one onto the timer), gradients, aurora and particles
- Shader effects: bloom, light rays, grain, CRT, scanlines and more
- A **Workshop** to share looks and download other people's
- Per-game looks, F2 to flip between looks, sounds for splits, golds and PBs

**Splits**
- **Auto Splits**: builds your splits from the autosplitter's settings
- **Subsplits**: sections that fold away when you're not in them (LiveSplit's naming, so your files stay compatible)
- Sum of best, best possible time, possible time save, autosplitter status

**Online**
- **Races**: make a race, send the code, and everyone's timer starts on the same countdown. Live standings show who's ahead at every split, with chat
- **Discord status**: shows your game, current split and time on your profile

**Also**
- Hide the title bar, always on top, in-game overlay mode
- **Linux (beta)**: the timer runs natively; autosplitters work through Proton. See [README-linux.md](README-linux.md)

## Building it yourself

Needs Windows and the [.NET SDK](https://dotnet.microsoft.com/download). Run **`build.bat`**: it downloads LiveSplit's libraries and LÖVE into `vendor\` and puts the app in `dist\`. Details in [docs/DEVELOPING.md](docs/DEVELOPING.md).

The race server is a free Cloudflare Worker: see [server/README.md](server/README.md).

## Credits

- [LiveSplit](https://github.com/LiveSplit/LiveSplit) (MIT): the timing engine and autosplitter support Mu Split is built on. Thank you to everyone who works on it.
- [LÖVE](https://love2d.org) (zlib): the app is made with it.
- [moonshine](https://github.com/vrld/moonshine) (MIT): shader effects.

Mu Split isn't made by or affiliated with the LiveSplit team.

## License

[MIT](LICENSE)
