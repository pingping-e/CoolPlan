-- Options page (raw frames, no libs): alert channels, anticipation lead,
-- HUD appearance, sound, TTS, queue, and per-category gating.
-- Embedded into the Window shell via Options.BuildPage(host).

local _, ns = ...
local Options = {}
ns.Options = Options

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

-- Wow built-in SOUNDKIT names (verified to exist). value = SOUNDKIT key.
local SOUNDS = {
  { "Raid Warning",   "RAID_WARNING" },
  { "Ready Check",    "READY_CHECK" },
  { "Alarm",          "ALARM_CLOCK_WARNING_3" },
  { "Boss Whisper",   "UI_RAID_BOSS_WHISPER_WARNING" },
  { "Boss Emote",     "UI_RAID_BOSS_EMOTE_WARNING" },
  { "PvP Update",     "IGPVPUPDATE" },
  { "Map Ping",       "MAP_PING" },
  { "Auction Open",   "AUCTION_WINDOW_OPEN" },
}

local function soundLabel(kit)
  for _, s in ipairs(SOUNDS) do if s[2] == kit then return s[1] end end
  return kit or "Raid Warning"
end

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

-- Attach all the option widgets to the Window's content host.
function Options.BuildPage(host)
  local o = ns.DB.Options()

  -- ── left column: alerts + lead ──
  local LX = 10
  header(host, "Alerts", LX, -6)
  checkbox(host, "On-screen text", LX, -26, function() return o.textEnabled end, function(v) o.textEnabled = v end)
  checkbox(host, "Sound", LX, -50, function() return o.soundEnabled end, function(v) o.soundEnabled = v end)
  checkbox(host, "Text-to-speech (TTS)", LX, -74, function() return o.ttsEnabled end, function(v) o.ttsEnabled = v end)
  checkbox(host, "TTS count down (3..2..1)", LX + 16, -98, function() return o.ttsCountdown end, function(v) o.ttsCountdown = v end)
  checkbox(host, "Only my character", LX, -122, function() return o.filterToMe end, function(v) o.filterToMe = v end)

  slider(host, "Lead time (s)", LX, -154, 0, 10, 1, function() return o.leadSeconds or 4 end, function(v) o.leadSeconds = v end)

  -- ── sound cue dropdown ──
  header(host, "Sound cue", LX, -204)
  local sndDD = ns.Window.MakeDropdown(host, "CoolPlanOptSoundDD", 160,
    function()
      local items = {}
      for _, s in ipairs(SOUNDS) do items[#items + 1] = { text = s[1], value = s[2] } end
      return items
    end,
    function(kit)
      o.soundKit = kit
      o.customSound = ""
      local k = SOUNDKIT and SOUNDKIT[kit]
      if k then PlaySound(k, "Master") end
    end)
  sndDD:SetPoint("TOPLEFT", LX - 8, -222)
  sndDD:SetValue(o.soundKit or "RAID_WARNING", soundLabel(o.soundKit))

  local csLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  csLabel:SetPoint("TOPLEFT", LX, -256)
  csLabel:SetText("Custom sound file (overrides above):")
  local cs = CreateFrame("EditBox", nil, host, "InputBoxTemplate")
  cs:SetSize(244, 20)
  cs:SetPoint("TOPLEFT", LX + 4, -272)
  cs:SetAutoFocus(false)
  cs:SetText(o.customSound or "")
  cs:SetScript("OnEnterPressed", ns.wrap(function(self)
    o.customSound = self:GetText()
    self:ClearFocus()
    if o.customSound ~= "" then PlaySoundFile(o.customSound, "Master") end
  end))

  local voiceLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  voiceLabel:SetPoint("TOPLEFT", LX, -300)
  voiceLabel:SetText("TTS voice id:")
  local voice = CreateFrame("EditBox", nil, host, "InputBoxTemplate")
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
  header(host, "HUD", RX, -6)
  slider(host, "Scale (%)", RX, -26, 50, 200, 5,
    function() return math.floor((o.scale or 1) * 100) end,
    function(v) o.scale = v / 100 end)
  slider(host, "Font size", RX, -74, 12, 48, 1, function() return o.fontSize or 28 end, function(v) o.fontSize = v end)

  local colorLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  colorLabel:SetPoint("TOPLEFT", RX, -122)
  colorLabel:SetText("Text color:")
  local cx = RX
  for _, col in ipairs(COLORS) do
    local sw = CreateFrame("Button", nil, host)
    sw:SetSize(22, 22)
    sw:SetPoint("TOPLEFT", cx, -138)
    local tex = sw:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetColorTexture(col[1], col[2], col[3])
    sw:SetScript("OnClick", ns.wrap(function()
      o.textColor = { r = col[1], g = col[2], b = col[3] }
      refresh()
    end))
    cx = cx + 26
  end

  header(host, "Upcoming queue", RX, -170)
  checkbox(host, "Show queue", RX, -190, function() return o.showQueue end, function(v) o.showQueue = v end)
  slider(host, "Queue size", RX, -218, 1, 6, 1, function() return o.queueCount or 3 end, function(v) o.queueCount = v end)
  checkbox(host, "Show boss mechanics", RX, -250, function() return o.showBoss end, function(v) o.showBoss = v end)

  header(host, "Position", RX, -282)
  button(host, "Move frames", 110, RX, -302, function() ns.Reminders.ToggleMover() end)
  button(host, "Lock", 60, RX + 116, -302, function() ns.Reminders.SetLocked(true) end)

  -- ── categories ──
  header(host, "Show categories", LX, -332)
  local gx, gy, col = LX, -352, 0
  for _, c in ipairs(CATEGORIES) do
    local key = c[1]
    checkbox(host, c[2], gx, gy,
      function() return ns.DB.CategoryEnabled(key) end,
      function(v) o.categoryEnabled[key] = v and nil or false end)
    col = col + 1
    if col % 3 == 0 then gx = LX; gy = gy - 24 else gx = gx + 175 end
  end

  -- ── bottom buttons (no Saved Plans / Import — the sidebar replaces them) ──
  button(host, "Test alert", 100, LX, -440, function() ns.Reminders.Test() end)
  button(host, "Demo countdown", 130, LX + 106, -440, function()
    if not ns.Scheduler.StartDemo() then ns.Print("demo failed.") end
  end)
  button(host, "Stop", 60, LX + 242, -440, function() ns.Scheduler.Stop() end)
end

-- Back-compat: other code (and slash) call Options.Open() → open the shell page.
function Options.Open()
  ns.Window.Open("options")
end

ns.Window.RegisterPage("options", "Options", Options.BuildPage)
