-- Timeline page: pick a category → dungeon/instance → boss → saved note, render
-- the note's cooldowns as a horizontal per-player timeline (spell icons placed
-- at their cast time), with a separate red boss track on top. A Test button
-- plays the note back live (Scheduler preview mode) with a moving playhead;
-- Shift+click runs it at 3x. Clicking again while playing stops it.
-- Embedded into the Window shell via Timeline.BuildPage(host).

local _, ns = ...
local Timeline = {}
ns.Timeline = Timeline

local PX_PER_SEC = 36          -- horizontal scale
local ROW_H = 26               -- per-player row height
local LABEL_W = 96             -- left gutter for player/track names
local BOSS_ROW_H = 26
local ICON = 20

local page, catDD, grpDD, bossDD, noteDD, testBtn, status
local scroll, canvas, playhead
local markerPool = {}          -- reusable icon markers
local rowPool = {}             -- reusable per-track background rows
local labelPool = {}

local selCat = "mythicplus"
local selGrp = 1               -- index into the category's groups
local selBoss = 1              -- index into the group's bosses
local selEnc = nil             -- resolved encounterID for the selected boss
local selNote = nil            -- plan index within the encounter

-- ── spell info ───────────────────────────────────────────────────────────────
local function spellIcon(spellId)
  if C_Spell and C_Spell.GetSpellTexture then
    local tex = C_Spell.GetSpellTexture(spellId)
    if tex then return tex end
  end
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellId)
    if info and info.iconID then return info.iconID end
  end
  if _G.GetSpellTexture then return _G.GetSpellTexture(spellId) end
  return nil
end

-- ── pools ────────────────────────────────────────────────────────────────────
local function getMarker(i)
  if markerPool[i] then return markerPool[i] end
  local m = CreateFrame("Frame", nil, canvas)
  m:SetSize(ICON, ICON)
  m.tex = m:CreateTexture(nil, "ARTWORK")
  m.tex:SetAllPoints()
  m.tex:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  m.dot = m:CreateTexture(nil, "ARTWORK")
  m.dot:SetAllPoints()
  m.dot:SetColorTexture(0.4, 0.7, 1, 0.9)
  markerPool[i] = m
  return m
end

local function getRowBg(i)
  if rowPool[i] then return rowPool[i] end
  local t = canvas:CreateTexture(nil, "BACKGROUND")
  rowPool[i] = t
  return t
end

local function getLabel(i)
  if labelPool[i] then return labelPool[i] end
  local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetJustifyH("LEFT")
  fs:SetWidth(LABEL_W - 6)
  labelPool[i] = fs
  return fs
end

local function hideFrom(pool, n, kind)
  for i = n + 1, #pool do
    if kind == "marker" then pool[i]:Hide()
    elseif kind == "tex" then pool[i]:Hide()
    else pool[i]:SetText(""); pool[i]:Hide() end
  end
end

-- ── note access ──────────────────────────────────────────────────────────────
local function currentNote()
  if not selEnc then return nil end
  local e = ns.DB.GetEncounter(selEnc)
  if not e then return nil end
  local p = e.plans[selNote or e.active]
  return e, p
end

