-- Import / Export window. The human-readable format means the multiline box IS
-- the editor: paste a plan from coolplan.team, optionally name it, and Load to
-- ADD it to that encounter's saved list (existing plans are kept). Export All
-- dumps each encounter's active plan back out.

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
  f:SetSize(600, 480)
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

  local savedBtn = makeButton(f, "Saved Plans", 110)
  savedBtn:SetPoint("TOPLEFT", 14, -12)
  savedBtn:SetScript("OnClick", function() ns.Manager.Open() end)

  local help = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 18, -42)
  help:SetPoint("TOPRIGHT", -18, -42)
  help:SetJustifyH("LEFT")
  help:SetText("Paste a plan from coolplan.team, optionally name it, and Load to ADD it to that boss's saved list (existing plans are kept). You can edit times / spell IDs directly. Export All dumps each boss's active plan.")

  local sf = CreateFrame("ScrollFrame", "CoolPlanEditorScroll", f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 18, -86)
  sf:SetPoint("BOTTOMRIGHT", -38, 86)

  local eb = CreateFrame("EditBox", "CoolPlanEditorBox", sf)
  eb:SetMultiLine(true)
  eb:SetFontObject(ChatFontNormal)
  eb:SetAutoFocus(false)
  eb:SetWidth(520)
  eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  eb:SetScript("OnTextChanged", function() sf:UpdateScrollChildRect() end)
  sf:SetScrollChild(eb)
  f.editbox = eb

  local status = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", 18, 50)
  status:SetPoint("BOTTOMRIGHT", -18, 50)
  status:SetJustifyH("LEFT")
  f.status = status

  -- name field (bottom-left)
  local nameLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nameLabel:SetPoint("BOTTOMLEFT", 18, 24)
  nameLabel:SetText("Plan name:")
  local nameBox = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
  nameBox:SetSize(150, 20)
  nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
  nameBox:SetAutoFocus(false)
  nameBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
  f.nameBox = nameBox

  -- buttons (bottom-right)
  local loadBtn = makeButton(f, "Load Plans", 100)
  loadBtn:SetPoint("BOTTOMRIGHT", -18, 18)
  loadBtn:SetScript("OnClick", ns.wrap(function()
    local plans, _, err = ns.Format.Parse(f.editbox:GetText())
    if not plans then
      f.status:SetText("|cffff5555" .. (err or "parse error") .. "|r")
      return
    end
    -- count encounters so a typed name only applies to a single-encounter import
    local nEnc = 0
    for _ in pairs(plans) do nEnc = nEnc + 1 end
    local typed = f.nameBox:GetText()
    if typed == "" then typed = nil end

    local added, bossOnly = 0, 0
    for id, parsed in pairs(plans) do
      local label = (nEnc == 1) and typed or nil
      local idx = ns.DB.AddPlan(id, parsed.name, label, parsed.reminders, parsed.boss)
      if idx == 0 then bossOnly = bossOnly + 1 else added = added + 1 end
    end
    f.nameBox:SetText("")
    f.status:SetText(("|cff66ff66Added %d plan(s)%s.|r"):format(
      added, bossOnly > 0 and (", refreshed %d boss timeline(s)"):format(bossOnly) or ""))
    if ns.Manager then ns.Manager.Refresh() end
  end))

  local exportBtn = makeButton(f, "Export All", 100)
  exportBtn:SetPoint("RIGHT", loadBtn, "LEFT", -8, 0)
  exportBtn:SetScript("OnClick", ns.wrap(function()
    local str = ns.Format.Serialize(ns.DB.ToSerializable(), { source = "addon" })
    f.editbox:SetText(str)
    f.editbox:SetFocus()
    f.editbox:HighlightText()
    f.status:SetText("Exported active plans. Ctrl-C to copy.")
  end))

  local clearBtn = makeButton(f, "Clear Box", 90)
  clearBtn:SetPoint("RIGHT", exportBtn, "LEFT", -8, 0)
  clearBtn:SetScript("OnClick", function()
    f.editbox:SetText("")
    f.status:SetText("")
  end)

  return f
end

-- Open and drop a string into the box (used by the manager's per-plan export).
function Editor.SetText(str)
  if not frame then frame = build() end
  frame:Show()
  frame.editbox:SetText(str or "")
  frame.editbox:SetFocus()
  frame.editbox:HighlightText()
  frame.status:SetText("Exported. Ctrl-C to copy.")
end

function Editor.Open()
  if not frame then frame = build() end
  frame:Show()
end
