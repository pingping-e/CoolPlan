-- Single-window shell with a left navigation sidebar. One movable frame with a
-- title + close button; the right-hand content host is swapped per page. Pages
-- are built lazily: the first time a page is opened, its module's
-- BuildPage(host) is called to attach widgets to the content host, then reused.
--
-- Modules register themselves via Window.RegisterPage(key, label, builder). The
-- builder receives the content host frame and returns nothing (it attaches
-- widgets to host). A page may expose host._onShow(host) which Window calls
-- every time the page becomes visible (used for refresh-on-show).

local _, ns = ...
local Window = {}
ns.Window = Window

-- ordered page registry: { {key, label, builder, host} ... }
local pages = {}
local byKey = {}
local frame, sidebar, contentArea
local navButtons = {}
local current

local NAV_W = 150

-- Modules call this at file-load time (before PLAYER_LOGIN). Order of calls is
-- the order the tabs appear; the spec order is Timeline · Saved · Import · Options.
function Window.RegisterPage(key, label, builder)
  if byKey[key] then
    byKey[key].label = label
    byKey[key].builder = builder
    return
  end
  local page = { key = key, label = label, builder = builder, host = nil }
  pages[#pages + 1] = page
  byKey[key] = page
end

-- ── shell construction ───────────────────────────────────────────────────────
local function buildNav()
  for _, btn in ipairs(navButtons) do btn:Hide() end
  wipe(navButtons)
  for i, page in ipairs(pages) do
    local btn = CreateFrame("Button", nil, sidebar)
    btn:SetSize(NAV_W - 12, 26)
    btn:SetPoint("TOPLEFT", 6, -8 - (i - 1) * 30)

    local hl = btn:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.10)

    -- hover tint to accent
    if ns.Style then hl:SetColorTexture(ns.Style.colors.accent[1], ns.Style.colors.accent[2], ns.Style.colors.accent[3], 0.12) end

    local sel = btn:CreateTexture(nil, "BACKGROUND")
    sel:SetAllPoints()
    if ns.Style then
      local a = ns.Style.colors.accent
      sel:SetColorTexture(a[1], a[2], a[3], 0.22)
    else
      sel:SetColorTexture(0.20, 0.45, 0.85, 0.45)
    end
    sel:Hide()
    btn.sel = sel

    -- accent left bar for the active tab
    local bar = btn:CreateTexture(nil, "ARTWORK")
    bar:SetPoint("TOPLEFT", 0, 0)
    bar:SetPoint("BOTTOMLEFT", 0, 0)
    bar:SetWidth(2)
    if ns.Style then
      local a = ns.Style.colors.accent
      bar:SetColorTexture(a[1], a[2], a[3], 1)
    else
      bar:SetColorTexture(0.20, 0.45, 0.85, 1)
    end
    bar:Hide()
    btn.bar = bar

    local fs = btn:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    fs:SetPoint("LEFT", 8, 0)
    fs:SetText(page.label)
    btn.fs = fs

    btn.key = page.key
    btn:SetScript("OnClick", ns.wrap(function() Window.Open(page.key) end))
    navButtons[i] = btn
  end
end

local function highlightNav(key)
  local accent = ns.Style and ns.Style.colors.accent
  local text = ns.Style and ns.Style.colors.text
  local subtle = ns.Style and ns.Style.colors.subtle
  for _, btn in ipairs(navButtons) do
    if btn.key == key then
      btn.sel:Show()
      if btn.bar then btn.bar:Show() end
      btn.fs:SetFontObject(GameFontNormal)
      if text then btn.fs:SetTextColor(text[1], text[2], text[3]) end
    else
      btn.sel:Hide()
      if btn.bar then btn.bar:Hide() end
      btn.fs:SetFontObject(GameFontHighlight)
      if subtle then btn.fs:SetTextColor(subtle[1], subtle[2], subtle[3]) end
    end
  end
end

