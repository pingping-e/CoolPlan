-- Options page (raw frames, no libs): alert channels, anticipation lead,
-- HUD appearance, sound, TTS, queue, and per-category gating.
-- Embedded into the Window shell via Options.BuildPage(host).

local _, ns = ...
local Options = {}
ns.Options = Options

local CATEGORIES = {
  { "personal_defensive", "Personal def" },
  { "external_defensive", "External def" },
  { "raid_defensive",     "Raid Cd (raid-wide)" },
  { "healer_cd",          "Healer Cd" },
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

-- Display name for a saved sound value (SOUNDKIT name or LSM sound name).
-- "Raid Warning" is the pinned SOUNDKIT default; LSM names show as-is.
local function soundName(v)
  if not v or v == "RAID_WARNING" then return "Raid Warning" end
  return v
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

-- Confirm dialog for "Reset settings" - a self-contained frame, NOT Blizzard's
-- shared `StaticPopupDialogs`. Writing into that global table taints it, and
-- protected UIs that read it (e.g. the transmog outfit dropdown, which drives
-- ChangeDisplayedOutfit) inherit the taint → ADDON_ACTION_FORBIDDEN. A private
-- frame keeps the taint contained. Reset + ReloadUI so the page rebuilds against
-- fresh defaults (widgets only read their values on build).
local resetConfirm
local function showResetConfirm()
  if not resetConfirm then
    local f = CreateFrame("Frame", "CoolPlanResetConfirm", UIParent, "BackdropTemplate")
    f:SetSize(360, 130)
    f:SetPoint("CENTER")
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    f:SetToplevel(true)
    f:EnableMouse(true)
    if ns.Style and ns.Style.Panel then
      ns.Style.Panel(f, 0.98)
    elseif f.SetBackdrop then
      f:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8", edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
      f:SetBackdropColor(0.06, 0.06, 0.08, 0.98)
      f:SetBackdropBorderColor(0.3, 0.3, 0.35, 1)
    end
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    lbl:SetPoint("TOP", 0, -18)
    lbl:SetWidth(324)
    lbl:SetText("Reset all CoolPlan settings to defaults?\nYour UI will reload. Saved plans and frame positions are kept.")
    local ok = button(f, OKAY or "Okay", 90, 0, 0, function()
      f:Hide(); ns.DB.ResetOptions(); ReloadUI()
    end)
    ok:ClearAllPoints(); ok:SetPoint("BOTTOMRIGHT", -18, 16)
    local cancel = button(f, CANCEL or "Cancel", 90, 0, 0, function() f:Hide() end)
    cancel:ClearAllPoints(); cancel:SetPoint("BOTTOMLEFT", 18, 16)
    if UISpecialFrames and not tContains(UISpecialFrames, "CoolPlanResetConfirm") then
      tinsert(UISpecialFrames, "CoolPlanResetConfirm") -- Esc closes
    end
    resetConfirm = f
  end
  resetConfirm:Show()
end

-- Attach all the option widgets to the Window's content host. The 860×600 window
-- gives each column ~410px; widgets are spaced generously so labels, dropdowns,
-- sliders and the category grid never overlap.
function Options.BuildPage(host)
  local o = ns.DB.Options()

  -- Left column anchors to the host's top-left (TOPLEFT offsets, as before).
  -- Right column lives in a container pinned to the host's TOP-RIGHT so it
  -- follows the window edge when the shell is resized (instead of a fixed RX).
  local LX = 16

  -- right-column container: a fixed-width strip hugging the right edge. Widgets
  -- inside use small TOPLEFT offsets, so RX becomes a local origin (≈8) and the
  -- whole column tracks the window width.
  local RCOL_W = 240
  local rcol = CreateFrame("Frame", nil, host)
  rcol:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, 0)
  rcol:SetPoint("BOTTOMRIGHT", host, "BOTTOMRIGHT", -8, 0)
  rcol:SetWidth(RCOL_W)
  -- local origin inside the right column (keeps the original ~16px inset feel)
  local RX = 8

  -- forward refs so the alert-mode dropdown can enable/disable the dependent rows
  local sndBtn, voiceDD
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
    if sndBtn then sndBtn:SetEnabled(mode == "sound") end
    if voiceDD then voiceDD:SetEnabled(mode == "tts") end
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
        if ns.Reminders then ns.Reminders.PlaySound(o.soundKit) end
      elseif mode == "tts" and ns.Reminders and ns.Reminders._speak then
        ns.Reminders._speak("CoolPlan", o)
      end
    end)
  modeDD:SetPoint("TOPLEFT", LX - 8, -110)
  modeDD:SetValue(o.alertSound or "sound", alertModeLabel(o.alertSound))

  -- sound cue (only meaningful in "sound" mode). Opens a scrollable, searchable
  -- picker backed by LibSharedMedia - the same shared sound list MRT/BigWigs/
  -- WeakAuras/SharedMedia all contribute to. Raid Warning is pinned default.
  local sndLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  sndLabel:SetPoint("TOPLEFT", LX, -148)
  sndLabel:SetText("Sound cue:")
  sndBtn = CreateFrame("Button", "CoolPlanOptSoundBtn", host, "UIPanelButtonTemplate")
  sndBtn:SetSize(200, 22)
  sndBtn:SetPoint("TOPLEFT", LX - 8, -168)
  sndBtn:SetText(soundName(o.soundKit))
  -- match MakeDropdown selects: clipped left label + dropdown chevron
  if ns.Window and ns.Window.AddSelectArrow then ns.Window.AddSelectArrow(sndBtn) end
  sndBtn:SetScript("OnClick", ns.wrap(function()
    if ns.SoundPicker.IsShown() then ns.SoundPicker.Hide(); return end
    ns.SoundPicker.Show(sndBtn, o.soundKit, function(value)
      o.soundKit = value
      sndBtn:SetText(soundName(value))
      if ns.Reminders then ns.Reminders.PlaySound(value) end -- live preview
    end)
  end))
  if ns.Style then ns.Style.Button(sndBtn) end

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

  -- ── timing (a middle column that FLOATS between Alerts and the HUD column;
  -- anchoring its container to host TOP keeps it band-centered as the window
  -- resizes, instead of staying glued to the left next to Alerts) ──
  local timingCol = CreateFrame("Frame", nil, host)
  timingCol:SetSize(200, 150)
  timingCol:SetPoint("TOP", host, "TOP", -16, -8)
  header(timingCol, "Timing", 4, 0)
  slider(timingCol, "On-screen lead (s)", 4, -24, 0, 10, 1,
    function() return o.leadSeconds or 4 end, function(v) o.leadSeconds = v end)
  local soundLeadSlider = slider(timingCol, "Sound/TTS lead (s)", 4, -78, 0, 10, 1,
    function() return o.soundLeadSeconds or 0 end, function(v) o.soundLeadSeconds = v end)

  -- The spoken 3-2-1 countdown IS the audio lead-in, so a separate Sound/TTS
  -- lead would fire the cue (ping / spell-name TTS) on top of the "3..2..1"
  -- numbers - overlapping and awkward. While the countdown is on, force the
  -- Sound/TTS lead to 0 (cue fires AT cast, after the count) and lock the slider;
  -- restore the prior value when unchecked. The restore value is stashed in a
  -- PERSISTENT field (o.savedSoundLead) - not a session local - because forcing
  -- the slider to 0 writes 0 through to SavedVariables, so the original would
  -- otherwise be lost across /reload (a settings-eating bug).
  -- Grey the (otherwise brand-blue) thumb while locked so it visibly reads as
  -- non-editable. We paint the thumb a flat colour ourselves, so the native
  -- Disable() can't desaturate it - recolour it directly instead.
  local function tintSoundLead(locked)
    local thumb = soundLeadSlider.GetThumbTexture and soundLeadSlider:GetThumbTexture()
    if not (thumb and thumb.SetColorTexture) then return end
    if locked then
      thumb:SetColorTexture(0.42, 0.44, 0.48, 1)                 -- greyed
    else
      local a = ns.Style and ns.Style.colors and ns.Style.colors.accent
      if a then thumb:SetColorTexture(a[1], a[2], a[3], 1) end    -- brand blue
    end
  end
  local function applyCountdownLock(on)
    if on then
      -- remember the user's lead durably, once, before forcing it to 0. The
      -- `> 0` guard means re-running this at build/reload time (when the lead is
      -- already 0) never clobbers the remembered value.
      if (o.soundLeadSeconds or 0) > 0 then o.savedSoundLead = o.soundLeadSeconds end
      soundLeadSlider:SetValue(0)
      if soundLeadSlider.Disable then soundLeadSlider:Disable() end
    else
      if soundLeadSlider.Enable then soundLeadSlider:Enable() end
      soundLeadSlider:SetValue(o.savedSoundLead or 0)
    end
    tintSoundLead(on)
  end

  -- Spoken 3-2-1 countdown (TTS). Independent of the alert sound mode - works
  -- even on Sound/None, and is separate from the spell-name TTS.
  checkbox(timingCol, "Speak 3-2-1 countdown (TTS)", 4, -126,
    function() return o.countdownVoice end,
    function(v) o.countdownVoice = v; applyCountdownLock(v) end)

  -- ── right column: HUD ── (parented to rcol → tracks the window's right edge)
  header(rcol, "HUD", RX, -8)
  slider(rcol, "Scale (%)", RX, -32, 50, 200, 5,
    function() return math.floor((o.scale or 1) * 100) end,
    function(v) o.scale = v / 100 end)
  slider(rcol, "Font size", RX, -86, 12, 48, 1,
    function() return o.fontSize or 28 end, function(v) o.fontSize = v end)

  -- HUD display style (icon only / icon + name / bar)
  local styleLabel = rcol:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  styleLabel:SetPoint("TOPLEFT", RX, -132)
  styleLabel:SetText("Display style:")
  styleDD = ns.Window.MakeDropdown(rcol, "CoolPlanOptStyleDD", 200,
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
  local timePosLbl = rcol:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  timePosLbl:SetPoint("TOPLEFT", RX, -188)
  timePosLbl:SetText("Time position:")
  timePosDD = ns.Window.MakeDropdown(rcol, "CoolPlanOptTimePosDD", 200,
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

  local colorLabel = rcol:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  colorLabel:SetPoint("TOPLEFT", RX, -244)
  colorLabel:SetText("Text color:")
  local cx = RX
  for _, col in ipairs(COLORS) do
    local sw = CreateFrame("Button", nil, rcol)
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
  header(rcol, "Upcoming queue", RX, -298)
  checkbox(rcol, "Show queue", RX, -322,
    function() return o.showQueue end, function(v) o.showQueue = v end)
  slider(rcol, "Queue size", RX, -350, 1, 6, 1,
    function() return o.queueCount or 3 end, function(v) o.queueCount = v end)
  -- only list queued cues casting within this many seconds (10–30).
  slider(rcol, "Queue window (s)", RX, -404, 10, 30, 1,
    function() return o.queueWindow or 10 end, function(v) o.queueWindow = v end)

  -- ── right column: position ──
  -- (boss mechanics are intentionally NOT alerted here - BigWigs/DBM already
  -- call those out; CoolPlan focuses on the team's cooldowns.)
  header(rcol, "Position", RX, -458)
  -- Test = show/hide preview frames; Move = toggle dragging them (label flips to
  -- Lock). The two are independent (Move drags whatever is shown).
  local testBtn = button(rcol, "Test frames", 110, RX, -480, function() ns.Reminders.ToggleTest() end)
  local moveBtn = button(rcol, "Move", 90, RX + 118, -480, function() ns.Reminders.ToggleMover() end)
  ns.Reminders.SetModeButtonUpdater(function(moving, testing)
    if moveBtn then moveBtn:SetText(moving and "Lock" or "Move") end
    if testBtn then testBtn:SetText(testing and "Hide test" or "Test frames") end
  end)
  button(rcol, "Reset position", 120, RX, -506, function() ns.Reminders.ResetPositions() end)
  checkbox(rcol, "Show grid", RX, -534,
    function() return o.showGrid end,
    function(v) o.showGrid = v end)

  -- ── categories (moved up into the freed left/middle space; responsive grid
  -- that reflows its column count with the window width) ──
  header(host, "Show categories", LX, -262)
  local catBoxes = {}
  for _, c in ipairs(CATEGORIES) do
    local key = c[1]
    local cb = checkbox(host, c[2], LX, -288,
      function() return ns.DB.CategoryEnabled(key) end,
      function(v)
        -- enabled = nil (default-on), disabled = false. NOTE: `v and nil or false`
        -- is a Lua trap that always yields false - must branch explicitly.
        if v then o.categoryEnabled[key] = nil else o.categoryEnabled[key] = false end
      end)
    catBoxes[#catBoxes + 1] = cb
  end
  local CAT_COL_W, CAT_ROW_H, CAT_Y0 = 185, 28, -288
  local function layoutCategories()
    -- keep the grid clear of the right-hand HUD column (~250px)
    local avail = (host:GetWidth() or 720) - LX - 250
    local cols = math.max(1, math.floor(avail / CAT_COL_W))
    for i, cb in ipairs(catBoxes) do
      local c0 = (i - 1) % cols
      local r0 = math.floor((i - 1) / cols)
      cb:ClearAllPoints()
      cb:SetPoint("TOPLEFT", LX + c0 * CAT_COL_W, CAT_Y0 - r0 * CAT_ROW_H)
    end
  end
  layoutCategories()
  if host.HookScript then host:HookScript("OnSizeChanged", ns.wrap(layoutCategories)) end

  -- ── bottom buttons - pinned to the host's BOTTOM so they're always visible
  -- (responsive to window height) and never clip below the category grid.
  local testB = button(host, "Test alert", 110, 0, 0, function() ns.Reminders.Test() end)
  testB:ClearAllPoints(); testB:SetPoint("BOTTOMLEFT", host, "BOTTOMLEFT", LX, 10)
  local demoB = button(host, "Demo countdown", 140, 0, 0, function()
    if not ns.Scheduler.StartDemo() then ns.Print("demo failed.") end
  end)
  demoB:ClearAllPoints(); demoB:SetPoint("LEFT", testB, "RIGHT", 8, 0)
  local stopB = button(host, "Stop", 70, 0, 0, function() ns.Scheduler.Stop() end)
  stopB:ClearAllPoints(); stopB:SetPoint("LEFT", demoB, "RIGHT", 8, 0)
  local resetAllB = button(host, "Reset settings", 130, 0, 0,
    function() showResetConfirm() end)
  resetAllB:ClearAllPoints(); resetAllB:SetPoint("LEFT", stopB, "RIGHT", 8, 0)

  if ns.Style then
    ns.Style.Apply(host)
    ns.Style.Dropdown(modeDD)
    ns.Style.Dropdown(voiceDD)
    ns.Style.Dropdown(styleDD)
    ns.Style.Dropdown(timePosDD)
  end

  -- after styling (which paints the thumb brand-blue): reflect the saved lock
  -- state so a countdown-on session opens with the lead slider greyed/locked.
  applyCountdownLock(o.countdownVoice and true or false)

  syncAlertRows()
end

-- Back-compat: other code (and slash) call Options.Open() → open the shell page.
function Options.Open()
  ns.Window.Open("options")
end

ns.Window.RegisterPage("options", "Options", Options.BuildPage)
