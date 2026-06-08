-- CoolPlan core: lifecycle, encounter events, slash commands.

local addonName, ns = ...

local function out(msg)
  print("|cff66b3ffCoolPlan|r: " .. msg)
end
ns.Print = out

local Core = CreateFrame("Frame")
ns.Core = Core

Core:RegisterEvent("ADDON_LOADED")
Core:RegisterEvent("PLAYER_LOGIN")
Core:RegisterEvent("ENCOUNTER_START")
Core:RegisterEvent("ENCOUNTER_END")
Core:RegisterEvent("PLAYER_REGEN_ENABLED")

Core:SetScript("OnEvent", ns.wrap(function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == addonName then
      ns.DB.Init()
      Core:UnregisterEvent("ADDON_LOADED") -- only needed for our own load
    end
  elseif event == "PLAYER_LOGIN" then
    ns.Reminders.Init()
    ns.Comm.Init()
    if ns.Minimap then ns.Minimap.Init() end
    out("loaded. /coolplan to open, /coolplan import to paste a plan.")
  elseif event == "ENCOUNTER_START" then
    local encounterID = ...
    local e = ns.DB.GetEncounter(encounterID)
    if ns.Scheduler.Start(encounterID) then
      out("reminders armed (encounter " .. tostring(encounterID) .. ").")
    elseif e then
      out("|cffffcc00encounter " .. tostring(encounterID) ..
        " started — plan found but nothing to show (no active plan, or filtered out by 'only me' / hidden categories).|r")
    else
      out("|cffffcc00encounter " .. tostring(encounterID) ..
        " started — no saved plan for THIS encounter id. Your plan is saved under a different id; that's why nothing fires.|r")
    end
  elseif event == "ENCOUNTER_END" then
    ns.Scheduler.Stop()
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- safety net: combat ended without an ENCOUNTER_END (wipe / left instance)
    if ns.Scheduler.IsActive() then ns.Scheduler.Stop() end
  end
end))

-- ── Slash commands ──────────────────────────────────────────────────────────
SLASH_COOLPLAN1 = "/coolplan"
SLASH_COOLPLAN2 = "/cp"
SlashCmdList["COOLPLAN"] = ns.wrap(function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.*)$")
  cmd = (cmd or ""):lower()

  if cmd == "" then
    ns.Window.Open()
  elseif cmd == "options" or cmd == "config" then
    ns.Window.Open("options")
  elseif cmd == "edit" or cmd == "import" or cmd == "export" then
    ns.Window.Open("import")
  elseif cmd == "export-char" or cmd == "exportchar" or cmd == "char" or cmd == "loadout" then
    if ns.LoadoutExport then
      ns.LoadoutExport.Export()
    else
      out("loadout export unavailable.")
    end
  elseif cmd == "dumptree" then
    -- DEV/PoC: dump the canonical talent node order + serialization version +
    -- per-node state, so the website can build a Blizzard import-string encoder.
    -- Dev-gated: enable with /coolplan debug first (not for normal users).
    if not ns.debug then
      out("dev-only command. run /coolplan debug first to enable.")
      return
    end
    if not (C_ClassTalents and C_Traits and C_ClassTalents.GetActiveConfigID) then
      out("talent API unavailable."); return
    end
    local configID = C_ClassTalents.GetActiveConfigID()
    local cfg = configID and C_Traits.GetConfigInfo(configID)
    local treeID = cfg and cfg.treeIDs and cfg.treeIDs[1]
    if not treeID then out("no active talent tree."); return end
    local ver = C_Traits.GetLoadoutSerializationVersion and C_Traits.GetLoadoutSerializationVersion() or "?"
    local nodes = C_Traits.GetTreeNodes(treeID) or {}
    local order, state = {}, {}
    for _, nid in ipairs(nodes) do
      order[#order + 1] = nid
      local info = C_Traits.GetNodeInfo(configID, nid)
      local ranks = (info and info.ranksPurchased) or 0
      local active = (info and info.activeRank) or 0
      local maxr = (info and info.maxRanks) or 0
      local isChoice = (info and Enum and Enum.TraitNodeType and info.type == Enum.TraitNodeType.Selection) and 1 or 0
      local eidx = 0
      if info and info.activeEntry and info.entryIDs then
        for i, eid in ipairs(info.entryIDs) do
          if eid == info.activeEntry.entryID then eidx = i; break end
        end
      end
      state[#state + 1] = ("%d.%d.%d.%d.%d.%d"):format(nid, ranks, active, maxr, isChoice, eidx)
    end
    local dump = ("COOLPLAN-TREEDUMP tree=%s ver=%s n=%d\norder=%s\nstate=%s"):format(
      tostring(treeID), tostring(ver), #order, table.concat(order, ","), table.concat(state, ";"))
    if ns.Editor and ns.Editor.SetText then ns.Editor.SetText(dump) end
    out(("dumped tree %s (ver %s, %d nodes) to the import box — Ctrl-C to copy."):format(
      tostring(treeID), tostring(ver), #order))
  elseif cmd == "plans" or cmd == "manager" or cmd == "saved" then
    ns.Window.Open("saved")
  elseif cmd == "timeline" then
    ns.Window.Open("timeline")
  elseif cmd == "minimap" then
    ns.Minimap.Toggle()
  elseif cmd == "share" then
    ns.Comm.ShareActive()
  elseif cmd == "test" then
    ns.Reminders.Test()
  elseif cmd == "demo" then
    if not ns.Scheduler.StartDemo() then out("demo failed.") end
  elseif cmd == "move" then
    ns.Reminders.ToggleMover()
  elseif cmd == "lock" then
    ns.Reminders.SetLocked(true)
    out("frames locked.")
  elseif cmd == "preview" or cmd == "testframes" then
    ns.Reminders.ToggleTest()
  elseif cmd == "reset" then
    ns.Reminders.ResetPositions()
  elseif cmd == "testenc" then
    local id = tonumber(rest)
    if id then
      if not ns.Scheduler.Start(id) then
        out("no plan (or no matching reminders) for encounter " .. id .. ".")
      end
    else
      out("usage: /coolplan testenc <encounterID>")
    end
  elseif cmd == "stop" then
    ns.Scheduler.Stop()
    out("stopped.")
  elseif cmd == "errors" then
    ns.PrintErrors()
  elseif cmd == "debug" then
    ns.debug = not ns.debug
    out("debug mode " .. (ns.debug and "ON (errors will pop up)" or "OFF (errors suppressed)") .. ".")
  elseif cmd == "list" then
    local n = 0
    for id, e in pairs(ns.DB.Library()) do
      n = n + 1
      local plans = e.plans or {}
      out(("  [%s] %s — %d plan(s)"):format(tostring(id), e.name or "?", #plans))
      for i, p in ipairs(plans) do
        out(("       %s %s (%d cd%s)"):format(
          i == e.active and "|cff66ff66>|r" or " ", p.label or "?", #(p.reminders or {}),
          (p.boss and #p.boss > 0) and (", boss x" .. #p.boss) or ""))
      end
    end
    if n == 0 then out("no plans imported yet. /coolplan edit to paste one.") end
  else
    out("commands: (blank)=open | timeline | plans | import | export-char | options | minimap | share | list | test | demo | move | lock | preview | reset | testenc <id> | stop | errors | debug")
  end
end)
