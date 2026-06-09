-- SavedVariables (CoolPlanDB): a per-encounter LIBRARY of named cooldown plans
-- and options.
--
-- library[encounterID] = {
--   name   = "Boss Name",
--   plans  = { { label="Team A", reminders={...}, boss={...}|nil }, ... },
--   active = <index into plans>,
-- }
--
-- The boss timeline is bound to EACH plan (one body): importing a team plan that
-- carries boss abilities stores them together, and deleting the plan deletes its
-- boss timeline with it. There is no separately-deletable shared boss row.

local _, ns = ...
local DB = {}
ns.DB = DB

-- account-wide defaults (the saved-plan library is per-character; see DB.Init).
local defaults = {
  options = {
    filterToMe = true,
    leadSeconds = 5,          -- on-screen anticipation lead (seconds before cast)
    soundLeadSeconds = 0,     -- sound/TTS lead (seconds before cast) — independent
    textEnabled = true,
    alertSound = "sound",     -- single alert mode: "none" | "sound" | "tts"
    ttsVoice = 0,
    soundKit = "RAID_WARNING",
    countdownVoice = false, -- speak a 3-2-1 TTS countdown before each cue (separate from spell-name TTS)
    scale = 1.0,
    fontSize = 28,
    hudStyle = "icon",        -- "icon" | "iconName" | "bar"
    timePos = "icon",         -- "icon" (inside icon/bar) | "right" (separate, on the right)
    textColor = { r = 1, g = 1, b = 1 },
    showQueue = true,
    queueCount = 2,
    queueWindow = 10,         -- only show queued cues casting within N seconds (10–30)
    categoryEnabled = {},
    hud = { point = "CENTER", relPoint = "CENTER", x = 0, y = 200, locked = true },
    -- queue sits BELOW the HUD, left edges aligned (HUD is 440 wide → left edge
    -- at -220 from screen centre; HUD bottom ≈ y 164, so 150 leaves a small gap).
    queueAnchor = { point = "TOPLEFT", relPoint = "CENTER", x = -220, y = 150, locked = true },
    showGrid = true,          -- show an alignment grid while in move mode
    lastPage = "timeline",
    minimap = { angle = 210, hide = false },
    windowW = 940, windowH = 640,  -- windowW matches Window.lua MIN_W
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

  -- Normalize the library so downstream code (Timeline / Scheduler / Manager)
  -- only ever sees clean data — even from hand-edited or legacy SavedVariables.
  -- Each encounter gets plans{}/numeric active; each plan gets reminders{}; and
  -- any reminder/boss row with a non-numeric timeMs or spellId is dropped (those
  -- would otherwise cause "compare nil with number" / "#nil" / nil-arithmetic).
  for _, e in pairs(CoolPlanCharDB.library) do
    if type(e) == "table" then
      if type(e.plans) ~= "table" then e.plans = {} end
      if type(e.active) ~= "number" then e.active = 0 end
      -- iterate plans in reverse so a non-table plan element (e.g. hand-edited
      -- plans = { 123 }) can be dropped instead of crashing on p.reminders.
      for pi = #e.plans, 1, -1 do
        local p = e.plans[pi]
        if type(p) ~= "table" then
          table.remove(e.plans, pi)
        else
          if type(p.reminders) ~= "table" then p.reminders = {} end
          for i = #p.reminders, 1, -1 do
            local r = p.reminders[i]
            if type(r) ~= "table" or type(r.timeMs) ~= "number" or type(r.spellId) ~= "number" then
              table.remove(p.reminders, i)
            end
          end
          if type(p.boss) == "table" then
            for i = #p.boss, 1, -1 do
              local b = p.boss[i]
              if type(b) ~= "table" or type(b.timeMs) ~= "number" or type(b.spellId) ~= "number" then
                table.remove(p.boss, i)
              end
            end
          end
        end
      end
      if e.active > #e.plans then e.active = #e.plans end
    end
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
  -- Boss mechanics no longer fire as alerts (boss timelines are display-only in
  -- the Timeline view); drop any stale saved option.
  CoolPlanDB.options.showBoss = nil
  -- One-time: apply the recommended default profile to existing installs so
  -- everyone converges on the tuned out-of-box settings once. Frame positions,
  -- minimap and window size are intentionally left untouched. New installs get
  -- these straight from `defaults` above. (Supersedes the earlier per-key
  -- showBoss-off / showQueue-off / category-reset migrations.)
  if not CoolPlanDB._migrDefaultsV2 then
    local opt = CoolPlanDB.options
    opt.textEnabled = true
    opt.filterToMe = true
    opt.alertSound = "sound"
    opt.soundKit = "RAID_WARNING"
    opt.leadSeconds = 5
    opt.soundLeadSeconds = 3
    opt.categoryEnabled = {}
    opt.scale = 1.0
    opt.fontSize = 28
    opt.hudStyle = "iconName"
    opt.timePos = "icon"
    opt.textColor = { r = 1, g = 1, b = 1 }
    opt.showQueue = true
    opt.queueCount = 2
    CoolPlanDB._migrDefaultsV2 = true
  end
  -- One-time: boss timelines were once SHARED at the encounter level. They are
  -- now bound to each plan (one body). Copy any encounter-level boss onto every
  -- plan that lacks one, then drop the shared copy.
  if not CoolPlanDB._migrBossToPlan then
    for _, e in pairs(CoolPlanCharDB.library) do
      if e.boss and #e.boss > 0 then
        for _, p in ipairs(e.plans or {}) do
          if not (p.boss and #p.boss > 0) then p.boss = e.boss end
        end
      end
      e.boss = nil
    end
    CoolPlanDB._migrBossToPlan = true
  end
  DB.data = CoolPlanDB
  return CoolPlanDB
end

function DB.Options() return CoolPlanDB.options end

-- Reset the Options-page settings to defaults. Frame positions, window size,
-- minimap and last page are PRESERVED (the HUD has its own "Reset position"),
-- as is the saved-plan library (per-character, untouched). Caller should
-- ReloadUI afterwards so the Options widgets rebuild against the fresh values.
function DB.ResetOptions()
  local o = CoolPlanDB.options
  if not o then return end
  local keep = {
    hud = o.hud, queueAnchor = o.queueAnchor,
    windowW = o.windowW, windowH = o.windowH,
    minimap = o.minimap, lastPage = o.lastPage,
  }
  if wipe then wipe(o) else for k in pairs(o) do o[k] = nil end end
  deepFill(o, defaults.options)             -- deep-copies every default back in
  o.hud, o.queueAnchor = keep.hud, keep.queueAnchor
  o.windowW, o.windowH = keep.windowW, keep.windowH
  o.minimap, o.lastPage = keep.minimap, keep.lastPage
end
-- Default frame positions (for the "Reset" button), copied so callers can't
-- mutate the shared defaults table.
function DB.DefaultPositions()
  local d = defaults.options
  return
    { point = d.hud.point, relPoint = d.hud.relPoint, x = d.hud.x, y = d.hud.y },
    { point = d.queueAnchor.point, relPoint = d.queueAnchor.relPoint, x = d.queueAnchor.x, y = d.queueAnchor.y }
end
-- Per-character Timeline "Preview as" default: remember the last slot the user
-- picked so the tab doesn't reset to "Everyone" each visit. Stored per character
-- (one name), restored when the note contains that player. "__all__" = Everyone.
function DB.GetTimelinePreviewAs() return CoolPlanCharDB.timelinePreviewAs end
function DB.SetTimelinePreviewAs(v) CoolPlanCharDB.timelinePreviewAs = v end

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

-- Add a plan to an encounter. The boss timeline (if any) is stored ON the plan,
-- so team cooldowns + boss abilities live and die together. Returns the new plan
-- index, or 0 when there was nothing to store.
function DB.AddPlan(id, encName, label, reminders, boss, phases)
  local lib = CoolPlanCharDB.library
  local e = lib[id]
  if not e then
    e = { name = encName or ("Encounter " .. id), plans = {}, active = 0 }
    lib[id] = e
  end
  if encName and encName ~= "" then e.name = encName end

  local hasReminders = reminders and #reminders > 0
  local hasBoss = boss and #boss > 0
  if not hasReminders and not hasBoss then
    return 0 -- nothing to store
  end

  -- De-duplicate the label within THIS encounter, file-copy style: a second
  -- "Speed comp" becomes "Speed comp (2)", a third "(3)", etc. Keeps repeated
  -- shares/imports from silently producing ambiguous same-name rows.
  local label2 = (label and label ~= "" and label) or ("Plan " .. (#e.plans + 1))
  do
    local exists = function(l)
      for _, p in ipairs(e.plans) do if p.label == l then return true end end
      return false
    end
    if exists(label2) then
      local base, n = label2, 1
      repeat n = n + 1; label2 = base .. " (" .. n .. ")" until not exists(label2)
    end
  end

  e.plans[#e.plans + 1] = {
    label = label2,
    reminders = reminders or {},
    boss = hasBoss and boss or nil,
    -- Phase table (phase-gated bosses) — drives the Scheduler's live re-anchoring.
    phases = (phases and #phases > 0) and phases or nil,
  }
  e.active = #e.plans -- newly imported becomes active
  return #e.plans
end

-- index 0 = explicit NONE active: nothing plays on pull (full disarm). A real
-- plan index activates it. A nil / out-of-range index is a NO-OP (keeps the
-- current active) — so a stray bad call can't silently disarm an encounter; only
-- an explicit 0 does.
function DB.SetActive(id, index)
  local e = CoolPlanCharDB.library[id]
  if not e then return end
  if index == 0 then e.active = 0
  elseif index and e.plans[index] then e.active = index end
end

function DB.RenamePlan(id, index, label)
  local e = CoolPlanCharDB.library[id]
  if e and e.plans[index] and label and label ~= "" then e.plans[index].label = label end
end

local function pruneIfEmpty(id, e)
  if #e.plans == 0 then
    CoolPlanCharDB.library[id] = nil
  end
end

function DB.DeletePlan(id, index)
  local e = CoolPlanCharDB.library[id]
  if not e or not e.plans[index] then return end
  table.remove(e.plans, index) -- the plan's boss timeline goes with it (one body)
  -- clamp a dangling active index, but DON'T force-arm plan 1 when active is 0
  -- (none) — the user may have intentionally disarmed the encounter.
  if e.active > #e.plans then e.active = #e.plans end
  pruneIfEmpty(id, e)
end

-- Delete an entire encounter (all its plans + boss timeline) in one go.
-- Returns true if an entry was actually removed.
function DB.DeleteEncounter(id)
  if id == nil or CoolPlanCharDB.library[id] == nil then return false end
  CoolPlanCharDB.library[id] = nil
  return true
end

-- Build a serializable { [id] = { name, reminders, boss } } from the library.
-- onlyId / onlyIndex narrow it to a single encounter / plan (for per-row export).
-- The boss timeline is sourced from the selected plan (it lives on the plan).
function DB.ToSerializable(onlyId, onlyIndex)
  local out = {}
  for id, e in pairs(CoolPlanCharDB.library) do
    if (not onlyId) or id == onlyId then
      local idx = onlyIndex or e.active
      local p = idx and e.plans[idx]   -- nil when disarmed (active == 0) / invalid
      -- skip disarmed encounters entirely instead of emitting an empty plan, so
      -- whole-library export/share doesn't ship (and count) blank entries.
      if p then
        out[id] = { name = e.name, reminders = p.reminders or {}, boss = p.boss, phases = p.phases }
      end
    end
  end
  return out
end
