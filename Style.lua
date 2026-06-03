-- Shared dark-flat skin for CoolPlan's own frames. The goal is an app-like look
-- (MRT / ElvUI feel) instead of WoW's stock gold DialogBox texture: a near-black
-- panel with a 1px border and a brand-blue accent. Everything here is defensive
-- — every WoW method we call is nil-guarded and wrapped — and we ONLY skin our
-- own widgets (never library frames like LibDBIcon's minimap button).
--
-- Usage: a page builds its widgets, then calls ns.Style.Apply(host) once to skin
-- the buttons / editboxes / checkboxes / sliders / scrollbars / dropdowns it
-- created. Containers that own their own backdrop (the Window shell, popups, the
-- combat HUD) call ns.Style.Panel(frame) directly. Nothing here runs at file
-- load — callers invoke it from PLAYER_LOGIN-driven build paths.

local _, ns = ...
local Style = {}
ns.Style = Style

-- ── palette ──────────────────────────────────────────────────────────────────
local C = {
  bg         = { 0.05, 0.06, 0.08 }, -- window shell base
  panel      = { 0.08, 0.09, 0.11 }, -- sidebar / popup body
  panelLight = { 0.12, 0.13, 0.16 }, -- buttons, editboxes, hover targets
  border     = { 0.20, 0.23, 0.28 }, -- 1px borders
  accent     = { 0.23, 0.51, 0.96 }, -- brand #3b82f6
  accentDim  = { 0.23, 0.51, 0.96, 0.30 },
  text       = { 0.90, 0.92, 0.95 },
  subtle     = { 0.60, 0.63, 0.69 },
}
Style.colors = C

local WHITE = "Interface\\Buttons\\WHITE8X8"

-- ── small guards ─────────────────────────────────────────────────────────────
local function has(obj, method)
  return obj and type(obj[method]) == "function"
end

-- Ensure a frame can take a backdrop. Retail moved SetBackdrop onto
-- BackdropTemplateMixin; mix it in when the frame predates the template. Returns
-- true if the frame can now SetBackdrop.
local function ensureBackdrop(frame)
  if not frame then return false end
  if has(frame, "SetBackdrop") then return true end
  if BackdropTemplateMixin and type(Mixin) == "function" then
    Mixin(frame, BackdropTemplateMixin)
    if has(frame, "OnBackdropLoaded") then pcall(frame.OnBackdropLoaded, frame) end
    return has(frame, "SetBackdrop")
  end
  return false
end

-- ── flat panel backdrop ──────────────────────────────────────────────────────
function Style.Panel(frame, alpha)
  if not ensureBackdrop(frame) then return end
  local p = C.panel
  pcall(frame.SetBackdrop, frame, {
    bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  if has(frame, "SetBackdropColor") then
    frame:SetBackdropColor(p[1], p[2], p[3], alpha or 0.97)
  end
  if has(frame, "SetBackdropBorderColor") then
    frame:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
  end
end

-- A slightly lighter inset panel (used for the sidebar, list backgrounds).
function Style.InsetPanel(frame, alpha)
  if not ensureBackdrop(frame) then return end
  local p = C.bg
  pcall(frame.SetBackdrop, frame, {
    bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
    insets = { left = 1, right = 1, top = 1, bottom = 1 },
  })
  if has(frame, "SetBackdropColor") then
    frame:SetBackdropColor(p[1], p[2], p[3], alpha or 0.9)
  end
  if has(frame, "SetBackdropBorderColor") then
    frame:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1)
  end
end

-- ── button ───────────────────────────────────────────────────────────────────
-- Kill the gold UIPanelButtonTemplate art, draw a flat panelLight rect with a
-- 1px border, brand-accent on hover, dim when disabled. Idempotent.
function Style.Button(btn)
  if not btn or btn._cpSkinned then return end
  if has(btn, "GetObjectType") and btn:GetObjectType() ~= "Button" then return end

  -- blank out the stock textures (guarded — not every Button has them)
  local empty = function(set)
    if has(btn, set) then pcall(btn[set], btn, nil) end
  end
  empty("SetNormalTexture"); empty("SetPushedTexture")
  empty("SetDisabledTexture"); empty("SetHighlightTexture")
  if has(btn, "GetNormalTexture") and btn:GetNormalTexture() then btn:GetNormalTexture():SetTexture(nil) end
  if has(btn, "GetPushedTexture") and btn:GetPushedTexture() then btn:GetPushedTexture():SetTexture(nil) end

  -- flat background + 1px border via our own textures
  local bg = btn:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(C.panelLight[1], C.panelLight[2], C.panelLight[3], 1)
  btn._cpBg = bg

  -- 1px border = four thin edge textures (works without a backdrop template)
  local function edge(p1, p2)
    local t = btn:CreateTexture(nil, "BORDER")
    t:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    t:SetPoint(p1); t:SetPoint(p2)
    return t
  end
  local top = edge("TOPLEFT", "TOPRIGHT");       top:SetHeight(1)
  local bot = edge("BOTTOMLEFT", "BOTTOMRIGHT");  bot:SetHeight(1)
  local lft = edge("TOPLEFT", "BOTTOMLEFT");      lft:SetWidth(1)
  local rgt = edge("TOPRIGHT", "BOTTOMRIGHT");     rgt:SetWidth(1)
  btn._cpBorder = { top, bot, lft, rgt }

  -- hover tint to accent
  local hl = btn:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.30)

  -- text color
  local fs = has(btn, "GetFontString") and btn:GetFontString()
  if fs then fs:SetTextColor(C.text[1], C.text[2], C.text[3]) end

  -- pressed feedback (guarded scripts; preserve any existing handler by chaining)
  if has(btn, "HookScript") then
    pcall(btn.HookScript, btn, "OnMouseDown", ns.wrap(function() bg:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.45) end))
    pcall(btn.HookScript, btn, "OnMouseUp", ns.wrap(function() bg:SetColorTexture(C.panelLight[1], C.panelLight[2], C.panelLight[3], 1) end))
    pcall(btn.HookScript, btn, "OnDisable", ns.wrap(function()
      bg:SetColorTexture(C.panelLight[1] * 0.6, C.panelLight[2] * 0.6, C.panelLight[3] * 0.6, 1)
      if fs then fs:SetTextColor(C.subtle[1] * 0.7, C.subtle[2] * 0.7, C.subtle[3] * 0.7) end
    end))
    pcall(btn.HookScript, btn, "OnEnable", ns.wrap(function()
      bg:SetColorTexture(C.panelLight[1], C.panelLight[2], C.panelLight[3], 1)
      if fs then fs:SetTextColor(C.text[1], C.text[2], C.text[3]) end
    end))
  end
  if has(btn, "IsEnabled") and not btn:IsEnabled() then
    bg:SetColorTexture(C.panelLight[1] * 0.6, C.panelLight[2] * 0.6, C.panelLight[3] * 0.6, 1)
    if fs then fs:SetTextColor(C.subtle[1] * 0.7, C.subtle[2] * 0.7, C.subtle[3] * 0.7) end
  end

  btn._cpSkinned = true
