-- Reminder rendering: anticipation HUD (icon + name + countdown + depleting
-- bar) and an upcoming-reminders queue. Raw frames (no libs) so the combat HUD
-- stays lightweight. Both frames are movable/lockable with saved positions.

local _, ns = ...
local Reminders = {}
ns.Reminders = Reminders

local LINGER = 1.0 -- seconds to keep showing an alert after its cast time

local hud, queue
local moverOn = false -- frames draggable (+ grid + coord panel) whenever shown
local testOn = false  -- sample preview frames visible (independent of moverOn)
local testTicker
-- coordinate-input panel wiring (ElvUI-style nudge). Forward-declared so
-- makeMovable / the mover toggles can reference them before the panel section
-- defines them further down.
local selectPosTarget, showPosPanel, onMoverDragTick, draggingFrame

-- ── spell info ───────────────────────────────────────────────────────────────
local function spellInfo(spellId)
  local name, icon
  if C_Spell and C_Spell.GetSpellInfo then
    local info = C_Spell.GetSpellInfo(spellId)
    if info then name = info.name; icon = info.iconID end
  end
  if (not name) and _G.GetSpellInfo then
    local n, _, ic = _G.GetSpellInfo(spellId)
    name = n; icon = icon or ic
  end
  if (not icon) and C_Spell and C_Spell.GetSpellTexture then
    icon = C_Spell.GetSpellTexture(spellId)
  end
  return name, icon
end

local function labelFor(reminder)
  local name = spellInfo(reminder.spellId)
  if reminder.alert and reminder.alert ~= "" then return reminder.alert end
  return name or reminder.spellName or ("Spell " .. tostring(reminder.spellId))
end

-- Apply a cue's icon to a texture region. A free-text note (spellId 0) has no
-- real spell art: write a transparent texture (layoutHud/queue also HIDE the
-- icon for a note so the message starts at the far left; the blank is just a
-- safety so a note can never inherit the PREVIOUS cue's icon if the frame is
-- ever shown). Any other cue whose spellId resolves no icon gets a neutral "?".
-- Always writes SOMETHING so a missing icon can't keep a STALE one either
-- (SetTexture(nil) would silently leave the stale texture in place).
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local function applyCueIcon(tex, cue)
  if not cue.spellId or cue.spellId == 0 then
    tex:SetColorTexture(0, 0, 0, 0) -- note: blank, but keep the slot
    return
  end
  local _, icon = spellInfo(cue.spellId)
  tex:SetTexture(icon or FALLBACK_ICON)
  tex:SetTexCoord(0.07, 0.93, 0.07, 0.93) -- re-crop: a prior note's SetColorTexture resets texcoords
end