-- ── render the timeline canvas ───────────────────────────────────────────────
local function renderCanvas()
  local e, p = currentNote()
  local reminders = (p and p.reminders) or {}
  local boss = (e and e.boss) or {}

  -- compute time extent
  local maxMs = 1000
  for _, r in ipairs(reminders) do if r.timeMs > maxMs then maxMs = r.timeMs end end
  for _, b in ipairs(boss) do if b.timeMs > maxMs then maxMs = b.timeMs end end
  local totalSec = maxMs / 1000 + 2
  local width = LABEL_W + totalSec * PX_PER_SEC + 20
  canvas:SetWidth(math.max(width, scroll:GetWidth() or 600))

  -- group cooldowns by player (preserve first-seen order)
  local order, byPlayer = {}, {}
  for _, r in ipairs(reminders) do
    local pl = (r.player and r.player ~= "" and r.player) or "?"
    if not byPlayer[pl] then byPlayer[pl] = {}; order[#order + 1] = pl end
    byPlayer[pl][#byPlayer[pl] + 1] = r
  end

  local trackIndex = 0
  local markerIndex = 0
  local labelIndex = 0
  local rowIndex = 0

  local function placeMarker(spellId, timeMs, rowTop, isBoss, bossType)
    markerIndex = markerIndex + 1
    local m = getMarker(markerIndex)
    m:ClearAllPoints()
    local x = LABEL_W + (timeMs / 1000) * PX_PER_SEC
    m:SetPoint("TOPLEFT", canvas, "TOPLEFT", x - ICON / 2, rowTop)
    local icon = spellIcon(spellId)
    if icon then
      m.tex:SetTexture(icon); m.tex:Show(); m.dot:Hide()
    else
      m.tex:Hide(); m.dot:Show()
      if isBoss then m.dot:SetColorTexture(1, 0.3, 0.25, 0.95)
      else m.dot:SetColorTexture(0.4, 0.7, 1, 0.95) end
    end
    m:Show()
  end

  local y = -4

  -- boss track (top, red)
  if #boss > 0 then
    rowIndex = rowIndex + 1
    local bg = getRowBg(rowIndex)
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", canvas, "TOPLEFT", LABEL_W, y)
    bg:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -4, y)
    bg:SetHeight(BOSS_ROW_H)
    bg:SetColorTexture(0.5, 0.1, 0.1, 0.25)
    bg:Show()

    labelIndex = labelIndex + 1
    local lbl = getLabel(labelIndex)
    lbl:ClearAllPoints()
    lbl:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, y - 4)
    lbl:SetText("|cffff7777Boss|r")
    lbl:Show()

    for _, b in ipairs(boss) do
      placeMarker(b.spellId, b.timeMs, y - 3, true, b.type)
    end
    y = y - BOSS_ROW_H - 2
  end

  -- player tracks
  for _, pl in ipairs(order) do
    trackIndex = trackIndex + 1
    rowIndex = rowIndex + 1
    local bg = getRowBg(rowIndex)
    bg:ClearAllPoints()
    bg:SetPoint("TOPLEFT", canvas, "TOPLEFT", LABEL_W, y)
    bg:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -4, y)
    bg:SetHeight(ROW_H)
    bg:SetColorTexture(1, 1, 1, (trackIndex % 2 == 0) and 0.04 or 0.08)
    bg:Show()

    labelIndex = labelIndex + 1
    local lbl = getLabel(labelIndex)
    lbl:ClearAllPoints()
    lbl:SetPoint("TOPLEFT", canvas, "TOPLEFT", 4, y - 4)
    lbl:SetText(pl)
    lbl:Show()

    for _, r in ipairs(byPlayer[pl]) do
      placeMarker(r.spellId, r.timeMs, y - 3, false)
    end
    y = y - ROW_H - 2
  end

  hideFrom(markerPool, markerIndex, "marker")
  hideFrom(rowPool, rowIndex, "tex")
  hideFrom(labelPool, labelIndex, "label")

  local h = math.abs(y) + 8
  canvas:SetHeight(math.max(h, 60))
  canvas._totalSec = totalSec
  canvas._height = h

  -- park playhead at the start, hidden until Test runs
  playhead:ClearAllPoints()
  playhead:SetPoint("TOPLEFT", canvas, "TOPLEFT", LABEL_W, 0)
  playhead:SetHeight(h)
  playhead:Hide()

  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
end

local function setPlayhead(elapsed)
  local x = LABEL_W + (elapsed or 0) * PX_PER_SEC
  playhead:ClearAllPoints()
  playhead:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, 0)
  playhead:SetHeight(canvas._height or 60)
  playhead:Show()
end

-- ── Test playback ────────────────────────────────────────────────────────────
local function stopTest()
  ns.Scheduler.Stop()
  playhead:Hide()
  if testBtn then testBtn:SetText("Test") end
  if status then status:SetText("") end
end

local function startTest(speed)
  local e, p = currentNote()
  if not p then
    if status then status:SetText("|cffff8888No note selected.|r") end
    return
  end
  local ok = ns.Scheduler.StartPreview(p.reminders, e and e.boss, speed,
    function(elapsed) setPlayhead(elapsed) end)
  if not ok then
    if status then status:SetText("|cffffcc00Nothing to play (filtered out by 'only me' / categories?).|r") end
    return
  end
  if testBtn then testBtn:SetText("Stop") end
  if status then
    status:SetText(("|cff66ff66Playing preview%s…|r"):format(speed and speed > 1 and (" " .. speed .. "x") or ""))
  end
end

local function onTestClick()
  if ns.Scheduler.IsPreview() then
    stopTest()
    return
  end
  local speed = IsShiftKeyDown and IsShiftKeyDown() and 3 or 1
  startTest(speed)
end

-- ── dropdown item providers ──────────────────────────────────────────────────
local function currentBoss()
  local groups = ns.Window.Groups(selCat)
  local grp = groups[selGrp]
  return grp and grp.bosses and grp.bosses[selBoss] or nil
end

