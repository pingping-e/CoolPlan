# CoolPlan (WoW addon)

On-screen / sound / TTS cooldown reminders during boss encounters, driven by
plans you export from **[coolplan.team](https://coolplan.team)**.

The website analyzes a Warcraft Logs run and builds a team cooldown timeline.
Click **Export to Addon** on a fight to get a CoolPlan string, paste it into this
addon, and it fires reminders at the right times when you pull the matching boss
(matched by `encounterID` via the `ENCOUNTER_START` event).

> ⚠️ This folder currently lives inside the `team-cooldown-site` repo as a
> temporary home. It is meant to be extracted into its own repo
> (`pingping-e/CoolPlan`) and shipped as a standalone addon.

## Install (manual)

Copy the `coolplan-addon` folder into your WoW AddOns directory, **renaming it to
`CoolPlan`** (the folder name must match the `.toc`):

```
World of Warcraft/_retail_/Interface/AddOns/CoolPlan/
  CoolPlan.toc
  *.lua
```

Then `/reload` or restart the client. If it shows as "out of date", set
`## Interface:` in `CoolPlan.toc` to your client's build (see the number in the
AddOns list), or tick **Load out of date AddOns**.

## Usage

1. On coolplan.team, open a fight timeline and click **Export to Addon**, then
   **Copy String**.
2. In game: `/coolplan edit` → paste into the box → **Load Plans**.
3. Pull the boss. Reminders fire automatically (filtered to your character by
   default).

### Slash commands

| Command | Action |
|---|---|
| `/coolplan` or `/cp` | Open options |
| `/coolplan edit` | Import / Export window |
| `/coolplan list` | List imported plans |
| `/coolplan test` | Fire a test reminder (sound + flash) |
| `/coolplan demo` | Preview the anticipation countdown in town (synthetic plan) |
| `/coolplan move` | Toggle move mode (drag the HUD + queue) |
| `/coolplan lock` | Lock frames and save positions |
| `/coolplan testenc <encounterID>` | Dry-run a stored plan's schedule now |
| `/coolplan stop` | Stop the active schedule |

### Alerts

Each cooldown shows as an **anticipation countdown**: the alert appears `lead`
seconds before the cast with a depleting bar and a `3.. 2.. 1..` number, flips to
**NOW** at the cast time, then clears. An **upcoming queue** lists the next few
cooldowns with their countdowns.

### Options (`/coolplan`)

- **On-screen text / Sound / TTS** — toggle each alert channel independently.
  - **TTS count down** — speak `3.. 2.. 1..` each second instead of announcing once.
- **Only my character** — filter to casts by your character (on by default). Off
  = show the whole team's plan.
- **Lead time** — how many seconds before the cast the alert appears (default 4s).
- **Sound cue** — pick a built-in sound, or set a **custom sound file** path.
- **HUD** — scale, font size, and text color (presets).
- **Upcoming queue** — show/hide and how many entries.
- **Show categories** — hide/show reminders by category (e.g. turn off Offensive).
- **Move frames / Lock** — drag the HUD and queue, then lock to save positions
  (also `/coolplan move` and `/coolplan lock`).
- **Demo countdown** — preview the whole thing in town without a boss.

## Editing plans

The CoolPlan format is human-readable, so the import box **is** the editor — edit
times and spell IDs directly, then **Load Plans** again. **Export All** dumps your
stored plans back out (Ctrl-C to copy), so you can round-trip:
site → addon → tweak in game → export.

## Format (v1)

```
COOLPLAN v1
@meta source=coolplan

[encounter] id=112526; name=Echo of Doragosa
# time | spellId | player | category | spellName | alert
0:08.0|123904|Lavie|offensive|Invoke Niuzao
1:32.5|740|Mistweave|raid_defensive|Tranquility|Tranq for Doom
```

- Line 1 is the magic header `COOLPLAN v1`.
- `#` lines and blanks are ignored; `@meta` holds free-form key=value pairs.
- `[encounter] id=<encounterID>; name=<boss>` starts a section.
- Each reminder row is pipe-delimited: `time | spellId | player | category? |
  spellName? | alert?`. Time is `M:SS.T` relative to the encounter pull (plain
  seconds like `92.5` are also accepted when hand-editing).

The canonical spec and a matching TypeScript implementation live in the website
repo at `lib/export/coolplan-format.ts`; `Format.lua` here is a byte-compatible
mirror (verified against the same fixtures).

## Files

| File | Responsibility |
|---|---|
| `Core.lua` | Lifecycle, encounter events, slash commands |
| `Format.lua` | Parse / serialize the v1 format (mirrors the TS module) |
| `DB.lua` | SavedVariables (`CoolPlanDB`): plans + options |
| `Scheduler.lua` | `ENCOUNTER_START` → sorted reminder queue via `C_Timer` ticker |
| `Reminders.lua` | HUD frame + sound + TTS |
| `Editor.lua` | Import / Export window |
| `Options.lua` | Options window |
| `EncounterNames.lua` | Generated `encounterID → name` fallback table |

`EncounterNames.lua` is generated from the site catalogs by
`scripts/gen-addon-encounter-names.ts` (run `pnpm tsx
scripts/gen-addon-encounter-names.ts` in the website repo).