-- ── placement helpers ──────────────────────────────────────────────────────────
-- The HUD is CENTRE-anchored: fitHudWidth sizes the frame to its content and the
-- CENTRE stays put, so the block reads as centred on its anchor point. saved.x/y
-- is that centre. (A cue with a different name length re-centres the block, the
-- user's chosen behaviour.) The queue keeps its own saved anchor (TOP-centred).
local function restorePosition(frame, saved)
  frame:ClearAllPoints()
  local point = (frame == hud) and "CENTER" or (saved.point or "CENTER")
  frame:SetPoint(point, UIParent, saved.relPoint or "CENTER", saved.x or 0, saved.y or 0)
end

local GRID = 20 -- alignment grid spacing, in (UIParent) pixels

local function savePosition(frame, saved)
  local point, _, relPoint, x, y = frame:GetPoint(1)
  if frame == hud then point = "CENTER" end -- keep the HUD centre-anchored
  saved.point = point or "CENTER"
  saved.relPoint = relPoint or "CENTER"
  saved.x = x or 0
  saved.y = y or 0
end

local function makeMovable(frame, saved)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  -- clicking a frame in move mode selects it for the coordinate panel
  frame:SetScript("OnMouseDown", ns.wrap(function(self)
    if selectPosTarget then selectPosTarget(self) end
  end))
  frame:SetScript("OnDragStart", ns.wrap(function(self)
    if not saved.locked then
      self:StartMoving()
      draggingFrame = self
      if selectPosTarget then selectPosTarget(self) end
    end
  end))
  frame:SetScript("OnDragStop", ns.wrap(function(self)
    self:StopMovingOrSizing()
    draggingFrame = nil
    savePosition(self, saved)
    if onMoverDragTick then onMoverDragTick() end -- final coord refresh
  end))
end

-- ── alignment grid overlay (shown only while moving) ─────────────────────────────
local gridFrame
local function buildGrid()
  local g = CreateFrame("Frame", "CoolPlanGrid", UIParent)
  g:SetAllPoints(UIParent)
  g:SetFrameStrata("BACKGROUND")
  g.lines = {}
  local w, h = UIParent:GetWidth(), UIParent:GetHeight()
  local cx, cy = w / 2, h / 2
  local function line(isV, offset, center)
    local t = g:CreateTexture(nil, "BACKGROUND")
    if center then
      t:SetColorTexture(1, 0.82, 0.2, 0.5) -- amber center guide
    else
      t:SetColorTexture(1, 1, 1, 0.10)
    end
    if isV then
      t:SetWidth(center and 2 or 1)
      t:SetPoint("TOP", g, "TOPLEFT", offset, 0)
      t:SetPoint("BOTTOM", g, "BOTTOMLEFT", offset, 0)
    else
      t:SetHeight(center and 2 or 1)
      t:SetPoint("LEFT", g, "TOPLEFT", 0, -offset)
      t:SetPoint("RIGHT", g, "TOPRIGHT", 0, -offset)
    end
    g.lines[#g.lines + 1] = t
  end
  -- grid aligned to screen centre (so it matches CENTER-anchored offsets/snap)
  for x = cx, w, GRID do line(true, x, x == cx) end
  for x = cx - GRID, 0, -GRID do line(true, x, false) end
  for y = cy, h, GRID do line(false, y, y == cy) end
  for y = cy - GRID, 0, -GRID do line(false, y, false) end
  g:Hide()
  return g
end

local function setGrid(show)
  if show then
    if not gridFrame then gridFrame = buildGrid() end
    gridFrame:Show()
  elseif gridFrame then
    gridFrame:Hide()
  end
end

-- ── frame construction ──────────────────────────────────────────────────────────
local function buildHud()
  local f = CreateFrame("Frame", "CoolPlanHUD", UIParent, "BackdropTemplate")
  f:SetSize(440, 72)
  f:SetFrameStrata("HIGH")

  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  do
    local p = ns.Style and ns.Style.colors.panel
    if p then f.bg:SetColorTexture(p[1], p[2], p[3], 0.55) else f.bg:SetColorTexture(0, 0, 0, 0.35) end
  end
  f.bg:Hide()

  f.icon = f:CreateTexture(nil, "ARTWORK")
  f.icon:SetSize(52, 52)
  f.icon:SetPoint("LEFT", f, "LEFT", 6, 0)
  f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

  -- start from a real font object so SetText never hits a font-less string;
  -- ApplyOptions resizes via SetFont afterwards.
  f.count = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.count:SetPoint("CENTER", f.icon, "CENTER", 0, 0)

  f.name = f:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.name:SetPoint("LEFT", f.icon, "RIGHT", 12, 6)

  f.bar = CreateFrame("StatusBar", nil, f)
  f.bar:SetPoint("LEFT", f.icon, "RIGHT", 12, -16)
  f.bar:SetSize(340, 12)
  f.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  f.bar:SetMinMaxValues(0, 1)
  f.bar:SetValue(1)
  f.bar.bg = f.bar:CreateTexture(nil, "BACKGROUND")
  f.bar.bg:SetAllPoints()
  do
    local b = ns.Style and ns.Style.colors.bg
    if b then f.bar.bg:SetColorTexture(b[1], b[2], b[3], 0.7) else f.bar.bg:SetColorTexture(0, 0, 0, 0.5) end
  end
  -- name overlaid INSIDE the bar (bar style). It is a CHILD of the bar so it
  -- renders ABOVE the fill texture instead of being hidden beneath it.
  f.barName = f.bar:CreateFontString(nil, "OVERLAY", "GameFontNormalHuge")
  f.barName:SetJustifyH("LEFT")
  f.barName:Hide()

  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOM", f, "TOP", 0, 2)
  f.label:SetText("CoolPlan alert")
  f.label:Hide()

  f:EnableMouse(false)
  f:Hide()
  return f
end

local function buildQueue()
  local f = CreateFrame("Frame", "CoolPlanQueue", UIParent, "BackdropTemplate")
  f:SetSize(240, 80)
  f:SetFrameStrata("MEDIUM")

  f.bg = f:CreateTexture(nil, "BACKGROUND")
  f.bg:SetAllPoints()
  do
    local p = ns.Style and ns.Style.colors.panel
    if p then f.bg:SetColorTexture(p[1], p[2], p[3], 0.55) else f.bg:SetColorTexture(0, 0, 0, 0.35) end
  end
  f.bg:Hide()

  f.header = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.header:SetPoint("TOPLEFT", 4, -2)
  f.header:Hide() -- no "Next up" caption; the rows read as the queue on their own

  f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.label:SetPoint("BOTTOM", f, "TOP", 0, 2)
  f.label:SetText("CoolPlan queue")
  f.label:Hide()

  f.rows = {}
  f:EnableMouse(false)
  f:Hide()
  return f
end

local function ensureFrames()
  if hud then return end
  hud = buildHud()
  queue = buildQueue()
  -- wire dragging (respects the per-frame `locked` flag)
  local o = ns.DB and ns.DB.Options and ns.DB.Options()
  if o then
    makeMovable(hud, o.hud)
    makeMovable(queue, o.queueAnchor)
  end
end

-- ── HUD layout (style + time position) ────────────────────────────────────────
-- Re-anchors / shows / hides / sizes the icon, name, count and bar regions for
-- the chosen hudStyle ("icon" | "iconName" | "bar") and timePos ("icon" |
-- "right"), then sizes the hud frame to fit. RenderTick only updates VALUES;
-- this function owns all the Show/Hide + ClearAllPoints + fonts so a hidden
-- region never resurfaces on the next tick.
local ICON_SIZE = 52
local THIN_BAR_H = 5
-- A saved textColor may be malformed (stale/externally-edited SavedVariables);
-- SetTextColor(nil,…) would throw every frame, so validate before use.
local function validColor(tc) return type(tc) == "table" and type(tc.r) == "number" end

-- Font family (o.fontFamily = a "Fonts\\X.TTF" path, or empty = default). A path
-- that no longer loads (e.g. a LibSharedMedia font whose provider addon was
-- removed) would make SetFont fail and blank the HUD text, so resolveFont
-- validates and falls back to the locale default. It returns a KNOWN-GOOD path,
-- so the layout SetFont calls below don't each need a guard.
local DEFAULT_FONT = GameFontNormalHuge:GetFont()
local fontProbe
local function resolveFont(o)
  local p = o and o.fontFamily
  if type(p) ~= "string" or p == "" then return DEFAULT_FONT end
  -- Validate by READBACK, not SetFont's return value (that is unreliable / nil on
  -- some clients, which pinned everyone to the default). If the path loads,
  -- GetFont echoes it back; a missing font leaves the probe's prior font, so the
  -- mismatch routes us to the default and the text never vanishes.
  if not fontProbe then fontProbe = UIParent:CreateFontString(nil, "BACKGROUND") end
  fontProbe:SetFont(p, 12, "")
  if fontProbe:GetFont() == p then return p end
  return DEFAULT_FONT
end

local function layoutHud(o, isNote)
  local style = o.hudStyle or "iconName"
  local tpos = o.timePos or "icon"
  local size = o.fontSize or 28
  local c = validColor(o.textColor) and o.textColor or { r = 1, g = 0.95, b = 0.4 }
  local fontPath = resolveFont(o) -- chosen font (validated; falls back to default)

  local icon, name, count, bar = hud.icon, hud.name, hud.count, hud.bar
  icon:ClearAllPoints(); name:ClearAllPoints(); count:ClearAllPoints(); bar:ClearAllPoints()

  -- count font: big when centered inside the icon/bar, normal when on the right
  local countSize = (tpos == "icon") and (size + 10) or size
  if fontPath then
    if name.SetFont then name:SetFont(fontPath, size, "OUTLINE") end
    if count.SetFont then count:SetFont(fontPath, countSize, "OUTLINE") end
  end
  name:SetTextColor(c.r, c.g, c.b)
  count:SetTextColor(1, 1, 1)
  if hud.barName then hud.barName:Hide() end -- only the bar style uses the in-bar name

  local PAD = 6

  if style == "bar" then
    -- thick horizontal bar with a small square icon on the left, name overlaid
    -- left INSIDE the bar (drawn above the fill via the bar-child barName), time
    -- either inside the icon or as a separate right field.
    local barH = math.max(20, size)
    local barW = 300
    icon:SetSize(barH, barH)
    icon:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    icon:Show()

    bar:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    bar:SetSize(barW, barH)
    bar:Show()

    name:Hide()
    if fontPath and hud.barName.SetFont then hud.barName:SetFont(fontPath, size, "OUTLINE") end
    hud.barName:ClearAllPoints()
    hud.barName:SetPoint("LEFT", bar, "LEFT", 6, 0)
    hud.barName:SetWidth(barW - 12)
    hud.barName:SetJustifyH("LEFT")
    hud.barName:SetTextColor(c.r, c.g, c.b)
    hud.barName:Show()

    local totalW = PAD + barH + 4 + barW + PAD
    if tpos == "icon" then
      -- "in icon/bar" for the bar style = inside the small left icon
      count:SetPoint("CENTER", icon, "CENTER", 0, 0)
      count:SetJustifyH("CENTER")
      if fontPath and count.SetFont then count:SetFont(fontPath, math.max(12, barH - 6), "OUTLINE") end
    else
      count:SetPoint("LEFT", bar, "RIGHT", 8, 0)
      count:SetJustifyH("LEFT")
      totalW = totalW + 8 + math.max(28, size)
    end
    count:Show()
    hud:SetSize(totalW, barH + 4)

  elseif style == "icon" then
    -- icon only: just the 52px icon with the countdown number. No bar, no name.
    icon:SetSize(ICON_SIZE, ICON_SIZE)
    icon:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    icon:Show()

    bar:Hide()
    name:Hide()

    local totalW = PAD + ICON_SIZE + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0)
      count:SetJustifyH("CENTER")
    else
      count:SetPoint("LEFT", icon, "RIGHT", 8, 0)
      count:SetJustifyH("LEFT")
      totalW = totalW + 8 + math.max(28, size)
    end
    count:Show()
    hud:SetSize(totalW, ICON_SIZE + THIN_BAR_H + 2)

  else -- "iconName"
    -- icon sized to the TEXT height (not a fixed 52) so it doesn't dwarf the name,
    -- then the name on the right. No bar (countdown number only).
    local isz = math.max(14, size)
    icon:SetSize(isz, isz)
    icon:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    icon:Show()

    name:SetWidth(0); name:SetWordWrap(false) -- one line; never wrap a long name
    name:SetPoint("LEFT", icon, "RIGHT", 8, 0)
    name:SetJustifyH("LEFT")
    name:Show()

    bar:Hide()

    -- base width (the icon + a nominal name budget); RenderTick/showSample shrink
    -- the frame to hug the ACTUAL text via fitHudWidth so the box isn't oversized.
    local totalW = PAD + isz + 8 + 240 + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0)
      count:SetJustifyH("CENTER")
      -- the icon now matches the text height, so shrink the in-icon number to fit
      if fontPath and count.SetFont then count:SetFont(fontPath, math.max(9, isz - 4), "OUTLINE") end
    else
      count:SetPoint("LEFT", name, "RIGHT", 8, 0)
      count:SetJustifyH("LEFT")
    end
    count:Show()
    hud:SetSize(totalW, math.max(isz, size) + 4)
  end

  -- Stable countdown reserve: measure a max-width template with the active count
  -- font so fitHudWidth reserves a CONSTANT slot for the number. Otherwise the
  -- frame width tracked the number's glyph width and the box jittered left/right
  -- each tick under centre/right alignment.
  do
    -- reserve the widest 1-digit-decimal ("8.8"; "8" is a wide glyph). fitHudWidth
    -- uses this FIXED reserve for the number, so 1-digit countdowns (the common
    -- case) sit in a CONSTANT slot with no per-tick jitter from proportional glyph
    -- widths. A rare 2-digit "10.0" pokes a hair past the edge for a moment.
    local prevCount = count:GetText()
    count:SetText("8.8")
    hud._countReserve = count:GetStringWidth() or 0
    count:SetText(prevCount or "")
  end

  -- A free-text note has no icon. In the text ("iconName") style, hide the icon
  -- and pull the message to the far left so it STARTS where the icon would be,
  -- no reserved gap. Record what we laid out so RenderTick relayouts only when
  -- the note/spell state actually flips (this fn otherwise only runs on options).
  if isNote and style ~= "bar" and style ~= "icon" then
    icon:Hide()
    if tpos == "icon" then
      -- "time in icon", but a note has no icon: the countdown takes the front
      -- slot where the icon would be, and the message follows to its right.
      count:ClearAllPoints()
      count:SetPoint("LEFT", hud, "LEFT", PAD, 0); count:SetJustifyH("LEFT")
      -- a note has no icon, so undo the in-icon font shrink; match the text size
      if fontPath and count.SetFont then count:SetFont(fontPath, size, "OUTLINE") end
      name:ClearAllPoints()
      name:SetPoint("LEFT", count, "RIGHT", 8, 0)
    else
      -- "time on the right": message starts at the far left, the time trails it
      -- (layoutHud's right branch already anchored count to the name's right).
      name:ClearAllPoints()
      name:SetPoint("LEFT", hud, "LEFT", PAD, 0)
    end
    name:SetWordWrap(false)
  end
  hud._isNote = isNote and true or false