local function grpItems()
  local items = {}
  for i, g in ipairs(ns.Window.Groups(selCat)) do
    items[#items + 1] = { text = g.name, value = i }
  end
  return items
end

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

local function noteItems()
  local items = {}
  if selEnc then
    local e = ns.DB.GetEncounter(selEnc)
    if e then
      for i, p in ipairs(e.plans) do
        items[#items + 1] = { text = p.label .. (i == e.active and "  (active)" or ""), value = i }
      end
    end
  end
  return items
end

local function refreshNoteDD()
  local e = selEnc and ns.DB.GetEncounter(selEnc)
  if e and #e.plans > 0 then
    local valid = selNote and e.plans[selNote]
    if not valid then selNote = e.active or 1 end
    noteDD:SetValue(selNote, e.plans[selNote] and e.plans[selNote].label or "—")
  else
    selNote = nil
    noteDD:SetValue(nil, "—")
  end
end

local function resolveSelEnc()
  local boss = currentBoss()
  selEnc = boss and ns.Window.ResolveBossId(boss.name, boss.id) or nil
end

local function ensureGrpSelection()
  local groups = ns.Window.Groups(selCat)
  if not groups[selGrp] then selGrp = groups[1] and 1 or 1 end
  if grpDD then
    local g = groups[selGrp]
    grpDD:SetValue(g and selGrp or nil, g and g.name or "—")
  end
end

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

-- Public refresh (called after imports change the library).
function Timeline.Refresh()
  if not page then return end
  ensureGrpSelection()
  ensureBossSelection()
  refreshNoteDD()
  renderCanvas()
end

function Timeline.BuildPage(host)
  page = host

  local hint = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 8, -6)
  hint:SetText("Pick a dungeon / boss / note to preview its cooldown timeline. Test = live playback (Shift+click = 3x).  Shift+scroll = pan ◀ ▶")

  -- row 1: category + dungeon/instance
  catDD = ns.Window.MakeDropdown(host, "CoolPlanTLCatDD", 100,
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
      selNote = nil
      ensureGrpSelection()
      ensureBossSelection()
      refreshNoteDD()
      renderCanvas()
    end)
  catDD:SetPoint("TOPLEFT", -8, -24)
  do
    local cat = ns.Window.CategoryByKey(selCat) or ns.Window.Categories()[1]
    if cat then selCat = cat.key; catDD:SetValue(cat.key, cat.label) end
  end

  grpDD = ns.Window.MakeDropdown(host, "CoolPlanTLGrpDD", 180, grpItems,
    function(idx)
      selGrp = idx
      selBoss = 1
      selNote = nil
      ensureBossSelection()
      refreshNoteDD()
      renderCanvas()
    end)
  grpDD:SetPoint("LEFT", catDD, "RIGHT", 2, 0)

  -- row 2: boss + note + Test (kept off the first row so the dropdowns never
  -- overflow the page to the right)
  bossDD = ns.Window.MakeDropdown(host, "CoolPlanTLBossDD", 160, bossItems,
    function(idx)
      selBoss = idx
      selNote = nil
      resolveSelEnc()
      refreshNoteDD()
      renderCanvas()
    end)
  bossDD:SetPoint("TOPLEFT", -8, -54)

  noteDD = ns.Window.MakeDropdown(host, "CoolPlanTLNoteDD", 150, noteItems,
    function(idx)
      selNote = idx
      renderCanvas()
    end)
  noteDD:SetPoint("LEFT", bossDD, "RIGHT", 2, 0)

  -- Test / Stop button (its own spot, with a hover tooltip explaining the speeds)
  testBtn = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  testBtn:SetSize(80, 22)
  testBtn:SetText("Test")
  testBtn:SetPoint("LEFT", noteDD, "RIGHT", 6, 2)
  testBtn:SetScript("OnClick", ns.wrap(onTestClick))
  testBtn:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Test playback")
    GameTooltip:AddLine("Click = play at 1x", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Shift + Click = play at 3x", 0.8, 0.8, 0.8)
    GameTooltip:AddLine("Click again while playing = stop", 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  testBtn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  status = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("TOPLEFT", 8, -84)

  -- scrollable canvas
  scroll = CreateFrame("ScrollFrame", "CoolPlanTimelineScroll", host, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -102)
  scroll:SetPoint("BOTTOMRIGHT", -28, 12)

  canvas = CreateFrame("Frame", "CoolPlanTimelineCanvas", scroll)
  canvas:SetSize(600, 60)
  scroll:SetScrollChild(canvas)

  -- horizontal pan with Shift+wheel (the timeline is usually far wider than the
  -- view); plain wheel scrolls vertically.
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", ns.wrap(function(self, delta)
    if IsShiftKeyDown and IsShiftKeyDown() then
      local maxx = math.max(0, (canvas:GetWidth() or 0) - self:GetWidth())
      self:SetHorizontalScroll(math.min(maxx, math.max(0, self:GetHorizontalScroll() - delta * 80)))
    else
      local maxy = math.max(0, (canvas:GetHeight() or 0) - self:GetHeight())
      self:SetVerticalScroll(math.min(maxy, math.max(0, self:GetVerticalScroll() - delta * 30)))
    end
  end))

  playhead = canvas:CreateTexture(nil, "OVERLAY")
  playhead:SetWidth(2)
  playhead:SetColorTexture(1, 0.9, 0.2, 0.9)
  playhead:Hide()

  ensureGrpSelection()
  ensureBossSelection()
  refreshNoteDD()
  renderCanvas()

  -- re-fit the canvas min-width when the window is resized
  host._onResize = function() renderCanvas() end

  -- stop any running preview when the page is hidden
  host:SetScript("OnHide", ns.wrap(function()
    if ns.Scheduler.IsPreview() then stopTest() end
  end))

  host._onShow = function() Timeline.Refresh() end
end

function Timeline.Open()
  ns.Window.Open("timeline")
end

ns.Window.RegisterPage("timeline", "Timeline", Timeline.BuildPage)