local function build()
  local o = ns.DB and ns.DB.Options and ns.DB.Options()
  local f = CreateFrame("Frame", "CoolPlanWindow", UIParent, "BackdropTemplate")
  -- Esc closes the window, like most addons. UISpecialFrames hides the named
  -- frame on Esc; closing is just a Hide (lastPage is saved on open, not close),
  -- so nothing is lost. Guard against a double-insert if build() ever reruns.
  if not tContains(UISpecialFrames, "CoolPlanWindow") then
    tinsert(UISpecialFrames, "CoolPlanWindow")
  end
  -- Size bounds: min so the content-heavy Options page can lay out (the bottom
  -- action row must clear the right-hand column, hence 940); max so it can never
  -- grow past the screen and put the resize grip out of reach.
  local MIN_W = 940
  local maxW = math.min(1600, math.max(MIN_W, (UIParent:GetWidth() or 1280) - 40))
  local maxH = math.min(1000, math.max(700, (UIParent:GetHeight() or 800) - 40))
  local function clampSize(v, lo, hi) return math.min(math.max(v or lo, lo), hi) end
  -- min height 700: the Options page stacks Timing+Queue and the category grid in
  -- the middle/left, and the bottom action row is pinned to the frame bottom, a
  -- shorter frame let those buttons ride up over the last category rows.
  f:SetSize(clampSize((o and o.windowW) or MIN_W, MIN_W, maxW), clampSize((o and o.windowH) or 700, 700, maxH))
  f:SetPoint("CENTER")
  f:SetFrameStrata("DIALOG")
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", f.StartMoving)
  f:SetScript("OnDragStop", f.StopMovingOrSizing)
  f:SetClampedToScreen(true)

  -- resizable from a bottom-right grip; the sidebar/content use anchored points
  -- so they reflow automatically. Size is saved across sessions.
  f:SetResizable(true)
  if f.SetResizeBounds then
    f:SetResizeBounds(MIN_W, 700, maxW, maxH)
  elseif f.SetMinResize then
    f:SetMinResize(MIN_W, 700)
    if f.SetMaxResize then f:SetMaxResize(maxW, maxH) end
  end
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  -- Only start sizing after the cursor actually moves a few px. Otherwise a plain
  -- click made StartSizing snap the corner to the cursor (grip sits inset from the
  -- corner), shrinking the window on a mere click.
  local gripSizing = false
  grip:SetScript("OnMouseDown", ns.wrap(function(self)
    gripSizing = false
    local sx, sy = GetCursorPosition()
    self:SetScript("OnUpdate", ns.wrap(function()
      local cx, cy = GetCursorPosition()
      if (not gripSizing) and (math.abs(cx - sx) + math.abs(cy - sy)) > 4 then
        gripSizing = true
        f:StartSizing("BOTTOMRIGHT")
      end
    end))
  end))
  grip:SetScript("OnMouseUp", ns.wrap(function(self)
    self:SetScript("OnUpdate", nil)
    if gripSizing then
      f:StopMovingOrSizing()
      local oo = ns.DB and ns.DB.Options and ns.DB.Options()
      if oo then oo.windowW = math.floor(f:GetWidth() + 0.5); oo.windowH = math.floor(f:GetHeight() + 0.5) end
      if current and current.host and current.host._onResize then ns.safecall(current.host._onResize, current.host) end
    end
    gripSizing = false
  end))
  -- safety: if the window hides mid-drag (Esc/close), release sizing so it can't
  -- keep following the cursor after a missed mouse-up.
  f:SetScript("OnHide", ns.wrap(function()
    grip:SetScript("OnUpdate", nil)
    gripSizing = false
    f:StopMovingOrSizing()
  end))
  if ns.Style then
    ns.Style.Panel(f, 0.98)
  elseif f.SetBackdrop then
    f:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end

  -- title bar accent strip (a thin brand line under the title)
  local titlebar = f:CreateTexture(nil, "ARTWORK")
  titlebar:SetPoint("TOPLEFT", 12, -38)
  titlebar:SetPoint("TOPRIGHT", -12, -38)
  titlebar:SetHeight(1)
  if ns.Style then
    local a = ns.Style.colors.accent
    titlebar:SetColorTexture(a[1], a[2], a[3], 0.5)
  else
    titlebar:SetColorTexture(0.2, 0.45, 0.85, 0.5)
  end

  local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  -- nudge the title right so the brand icon + wordmark read as a centered pair.
  title:SetPoint("TOP", 12, -14)
  title:SetText("|cff66b3ffCoolPlan|r")
  f.title = title

  -- brand icon to the LEFT of the wordmark (reuses the minimap/logo asset)
  local titleIcon = f:CreateTexture(nil, "OVERLAY")
  titleIcon:SetSize(20, 20)
  titleIcon:SetPoint("RIGHT", title, "LEFT", -5, 0)
  titleIcon:SetTexture("Interface\\AddOns\\CoolPlan\\media\\logo.tga")
  f.titleIcon = titleIcon

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  -- Window scale slider (top-left). Drag to zoom the whole window 50%-150%.
  -- SetScale scales the frame and all children uniformly; the saved size stays in
  -- unscaled units, so scale is independent of the resize grip. Persisted in
  -- o.windowScale so small screens can shrink the window to fit.
  local function clampScale(s) return math.min(1.5, math.max(0.5, tonumber(s) or 1)) end
  f:SetScale(clampScale(o and o.windowScale))
  local scaleLbl = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  scaleLbl:SetPoint("TOPLEFT", 16, -16)
  local function setScaleLabel(v) scaleLbl:SetText(("Scale: |cffffffff%.2f|r"):format(v)) end
  local scaleSlider = CreateFrame("Slider", "CoolPlanWindowScale", f, "OptionsSliderTemplate")
  scaleSlider:SetPoint("LEFT", scaleLbl, "RIGHT", 10, 0)
  scaleSlider:SetWidth(120)
  scaleSlider:SetHeight(16)
  scaleSlider:SetMinMaxValues(0.5, 1.5)
  scaleSlider:SetValueStep(0.05)
  scaleSlider:SetObeyStepOnDrag(true)
  do
    local sn = scaleSlider:GetName()
    if _G[sn .. "Low"] then _G[sn .. "Low"]:SetText("") end
    if _G[sn .. "High"] then _G[sn .. "High"]:SetText("") end
    if _G[sn .. "Text"] then _G[sn .. "Text"]:SetText("") end
  end
  scaleSlider:SetValue(clampScale(o and o.windowScale))
  setScaleLabel(clampScale(o and o.windowScale))
  -- While dragging, only move the thumb + update the label. Do NOT rescale the
  -- window mid-drag: SetScale would scale the slider itself, shift the thumb out
  -- from under the cursor, and make the value jump to an extreme. Apply the new
  -- scale once, on mouse release.
  scaleSlider:SetScript("OnValueChanged", ns.wrap(function(self, v)
    self._pending = clampScale(math.floor(v / 0.05 + 0.5) * 0.05)
    setScaleLabel(self._pending)
  end))
  scaleSlider:SetScript("OnMouseUp", ns.wrap(function(self)
    local v = clampScale(self._pending or (o and o.windowScale))
    local oo = ns.DB and ns.DB.Options and ns.DB.Options()
    if oo then oo.windowScale = v end
    f:SetScale(v)
  end))

  -- left sidebar
  sidebar = CreateFrame("Frame", nil, f, "BackdropTemplate")
  sidebar:SetPoint("TOPLEFT", 12, -44)
  sidebar:SetPoint("BOTTOMLEFT", 12, 38)
  sidebar:SetWidth(NAV_W)
  if ns.Style then
    ns.Style.InsetPanel(sidebar, 0.85)
  elseif sidebar.SetBackdrop then
    sidebar:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true, tileSize = 16, edgeSize = 12,
      insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
  end

  -- right content host (each page attaches its widgets here)
  contentArea = CreateFrame("Frame", "CoolPlanWindowContent", f)
  contentArea:SetPoint("TOPLEFT", sidebar, "TOPRIGHT", 10, 0)
  contentArea:SetPoint("BOTTOMRIGHT", -14, 38)
  -- bordered panel (like the sidebar) so the content area reads as a distinct
  -- region and the footer below it is clearly separated.
  if ns.Style and ns.Style.InsetPanel then ns.Style.InsetPanel(contentArea, 0.85) end

  -- footer: version + selectable (drag-to-copy) site / discord links.
  local verStr = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("CoolPlan", "Version")) or "?"
  local foot = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
  foot:SetPoint("BOTTOMLEFT", 16, 16)
  foot:SetText("v" .. verStr)

  -- a label + bordered read-only EditBox so the URL can be selected (drag) and
  -- copied (Ctrl+C), with a subtle border so it reads as a link, not an input.
  local function labeledLink(anchor, label, url, boxW)
    local lbl = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    lbl:SetPoint("LEFT", anchor, "RIGHT", 16, 0)
    lbl:SetText("|cffaaaaaa" .. label .. "|r")
    local b = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    b:SetFontObject(GameFontDisableSmall)
    b:SetAutoFocus(false)
    b:SetSize(boxW, 16)
    b:SetPoint("LEFT", lbl, "RIGHT", 8, 0)
    b:SetText(url)
    b:EnableMouse(true)
    b:SetScript("OnEscapePressed", ns.wrap(function(s) s:ClearFocus() end))
    b:SetScript("OnEditFocusGained", ns.wrap(function(s) s:HighlightText() end))
    b:SetScript("OnEditFocusLost", ns.wrap(function(s) s:HighlightText(0, 0); s:SetCursorPosition(0) end))
    -- read-only: revert any typed change so it stays copy-only
    b:SetScript("OnChar", ns.wrap(function(s) s:SetText(url); s:HighlightText() end))
    b:SetScript("OnTextChanged", ns.wrap(function(s, user) if user then s:SetText(url); s:HighlightText() end end))
    return b
  end
  local siteBox = labeledLink(foot, "Planner", "https://coolplan.team", 150)
  labeledLink(siteBox, "Discord", "https://discord.gg/atcYRRG8ka", 185)

  return f
