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

local page, catDD, grpDD, bossDD, noteDD, previewDD, testBtn, status
local scroll, canvas, playhead, hbar
local zoomBtns = {}
local markerPool = {}          -- reusable icon markers
local rowPool = {}             -- reusable per-track background rows
local labelPool = {}
local linePool = {}            -- vertical gridlines (time ticks + boss abilities)
local axisPool = {}            -- time-axis labels

local AXIS_H = 16              -- top strip for the time axis
local secondsPerView = 60     -- zoom: how many seconds fill the visible width (1x)

-- px-per-second derived from the current view width so "Ns/view" fills the view.
local function pxPerSec()
  local w = (scroll and scroll:GetWidth()) or 0
  if w < 50 then w = 500 end
  return math.max(2, (w - LABEL_W - 8) / secondsPerView)
end

local selCat = "mythicplus"
local selGrp = 1               -- index into the category's groups
local selBoss = 1              -- index into the group's bosses
local selEnc = nil             -- resolved encounterID for the selected boss
local selNote = nil            -- plan index within the encounter
local selPreviewAs = "__all__" -- preview filter: "__all__" | a player name

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

local function spellNameOf(spellId)
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellId)
    if info and info.name then return info.name end
  end
  if _G.GetSpellInfo then local n = _G.GetSpellInfo(spellId); if n then return n end end
  return nil
end

local function getLine(i)
  if linePool[i] then return linePool[i] end
  local t = canvas:CreateTexture(nil, "ARTWORK")
  t:SetWidth(1)
  linePool[i] = t
  return t
end

local function getAxis(i)
  if axisPool[i] then return axisPool[i] end
  local fs = canvas:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  fs:SetJustifyH("CENTER")
  axisPool[i] = fs
  return fs
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
  -- hover = time + spell name
  m:EnableMouse(true)
  m:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(self._name or ("Spell " .. tostring(self._spellId or "?")))
    GameTooltip:AddLine(ns.Format.FormatTime(self._time or 0), 0.8, 0.8, 0.8)
    GameTooltip:Show()
  end)
  m:SetScript("OnLeave", function() GameTooltip:Hide() end)
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
-- The Timeline is a viewer, so when the encounter is disarmed (active == 0 /
-- none) it still previews plan 1 rather than going blank. The live Scheduler
-- separately honours active == 0 (no alerts on pull). NB: 0 is truthy in Lua, so
-- `e.active or 1` won't fall through — guard the index explicitly.
local function previewIndex(e)
  return selNote or (e.active and e.active >= 1 and e.active) or 1
end

local function currentNote()
  if not selEnc then return nil end
  local e = ns.DB.GetEncounter(selEnc)
  if not e then return nil end
  local p = e.plans[previewIndex(e)]
  return e, p
end

