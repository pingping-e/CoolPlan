-- Scheduling: on ENCOUNTER_START, build a sorted reminder queue and drive it
-- with a single 0.1s ticker comparing elapsed time against each fire time.

local _, ns = ...
local Scheduler = {}
ns.Scheduler = Scheduler

local ticker, pullTime, queue, activeId

local function nameMatchesMe(player)
  if not player or player == "" then return true end
  local me = UnitName("player")
  if not me then return true end
  return strlower(player) == strlower(me)
end

-- Returns true if at least one reminder was armed.
function Scheduler.Start(encounterID)
  Scheduler.Stop()

  local plan = ns.DB.Plans()[encounterID]
  if not plan then return false end

  local opts = ns.DB.Options()
  local lead = opts.leadSeconds or 0

  queue = {}
  for _, r in ipairs(plan.reminders) do
    if (not opts.filterToMe) or nameMatchesMe(r.player) then
      queue[#queue + 1] = {
        fireAt = math.max(0, r.timeMs / 1000 - lead),
        reminder = r,
        fired = false,
      }
    end
  end
  if #queue == 0 then return false end
  table.sort(queue, function(a, b) return a.fireAt < b.fireAt end)

  activeId = encounterID
  pullTime = GetTime()
  ticker = C_Timer.NewTicker(0.1, function()
    local elapsed = GetTime() - pullTime
    for _, item in ipairs(queue) do
      if (not item.fired) and elapsed >= item.fireAt then
        item.fired = true
        ns.Reminders.Fire(item.reminder, opts)
      end
    end
  end)

  return true
end

function Scheduler.Stop()
  if ticker then ticker:Cancel(); ticker = nil end
  queue, pullTime, activeId = nil, nil, nil
  if ns.Reminders then ns.Reminders.Hide() end
end

function Scheduler.IsActive()
  return ticker ~= nil
end

function Scheduler.ActiveEncounter()
  return activeId
end
