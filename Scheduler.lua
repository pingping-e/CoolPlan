-- Scheduling: on ENCOUNTER_START, build a sorted reminder queue and drive it
-- with a single per-frame ticker. Each tick computes the imminent alert (within
-- its lead window) + the upcoming queue, and renders an anticipation countdown.
--
-- Phase-gated bosses: reminders carry a phaseIndex (offset from a phase that
-- begins on a variable trigger — a boss cast, a shield removal, or an HP%). Those
-- cues are deferred until we DETECT the phase live (via BigWigs/DBM boss-mod
-- callbacks — Midnight blocks addons from reading the combat log / enemy spellIds
-- directly), then scheduled relative to the moment the phase began for THIS pull.
-- Absolute cues are unchanged.

local _, ns = ...
local Scheduler = {}
ns.Scheduler = Scheduler

local LINGER = 1.0
-- 3-2-1 countdown window. A cue whose cast lands within this many seconds of the
-- PREVIOUS cast gets no spoken countdown (the lead spell's countdown already
-- covers the window — a back-to-back cue would only stutter a clipped "2..1").
local COUNTDOWN_LEAD = 3

local driver, pullTime, queue, activeId
-- phase state (live, phase-gated bosses only):
--   pendingPhase[idx]  = { cue, ... } cues waiting for phase idx to begin
--   phaseTriggers      = { {index, kind, spellId, occurrence, pct, seen, fired}, ... }
--   hasHealthTrigger   = true if any trigger polls UnitHealth
local pendingPhase, phaseTriggers, hasHealthTrigger
-- C_EncounterTimeline sub-phase tracking (drives firePhase on BW-less bosses):
--   tlAddedAt[id]   = elapsed when that timeline event was ADDED (survival fallback)
--   durById[id]     = the event's info.duration (for dur-signature matching)
--   tlLastAdvance   = elapsed of the last advance (debounce so one signal fires once)
--   tlLastSignal    = 'entry' | 'exit' — alternation guard for 5-segment advance
--   tlCursor        = index into phaseTriggers; the next phase a TL signal fires
local tlAddedAt, tlPhaseSeen, tlLastAdvance, durById, tlLastSignal, tlCursor
-- HP / boss-count diagnostic state. logBossHealth is defined AFTER recordCapture
-- (it calls it), so forward-declare here for tick() and run() to reference.
local logBossHealth, lastHpLog, lastBossCount, recordCapture
local TL_MIN_SURVIVE = 4   -- s: a CANCELED event must have lived this long to count
                            -- as a sub-phase entry (survival FALLBACK, no dur sig)
local TL_DEBOUNCE = 8       -- s: ignore further signals within this window. Its only
                            -- job is to collapse a boundary's burst of simultaneous
                            -- events (<1s apart) into one advance — the entry/exit
                            -- alternation already prevents same-type repeats. Kept
                            -- BELOW the shortest real sub-phase (Crawth fight 2564 sub-
                            -- phase 1 was ~14s entry→exit; 15s would have eaten its
                            -- exit and mis-anchored to the next rotation cycle).
-- NSRT-style dur signatures (from /coolplan capture): a boss's MAIN rotation event
-- durations. A main-dur event CANCELED (state=3) = sub-phase ENTRY; the main-dur set
-- re-ADDED = sub-phase EXIT (= next main phase). More robust than survival+occurrence
-- (no occ-skew). Gemellus uses unitCount, L'ura is absolute → not listed here (they
-- fall back to survival / unitCount). Crawth (2564) reuses its rotation dur during the
-- sub-phase, so its ENTRY comes from PHASE_ENTRY_WARN instead (the dur sig here
-- still drives its exit). ✓ ALL FOUR VERIFIED in-game (2026-06-11/12): 3058 Kroluk &
-- 3213 Vordaza use a signature dur going state=3 for ENTRY (Vordaza's dur=70 cancels at
-- the Deathshroud entry); 2564 Crawth & 3333 Lothraxion are warning-gated (PHASE_ENTRY_
-- WARN) so their signature is EXIT-ONLY (the rotation set re-ADDED ends the sub-phase).
local PHASE_DUR_SIGNATURES = {
  [2564] = { 20, 5, 14 },                      -- Crawth (Gust/Peck/Screech)
  [3213] = { 25.333, 3, 70, 14.166, 33.5 },    -- Vordaza
  [3058] = { 1001, 999, 1004 },                -- Kroluk: long "main rotation" bars.
  -- VERIFIED 2026-06-11 (in-game capture, fight 3058): the main-phase bars are
  -- always freshly ADDED at exactly {1001, 999, 1004}; they go state=3 at each
  -- sub-phase ENTRY and re-ADD at the EXIT. The 952-998 values seen in the capture
  -- are transient "remaining-time" snapshots at the boundary — deliberately NOT
  -- listed (an exact match avoids false EXIT fires right after an entry).
  [3333] = { 2, 11, 52, 24 },                  -- Lothraxion
}
local DUR_EPSILON = 0.3     -- s: float dur match tolerance (25.333, 14.166 …)
-- Warning-gated ENTRY. Some bosses don't surface a clean sub-phase CANCEL on a signature
-- duration, but DO herald the sub-phase with an ENCOUNTER_WARNING. `sev` = minimum
-- severity; optional `dur` pins the warning's own duration when severity alone doesn't
-- disambiguate. For these bosses the warning is the SOLE entry signal — the state=3 entry
-- path is suppressed (their signature durations also CANCEL as routine/exit churn, which
-- must not count as an entry). The signature is kept for the EXIT (rotation set re-ADDED).
--   Crawth (2564): Ruinous Winds = sev 2; routine telegraphs are sev 1, so sev alone
--     suffices. VERIFIED 2026-06-11: sub-phase warnings at 50.6s / 112.6s (both subs).
--   Lothraxion (3333): Divine Guile = a sev-2 warning of dur 3.5, but ROUTINE telegraphs
--     are ALSO sev 2 (dur 3) — so the 3.5 duration is the discriminator. VERIFIED
--     2026-06-12 (two captures): dur=3.5 sev=2 precedes each sub-phase (player: ~52-53s
--     cycle, the actual mechanic begins ~9.5s later = cast 7.5s + ~2s); routine dur=3
--     sev=2 warnings are correctly excluded; exit = rotation set {2,11,52,24} re-ADDED.
local PHASE_ENTRY_WARN = {
  [2564] = { sev = 2 },              -- Crawth: severity alone (routine = sev 1)
  [3333] = { sev = 2, dur = 3.5 },   -- Lothraxion: routine warnings are also sev 2 (dur 3)
}
-- preview mode: a virtual clock advanced by `speed`x each real tick, with an
-- optional onTick(elapsed, total) callback (used by the Timeline playhead).
local preview = false
local previewClock = 0
local previewSpeed = 1
local previewTotal = 0
local previewOnTick = nil
local previewPhaseStart = nil  -- {[phaseIndex]=startMs}: synthetic phase windows (preview)
-- Preview has no live phase timing. The Timeline view passes its own per-phase start
-- offsets (opts.phaseStart) so the playhead/markers/HUD share one layout; this constant
-- is only a FALLBACK (seconds per phase) when a caller arms a preview without one.
local PREVIEW_PHASE_GAP = 30

