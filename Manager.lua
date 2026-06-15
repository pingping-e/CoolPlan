-- Saved Plans page: a per-dungeon/boss browser of YOUR saved notes.
-- Top: Category dropdown (Mythic+ / Raid) → Dungeon/Instance dropdown → Boss
-- dropdown. Below: the selected boss's saved cooldown plans, each with Use /
-- Rename / Delete / Export / Share. A plan's boss timeline (if any) travels with
-- it silently - display-only on the Timeline view, so it's not surfaced here.
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

-- The green "Active" chip - deliberately a different shape/colour from the gray
-- action buttons so the active plan reads as a STATUS, not as one more setting.
-- It's also a toggle: clicking the active chip disarms the encounter (none
-- active → nothing plays on pull). (Previously the "Use" button just relabelled
-- itself to "Active", which conflated the toggle with its state.)
local function makeBadge(parent, w)
  local f = CreateFrame("Button", nil, parent)
  f:SetSize(w, 18)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.16, 0.40, 0.20, 0.85)        -- green tint
  if ns.Style and ns.Style.Border then
    ns.Style.Border(f, { 0.35, 0.78, 0.42, 1 })     -- green 1px border (shared helper)
  end
  local hl = f:CreateTexture(nil, "HIGHLIGHT")        -- hover hint: it's clickable
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.12)
  local fs = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  fs:SetPoint("CENTER")
  fs:SetText("Active")                               -- green badge; ASCII-only (some client fonts lack glyphs)
  fs:SetTextColor(0.66, 1.0, 0.66)                   -- bright green text
  f.text = fs
  return f
end

local function getRow(i)
  if rows[i] then return rows[i] end
  local row = CreateFrame("Frame", nil, content)
  row:SetSize(CONTENT_W, 22)

  -- LEFT cluster: the active/use control sits next to the plan name, apart from
  -- the right-side settings buttons. "Use Plan" and the green "Active" chip share
  -- one slot (mutually exclusive): non-active rows show the button, the active
  -- row shows the chip.
  row.use = tinyBtn(row, "Use Plan", 72)
  row.use:SetPoint("LEFT", 4, 0)
  row.active = makeBadge(row, 72)
  row.active:SetPoint("LEFT", 4, 0)
  row.active:Hide()

  -- plan label, anchored after the control (anchor holds even while `use` is
  -- hidden, so the chip and button align to the same x).
  row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  row.text:SetPoint("LEFT", row.use, "RIGHT", 10, 0)
  row.text:SetJustifyH("LEFT")
  -- one-line, no wrap: long "Shared from X" names clip instead of wrapping under
  -- the row. The right edge is clamped to the buttons (set after they exist).
  if row.text.SetWordWrap then row.text:SetWordWrap(false) end

  -- 7px gaps so the actions read as separate buttons instead of one strip.
  -- Widths give each label comfortable padding (Rename is the widest word).
  local GAP = 7
  -- Delete is the rightmost (most destructive) action; others sit to its left.
  row.del = tinyBtn(row, "|cffff6666Delete|r", 60); row.del:SetPoint("RIGHT", -4, 0)
  row.exp = tinyBtn(row, "Export", 62); row.exp:SetPoint("RIGHT", row.del, "LEFT", -GAP, 0)
  row.shr = tinyBtn(row, "Send", 56);  row.shr:SetPoint("RIGHT", row.exp, "LEFT", -GAP, 0)
  row.ren = tinyBtn(row, "Rename", 72); row.ren:SetPoint("RIGHT", row.shr, "LEFT", -GAP, 0)

  -- clamp the name's right edge to the leftmost button so it never overlaps or
  -- wraps; combined with SetWordWrap(false) above, long names clip on one line.
  row.text:SetPoint("RIGHT", row.ren, "LEFT", -10, 0)

  if ns.Style then
    ns.Style.Button(row.exp); ns.Style.Button(row.del)
    ns.Style.Button(row.shr); ns.Style.Button(row.ren); ns.Style.Button(row.use)
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
    box:SetScript("OnEscapePressed", ns.wrap(function() prompt:Hide() end))
    cancel:SetScript("OnClick", ns.wrap(function() prompt:Hide() end))
    if ns.Style then ns.Style.Apply(prompt) end
  end
  prompt.id, prompt.index = id, index
  prompt.box:SetText(current or "")
  prompt.box:HighlightText()
  prompt:Show()
  prompt.box:SetFocus()
end

-- ── share-dungeon popup ──────────────────────────────────────────────────────
-- A self-built frame (NOT Blizzard StaticPopupDialogs - that taints the shared
-- global). Lists the selected dungeon's bosses; bosses with an active plan get a
-- checkbox (checked), bosses without are greyed/skipped. Shares the ACTIVE plan
-- of each checked boss in one transfer.
local sharePrompt