end

-- ── editbox ──────────────────────────────────────────────────────────────────
-- InputBoxTemplate draws metal end-cap textures via named regions
-- (<name>Left/Right/Middle). Hide them and lay a flat dark bg + 1px border.
function Style.EditBox(eb)
  if not eb or eb._cpSkinned then return end
  if has(eb, "GetObjectType") and eb:GetObjectType() ~= "EditBox" then return end

  local name = has(eb, "GetName") and eb:GetName()
  if name then
    for _, suffix in ipairs({ "Left", "Right", "Middle", "Mid" }) do
      local r = _G[name .. suffix]
      if r and r.Hide then r:Hide() end
    end
  end
  -- some templates store the textures as keys instead of globals
  for _, key in ipairs({ "Left", "Right", "Middle" }) do
    local r = eb[key]
    if r and type(r) == "table" and r.Hide then pcall(r.Hide, r) end
  end

  local bg = eb:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", -2, 1)
  bg:SetPoint("BOTTOMRIGHT", 2, -1)
  bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.95)

  local function edge(p1, p2)
    local t = eb:CreateTexture(nil, "BORDER")
    t:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    t:SetPoint(p1, bg, p1); t:SetPoint(p2, bg, p2)
    return t
  end
  local top = edge("TOPLEFT", "TOPRIGHT");      top:SetHeight(1)
  local bot = edge("BOTTOMLEFT", "BOTTOMRIGHT"); bot:SetHeight(1)
  local lft = edge("TOPLEFT", "BOTTOMLEFT");     lft:SetWidth(1)
  local rgt = edge("TOPRIGHT", "BOTTOMRIGHT");    rgt:SetWidth(1)

  if has(eb, "SetTextColor") then eb:SetTextColor(C.text[1], C.text[2], C.text[3]) end
  eb._cpSkinned = true
