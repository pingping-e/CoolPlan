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
  do
    local p = ns.Style and ns.Style.colors.panel
    if p then f.bg:SetColorTexture(p[1], p[2], p[3], 0.55) else f.bg:SetColorTexture(0, 0, 0, 0.35) end
  end
  f.bg:Hide()

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(52, 52)
  f.icon:SetPoint("LEFT", f, "LEFT", 6, 0)
  f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  -- start from a real font object so SetText never hits a font-less string;
  -- ApplyOptions resizes via SetFont afterwards.
  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.count:SetPoint("CENTER", f.icon, "CENTER", 0, 0)

  f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.name:SetPoint("LEFT", f.icon, "RIGHT", 12, 6)

  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetPoint("LEFT", f.icon, "RIGHT", 12, -16)
  f.bar:SetSize(340, 12)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetMinMaxValues(0, 1)
  f.bar:SetValue(1)
  f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
  f.bar.bg:SetAllPoints()
  do
    local b = ns.Style and ns.Style.colors.bg
    if b then f.bar.bg:SetColorTexture(b[1], b[2], b[3], 0.7) else f.bar.bg:SetColorTexture(0, 0, 0, 0.5) end
  end

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
  do
    local p = ns.Style and ns.Style.colors.panel
    if p then f.bg:SetColorTexture(p[1], p[2], p[3], 0.55) else f.bg:SetColorTexture(0, 0, 0, 0.35) end
  end
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
  -- wire dragging (respects the per-frame `locked` flag)
  local o = ns.DB and ns.DB.Options and ns.DB.Options()
  if o then
    makeMovable(hud, o.hud)
    makeMovable(queue, o.queueAnchor)
  end
end

-- ── HUD layout (style + time position) ────────────────────────────────────────
-- Re-anchors / shows / hides / sizes the icon, name, count and bar regions for
-- the chosen hudStyle ("icon" | "iconName" | "bar") and timePos ("icon" |
-- "right"), then sizes the hud frame to fit. RenderTick only updates VALUES;
-- this function owns all the Show/Hide + ClearAllPoints + fonts so a hidden
-- region never resurfaces on the next tick.
local ICON_SIZE = 52
local THIN_BAR_H = 5
local function layoutHud(o)
  local style = o.hudStyle or "iconName"
  local tpos = o.timePos or "icon"
  local size = o.fontSize or 28
  local c = o.textColor or { r = 1, g = 0.95, b = 0.4 }
  local fontPath = GameFontNormalHuge:GetFont() -- nil-guarded below

  local icon, name, count, bar = hud.icon, hud.name, hud.count, hud.bar
  icon:ClearAllPoints(); name:ClearAllPoints(); count:ClearAllPoints(); bar:ClearAllPoints()

  -- count font: big when centered inside the icon/bar, normal when on the right
  local countSize = (tpos == "icon") and (size + 10) or size
  if fontPath then
    if name.SetFont then name:SetFont(fontPath, size, "OUTLINE") end
    if count.SetFont then count:SetFont(fontPath, countSize, "OUTLINE") end
  end
  name:SetTextColor(c.r, c.g, c.b)
  count:SetTextColor(1, 1, 1)

  local PAD = 6

  if style == "bar" then
    -- thick horizontal bar with a small square icon on the left, name overlaid
    -- left, time either inside-right or as a separate right field.
    local barH = math.max(20, size)
    local barW = 300
    icon:SetSize(barH, barH)
    icon:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    icon:Show()

    bar:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    bar:SetSize(barW, barH)
    bar:Show()

    name:SetPoint("LEFT", bar, "LEFT", 6, 0)
    name:SetJustifyH("LEFT")
    name:Show()

    local totalW = PAD + barH + 4 + barW + PAD
    if tpos == "icon" then
      -- "in icon/bar" for the bar style = inside the small left icon
      count:SetPoint("CENTER", icon, "CENTER", 0, 0)
      count:SetJustifyH("CENTER")
      if fontPath and count.SetFont then count:SetFont(fontPath, math.max(12, barH - 6), "OUTLINE") end
    else
      count:SetPoint("LEFT", bar, "RIGHT", 8, 0)
      count:SetJustifyH("LEFT")
      totalW = totalW + 8 + math.max(28, size)
    end
    count:Show()
    hud:SetSize(totalW, barH + 4)

  elseif style == "icon" then
    -- icon only: just the 52px icon with the countdown number. No bar, no name.
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    icon:Show()

    bar:Hide()
    name:Hide()

    local totalW = PAD + ICON_SIZE + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0)
      count:SetJustifyH("CENTER")
    else
      count:SetPoint("LEFT", icon, "RIGHT", 8, 0)
      count:SetJustifyH("LEFT")
      totalW = totalW + 8 + math.max(28, size)
    end
    count:Show()
    hud:SetSize(totalW, ICON_SIZE + THIN_BAR_H + 2)

  else -- "iconName"
    -- 52px icon on the left, name on the right. No bar (countdown number only).
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    icon:Show()

    name:SetPoint("LEFT", icon, "RIGHT", 12, 0)
    name:SetJustifyH("LEFT")
    name:Show()

    bar:Hide()

    local totalW = PAD + ICON_SIZE + 12 + 240 + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0)
      count:SetJustifyH("CENTER")
    else
      count:SetPoint("LEFT", name, "RIGHT", 10, 0)
      count:SetJustifyH("LEFT")
    end
    count:Show()
    hud:SetSize(totalW, ICON_SIZE + 4)
  end
end
ns.Reminders._layoutHud = layoutHud

function Reminders.Init()
  ensureFrames()
  Reminders.ApplyOptions()
end

