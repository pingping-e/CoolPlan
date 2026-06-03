-- Scheduling: on ENCOUNTER_START, build a sorted reminder queue and drive it
-- with a single 0.1s ticker. Each tick computes the imminent alert (within its
-- lead window) + the upcoming queue, and renders an anticipation countdown.

local _, ns = ...
local Scheduler = {}
ns.Scheduler = Scheduler

local LINGER = 1.0

local ticker, pullTime, queue, activeId
-- preview mode: a virtual clock advanced by `speed`x each real tick, with an
-- optional onTick(elapsed, total) callback (used by the Timeline playhead).
local preview = false
local previewClock = 0
local previewSpeed = 1
local previewTotal = 0
local previewOnTick = nil

local function nameMatchesMe(player)
  if not player or player == "" then return true end
  local me = UnitName("player")
  if not me then return true end
  return strlower(player) == strlower(me)
end

local function nowElapsed()
  if preview then return previewClock end
  if not pullTime then return 0 end
  return GetTime() - pullTime
end

local function tick()
  if not queue then return end
  if (not preview) and not pullTime then return end
  local o = ns.DB.Options()
  if preview then previewClock = previewClock + 0.1 * previewSpeed end
  local elapsed = nowElapsed()
  local lead = o.leadSeconds or 4

  local active = nil       -- {reminder, remaining, total}
  local upcoming = {}

  for _, item in ipairs(queue) do
    local remaining = item.castAt - elapsed

    -- audible cue (sound / TTS) fires once when the SOUND lead window opens —
    -- independent of the on-screen lead so audio can lead/trail the visuals.
    if (not item.soundCued) and elapsed >= item.soundAt then
      item.soundCued = true
      ns.Reminders.Cue(item.cue, o)
    end

    if elapsed >= item.showAt and elapsed <= item.castAt + LINGER then
      -- in the anticipation window: nearest cast becomes the big alert,
      -- any others fall into the queue
      if (not active) or remaining < active.remaining then
        if active then upcoming[#upcoming + 1] = { cue = active.cue, remaining = active.remaining } end
        active = { cue = item.cue, remaining = remaining, total = lead }
      else
        upcoming[#upcoming + 1] = { cue = item.cue, remaining = remaining }
      end
    elseif remaining > 0 then
      upcoming[#upcoming + 1] = { cue = item.cue, remaining = remaining }
    end
  end

  table.sort(upcoming, function(a, b) return a.remaining < b.remaining end)
  local cap = o.queueCount or 3
  while #upcoming > cap do table.remove(upcoming) end

  ns.Reminders.RenderTick(active, upcoming, o)

  if preview then
    if previewOnTick then ns.safecall(previewOnTick, elapsed, previewTotal) end
    -- auto-stop a short while past the last cast
    if elapsed > previewTotal + LINGER + 1 then
      Scheduler.Stop()
    end
  end
end

-- Run an arbitrary cue list (already filtered). Returns true if armed.
-- opts (optional): { preview=true, speed=1, onTick=fn } for the live preview.
local function run(cues, opts)
  Scheduler.Stop()
  local o = ns.DB.Options()
  local lead = o.leadSeconds or 4
  local soundLead = o.soundLeadSeconds or 0

  queue = {}
  local maxCast = 0
  for _, c in ipairs(cues) do
    local castAt = c.timeMs / 1000
    if castAt > maxCast then maxCast = castAt end
    queue[#queue + 1] = {
      cue = c,
      castAt = castAt,
      showAt = math.max(0, castAt - lead),      -- on-screen anticipation window
      soundAt = math.max(0, castAt - soundLead), -- audible cue trigger
      soundCued = false,
    }
  end
  if #queue == 0 then return false end
  table.sort(queue, function(a, b) return a.castAt < b.castAt end)

  if opts and opts.preview then
    preview = true
    previewClock = 0
    previewSpeed = opts.speed or 1
    previewTotal = maxCast
    previewOnTick = opts.onTick
    pullTime = nil
  else
    pullTime = GetTime()
  end
  ticker = C_Timer.NewTicker(0.1, ns.wrap(tick))
  return true
end

-- Categories shown to EVERYONE regardless of "only me": raid-wide defensives
-- and healer cooldowns (공생기 & 힐러 쿨기) are group-relevant, so a player
-- should see them even when they belong to someone else. Everything else is
-- filtered to the local character when filterToMe is on.
local ALWAYS_SHOWN = { raid_defensive = true }

-- Build the combined cue list:
--  • cooldowns (kind="cd")  — raid_defensive shown to all; others "only me" + enabled categories
--  • boss mechanics (kind="boss") — only when showBoss (off by default; kept out of alerts)
-- previewAll: the Timeline "Test" is a preview of the whole plan, so it must NOT
-- filter to the logged-in character's name or hide categories — otherwise testing
-- on a different char (or with log/team names that don't match) shows nothing.
local function buildCues(reminders, boss, previewAll)
  local o = ns.DB.Options()
  local cues = {}
  for _, r in ipairs(reminders or {}) do
    local common = ALWAYS_SHOWN[r.category or ""]
    local meOk = previewAll or common or (not o.filterToMe) or nameMatchesMe(r.player)
    if meOk and (previewAll or ns.DB.CategoryEnabled(r.category)) then
      cues[#cues + 1] = {
        kind = "cd", timeMs = r.timeMs, spellId = r.spellId,
        player = r.player, category = r.category, spellName = r.spellName, alert = r.alert,
      }
    end
  end
  if o.showBoss and boss then
    for _, b in ipairs(boss) do
      cues[#cues + 1] = {
        kind = "boss", timeMs = b.timeMs, spellId = b.spellId,
        bossType = b.type, spellName = b.spellName,
      }
    end
  end
  return cues
end

-- Start from the encounter's ACTIVE plan + shared boss timeline.
function Scheduler.Start(encounterID)
  local e = ns.DB.GetEncounter(encounterID)
  if not e then return false end
  local plan = e.plans[e.active]
  local cues = buildCues(plan and plan.reminders or {}, e.boss)
  if #cues == 0 then return false end
  activeId = encounterID
  return run(cues)
end

-- A short synthetic schedule so the user can preview the countdown in town.
function Scheduler.StartDemo()
  local me = UnitName("player")
  local demo = {
    { kind = "cd",   timeMs = 3000,  spellId = 740,   player = me, spellName = "Tranquility" },
    { kind = "boss", timeMs = 6000,  spellId = 100,   bossType = "tank_buster", spellName = "Doom Bolt" },
    { kind = "cd",   timeMs = 8000,  spellId = 48707, player = me, spellName = "Anti-Magic Shell" },
    { kind = "boss", timeMs = 11000, spellId = 101,   bossType = "raid_aoe", spellName = "Shadow Nova" },
    { kind = "cd",   timeMs = 13000, spellId = 31884, player = me, spellName = "Avenging Wrath" },
  }
  activeId = -1
  return run(demo)
end

function Scheduler.Stop()
  if ticker then ticker:Cancel(); ticker = nil end
  queue, pullTime, activeId = nil, nil, nil
  preview, previewClock, previewSpeed, previewTotal, previewOnTick = false, 0, 1, 0, nil
  if ns.Reminders then ns.Reminders.Clear() end
end

-- Live preview of a plan, with no real encounter: virtual clock from 0.
-- `reminders`/`boss` come from a saved note. `speed` (default 1) accelerates
-- the virtual clock. `onTick(elapsed, total)` drives the Timeline playhead.
-- Honors the same filterToMe / category / showBoss options as a real pull.
function Scheduler.StartPreview(reminders, boss, speed, onTick)
  -- Preview honors the live filters (only-my-character + Show categories) so it
  -- shows what you'd actually see in the fight. If that leaves nothing (e.g.
  -- testing on a char whose name isn't in the plan), fall back to the whole plan
  -- so the Test is never a dead end.
  local cues = buildCues(reminders or {}, boss, false)
  if #cues == 0 then cues = buildCues(reminders or {}, boss, true) end
  if #cues == 0 then return false end
  activeId = -2
  return run(cues, { preview = true, speed = speed or 1, onTick = onTick })
end

function Scheduler.IsPreview()
  return preview
end

function Scheduler.IsActive()
  return ticker ~= nil
end

function Scheduler.ActiveEncounter()
  return activeId
end
