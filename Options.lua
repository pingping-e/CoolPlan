-- Simple options window (raw frames, no libs): channel toggles, lead-time
-- slider, filter-to-me, plus quick access to the editor and a test button.

local _, ns = ...
local Options = {}
ns.Options = Options

local frame

local function checkbox(parent, label, x, y, getter, setter)
  local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
  cb:SetPoint("TOPLEFT", x, y)
  cb:SetChecked(getter() and true or false)
  local fs = cb:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  fs:SetPoint("LEFT", cb, "RIGHT", 4, 0)
  fs:SetText(label)
  cb:SetScript("OnClick", function(self) setter(self:GetChecked() and true or false) end)
  return cb
end

local function build()
  local o = ns.DB.Options()

  local f = CreateFrame("Frame", "CoolPlanOptions", UIParent, "BackdropTemplate")
  f:SetSize(380, 340)
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

  checkbox(f, "On-screen text", 22, -48,
    function() return o.textEnabled end, function(v) o.textEnabled = v end)
  checkbox(f, "Sound alert", 22, -78,
    function() return o.soundEnabled end, function(v) o.soundEnabled = v end)
  checkbox(f, "Text-to-speech (TTS)", 22, -108,
    function() return o.ttsEnabled end, function(v) o.ttsEnabled = v end)
  checkbox(f, "Only my character's cooldowns", 22, -138,
    function() return o.filterToMe end, function(v) o.filterToMe = v end)

  local sliderLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  sliderLabel:SetPoint("TOPLEFT", 22, -180)
  sliderLabel:SetText("Lead time: " .. (o.leadSeconds or 3) .. "s")

  local slider = CreateFrame("Slider", "CoolPlanLeadSlider", f, "OptionsSliderTemplate")
  slider:SetPoint("TOPLEFT", 26, -206)
  slider:SetWidth(300)
  slider:SetMinMaxValues(0, 10)
  slider:SetValueStep(1)
  slider:SetObeyStepOnDrag(true)
  slider:SetValue(o.leadSeconds or 3)
  _G[slider:GetName() .. "Low"]:SetText("0s")
  _G[slider:GetName() .. "High"]:SetText("10s")
  _G[slider:GetName() .. "Text"]:SetText("")
  slider:SetScript("OnValueChanged", function(_, val)
    val = math.floor(val + 0.5)
    o.leadSeconds = val
    sliderLabel:SetText("Lead time: " .. val .. "s")
  end)

  local testBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  testBtn:SetSize(130, 24)
  testBtn:SetText("Test alert")
  testBtn:SetPoint("BOTTOMLEFT", 22, 18)
  testBtn:SetScript("OnClick", function() ns.Reminders.Test() end)

  local editBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  editBtn:SetSize(150, 24)
  editBtn:SetText("Import / Export")
  editBtn:SetPoint("BOTTOMRIGHT", -22, 18)
  editBtn:SetScript("OnClick", function() ns.Editor.Open() end)

  return f
end

function Options.Open()
  if not frame then frame = build() end
  frame:Show()
end