end

-- ── page lifecycle ───────────────────────────────────────────────────────────
local function ensurePage(page)
  if page.host then return page.host end
  -- a per-page host frame parented to the shared content area; all the page's
  -- widgets live under it so we can show/hide an entire page at once.
  local host = CreateFrame("Frame", nil, contentArea)
  -- inset inside contentArea's border so page widgets (dropdowns, etc.) sit
  -- within the bordered panel instead of spilling over its edge.
  host:SetPoint("TOPLEFT", contentArea, "TOPLEFT", 6, -6)
  host:SetPoint("BOTTOMRIGHT", contentArea, "BOTTOMRIGHT", -6, 6)
  host:Hide()
  page.host = host
  if page.builder then ns.safecall(page.builder, host) end
  return host
end

-- Open the window on a given page (default: last page, else first/Timeline).
function Window.Open(pageKey)
  if not frame then
    frame = build()
    buildNav()
  end

  if not pageKey then
    local o = ns.DB and ns.DB.Options and ns.DB.Options()
    pageKey = (o and o.lastPage) or (pages[1] and pages[1].key)
  end
  local page = byKey[pageKey] or pages[1]
  if not page then
    frame:Show()
    return
  end

  -- hide the currently shown page host
  if current and current.host then current.host:Hide() end

  local host = ensurePage(page)
  host:Show()
  current = page
  highlightNav(page.key)
  frame.title:SetText("|cff66b3ffCoolPlan|r  |cffaaaaaa-  " .. page.label .. "|r")

  local o = ns.DB and ns.DB.Options and ns.DB.Options()
  if o then o.lastPage = page.key end

  if host._onShow then ns.safecall(host._onShow, host) end

  frame:Show()
