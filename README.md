# CoolPlan

On-screen / sound / TTS **cooldown reminders** for World of Warcraft Mythic+ and
raid encounters. Companion addon to **[coolplan.team](https://coolplan.team)** —
plan a team's cooldowns on the website, export a string, import it here, and the
reminders fire automatically during the matching boss.

## How it works

1. On [coolplan.team](https://coolplan.team), open a boss timeline and click
   **Export to Addon**. Rename each player to your real character names (so
   reminders filter to the right person), then copy the string.
2. In game: `/coolplan` → **Import / Export** tab → paste → **Load Plans**.
3. Pull that boss. The addon matches the encounter and shows each player only
   their own cooldowns (raid-wide defensives are shown to everyone).

The plan format is plain text, so you can also hand-edit it in the box.

## Features

- **Anticipation HUD** — icon / icon+name / bar styles, with a countdown and a
  smooth depleting bar; configurable lead time, position, scale, font and color.
- **Sound or TTS** alerts, with separate timing from the on-screen display.
- **Upcoming queue** of the next few cooldowns.
- **Boss ability timeline** (optional) layered onto the same countdown.
- **Per-character saved plans** with a named library (multiple plans per boss),
  a dungeon → boss browser, and a timeline preview with a "Test" playback.
- **Share to party** — broadcast the active plan to party members in one click.
- **Minimap button** (collects cleanly into MinimapButtonButton / Titan / etc).

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
- The website is the planning tool; this addon is the in-game display. Feedback
  and bug reports: the Discord linked on coolplan.team.

## License

MIT — see [LICENSE](LICENSE). Bundled libraries keep their own licenses.