end

-- ── checkbox ─────────────────────────────────────────────────────────────────
-- Darken the stock check button: flat dark box, brand-accent check mark.
function Style.CheckBox(cb)
  if not cb or cb._cpSkinned then return end
  if has(cb, "GetObjectType") and cb:GetObjectType() ~= "CheckButton" then return end

  -- The empty box: replace the bevel normal texture with a flat dark swatch.
  local nt = has(cb, "GetNormalTexture") and cb:GetNormalTexture()
  if nt then
    nt:SetColorTexture(C.panelLight[1], C.panelLight[2], C.panelLight[3], 1)
    if has(nt, "SetTexCoord") then nt:SetTexCoord(0, 1, 0, 1) end
  end
  -- 1px border around the box
  local function edge(p1, p2)
    local t = cb:CreateTexture(nil, "OVERLAY")
    t:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    t:SetPoint(p1); t:SetPoint(p2)
    return t
  end
  edge("TOPLEFT", "TOPRIGHT"):SetHeight(1)
  edge("BOTTOMLEFT", "BOTTOMRIGHT"):SetHeight(1)
  edge("TOPLEFT", "BOTTOMLEFT"):SetWidth(1)
  edge("TOPRIGHT", "BOTTOMRIGHT"):SetWidth(1)

  -- tint the check mark to accent
  local ck = has(cb, "GetCheckedTexture") and cb:GetCheckedTexture()
  if ck and has(ck, "SetVertexColor") then
    ck:SetVertexColor(C.accent[1], C.accent[2], C.accent[3])
  end
  -- subtle hover
  local hl = has(cb, "GetHighlightTexture") and cb:GetHighlightTexture()
  if hl and has(hl, "SetColorTexture") then
    hl:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 0.20)
  end
  cb._cpSkinned = true
end

-- ── slider ───────────────────────────────────────────────────────────────────
-- Flat dark track + accent thumb for OptionsSliderTemplate (and our HBar).
function Style.Slider(sl)
  if not sl or sl._cpSkinned then return end
  if has(sl, "GetObjectType") and sl:GetObjectType() ~= "Slider" then return end

  -- track backdrop (sliders are BackdropTemplate-capable on retail)
  if ensureBackdrop(sl) then
    pcall(sl.SetBackdrop, sl, {
      bgFile = WHITE, edgeFile = WHITE, edgeSize = 1,
      insets = { left = 1, right = 1, top = 1, bottom = 1 },
    })
    if has(sl, "SetBackdropColor") then sl:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], 0.9) end
    if has(sl, "SetBackdropBorderColor") then sl:SetBackdropBorderColor(C.border[1], C.border[2], C.border[3], 1) end
  end

  -- thumb → accent swatch
  local thumb = has(sl, "GetThumbTexture") and sl:GetThumbTexture()
  if thumb then
    if has(thumb, "SetColorTexture") then thumb:SetColorTexture(C.accent[1], C.accent[2], C.accent[3], 1) end
    if has(thumb, "SetSize") then thumb:SetSize(10, 16) end
  end
  sl._cpSkinned = true
end

-- ── scroll bar ───────────────────────────────────────────────────────────────
-- UIPanelScrollFrameTemplate ships <name>ScrollBar with up/down buttons + thumb.
-- Flatten the thumb and dim the arrow buttons (kept functional).
function Style.ScrollBar(sf)
  if not sf then return end
  local name = has(sf, "GetName") and sf:GetName()
  local sb = (name and _G[name .. "ScrollBar"]) or sf.ScrollBar or sf._scrollbar
  if not sb or sb._cpSkinned then return end

  local thumb = has(sb, "GetThumbTexture") and sb:GetThumbTexture()
  if thumb and has(thumb, "SetColorTexture") then
    thumb:SetColorTexture(C.panelLight[1] + 0.06, C.panelLight[2] + 0.06, C.panelLight[3] + 0.06, 1)
    if has(thumb, "SetSize") then thumb:SetSize(thumb:GetWidth() or 12, 24) end
  end
  -- dim the up/down arrow textures if present (named regions)
  if name then
    for _, suffix in ipairs({ "ScrollBarScrollUpButton", "ScrollBarScrollDownButton" }) do
      local b = _G[name .. suffix]
      if b and has(b, "GetNormalTexture") and b:GetNormalTexture() then
        b:GetNormalTexture():SetVertexColor(0.7, 0.72, 0.78)
      end
    end
  end
  sb._cpSkinned = true