-- ── apply options (scale / font / color / positions / lock / queue rows) ───────
function Reminders.ApplyOptions()
  ensureFrames()
  local o = ns.DB.Options()
  local c = o.textColor or { r = 1, g = 0.95, b = 0.4 }

  hud:SetScale(o.scale or 1)
  -- style/timePos/font ownership lives in layoutHud (anchors + Show/Hide + fonts)
  layoutHud(o)
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
    layoutHud(o) -- preview matches the current style/timePos
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
-- active = { cue, remaining, total } or nil; upcoming = { {cue, remaining}, ... }
-- A cue has: kind ("cd" | "boss"), timeMs, spellId, spellName?, alert?, bossType?
function Reminders.RenderTick(active, upcoming, o)
  ensureFrames()
  if moverOn then return end

  if active and o.textEnabled then
    local cue = active.cue
    local isBoss = cue.kind == "boss"
    local _, icon = spellInfo(cue.spellId)
    -- icon texture only; layoutHud already decided icon Show/Hide for the style
    if icon then hud.icon:SetTexture(icon) end
    local c = isBoss and { r = 1, g = 0.45, b = 0.3 } or (o.textColor or { r = 1, g = 0.95, b = 0.4 })
    -- update name TEXT/color only; layoutHud owns whether name is shown for the style
    hud.name:SetText((isBoss and "|cffff7777[BOSS]|r " or "") .. labelFor(cue))
    hud.name:SetTextColor(c.r, c.g, c.b)
    local total = active.total or (o.leadSeconds or 4)
    local rem = active.remaining
    if rem > 0 then
      hud.count:SetText(tostring(math.ceil(rem)))
      hud.bar:SetValue(math.max(0, math.min(1, total > 0 and rem / total or 0)))
      hud.bar:SetStatusBarColor(c.r, c.g, c.b)
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
        local cue = item.cue
        local tag = cue.kind == "boss" and "|cffff7777[B]|r " or ""
        row:SetText(("%s|cffffd200%s|r  %s |cff888888(in %ds)|r"):format(
          tag, ns.Format.FormatTime(cue.timeMs), labelFor(cue), math.max(0, math.ceil(item.remaining))))
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

-- ── text-to-speech ────────────────────────────────────────────────────────────
-- Resolve a USABLE voice id. Voice id 0 is not guaranteed to exist on every
-- client (different installed TTS voices), and SpeakText silently does nothing
-- for an unknown voice — that's why "TTS on" only played the warning sound.
-- Use the configured voice if it still exists, else the first installed one.
local function ttsVoiceId(o)
  local want = o and o.ttsVoice
  if C_VoiceChat and C_VoiceChat.GetTtsVoices then
    local voices = C_VoiceChat.GetTtsVoices()
    if voices and #voices > 0 then
      -- ttsVoice == 0 is the UNSET default, not a deliberate pick — so use the
      -- first actually-installed voice. Only honor an explicit non-zero choice.
      if want and want ~= 0 then
        for _, v in ipairs(voices) do if v.voiceID == want then return want end end
      end
      return voices[1].voiceID
    end
  end
  return want or 0
end

local function speak(text, o)
  if not (C_VoiceChat and C_VoiceChat.SpeakText) then return end
  local voiceId = ttsVoiceId(o)
  local rate = (C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate()) or 0
  local volume = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100
  -- Retail (Midnight / Mainline) changed the signature: SpeakText DROPPED the
  -- destination enum -> (voiceID, text, rate, volume, true). We were passing the
  -- old form with a VoiceTtsDestination where rate goes, so the args were
  -- misaligned and TTS silently did nothing. (Matches Method Raid Tools.)
  if WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
    C_VoiceChat.SpeakText(voiceId, text, rate, volume, true)
  elseif Enum and Enum.VoiceTtsDestination then
    C_VoiceChat.SpeakText(voiceId, text, Enum.VoiceTtsDestination.QueuedLocalPlayback, rate, volume)
  end
end
ns.Reminders._speak = speak

-- ── discrete cues (fired once when a reminder's sound/TTS lead window opens) ────
-- A single alert mode picks the audible channel: "sound" plays a sound kit,
-- "tts" speaks the cooldown name, "none" stays silent (on-screen text only).
function Reminders.Cue(reminder, o)
  local mode = o.alertSound or "sound"
  if mode == "sound" then
    local kit = SOUNDKIT and SOUNDKIT[o.soundKit or "RAID_WARNING"]
    if kit then PlaySound(kit, "Master") end
  elseif mode == "tts" then
    speak(labelFor(reminder), o)
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
  local cue = { kind = "cd", spellId = 740, alert = "CoolPlan test" }
  Reminders.Cue(cue, o)
  -- TTS diagnostic: list the installed voices + the one we use, so a silent TTS
  -- is explained (api missing / no voices / wrong output device).
  if o.alertSound == "tts" then
    local voices = (C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()) or {}
    local hasApi = (C_VoiceChat and C_VoiceChat.SpeakText) ~= nil
    ns.Print(("TTS: api=%s, voices=%d, using id=%s"):format(tostring(hasApi), #voices, tostring(ttsVoiceId(o))))
    for _, v in ipairs(voices) do
      ns.Print(("   id=%s  %s"):format(tostring(v.voiceID), tostring(v.name)))
    end
    if #voices == 0 then
      ns.Print("|cffff6666no TTS voices — add one in Windows Speech settings, then /reload|r")
    elseif hasApi then
      ns.Print("|cff888888if still silent: Esc > Options > Voice Chat — TTS plays through the voice-chat OUTPUT device.|r")
    end
  end
  Reminders.RenderTick({ cue = cue, remaining = 0, total = o.leadSeconds }, nil, o)
  C_Timer.After(1.5, function() Reminders.Clear() end)
end

function Reminders.StopTest()
  if testTicker then testTicker:Cancel(); testTicker = nil end
  Reminders.Clear()
end
