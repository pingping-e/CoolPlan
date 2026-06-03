-- SavedVariables (CoolPlanDB): imported plans keyed by encounterID + options.

local _, ns = ...
local DB = {}
ns.DB = DB

local defaults = {
  plans = {}, -- [encounterID] = { name = "...", reminders = { ... } }
  options = {
    filterToMe = true,    -- only show reminders cast by my character
    leadSeconds = 4,      -- anticipation window: alert appears N seconds before the cast
    textEnabled = true,   -- on-screen HUD
    soundEnabled = true,  -- sound cue when an alert appears
    ttsEnabled = false,   -- text-to-speech
    ttsCountdown = false, -- speak "3.. 2.. 1.." each second (vs announce once)
    ttsVoice = 0,         -- C_VoiceChat voice id
    soundKit = "RAID_WARNING",
    customSound = "",     -- file path; overrides soundKit when non-empty

    -- HUD appearance
    scale = 1.0,
    fontSize = 28,
    textColor = { r = 1, g = 0.95, b = 0.4 },

    -- upcoming-reminders queue
    showQueue = true,
    queueCount = 3,

    -- category gating: [category] = false hides those reminders (nil/true = show)
    categoryEnabled = {},

    -- saved frame placement (relative to UIParent); locked = not draggable
    hud = { point = "CENTER", relPoint = "CENTER", x = 0, y = 200, locked = true },
    queueAnchor = { point = "CENTER", relPoint = "CENTER", x = 0, y = 60, locked = true },
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
  CoolPlanDB = CoolPlanDB or {}
  deepFill(CoolPlanDB, defaults)
  DB.data = CoolPlanDB
  return CoolPlanDB
end

function DB.Options()
  return CoolPlanDB.options
end

function DB.Plans()
  return CoolPlanDB.plans
end

-- A category is shown unless explicitly disabled.
function DB.CategoryEnabled(category)
  if not category or category == "" then return true end
  local v = CoolPlanDB.options.categoryEnabled[category]
  return v ~= false
end
