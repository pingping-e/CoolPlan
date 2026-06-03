-- Reminder rendering: anticipation HUD (icon + name + countdown + depleting
-- bar) and an upcoming-reminders queue. Raw frames (no libs) so the combat HUD
-- stays lightweight. Both frames are movable/lockable with saved positions.

local _, ns = ...
local Reminders = {}
ns.Reminders = Reminders

local LINGER = 1.0 -- seconds to keep showing an alert after its cast time

local hud, queue
local moverOn = false
local testTicker

-- ── spell info ───────────────────────────────────────────────────────────────
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

local function labelFor(reminder)
  local name = spellInfo(reminder.spellId)
  if reminder.alert and reminder.alert ~= "" then return reminder.alert end
  return name or reminder.spellName or ("Spell " .. tostring(reminder.spellId))
end

-- ── placement helpers ──────────────────────────────────────────────────────────
local function restorePosition(frame, saved)
  frame:ClearAllPoints()
  frame:SetPoint(saved.point or "CENTER", UIParent, saved.relPoint or "CENTER",
    saved.x or 0, saved.y or 0)
end

local function savePosition(frame, saved)
  local point, _, relPoint, x, y = frame:GetPoint(1)
  saved.point = point or "CENTER"
  saved.relPoint = relPoint or "CENTER"
  saved.x = x or 0
  saved.y = y or 0
end

local function makeMovable(frame, saved)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self)
    if not saved.locked then self:StartMoving() end
  end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    savePosition(self, saved)
  end)
end

-- ── frame construction ──────────────────────────────────────────────────────────
local function buildHud()
  local f = CreateFrame("Frame", "CoolPlanHUD", UIParent, "BackdropTemplate")
  f:SetSize(440, 72)
  f:SetFrameStrata("HIGH")

  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bg:SetColorTexture(0, 0, 0, 0.35)
  f.bg:Hide()

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(52, 52)
  f.icon:SetPoint("LEFT", f, "LEFT", 6, 0)
  f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  f.count = f:CreateFontString(nil, "OVERLAY")
  f.count:SetPoint("CENTER", f.icon, "CENTER", 0, 0)

  f.name = f:CreateFontString(nil, "OVERLAY")
  f.name:SetPoint("LEFT", f.icon, "RIGHT", 12, 6)

  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetPoint("LEFT", f.icon, "RIGHT", 12, -16)
  f.bar:SetSize(340, 12)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetMinMaxValues(0, 1)
  f.bar:SetValue(1)
  f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
  f.bar.bg:SetAllPoints()
  f.bar.bg:SetColorTexture(0, 0, 0, 0.5)

  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOM", f, "TOP", 0, 2)
  f.label:SetText("CoolPlan alert")
  f.label:Hide()

  f:EnableMouse(false)
  f:Hide()
  return f
end

local function buildQueue()
  local f = CreateFrame("Frame", "CoolPlanQueue", UIParent, "BackdropTemplate")
  f:SetSize(240, 80)
  f:SetFrameStrata("MEDIUM")

  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  f.bg:SetColorTexture(0, 0, 0, 0.35)
  f.bg:Hide()

  f.header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.header:SetPoint("TOPLEFT", 4, -2)
  f.header:SetText("Next up")

  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOM", f, "TOP", 0, 2)
  f.label:SetText("CoolPlan queue")
  f.label:Hide()

  f.rows = {}
  f:EnableMouse(false)
  f:Hide()
  return f
end

local function ensureFrames()
  if hud then return end
  hud = buildHud()
  queue = buildQueue()
end

function Reminders.Init()
  ensureFrames()
  Reminders.ApplyOptions()
end

-- ── apply options (scale / font / color / positions / lock / queue rows) ───────
function Reminders.ApplyOptions()
  ensureFrames()
  local o = ns.DB.Options()
  local fontPath = GameFontNormalHuge:GetFont()
  local size = o.fontSize or 28
  local c = o.textColor or { r = 1, g = 0.95, b = 0.4 }

  hud:SetScale(o.scale or 1)
  hud.name:SetFont(fontPath, size, "OUTLINE")
  hud.name:SetTextColor(c.r, c.g, c.b)
  hud.count:SetFont(fontPath, size + 10, "OUTLINE")
  hud.count:SetTextColor(1, 1, 1)
  hud.bar:SetStatusBarColor(c.r, c.g, c.b)
  restorePosition(hud, o.hud)
  restorePosition(queue, o.queueAnchor)

  -- (re)build queue rows to match queueCount
  local n = o.queueCount or 3
  for i = 1, n do
    if not queue.rows[i] then
      local fs = queue:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
      fs:SetPoint("TOPLEFT", 4, -2 - i * 16)
      fs:SetJustifyH("LEFT")
      queue.rows[i] = fs
    end
  end
  for i = n + 1, #queue.rows do
    queue.rows[i]:SetText("")
    queue.rows[i]:Hide()
  end
  queue:SetHeight(20 + n * 16)

  if not moverOn then Reminders.SetLocked(true) end -- keep mover mode intact
end

