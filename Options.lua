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

local function alertModeLabel(mode)
  if mode == "none" then return "None (screen only)"
  elseif mode == "tts" then return "Text-to-speech"
  else return "Sound" end
end

-- Attach all the option widgets to the Window's content host. The 860×600 window
-- gives each column ~410px; widgets are spaced generously so labels, dropdowns,
-- sliders and the category grid never overlap.
function Options.BuildPage(host)
  local o = ns.DB.Options()

  -- two roomy columns with extra gutter
  local LX = 16
  local RX = 440

  -- forward refs so the alert-mode dropdown can enable/disable the dependent rows
  local sndDD, voiceDD
  local styleDD, timePosDD

  local function hudStyleLabel(v)
    if v == "icon" then return "Icon only"
    elseif v == "bar" then return "Bar"
    else return "Icon + name" end
  end
  local function timePosLabel(v)
    if v == "right" then return "On the right" else return "In icon/bar" end
  end

  local function syncAlertRows()
    local mode = o.alertSound or "sound"
    if sndDD then
      if mode == "sound" then UIDropDownMenu_EnableDropDown(sndDD) else UIDropDownMenu_DisableDropDown(sndDD) end
    end
    if voiceDD then
      if mode == "tts" then UIDropDownMenu_EnableDropDown(voiceDD) else UIDropDownMenu_DisableDropDown(voiceDD) end
    end
  end

  -- ── left column: alerts ──
  header(host, "Alerts", LX, -8)
  checkbox(host, "On-screen text", LX, -32,
    function() return o.textEnabled end, function(v) o.textEnabled = v end)
  checkbox(host, "Only my character", LX, -58,
    function() return o.filterToMe end, function(v) o.filterToMe = v end)

  -- single alert-mode dropdown (None / Sound / TTS)
  local modeLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  modeLabel:SetPoint("TOPLEFT", LX, -92)
  modeLabel:SetText("Alert sound mode:")
  local modeDD = ns.Window.MakeDropdown(host, "CoolPlanOptModeDD", 200,
    function()
      return {
        { text = alertModeLabel("none"),  value = "none" },
        { text = alertModeLabel("sound"), value = "sound" },
        { text = alertModeLabel("tts"),   value = "tts" },
      }
    end,
    function(mode)
      o.alertSound = mode
      syncAlertRows()
      -- audible preview of the chosen channel
      if mode == "sound" then
        local k = SOUNDKIT and SOUNDKIT[o.soundKit or "RAID_WARNING"]
        if k then PlaySound(k, "Master") end
      elseif mode == "tts" and ns.Reminders and ns.Reminders._speak then
        ns.Reminders._speak("CoolPlan", o)
      end
    end)
  modeDD:SetPoint("TOPLEFT", LX - 8, -110)
  modeDD:SetValue(o.alertSound or "sound", alertModeLabel(o.alertSound))

  -- sound kit (only meaningful in "sound" mode)
  local sndLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sndLabel:SetPoint("TOPLEFT", LX, -148)
  sndLabel:SetText("Sound cue:")
  sndDD = ns.Window.MakeDropdown(host, "CoolPlanOptSoundDD", 200,
    function()
      local items = {}
      for _, s in ipairs(SOUNDS) do items[#items + 1] = { text = s[1], value = s[2] } end
      return items
    end,
    function(kit)
      o.soundKit = kit
      local k = SOUNDKIT and SOUNDKIT[kit]
      if k then PlaySound(k, "Master") end
    end)
  sndDD:SetPoint("TOPLEFT", LX - 8, -166)
  sndDD:SetValue(o.soundKit or "RAID_WARNING", soundLabel(o.soundKit))

  -- TTS voice select (only meaningful in "tts" mode). Lists installed voices by
  -- NAME; picking one saves its voiceID and speaks a preview.
  local function voiceName(id)
    if C_VoiceChat and C_VoiceChat.GetTtsVoices then
      for _, v in ipairs(C_VoiceChat.GetTtsVoices() or {}) do
        if v.voiceID == id then return v.name end
      end
    end
    return id and ("Voice " .. tostring(id)) or "Default"
  end
  local voiceLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  voiceLabel:SetPoint("TOPLEFT", LX, -204)
  voiceLabel:SetText("TTS voice:")
  voiceDD = ns.Window.MakeDropdown(host, "CoolPlanOptVoiceDD", 200,
    function()
      local items = {}
      if C_VoiceChat and C_VoiceChat.GetTtsVoices then
        for _, v in ipairs(C_VoiceChat.GetTtsVoices() or {}) do
          items[#items + 1] = { text = v.name, value = v.voiceID }
        end
      end
      if #items == 0 then items[1] = { text = "No voices installed", value = 0 } end
      return items
    end,
    function(id)
      o.ttsVoice = id
      if ns.Reminders and ns.Reminders._speak then ns.Reminders._speak("CoolPlan", o) end
    end)
  voiceDD:SetPoint("TOPLEFT", LX - 8, -222)
  voiceDD:SetValue(o.ttsVoice or 0, voiceName(o.ttsVoice))

  -- ── left column: timing ──
  header(host, "Timing", LX, -262)
  slider(host, "On-screen lead (s)", LX, -286, 0, 10, 1,
    function() return o.leadSeconds or 4 end, function(v) o.leadSeconds = v end)
  slider(host, "Sound/TTS lead (s)", LX, -340, 0, 10, 1,
    function() return o.soundLeadSeconds or 0 end, function(v) o.soundLeadSeconds = v end)

  -- ── right column: HUD ──
  header(host, "HUD", RX, -8)
  slider(host, "Scale (%)", RX, -32, 50, 200, 5,
    function() return math.floor((o.scale or 1) * 100) end,
    function(v) o.scale = v / 100 end)
  slider(host, "Font size", RX, -86, 12, 48, 1,
    function() return o.fontSize or 28 end, function(v) o.fontSize = v end)

  -- HUD display style (icon only / icon + name / bar)
  local styleLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  styleLabel:SetPoint("TOPLEFT", RX, -132)
  styleLabel:SetText("Display style:")
  styleDD = ns.Window.MakeDropdown(host, "CoolPlanOptStyleDD", 200,
    function()
      return {
        { text = hudStyleLabel("icon"),     value = "icon" },
        { text = hudStyleLabel("iconName"), value = "iconName" },
        { text = hudStyleLabel("bar"),      value = "bar" },
      }
    end,
    function(v)
      o.hudStyle = v
      if ns.Reminders then ns.Reminders.ApplyOptions() end
    end)
  styleDD:SetPoint("TOPLEFT", RX - 8, -150)
  styleDD:SetValue(o.hudStyle or "iconName", hudStyleLabel(o.hudStyle))

  -- time (countdown) position (inside the icon/bar / separate on the right)
  local timePosLbl = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  timePosLbl:SetPoint("TOPLEFT", RX, -188)
  timePosLbl:SetText("Time position:")
  timePosDD = ns.Window.MakeDropdown(host, "CoolPlanOptTimePosDD", 200,
    function()
      return {
        { text = timePosLabel("icon"),  value = "icon" },
        { text = timePosLabel("right"), value = "right" },
      }
    end,
    function(v)
      o.timePos = v
      if ns.Reminders then ns.Reminders.ApplyOptions() end
    end)
  timePosDD:SetPoint("TOPLEFT", RX - 8, -206)
  timePosDD:SetValue(o.timePos or "icon", timePosLabel(o.timePos))

  local colorLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  colorLabel:SetPoint("TOPLEFT", RX, -244)
  colorLabel:SetText("Text color:")
  local cx = RX
  for _, col in ipairs(COLORS) do
    local sw = CreateFrame("Button", nil, host)
    sw:SetSize(22, 22)
    sw:SetPoint("TOPLEFT", cx, -262)
    local tex = sw:CreateTexture(nil, "ARTWORK")
    tex:SetAllPoints()
    tex:SetColorTexture(col[1], col[2], col[3])
    sw:SetScript("OnClick", ns.wrap(function()
      o.textColor = { r = col[1], g = col[2], b = col[3] }
      refresh()
    end))
    sw._cpSkinned = true -- preserve the meaningful swatch color (skip auto-skin)
    cx = cx + 28
  end

  -- ── right column: queue ──
  header(host, "Upcoming queue", RX, -298)
  checkbox(host, "Show queue", RX, -322,
    function() return o.showQueue end, function(v) o.showQueue = v end)
  slider(host, "Queue size", RX, -350, 1, 6, 1,
    function() return o.queueCount or 3 end, function(v) o.queueCount = v end)
  checkbox(host, "Show boss mechanics", RX, -404,
    function() return o.showBoss end, function(v) o.showBoss = v end)

  -- ── right column: position ──
  header(host, "Position", RX, -438)
  button(host, "Move frames", 120, RX, -460, function() ns.Reminders.ToggleMover() end)
  button(host, "Lock", 70, RX + 128, -460, function() ns.Reminders.SetLocked(true) end)

  -- ── categories (full width, roomy 3-col grid) ──
  header(host, "Show categories", LX, -404)
  local gx, gy, col = LX, -428, 0
  for _, c in ipairs(CATEGORIES) do
    local key = c[1]
    checkbox(host, c[2], gx, gy,
      function() return ns.DB.CategoryEnabled(key) end,
      function(v) o.categoryEnabled[key] = v and nil or false end)
    col = col + 1
    if col % 3 == 0 then gx = LX; gy = gy - 28 else gx = gx + 200 end
  end

  -- ── bottom buttons (no Saved Plans / Import — the sidebar replaces them) ──
  button(host, "Test alert", 110, LX, -528, function() ns.Reminders.Test() end)
  button(host, "Demo countdown", 140, LX + 118, -528, function()
    if not ns.Scheduler.StartDemo() then ns.Print("demo failed.") end
  end)
  button(host, "Stop", 70, LX + 266, -528, function() ns.Scheduler.Stop() end)

  if ns.Style then
    ns.Style.Apply(host)
    ns.Style.Dropdown(modeDD)
    ns.Style.Dropdown(sndDD)
    ns.Style.Dropdown(voiceDD)
    ns.Style.Dropdown(styleDD)
    ns.Style.Dropdown(timePosDD)
  end

  syncAlertRows()
end

-- Back-compat: other code (and slash) call Options.Open() → open the shell page.
function Options.Open()
  ns.Window.Open("options")
end

ns.Window.RegisterPage("options", "Options", Options.BuildPage)
