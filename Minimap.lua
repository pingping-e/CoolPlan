-- Minimap button (dependency-free; no LibDBIcon). The icon is our brand mark:
-- three horizontal gantt bars (blue / green / orange) matching the site logo.
-- Drag to reposition around the minimap edge (angle saved). Left-click opens
-- the window, right-click opens Options. /coolplan minimap toggles visibility.

local _, ns = ...
local Minimap_ = {}
ns.Minimap = Minimap_

local RADIUS = 80              -- distance from minimap center to the button
local button

-- brand colors (same as the site logo / favicon gantt bars)
local BARS = {
  { 0.23, 0.51, 0.96 },  -- blue
  { 0.06, 0.73, 0.51 },  -- green
  { 0.96, 0.62, 0.07 },  -- orange
}

local function opt()
  local o = ns.DB and ns.DB.Options and ns.DB.Options()
  if not o then return nil end
  o.minimap = o.minimap or { angle = 210, hide = false }
  return o.minimap
end

-- Position the button on the minimap edge from a saved angle (degrees).
local function reposition()
  if not button then return end
  local m = opt()
  local angle = math.rad((m and m.angle) or 210)
  local x = math.cos(angle) * RADIUS
  local y = math.sin(angle) * RADIUS
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function buildIcon(btn)
  -- circular backdrop ring
  local ring = btn:CreateTexture(nil, "BACKGROUND")
  ring:SetSize(31, 31)
  ring:SetPoint("CENTER", 0, 0)
  ring:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  -- a dark disc behind the bars so they read on any minimap
  local disc = btn:CreateTexture(nil, "BORDER")
  disc:SetSize(20, 20)
  disc:SetPoint("CENTER", 0, 1)
  disc:SetColorTexture(0.05, 0.05, 0.08, 0.9)

  -- three stacked gantt bars (offset widths to look like a timeline)
  local widths = { 14, 10, 12 }
  local yoff = { 4, 0, -4 }
  for i, col in ipairs(BARS) do
    local bar = btn:CreateTexture(nil, "ARTWORK")
    bar:SetSize(widths[i], 3)
    bar:SetPoint("LEFT", btn, "CENTER", -7, yoff[i])
    bar:SetColorTexture(col[1], col[2], col[3], 1)
  end
end

local function makeDraggable(btn)
  btn:RegisterForDrag("LeftButton")
  btn:SetScript("OnDragStart", function(self)
    self.dragging = true
    self:SetScript("OnUpdate", ns.wrap(function()
      local mx, my = Minimap:GetCenter()
      local px, py = GetCursorPosition()
      local scale = Minimap:GetEffectiveScale()
      px, py = px / scale, py / scale
      local angle = math.deg(math.atan2(py - my, px - mx))
      local m = opt(); if m then m.angle = angle end
      reposition()
    end))
  end)
  btn:SetScript("OnDragStop", function(self)
    self.dragging = false
    self:SetScript("OnUpdate", nil)
  end)
end

local function buildButton()
  local btn = CreateFrame("Button", "CoolPlanMinimapButton", Minimap)
  btn:SetSize(31, 31)
  btn:SetFrameStrata("MEDIUM")
  btn:SetFrameLevel(8)
  btn:EnableMouse(true)
  btn:SetMovable(true)
  btn:RegisterForClicks("LeftButtonUp", "RightButtonUp")

  buildIcon(btn)
  makeDraggable(btn)

  btn:SetScript("OnClick", ns.wrap(function(_, mouseButton)
    if mouseButton == "RightButton" then
      ns.Window.Open("options")
    else
      ns.Window.Toggle()
    end
  end))

  btn:SetScript("OnEnter", ns.wrap(function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine("|cff66b3ffCoolPlan|r")
    GameTooltip:AddLine("Left-click: open", 0.9, 0.9, 0.9)
    GameTooltip:AddLine("Right-click: options", 0.9, 0.9, 0.9)
    GameTooltip:AddLine("Drag: move around minimap", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end))
  btn:SetScript("OnLeave", function() GameTooltip:Hide() end)

  return btn
end

function Minimap_.Init()
  if button then return end
  if not Minimap then return end          -- no minimap (rare) → skip silently
  button = buildButton()
  reposition()
  local m = opt()
  if m and m.hide then button:Hide() end
end

function Minimap_.Toggle()
  if not button then Minimap_.Init() end
  if not button then return end
  local m = opt()
  if button:IsShown() then
    button:Hide()
    if m then m.hide = true end
    ns.Print("minimap button hidden (/coolplan minimap to show).")
  else
    button:Show()
    if m then m.hide = false end
    ns.Print("minimap button shown.")
  end
end