end
ns.Reminders._layoutHud = layoutHud

-- Shrink the HUD frame to hug its ACTUAL content (the background box is
-- SetAllPoints, so a fixed name budget made it far wider than short text). Only
-- the "iconName" style has a name budget worth trimming; "icon"/"bar" keep their
-- deliberate sizes. Call AFTER the name/count text is set (GetStringWidth needs
-- the final text). The HUD is CENTRE-anchored, so the box grows/shrinks around
-- its centre; the fixed count reserve keeps the width constant per cue (no
-- per-tick jitter), and the block re-centres only when a new cue's name differs.
local function fitHudWidth(o, isNote)
  if (o.hudStyle or "iconName") ~= "iconName" then return end
  local PAD = 6
  local tpos = o.timePos or "icon"
  local nameW = (hud.name:GetStringWidth() or 0)
  -- FIXED countdown reserve so the frame width is CONSTANT, never track the live
  -- number's glyph width, or the centre-anchored frame would jitter left/right
  -- each tick. 1-digit numbers fit snugly; a rare 2-digit "10.0" just pokes a
  -- hair past the edge for a moment (still no reflow).
  local countW = hud._countReserve or 0
  local w
  if isNote then
    if tpos == "icon" then w = PAD + countW + 8 + nameW + PAD   -- [count][name]
    else                   w = PAD + nameW + 8 + countW + PAD   -- [name][count]
    end
  else
    local isz = math.max(14, o.fontSize or 28)                  -- icon = text height
    w = PAD + isz + 8 + nameW + PAD                             -- [icon][name]
    if tpos == "right" then w = w + 8 + countW end              -- + [count]
  end
  hud:SetWidth(math.max(w, PAD * 2 + 24))
end
ns.Reminders._fitHudWidth = fitHudWidth

-- ── upcoming queue rows (mini-HUD at 50% - follows hudStyle + timePos) ─────────
-- Each row is a scaled-down copy of the HUD: it honors the same display style
-- ("icon" | "iconName" | "bar") and time position ("icon" | "right") so the
-- queue reads as the same alert, just smaller. RenderTick only sets values;
-- this function owns all Show/Hide + anchors + fonts (mirrors layoutHud).
local QUEUE_PAD = 6
local QUEUE_GAP = 3
local QUEUE_SCALE = 0.5

