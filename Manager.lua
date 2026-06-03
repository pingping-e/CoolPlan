-- Saved Plans manager: per-encounter library with multiple named plans.
-- List shows each boss's shared boss-timeline row + its cooldown plans, with
-- Use (set active) / Rename / Delete / Export per row, and Import new.

local _, ns = ...
local Manager = {}
ns.Manager = Manager

local ROW_H = 24
local CONTENT_W = 500

local frame, content, empty
local rows = {}

local function tinyBtn(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 20)
  b:SetText(text)
  return b
end

local function getRow(i)
  if rows[i] then return rows[i] end
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(CONTENT_W, 22)

  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", 4, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWidth(220)

  row.exp = tinyBtn(row, "Export", 52); row.exp:SetPoint("RIGHT", -2, 0)
  row.del = tinyBtn(row, "Delete", 52); row.del:SetPoint("RIGHT", row.exp, "LEFT", -3, 0)
  row.shr = tinyBtn(row, "Share", 48);  row.shr:SetPoint("RIGHT", row.del, "LEFT", -3, 0)
  row.ren = tinyBtn(row, "Rename", 52); row.ren:SetPoint("RIGHT", row.shr, "LEFT", -3, 0)
  row.use = tinyBtn(row, "Use", 44);    row.use:SetPoint("RIGHT", row.ren, "LEFT", -3, 0)

  rows[i] = row
  return row
end

-- ── rename prompt ────────────────────────────────────────────────────────────
local prompt
local function promptRename(id, index, current)
  if not prompt then
    prompt = CreateFrame("Frame", "CoolPlanRenamePrompt", UIParent, "BackdropTemplate")
    prompt:SetSize(320, 110)
    prompt:SetPoint("CENTER")
    prompt:SetFrameStrata("FULLSCREEN_DIALOG")
    if prompt.SetBackdrop then
      prompt:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
      })
    end
    local lbl = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    lbl:SetPoint("TOP", 0, -16); lbl:SetText("Rename plan:")
    local box = CreateFrame("EditBox", nil, prompt, "InputBoxTemplate")
    box:SetSize(260, 22); box:SetPoint("TOP", 0, -40); box:SetAutoFocus(true)
    prompt.box = box
    local ok = tinyBtn(prompt, "OK", 80); ok:SetPoint("BOTTOMRIGHT", -16, 14)
    local cancel = tinyBtn(prompt, "Cancel", 80); cancel:SetPoint("BOTTOMLEFT", 16, 14)
    local function accept()
      ns.DB.RenamePlan(prompt.id, prompt.index, prompt.box:GetText())
      prompt:Hide(); Manager.Refresh()
    end
    ok:SetScript("OnClick", ns.wrap(accept))
    box:SetScript("OnEnterPressed", ns.wrap(accept))
    box:SetScript("OnEscapePressed", function() prompt:Hide() end)
    cancel:SetScript("OnClick", function() prompt:Hide() end)
  end
  prompt.id, prompt.index = id, index
  prompt.box:SetText(current or "")
  prompt.box:HighlightText()
  prompt:Show()
  prompt.box:SetFocus()
end