-- ── render the timeline canvas ───────────────────────────────────────────────
local function renderCanvas()
  local e, p = currentNote()
  local reminders = (p and p.reminders) or {}
  local boss = (p and p.boss) or {}

  -- compute time extent
  local maxMs = 1000
  for _, r in ipairs(reminders) do if r.timeMs > maxMs then maxMs = r.timeMs end end
  for _, b in ipairs(boss) do if b.timeMs > maxMs then maxMs = b.timeMs end end
  local totalSec = maxMs / 1000 + 2
  local pps = pxPerSec()
  canvas._pxPerSec = pps
  local width = LABEL_W + totalSec * pps + 20
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

  local function placeMarker(spellId, timeMs, rowTop, isBoss, nameHint)
    markerIndex = markerIndex + 1
    local m = getMarker(markerIndex)
    m:ClearAllPoints()
    local x = LABEL_W + (timeMs / 1000) * pps
    m:SetPoint("TOPLEFT", canvas, "TOPLEFT", x - ICON / 2, rowTop)
    local icon = spellIcon(spellId)
    if icon then
      m.tex:SetTexture(icon); m.tex:Show(); m.dot:Hide()
    else
      m.tex:Hide(); m.dot:Show()
      if isBoss then m.dot:SetColorTexture(1, 0.3, 0.25, 0.95)
      else m.dot:SetColorTexture(0.4, 0.7, 1, 0.95) end
    end
    m._time = timeMs
    m._spellId = spellId
    m._name = (nameHint and nameHint ~= "" and nameHint) or spellNameOf(spellId)
    m:Show()
  end

  -- content starts below the top time-axis strip
  local y = -AXIS_H - 4

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
      placeMarker(b.spellId, b.timeMs, y - 3, true, b.spellName)
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
      placeMarker(r.spellId, r.timeMs, y - 3, false, r.spellName)
    end
    y = y - ROW_H - 2
  end

  -- ── 30s time axis (top) + vertical gridlines (boss abilities in red) ──
  local gridTop, gridBottom = -AXIS_H, y + 2
  local lineIndex, axisIndex = 0, 0
  local function vline(timeMs, isBoss)
    lineIndex = lineIndex + 1
    local t = getLine(lineIndex)
    t:ClearAllPoints()
    local x = LABEL_W + (timeMs / 1000) * pps
    t:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, gridTop)
    t:SetPoint("BOTTOMLEFT", canvas, "TOPLEFT", x, gridBottom)
    if isBoss then t:SetColorTexture(1, 0.3, 0.25, 0.5) else t:SetColorTexture(1, 1, 1, 0.10) end
    t:Show()
  end
  -- adaptive tick interval: smallest "nice" step that keeps labels ~64px apart
  local tickSec = 60
  for _, cand in ipairs({ 5, 10, 15, 30, 60, 120 }) do
    if cand * pps >= 64 then tickSec = cand; break end
  end
  local sec = 0
  while sec <= totalSec do
    vline(sec * 1000, false)
    axisIndex = axisIndex + 1
    local a = getAxis(axisIndex)
    a:ClearAllPoints()
    a:SetPoint("TOP", canvas, "TOPLEFT", LABEL_W + sec * pps, -2)
    a:SetText((ns.Format.FormatTime(sec * 1000):gsub("%.%d$", "")))
    a:Show()
    sec = sec + tickSec
  end
  for _, b in ipairs(boss) do vline(b.timeMs, true) end

  hideFrom(markerPool, markerIndex, "marker")
  hideFrom(rowPool, rowIndex, "tex")
  hideFrom(labelPool, labelIndex, "label")
  hideFrom(linePool, lineIndex, "tex")
  hideFrom(axisPool, axisIndex, "label")

  local h = math.abs(y) + 8
  canvas:SetHeight(math.max(h, 60))
  canvas._totalSec = totalSec
  canvas._height = math.abs(gridBottom) + 4
  canvas._gridTop = gridTop

  -- park playhead at the start, hidden until Test runs
  playhead:ClearAllPoints()
  playhead:SetPoint("TOPLEFT", canvas, "TOPLEFT", LABEL_W, gridTop)
  playhead:SetHeight(canvas._height)
  playhead:Hide()

  -- keep the bottom horizontal scrollbar range in sync with the canvas width
  if hbar then
    local maxx = math.max(0, (canvas:GetWidth() or 0) - (scroll:GetWidth() or 0))
    hbar:SetMinMaxValues(0, maxx)
    if hbar:GetValue() > maxx then hbar:SetValue(maxx) end
  end

  if scroll.UpdateScrollChildRect then scroll:UpdateScrollChildRect() end
end

local function setPlayhead(elapsed)
  local x = LABEL_W + (elapsed or 0) * (canvas._pxPerSec or 8)
  playhead:ClearAllPoints()
  playhead:SetPoint("TOPLEFT", canvas, "TOPLEFT", x, canvas._gridTop or -AXIS_H)
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
  local ok = ns.Scheduler.StartPreview(p.reminders, p.boss, speed,
    function(elapsed) setPlayhead(elapsed) end, selPreviewAs)
  if not ok then
    if status then status:SetText("|cffffcc00Nothing to play — this note has no cooldowns. Pick another boss / note above.|r") end
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