local function ensureQueueRow(i)
  local row = queue.rows[i]
  if row then return row end
  row = CreateFrame("Frame", nil, queue)
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
  row.name = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.name:SetJustifyH("LEFT")
  row.count = row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.bar = CreateFrame("StatusBar", nil, row)
  row.bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
  row.bar:SetMinMaxValues(0, 1)
  row.bar:SetValue(1)
  row.bar.bg = row.bar:CreateTexture(nil, "BACKGROUND")
  row.bar.bg:SetAllPoints()
  do
    local b = ns.Style and ns.Style.colors.bg
    if b then row.bar.bg:SetColorTexture(b[1], b[2], b[3], 0.7) else row.bar.bg:SetColorTexture(0, 0, 0, 0.5) end
  end
  -- in-bar name (child of the bar → renders above the fill) for the bar style
  row.barName = row.bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  row.barName:SetJustifyH("LEFT")
  row.barName:Hide()
  queue.rows[i] = row
  return row
end

-- Lay out a single row's regions for the given style/timePos. Returns w, h.
local function layoutQueueRow(row, style, tpos, size, countSize, isize, fontPath, c)
  local icon, name, count, bar = row.icon, row.name, row.count, row.bar
  icon:ClearAllPoints(); name:ClearAllPoints(); count:ClearAllPoints(); bar:ClearAllPoints()
  if fontPath then
    if name.SetFont then name:SetFont(fontPath, size, "OUTLINE") end
    if count.SetFont then count:SetFont(fontPath, countSize, "OUTLINE") end
  end
  name:SetTextColor(c.r, c.g, c.b)
  count:SetTextColor(1, 1, 1)
  if row.barName then row.barName:Hide() end -- only the bar style uses the in-bar name
  local PAD = 3

  if style == "bar" then
    -- name overlaid left INSIDE the bar, drawn above the fill via barName
    local barH = math.max(10, size)
    local barW = math.floor(300 * QUEUE_SCALE)
    icon:SetSize(barH, barH); icon:SetPoint("LEFT", row, "LEFT", PAD, 0); icon:Show()
    bar:SetPoint("LEFT", icon, "RIGHT", 3, 0); bar:SetSize(barW, barH); bar:Show()
    name:Hide()
    if fontPath and row.barName.SetFont then row.barName:SetFont(fontPath, size, "OUTLINE") end
    row.barName:ClearAllPoints()
    row.barName:SetPoint("LEFT", bar, "LEFT", 4, 0)
    row.barName:SetWidth(barW - 8)
    row.barName:SetJustifyH("LEFT")
    row.barName:SetTextColor(c.r, c.g, c.b)
    row.barName:Show()
    local totalW = PAD + barH + 3 + barW + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0); count:SetJustifyH("CENTER")
      if fontPath and count.SetFont then count:SetFont(fontPath, math.max(8, barH - 4), "OUTLINE") end
    else
      count:SetPoint("LEFT", bar, "RIGHT", 5, 0); count:SetJustifyH("LEFT")
      totalW = totalW + 5 + math.max(16, size)
    end
    count:Show()
    return totalW, barH

  elseif style == "icon" then
    icon:SetSize(isize, isize); icon:SetPoint("LEFT", row, "LEFT", PAD, 0); icon:Show()
    bar:Hide(); name:Hide()
    local totalW = PAD + isize + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0); count:SetJustifyH("CENTER")
    else
      count:SetPoint("LEFT", icon, "RIGHT", 5, 0); count:SetJustifyH("LEFT")
      totalW = totalW + 5 + math.max(16, size)
    end
    count:Show()
    return totalW, isize

  else -- iconName
    icon:SetSize(isize, isize); icon:SetPoint("LEFT", row, "LEFT", PAD, 0); icon:Show()
    local nameW = math.floor(240 * QUEUE_SCALE)
    -- No fixed width + no wrap: the name stays on ONE line and the time (count)
    -- sits right after the text, mirroring the main HUD. A fixed width both
    -- wrapped long names and pushed the count out to a fixed far-right column.
    name:SetWidth(0); name:SetWordWrap(false)
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0); name:Show()
    bar:Hide()
    local totalW = PAD + isize + 6 + nameW + PAD
    if tpos == "icon" then
      count:SetPoint("CENTER", icon, "CENTER", 0, 0); count:SetJustifyH("CENTER")
    else
      count:SetPoint("LEFT", name, "RIGHT", 5, 0); count:SetJustifyH("LEFT")
      totalW = totalW + 5 + math.max(16, size)
    end
    count:Show()
    return totalW, isize
  end
end

local function layoutQueueRows(o)
  local style = o.hudStyle or "iconName"
  local tpos = o.timePos or "icon"
  local fontPath = resolveFont(o)
  local size = math.max(8, math.floor((o.fontSize or 28) * QUEUE_SCALE))
  local countSize = (tpos == "icon") and (size + math.floor(10 * QUEUE_SCALE)) or size
  local isize = math.max(10, size) -- icon matches the queue text height (not 52*scale)
  local c = o.textColor or { r = 1, g = 0.95, b = 0.4 }
  local top = QUEUE_PAD -- no header band (the "Next up" caption was removed)
  local n = o.queueCount or 3

  local maxW, rowH = 1, isize
  for i = 1, n do
    local row = ensureQueueRow(i)
    local w, h = layoutQueueRow(row, style, tpos, size, countSize, isize, fontPath, c)
    row:SetSize(w, h)
    row:Hide()
    if w > maxW then maxW = w end
    rowH = h
  end
  for i = 1, n do
    queue.rows[i]:ClearAllPoints()
    queue.rows[i]:SetPoint("TOPLEFT", QUEUE_PAD, -(top + (i - 1) * (rowH + QUEUE_GAP)))
  end
  for i = n + 1, #queue.rows do
    if queue.rows[i] and queue.rows[i].Hide then queue.rows[i]:Hide() end
  end
  -- stable count reserve for fitQueueWidth (mirrors the HUD's _countReserve so a
  -- ticking queue number does not jitter the row width). Measured with row 1's
  -- count font, set by layoutQueueRow above.
  local r1 = queue.rows[1]
  if r1 and r1.count then
    local prev = r1.count:GetText()
    r1.count:SetText("8.8")
    queue._countReserve = r1.count:GetStringWidth() or 0
    r1.count:SetText(prev or "")
  end
  queue:SetWidth(maxW + QUEUE_PAD * 2)
  queue:SetHeight(top + n * (rowH + QUEUE_GAP) + QUEUE_PAD)
end

