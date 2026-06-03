-- SavedVariables (CoolPlanDB): a per-encounter LIBRARY of named cooldown plans
-- plus a shared boss timeline, and options.
--
-- library[encounterID] = {
--   name   = "Boss Name",
--   boss   = { {timeMs, spellId, type, spellName}, ... } | nil,   -- shared, layered
--   plans  = { { label = "Team A", reminders = { ... } }, ... },  -- multiple
--   active = <index into plans>,
-- }

local _, ns = ...
local DB = {}
ns.DB = DB

-- account-wide defaults (the saved-plan library is per-character; see DB.Init).
local defaults = {
  options = {
    filterToMe = true,
    leadSeconds = 4,          -- on-screen anticipation lead (seconds before cast)
    soundLeadSeconds = 0,     -- sound/TTS lead (seconds before cast) — independent
    textEnabled = true,
    alertSound = "sound",     -- single alert mode: "none" | "sound" | "tts"
    ttsVoice = 0,
    soundKit = "RAID_WARNING",
    showBoss = false, -- boss mechanics kept OUT of on-screen alerts by default
    scale = 1.0,
    fontSize = 28,
    hudStyle = "iconName",    -- "icon" | "iconName" | "bar"
    timePos = "icon",         -- "icon" (inside icon/bar) | "right" (separate, on the right)
    textColor = { r = 1, g = 0.95, b = 0.4 },
    showQueue = false,
    queueCount = 3,
    categoryEnabled = {},
    hud = { point = "CENTER", relPoint = "CENTER", x = 0, y = 200, locked = true },
    queueAnchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = 60, locked = true },
    lastPage = "timeline",
    minimap = { angle = 210, hide = false },
    windowW = 860, windowH = 640,
  },
}

local function deepFill(dst, src)
  for k, v in pairs(src) do
    if type(v) == "table" then
      if type(dst[k]) ~= "table" then dst[k] = {} end
      deepFill(dst[k], v)
    elseif dst[k] == nil then
      dst[k] = v
    end
  end
end

function DB.Init()
  CoolPlanDB = CoolPlanDB or {}        -- account-wide: options
  CoolPlanCharDB = CoolPlanCharDB or {} -- PER CHARACTER: the saved-plan library
  CoolPlanCharDB.library = CoolPlanCharDB.library or {}

  -- legacy: the very old single-plan-per-encounter storage → library
  if CoolPlanDB.plans then
    for id, p in pairs(CoolPlanDB.plans) do
      CoolPlanCharDB.library[id] = CoolPlanCharDB.library[id] or {
        name = p.name,
        boss = p.boss,
        plans = { { label = "Imported", reminders = p.reminders or {} } },
        active = 1,
      }
    end
    CoolPlanDB.plans = nil
  end

  -- Notes are now PER CHARACTER. Move a pre-existing ACCOUNT-wide library onto
  -- this character once (the char you imported on keeps the data; other chars
  -- start empty). Done a single time, then the account copy is dropped.
  if CoolPlanDB.library and not CoolPlanDB._libToChar then
    if next(CoolPlanCharDB.library) == nil then
      CoolPlanCharDB.library = CoolPlanDB.library
    end
    CoolPlanDB.library = nil
    CoolPlanDB._libToChar = true
  end
  -- One-time: derive the new single alert mode from the OLD soundEnabled/
  -- ttsEnabled checkboxes (run BEFORE deepFill so we read the user's old values,
  -- not freshly-filled defaults). TTS wins, then explicit sound-off → none.
  local opt = CoolPlanDB.options
  if opt and not CoolPlanDB._migrAlertSound then
    if opt.alertSound == nil then
      if opt.ttsEnabled then
        opt.alertSound = "tts"
      elseif opt.soundEnabled == false then
        opt.alertSound = "none"
      else
        opt.alertSound = "sound"
      end
    end
    -- retire the removed options so stale values can't resurface
    opt.soundEnabled = nil
    opt.ttsEnabled = nil
    opt.ttsCountdown = nil
    opt.customSound = nil
    CoolPlanDB._migrAlertSound = true
  end

  deepFill(CoolPlanDB, defaults)
  -- One-time: boss mechanics are now OFF by default in on-screen alerts. Flip an
  -- existing saved 'true' once (users can re-enable via Options afterwards).
  if not CoolPlanDB._migrShowBossOff then
    CoolPlanDB.options.showBoss = false
    CoolPlanDB._migrShowBossOff = true
  end
  -- One-time: the upcoming queue is now OFF by default. Flip an existing saved
  -- 'true' once (users can re-enable via Options afterwards).
  if not CoolPlanDB._migrShowQueueOff then
    CoolPlanDB.options.showQueue = false
    CoolPlanDB._migrShowQueueOff = true
  end
  DB.data = CoolPlanDB
  return CoolPlanDB
