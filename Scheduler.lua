-- Scheduling: on ENCOUNTER_START, build a sorted reminder queue and drive it
-- with a single 0.1s ticker. Each tick computes the imminent alert (within its
-- lead window) + the upcoming queue, and renders an anticipation countdown.

local _, ns = ...
local Scheduler = {}
ns.Scheduler = Scheduler

local LINGER = 1.0

local ticker, pullTime, queue, activeId

local function nameMatchesMe(player)
  if not player or player == "" then return true end
  local me = UnitName("player")
  if not me then return true end
  return strlower(player) == strlower(me)
end

local function tick()
  local o = ns.DB.Options()
  local elapsed = GetTime() - pullTime
  local lead = o.leadSeconds or 4

  local active = nil       -- {reminder, remaining, total}
  local upcoming = {}

  for _, item in ipairs(queue) do
    local remaining = item.castAt - elapsed

    -- appear cue (sound + announce) once when the window opens
    if (not item.cued) and elapsed >= item.showAt then
      item.cued = true
      ns.Reminders.Cue(item.reminder, o)
    end

    -- per-second TTS countdown
    if o.ttsEnabled and o.ttsCountdown and elapsed >= item.showAt and remaining > 0 then
      local sec = math.ceil(remaining)
      if item.lastCount ~= sec then
        item.lastCount = sec
        ns.Reminders.SpeakCount(sec, o)
      end
    end

    if elapsed >= item.showAt and elapsed <= item.castAt + LINGER then
      -- in the anticipation window: nearest cast becomes the big alert,
      -- any others fall into the queue
      if (not active) or remaining < active.remaining then
        if active then upcoming[#upcoming + 1] = { reminder = active.reminder, remaining = active.remaining } end
        active = { reminder = item.reminder, remaining = remaining, total = lead }
      else
        upcoming[#upcoming + 1] = { reminder = item.reminder, remaining = remaining }
      end
    elseif remaining > 0 then
      upcoming[#upcoming + 1] = { reminder = item.reminder, remaining = remaining }
    end
  end

  table.sort(upcoming, function(a, b) return a.remaining < b.remaining end)
  local cap = o.queueCount or 3
  while #upcoming > cap do table.remove(upcoming) end

  ns.Reminders.RenderTick(active, upcoming, o)
end

-- Run an arbitrary reminder list (already filtered). Returns true if armed.
local function run(reminders)
  Scheduler.Stop()
  local o = ns.DB.Options()
  local lead = o.leadSeconds or 4

  queue = {}
  for _, r in ipairs(reminders) do
    local castAt = r.timeMs / 1000
    queue[#queue + 1] = {
      reminder = r,
      castAt = castAt,
      showAt = math.max(0, castAt - lead),
      cued = false,
      lastCount = nil,
    }
  end
  if #queue == 0 then return false end
  table.sort(queue, function(a, b) return a.castAt < b.castAt end)

  pullTime = GetTime()
  ticker = C_Timer.NewTicker(0.1, tick)
  return true
end

-- Filter a plan's reminders by "only me" + enabled categories.
local function filterReminders(plan)
  local o = ns.DB.Options()
  local out = {}
  for _, r in ipairs(plan.reminders) do
    local meOk = (not o.filterToMe) or nameMatchesMe(r.player)
    local catOk = ns.DB.CategoryEnabled(r.category)
    if meOk and catOk then out[#out + 1] = r end
  end
  return out
end

-- Start from a stored plan. Returns true if at least one reminder was armed.
function Scheduler.Start(encounterID)
  local plan = ns.DB.Plans()[encounterID]
  if not plan then return false end
  local reminders = filterReminders(plan)
  if #reminders == 0 then return false end
  activeId = encounterID
  return run(reminders)
end

-- A short synthetic schedule so the user can preview the countdown in town.
function Scheduler.StartDemo()
  local now = 0
  local demo = {
    { timeMs = 3000,  spellId = 740,    player = UnitName("player"), spellName = "Tranquility", category = "raid_defensive" },
    { timeMs = 8000,  spellId = 48707,  player = UnitName("player"), spellName = "Anti-Magic Shell", category = "personal_defensive" },
    { timeMs = 13000, spellId = 31884,  player = UnitName("player"), spellName = "Avenging Wrath", category = "offensive" },
  }
  activeId = -1
  return run(demo)
end

function Scheduler.Stop()
  if ticker then ticker:Cancel(); ticker = nil end
  queue, pullTime, activeId = nil, nil, nil
  if ns.Reminders then ns.Reminders.Clear() end
end

function Scheduler.IsActive()
  return ticker ~= nil
end

function Scheduler.ActiveEncounter()
  return activeId
end
