# Developing Mu Split

How it fits together, how to build it, and the engine protocol. For what Mu Split is, see the [README](../README.md).

Mu Split is two programs: the app you see (Love2D) and **MuSplitEngine.exe**, our own small
engine with no window. The engine is built on LiveSplit's open-source libraries (MIT), so timing,
.lss files and every ASL/DLL/WebAssembly autosplitter behave exactly like LiveSplit, but
LiveSplit itself is never started.

```
MuSplitEngine.exe (no window)                 Mu Split (Love2D)
  LiveSplit.Core + autosplitter components
  └ Mu Split Bridge  ── state 20x/s + events ──▶  timer, splits, menus, editors
     127.0.0.1:16850 ◀── commands / edits ──────
```

## Build

Needs Windows and the [.NET SDK](https://dotnet.microsoft.com/download). Then double-click **`build.bat`**.
First run downloads LiveSplit (only for its libraries) and LÖVE into `vendor\` and puts the app in `dist\`:

```
dist\
  MuSplit.exe      run this
  *.dll            LÖVE runtime
  engine\          MuSplitEngine.exe, LiveSplit's libraries and components, settings.cfg, engine.log
```

Your old `dist\LiveSplit\settings.cfg` (hotkeys, recent splits) is carried over on the first build.

## Using it

Right-click anywhere for the menu. It has what LiveSplit's menu has:

- **Edit Splits…**: game, category, attempts, offset, real/game time, the split table
  (PB split, PB segment, gold, your own comparisons), insert/remove/move, add/rename/remove
  comparisons, clear history/times, and turning the autosplitter on
- **Open Splits** (recent files + From File…), **Save**, **Save As…**, **Close**
- **Control**: start/split, reset, undo, skip, pause, undo all pauses, global hotkeys, hotkey profile
- **Compare Against**: every comparison, real time / game time
- **Autosplitter Settings…**: Start/Split/Reset and the script's own options tree
- **Settings…**: hotkey profiles and hotkeys, global hotkeys, double tap prevention, hotkey delay,
  reset warning, sum of best, refresh rate, generated comparisons

All the editing runs inside LiveSplit itself, ported from LiveSplit's own code (fixing splits after
edits, merging history when a split is removed, etc.), so your .lss files come out the same.
The "save splits?" / "update times?" / "save as PB?" prompts are the same ones LiveSplit asks.

Hotkeys: with global hotkeys on, LiveSplit catches them directly. With them off, Mu Split
forwards your hotkeys while its window has focus.

## Folders

| folder    | what it is |
|-----------|------------|
| `engine/` | MuSplitEngine.exe: an invisible stand-in for LiveSplit's main window (settings, open/save, comparisons, autosplitter, global hotkeys). Compiles `bridge/` in |
| `bridge/` | the protocol server and all the editing logic (still works as a LiveSplit plugin too) |
| `love/`   | the app |
| `mock/`   | Python fake LiveSplit, for working on the UI on any OS |

In `love/`:

| file | what it does |
|------|--------------|
| `theme.lua` | turns a *look* (colours, background, fonts, sizes, layout, effects) into what the UI draws with; colours glide when it changes |
| `presets.lua` | the 12 built-in looks, your saved ones (`%APPDATA%\LOVE\musplit\presets`), copy/paste sharing, the look in use |
| `customwindow.lua` | **Customise Look…** (right-click menu or F1): looks gallery, quick accent, every setting, live animated preview |
| `widgets.lua` | sliders, switches, colour picker, tabs, cards |
| `postfx.lua` | shader effects over the timer (bloom, light rays, grain, chromatic aberration, CRT, scanlines, pixelate, posterize, Game Boy) via [moonshine](https://github.com/vrld/moonshine) (MIT), which build.bat downloads into `love\moonshine` |
| `timerview.lua` | the timer + split list (aurora backgrounds, rolling digits, gliding highlight, split pops, sparks, confetti), the smooth clock, and the demo run used by the preview |
| `ui.lua` | widgets: button, text box, checkbox, dropdown, hotkey box, scroll area |
| `menu.lua` | right-click menu |
| `editor.lua`, `settingswindow.lua`, `aslwindow.lua` | the windows |
| `dialogs.lua` | prompts and input boxes |
| `main.lua` | wires it together: menu contents, save/open/reset flow, hotkeys |
| `net.lua`, `launcher.lua`, `filedialog.lua` | bridge connection, starting LiveSplit, Windows file dialogs |

For development: run `build.bat` once, then `love love` launches the same way.
Headless UI test (any LuaJIT, e.g. TeX Live's `texluajit`): `texluajit tests/test_ui.lua` from this folder.
To work on the UI without LiveSplit: `python mock\mock_bridge.py --auto`, then `love love`.

## Protocol

Commands (one per line, argument after a space, JSON where noted):

`start` `split` `splitorstart` `undo` `skip` `pause` `undo_pauses` `reset` `reset_discard`
`timing [real|game]` `compare <name>` `compare_next` `compare_prev` `global_hotkeys` `profile <name>`
`open <path>` `save [path]` `save_pb` `discard_changes` `close` `menu`
`editor_begin` `editor_op {json}` `editor_ok` `editor_cancel`
`asl_toggle [game]` `asl_get` `asl_set {json}` `asl_native`
`settings_get` `settings_apply {json}` `hotkeys_suspend` `hotkeys_resume`
`window hide|show` `quit` `ping`

Messages back are JSON objects with a `type`: `state` (20x/s and on every change), `menu`, `editor`,
`asl`, `settings`, `result`. Times are milliseconds or `null`.

## Also

- Races: `love/race.lua`, `racewindow.lua`, `racenet.lua`; the server is `server/worker.js` (Cloudflare Worker); the engine side is `engine/RaceRelay.cs` (127.0.0.1:16851)
- Discord status: `love/discordrpc.lua`, `engine/DiscordPresence.cs`
- Linux: `love/linux.lua`, `linuxwindow.lua`, `steam.lua`, `engine/EngineLinux.cs`, [README-linux.md](../README-linux.md)
- Tests: `texluajit tests/test_ui.lua` (UI, headless) and `node tests/test_worker.mjs server/worker.js` (race server)

## Not done yet

- Speedrun.com game/category lookup, icons, run history and metadata tabs in the editor
- Layout settings (Mu Split's look lives in `theme.lua` instead)
