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
  -- clamp the saved size up to the minimum so the content-heavy Options page
  -- never opens smaller than it can lay out.
  f:SetSize(math.max((o and o.windowW) or 860, 760), math.max((o and o.windowH) or 640, 620))
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
  if f.SetResizeBounds then f:SetResizeBounds(760, 620)
  elseif f.SetMinResize then f:SetMinResize(760, 620) end
  local grip = CreateFrame("Button", nil, f)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -4, 4)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", ns.wrap(function() f:StartSizing("BOTTOMRIGHT") end))
  grip:SetScript("OnMouseUp", ns.wrap(function()
    f:StopMovingOrSizing()
    local oo = ns.DB and ns.DB.Options and ns.DB.Options()
    if oo then oo.windowW = math.floor(f:GetWidth() + 0.5); oo.windowH = math.floor(f:GetHeight() + 0.5) end
    if current and current.host and current.host._onResize then ns.safecall(current.host._onResize, current.host) end
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
  title:SetPoint("TOP", 0, -14)
  title:SetText("|cff66b3ffCoolPlan|r")
  f.title = title

  local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", -4, -4)

  -- left sidebar
  sidebar = CreateFrame("Frame", nil, f, "BackdropTemplate")
  sidebar:SetPoint("TOPLEFT", 12, -44)
  sidebar:SetPoint("BOTTOMLEFT", 12, 14)
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
  contentArea:SetPoint("BOTTOMRIGHT", -14, 14)

  return f
end

-- ── page lifecycle ───────────────────────────────────────────────────────────
local function ensurePage(page)
  if page.host then return page.host end
  -- a per-page host frame parented to the shared content area; all the page's
  -- widgets live under it so we can show/hide an entire page at once.
  local host = CreateFrame("Frame", nil, contentArea)
  host:SetAllPoints(contentArea)
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
  frame.title:SetText("|cff66b3ffCoolPlan|r  |cffaaaaaa—  " .. page.label .. "|r")

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
-- CoolPlanContent is emitted by gen-addon-encounter-names.ts. Provide safe
-- accessors so pages don't each re-derive the grouping.
function Window.Categories()
  return CoolPlanContent or {}
end

function Window.CategoryByKey(key)
  for _, cat in ipairs(CoolPlanContent or {}) do
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
  --    M+ export is keyed by the DUNGEON's WCL id — shared across the dungeon's
  --    bosses — so trusting the catalog id collides them.)
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
  if CoolPlanEncounterNames and CoolPlanEncounterNames[id] then
    return CoolPlanEncounterNames[id]
  end
  return "Encounter " .. tostring(id)
end

-- ── reusable UIDropDownMenu wrapper ──────────────────────────────────────────
-- Creates a dropdown. `getItems()` must return a list of { text=, value=,
-- (optional) onClick= }. `onSelect(value, text)` fires after a pick. The
-- caller drives the displayed text via dd:Refresh(value, text).
function Window.MakeDropdown(parent, name, width, getItems, onSelect)
  local dd = CreateFrame("Frame", name, parent, "UIDropDownMenuTemplate")
  dd._value = nil

  local function init(self, level)
    local items = getItems() or {}
    for _, it in ipairs(items) do
      local info = UIDropDownMenu_CreateInfo()
      info.text = it.text
      info.value = it.value
      info.checked = (dd._value == it.value)
      info.func = ns.wrap(function()
        dd._value = it.value
        UIDropDownMenu_SetText(dd, it.text)
        CloseDropDownMenus()
        if onSelect then onSelect(it.value, it.text) end
      end)
      UIDropDownMenu_AddButton(info, level)
    end
  end

  UIDropDownMenu_Initialize(dd, ns.wrap(init))
  UIDropDownMenu_SetWidth(dd, width or 160)
  UIDropDownMenu_JustifyText(dd, "LEFT")

  -- Whole-box click: the stock template only opens when the small arrow button
  -- is clicked. Lay a transparent button over the visible field area so a click
  -- anywhere in the box toggles the menu. The arrow button keeps working too.
  do
    local ddName = dd.GetName and dd:GetName()
    local arrow = ddName and _G[ddName .. "Button"]
    local hit = CreateFrame("Button", nil, dd)
    -- cover the visible field: the template pads ~16px left and the arrow sits
    -- on the right, so span between them. Leave the arrow itself clickable.
    hit:SetPoint("TOPLEFT", dd, "TOPLEFT", 16, -2)
    hit:SetPoint("BOTTOMRIGHT", dd, "BOTTOMRIGHT", -16, 2)
    hit:SetFrameLevel((dd:GetFrameLevel() or 1) + 1)
    hit:RegisterForClicks("LeftButtonUp")
    hit:SetScript("OnClick", ns.wrap(function()
      if arrow and arrow.Click then
        arrow:Click()        -- reuse the template's own toggle logic
      else
        ToggleDropDownMenu(1, nil, dd, dd, 0, 0)
      end
    end))
    -- subtle hover tint across the whole box (matches Style accent)
    local hl = hit:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    if ns.Style then
      local a = ns.Style.colors.accent
      hl:SetColorTexture(a[1], a[2], a[3], 0.12)
    else
      hl:SetColorTexture(1, 1, 1, 0.08)
    end
    dd._hit = hit
  end

  -- programmatically set value + display text without firing onSelect
  function dd:SetValue(value, text)
    self._value = value
    UIDropDownMenu_SetText(self, text or "")
  end

  return dd
end