end

-- ── dropdown (UIDropDownMenu) ─────────────────────────────────────────────────
-- The template uses <name>Left/Middle/Right gold border textures + a Button.
-- Hide the gold art, lay a flat dark bg + 1px border, accent the arrow button.
function Style.Dropdown(dd)
  if not dd or dd._cpSkinned then return end
  local name = has(dd, "GetName") and dd:GetName()
  if not name then return end

  for _, suffix in ipairs({ "Left", "Middle", "Right" }) do
    local r = _G[name .. suffix]
    if r and r.SetTexture then pcall(r.SetTexture, r, nil) end
  end

  -- a flat dark bg inset within the template's frame (the visible field area)
  local bg = dd:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", 18, -6)
  bg:SetPoint("BOTTOMRIGHT", -18, 8)
  bg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.95)

  local function edge(p1, p2)
    local t = dd:CreateTexture(nil, "BORDER")
    t:SetColorTexture(C.border[1], C.border[2], C.border[3], 1)
    t:SetPoint(p1, bg, p1); t:SetPoint(p2, bg, p2)
    return t
  end
  edge("TOPLEFT", "TOPRIGHT"):SetHeight(1)
  edge("BOTTOMLEFT", "BOTTOMRIGHT"):SetHeight(1)
  edge("TOPLEFT", "BOTTOMLEFT"):SetWidth(1)
  edge("TOPRIGHT", "BOTTOMRIGHT"):SetWidth(1)

  -- text + arrow button
  local fs = _G[name .. "Text"]
  if fs and has(fs, "SetTextColor") then fs:SetTextColor(C.text[1], C.text[2], C.text[3]) end
  local btn = _G[name .. "Button"]
  if btn and has(btn, "GetNormalTexture") and btn:GetNormalTexture() then
    btn:GetNormalTexture():SetVertexColor(C.accent[1], C.accent[2], C.accent[3])
    -- align the arrow to the flat bg's right edge + center it vertically. The
    -- stock template anchors the arrow ~16px off the frame's right; our bg ends
    -- at -18, so nudge the arrow to sit just inside the box. Guarded.
    if has(btn, "ClearAllPoints") and has(btn, "SetPoint") then
      pcall(function()
        btn:ClearAllPoints()
        btn:SetPoint("RIGHT", bg, "RIGHT", 2, 0)
      end)
    end
    if has(btn, "SetSize") then pcall(btn.SetSize, btn, 20, 20) end
  end
  dd._cpSkinned = true
end

-- ── recursive auto-skin ──────────────────────────────────────────────────────
-- Detect a UIDropDownMenu frame: it owns a child Button named <name>Button and a
-- <name>Text fontstring (created by UIDropDownMenuTemplate).
local function isDropdown(frame)
  if not has(frame, "GetName") then return false end
  local name = frame:GetName()
  if not name then return false end
  if not (has(frame, "GetObjectType") and frame:GetObjectType() == "Frame") then return false end
  return _G[name .. "Button"] ~= nil and _G[name .. "Middle"] ~= nil
end

-- Walk a frame's children once and skin each by type. Call after a page is built.
-- Guards: skip already-skinned, skip frames without our markers, never recurse
-- into library frames (we only ever pass our own hosts/popups).
function Style.Apply(root)
  if not root or not has(root, "GetChildren") then return end
  local visited = {}

  local function skinOne(f)
    if not f or visited[f] then return end
    visited[f] = true
    local ot = has(f, "GetObjectType") and f:GetObjectType()

    if isDropdown(f) then
      Style.Dropdown(f)
      return -- don't descend into the dropdown's internal button
    elseif ot == "Button" then
      Style.Button(f)
    elseif ot == "EditBox" then
      Style.EditBox(f)
    elseif ot == "CheckButton" then
      Style.CheckBox(f)
    elseif ot == "Slider" then
      Style.Slider(f)
    elseif ot == "ScrollFrame" then
      Style.ScrollBar(f)
    end

    if has(f, "GetChildren") then
      local kids = { f:GetChildren() }
      for _, c in ipairs(kids) do skinOne(c) end
    end
  end

  local kids = { root:GetChildren() }
  for _, c in ipairs(kids) do skinOne(c) end
end

return Style
