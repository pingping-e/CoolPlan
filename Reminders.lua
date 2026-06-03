-- Reminder rendering: on-screen HUD + sound + TTS. Raw frame (no libs) so the
-- combat HUD stays lightweight and fully controllable.

local _, ns = ...
local Reminders = {}
ns.Reminders = Reminders

local hud

local function spellInfo(spellId)
  local name, icon
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellId)
    if info then name = info.name; icon = info.iconID end
  end
  if (not name) and _G.GetSpellInfo then
    local n, _, ic = _G.GetSpellInfo(spellId)
    name = n; icon = icon or ic
  end
  if (not icon) and C_Spell and C_Spell.GetSpellTexture then
    icon = C_Spell.GetSpellTexture(spellId)
  end
  return name, icon
end

local function ensureHud()
  if hud then return hud end
  hud = CreateFrame("Frame", "CoolPlanHUD", UIParent)
  hud:SetSize(420, 64)
  hud:SetPoint("CENTER", UIParent, "CENTER", 0, 200)
  hud:SetFrameStrata("HIGH")

  hud.icon = hud:CreateTexture(nil, "ARTWORK")
  hud.icon:SetSize(48, 48)
  hud.icon:SetPoint("LEFT", hud, "LEFT", 0, 0)
  hud.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  hud.text = hud:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  hud.text:SetPoint("LEFT", hud.icon, "RIGHT", 12, 0)
  hud.text:SetTextColor(1, 0.95, 0.4)

  hud.anim = hud:CreateAnimationGroup()
  local fade = hud.anim:CreateAnimation("Alpha")
  fade:SetFromAlpha(1)
  fade:SetToAlpha(0)
  fade:SetDuration(0.5)
  fade:SetStartDelay(2.2)
  hud.anim:SetScript("OnFinished", function() hud:Hide() end)

  hud:Hide()
  return hud
end

-- reminder = { spellId, player?, category?, spellName?, alert? }
-- opts     = DB.Options()
function Reminders.Fire(reminder, opts)
  local name, icon = spellInfo(reminder.spellId)
  local label = reminder.alert
  if not label or label == "" then
    label = name or reminder.spellName or ("Spell " .. tostring(reminder.spellId))
  end

  if opts.textEnabled then
    local f = ensureHud()
    f:SetScale(opts.scale or 1)
    if icon then f.icon:SetTexture(icon); f.icon:Show() else f.icon:Hide() end
    f.text:SetText(label)
    f:Show()
    f:SetAlpha(1)
    f.anim:Stop()
    f.anim:Play()
  end

  if opts.soundEnabled then
    local kit = SOUNDKIT and SOUNDKIT[opts.soundKit or "RAID_WARNING"]
    if kit then PlaySound(kit, "Master") end
  end

  if opts.ttsEnabled and C_VoiceChat and C_VoiceChat.SpeakText and Enum and Enum.VoiceTtsDestination then
    C_VoiceChat.SpeakText(opts.ttsVoice or 0, label, Enum.VoiceTtsDestination.LocalPlayback, 0, 100)
  end
end

function Reminders.Hide()
  if hud then hud.anim:Stop(); hud:Hide() end
end

function Reminders.Test()
  Reminders.Fire({ spellId = 740, alert = "CoolPlan test" }, ns.DB.Options())
end
