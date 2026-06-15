-- Generic popup list picker - a single shared scrollable/searchable popup used
-- by EVERY select control in the addon (via Window.MakeDropdown) plus the sound
-- picker. Replaces the stock UIDropDownMenu look with a consistent dark list.
--
-- ns.Picker.Open(anchor, cfg) where cfg = {
--   width    = number,                       -- popup + button width
--   current  = value,                        -- highlighted entry
--   items    = { {text=, value=}, ... }      -- OR
--   getItems = function() -> items,          -- dynamic list
--   onPick   = function(value, text),        -- fired on click
--   search   = true | false | "auto",        -- "auto" shows search when >10 items
--   keepOpen = bool,                         -- stay open after a pick (sound audition)
--   title    = string,                       -- header label
-- }

local _, ns = ...
local Picker = {}
ns.Picker = Picker

local ROW_H = 18
local MAX_ROWS = 14
local popup

local function currentItems()
  local cfg = popup._cfg
  local list = cfg.items or (cfg.getItems and cfg.getItems()) or {}
  if popup.search:IsShown() then
    local f = popup.search:GetText()
    if f and f ~= "" then
      local lf = strlower(f)
      local out = {}
      for _, it in ipairs(list) do
        if strfind(strlower(it.text or ""), lf, 1, true) then out[#out + 1] = it end
      end
      return out
    end
  end
  return list
end

local function getRow(i)
  if popup.rows[i] then return popup.rows[i] end
  local row = CreateFrame("Button", nil, popup.content)
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", 6, 0)
  row.text:SetPoint("RIGHT", -6, 0)
  row.text:SetJustifyH("LEFT")
  if row.text.SetWordWrap then row.text:SetWordWrap(false) end
  row.hl = row:CreateTexture(nil, "HIGHLIGHT")
  row.hl:SetAllPoints()
  row.hl:SetColorTexture(1, 1, 1, 0.10)
  popup.rows[i] = row
  return row
end

function Picker.Refresh()
  if not popup or not popup._cfg then return end
  local list = currentItems()
  local w = (popup._w or 280) - 30
  for i, it in ipairs(list) do
    local row = getRow(i)
    row:SetSize(w, ROW_H)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 2, -(i - 1) * ROW_H)
    local active = (popup._cfg.current == it.value)
    row.text:SetText(active and ("|cff66ff66" .. (it.text or "") .. "|r") or (it.text or ""))
    row:SetScript("OnClick", ns.wrap(function()
      popup._cfg.current = it.value
      if popup._cfg.onPick then popup._cfg.onPick(it.value, it.text) end
      if popup._cfg.keepOpen then Picker.Refresh() else popup:Hide() end
    end))
    row:Show()
  end
  for i = #list + 1, #popup.rows do popup.rows[i]:Hide() end
  popup.content:SetHeight(math.max(1, #list * ROW_H + 4))
  if popup.scroll.UpdateScrollChildRect then popup.scroll:UpdateScrollChildRect() end
end

local function ensurePopup()
  if popup then return popup end
  -- click-away catcher: a full-screen button just below the popup that closes it
  local catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetFrameStrata("FULLSCREEN_DIALOG")
  catcher:SetAllPoints(UIParent)
  catcher:EnableMouse(true)
  catcher:RegisterForClicks("AnyUp")
  catcher:Hide()

  popup = CreateFrame("Frame", "CoolPlanPicker", UIParent, "BackdropTemplate")
  popup:SetFrameStrata("FULLSCREEN_DIALOG")
  popup:SetFrameLevel((catcher:GetFrameLevel() or 1) + 10)
  popup:EnableMouse(true)
  popup:SetClampedToScreen(true)
  popup.catcher = catcher
  catcher:SetScript("OnClick", ns.wrap(function() popup:Hide() end))

  if ns.Style and ns.Style.Panel then
    ns.Style.Panel(popup, 0.98)
  elseif popup.SetBackdrop then
    popup:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end

  popup.title = popup:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  popup.title:SetPoint("TOPLEFT", 12, -8)

  local close = CreateFrame("Button", nil, popup, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", 2, 2)
  close:SetScript("OnClick", ns.wrap(function() popup:Hide() end))

  popup.search = CreateFrame("EditBox", nil, popup, "InputBoxTemplate")
  popup.search:SetAutoFocus(false)
  popup.search:SetScript("OnTextChanged", ns.wrap(function() Picker.Refresh() end))
  popup.search:SetScript("OnEscapePressed", ns.wrap(function(self) self:ClearFocus(); popup:Hide() end))

  local sf = CreateFrame("ScrollFrame", "CoolPlanPickerScroll", popup, "UIPanelScrollFrameTemplate")
  sf:EnableMouseWheel(true)
  sf:SetScript("OnMouseWheel", ns.wrap(function(self, delta)
    local cur = self:GetVerticalScroll()
    local maxS = self:GetVerticalScrollRange()
    local nextS = cur - delta * ROW_H * 3
    if nextS < 0 then nextS = 0 elseif nextS > maxS then nextS = maxS end
    self:SetVerticalScroll(nextS)
  end))
  local content = CreateFrame("Frame", nil, sf)
  content:SetSize(180, 1)
  sf:SetScrollChild(content)
  popup.scroll = sf
  popup.content = content
  popup.rows = {}

  popup:SetScript("OnHide", ns.wrap(function()
    if popup.search then popup.search:SetText("") end
    if popup.catcher then popup.catcher:Hide() end
  end))
  -- Esc closes even when the search box isn't focused.
  if UISpecialFrames and not tContains(UISpecialFrames, "CoolPlanPicker") then
    tinsert(UISpecialFrames, "CoolPlanPicker")
  end
  if ns.Style and ns.Style.Apply then ns.Style.Apply(popup) end
  popup:Hide()
  return popup
end

function Picker.Open(anchor, cfg)
  ensurePopup()
  popup._cfg = cfg
  -- the opened popup is wider than its button so long values (TTS voice / sound
  -- names) are readable; SetClampedToScreen keeps the right edge on screen.
  local W = math.max(cfg.width or 200, 280)
  popup._w = W
  popup:SetWidth(W)
  popup.title:SetText(cfg.title or "")

  local list = cfg.items or (cfg.getItems and cfg.getItems()) or {}
  local showSearch = (cfg.search == true) or (cfg.search == "auto" and #list > 10)
  local top
  if showSearch then
    popup.search:ClearAllPoints()
    popup.search:SetPoint("TOPLEFT", 14, -28)
    popup.search:SetSize(W - 30, 20)
    popup.search:Show()
    top = 52
  else
    popup.search:Hide()
    top = 24
  end

  local visRows = math.min(math.max(#list, 1), MAX_ROWS)
  local listH = visRows * ROW_H + 6
  popup.scroll:ClearAllPoints()
  popup.scroll:SetPoint("TOPLEFT", 10, -top)
  popup.scroll:SetSize(W - 28, listH)
  popup.content:SetWidth(W - 28)
  popup:SetHeight(top + listH + 12)

  popup:ClearAllPoints()
  if anchor then
    -- nudge right a touch so it sits inside the window edge, not poking out
    popup:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 8, -2)
  else
    popup:SetPoint("CENTER")
  end

  popup.catcher:Show()
  popup:Show()
  popup.search:SetText("")
  Picker.Refresh()
  if showSearch then popup.search:SetFocus() end
end

function Picker.IsShown() return popup and popup:IsShown() end
function Picker.Hide() if popup then popup:Hide() end end
