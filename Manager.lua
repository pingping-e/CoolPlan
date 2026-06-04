-- Saved Plans page: a per-dungeon/boss browser of YOUR saved notes.
-- Top: Category dropdown (Mythic+ / Raid) → Dungeon/Instance dropdown → Boss
-- dropdown. Below: the selected boss's saved cooldown plans, each with Use /
-- Rename / Delete / Export / Share. A plan that carries a boss timeline shows a
-- "+boss" tag; the boss travels with the plan (deleting the plan removes it).
-- Embedded into the Window shell via Manager.BuildPage(host).

local _, ns = ...
local Manager = {}
ns.Manager = Manager

local ROW_H = 24
local CONTENT_W = 520

local page, content, empty, header
local catDD, grpDD, bossDD
local rows = {}

-- selection state (persists across page rebuilds within a session)
local selCat = "mythicplus"
local selGrp = 1     -- index into the category's groups
local selBoss = 1    -- index into the group's bosses
local selEnc = nil   -- resolved encounterID for the selected boss (may be nil)

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

  -- left label gets the space the action buttons don't use (button cluster ≈
  -- 5 buttons + roomy 7px gaps); keep it from crowding the first button.
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", 4, 0)
  row.text:SetJustifyH("LEFT")
  row.text:SetWidth(170)

  -- 7px gaps so the actions read as separate buttons instead of one strip.
  local GAP = 7
  row.exp = tinyBtn(row, "Export", 54); row.exp:SetPoint("RIGHT", -4, 0)
  row.del = tinyBtn(row, "Delete", 54); row.del:SetPoint("RIGHT", row.exp, "LEFT", -GAP, 0)
  row.shr = tinyBtn(row, "Share", 50);  row.shr:SetPoint("RIGHT", row.del, "LEFT", -GAP, 0)
  row.ren = tinyBtn(row, "Rename", 56); row.ren:SetPoint("RIGHT", row.shr, "LEFT", -GAP, 0)
  row.use = tinyBtn(row, "Use", 48);    row.use:SetPoint("RIGHT", row.ren, "LEFT", -GAP, 0)

  if ns.Style then
    ns.Style.Button(row.exp); ns.Style.Button(row.del); ns.Style.Button(row.shr)
    ns.Style.Button(row.ren); ns.Style.Button(row.use)
  end

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
    if ns.Style then
      ns.Style.Panel(prompt, 0.98)
    elseif prompt.SetBackdrop then
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
    if ns.Style then ns.Style.Apply(prompt) end
  end
  prompt.id, prompt.index = id, index
  prompt.box:SetText(current or "")
  prompt.box:HighlightText()
  prompt:Show()
  prompt.box:SetFocus()
end

