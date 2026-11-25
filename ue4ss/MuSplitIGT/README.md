# Mu Split IGT — Poppy Playtime: Chapter 4

An in-game speedrun timer that runs inside the game through UE4SS, like SpeedRunIGT for
Minecraft or Menzo's SpeedrunTimer for Hello Neighbor. No LiveSplit, no overlay window.

- IGT and RTA drawn in the game
- Starts by itself; pauses, loading screens and load hitches are taken out of IGT
- Checkpoint and item splits (the same 100 options as the LiveSplit autosplitter), deltas to your PB
- Personal best, best split times, attempts and the last 50 runs, saved next to the mod
- Almost everything is customisable from the in-game menu, and saved

Start / split / load rules come from the LiveSplit autosplitter by **TheDementedSalad & Lox**.
The mod reads the same game values, by name:

| value | where |
|-------|-------|
| current checkpoint | `CheckpointSubsystem.CurrentCheckpointId` |
| items | `Player.InventoryManagerComponent.InventoryList.Items[i].Instance` |
| game paused | `GEngine.TransitionType` and `IsGamePaused` |
| loading | loading-screen widgets, no player controller, and very long frames |

## Install

1. Install [UE4SS](https://github.com/UE4SS-RE/RE-UE4SS/releases) next to `ch4_pro-Win64-Shipping.exe`
   (`...\Playtime_Chapter4\ch4_pro\Binaries\Win64\`).
2. Copy this `MuSplitIGT` folder into `Win64\ue4ss\Mods\`. The empty `enabled.txt` turns it on.
3. Start the game.

## The menu (Tab)

| key | does |
|-----|------|
| ↑ ↓ / PgUp PgDn | move |
| ← → | change the value |
| Enter | open / toggle / do it (actions marked as risky ask twice) |
| Backspace | back a page (closes on the first page) |
| Tab | close (it reopens on the page you left) |

**Display**: main timer IGT or RTA · second timer: **RTA**, **SPLIT** (segment time, resets on
every split) or **Hidden** · labels on/off and their text · status line (LOADING / PAUSED / FINISHED) ·
split ticker (just the latest split; slides in, pops and flashes) · split animations on/off · delta to PB ·
colour the timer by pace · PB line · attempt counter · current checkpoint name · start hint

**Layout & size**: 9 positions · move left/right and up/down in 10 px steps · edge distance ·
alignment · main / other / split / info text sizes · line spacing · font style (regular, bold,
light, italic, bold italic) · outline · shadow, its distance and colour · background box,
colour, opacity, padding and corner rounding · accent bar on/off, colour and width · monospace digits

**Colours** (14-colour palette each): running, not started, finished/new PB, paused, loading,
other timer, splits, ahead, behind, best split, info lines

**Time format**: decimals for the main timer, other timer and splits (0–3) ·
leading zero (`00:00` / `0:00`) · always show hours

**Timer behaviour**: auto start · stop at the final split · reset at the main menu ·
take pauses / loading screens / load hitches (100–600 ms) out of IGT ·
pause the game while the menu is open

**Splits**: all checkpoints on · key items on · all off · the full list in groups
(→ turns a group on, ← off, Enter opens it). "Fallen Down the Hole" is always the last split.

**Keys**: menu, reset, split (or start), pause/resume, hide/show. Pick from Tab, F1–F12,
Insert/Home/End/Delete, Pause, Scroll Lock, \` and the numpad.

**Records**: PB (IGT and RTA), attempts, finished runs, the last 8 runs, clear PB, clear history

**Quick actions** on the first page: reset, start now, pause/resume, finish now, hide/show,
reset all settings.

## Tweaking the look in code

The top of `Scripts/main.lua` has a `THEME` block with the animation timings (slide time and
distance, pop size and time, flash colour) and label dimming. `DEFAULTS` just below has the
first-run values for everything in the menu, including `secondaryMode` ("RTA" / "SPLIT" / "HIDDEN").

## Files it writes (in this folder)

- `settings.lua`: every setting and your chosen splits
- `records.lua`: PB, best split times, attempts, run history

## If something's off

Open `Win64\ue4ss\UE4SS.log` and look for lines starting with `[MuSplitIGT]`.
It logs what it found: `checkpoint: …`, `item id: …`, `pause flag: …`, `loading screen widget: …`.