-- The selected dungeon's bosses with their active-plan status.
-- Unique caster names in a plan (first-seen order) for the share popup - shows
-- WHO is in the plan rather than the plan label. reminders is an in-memory table
-- (already parsed), so this is cheap even across all bosses.
local function planCasters(plan)
  local seen, names = {}, {}
  for _, r in ipairs(plan and plan.reminders or {}) do
    local p = r.player
    if p and p ~= "" and not seen[p] then
      seen[p] = true
      names[#names + 1] = p
    end
  end
  return table.concat(names, ", ")
end

local function dungeonShareList()
  local out = {}
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  if not grp then return out end
  for _, b in ipairs(grp.bosses or {}) do
    local id = ns.Window.ResolveBossId(b.name, b.id)
    local plan
    if id then
      local e = ns.DB.GetEncounter(id)
      if e and e.active and e.active > 0 and e.plans[e.active] then
        plan = e.plans[e.active]
      end
    end
    out[#out + 1] = { name = b.name, id = id, plan = plan } -- plan nil = skipped
  end
  return out
end

local function shareRow(f, i)
  if f.rows[i] then return f.rows[i] end
  local r = CreateFrame("Frame", nil, f)
  r:SetSize(448, 20)
  r.cb = CreateFrame("CheckButton", nil, r, "UICheckButtonTemplate")
  r.cb:SetSize(20, 20)
  r.cb:SetPoint("LEFT", 0, 0)
  r.txt = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  -- explicit SetFontObject (not just the template arg) so the font's CJK/Hangul
  -- fallback chain is applied - same fix that made the import EditBox render 한글.
  if GameFontHighlightSmall then r.txt:SetFontObject(GameFontHighlightSmall) end
  r.txt:SetPoint("LEFT", r.cb, "RIGHT", 4, 0)
  r.txt:SetPoint("RIGHT", -4, 0)
  r.txt:SetJustifyH("LEFT")
  -- one line, no wrap: long caster lists clip instead of wrapping into the next
  -- row (wrapping made rows overlap). The wider popup fits a 5-man list on a line.
  if r.txt.SetWordWrap then r.txt:SetWordWrap(false) end
  f.rows[i] = r
  return r
end

local function buildSharePrompt()
  local f = CreateFrame("Frame", "CoolPlanShareDungeon", UIParent, "BackdropTemplate")
  f:SetSize(500, 200)
  f:SetPoint("CENTER")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetToplevel(true)
  f:EnableMouse(true)
  f:SetMovable(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  if ns.Style and ns.Style.Panel then
    ns.Style.Panel(f, 0.98)
  elseif f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOPLEFT", 16, -14)
  f.sub = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  f.sub:SetPoint("TOPLEFT", 16, -34)
  f.sub:SetText("Active plan per boss. Row names must match party members.")
  f.rows = {}
  f.shareBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.shareBtn:SetSize(150, 22)
  f.shareBtn:SetPoint("BOTTOMRIGHT", -16, 14)
  f.cancelBtn = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  f.cancelBtn:SetSize(90, 22)
  f.cancelBtn:SetPoint("BOTTOMLEFT", 16, 14)
  f.cancelBtn:SetText("Cancel")
  f.cancelBtn:SetScript("OnClick", ns.wrap(function() f:Hide() end))
  if UISpecialFrames and not tContains(UISpecialFrames, "CoolPlanShareDungeon") then
    tinsert(UISpecialFrames, "CoolPlanShareDungeon") -- Esc closes
  end
  if ns.Style then ns.Style.Apply(f) end
  return f
end

local function openShareDungeon()
  sharePrompt = sharePrompt or buildSharePrompt()
  local f = sharePrompt
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  f.title:SetText("Send this dungeon - " .. ((grp and grp.name) or "-"))

  local list = dungeonShareList()
  local shown = 0
  local y = -56
  for _, item in ipairs(list) do
    shown = shown + 1
    local r = shareRow(f, shown)
    r:ClearAllPoints(); r:SetPoint("TOPLEFT", 16, y); r:Show()
    y = y - 26
    if item.plan then
      r.cb:Show(); r.cb:Enable(); r.cb:SetChecked(true)
      local who = planCasters(item.plan)
      if who == "" then who = item.plan.label or "?" end
      -- keep the caster names OUTSIDE the color code: Hangul/CJK inside a |c..|r
      -- color escape can render as boxes on some clients; plain text is fine.
      r.txt:SetText(("|cff88ccff%s|r  %s"):format(item.name, who))
      r._id, r._has = item.id, true
    else
      r.cb:Hide(); r.cb:SetChecked(false)
      r.txt:SetText(("|cff666666%s  (no active plan)|r"):format(item.name))
      r._id, r._has = nil, false
    end
  end
  for i = shown + 1, #f.rows do f.rows[i]:Hide() end

  local function checkedIds()
    local ids = {}
    for i = 1, shown do
      local r = f.rows[i]
      if r._has and r.cb:GetChecked() then ids[#ids + 1] = r._id end
    end
    return ids
  end
  local function updateCount()
    local n = #checkedIds()
    f.shareBtn:SetText(("Send to party (%d)"):format(n))
    if n > 0 then f.shareBtn:Enable() else f.shareBtn:Disable() end
  end
  for i = 1, shown do
    local r = f.rows[i]
    r.cb:SetScript("OnClick", r._has and ns.wrap(updateCount) or nil)
  end
  f.shareBtn:SetScript("OnClick", ns.wrap(function()
    local ids = checkedIds()
    if #ids == 0 then return end
    f:Hide()
    ns.Comm.ShareEncounters(ids)
  end))

  f:SetHeight(math.max(160, 60 + math.max(1, shown) * 26 + 46))
  updateCount()
  f:Show()
end

-- ── clear-whole-dungeon confirm ──────────────────────────────────────────────
-- Delete every saved plan for every boss in the selected dungeon at once.
-- Uses a self-built confirm frame (NOT Blizzard StaticPopupDialogs - that taints
-- the shared dialog system). Destructive, so it always confirms first.
local clearConfirm
local function openClearDungeon()
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  if not grp then return end

  if not clearConfirm then
    local c = CreateFrame("Frame", "CoolPlanClearConfirm", UIParent, "BackdropTemplate")
    c:SetSize(340, 130)
    c:SetPoint("CENTER")
    c:SetFrameStrata("FULLSCREEN_DIALOG")
    if ns.Style and ns.Style.Panel then ns.Style.Panel(c, 0.98) end
    c.text = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.text:SetPoint("TOP", 0, -18)
    c.text:SetWidth(308)
    c.text:SetJustifyH("CENTER")
    c.yes = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.yes:SetSize(120, 22)
    c.yes:SetText("|cffff6666Delete all|r")
    c.yes:SetPoint("BOTTOMRIGHT", c, "BOTTOM", -6, 16)
    c.no = CreateFrame("Button", nil, c, "UIPanelButtonTemplate")
    c.no:SetSize(120, 22)
    c.no:SetText("Cancel")
    c.no:SetPoint("BOTTOMLEFT", c, "BOTTOM", 6, 16)
    c.yes:SetScript("OnClick", ns.wrap(function()
      c:Hide()
      if c._onYes then c._onYes() end
    end))
    c.no:SetScript("OnClick", ns.wrap(function() c:Hide() end))
    if UISpecialFrames and not tContains(UISpecialFrames, "CoolPlanClearConfirm") then
      tinsert(UISpecialFrames, "CoolPlanClearConfirm") -- Esc closes
    end
    if ns.Style then ns.Style.Apply(c) end
    clearConfirm = c
  end

  clearConfirm.text:SetText(
    ("Delete ALL saved plans for\n|cffffd200%s|r ?\n\n|cffff6666This cannot be undone.|r")
      :format(grp.name or "?"))
  clearConfirm._onYes = function()
    local n = 0
    for _, b in ipairs(grp.bosses or {}) do
      local encId = ns.Window.ResolveBossId(b.name, b.id)
      if encId and ns.DB.DeleteEncounter(encId) then n = n + 1 end
    end
    ns.Print(("cleared %d boss plan set(s) in %s."):format(n, grp.name or "?"))
    Manager.Refresh()
  end
  clearConfirm:Show()
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
    row:SetPoint("TOPRIGHT", 0, -(i - 1) * ROW_H) -- fill content width so right buttons reach the edge
    row:Show()
    local e, id = it.e, it.id

    local active = (e.active == it.index)
    row.text:SetText(("|cff88ccff%s|r |cff888888(%d cd)|r"):format(it.p.label, #it.p.reminders))
    if active then
      row.use:Hide(); row.active:Show()
      row.active:SetScript("OnClick", ns.wrap(function() ns.DB.SetActive(id, 0); Manager.Refresh() end))
      row.active:SetScript("OnEnter", ns.wrap(function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Active plan")
        GameTooltip:AddLine("Click to deactivate. Nothing will play on pull.", 0.8, 0.8, 0.8, true)
        GameTooltip:Show()
      end))
      row.active:SetScript("OnLeave", ns.wrap(function() GameTooltip:Hide() end))
    else
      row.active:Hide(); row.use:Show()
      row.use:SetScript("OnClick", ns.wrap(function() ns.DB.SetActive(id, it.index); Manager.Refresh() end))
    end
    row.ren:Show()
    row.ren:SetScript("OnClick", ns.wrap(function() promptRename(id, it.index, it.p.label) end))
    row.shr:Show()
    row.shr:SetScript("OnClick", ns.wrap(function()
      -- send THIS plan verbatim; does NOT change your active plan (index arg).
      ns.Comm.ShareEncounter(id, it.index)
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
  hint:SetText("Pick a dungeon / boss to see its plans. Use Plan = arm (plays on pull); click the green Active chip to disarm.")

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
  catDD:SetPoint("TOPLEFT", 4, -24)
  do
    local cat = ns.Window.CategoryByKey(selCat) or ns.Window.Categories()[1]
    if cat then selCat = cat.key; catDD:SetValue(cat.key, cat.label) end
  end

  -- dungeon / instance dropdown
  grpDD = ns.Window.MakeDropdown(host, "CoolPlanMgrGrpDD", 210, grpItems,
    function(idx)
      selGrp = idx
      selBoss = 1
      ensureBossSelection()
      Manager.Refresh()
    end)
  grpDD:SetPoint("LEFT", catDD, "RIGHT", 8, 0)

  -- dungeon-level action: share every boss's active plan in this dungeon (popup
  -- lets you pick a subset). Sits on the dungeon row, BEFORE the boss selector,
  -- so its scope reads as "this dungeon", not "this boss".
  local shareDungeonBtn = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  shareDungeonBtn:SetSize(170, 22)
  shareDungeonBtn:SetText("Send this dungeon")
  shareDungeonBtn:SetPoint("LEFT", grpDD, "RIGHT", 12, 0)
  shareDungeonBtn:SetScript("OnClick", ns.wrap(openShareDungeon))

  -- dungeon-level action: delete every saved plan in this dungeon (confirms).
  local clearDungeonBtn = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  clearDungeonBtn:SetSize(150, 22)
  -- inline color code (not SetTextColor) so the red survives UIPanelButton's
  -- hover/state restyling.
  clearDungeonBtn:SetText("|cffff6666Delete this dungeon|r")
  clearDungeonBtn:SetPoint("LEFT", shareDungeonBtn, "RIGHT", 8, 0)
  clearDungeonBtn:SetScript("OnClick", ns.wrap(openClearDungeon))

  -- boss dropdown (second row - a drilldown under the dungeon)
  bossDD = ns.Window.MakeDropdown(host, "CoolPlanMgrBossDD", 210, bossItems,
    function(idx)
      selBoss = idx
      resolveSelEnc()
      Manager.Refresh()
    end)
  bossDD:SetPoint("TOPLEFT", catDD, "BOTTOMLEFT", 0, -6)

  -- selected boss header
  header = host:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  header:SetPoint("TOPLEFT", bossDD, "BOTTOMLEFT", 20, -12)

  -- scroll list of saved notes for the selected boss
  local sf = CreateFrame("ScrollFrame", "CoolPlanManagerScroll", host, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", header, "BOTTOMLEFT", -12, -8)
  -- right edge aligns to the "Delete this dungeon" button so the per-row action
  -- buttons (right-anchored in each row) line up under it instead of running all
  -- the way to the scrollbar.
  sf:SetPoint("BOTTOM", host, "BOTTOM", 0, 12)
  sf:SetPoint("RIGHT", clearDungeonBtn, "RIGHT", 0, 0)
  host.scroll = sf

  content = CreateFrame("Frame", nil, sf)
  content:SetSize(CONTENT_W, 1)
  sf:SetScrollChild(content)

  -- keep the scroll child as wide as the viewport so rows (and their right-aligned
  -- buttons) fill the panel instead of stopping at a fixed 520px.
  local function syncContentWidth()
    local w = sf:GetWidth()
    if w and w > 1 then content:SetWidth(w) end
  end
  sf:SetScript("OnSizeChanged", ns.wrap(syncContentWidth))
  syncContentWidth()

  empty = host:CreateFontString(nil, "OVERLAY", "GameFontDisableLarge")
  empty:SetPoint("CENTER", sf, "CENTER", 0, 0)
  empty:SetWidth(420)
  empty:SetText("No saved notes for this boss.\nAdd one in the Import/Export tab.")
  empty:Hide()

  -- (no bottom Import/Export button - the left nav already has an Import tab)

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
