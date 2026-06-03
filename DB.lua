-- SavedVariables (CoolPlanDB): imported plans keyed by encounterID + options.

local _, ns = ...
local DB = {}
ns.DB = DB

local defaults = {
  plans = {}, -- [encounterID] = { name = "...", reminders = { ... } }
  options = {
    filterToMe = true,   -- only show reminders cast by my character
    leadSeconds = 3,     -- fire N seconds before the scheduled time
    textEnabled = true,  -- on-screen HUD
    soundEnabled = true, -- sound cue
    ttsEnabled = false,  -- text-to-speech
    ttsVoice = 0,        -- C_VoiceChat voice id
    soundKit = "RAID_WARNING",
    scale = 1.0,         -- HUD scale
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