local function nameMatchesMe(player)
  if not player or player == "" then return true end
  local me = UnitName("player")
  if not me then return true end
  return strlower(player) == strlower(me)
end

local function nowElapsed()
  if preview then return previewClock end
  if not pullTime then return 0 end
  return GetTime() - pullTime
end

-- Push a cue onto the live queue at an absolute elapsed-seconds castAt, computing
-- its on-screen (lead) and audible (soundLead) windows. Shared by the initial
-- build and dynamic phase insertion.
local function enqueue(cue, castAt)
  local o = ns.DB.Options()
  local lead = o.leadSeconds or 4
  local soundLead = o.soundLeadSeconds or 0
  queue[#queue + 1] = {
    cue = cue,
    castAt = castAt,
    showAt = math.max(0, castAt - lead),
    soundAt = math.max(0, castAt - soundLead),
    soundCued = false,
  }
end

-- Sort the queue by castAt and (re)flag cues that follow the previous cast within
-- the countdown window so they skip their spoken countdown. Recomputed whenever
-- the queue changes (initial build + each phase insertion).
local function finalizeQueue()
  table.sort(queue, function(a, b) return a.castAt < b.castAt end)
  local prevCast
  for _, item in ipairs(queue) do
    item.silentCountdown = nil
    if prevCast and (item.castAt - prevCast) < COUNTDOWN_LEAD then
      item.silentCountdown = true
    end
    prevCast = item.castAt
  end
end