end

function DB.Options() return CoolPlanDB.options end
function DB.Library() return CoolPlanCharDB.library end
function DB.GetEncounter(id) return CoolPlanCharDB.library[id] end

function DB.ActiveReminders(id)
  local e = CoolPlanCharDB.library[id]
  if not e then return nil end
  local p = e.plans[e.active]
  return p and p.reminders or {}
end

-- A category is shown unless explicitly disabled.
function DB.CategoryEnabled(category)
  if not category or category == "" then return true end
  return CoolPlanDB.options.categoryEnabled[category] ~= false
end

-- Add a plan to an encounter (or just refresh the boss timeline). Returns the
-- new plan index, or 0 when the import was a boss-timeline-only payload.
function DB.AddPlan(id, encName, label, reminders, boss)
  local lib = CoolPlanCharDB.library
  local e = lib[id]
  if not e then
    e = { name = encName or ("Encounter " .. id), boss = nil, plans = {}, active = 0 }
    lib[id] = e
  end
  if encName and encName ~= "" then e.name = encName end
  if boss and #boss > 0 then e.boss = boss end -- update boss; else keep existing

  if (not reminders or #reminders == 0) and boss and #boss > 0 then
    return 0 -- boss-only import: refreshed boss timeline, no plan added
  end

  e.plans[#e.plans + 1] = {
    label = (label and label ~= "" and label) or ("Plan " .. (#e.plans + 1)),
    reminders = reminders or {},
  }
  e.active = #e.plans -- newly imported becomes active
  return #e.plans
end

function DB.SetActive(id, index)
  local e = CoolPlanCharDB.library[id]
  if e and e.plans[index] then e.active = index end
end

function DB.RenamePlan(id, index, label)
  local e = CoolPlanCharDB.library[id]
  if e and e.plans[index] and label and label ~= "" then e.plans[index].label = label end
end

local function pruneIfEmpty(id, e)
  if #e.plans == 0 and not (e.boss and #e.boss > 0) then
    CoolPlanCharDB.library[id] = nil
  end
end

function DB.DeletePlan(id, index)
  local e = CoolPlanCharDB.library[id]
  if not e or not e.plans[index] then return end
  table.remove(e.plans, index)
  if e.active > #e.plans then e.active = #e.plans end
  if e.active < 1 and #e.plans > 0 then e.active = 1 end
  pruneIfEmpty(id, e)
end

function DB.DeleteBoss(id)
  local e = CoolPlanCharDB.library[id]
  if not e then return end
  e.boss = nil
  pruneIfEmpty(id, e)
end

-- Build a serializable { [id] = { name, reminders, boss } } from the library.
-- onlyId / onlyIndex narrow it to a single encounter / plan (for per-row export).
function DB.ToSerializable(onlyId, onlyIndex)
  local out = {}
  for id, e in pairs(CoolPlanCharDB.library) do
    if (not onlyId) or id == onlyId then
      local idx = onlyIndex or e.active
      local p = e.plans[idx]
      out[id] = { name = e.name, reminders = (p and p.reminders) or {}, boss = e.boss }
    end
  end
  return out
end