-- ── list build ───────────────────────────────────────────────────────────────
local function buildItems()
  local lib = ns.DB.Library()
  local ids = {}
  for id in pairs(lib) do ids[#ids + 1] = id end
  table.sort(ids)

  local items = {}
  for _, id in ipairs(ids) do
    local e = lib[id]
    if e.boss and #e.boss > 0 then
      items[#items + 1] = { kind = "boss", id = id, e = e }
    end
    for i, p in ipairs(e.plans) do
      items[#items + 1] = { kind = "plan", id = id, index = i, e = e, p = p }
    end
  end
  return items
end

function Manager.Refresh()
  if not frame then return end
  local items = buildItems()

  for i, it in ipairs(items) do
    local row = getRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:Show()
    local e, id = it.e, it.id

    if it.kind == "boss" then
      row.text:SetText(("%s  |cffff7777Boss timeline|r |cff888888(%d mech)|r"):format(e.name or id, #e.boss))
      row.use:Hide()
      row.ren:Hide()
      row.shr:Hide()
      row.del:Show(); row.del:SetScript("OnClick", ns.wrap(function() ns.DB.DeleteBoss(id); Manager.Refresh() end))
      row.exp:Show(); row.exp:SetScript("OnClick", ns.wrap(function()
        ns.Editor.SetText(ns.Format.Serialize(ns.DB.ToSerializable(id), { source = "addon" }))
      end))
    else
      local active = (e.active == it.index)
      row.text:SetText(("%s%s  |cff88ccff%s|r |cff888888(%d cd)|r"):format(
        active and "|cff66ff66> |r" or "", e.name or id, it.p.label, #it.p.reminders))
      row.use:Show()
      row.use:SetText(active and "Active" or "Use")
      row.use:SetScript("OnClick", ns.wrap(function() ns.DB.SetActive(id, it.index); Manager.Refresh() end))
      row.ren:Show()
      row.ren:SetScript("OnClick", ns.wrap(function() promptRename(id, it.index, it.p.label) end))
      row.shr:Show()
      row.shr:SetScript("OnClick", ns.wrap(function()
        ns.DB.SetActive(id, it.index)   -- share what's shown on this row
        ns.Comm.ShareEncounter(id)
        Manager.Refresh()
      end))
      row.del:Show()
      row.del:SetScript("OnClick", ns.wrap(function() ns.DB.DeletePlan(id, it.index); Manager.Refresh() end))
      row.exp:Show()
      row.exp:SetScript("OnClick", ns.wrap(function()
        ns.Editor.SetText(ns.Format.Serialize(ns.DB.ToSerializable(id, it.index), { source = "addon" }))
      end))
    end
  end

  for i = #items + 1, #rows do rows[i]:Hide() end
  content:SetHeight(math.max(1, #items * ROW_H + 4))
  empty:SetShown(#items == 0)
  if frame.scroll.UpdateScrollChildRect then frame.scroll:UpdateScrollChildRect() end
end

local function build()
  local f = CreateFrame("Frame", "CoolPlanManager", UIParent, "BackdropTemplate")
  f:SetSize(560, 440)
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
  title:SetText("CoolPlan — Saved Plans")
  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 18, -40)
  hint:SetText("Use = make active (plays on pull). Multiple plans per boss are kept.")

  local sf = CreateFrame("ScrollFrame", "CoolPlanManagerScroll", f, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 16, -62)
  sf:SetPoint("BOTTOMRIGHT", -34, 50)
  f.scroll = sf

  content = CreateFrame("Frame", nil, sf)
  content:SetSize(CONTENT_W, 1)
  sf:SetScrollChild(content)

  empty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
  empty:SetPoint("CENTER", sf, "CENTER", 0, 0)
  empty:SetText("No saved plans.\nClick Import new… to add one.")
  empty:Hide()

  local importBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  importBtn:SetSize(110, 22)
  importBtn:SetText("Import new…")
  importBtn:SetPoint("BOTTOMLEFT", 18, 16)
  importBtn:SetScript("OnClick", function() ns.Editor.Open() end)

  local shareBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  shareBtn:SetSize(130, 22)
  shareBtn:SetText("Share to Party")
  shareBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
  shareBtn:SetScript("OnClick", ns.wrap(function() ns.Comm.ShareActive() end))

  local closeBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  closeBtn:SetSize(90, 22)
  closeBtn:SetText("Close")
  closeBtn:SetPoint("BOTTOMRIGHT", -18, 16)
  closeBtn:SetScript("OnClick", function() f:Hide() end)

  return f
end

function Manager.Open()
  if not frame then frame = build() end
  frame:Show()
  Manager.Refresh()
end