-- ── lock / mover ────────────────────────────────────────────────────────────────
function Reminders.SetLocked(locked)
  ensureFrames()
  local o = ns.DB.Options()
  o.hud.locked = locked
  o.queueAnchor.locked = locked
  hud:EnableMouse(not locked)
  queue:EnableMouse(not locked)
  if locked then
    moverOn = false
    if not (hud._active) then hud:Hide() end
    hud.bg:Hide(); hud.label:Hide()
    queue.bg:Hide(); queue.label:Hide()
    if not queue._live then queue:Hide() end
  end
end

function Reminders.ToggleMover()
  ensureFrames()
  moverOn = not moverOn
  local o = ns.DB.Options()
  if moverOn then
    o.hud.locked = false
    o.queueAnchor.locked = false
    hud:EnableMouse(true)
    queue:EnableMouse(true)
    -- show samples so they can be dragged
    if hud.icon then hud.icon:SetTexture(136235) end -- generic icon
    hud.name:SetText("Cooldown name")
    hud.count:SetText("3")
    hud.bar:SetValue(0.6)
    hud.bg:Show(); hud.label:Show(); hud:Show(); hud._active = true
    queue.rows[1] = queue.rows[1]
    if queue.rows[1] then queue.rows[1]:SetText("|cffaaaaaa0:18  Next cooldown (in 12s)|r"); queue.rows[1]:Show() end
    queue.bg:Show(); queue.label:Show(); queue:Show(); queue._live = true
    ns.Print("move mode ON — drag the alert and queue, then /coolplan lock.")
  else
    hud._active = false
    queue._live = false
    Reminders.SetLocked(true)
    ns.Print("move mode OFF — positions saved.")
  end
end

-- ── per-tick render (called by Scheduler) ─────────────────────────────────────
-- active = { reminder, remaining, total } or nil; upcoming = { {reminder, remaining}, ... }
function Reminders.RenderTick(active, upcoming, o)
  ensureFrames()
  if moverOn then return end

  if active and o.textEnabled then
    local r = active.reminder
    local name, icon = spellInfo(r.spellId)
    if icon then hud.icon:SetTexture(icon); hud.icon:Show() else hud.icon:Hide() end
    hud.name:SetText(labelFor(r))
    local total = active.total or (o.leadSeconds or 4)
    local rem = active.remaining
    if rem > 0 then
      hud.count:SetText(tostring(math.ceil(rem)))
      hud.bar:SetValue(math.max(0, math.min(1, total > 0 and rem / total or 0)))
      hud.bar:SetStatusBarColor((o.textColor or {}).r or 1, (o.textColor or {}).g or 0.95, (o.textColor or {}).b or 0.4)
    else
      hud.count:SetText("")
      hud.bar:SetValue(1)
      hud.bar:SetStatusBarColor(1, 0.2, 0.2) -- NOW
    end
    hud._active = true
    hud:Show()
  else
    hud._active = false
    hud:Hide()
  end

  if o.showQueue and upcoming and #upcoming > 0 then
    for i, row in ipairs(queue.rows) do
      local item = upcoming[i]
      if item then
        local nm = labelFor(item.reminder)
        row:SetText(("|cffffd200%s|r  %s |cff888888(in %ds)|r"):format(
          ns.Format.FormatTime(item.reminder.timeMs), nm, math.max(0, math.ceil(item.remaining))))
        row:Show()
      else
        row:SetText(""); row:Hide()
      end
    end
    queue._live = true
    queue:Show()
  else
    queue._live = false
    queue:Hide()
  end
end

-- ── discrete cues (called once when an alert appears) ──────────────────────────
function Reminders.Cue(reminder, o)
  if o.soundEnabled then
    if o.customSound and o.customSound ~= "" then
      PlaySoundFile(o.customSound, "Master")
    else
      local kit = SOUNDKIT and SOUNDKIT[o.soundKit or "RAID_WARNING"]
      if kit then PlaySound(kit, "Master") end
    end
  end
  if o.ttsEnabled and (not o.ttsCountdown) and C_VoiceChat and C_VoiceChat.SpeakText
     and Enum and Enum.VoiceTtsDestination then
    C_VoiceChat.SpeakText(o.ttsVoice or 0, labelFor(reminder), Enum.VoiceTtsDestination.LocalPlayback, 0, 100)
  end
end

function Reminders.SpeakCount(n, o)
  if o.ttsEnabled and C_VoiceChat and C_VoiceChat.SpeakText and Enum and Enum.VoiceTtsDestination then
    C_VoiceChat.SpeakText(o.ttsVoice or 0, tostring(n), Enum.VoiceTtsDestination.LocalPlayback, 0, 100)
  end
end

function Reminders.Clear()
  ensureFrames()
  hud._active = false
  queue._live = false
  if not moverOn then hud:Hide(); queue:Hide() end
end

-- ── quick test (sound flash) + countdown demo without an encounter ─────────────
function Reminders.Test()
  ensureFrames()
  local o = ns.DB.Options()
  Reminders.Cue({ spellId = 740, alert = "CoolPlan test" }, o)
  Reminders.RenderTick({ reminder = { spellId = 740, alert = "CoolPlan test" }, remaining = 0, total = o.leadSeconds }, nil, o)
  C_Timer.After(1.5, function() Reminders.Clear() end)
end

function Reminders.StopTest()
  if testTicker then testTicker:Cancel(); testTicker = nil end
  Reminders.Clear()
end
