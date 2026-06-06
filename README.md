<div align="center">

# CoolPlan

**On-screen / sound / TTS cooldown reminders for World of Warcraft Mythic+ and raids.**

Plan a team's cooldowns on **[coolplan.team](https://coolplan.team)**, export a string,
import it in game — reminders then fire automatically during the matching boss.

![CoolPlan in game — timeline preview with anticipation countdown](https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/demo.gif)

</div>

## Plan on the web, play in game

| 1 · Plan on [coolplan.team](https://coolplan.team) | 2 · Reminders fire in game |
|:--:|:--:|
| ![Boss timeline on coolplan.team](https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/web-timeline.png) | ![In-combat anticipation HUD](https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/hud-incombat.png) |

The website is the planning tool; this addon is the in-game display. Each player
sees only their own cooldowns — raid-wide defensives and Bloodlust are shown to
everyone.

## How it works

**1. Export from the website.** Open a boss timeline on
[coolplan.team](https://coolplan.team) and click **Export to Addon**. Rename each
player to your real character names so reminders filter to the right person, then
copy the string.

<img src="https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/web-export.png" width="520" alt="Export to Addon dialog on coolplan.team" />

**2. Import in game.** `/coolplan` → **Import / Export** → paste → **Load Plans**.
The plan format is plain text, so you can also hand-edit it in the box.

<img src="https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/import.png" width="620" alt="Import / Export tab in game" />

**3. Pull the boss.** The addon matches the encounter and shows each player their
own cooldowns on an anticipation HUD with a countdown and a smooth depleting bar.

## Features

**Saved plan library** — multiple named plans per boss, a dungeon → boss browser,
Use / Rename / Share / Export per plan, and one-click **Share to party**.

<img src="https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/saved-plans.png" width="620" alt="Saved Plans library" />

**Timeline preview** — scrub the whole plan, zoom/pan, and **Test** playback (1x or
Shift-click 3x) to rehearse before the pull.

<img src="https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/timeline.png" width="620" alt="In-game timeline preview" />

**Fully configurable** — HUD style (icon / icon+name / bar), lead time, position,
scale, font and color; sound **or** TTS alerts with separate timing; an upcoming
queue; per-category show/hide; and an optional boss-ability timeline.

<img src="https://raw.githubusercontent.com/pingping-e/CoolPlan/main/docs/img/options.png" width="620" alt="Options panel" />

Other niceties: a **minimap button** (collects cleanly into MinimapButtonButton /
Titan / etc.) and per-character saved data.

## Slash commands

| Command | What it does |
|---|---|
| `/coolplan` | Open the main window |
| `/coolplan plans` | Saved Plans |
| `/coolplan edit` | Import / Export |
| `/coolplan options` | Options |
| `/coolplan timeline` | Timeline preview |
| `/coolplan share` | Share the active plan to your party |
| `/coolplan test` / `demo` | Preview an alert / a countdown |
| `/coolplan move` / `lock` | Move / lock the HUD frames |
| `/coolplan minimap` | Toggle the minimap button |
| `/coolplan errors` | Show suppressed Lua errors |

## Install

- **CurseForge:** search for **CoolPlan** (recommended — auto-updates).
- **Manual:** download, unzip, and copy the **`CoolPlan`** folder into
  `World of Warcraft/_retail_/Interface/AddOns/`. Restart WoW.

## Notes

- No dependencies — bundles LibStub, LibDataBroker-1.1 and LibDBIcon-1.0 under
  `Libs/` (each under its own license).
- Feedback and bug reports: the Discord linked on [coolplan.team](https://coolplan.team).

## License

MIT — see [LICENSE](LICENSE). Bundled libraries keep their own licenses.
