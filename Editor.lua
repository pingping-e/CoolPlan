-- Import / Export window. Because the CoolPlan format is human-readable, the
-- multiline text box IS the editor: paste a plan from coolplan.team, tweak times
-- and spell IDs directly, Load to store it; Export All dumps stored plans back.

local _, ns = ...
local Editor = {}
ns.Editor = Editor

local frame

local function makeButton(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

local function build()
  local f = CreateFrame("Frame", "CoolPlanEditor", UIParent, "BackdropTemplate")
  f:SetSize(580, 470)
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
  title:SetText("CoolPlan — Import / Export")

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 18, -42)
  help:SetPoint("TOPRIGHT", -18, -42)
  help:SetJustifyH("LEFT")
  help:SetText("Paste a plan from coolplan.team and click Load Plans. You can edit times / spell IDs directly in the text and Load again. Export All dumps your stored plans (Ctrl-C to copy).")

  local sf = CreateFrame("ScrollFrame", "CoolPlanEditorScroll", f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 18, -82)
  sf:SetPoint("BOTTOMRIGHT", -38, 84)

  local eb = CreateFrame("EditBox", "CoolPlanEditorBox", sf)
  eb:SetMultiLine(true)
  eb:SetFontObject(ChatFontNormal)
  eb:SetAutoFocus(false)
  eb:SetWidth(500)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eb:SetScript("OnTextChanged", function(self)
    -- keep scroll child sized to content
    sf:UpdateScrollChildRect()
  end)
  sf:SetScrollChild(eb)
  f.editbox = eb

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", 18, 52)
  status:SetPoint("BOTTOMRIGHT", -18, 52)
  status:SetJustifyH("LEFT")
  f.status = status

  local loadBtn = makeButton(f, "Load Plans", 110)
  loadBtn:SetPoint("BOTTOMRIGHT", -18, 18)
  loadBtn:SetScript("OnClick", function()
    local plans, _, err = ns.Format.Parse(f.editbox:GetText())
    if not plans then
      f.status:SetText("|cffff5555" .. (err or "parse error") .. "|r")
      return
    end
    local enc, rem, bos = 0, 0, 0
    for id, plan in pairs(plans) do
      local existing = ns.DB.Plans()[id]
      -- Preserve an existing boss timeline when importing a team-only plan, so
      -- you can layer different teams' cooldowns onto the same boss.
      if existing and existing.boss and not plan.boss then
        plan.boss = existing.boss
      end
      ns.DB.Plans()[id] = plan
      enc = enc + 1
      rem = rem + #plan.reminders
      bos = bos + (plan.boss and #plan.boss or 0)
    end
    if enc == 0 then
      f.status:SetText("|cffffcc55Parsed OK but found 0 encounters.|r")
    else
      f.status:SetText(("|cff66ff66Loaded %d encounter(s), %d reminders, %d boss mechanics.|r"):format(enc, rem, bos))
    end
  end)

  local exportBtn = makeButton(f, "Export All", 110)
  exportBtn:SetPoint("RIGHT", loadBtn, "LEFT", -8, 0)
  exportBtn:SetScript("OnClick", function()
    local str = ns.Format.Serialize(ns.DB.Plans(), { source = "addon" })
    f.editbox:SetText(str)
    f.editbox:SetFocus()
    f.editbox:HighlightText()
    f.status:SetText("Exported stored plans. Ctrl-C to copy.")
  end)

  local clearBtn = makeButton(f, "Clear Box", 110)
  clearBtn:SetPoint("RIGHT", exportBtn, "LEFT", -8, 0)
  clearBtn:SetScript("OnClick", function()
    f.editbox:SetText("")
    f.status:SetText("")
  end)

  return f
end

function Editor.Open()
  if not frame then frame = build() end
  frame:Show()
end
