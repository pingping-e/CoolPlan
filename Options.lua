-- Options window (raw frames, no libs): alert channels, anticipation lead,
-- HUD appearance, sound, TTS, queue, and per-category gating.

local _, ns = ...
local Options = {}
ns.Options = Options

local frame

local CATEGORIES = {
  { "personal_defensive", "Personal def" },
  { "external_defensive", "External def" },
  { "raid_defensive",     "Raid/Healer Cd" },
  { "offensive",          "Offensive" },
  { "utility",            "Utility" },
  { "bloodlust",          "Bloodlust" },
  { "potion",             "Potion" },
  { "trinket",            "Trinket" },
  { "racial",             "Racial" },
}

local COLORS = {
  { 1, 0.95, 0.4 },  -- amber
  { 1, 1, 1 },       -- white
  { 1, 0.3, 0.3 },   -- red
  { 0.4, 1, 0.5 },   -- green
  { 0.4, 0.8, 1 },   -- cyan
}

local SOUNDS = {
  { "Raid Warning", "RAID_WARNING" },
  { "Ready Check",  "READY_CHECK" },
  { "Alarm",        "ALARM_CLOCK_WARNING_3" },
}

local function refresh()
  if ns.Reminders then ns.Reminders.ApplyOptions() end
end

local function header(parent, text, x, y)
  local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  fs:SetPoint("TOPLEFT", x, y)
  fs:SetText("|cff66b3ff" .. text .. "|r")
  return fs
end

local function checkbox(parent, label, x, y, getter, setter)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetSize(24, 24)
  cb:SetPoint("TOPLEFT", x, y)
  cb:SetChecked(getter() and true or false)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("LEFT", cb, "RIGHT", 2, 0)
  fs:SetText(label)
  cb:SetScript("OnClick", ns.wrap(function(self)
    setter(self:GetChecked() and true or false)
    refresh()
  end))
  return cb
end

local function slider(parent, label, x, y, minV, maxV, step, getter, setter)
  local lbl = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  lbl:SetPoint("TOPLEFT", x, y)
  local s = CreateFrame("Slider", "CoolPlanSlider" .. label:gsub("%s", ""), parent, "OptionsSliderTemplate")
  s:SetPoint("TOPLEFT", x + 4, y - 18)
  s:SetWidth(180)
  s:SetMinMaxValues(minV, maxV)
  s:SetValueStep(step)
  s:SetObeyStepOnDrag(true)
  s:SetValue(getter())
  -- OptionsSliderTemplate's named regions can vary by client; guard them.
  local low = _G[s:GetName() .. "Low"]; if low then low:SetText(tostring(minV)) end
  local high = _G[s:GetName() .. "High"]; if high then high:SetText(tostring(maxV)) end
  local txt = _G[s:GetName() .. "Text"]; if txt then txt:SetText("") end
  local function setLabel(v) lbl:SetText(label .. ": " .. v) end
  setLabel(getter())
  s:SetScript("OnValueChanged", ns.wrap(function(_, v)
    v = math.floor(v / step + 0.5) * step
    setter(v)
    setLabel(v)
    refresh()
  end))
  return s
end

