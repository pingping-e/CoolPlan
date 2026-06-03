-- Minimap button via LibDataBroker-1.1 + LibDBIcon-1.0 (the de-facto standard),
-- so collectors like MinimapButtonButton / Titan / ElvUI gather it cleanly
-- instead of leaving it floating uncollected. Icon = the brand gantt-bar logo
-- (a TGA, since LibDBIcon takes a single icon texture).

local _, ns = ...
local Minimap_ = {}
ns.Minimap = Minimap_

local LDB = LibStub and LibStub("LibDataBroker-1.1", true)
local LDBIcon = LibStub and LibStub("LibDBIcon-1.0", true)

local dataObject = LDB and LDB:NewDataObject("CoolPlan", {
  type = "launcher",
  label = "CoolPlan",
  icon = "Interface\\AddOns\\CoolPlan\\media\\logo.tga",
  OnClick = ns.wrap(function(_, button)
    if button == "RightButton" then
      ns.Window.Open("options")
    else
      ns.Window.Toggle()
    end
  end),
  OnTooltipShow = function(tt)
    if not tt then return end
    tt:AddLine("|cff66b3ffCoolPlan|r")
    tt:AddLine("Left-click: open", 0.8, 0.8, 0.8)
    tt:AddLine("Right-click: options", 0.8, 0.8, 0.8)
  end,
})

function Minimap_.Init()
  if not (LDBIcon and dataObject) then return end
  local o = ns.DB and ns.DB.Options and ns.DB.Options()
  local db = (o and o.minimap) or {}
  if not LDBIcon:IsRegistered("CoolPlan") then
    LDBIcon:Register("CoolPlan", dataObject, db)
  end
  if db.hide then LDBIcon:Hide("CoolPlan") else LDBIcon:Show("CoolPlan") end
end

-- Toggle the button's visibility (slash: /coolplan minimap).
function Minimap_.Toggle()
  if not (LDBIcon and LDBIcon:IsRegistered("CoolPlan")) then
    ns.Print("minimap button unavailable (LibDBIcon not loaded).")
    return
  end
  local o = ns.DB.Options()
  o.minimap.hide = not o.minimap.hide
  if o.minimap.hide then LDBIcon:Hide("CoolPlan") else LDBIcon:Show("CoolPlan") end
  ns.Print("minimap button " .. (o.minimap.hide and "hidden" or "shown") .. ".")
end