-- Shrink each visible queue row (and the queue frame) to hug its actual text,
-- mirroring fitHudWidth. Runs after RenderTick/showSample set the row texts. Only
-- the "iconName" style has a name budget worth trimming; icon/bar keep their sizes.
local function fitQueueWidth(o)
  if (o.hudStyle or "iconName") ~= "iconName" then return end
  local tpos = o.timePos or "icon"
  local size = math.max(8, math.floor((o.fontSize or 28) * QUEUE_SCALE))
  local isize = math.max(10, size)
  local reserve = queue._countReserve or 0
  local maxW = 1
  for _, row in ipairs(queue.rows) do
    if row:IsShown() then
      local nameW = row.name:GetStringWidth() or 0
      local w
      if row.icon:IsShown() then
        w = 3 + isize + 6 + nameW                       -- [icon][name]
        if tpos == "right" then w = w + 5 + reserve end -- + [count]
      elseif tpos == "icon" then
        w = 3 + reserve + 5 + nameW                     -- note, time in front: [count][name]
      else
        w = 3 + nameW + 5 + reserve                     -- note, time on right: [name][count]
      end
      w = w + 3
      row:SetWidth(w)
      if w > maxW then maxW = w end
    end
  end
  queue:SetWidth(maxW + QUEUE_PAD * 2)
end
ns.Reminders._fitQueueWidth = fitQueueWidth

function Reminders.Init()
  ensureFrames()
  Reminders.ApplyOptions()
end