local function button(parent, text, w, x, y, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  b:SetPoint("TOPLEFT", x, y)
  b:SetScript("OnClick", ns.wrap(onClick))
  return b
end

local function build()
  local o = ns.DB.Options()

  local f = CreateFrame("Frame", "CoolPlanOptions", UIParent, "BackdropTemplate")
  f:SetSize(560, 500)
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOP", 0, -14)
  title:SetText("CoolPlan — Options")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  -- ── left column: alerts + lead ──
  local LX = 22
  header(f, "Alerts", LX, -40)
  checkbox(f, "On-screen text", LX, -60, function() return o.textEnabled end, function(v) o.textEnabled = v end)
  checkbox(f, "Sound", LX, -84, function() return o.soundEnabled end, function(v) o.soundEnabled = v end)
  checkbox(f, "Text-to-speech (TTS)", LX, -108, function() return o.ttsEnabled end, function(v) o.ttsEnabled = v end)
  checkbox(f, "TTS count down (3..2..1)", LX + 16, -132, function() return o.ttsCountdown end, function(v) o.ttsCountdown = v end)
  checkbox(f, "Only my character", LX, -156, function() return o.filterToMe end, function(v) o.filterToMe = v end)

  slider(f, "Lead time (s)", LX, -188, 0, 10, 1, function() return o.leadSeconds or 4 end, function(v) o.leadSeconds = v end)

  header(f, "Sound cue", LX, -238)
  local sx = LX
  for _, s in ipairs(SOUNDS) do
    local name, kit = s[1], s[2]
    local w = 86
    button(f, name, w, sx, -258, function()
      o.soundKit = kit
      o.customSound = ""
      local k = SOUNDKIT and SOUNDKIT[kit]
      if k then PlaySound(k, "Master") end
    end)
    sx = sx + w + 4
  end
  local csLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  csLabel:SetPoint("TOPLEFT", LX, -288)
  csLabel:SetText("Custom sound file (overrides above):")
  local cs = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  cs:SetSize(244, 20)
  cs:SetPoint("TOPLEFT", LX + 4, -304)
  cs:SetAutoFocus(false)
  cs:SetText(o.customSound or "")
  cs:SetScript("OnEnterPressed", ns.wrap(function(self)
    o.customSound = self:GetText()
    self:ClearFocus()
    if o.customSound ~= "" then PlaySoundFile(o.customSound, "Master") end
  end))

  local voiceLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  voiceLabel:SetPoint("TOPLEFT", LX, -332)
  voiceLabel:SetText("TTS voice id:")
  local voice = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  voice:SetSize(50, 20)
  voice:SetPoint("LEFT", voiceLabel, "RIGHT", 8, 0)
  voice:SetAutoFocus(false)
  voice:SetNumeric(true)
  voice:SetText(tostring(o.ttsVoice or 0))
  voice:SetScript("OnEnterPressed", ns.wrap(function(self)
    o.ttsVoice = tonumber(self:GetText()) or 0
    self:ClearFocus()
  end))

  -- ── right column: HUD + queue ──
  local RX = 300
  header(f, "HUD", RX, -40)
  slider(f, "Scale (%)", RX, -60, 50, 200, 5,
    function() return math.floor((o.scale or 1) * 100) end,
    function(v) o.scale = v / 100 end)
  slider(f, "Font size", RX, -108, 12, 48, 1, function() return o.fontSize or 28 end, function(v) o.fontSize = v end)

  local colorLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  colorLabel:SetPoint("TOPLEFT", RX, -156)
  colorLabel:SetText("Text color:")
  local cx = RX
  for _, col in ipairs(COLORS) do
    local sw = CreateFrame("Button", nil, f)
    sw:SetSize(22, 22)
    sw:SetPoint("TOPLEFT", cx, -172)
    local tex = sw:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetColorTexture(col[1], col[2], col[3])
    sw:SetScript("OnClick", ns.wrap(function()
      o.textColor = { r = col[1], g = col[2], b = col[3] }
      refresh()
    end))
    cx = cx + 26
  end

  header(f, "Upcoming queue", RX, -204)
  checkbox(f, "Show queue", RX, -224, function() return o.showQueue end, function(v) o.showQueue = v end)
  slider(f, "Queue size", RX, -252, 1, 6, 1, function() return o.queueCount or 3 end, function(v) o.queueCount = v end)
  checkbox(f, "Show boss mechanics", RX, -284, function() return o.showBoss end, function(v) o.showBoss = v end)

  header(f, "Position", RX, -316)
  button(f, "Move frames", 110, RX, -336, function() ns.Reminders.ToggleMover() end)
  button(f, "Lock", 60, RX + 116, -336, function() ns.Reminders.SetLocked(true) end)

  -- ── categories ──
  header(f, "Show categories", LX, -362)
  local gx, gy, col = LX, -382, 0
  for _, c in ipairs(CATEGORIES) do
    local key = c[1]
    checkbox(f, c[2], gx, gy,
      function() return ns.DB.CategoryEnabled(key) end,
      function(v) o.categoryEnabled[key] = v and nil or false end)
    col = col + 1
    if col % 3 == 0 then gx = LX; gy = gy - 24 else gx = gx + 175 end
  end

  -- ── bottom buttons ──
  button(f, "Test alert", 100, LX, -468, function() ns.Reminders.Test() end)
  button(f, "Demo countdown", 130, LX + 106, -468, function()
    if not ns.Scheduler.StartDemo() then ns.Print("demo failed.") end
  end)
  button(f, "Stop", 60, LX + 242, -468, function() ns.Scheduler.Stop() end)
  button(f, "Saved Plans", 110, RX - 20, -468, function() ns.Manager.Open() end)
  button(f, "Import…", 96, RX + 96, -468, function() ns.Editor.Open() end)

  return f
end

function Options.Open()
  if not frame then frame = build() end
  frame:Show()
end