-- ── list build (for the SELECTED encounter only) ─────────────────────────────
local function buildItems()
  local items = {}
  if not selEnc then return items end
  local e = ns.DB.GetEncounter(selEnc)
  if not e then return items end
  for i, p in ipairs(e.plans) do
    items[#items + 1] = { kind = "plan", id = selEnc, index = i, e = e, p = p }
  end
  return items
end

-- The currently selected boss (from the dropdowns), if any.
local function currentBoss()
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  return grp and grp.bosses and grp.bosses[selBoss] or nil
end

function Manager.Refresh()
  if not page then return end

  -- header reflects current selection (boss name; resolved or catalog)
  local boss = currentBoss()
  local name = (boss and boss.name) or (selEnc and ns.Window.EncounterName(selEnc)) or "—"
  header:SetText("|cffffd200" .. name .. "|r")

  local items = buildItems()

  for i, it in ipairs(items) do
    local row = getRow(i)
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
    row:Show()
    local e, id = it.e, it.id

    local active = (e.active == it.index)
    local bossTag = (it.p.boss and #it.p.boss > 0) and " |cffff7777+boss|r" or ""
    row.text:SetText(("%s|cff88ccff%s|r |cff888888(%d cd)|r%s"):format(
      active and "|cff66ff66> |r" or "", it.p.label, #it.p.reminders, bossTag))
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

  for i = #items + 1, #rows do rows[i]:Hide() end
  content:SetHeight(math.max(1, #items * ROW_H + 4))
  empty:SetShown(#items == 0)
  if page.scroll and page.scroll.UpdateScrollChildRect then page.scroll:UpdateScrollChildRect() end
end

-- ── dropdown item providers ──────────────────────────────────────────────────
-- group (dungeon / instance) dropdown for the selected category
local function grpItems()
  local items = {}
  for i, g in ipairs(ns.Window.Groups(selCat)) do
    items[#items + 1] = { text = g.name, value = i }
  end
  return items
end

-- boss dropdown for the selected group
local function bossItems()
  local items = {}
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  if grp then
    for i, b in ipairs(grp.bosses or {}) do
      items[#items + 1] = { text = b.name, value = i }
    end
  end
  return items
end

-- Resolve the selected boss → encounterID via the library (catalog id when
-- present, else name match).
local function resolveSelEnc()
  local boss = currentBoss()
  selEnc = boss and ns.Window.ResolveBossId(boss.name, boss.id) or nil
end

-- Clamp the group selection to the current category and refresh the group
-- dropdown's displayed text.
local function ensureGrpSelection()
  local groups = ns.Window.Groups(selCat)
  if not groups[selGrp] then selGrp = groups[1] and 1 or 1 end
  if grpDD then
    local g = groups[selGrp]
    grpDD:SetValue(g and selGrp or nil, g and g.name or "—")
  end
end

-- Clamp the boss selection to the current group, refresh the boss dropdown's
-- text, and re-resolve the encounterID.
local function ensureBossSelection()
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  local bosses = grp and grp.bosses or {}
  if not bosses[selBoss] then selBoss = bosses[1] and 1 or 1 end
  local boss = bosses[selBoss]
  if bossDD then
    bossDD:SetValue(boss and selBoss or nil, boss and boss.name or "—")
  end
  resolveSelEnc()
end

function Manager.BuildPage(host)
  page = host

  local hint = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 8, -6)
  hint:SetText("Pick a dungeon / boss to browse its saved notes. Use = make active (plays on pull).")

  -- category dropdown
  catDD = ns.Window.MakeDropdown(host, "CoolPlanMgrCatDD", 110,
    function()
      local items = {}
      for _, c in ipairs(ns.Window.Categories()) do
        items[#items + 1] = { text = c.label, value = c.key }
      end
      return items
    end,
    function(key)
      selCat = key
      selGrp = 1
      selBoss = 1
      ensureGrpSelection()
      ensureBossSelection()
      Manager.Refresh()
    end)
  catDD:SetPoint("TOPLEFT", -8, -24)
  do
    local cat = ns.Window.CategoryByKey(selCat) or ns.Window.Categories()[1]
    if cat then selCat = cat.key; catDD:SetValue(cat.key, cat.label) end
  end

  -- dungeon / instance dropdown
  grpDD = ns.Window.MakeDropdown(host, "CoolPlanMgrGrpDD", 180, grpItems,
    function(idx)
      selGrp = idx
      selBoss = 1
      ensureBossSelection()
      Manager.Refresh()
    end)
  grpDD:SetPoint("LEFT", catDD, "RIGHT", 4, 0)

  -- boss dropdown
  bossDD = ns.Window.MakeDropdown(host, "CoolPlanMgrBossDD", 180, bossItems,
    function(idx)
      selBoss = idx
      resolveSelEnc()
      Manager.Refresh()
    end)
  bossDD:SetPoint("LEFT", grpDD, "RIGHT", 4, 0)

  -- selected boss header
  header = host:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  header:SetPoint("TOPLEFT", 12, -64)

  -- scroll list of saved notes for the selected boss
  local sf = CreateFrame("ScrollFrame", "CoolPlanManagerScroll", host, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 8, -90)
  sf:SetPoint("BOTTOMRIGHT", -28, 44)
  host.scroll = sf

  content = CreateFrame("Frame", nil, sf)
  content:SetSize(CONTENT_W, 1)
  sf:SetScrollChild(content)

  empty = host:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
  empty:SetPoint("CENTER", sf, "CENTER", 0, 0)
  empty:SetWidth(420)
  empty:SetText("No saved notes for this boss.\nAdd one in the Import/Export tab.")
  empty:Hide()

  -- bottom: jump to import + share
  local importBtn = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  importBtn:SetSize(120, 22)
  importBtn:SetText("Import / Export")
  importBtn:SetPoint("BOTTOMLEFT", 8, 12)
  importBtn:SetScript("OnClick", function() ns.Window.Open("import") end)

  local shareBtn = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  shareBtn:SetSize(130, 22)
  shareBtn:SetText("Share to Party")
  shareBtn:SetPoint("LEFT", importBtn, "RIGHT", 8, 0)
  shareBtn:SetScript("OnClick", ns.wrap(function()
    if selEnc then ns.Comm.ShareEncounter(selEnc) else ns.Comm.ShareActive() end
  end))

  ensureGrpSelection()
  ensureBossSelection()

  -- refresh whenever the page becomes visible (re-resolve in case a new import
  -- now matches the selected boss by name)
  host._onShow = function()
    ensureGrpSelection()
    ensureBossSelection()
    Manager.Refresh()
  end

  if ns.Style then
    ns.Style.Apply(host)
    ns.Style.Dropdown(catDD); ns.Style.Dropdown(grpDD); ns.Style.Dropdown(bossDD)
  end
end

-- Back-compat for slash / other callers.
function Manager.Open()
  ns.Window.Open("saved")
end

ns.Window.RegisterPage("saved", "Saved Plans", Manager.BuildPage)