-- ── preview / move chrome ─────────────────────────────────────────────────────
-- Fill the HUD + queue with sample content and show them. Used by the Test
-- preview and by Move (so there's something to drag out of combat).
local function showSample(o)
  o = o or ns.DB.Options()
  layoutHud(o)
  layoutQueueRows(o)
  local sc = validColor(o.textColor) and o.textColor or { r = 1, g = 0.95, b = 0.4 }
  if hud.icon then hud.icon:SetTexture(136235) end -- generic icon
  hud.name:SetText("Cooldown name"); hud.name:SetTextColor(sc.r, sc.g, sc.b)
  hud.count:SetText("3"); hud.count:SetTextColor(sc.r, sc.g, sc.b)
  hud.bar:SetValue(0.6)
  fitHudWidth(o, false) -- preview box hugs the sample text, not the name budget
  hud.bg:Show(); hud.label:Show(); hud:Show(); hud._active = true
  local qr = queue.rows[1]
  if qr and qr.icon then
    local mc = validColor(o.textColor) and o.textColor or { r = 1, g = 0.95, b = 0.4 }
    qr.icon:SetTexture(136235); qr.icon:Show()
    qr.name:SetText("Next cooldown"); qr.name:SetTextColor(mc.r, mc.g, mc.b)
    if qr.barName then qr.barName:SetText("Next cooldown"); qr.barName:SetTextColor(mc.r, mc.g, mc.b) end
    qr.count:SetText("12"); qr.count:SetTextColor(mc.r, mc.g, mc.b)
    if qr.bar then qr.bar:SetValue(0.6); qr.bar:SetStatusBarColor(mc.r, mc.g, mc.b) end
    qr:Show()
  end
  fitQueueWidth(o) -- preview queue hugs its sample text too
  queue.bg:Show(); queue.label:Show(); queue:Show(); queue._live = true
end

-- Options buttons register a label updater so "Move"⇄"Lock" / "Test frames"⇄
-- "Hide test" track the live state (incl. when toggled via slash commands).
local modeBtnUpdater
local function notifyMode()
  if modeBtnUpdater then modeBtnUpdater(moverOn, testOn) end
end

-- Single source of truth for the editing chrome (out of combat). Frame
-- visibility (sample preview) = testOn or moverOn; drag affordances (mouse +
-- grid + coord panel) = moverOn. Live combat is owned by RenderTick, which
-- still freezes while moverOn (we only drag the preview, not live frames).
local function refreshFrames(o)
  o = o or ns.DB.Options()
  hud:EnableMouse(moverOn)
  queue:EnableMouse(moverOn)
  o.hud.locked = not moverOn
  o.queueAnchor.locked = not moverOn
  -- Move only drags frames that Test makes visible - it does NOT show the sample
  -- itself. Grid + coord panel are editing chrome, so they appear only when
  -- there are actually visible frames to move (Test on AND Move on).
  local editing = moverOn and testOn
  setGrid(editing and o.showGrid)
  if showPosPanel then showPosPanel(editing) end
  if testOn then
    showSample(o)
  else
    -- Drop the preview chrome. But if a live reminder is on screen (e.g. an
    -- option was changed mid-combat), leave the frame to RenderTick - don't yank
    -- a live alert. Out of combat there's nothing live, so hide outright.
    hud.bg:Hide(); hud.label:Hide()
    queue.bg:Hide(); queue.label:Hide()
    if not InCombatLockdown() then
      hud._active = false
      queue._live = false
      hud:Hide()
      queue:Hide()
    end
  end
  notifyMode()
end

function Reminders.IsMoving() return moverOn end
function Reminders.IsTesting() return testOn end
function Reminders.SetModeButtonUpdater(fn) modeBtnUpdater = fn; notifyMode() end

-- ── apply options (scale / font / color / positions / lock / queue rows) ───────
function Reminders.ApplyOptions()
  ensureFrames()
  local o = ns.DB.Options()
  local c = o.textColor or { r = 1, g = 0.95, b = 0.4 }

  hud:SetScale(o.scale or 1)
  queue:SetScale(o.scale or 1) -- queue tracks the global scale; rows are ~60% within
  -- style/timePos/font ownership lives in layoutHud (anchors + Show/Hide + fonts)
  layoutHud(o)
  hud.bar:SetStatusBarColor(c.r, c.g, c.b)
  restorePosition(hud, o.hud)
  restorePosition(queue, o.queueAnchor)

  -- (re)build queue rows as mini-HUD rows (icon + name + countdown) at ~60% size
  layoutQueueRows(o)

  refreshFrames(o) -- show preview / drag chrome per testOn / moverOn (or hide)
end

-- ── lock / mover ────────────────────────────────────────────────────────────────
-- Lock = stop dragging (Move off). The Test preview, if on, stays visible.
function Reminders.SetLocked(locked)
  ensureFrames()
  if locked then moverOn = false end
  refreshFrames()
end

-- Reset HUD + queue to their out-of-box positions (the "Reset" button).
-- Queue is placed centred directly BELOW the HUD, by anchoring it relative to the
-- HUD frame - so it stays centred regardless of HUD width.
local QUEUE_BELOW_GAP = 8
function Reminders.ResetPositions()
  ensureFrames()
  local o = ns.DB.Options()
  -- 1. Restore HUD to its canonical default (screen centre) and lay it out. The
  --    HUD is centre-anchored, so the block stays centred on that coordinate; the
  --    default (0,0) puts it dead-centre.
  local hudDef = ns.DB.DefaultPositions()
  for k, v in pairs(hudDef) do o.hud[k] = v end
  restorePosition(hud, o.hud)
  layoutHud(o)

  -- 2. Centre the queue's top under the HUD's bottom-centre, then persist it as a
  --    TOP(-centre)-anchored UIParent-CENTER position. Anchoring by TOP (not
  --    TOPLEFT) keeps the queue CENTRED as its width changes cue-to-cue, instead
  --    of growing rightward from a pinned left edge (which looked like drifting).
  queue:ClearAllPoints()
  queue:SetPoint("TOP", hud, "BOTTOM", 0, -QUEUE_BELOW_GAP)
  local qL, qW, top = queue:GetLeft(), queue:GetWidth(), queue:GetTop()
  local cx, cy = UIParent:GetCenter()
  local qcx = (qL and qW) and (qL + qW / 2) or nil
  if qcx and top and cx and cy then
    -- 3a. Re-anchor the queue's TOP-centre to UIParent CENTER and persist it.
    queue:ClearAllPoints()
    queue:SetPoint("TOP", UIParent, "CENTER", qcx - cx, top - cy)
    savePosition(queue, o.queueAnchor)
  else
    -- 3b. Frame rect not realized yet → GetLeft/GetTop returned nil. Do NOT
    --     savePosition here: the queue is still anchored relative to the icon,
    --     and savePosition would store relPoint=BOTTOMLEFT which restorePosition
    --     (UIParent-based) maps to the screen's bottom-left corner on /reload.
    --     Fall back to the safe static UIParent-relative default instead.
    local _, queueDef = ns.DB.DefaultPositions()
    for k, v in pairs(queueDef) do o.queueAnchor[k] = v end
    restorePosition(queue, o.queueAnchor)
  end
  -- Re-show the preview so it re-fits at the reset spot. Without this, the last
  -- layoutHud left the HUD at its wide "budget" width, and the centre anchor then
  -- shifted the sample text sideways until the next render refit it.
  refreshFrames(o)
  ns.Print("frame positions reset to default.")
end

-- Move ⇄ Lock toggle: when on, the shown frames become draggable (+ grid + the
-- X/Y coordinate panel). refreshFrames also shows a sample so there's something
-- to grab even if Test preview is off.
function Reminders.ToggleMover()
  ensureFrames()
  moverOn = not moverOn
  refreshFrames()
  if not moverOn then
    ns.Print("move mode OFF, positions saved.")
  elseif testOn then
    ns.Print("move mode ON: drag the frames or type X/Y in the panel, then Lock.")
  else
    ns.Print('move mode ON: press "Test frames" to show the frames, then drag them.')
  end
end

-- Test frames toggle: show/hide the sample preview frames (no drag - turn on
-- Move to reposition them). Independent of Move.
function Reminders.ToggleTest()
  ensureFrames()
  testOn = not testOn
  refreshFrames()
  ns.Print(testOn and "test frames shown." or "test frames hidden.")
end

-- ── coordinate-input panel (ElvUI-style: type exact X/Y for the selected frame) ──
-- A small draggable panel shown during move mode. Click the HUD or queue to
-- select it; its current offset (from screen centre) fills the X/Y boxes and
-- updates live while you drag. Type a number + Enter to place it precisely.
local posPanel, posTarget

local function targetSavedFor(f)
  local o = ns.DB.Options()
  return (f == queue) and o.queueAnchor or o.hud
end

local function refreshPosBoxes()
  if not (posPanel and posTarget) then return end
  local _, _, _, x, y = posTarget:GetPoint(1)
  x = math.floor((x or 0) + 0.5)
  y = math.floor((y or 0) + 0.5)
  posPanel.title:SetText(posTarget == queue and "Queue" or "Alert (HUD)")
  posPanel.xb.cur = x
  posPanel.yb.cur = y
  if not posPanel.xb:HasFocus() then posPanel.xb:SetText(tostring(x)) end
  if not posPanel.yb:HasFocus() then posPanel.yb:SetText(tostring(y)) end
end
onMoverDragTick = refreshPosBoxes

local function applyPos(axis, value)
  if not posTarget then return end
  local point, _, relPoint, x, y = posTarget:GetPoint(1)
  x = x or 0
  y = y or 0
  if axis == "x" then x = value else y = value end
  posTarget:ClearAllPoints()
  posTarget:SetPoint(point or "CENTER", UIParent, relPoint or "CENTER", x, y)
  savePosition(posTarget, targetSavedFor(posTarget))
  refreshPosBoxes()
end

local function buildPosPanel()
  local f = CreateFrame("Frame", "CoolPlanPosPanel", UIParent)
  f:SetSize(160, 96)
  f:SetFrameStrata("DIALOG")
  f:SetClampedToScreen(true) -- never let the panel render off the screen edge
  -- Initial anchor is set by showPosPanel → selectPosTarget; this is just a safe fallback.
  f:SetPoint("TOP", UIParent, "CENTER", 0, -40)
  -- NOT movable: it stays anchored to the selected frame and follows it while dragging.
  f:EnableMouse(true)

  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  do
    local p = ns.Style and ns.Style.colors.panel
    if p then bg:SetColorTexture(p[1], p[2], p[3], 0.92) else bg:SetColorTexture(0, 0, 0, 0.85) end
  end

  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  f.title:SetPoint("TOP", 0, -8)
  f.title:SetText("Alert (HUD)")

  local hint = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  hint:SetPoint("TOP", f.title, "BOTTOM", 0, -2)
  hint:SetText("click a frame, type X/Y, Enter")

  local function box(labelText, yOff, axis)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    lbl:SetPoint("TOPLEFT", 18, yOff)
    lbl:SetText(labelText)
    local eb = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    eb:SetSize(70, 18)
    eb:SetPoint("LEFT", lbl, "RIGHT", 10, 0)
    eb:SetAutoFocus(false)
    eb.cur = 0
    eb:SetScript("OnEnterPressed", ns.wrap(function(self)
      local n = tonumber(self:GetText())
      if n then applyPos(axis, math.floor(n + 0.5)) end
      self:ClearFocus()
    end))
    eb:SetScript("OnEscapePressed", ns.wrap(function(self) self:SetText(tostring(self.cur or 0)); self:ClearFocus() end))
    eb:SetScript("OnEditFocusLost", ns.wrap(function(self) self:SetText(tostring(self.cur or 0)) end))
    return eb
  end
  f.xb = box("X", -44, "x")
  f.yb = box("Y", -68, "y")

  -- live-update the boxes while a frame is being dragged
  f:SetScript("OnUpdate", ns.wrap(function() if draggingFrame then refreshPosBoxes() end end))
  return f
end

-- Re-anchor the coord panel to sit to the RIGHT of the given frame.
-- Uses a relative SetPoint so it automatically follows the frame when dragged.
local function anchorPanelToFrame(frame)
  if not (posPanel and frame) then return end
  posPanel:ClearAllPoints()
  -- Put the panel on whichever side keeps it on-screen: to the RIGHT of the
  -- frame normally, but flip to the LEFT when the frame sits in the right half
  -- of the screen (so a 160px panel doesn't spill off the right edge).
  -- SetClampedToScreen is a further backstop for the top/bottom edges.
  local fx = frame:GetCenter()
  local cx = (UIParent:GetWidth() or 0) / 2
  if fx and fx > cx then
    posPanel:SetPoint("RIGHT", frame, "LEFT", -8, 0)
  else
    posPanel:SetPoint("LEFT", frame, "RIGHT", 8, 0)
  end
end

selectPosTarget = function(frame)
  if frame ~= hud and frame ~= queue then return end
  posTarget = frame
  anchorPanelToFrame(frame)
  refreshPosBoxes()
end

showPosPanel = function(show)
  if show then
    if not posPanel then posPanel = buildPosPanel() end
    -- Always (re)start a move session on the HUD: a posTarget left over from a
    -- previous session could point at a frame that's now near/off a screen edge,
    -- which would anchor the panel off-screen ("panel doesn't show").
    posTarget = hud
    anchorPanelToFrame(posTarget)
    posPanel:Show()
    refreshPosBoxes()
  elseif posPanel then
    posPanel:Hide()
  end
end

-- ── per-tick render (called by Scheduler) ─────────────────────────────────────
-- active = { cue, remaining, total } or nil; upcoming = { {cue, remaining}, ... }
-- A cue has: kind ("cd" | "boss"), timeMs, spellId, spellName?, alert?, bossType?
function Reminders.RenderTick(active, upcoming, o)
  ensureFrames()
  -- NOTE: no early-return on moverOn. Move only toggles dragging; it must not
  -- block live rendering, so a test alert / demo / timeline test still shows the
  -- HUD (and stays draggable) while Move is on.

  if active and o.textEnabled then
    local cue = active.cue
    local isBoss = cue.kind == "boss"
    -- A note has no icon and its text starts at the far left; a spell shows its
    -- icon. layoutHud owns that split, so relayout only when the state FLIPS
    -- (this tick is otherwise value-only). applyCueIcon then blanks the note icon
    -- (harmless while hidden) or sets the spell/"?" texture, never a stale one.
    local isNote = (not cue.spellId or cue.spellId == 0)
    if isNote ~= hud._isNote then layoutHud(o, isNote) end
    applyCueIcon(hud.icon, cue)
    local c = isBoss and { r = 1, g = 0.45, b = 0.3 } or (validColor(o.textColor) and o.textColor or { r = 1, g = 0.95, b = 0.4 })
    -- update name TEXT/color only; layoutHud owns whether name (or barName, the
    -- in-bar variant for the "bar" style) is shown for the style
    local nameText = (isBoss and "|cffff7777[BOSS]|r " or "") .. labelFor(cue)
    hud.name:SetText(nameText)
    hud.name:SetTextColor(c.r, c.g, c.b)
    hud.count:SetTextColor(c.r, c.g, c.b) -- time follows the text color too
    if hud.barName then
      hud.barName:SetText(nameText)
      hud.barName:SetTextColor(c.r, c.g, c.b)
    end
    local total = active.total or (o.leadSeconds or 4)
    local rem = active.remaining
    if rem > 0 then
      -- decimal only when the time sits on the RIGHT (there's room); inside the
      -- icon/bar a "12.5" overflows the 52px icon, so keep it integer there.
      hud.count:SetText(o.timePos == "right" and string.format("%.1f", rem) or tostring(math.ceil(rem)))
      hud.bar:SetValue(math.max(0, math.min(1, total > 0 and rem / total or 0)))
      hud.bar:SetStatusBarColor(c.r, c.g, c.b)
    else
      hud.count:SetText("")
      hud.bar:SetValue(1)
      hud.bar:SetStatusBarColor(1, 0.2, 0.2) -- NOW
    end
    fitHudWidth(o, isNote) -- shrink the box to the actual text (name/count set)
    hud._active = true
    hud:Show()
  elseif not testOn then
    -- Between live cues: hide - UNLESS the Test preview is on, in which case keep
    -- the HUD visible (a running demo/test ticker must not hide the test frame).
    hud._active = false
    hud:Hide()
  end

  if o.showQueue and upcoming and #upcoming > 0 then
    local def = validColor(o.textColor) and o.textColor or { r = 1, g = 0.95, b = 0.4 }
    local style = o.hudStyle or "iconName"
    local lead = o.leadSeconds or 4
    for i, row in ipairs(queue.rows) do
      local item = upcoming[i]
      if item and row.icon then
        local cue = item.cue
        local isBoss = cue.kind == "boss"
        applyCueIcon(row.icon, cue)
        -- Mirror the HUD: a note (text style) drops its icon and starts the text
        -- at the far left; a spell keeps its icon with the name to its right.
        local isNote = (not cue.spellId or cue.spellId == 0)
        local tpos = o.timePos or "icon"
        local textStyle = (style ~= "bar" and style ~= "icon")
        row.name:ClearAllPoints()
        if isNote and textStyle then
          row.icon:Hide()
          if tpos == "icon" then
            -- no icon: the countdown takes the front slot, message follows it
            row.count:ClearAllPoints()
            row.count:SetPoint("LEFT", row, "LEFT", 3, 0); row.count:SetJustifyH("LEFT")
            row.name:SetPoint("LEFT", row.count, "RIGHT", 5, 0)
          else
            row.name:SetPoint("LEFT", row, "LEFT", 3, 0)
            row.count:ClearAllPoints()
            row.count:SetPoint("LEFT", row.name, "RIGHT", 5, 0); row.count:SetJustifyH("LEFT")
          end
        elseif textStyle then
          row.icon:Show()
          row.name:SetPoint("LEFT", row.icon, "RIGHT", 6, 0)
          -- restore the count anchor a prior note row in this slot may have moved
          row.count:ClearAllPoints()
          if tpos == "icon" then
            row.count:SetPoint("CENTER", row.icon, "CENTER", 0, 0); row.count:SetJustifyH("CENTER")
          else
            row.count:SetPoint("LEFT", row.name, "RIGHT", 5, 0); row.count:SetJustifyH("LEFT")
          end
        else
          row.icon:Show() -- bar/icon styles: layoutQueueRow owns the anchors
        end
        local c = isBoss and { r = 1, g = 0.45, b = 0.3 } or def
        -- layoutQueueRow owns name vs barName Show/Hide per style; just set both
        local nameText = (isBoss and "|cffff7777[B]|r " or "") .. labelFor(cue)
        row.name:SetText(nameText)
        row.name:SetTextColor(c.r, c.g, c.b)
        if row.barName then
          row.barName:SetText(nameText)
          row.barName:SetTextColor(c.r, c.g, c.b)
        end
        row.count:SetText(o.timePos == "right"
          and string.format("%.1f", math.max(0, item.remaining))
          or tostring(math.max(0, math.ceil(item.remaining))))
        row.count:SetTextColor(c.r, c.g, c.b)
        if style == "bar" and row.bar then
          row.bar:SetValue(math.max(0, math.min(1, lead > 0 and item.remaining / lead or 0)))
          row.bar:SetStatusBarColor(c.r, c.g, c.b)
        end
        row:Show()
      elseif row.Hide then
        row:Hide()
      end
    end
    fitQueueWidth(o) -- shrink rows/queue to the actual text (after texts are set)
    queue._live = true
    queue:Show()
  elseif not testOn then
    queue._live = false
    queue:Hide()
  end
end

-- ── text-to-speech ────────────────────────────────────────────────────────────
-- Resolve a USABLE voice id. Voice id 0 is not guaranteed to exist on every
-- client (different installed TTS voices), and SpeakText silently does nothing
-- for an unknown voice - that's why "TTS on" only played the warning sound.
-- Use the configured voice if it still exists, else the first installed one.
local function ttsVoiceId(o)
  local want = o and o.ttsVoice
  if C_VoiceChat and C_VoiceChat.GetTtsVoices then
    local voices = C_VoiceChat.GetTtsVoices()
    if voices and #voices > 0 then
      -- ttsVoice == 0 is the UNSET default, not a deliberate pick - so use the
      -- first actually-installed voice. Only honor an explicit non-zero choice.
      if want and want ~= 0 then
        for _, v in ipairs(voices) do if v.voiceID == want then return want end end
      end
      return voices[1].voiceID
    end
  end
  return want or 0
end

local function speak(text, o)
  if not (C_VoiceChat and C_VoiceChat.SpeakText) then return end
  local voiceId = ttsVoiceId(o)
  local rate = (C_TTSSettings and C_TTSSettings.GetSpeechRate and C_TTSSettings.GetSpeechRate()) or 0
  local volume = (C_TTSSettings and C_TTSSettings.GetSpeechVolume and C_TTSSettings.GetSpeechVolume()) or 100
  -- Retail (Midnight / Mainline) changed the signature: SpeakText DROPPED the
  -- destination enum -> (voiceID, text, rate, volume, true). We were passing the
  -- old form with a VoiceTtsDestination where rate goes, so the args were
  -- misaligned and TTS silently did nothing. (Matches Method Raid Tools.)
  if WOW_PROJECT_ID and WOW_PROJECT_MAINLINE and WOW_PROJECT_ID == WOW_PROJECT_MAINLINE then
    C_VoiceChat.SpeakText(voiceId, text, rate, volume, true)
  elseif Enum and Enum.VoiceTtsDestination then
    C_VoiceChat.SpeakText(voiceId, text, Enum.VoiceTtsDestination.QueuedLocalPlayback, rate, volume)
  end
end
ns.Reminders._speak = speak

-- ── discrete cues (fired once when a reminder's sound/TTS lead window opens) ────
-- A single alert mode picks the audible channel: "sound" plays a sound kit,
-- "tts" speaks the cooldown name, "none" stays silent (on-screen text only).
-- Hybrid sound playback: a saved value can be EITHER a SOUNDKIT constant name
-- (legacy / our pinned "Raid Warning" default) OR a LibSharedMedia sound name
-- (the big shared list, file-path based). Try SOUNDKIT first (back-compat, no
-- migration needed), then LSM via PlaySoundFile, else fall back to Raid Warning.
function Reminders.PlaySound(key)
  key = key or "RAID_WARNING"
  local kit = SOUNDKIT and SOUNDKIT[key]
  if kit then PlaySound(kit, "Master"); return end
  local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)
  if LSM then
    local path = LSM:Fetch("sound", key, true) -- silent=true → nil if missing
    if path then PlaySoundFile(path, "Master"); return end
  end
  if SOUNDKIT and SOUNDKIT.RAID_WARNING then PlaySound(SOUNDKIT.RAID_WARNING, "Master") end
end

function Reminders.Cue(reminder, o)
  local mode = o.alertSound or "sound"
  if mode == "sound" then
    Reminders.PlaySound(o.soundKit)
  elseif mode == "tts" then
    speak(labelFor(reminder), o)
  end
end

-- Spoken "3..2..1" countdown before a cue - ALWAYS uses TTS and is independent
-- of the alert sound mode (works on Sound/None too) and of the spell-name TTS.
function Reminders.SpeakCountdown(n, o)
  speak(tostring(n), o)
end

function Reminders.Clear()
  ensureFrames()
  hud._active = false
  queue._live = false
  -- After a test/demo/encounter: if the Test preview is on, restore it; else
  -- hide. (Move alone never shows frames, so there's nothing to keep.)
  if testOn then
    showSample()
  else
    hud:Hide(); queue:Hide()
  end
end

-- ── quick test (sound flash) + countdown demo without an encounter ─────────────
function Reminders.Test()
  ensureFrames()
  local o = ns.DB.Options()
  local cue = { kind = "cd", spellId = 740, alert = "CoolPlan test" }
  Reminders.Cue(cue, o)
  -- TTS diagnostic: list the installed voices + the one we use, so a silent TTS
  -- is explained (api missing / no voices / wrong output device).
  if o.alertSound == "tts" then
    local voices = (C_VoiceChat and C_VoiceChat.GetTtsVoices and C_VoiceChat.GetTtsVoices()) or {}
    local hasApi = (C_VoiceChat and C_VoiceChat.SpeakText) ~= nil
    ns.Print(("TTS: api=%s, voices=%d, using id=%s"):format(tostring(hasApi), #voices, tostring(ttsVoiceId(o))))
    for _, v in ipairs(voices) do
      ns.Print(("   id=%s  %s"):format(tostring(v.voiceID), tostring(v.name)))
    end
    if #voices == 0 then
      ns.Print("|cffff6666no TTS voices, add one in Windows Speech settings, then /reload|r")
    elseif hasApi then
      ns.Print("|cff888888if still silent: Esc > Options > Voice Chat. TTS plays through the voice-chat OUTPUT device.|r")
    end
  end
  Reminders.RenderTick({ cue = cue, remaining = 0, total = o.leadSeconds }, nil, o)
  C_Timer.After(1.5, ns.wrap(function() Reminders.Clear() end))
end

function Reminders.StopTest()
  if testTicker then testTicker:Cancel(); testTicker = nil end
  Reminders.Clear()
end