end

function Window.Close()
  if frame then frame:Hide() end
end

function Window.Toggle(pageKey)
  if frame and frame:IsShown() and (not pageKey or (current and current.key == pageKey)) then
    frame:Hide()
  else
    Window.Open(pageKey)
  end
end

-- Expose the frame (used by a few helpers / tests).
function Window.GetFrame() return frame end
function Window.IsShown() return frame and frame:IsShown() end

-- ── shared content-group helpers (used by Saved/Timeline category dropdowns) ──
-- ns.Content is emitted by gen-addon-encounter-names.ts. Provide safe
-- accessors so pages don't each re-derive the grouping.
function Window.Categories()
  return ns.Content or {}
end

function Window.CategoryByKey(key)
  for _, cat in ipairs(ns.Content or {}) do
    if cat.key == key then return cat end
  end
  return nil
end

-- Groups (dungeons / raid instances) of a category. Each group is
-- { name=, kr=, bosses = { { id?=, name=, kr= }, ... } }.
function Window.Groups(catKey)
  local cat = Window.CategoryByKey(catKey)
  return (cat and cat.groups) or {}
end

-- Resolve a boss to its saved-library encounterID. The catalog only carries an
-- `id` for the dungeon's deepest (resolved) boss; for every other boss the
-- WCL per-boss id lives only on imported plans, so we match by name against the
-- library. Returns nil when no saved entry exists for this boss (the boss can
-- still be selected; the page shows an empty state).
function Window.ResolveBossId(bossName, fallbackId)
  -- 1) Name match is the reliable key: each imported per-boss plan carries the
  --    boss's own name. (Prefer this over the catalog id, because a boss-scoped
  --    M+ export is keyed by the DUNGEON's WCL id - shared across the dungeon's
  --    bosses - so trusting the catalog id collides them.)
  if bossName and bossName ~= "" and ns.DB and ns.DB.Library then
    for id, entry in pairs(ns.DB.Library() or {}) do
      if entry and entry.name == bossName then return id end
    end
  end
  -- 2) Catalog id only if the saved entry there is actually THIS boss (or has no
  --    name), so a dungeon-level id never shows one boss's plan under another.
  if fallbackId and ns.DB and ns.DB.GetEncounter then
    local e = ns.DB.GetEncounter(fallbackId)
    if e and (not e.name or e.name == "" or e.name == bossName) then
      return fallbackId
    end
  end
  return nil
