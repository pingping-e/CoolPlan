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

Core:SetScript("OnEvent", function(_, event, ...)
  if event == "ADDON_LOADED" then
    local name = ...
    if name == addonName then
      ns.DB.Init()
    end
  elseif event == "PLAYER_LOGIN" then
    ns.Reminders.Init()
    out("loaded. /coolplan for options, /coolplan edit to import a plan.")
  elseif event == "ENCOUNTER_START" then
    local encounterID = ...
    if ns.Scheduler.Start(encounterID) then
      out("reminders armed (encounter " .. tostring(encounterID) .. ").")
    end
  elseif event == "ENCOUNTER_END" then
    ns.Scheduler.Stop()
  elseif event == "PLAYER_REGEN_ENABLED" then
    -- safety net: combat ended without an ENCOUNTER_END (wipe / left instance)
    if ns.Scheduler.IsActive() then ns.Scheduler.Stop() end
  end
end)

-- ── Slash commands ──────────────────────────────────────────────────────────
SLASH_COOLPLAN1 = "/coolplan"
SLASH_COOLPLAN2 = "/cp"
SlashCmdList["COOLPLAN"] = function(msg)
  msg = (msg or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local cmd, rest = msg:match("^(%S*)%s*(.*)$")
  cmd = (cmd or ""):lower()

  if cmd == "" or cmd == "options" or cmd == "config" then
    ns.Options.Open()
  elseif cmd == "edit" or cmd == "import" or cmd == "export" then
    ns.Editor.Open()
  elseif cmd == "plans" or cmd == "manager" or cmd == "saved" then
    ns.Manager.Open()
  elseif cmd == "test" then
    ns.Reminders.Test()
  elseif cmd == "demo" then
    if not ns.Scheduler.StartDemo() then out("demo failed.") end
  elseif cmd == "move" then
    ns.Reminders.ToggleMover()
  elseif cmd == "lock" then
    ns.Reminders.SetLocked(true)
    out("frames locked.")
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
  elseif cmd == "list" then
    local n = 0
    for id, e in pairs(ns.DB.Library()) do
      n = n + 1
      out(("  [%d] %s — %d plan(s)%s"):format(
        id, e.name or "?", #e.plans, (e.boss and #e.boss > 0) and (", boss x" .. #e.boss) or ""))
      for i, p in ipairs(e.plans) do
        out(("       %s %s (%d cd)"):format(i == e.active and "|cff66ff66>|r" or " ", p.label, #p.reminders))
      end
    end
    if n == 0 then out("no plans imported yet. /coolplan edit to paste one.") end
  else
    out("commands: options | edit | plans | list | test | demo | move | lock | testenc <id> | stop")
  end
end