-- "Preview as" items: Everyone + each distinct player in the selected note.
local function previewItems()
  local items = { { text = "Everyone", value = "__all__" } }
  local _, p = currentNote()
  if p then
    local seen = {}
    for _, r in ipairs(p.reminders or {}) do
      local pl = r.player
      if pl and pl ~= "" and not seen[pl] then
        seen[pl] = true
        items[#items + 1] = { text = pl, value = pl }
      end
    end
  end
  return items
end

-- Default the preview filter to "me": (1) the logged-in character if their name
-- is in the note, else (2) the slot the user last picked (remembered per
-- character — site roster overrides reuse the same name per spec slot, so this
-- effectively pins your own row), else (3) Everyone. Refreshed when the note
-- changes so a remembered name that's absent here falls back gracefully.
local function refreshPreviewDD()
  if not previewDD then return end
  local _, p = currentNote()
  local me = UnitName and UnitName("player")
  local nameMatch, savedMatch = nil, nil
  local saved = ns.DB.GetTimelinePreviewAs()
  if p then
    for _, r in ipairs(p.reminders or {}) do
      local pl = r.player
      if pl and pl ~= "" then
        if me and strlower(pl) == strlower(me) then nameMatch = pl end
        if saved and saved ~= "__all__" and strlower(pl) == strlower(saved) then savedMatch = pl end
      end
    end
  end
  selPreviewAs = nameMatch or savedMatch or "__all__"
  previewDD:SetValue(selPreviewAs, selPreviewAs == "__all__" and "Everyone" or selPreviewAs)
end

local function refreshNoteDD()
  local e = selEnc and ns.DB.GetEncounter(selEnc)
  if e and #e.plans > 0 then
    local valid = selNote and e.plans[selNote]
    if not valid then selNote = previewIndex(e) end
    noteDD:SetValue(selNote, e.plans[selNote] and e.plans[selNote].label or "—")
  else
    selNote = nil
    noteDD:SetValue(nil, "—")
  end
  refreshPreviewDD()
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

local function updateZoomButtons()
  for _, b in ipairs(zoomBtns) do
    if b.spv == secondsPerView then b:LockHighlight() else b:UnlockHighlight() end
  end
end

function Timeline.BuildPage(host)
  page = host

  local hint = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  hint:SetPoint("TOPLEFT", 8, -6)
  hint:SetText("Pick a dungeon / boss / note to preview. Test = playback (Shift+click 3x).  Scroll = zoom · Shift+scroll = pan · hover = time")

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

  grpDD = ns.Window.MakeDropdown(host, "CoolPlanTLGrpDD", 210, grpItems,
    function(idx)
      selGrp = idx
      selBoss = 1
      selNote = nil
      ensureBossSelection()
      refreshNoteDD()
      renderCanvas()
    end)
  grpDD:SetPoint("LEFT", catDD, "RIGHT", 8, 0)

  -- zoom control (row 1, right): 2x=30s/view, 1x=60s/view, ½x=120s/view
  local ZOOMS = { { label = "2x", spv = 30 }, { label = "1x", spv = 60 }, { label = "1/2x", spv = 120 } }
  local prevZ
  for _, z in ipairs(ZOOMS) do
    local b = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
    b:SetSize(36, 22)
    b:SetText(z.label)
    if prevZ then b:SetPoint("RIGHT", prevZ, "LEFT", 2, 0)
    else b:SetPoint("TOPRIGHT", -8, -24) end
    b.spv = z.spv
    b:SetScript("OnClick", ns.wrap(function()
      secondsPerView = z.spv
      updateZoomButtons()
      renderCanvas()
    end))
    b:SetScript("OnEnter", function(self)
      GameTooltip:SetOwner(self, "ANCHOR_TOP")
      GameTooltip:AddLine(z.spv .. "s per view")
      GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    zoomBtns[#zoomBtns + 1] = b
    prevZ = b
  end
  updateZoomButtons()

  -- row 2: boss + note + Test (kept off the first row so the dropdowns never
  -- overflow the page to the right)
  bossDD = ns.Window.MakeDropdown(host, "CoolPlanTLBossDD", 200, bossItems,
    function(idx)
      selBoss = idx
      selNote = nil
      resolveSelEnc()
      refreshNoteDD()
      renderCanvas()
    end)
  bossDD:SetPoint("TOPLEFT", -8, -54)

  noteDD = ns.Window.MakeDropdown(host, "CoolPlanTLNoteDD", 140, noteItems,
    function(idx)
      selNote = idx
      refreshPreviewDD()
      renderCanvas()
    end)
  noteDD:SetPoint("LEFT", bossDD, "RIGHT", 8, 0)

  -- "Preview as" — which player's reminders the Test plays (Everyone / a player).
  previewDD = ns.Window.MakeDropdown(host, "CoolPlanTLPreviewDD", 130, previewItems,
    function(v) selPreviewAs = v; ns.DB.SetTimelinePreviewAs(v) end)
  previewDD:SetPoint("LEFT", noteDD, "RIGHT", 8, 0)

  -- Test / Stop button — pin to the host's right edge (row 2) so it follows the
  -- window width and never gets clipped when the shell is narrowed. It sits to
  -- the right of noteDD; on a wide window there's a gap, on a narrow one they
  -- stay clear (noteDD is left-anchored, Test is right-anchored).
  testBtn = CreateFrame("Button", nil, host, "UIPanelButtonTemplate")
  testBtn:SetSize(80, 22)
  testBtn:SetText("Test")
  testBtn:SetPoint("TOPRIGHT", host, "TOPRIGHT", -8, -54)
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

  -- scrollable canvas (leave room at the bottom for the horizontal scrollbar)
  scroll = CreateFrame("ScrollFrame", "CoolPlanTimelineScroll", host, "UIPanelScrollFrameTemplate")
  scroll:SetPoint("TOPLEFT", 8, -102)
  scroll:SetPoint("BOTTOMRIGHT", -28, 30)

  canvas = CreateFrame("Frame", "CoolPlanTimelineCanvas", scroll)
  canvas:SetSize(600, 60)
  scroll:SetScrollChild(canvas)

  -- bottom horizontal scrollbar (like the vertical one) — drag to pan ◀ ▶
  hbar = CreateFrame("Slider", "CoolPlanTimelineHBar", host, "OptionsSliderTemplate")
  hbar:SetOrientation("HORIZONTAL")
  hbar:SetHeight(16)
  hbar:SetPoint("BOTTOMLEFT", 12, 6)
  hbar:SetPoint("BOTTOMRIGHT", -28, 6)
  hbar:SetMinMaxValues(0, 0)
  hbar:SetValue(0)
  hbar:SetValueStep(1)
  hbar:SetObeyStepOnDrag(true)
  do
    local hn = hbar:GetName()
    if _G[hn .. "Low"] then _G[hn .. "Low"]:SetText("") end
    if _G[hn .. "High"] then _G[hn .. "High"]:SetText("") end
    if _G[hn .. "Text"] then _G[hn .. "Text"]:SetText("") end
  end
  hbar:SetScript("OnValueChanged", ns.wrap(function(self, val)
    if scroll then scroll:SetHorizontalScroll(val) end
  end))

  -- Plain wheel = zoom (MRT-style: up = zoom in / compress to fewer s/view);
  -- Shift+wheel = pan horizontally via the scrollbar.
  scroll:EnableMouseWheel(true)
  scroll:SetScript("OnMouseWheel", ns.wrap(function(self, delta)
    if IsShiftKeyDown and IsShiftKeyDown() then
      if hbar then
        local _, mx = hbar:GetMinMaxValues()
        hbar:SetValue(math.min(mx or 0, math.max(0, hbar:GetValue() - delta * 80)))
      end
    else
      if delta > 0 then secondsPerView = math.max(10, secondsPerView / 1.25)
      else secondsPerView = math.min(300, secondsPerView * 1.25) end
      updateZoomButtons()
      renderCanvas()
    end
  end))

  playhead = canvas:CreateTexture(nil, "OVERLAY")
  playhead:SetWidth(2)
  playhead:SetColorTexture(1, 0.9, 0.2, 0.9)
  playhead:Hide()

  -- cursor crosshair: a full-height vertical line that follows the mouse over
  -- the timeline, with the time at the cursor shown above it. Textures don't
  -- intercept the mouse, so marker hover-tooltips still work underneath.
  local cline = canvas:CreateTexture(nil, "OVERLAY")
  cline:SetWidth(1)
  cline:SetColorTexture(0.8, 0.9, 1, 0.5)
  cline:Hide()
  local clabel = canvas:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  clabel:Hide()
  local cthrottle = 0
  scroll:SetScript("OnUpdate", ns.wrap(function(self, elapsed)
    cthrottle = cthrottle + (elapsed or 0)
    if cthrottle < 0.02 then return end
    cthrottle = 0
    if not self:IsVisible() then cline:Hide(); clabel:Hide(); return end
    local sc = self:GetEffectiveScale()
    local mx, my = GetCursorPosition()
    mx, my = mx / sc, my / sc
    local l, r, t, b = self:GetLeft(), self:GetRight(), self:GetTop(), self:GetBottom()
    if not l or mx < l or mx > r or my < b or my > t then cline:Hide(); clabel:Hide(); return end
    local canvasX = (mx - l) + (self:GetHorizontalScroll() or 0)
    if canvasX < LABEL_W then cline:Hide(); clabel:Hide(); return end
    cline:ClearAllPoints()
    cline:SetPoint("TOPLEFT", canvas, "TOPLEFT", canvasX, canvas._gridTop or -AXIS_H)
    cline:SetHeight(canvas._height or 60)
    cline:Show()
    clabel:ClearAllPoints()
    clabel:SetPoint("BOTTOMLEFT", canvas, "TOPLEFT", canvasX + 2, (canvas._gridTop or -AXIS_H))
    clabel:SetText(ns.Format.FormatTime(((canvasX - LABEL_W) / (canvas._pxPerSec or 8)) * 1000))
    clabel:Show()
  end))

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

  -- Re-entering the tab follows the encounter's ACTIVE plan. selNote persists
  -- across page rebuilds so a manual note pick sticks while you stay on the
  -- Timeline, but clearing it on show means changing the active plan elsewhere
  -- (Manager) is reflected here instead of showing a stale last-viewed note.
  host._onShow = function()
    selNote = nil
    Timeline.Refresh()
  end

  if ns.Style then
    ns.Style.Apply(host)
    ns.Style.Dropdown(catDD); ns.Style.Dropdown(grpDD)
    ns.Style.Dropdown(bossDD); ns.Style.Dropdown(noteDD)
    ns.Style.Slider(hbar)
    ns.Style.ScrollBar(scroll)
  end
end

function Timeline.Open()
  ns.Window.Open("timeline")
end

ns.Window.RegisterPage("timeline", "Timeline", Timeline.BuildPage)