end

-- Display name for an encounterID: prefer a saved library entry's own name,
-- then the content/fallback tables, then "Encounter <id>".
function Window.EncounterName(id)
  local e = ns.DB and ns.DB.GetEncounter and ns.DB.GetEncounter(id)
  if e and e.name and e.name ~= "" then return e.name end
  if ns.EncounterNames and ns.EncounterNames[id] then
    return ns.EncounterNames[id]
  end
  return "Encounter " .. tostring(id)
end

-- ── reusable select control (backed by ns.Picker) ────────────────────────────
-- Returns a flat button that opens the shared scrollable/searchable popup picker
-- (same look as the sound picker). `getItems()` returns { {text=, value=}, ... };
-- `onSelect(value, text)` fires after a pick. Keeps the old API: dd:SetValue,
-- dd:SetPoint, dd:SetEnabled.
-- Make any select-style button (MakeDropdown, or a button that opens a picker
-- like the sound cue) read as a dropdown: left-justified clipped label + a thin,
-- dim down-chevron on the right. A texture/atlas (never a unicode glyph) keeps it
-- font-safe. Shared so every select looks the same.
function Window.AddSelectArrow(btn)
  local fs = btn.GetFontString and btn:GetFontString()
  if fs then
    fs:ClearAllPoints()
    fs:SetPoint("LEFT", 8, 0)
    fs:SetPoint("RIGHT", -20, 0) -- room for the chevron
    fs:SetJustifyH("LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(false) end
  end
  local arrow = btn:CreateTexture(nil, "OVERLAY")
  arrow:SetSize(12, 12)
  arrow:SetPoint("RIGHT", -7, 0)
  -- check the atlas exists first (no pcall/closure churn); SetAtlas on a known
  -- atlas can't error. Fall back to a texture if neither atlas is present.
  local set = false
  if arrow.SetAtlas and C_Texture and C_Texture.GetAtlasInfo then
    for _, a in ipairs({ "uitools-icon-chevron-down", "common-dropdown-icon" }) do
      if C_Texture.GetAtlasInfo(a) then arrow:SetAtlas(a); set = true; break end
    end
  end
  if not set then
    arrow:SetTexture("Interface\\Buttons\\Arrow-Down-Up")
  end
  arrow:SetVertexColor(0.55, 0.55, 0.55)
  btn.arrow = arrow
  return arrow
end

function Window.MakeDropdown(parent, name, width, getItems, onSelect)
  width = width or 160
  local dd = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
  dd:SetSize(width, 22)
  dd._value = nil

  -- left-justified clipped label + dropdown chevron (shared helper)
  Window.AddSelectArrow(dd)

  -- programmatically set value + display text without firing onSelect
  function dd:SetValue(value, text)
    self._value = value
    self:SetText(text or "")
  end

  dd:SetScript("OnClick", ns.wrap(function(self)
    if ns.Picker.IsShown() then ns.Picker.Hide(); return end
    ns.Picker.Open(self, {
      width = width,
      current = self._value,
      getItems = getItems,
      search = "auto", -- show a search box only for long lists
      onPick = function(value, text)
        self:SetValue(value, text)
        if onSelect then onSelect(value, text) end
      end,
    })
  end))

  if ns.Style and ns.Style.Button then ns.Style.Button(dd) end
  return dd
end