-- A phase began (its trigger fired): anchor here and schedule its deferred cues
-- relative to this instant. One-shot per phase.
local function firePhase(index)
  local pend = pendingPhase and pendingPhase[index]
  if phaseTriggers then
    for _, tr in ipairs(phaseTriggers) do
      if tr.index == index then tr.fired = true end
    end
  end
  -- A new phase began: any still-pending cue scheduled for an EARLIER phase is now
  -- stale (that phase is over) and must NOT fire during this one. Drop un-cast queued
  -- cues from every earlier phase. In a phased plan, absolute (no-pN) cues ARE phase 1
  -- — `phaseIndex or 1` — so they're dropped too once we leave phase 1 (e.g. the boss
  -- hit the sub-phase early, before all of phase 1's cooldowns came up).
  if index and index > 1 and queue then
    local now = nowElapsed()
    for i = #queue, 1, -1 do
      local q = queue[i].cue
      if q and (q.phaseIndex or 1) < index and queue[i].castAt > now then
        table.remove(queue, i)
      end
    end
  end
  if ns.debug then ns.Print("|cff66ff66CoolPlan phase " .. index .. " fired @ " .. string.format("%.1f", nowElapsed()) .. "s — scheduling " .. (pend and #pend or 0) .. " cue(s)|r") end
  if not pend then return end
  pendingPhase[index] = nil
  local anchorElapsed = nowElapsed()
  for _, cue in ipairs(pend) do
    enqueue(cue, anchorElapsed + cue.timeMs / 1000)
  end
  finalizeQueue()
end

-- C_EncounterTimeline sub-phase advance (for BW-less bosses). The official timeline
-- has no usable info.phase; instead we read the entry/exit signals (a main rotation
-- event CANCELED / re-ADDED, or a high-severity warning) and walk the phase triggers
-- in order. We can't read which spellId each signal is, so the Nth signal fires the
-- Nth phase trigger (see timelineAdvancePhase's cursor).
-- Is this duration one of the active boss's MAIN rotation durations?
local function isMainDur(dur)
  local sig = activeId and PHASE_DUR_SIGNATURES[activeId]
  if not sig or type(dur) ~= "number" then return false end
  for _, d in ipairs(sig) do if math.abs(dur - d) < DUR_EPSILON then return true end end
  return false
end

-- Advance to the NEXT phase in plan order. The TL signals give the ORDER of phase
-- transitions (sub-phase entry / exit alternating); we walk phaseTriggers 2→3→4→5
-- in turn via an independent cursor — NOT "lowest unfired". That distinction matters
-- when BigWigs is also running: BW fires the entry phases (e.g. Crawth p2/p4) directly
-- via bossModSpell, marking them fired; a "lowest unfired" walk would then make the
-- NEXT TL signal skip ahead to the exit phase at the entry's time. The cursor is immune
-- — firePhase is idempotent, so BW's pre-fire of a phase the cursor also reaches is
-- harmless. Gemellus (HP-gated) is handled by unitCount, not this.
local function timelineAdvancePhase()
  if not phaseTriggers then return end
  tlCursor = (tlCursor or 0) + 1
  local tr = phaseTriggers[tlCursor]
  if tr then firePhase(tr.index) end
end

-- Sub-phase ENTRY / EXIT signals, alternated (tlLastSignal) so an entry can't fire
-- twice in a row, and debounced so a boundary's burst of simultaneous events (a whole
-- rotation set canceled / re-added at once) advances the phase only once.
local function tlEntry(now)
  local ok = tlLastSignal ~= "entry" and (now - (tlLastAdvance or -999)) >= TL_DEBOUNCE
  if ns.debug then
    local msg = "id=" .. tostring(activeId) .. " sig=" .. tostring(tlLastSignal) .. " cursor=" .. tostring(tlCursor) .. " → " .. (ok and "FIRE" or "skip")
    if recordCapture then recordCapture("tl:ENTRY?", msg, "") end
    ns.Print("|cffaaaaaa[tl] ENTRY @" .. string.format("%.1f", now) .. "s " .. msg .. "|r")
  end
  if ok then
    tlLastAdvance, tlLastSignal = now, "entry"
    timelineAdvancePhase()
  end
end
local function tlExit(now)
  local ok = tlLastSignal == "entry" and (now - (tlLastAdvance or -999)) >= TL_DEBOUNCE
  if ns.debug then
    local msg = "id=" .. tostring(activeId) .. " sig=" .. tostring(tlLastSignal) .. " cursor=" .. tostring(tlCursor) .. " → " .. (ok and "FIRE" or "skip")
    if recordCapture then recordCapture("tl:EXIT?", msg, "") end
    ns.Print("|cffaaaaaa[tl] EXIT @" .. string.format("%.1f", now) .. "s " .. msg .. "|r")
  end
  if ok then
    tlLastAdvance, tlLastSignal = now, "exit"
    timelineAdvancePhase()
  end
end

-- Health-gated phases: poll boss unit frames; fire when any boss drops to/below
-- the threshold. Cheap, and only called when a health trigger is pending.
local function pollHealth()
  if not phaseTriggers then return end
  for _, tr in ipairs(phaseTriggers) do
    if (not tr.fired) and tr.kind == "health" and tr.pct then
      for u = 1, 5 do
        local unit = "boss" .. u
        if UnitExists(unit) then
          local mx = UnitHealthMax(unit)
          if mx and mx > 0 then
            local pc = UnitHealth(unit) / mx * 100
            if pc > 0 and pc <= tr.pct then
              firePhase(tr.index)
              break
            end
          end
        end
      end
    end
  end
end

-- Driven every frame (OnUpdate) so bars deplete smoothly instead of stepping at
-- a tick. `dt` is the real frame delta; preview advances its virtual clock by
-- dt*speed.
local function tick(dt)
  if not queue then return end
  if (not preview) and not pullTime then return end
  local o = ns.DB.Options()
  if preview then previewClock = previewClock + (dt or 0) * previewSpeed end
  if (not preview) and hasHealthTrigger then pollHealth() end
  if (not preview) and pullTime then logBossHealth() end
  local elapsed = nowElapsed()
  local lead = o.leadSeconds or 4

  local active = nil       -- {reminder, remaining, total}
  local upcoming = {}
  local soonest, soonestItem = nil, nil  -- nearest still-upcoming cast (for the countdown)

  for _, item in ipairs(queue) do
    -- preview: a cue is only "live" during its OWN synthetic phase window. Before its
    -- phase starts it isn't visible; once the NEXT phase starts the live addon would
    -- have dropped it (firePhase). Skip otherwise so the Test mirrors the real per-phase
    -- visibility instead of showing every phase's cues at once.
    local visible = true
    if preview and previewPhaseStart then
      local pidx = (item.cue and item.cue.phaseIndex) or 1
      local startN = (previewPhaseStart[pidx] or 0) / 1000
      local nextMs = previewPhaseStart[pidx + 1]
      if previewClock < startN or (nextMs and previewClock >= nextMs / 1000) then
        visible = false
      end
    end
    if visible then
      local remaining = item.castAt - elapsed

      -- audible cue (sound / TTS) fires once when the SOUND lead window opens —
      -- independent of the on-screen lead so audio can lead/trail the visuals.
      if (not item.soundCued) and elapsed >= item.soundAt then
        item.soundCued = true
        ns.Reminders.Cue(item.cue, o)
      end

      -- track the single nearest upcoming cast in this same pass (the countdown
      -- below speaks only that one, so it doesn't need its own queue scan).
      if remaining > 0 and ((not soonest) or remaining < soonest) then
        soonest, soonestItem = remaining, item
      end

      if elapsed >= item.showAt and elapsed <= item.castAt + LINGER then
        -- in the anticipation window: nearest cast becomes the big alert,
        -- any others fall into the queue
        if (not active) or remaining < active.remaining then
          if active then upcoming[#upcoming + 1] = { cue = active.cue, remaining = active.remaining } end
          active = { cue = item.cue, remaining = remaining, total = lead }
        else
          upcoming[#upcoming + 1] = { cue = item.cue, remaining = remaining }
        end
      elseif remaining > 0 then
        upcoming[#upcoming + 1] = { cue = item.cue, remaining = remaining }
      end
    end
  end

  -- spoken 3-2-1 countdown (TTS) over the final 3s before a cast — once per
  -- whole second. Fired for ONLY the single soonest upcoming cast so overlapping
  -- cues (a queued "next" spell landing inside the active spell's countdown
  -- window) never stack two simultaneous countdowns. Independent of the alert
  -- mode and the spell-name TTS.
  if o.countdownVoice and soonestItem and not soonestItem.silentCountdown then
    local sec = math.ceil(soonest)
    if sec <= 3 and sec ~= soonestItem.cdLast then
      soonestItem.cdLast = sec
      ns.Reminders.SpeakCountdown(sec, o)
    end
  end

  -- only preview cues casting within the lookahead window (default 10s), so the
  -- queue doesn't list things still half a minute out.
  local window = o.queueWindow or 10
  for i = #upcoming, 1, -1 do
    if upcoming[i].remaining > window then table.remove(upcoming, i) end
  end
  table.sort(upcoming, function(a, b) return a.remaining < b.remaining end)
  local cap = o.queueCount or 3
  while #upcoming > cap do table.remove(upcoming) end

  ns.Reminders.RenderTick(active, upcoming, o)

  if preview then
    if previewOnTick then ns.safecall(previewOnTick, elapsed, previewTotal) end
    -- auto-stop a short while past the last cast
    if elapsed > previewTotal + LINGER + 1 then
      Scheduler.Stop()
    end
  end
end

-- Per-frame driver (only runs OnUpdate while shown → while a schedule is active).
driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function(_, e) ns.safecall(tick, e) end)

-- ── live phase detection via boss mods (BigWigs / DBM) ───────────────────────
-- Midnight blocks addons from reading enemy spellIds / the combat log inside
-- instances (RegisterEvent on COMBAT_LOG_EVENT_UNFILTERED is forbidden, and
-- UNIT_SPELLCAST spellIds are "secret"). Boss mods have sanctioned access and
-- expose callbacks, so we consume THEM: the catalog trigger spellId is matched
-- against the spellId carried by BigWigs/DBM bar/message/timer events. The rest
-- (occurrence count → firePhase, scheduling) is unchanged. Needs BigWigs
-- (+LittleWigs for M+) or DBM; without either, phase-gated bosses stay absolute.
local BOSSMOD_DEBOUNCE = 3 -- seconds: collapse the several bar/message/timer
-- events a boss mod fires for ONE ability instance into a single occurrence.

-- Capture buffer: every boss-mod event seen during the current armed encounter,
-- with its elapsed time — so the trigger spellId can be read exactly (WoW chat
-- isn't copyable). `/coolplan capture` dumps it to a copyable editbox. Reset per
-- pull in run().
local capture = {}
local lastTimelinePhase -- last Encounter-Timeline info.phase seen (diagnostic)
function recordCapture(label, v, name)
  if #capture >= 400 then return end
  capture[#capture + 1] = { t = nowElapsed(), label = label, v = v, name = name or "?" }
end

-- HP / boss-count diagnostic (assigns the forward-declared upvalue above). Logs
-- boss1-5 health (+ whether it's secret) every ~2s, and the boss UNIT COUNT the
-- instant it changes. Midnight 12.0.5 may mark HP secret/forbidden in instances
-- (project_midnight_addon_restrictions); the count (1→3→5 on Gemellus) uses only
-- UnitExists (a basic API) so it may be a more robust split signal than HP or TL.
function logBossHealth()
  -- Boss UNIT COUNT change (no throttle — catches the split instant). Gemellus:
  -- 1 → 3 (occ1) → 5 (occ2 / 50%); boss5 appearing == the 50% split.
  local count = 0
  for u = 1, 5 do if UnitExists("boss" .. u) then count = count + 1 end end
  if count ~= lastBossCount then
    lastBossCount = count
    recordCapture("BOSSCOUNT", tostring(count), "(boss unit count)")
    -- Fire any unitCount-gated phase whose threshold the count just reached
    -- (Gemellus 50% split = 5 units). UnitExists is readable in Midnight instances
    -- (HP/spellID are secret), so this is the robust path where HP and TL-occurrence
    -- both fail. firePhase is idempotent, so re-reaching the count is harmless.
    if phaseTriggers then
      for _, tr in ipairs(phaseTriggers) do
        if (not tr.fired) and tr.unitCount and count >= tr.unitCount then
          firePhase(tr.index)
        end
      end
    end
  end
  local now = nowElapsed()
  if lastHpLog and (now - lastHpLog) < 2 then return end
  lastHpLog = now
  for u = 1, 5 do
    local unit = "boss" .. u
    if UnitExists(unit) then
      local hp = UnitHealth(unit)
      local mx = UnitHealthMax(unit)
      local val
      if issecretvalue and (issecretvalue(hp) or issecretvalue(mx)) then
        val = "<secret>"
      elseif type(hp) == "number" and type(mx) == "number" and mx > 0 then
        val = string.format("%.0f%% (%d/%d)", hp / mx * 100, hp, mx)
      else
        val = "hp=" .. tostring(hp) .. " max=" .. tostring(mx)
      end
      recordCapture("HP:boss" .. u, val, "(health probe)")
    end
  end
end

-- Feed a spellId (from a boss-mod callback) into phase detection. `fire` acts on
-- it (an at-the-moment signal); otherwise it's logged only (diagnostics).
-- Secret / non-number keys (some BigWigs bars, or 12.0 secret values) are
-- skipped for matching — they can't be compared to a catalog spellId.
local function bossModSpell(spellID, label, fire)
  if not phaseTriggers then return end
  if type(spellID) ~= "number" then
    recordCapture(label, "key:" .. type(spellID), "(non-number)")
    if ns.debug then ns.Print("|cff888888[bossmod " .. label .. "] non-number key (" .. type(spellID) .. ")|r") end
    return
  end
  local nm = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)) or "?"
  recordCapture(label, spellID, nm)
  if ns.debug then
    local match = ""
    for _, tr in ipairs(phaseTriggers) do
      if tr.spellId == spellID then match = " |cff66ff66<<< matches p" .. tr.index .. (fire and "" or " (log only)") .. "|r" end
    end
    ns.Print("|cffffcc44[bossmod " .. label .. "] " .. spellID .. " (" .. nm .. ")|r" .. match)
  end
  if not fire then return end
  local now = GetTime()
  for _, tr in ipairs(phaseTriggers) do
    if (not tr.fired) and tr.spellId == spellID then
      if not (tr.lastSeen and (now - tr.lastSeen) < BOSSMOD_DEBOUNCE) then
        tr.lastSeen = now
        tr.seen = tr.seen + 1
        if tr.seen >= (tr.occurrence or 1) then firePhase(tr.index) end
      end
    end
  end
end

-- ── Encounter Timeline (official C_EncounterTimeline API) ─────────────────────
-- Midnight's SANCTIONED encounter-event feed — the same one NSRT uses (NOT
-- BigWigs/DBM). Events ENCOUNTER_TIMELINE_EVENT_ADDED/REMOVED/STATE_CHANGED +
-- ENCOUNTER_WARNING carry an `info` table (id, phase, duration, time, text, …).
-- CONFIRMED to fire in M+ dungeons (user test 2026-06-10). For now this only
-- DIAGNOSES: it logs every field (secret-guarded) into the capture buffer so one
-- pull reveals whether info.phase tracks our sub-phases — then we can drive
-- firePhase from it (cleaner than the BigWigs bridge: official, no BigWigs
-- dependency, no per-boss spellId curation). Fields may be `secret` inside
-- instances, so guard EVERY access.
local function safeVal(v)
  if v == nil then return "nil" end
  if issecretvalue and issecretvalue(v) then return "<secret>" end
  return tostring(v)
end

local function onTimelineEvent(e, a1)
  local line
  if e == "ENCOUNTER_TIMELINE_EVENT_ADDED" then
    local info = a1
    local phase = info and info.phase
    line = "id=" .. safeVal(info and info.id)
      .. " phase=" .. safeVal(phase)
      .. " dur=" .. safeVal(info and info.duration)
      .. " text=" .. safeVal(info and info.text)
    -- Track phase changes when `phase` is a real (non-secret) number — the signal
    -- we hope to drive firePhase from once the info.phase→our-index mapping is known.
    if type(phase) == "number" and not (issecretvalue and issecretvalue(phase)) then
      if phase ~= lastTimelinePhase then
        lastTimelinePhase = phase
        recordCapture("TL:PHASE", "phase:" .. phase, "(phase change)")
        if ns.debug then ns.Print("|cff00ff00[timeline] PHASE → " .. phase .. "|r") end
      end
    end
    -- Record the ADDED time (survival fallback) and the duration (dur signature).
    if phaseTriggers and type(info and info.id) == "number" then
      tlAddedAt = tlAddedAt or {}
      tlAddedAt[info.id] = nowElapsed()
      if type(info.duration) == "number" then
        durById = durById or {}
        durById[info.id] = info.duration
      end
    end
    -- dur-signature EXIT: the MAIN rotation set re-ADDED after a sub-phase means the
    -- sub-phase ended → next MAIN phase. tlExit only fires while the previous signal
    -- was an entry, so the pull's initial main-set ADDED (and every normal rotation
    -- cycle after an exit) is ignored.
    if phaseTriggers and isMainDur(info and info.duration) then
      tlExit(nowElapsed())
    end
  elseif e == "ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED" then
    local id = a1
    local st = C_EncounterTimeline and C_EncounterTimeline.GetEventState and C_EncounterTimeline.GetEventState(id)
    line = "id=" .. safeVal(id) .. " state=" .. safeVal(st)
    -- state 3 = Canceled. A MAIN rotation event canceled = sub-phase ENTRY. With a
    -- dur signature we match the canceled event's duration; without one we fall back
    -- to survival (lived >= TL_MIN_SURVIVE). Debounced + alternated with exits so a
    -- sub-phase's many simultaneous cancels advance the phase only once. SUPPRESSED for
    -- warning-gated bosses (PHASE_ENTRY_WARN): their signature durations also cancel as
    -- routine/exit churn, so a state=3 here would mis-fire — their entry is the warning.
    if st == 3 and phaseTriggers and not (activeId and PHASE_ENTRY_WARN[activeId]) then
      local now = nowElapsed()
      local sig = activeId and PHASE_DUR_SIGNATURES[activeId]
      local isEntry
      if sig then
        isEntry = isMainDur(durById and durById[id])
      else
        local at = tlAddedAt and tlAddedAt[id]
        isEntry = at ~= nil and (now - at) >= TL_MIN_SURVIVE
      end
      if isEntry then tlEntry(now) end
    end
  elseif e == "ENCOUNTER_TIMELINE_EVENT_REMOVED" then
    line = "id=" .. safeVal(a1)
    if tlAddedAt and type(a1) == "number" then tlAddedAt[a1] = nil end
    if durById and type(a1) == "number" then durById[a1] = nil end
  elseif e == "ENCOUNTER_WARNING" then
    local info = a1
    local sev = info and info.severity
    local wdur = info and info.duration
    line = "dur=" .. safeVal(wdur) .. " sev=" .. safeVal(sev)
    -- warning-gated ENTRY: the sub-phase telegraph. Match severity, and (when the boss
    -- needs it) the warning's own duration to tell the sub-phase cast apart from routine
    -- telegraphs of the same severity (Crawth = sev only; Lothraxion = sev 2 + dur 3.5).
    local cfg = activeId and PHASE_ENTRY_WARN[activeId]
    if phaseTriggers and cfg and type(sev) == "number"
       and not (issecretvalue and issecretvalue(sev)) and sev >= cfg.sev then
      local durOk = true
      if cfg.dur then
        durOk = type(wdur) == "number" and not (issecretvalue and issecretvalue(wdur))
                and math.abs(wdur - cfg.dur) < DUR_EPSILON
      end
      if durOk then tlEntry(nowElapsed()) end
    end
  else
    line = safeVal(a1)
  end
  local short = e:gsub("ENCOUNTER_TIMELINE_EVENT_", ""):gsub("ENCOUNTER_", "")
  recordCapture("TL:" .. short, line, "")
  if ns.debug then ns.Print("|cff66ccff[timeline " .. short .. "] " .. line .. "|r") end
end

-- Registered once on PLAYER_LOGIN, after BigWigs/DBM have loaded (see Core.lua).
function Scheduler.InitBossMods()
  local sources = {}
  local BW = _G.BigWigsLoader
  if BW and BW.RegisterMessage then
    local proxy = {} -- any table works as the CallbackHandler registrant
    -- key (3rd arg) is the spellId for spell bars/messages. We act on the
    -- at-event Message AND StartBar: for the HP/objective-gated abilities we gate
    -- on, BigWigs draws the cast bar AT the cast, so timing matches; the debounce
    -- collapses the Message+Bar pair into one occurrence.
    BW.RegisterMessage(proxy, "BigWigs_Message",  function(_, _, key) bossModSpell(key, "BW:Msg", true) end)
    BW.RegisterMessage(proxy, "BigWigs_StartBar", function(_, _, key) bossModSpell(key, "BW:Bar", true) end)
    BW.RegisterMessage(proxy, "BigWigs_SetStage", function(_, _, stage)
      if phaseTriggers then recordCapture("BW:SetStage", "stage:" .. tostring(stage), "(stage)") end
      if ns.debug then ns.Print("|cffffcc44[bossmod BW:SetStage] " .. tostring(stage) .. "|r") end
    end)
    sources[#sources + 1] = "BigWigs"
  end
  local DBM = _G.DBM
  if DBM and DBM.RegisterCallback then
    DBM:RegisterCallback("DBM_Announce",   function(_, _, _, _, spellId) bossModSpell(spellId, "DBM:Ann", true) end)
    DBM:RegisterCallback("DBM_TimerStart", function(_, _, _, _, _, _, spellId) bossModSpell(spellId, "DBM:Timer", false) end)
    sources[#sources + 1] = "DBM"
  end
  -- Official Encounter Timeline feed (sanctioned in Midnight instances incl. M+).
  -- Always on (diagnostic) when the client exposes it; independent of BigWigs/DBM.
  if C_EncounterTimeline then
    local tf = CreateFrame("Frame")
    for _, ev in ipairs({
      "ENCOUNTER_TIMELINE_EVENT_ADDED",
      "ENCOUNTER_TIMELINE_EVENT_REMOVED",
      "ENCOUNTER_TIMELINE_EVENT_STATE_CHANGED",
      "ENCOUNTER_WARNING",
    }) do
      pcall(tf.RegisterEvent, tf, ev) -- pcall: older clients may not have the event
    end
    tf:SetScript("OnEvent", function(_, e, a1) onTimelineEvent(e, a1) end)
    sources[#sources + 1] = "EncounterTimeline"
  end
  ns.bossModSources = sources
  if ns.debug then
    ns.Print("|cff88ccffCoolPlan boss-mod bridge: " .. (#sources > 0 and table.concat(sources, "+") or "NONE — install BigWigs+LittleWigs or DBM for live phases") .. "|r")
  end
end

-- Build a copyable dump of the capture buffer (every boss-mod event this pull,
-- with elapsed time) — WoW chat isn't copyable, so /coolplan capture shows this
-- in the editor box. Used to curate each phase boss's live trigger spellId.
function Scheduler.GetCaptureText()
  if #capture == 0 then
    return "COOLPLAN CAPTURE: nothing recorded.\nArm a plan (or /coolplan testenc <id>) then pull a boss — captures BigWigs (BW:*) AND official Encounter Timeline (TL:*) events. Then /coolplan capture."
  end
  local lines = {
    "COOLPLAN CAPTURE  (elapsed | source | value | name)",
    "  BW:* = BigWigs/DBM callbacks (id = spellId).  TL:* = official C_EncounterTimeline.",
    "  Look for: TL:PHASE lines (does info.phase track the sub-phases?), and which",
    "  TL:ADDED / BW line lines up with each sub-phase entry/exit.",
  }
  for _, c in ipairs(capture) do
    lines[#lines + 1] = string.format("%6.1fs | %-11s | %s | %s", c.t, c.label, tostring(c.v), c.name)
  end
  return table.concat(lines, "\n")
end

-- Run an arbitrary cue list (already filtered). Returns true if armed.
-- opts (optional): { preview=true, speed=1, onTick=fn } for the live preview,
-- and { phases = {...} } (live only) to enable phase re-anchoring.
local function run(cues, opts)
  -- Callers set `activeId` just before calling run(); Stop() clears it, so save and
  -- restore it across the cleanup. Without this, activeId is nil for the whole pull and
  -- every per-encounter table lookup (PHASE_DUR_SIGNATURES / PHASE_ENTRY_WARN) misses.
  local keepActiveId = activeId
  Scheduler.Stop()
  activeId = keepActiveId
  local previewMode = opts and opts.preview
  -- Capture-only arm: a phase boss with no saved plan still sets pullTime so
  -- /coolplan capture timestamps are real (for trigger curation). No reminders.
  local captureOnly = opts and opts.captureOnly

  wipe(capture) -- fresh capture buffer per pull (for /coolplan capture)
  lastTimelinePhase = nil
  tlAddedAt = {}
  durById = {}
  tlPhaseSeen = 0
  tlLastAdvance = nil
  tlLastSignal = nil
  tlCursor = nil
  lastHpLog = nil
  lastBossCount = nil
  queue = {}
  pendingPhase = nil
  phaseTriggers = nil
  hasHealthTrigger = false

  -- Build the live trigger table from the plan's phases. In preview there are no
  -- real triggers, so phase cues are flattened to absolute (anchored at the pull)
  -- just so the whole plan is visible in the Timeline test.
  local phases = opts and opts.phases
  if phases and not previewMode then
    local triggers = {}
    for _, p in ipairs(phases) do
      local t = p.trigger
      -- Register EVERY index>1 phase that carries a (recognized) trigger kind — even
      -- when it has no spellId/pct (rotation-resume / TL-only exits). Such phases have
      -- no BigWigs/CLEU match; they advance purely from the Encounter Timeline via
      -- timelineAdvancePhase, so the index SLOT must exist or 2→3→4→5 breaks.
      if p.index and p.index > 1 and t and t.kind then
        triggers[#triggers + 1] = {
          index = p.index, kind = t.kind, spellId = t.spellId,
          occurrence = t.occurrence or 1, pct = t.pct, unitCount = t.unitCount,
          seen = 0, fired = false,
        }
        if t.kind == "health" then hasHealthTrigger = true end
      end
    end
    if #triggers > 0 then phaseTriggers = triggers end
    if ns.debug and phaseTriggers then
      recordCapture("tl:ARMED", "activeId=" .. tostring(activeId)
        .. " warnEntry=" .. tostring(PHASE_ENTRY_WARN[activeId] ~= nil)
        .. " durSig=" .. tostring(PHASE_DUR_SIGNATURES[activeId] ~= nil)
        .. " triggers=" .. #phaseTriggers, "")
      local ids = {}
      for _, tr in ipairs(phaseTriggers) do
        ids[#ids + 1] = "p" .. tr.index .. "=" .. tostring(tr.kind) .. ":" .. tostring(tr.spellId or tr.pct) .. "x" .. tostring(tr.occurrence or 1)
      end
      ns.Print("|cff88ccffCoolPlan armed " .. #phaseTriggers .. " phase trigger(s): " .. table.concat(ids, ", ") .. "|r")
    end
  end

  local function phaseHasTrigger(idx)
    if not phaseTriggers then return false end
    for _, tr in ipairs(phaseTriggers) do
      if tr.index == idx then return true end
    end
    return false
  end

  local maxCast = 0
  for _, c in ipairs(cues) do
    local pidx = c.phaseIndex
    if pidx and pidx > 1 and phaseHasTrigger(pidx) then
      -- defer until that phase's trigger fires
      pendingPhase = pendingPhase or {}
      pendingPhase[pidx] = pendingPhase[pidx] or {}
      local list = pendingPhase[pidx]
      list[#list + 1] = c
    else
      -- absolute (or a phase with no usable trigger → best-effort offset-from-pull)
      local castAt = c.timeMs / 1000
      if previewMode and pidx and pidx > 1 then
        -- No real phase timing in preview. Use the SAME sequential layout the Timeline
        -- canvas draws its markers with (opts.phaseStart, ms), so the playhead, the
        -- icons, and the HUD line up. Fall back to a fixed gap if none was passed.
        local ps = opts and opts.phaseStart
        local baseMs = (ps and ps[pidx]) or ((pidx - 1) * PREVIEW_PHASE_GAP * 1000)
        castAt = (baseMs + c.timeMs) / 1000
      end
      enqueue(c, castAt)
      if castAt > maxCast then maxCast = castAt end
    end
  end

  if #queue == 0 and not pendingPhase and not captureOnly then return false end
  finalizeQueue()

  if previewMode then
    preview = true
    previewClock = 0
    previewSpeed = opts.speed or 1
    previewTotal = maxCast
    previewOnTick = opts.onTick
    previewPhaseStart = opts.phaseStart
    pullTime = nil
  else
    pullTime = GetTime()
    -- Phase triggers fire via the boss-mod bridge (registered once on login);
    -- bossModSpell gates on phaseTriggers, so nothing extra is needed here.
  end
  driver:Show()
  return true
end

-- Categories shown to EVERYONE regardless of "only me": group-relevant cues a
-- player should see even when they belong to someone else — raid-wide defensives
-- (공생기 / raid_defensive) and Bloodlust/Heroism (bloodlust), since the whole
-- party plans around the lust window. Healer cooldowns (healer_cd / 힐러 쿨기)
-- are NOT here — they are self-only and filtered to the local character when
-- filterToMe is on, like every other non-raid-wide category.
local ALWAYS_SHOWN = { raid_defensive = true, bloodlust = true }

-- Categories that don't identify a class/spec (everyone could share or item-grant
-- them), so they're ignored when guessing which slot is "me" by known spells.
local NONSPEC_CATEGORY = { trinket = true, potion = true, racial = true }

-- Resolve which plan slot is the LOCAL character, for the live "only me" filter.
--   1) exact character-name match — how plans authored with your own toon name
--      already work (unchanged path).
--   2) fallback when no name matches (site exports carry log/team names, not your
--      toon name): the slot whose cooldowns your CURRENT spec/talents actually
--      know, via IsPlayerSpell. Returns the SINGLE confident winner (strictly the
--      most known class/spec CDs, ≥1) or nil → no guess (caller then shows only
--      raid-wide cues, i.e. today's behavior). A same-spec slot outscores a
--      same-class-other-spec one (it knows more of the row's spells), so when your
--      spec is present it wins; ties / no match resolve to nil rather than guess.
local function resolveOwner(reminders)
  local me = UnitName and UnitName("player")
  if me then
    for _, r in ipairs(reminders or {}) do
      if r.player and r.player ~= "" and strlower(r.player) == strlower(me) then
        return r.player
      end
    end
  end
  local known = IsPlayerSpell or IsSpellKnown
  if not known then return nil end
  local score, seen = {}, {}
  for _, r in ipairs(reminders or {}) do
    local pl, sid, cat = r.player, r.spellId, r.category or ""
    if pl and pl ~= "" and sid and not ALWAYS_SHOWN[cat] and not NONSPEC_CATEGORY[cat] then
      local key = pl .. "|" .. tostring(sid)
      if not seen[key] then            -- count each distinct (player, spell) once
        seen[key] = true
        local ok, res = pcall(known, sid)
        if ok and res then score[pl] = (score[pl] or 0) + 1 end
      end
    end
  end
  local best, bestN, tie = nil, 0, false
  for pl, n in pairs(score) do
    if n > bestN then best, bestN, tie = pl, n, false
    elseif n == bestN then tie = true end
  end
  if best and bestN >= 1 and not tie then return best end
  return nil
end

-- Build the cue list of cooldowns (kind="cd"): raid_defensive + bloodlust shown
-- to all; others "only me" + enabled categories. Boss mechanics are NOT cued
-- here — boss timelines are display-only (the Timeline view's red boss track),
-- never on-screen/sound/TTS alerts (BigWigs/DBM already cover boss mechanics).
-- previewAll: the Timeline "Test" is a preview of the whole plan, so it must NOT
-- filter to the logged-in character's name or hide categories — otherwise testing
-- on a different char (or with log/team names that don't match) shows nothing.
-- forPlayer (preview only): show that exact player's casts (+ always-shown
-- categories), ignoring the live "only me"/category filters.
-- `_boss` is accepted (call-site symmetry) but unused: boss cues are not fired.
local function buildCues(reminders, _boss, previewAll, forPlayer)
  local o = ns.DB.Options()
  -- Live "only me": resolve my plan slot up front (exact name → else spec guess).
  -- nil → no confident slot, so only raid-wide cues show (today's behavior).
  local liveFilter = (not previewAll) and (not forPlayer) and o.filterToMe
  local resolvedMe = liveFilter and resolveOwner(reminders) or nil

  local cues = {}
  for _, r in ipairs(reminders or {}) do
    local common = ALWAYS_SHOWN[r.category or ""]
    local meOk
    if forPlayer then
      meOk = common or (strlower(r.player or "") == strlower(forPlayer))
    elseif liveFilter then
      local pl = r.player
      meOk = common or (not pl) or pl == ""
        or (resolvedMe ~= nil and strlower(pl) == strlower(resolvedMe))
    else
      meOk = previewAll or common or (not o.filterToMe) or nameMatchesMe(r.player)
    end
    if meOk and (previewAll or forPlayer or ns.DB.CategoryEnabled(r.category)) then
      cues[#cues + 1] = {
        kind = "cd", timeMs = r.timeMs, spellId = r.spellId, phaseIndex = r.phaseIndex,
        player = r.player, category = r.category, spellName = r.spellName, alert = r.alert,
      }
    end
  end
  return cues
end

-- Start from the encounter's ACTIVE plan (boss timeline + phases live on the plan).
function Scheduler.Start(encounterID)
  local e = ns.DB.GetEncounter(encounterID)
  if not e then return false end
  local plan = e.plans[e.active]
  local cues = buildCues(plan and plan.reminders or {}, plan and plan.boss)
  if #cues == 0 then return false end
  activeId = encounterID
  return run(cues, { phases = plan and plan.phases })
end

-- Arm WITHOUT a plan, purely to capture boss-mod / Encounter-Timeline events with
-- real timestamps (trigger curation). Sets pullTime; shows no reminders. Used as
-- the testenc fallback when a boss has no saved plan yet. Arms BARE phase slots
-- (p2..p7, no cues) so the live TL/warning detection can still advance and LOG
-- "phase N fired" — letting you verify 2→3→4→5 detection without importing a plan.
function Scheduler.StartCapture(encounterID)
  activeId = encounterID
  local phases = {}
  for i = 2, 7 do phases[#phases + 1] = { index = i, trigger = { kind = "cast" } } end
  return run({}, { captureOnly = true, phases = phases })
end

-- Manually fire a phase NOW (testing): isolates the cue display/scheduling path
-- from live CLEU detection. Arm with `/coolplan testenc <id>` first, then
-- `/coolplan firephase <n>` — the phase-N cues should schedule at now + offset.
function Scheduler.FirePhase(index)
  if not pullTime then ns.Print("CoolPlan: arm a schedule first (/coolplan testenc <id>).") return false end
  if ns.debug then ns.Print("|cff88ccffCoolPlan: manually firing phase " .. tostring(index) .. "|r") end
  firePhase(index)
  return true
end

-- A short synthetic schedule so the user can preview the countdown in town.
function Scheduler.StartDemo()
  local me = UnitName("player")
  local demo = {
    { kind = "cd",   timeMs = 3000,  spellId = 740,   player = me, spellName = "Tranquility" },
    { kind = "cd",   timeMs = 8000,  spellId = 48707, player = me, spellName = "Anti-Magic Shell" },
    { kind = "cd",   timeMs = 13000, spellId = 31884, player = me, spellName = "Avenging Wrath" },
  }
  activeId = -1
  return run(demo)
end

function Scheduler.Stop()
  if driver then driver:Hide() end
  -- Boss-mod callbacks stay registered (once, on login); bossModSpell no-ops once
  -- phaseTriggers is cleared below.
  queue, pullTime, activeId = nil, nil, nil
  pendingPhase, phaseTriggers, hasHealthTrigger = nil, nil, false
  preview, previewClock, previewSpeed, previewTotal, previewOnTick = false, 0, 1, 0, nil
  previewPhaseStart = nil
  if ns.Reminders then ns.Reminders.Clear() end
end

-- Live preview of a plan, with no real encounter: virtual clock from 0.
-- `reminders`/`boss` come from a saved note. `speed` (default 1) accelerates
-- the virtual clock. `onTick(elapsed, total)` drives the Timeline playhead.
-- Honors the same filterToMe / category options as a real pull. Phase-anchored
-- cues are flattened to absolute (no live triggers exist in preview).
-- forPlayer: "__all__" = everyone, "<name>" = that player, nil/"" = the live
-- "only my character" filter (with a whole-plan fallback if it leaves nothing).
function Scheduler.StartPreview(reminders, boss, speed, onTick, forPlayer, phaseStart)
  local cues
  if forPlayer == "__all__" then
    cues = buildCues(reminders or {}, boss, true)
  elseif forPlayer and forPlayer ~= "" then
    cues = buildCues(reminders or {}, boss, false, forPlayer)
  else
    cues = buildCues(reminders or {}, boss, false)
    if #cues == 0 then cues = buildCues(reminders or {}, boss, true) end
  end
  if #cues == 0 then return false end
  activeId = -2
  return run(cues, { preview = true, speed = speed or 1, onTick = onTick, phaseStart = phaseStart })
end

function Scheduler.IsPreview()
  return preview
end

function Scheduler.IsActive()
  return (driver and driver:IsShown()) or false
end

function Scheduler.ActiveEncounter()
  return activeId
end
