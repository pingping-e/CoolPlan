-- Party plan sharing (NSRT-style "Send" for 5-man M+).
--
-- The active plan + shared boss timeline is serialized with Format.Serialize,
-- then split into small chunks and broadcast over the PARTY addon channel. A
-- receiver buffers the chunks per transfer, reassembles, and shows an accept
-- prompt before saving into the per-encounter library (DB.AddPlan).
--
-- Wire protocol (one addon message body per chunk):
--   transferId|seq|total|payload
--     transferId  unique per send: sender's name + GetTime ticks + a counter,
--                 with '|' stripped so it never collides with the delimiter.
--     seq         1-based chunk index
--     total       number of chunks in this transfer
--     payload     <= CHUNK_BYTES of the serialized plan string
--
-- Constraints honored: WoW addon messages are <=255 bytes including the chat
-- prefix, and the server rate-limits them. We keep payload small and send one
-- chunk every SEND_INTERVAL seconds from a C_Timer queue (no ChatThrottleLib /
-- no external deps - this addon stays dependency-free). All callbacks are
-- wrapped with ns.wrap / ns.safecall per the addon's error-isolation rule.

local _, ns = ...
local Comm = {}
ns.Comm = Comm

local PREFIX = "CoolPlan"
Comm.PREFIX = PREFIX

-- Plans are large, repetitive text (16 KB+ for a whole dungeon). Compressing
-- with DEFLATE before chunking shrinks that ~8x, which keeps a transfer under
-- the client's addon-message burst quota (~25 messages) so it rarely throttles.
-- EncodeForWoWAddonChannel also makes the bytes channel-safe (handles newlines/
-- nulls), so no separate newline escaping is needed on the wire.
local LibDeflate = LibStub and LibStub("LibDeflate", true)

-- One addon message is <=255 bytes INCLUDING the "CoolPlan" prefix (8) + a
-- separator the server inserts (1). Our header "transferId|seq|total|" is up to
-- ~40 bytes (transferId ~28: a 12-char name + '-' + ms + '-' + counter, plus
-- seq/total digits + 3 pipes). 200 payload + 40 header + 9 = 249 < 255, with
-- margin to spare.
local CHUNK_BYTES   = 200
local SEND_INTERVAL = 0.15          -- seconds between chunks (rate-limit safe)
-- Retry cap for a TEMPORARY throttle (~9s at 0.15s/tick). Normal throttle clears
-- in 1-2s, well under this; permanent failures (left group) abort immediately
-- via the result code, so this only bounds a stuck-throttle edge case.
local MAX_SEND_RETRIES = 60

-- The serialized plan is a multi-LINE string (Format joins rows with '\n').
-- SendAddonMessage silently truncates a body at the first '\n' (or refuses to
-- send it), so a raw plan never reassembles on the receiver and the accept
-- popup never appears. Encode newlines to a control byte (0x1E, never produced
-- by sanitize()) for transport and restore them after reassembly. This is the
-- reason party-share never worked before - see OnReceived for the reverse.
local NL_SENTINEL = "\30"

-- Abuse guards (a hostile/oversized sender must not be able to grow memory).
local MAX_CHUNKS      = 400          -- ~80 KB max per transfer (200 * 400)
local MAX_TOTAL_BYTES = MAX_CHUNKS * CHUNK_BYTES
local TRANSFER_TIMEOUT = 30          -- seconds to receive all chunks before giving up
local MAX_LIVE_TRANSFERS = 8         -- simultaneous in-flight inbound transfers

-- ── outbound ────────────────────────────────────────────────────────────────
local sendQueue = {}                 -- list of pending chunk bodies
local sendTicker = nil
local idCounter = 0
local sendRetries = 0                -- consecutive failed sends of the head chunk

local INSTANCE_CAT = LE_PARTY_CATEGORY_INSTANCE or 2

local function inParty()
  -- works solo? no. We want a real party (5-man) or raid. Check BOTH the home
  -- group and the instance group (M+/LFG): inside a dungeon the party is an
  -- instance group, where IsInGroup() with no category can read false.
  if IsInRaid and IsInRaid() then return true end
  if IsInGroup and (IsInGroup() or IsInGroup(INSTANCE_CAT)) then return true end
  return false
end

local function channel()
  -- Inside an instance group (M+ dungeon / LFG / LFR), party & raid chat are
  -- routed through INSTANCE_CHAT; addon messages sent to "PARTY"/"RAID" there
  -- are silently dropped. This is a Mythic+ addon, so that's the common case.
  if IsInGroup and IsInGroup(INSTANCE_CAT) then return "INSTANCE_CHAT" end
  if IsInRaid and IsInRaid() then return "RAID" end
  return "PARTY"
end

-- Split a string into <=CHUNK_BYTES byte slices. Lua strings are byte arrays,
-- and our serialized format is ASCII (sanitize() strips control bytes), so a
-- plain byte slice never lands inside a multi-byte sequence here.
local function chunkString(s)
  local chunks = {}
  local n = #s
  local pos = 1
  while pos <= n do
    chunks[#chunks + 1] = s:sub(pos, pos + CHUNK_BYTES - 1)
    pos = pos + CHUNK_BYTES
  end
  if #chunks == 0 then chunks[1] = "" end
  return chunks
end

local function newTransferId()
  idCounter = idCounter + 1
  local me = (UnitName and UnitName("player")) or "?"
  local t = (GetTime and math.floor(GetTime() * 1000)) or 0
  -- strip the delimiter from the name so it can't break parsing.
  me = tostring(me):gsub("|", "")
  return me .. "-" .. t .. "-" .. idCounter
end

local function pumpSendQueue()
  if #sendQueue == 0 then
    if sendTicker then sendTicker:Cancel(); sendTicker = nil end
    sendRetries = 0
    return
  end
  -- Peek (don't pop yet): SendAddonMessage can be throttled by the client
  -- (Enum.SendAddonMessageResult.AddonMessageThrottle == 3), which silently
  -- drops the message. Only remove the chunk from the queue once the client
  -- accepted it; otherwise leave it to be retried on the next tick. Dropping
  -- throttled chunks here is what made large transfers lose their tail and
  -- never reassemble on the receiver.
  local body = sendQueue[1]
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
    table.remove(sendQueue, 1) -- no API: nothing we can do, drop it
    return
  end
  local ret = C_ChatInfo.SendAddonMessage(PREFIX, body, channel())
  local R = Enum and Enum.SendAddonMessageResult
  local SUCCESS  = (R and R.Success) or 0
  local THROTTLE = (R and R.AddonMessageThrottle) or 3
  local accepted = (ret == nil) or (ret == true) or (ret == SUCCESS)
  if accepted then
    table.remove(sendQueue, 1)
    sendRetries = 0
    return
  end
  -- A throttle (or an unknown non-numeric result on old clients) is TEMPORARY:
  -- keep the chunk and retry next tick, capped so it can't spin forever.
  if ret == THROTTLE or type(ret) ~= "number" then
    sendRetries = sendRetries + 1
    if sendRetries < MAX_SEND_RETRIES then return end
  end
  -- Permanent failure (left the group / bad channel), or throttle that never
  -- cleared within the cap: stop now instead of retrying forever.
  wipe(sendQueue)
  sendRetries = 0
  if sendTicker then sendTicker:Cancel(); sendTicker = nil end
  ns.Print("|cffff6666CoolPlan: couldn't finish sharing (left group or network issue). Try again.|r")
end

local function startPump()
  if sendTicker then return end
  -- send one immediately, then on an interval.
  ns.safecall(pumpSendQueue)
  if #sendQueue > 0 and C_Timer and C_Timer.NewTicker then
    sendTicker = C_Timer.NewTicker(SEND_INTERVAL, ns.wrap(pumpSendQueue))
  end
end

-- Enqueue a serialized string as a chunked transfer over the group channel.
local function broadcast(str)
  local c = LibDeflate and LibDeflate:CompressDeflate(str, { level = 9 })
  local enc = c and LibDeflate:EncodeForWoWAddonChannel(c)
  if enc then
    str = enc
  else
    -- no LibDeflate (or it returned nothing): fall back to plain newline-escaping
    -- so SendAddonMessage doesn't truncate at '\n'.
    str = (str:gsub("\n", NL_SENTINEL))
  end
  local chunks = chunkString(str)
  local total = #chunks
  if total > MAX_CHUNKS then
    ns.Print("|cffff6666plan too large to share (" .. total .. " chunks).|r")
    return false
  end
  local id = newTransferId()
  for seq = 1, total do
    sendQueue[#sendQueue + 1] = table.concat({ id, seq, total, chunks[seq] }, "|")
  end
  startPump()
  return true, total
end

-- Public: `/coolplan share`. If armed at a boss, share that boss; otherwise
-- point the user at Saved Plans (per-plan / whole-dungeon share live there).
-- NOTE: deliberately NO whole-library dump - that shipped plans for dungeons the
-- party isn't running and cluttered recipients.
function Comm.ShareActive()
  if not inParty() then
    ns.Print("not in a party, join a group to share a plan.")
    return
  end
  local lib = ns.DB.Library()
  local armed = ns.Scheduler and ns.Scheduler.ActiveEncounter and ns.Scheduler.ActiveEncounter()
  if armed and armed ~= -1 and lib[armed] then
    Comm.ShareEncounter(armed)
  else
    ns.Print("open Saved Plans (/coolplan plans) to share a boss plan, or a whole dungeon.")
  end
end

-- Public: share one encounter. `index` picks a specific plan (used by Manager
-- rows so the clicked plan is sent verbatim WITHOUT changing your active plan);
-- omit it to send the encounter's current active plan.
function Comm.ShareEncounter(id, index)
  if not inParty() then
    ns.Print("not in a party, join a group to share a plan.")
    return
  end
  local lib = ns.DB.Library()
  if not lib[id] then return end
  local payload = ns.DB.ToSerializable(id, index)
  local nEnc = 0
  for _ in pairs(payload) do nEnc = nEnc + 1 end
  if nEnc == 0 then
    ns.Print("nothing to share for this boss (no active plan).")
    return
  end
  local str = ns.Format.Serialize(payload, { source = "share" })
  local ok, total = broadcast(str)
  if ok then
    ns.Print(("sending %s to %s (%d chunk%s)…"):format(
      lib[id].name or ("encounter " .. id), channel():lower(), total, total == 1 and "" or "s"))
  end
end

-- Public: share the ACTIVE plan of several encounters at once (the "Share
-- dungeon" popup hands us the checked bosses). Disarmed/empty encounters drop
-- out naturally (ToSerializable skips them).
function Comm.ShareEncounters(ids)
  if not inParty() then
    ns.Print("not in a party, join a group to share a plan.")
    return
  end
  local lib = ns.DB.Library()
  local payload = {}
  for _, id in ipairs(ids or {}) do
    if lib[id] then
      for k, v in pairs(ns.DB.ToSerializable(id)) do payload[k] = v end
    end
  end
  local nEnc = 0
  for _ in pairs(payload) do nEnc = nEnc + 1 end
  if nEnc == 0 then
    ns.Print("no active plans to share.")
    return
  end
  local str = ns.Format.Serialize(payload, { source = "share" })
  local ok, total = broadcast(str)
  if ok then
    ns.Print(("sending %d boss plan(s) to %s (%d chunk%s)…"):format(
      nEnc, channel():lower(), total, total == 1 and "" or "s"))
  end
end

-- ── inbound ───────────────────────────────────────────────────────────────--
-- transfers[key] = { sender, total, got, bytes, chunks = { [seq]=payload }, started }
local transfers = {}

local function transferKey(sender, id)
  return sender .. "\0" .. id
end

local function liveTransferCount()
  local n = 0
  for _ in pairs(transfers) do n = n + 1 end
  return n
end

local function dropTransfer(key)
  transfers[key] = nil
end

-- Sweep transfers that never completed.
local function sweep()
  local now = (GetTime and GetTime()) or 0
  for key, t in pairs(transfers) do
    if now - t.started > TRANSFER_TIMEOUT then
      transfers[key] = nil
    end
  end
end

local function handleChunk(sender, body)
  -- body = transferId|seq|total|payload  (payload may itself contain '|', so
  -- only split off the first 3 fields and keep the rest verbatim).
  local id, seqS, totalS, payload = body:match("^(.-)|(%d+)|(%d+)|(.*)$")
  if not id or id == "" then return end
  local seq, total = tonumber(seqS), tonumber(totalS)
  if not seq or not total then return end
  if total < 1 or total > MAX_CHUNKS then return end
  if seq < 1 or seq > total then return end

  local key = transferKey(sender, id)
  local t = transfers[key]
  if not t then
    sweep()
    if liveTransferCount() >= MAX_LIVE_TRANSFERS then
      -- too many concurrent senders - ignore new ones rather than grow memory.
      return
    end
    t = { sender = sender, total = total, got = 0, bytes = 0, chunks = {},
          started = (GetTime and GetTime()) or 0 }
    transfers[key] = t
  end

  if t.total ~= total then return end       -- inconsistent header, ignore
  if t.chunks[seq] ~= nil then return end    -- duplicate seq, ignore

  t.bytes = t.bytes + #payload
  if t.bytes > MAX_TOTAL_BYTES then          -- runaway transfer, abort it
    dropTransfer(key)
    return
  end

  t.chunks[seq] = payload
  t.got = t.got + 1

  if t.got >= t.total then
    -- reassemble in order
    local parts = {}
    for i = 1, t.total do
      if t.chunks[i] == nil then
        -- missing a chunk despite the count (shouldn't happen) - bail safely.
        dropTransfer(key)
        return
      end
      parts[i] = t.chunks[i]
    end
    dropTransfer(key)
    local full = table.concat(parts)
    ns.safecall(Comm.OnReceived, sender, full)
  end
end

-- Throttle the "can't read / version mismatch" warning so a malformed or
-- cross-version sender can't spam the chat (one line per 5s at most).
local lastUnreadWarn = 0

-- Parse the reassembled plan and present an accept prompt.
function Comm.OnReceived(sender, str)
  if LibDeflate then
    -- reverse of broadcast(): channel-decode then DEFLATE-decompress.
    local decoded = LibDeflate:DecodeForWoWAddonChannel(str)
    local raw = decoded and LibDeflate:DecompressDeflate(decoded)
    if not raw then
      -- Couldn't decompress: sender is on a different (older/newer) CoolPlan whose
      -- wire format we can't read. Warn at most once per 5s so a malformed/hostile
      -- or cross-version sender can't spam the chat with red errors.
      local now = (GetTime and GetTime()) or 0
      if now - lastUnreadWarn > 5 then
        lastUnreadWarn = now
        ns.Print("|cffff6666CoolPlan: got a plan we can't read. You and the sender need the same CoolPlan version. Please update.|r")
      end
      return
    end
    str = raw
  else
    -- fallback path (older sender): undo newline escaping.
    str = (str:gsub(NL_SENTINEL, "\n"))
  end
  local plans = ns.Format.Parse(str)
  if not plans then
    -- silent on parse failure: could be a malformed / hostile payload.
    return
  end

  -- summarize what's inside (boss name + plan/boss counts) for the prompt.
  local firstId, firstEnc, nEnc = nil, nil, 0
  for id, enc in pairs(plans) do
    nEnc = nEnc + 1
    if not firstId then firstId, firstEnc = id, enc end
  end
  if nEnc == 0 then return end

  local bossName
  if nEnc == 1 then
    bossName = (firstEnc.name and firstEnc.name ~= "" and firstEnc.name)
      or (ns.EncounterNames and ns.EncounterNames[firstId])
      or ("Encounter " .. firstId)
  else
    bossName = nEnc .. " encounters"
  end

  Comm.PromptAccept(sender, bossName, plans)
end

-- Apply an accepted transfer: add each encounter's plan to the library.
local function applyPlans(sender, plans)
  local added, bossOnly = 0, 0
  -- drop the realm so a cross-realm "Name-Realm" sender saves as just "Name".
  local who = (Ambiguate and Ambiguate(tostring(sender), "short"))
    or tostring(sender):match("^[^%-]+") or tostring(sender)
  for id, parsed in pairs(plans) do
    local label = "Sent by " .. who
    local idx = ns.DB.AddPlan(id, parsed.name, label, parsed.reminders, parsed.boss, parsed.phases)
    if idx == 0 then bossOnly = bossOnly + 1 else added = added + 1 end
  end
  ns.Print(("|cff66ff66saved %d plan(s) from %s%s.|r"):format(
    added, tostring(sender),
    bossOnly > 0 and (", refreshed %d boss timeline(s)"):format(bossOnly) or ""))
  if ns.Manager and ns.Manager.Refresh then ns.safecall(ns.Manager.Refresh) end
end

-- ── accept prompt (self-built frame, matching Manager's no-StaticPopup style) ─
local prompt
function Comm.PromptAccept(sender, bossName, plans)
  if not prompt then
    prompt = CreateFrame("Frame", "CoolPlanSharePrompt", UIParent, "BackdropTemplate")
    prompt:SetSize(360, 130)
    prompt:SetPoint("CENTER", 0, 120)
    prompt:SetFrameStrata("FULLSCREEN_DIALOG")
    prompt:SetMovable(true)
    prompt:EnableMouse(true)
    prompt:RegisterForDrag("LeftButton")
    prompt:SetScript("OnDragStart", prompt.StartMoving)
    prompt:SetScript("OnDragStop", prompt.StopMovingOrSizing)
    if ns.Style then
      ns.Style.Panel(prompt, 0.98)
    elseif prompt.SetBackdrop then
      prompt:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 16,
        insets = { left = 4, right = 4, top = 4, bottom = 4 },
      })
    end
    local title = prompt:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", 0, -16)
    title:SetText("|cff66b3ffCoolPlan|r: shared plan")
    prompt.title = title

    local body = prompt:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    body:SetPoint("TOP", 0, -40)
    body:SetWidth(330)
    body:SetJustifyH("CENTER")
    prompt.body = body

    local accept = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
    accept:SetSize(110, 22); accept:SetText("Accept")
    accept:SetPoint("BOTTOMRIGHT", -20, 16)
    accept:SetScript("OnClick", ns.wrap(function()
      local p = prompt._plans
      local s = prompt._sender
      prompt:Hide()
      if p then applyPlans(s, p) end
      prompt._plans = nil
    end))

    local decline = CreateFrame("Button", nil, prompt, "UIPanelButtonTemplate")
    decline:SetSize(110, 22); decline:SetText("Decline")
    decline:SetPoint("BOTTOMLEFT", 20, 16)
    decline:SetScript("OnClick", ns.wrap(function()
      prompt:Hide()
      prompt._plans = nil
    end))

    if ns.Style then ns.Style.Apply(prompt) end
  end

  prompt._sender = sender
  prompt._plans = plans

  -- Build a transparent summary of what's arriving: each boss name + cooldown
  -- count (+boss timeline marker), and a note that accepting makes them active.
  -- (Plan labels aren't carried in the wire format, so we show boss + counts.)
  local enc = {}
  for id, p in pairs(plans) do
    local nm = (p.name and p.name ~= "" and p.name)
      or (ns.EncounterNames and ns.EncounterNames[id])
      or ("Encounter " .. tostring(id))
    enc[#enc + 1] = {
      name = nm,
      cd = (p.reminders and #p.reminders) or 0,
      hasBoss = p.boss and #p.boss > 0,
    }
  end
  table.sort(enc, function(a, b) return a.name < b.name end)
  local nEnc = #enc

  local lines = {}
  if nEnc <= 1 then
    lines[#lines + 1] = ("|cffffd200%s|r shared a plan:"):format(tostring(sender))
    lines[#lines + 1] = ""
    local e1 = enc[1]
    if e1 then
      lines[#lines + 1] = ("|cff88ccff%s|r |cff888888(%d cd)|r"):format(e1.name, e1.cd)
    end
  else
    lines[#lines + 1] = ("|cffffd200%s|r shared a dungeon plan - %d bosses:"):format(tostring(sender), nEnc)
    lines[#lines + 1] = ""
    for _, e1 in ipairs(enc) do
      lines[#lines + 1] = ("|cff88ccff%s|r |cff888888(%d cd)|r"):format(e1.name, e1.cd)
    end
  end
  lines[#lines + 1] = ""
  local it = (nEnc <= 1) and "it" or "them"
  lines[#lines + 1] = ("|cff888888Accepting adds %s and makes %s active.|r"):format(it, it)

  prompt.body:SetText(table.concat(lines, "\n"))
  -- grow the frame to fit (title 40 + body + gap 16 + button 22 + pad 18)
  local bh = (prompt.body.GetStringHeight and prompt.body:GetStringHeight()) or (#lines * 13)
  prompt:SetHeight(math.min(420, math.max(130, 40 + bh + 16 + 22 + 18)))
  prompt:Show()
end

-- ── version handshake ───────────────────────────────────────────────────────
-- Announce our addon version to group/guild; if a peer (or a version we saw
-- before, persisted) is newer, tell the user ONCE that they're out of date.
-- Everything here is best-effort + nil-guarded - a failure must never break the
-- rest of the addon (all callers are ns.wrap'd at the event layer).
local VER_TAG = "CPVER:"
local outdatedNotified = false

local function myVersion()
  local v = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata("CoolPlan", "Version"))
    or (GetAddOnMetadata and GetAddOnMetadata("CoolPlan", "Version"))
  return v or "0.0.0"
end

local function parseVer(s)
  local a, b, c = tostring(s or ""):match("(%d+)%.(%d+)%.(%d+)")
  return tonumber(a) or 0, tonumber(b) or 0, tonumber(c) or 0
end

-- is version `a` strictly older than `b`?
local function verLess(a, b)
  local a1, a2, a3 = parseVer(a)
  local b1, b2, b3 = parseVer(b)
  if a1 ~= b1 then return a1 < b1 end
  if a2 ~= b2 then return a2 < b2 end
  return a3 < b3
end
Comm._verLess = verLess -- exposed for tests

-- Highest version seen from peers THIS SESSION only. NOT persisted: a forged or
-- one-off bogus ping (e.g. someone sending "99.0.0") must not stick in
-- SavedVariables and produce a permanent, unfixable "out of date" nag every login.
local seenMaxVer = nil

local function notifyOutdated(latest)
  if outdatedNotified then return end
  outdatedNotified = true
  ns.Print(("|cffff9900CoolPlan is out of date - you have %s, latest seen is %s. Please update.|r")
    :format(myVersion(), tostring(latest)))
end

-- Inbound version ping: track the highest seen THIS SESSION, warn once if behind.
local function onVersionPing(other)
  if type(other) ~= "string" or other == "" then return end
  if not other:match("^%d+%.%d+%.%d+") then return end -- ignore garbage
  if (not seenMaxVer) or verLess(seenMaxVer, other) then seenMaxVer = other end
  if verLess(myVersion(), other) then notifyOutdated(other) end
end

-- Send our version to the channels we're in (group + guild).
local guildPinged = false
function Comm.BroadcastVersion()
  if not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then return end
  local msg = VER_TAG .. myVersion()
  local ch
  if IsInGroup and IsInGroup(INSTANCE_CAT) then ch = "INSTANCE_CHAT"
  elseif IsInRaid and IsInRaid() then ch = "RAID"
  elseif IsInGroup and IsInGroup() then ch = "PARTY" end
  if ch then C_ChatInfo.SendAddonMessage(PREFIX, msg, ch) end
  -- guild: once per session only. Roster churn (group invites/leaves) shouldn't
  -- re-ping the guild channel every time; peers announce themselves too.
  if not guildPinged and IsInGuild and IsInGuild() then
    guildPinged = true
    C_ChatInfo.SendAddonMessage(PREFIX, msg, "GUILD")
  end
end

-- Debounce roster churn so joining a group doesn't spam version pings.
local verBcastPending = false
local function scheduleVersionBroadcast()
  if verBcastPending then return end
  verBcastPending = true
  if C_Timer and C_Timer.After then
    C_Timer.After(3, ns.wrap(function() verBcastPending = false; Comm.BroadcastVersion() end))
  else
    verBcastPending = false
    Comm.BroadcastVersion()
  end
end

-- ── event wiring ─────────────────────────────────────────────────────────────
local listener
function Comm.Init()
  if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
    C_ChatInfo.RegisterAddonMessagePrefix(PREFIX)
  end
  if listener then return end
  listener = CreateFrame("Frame")
  listener:RegisterEvent("CHAT_MSG_ADDON")
  listener:RegisterEvent("GROUP_ROSTER_UPDATE")
  listener:SetScript("OnEvent", ns.wrap(function(_, event, ...)
    if event == "GROUP_ROSTER_UPDATE" then
      scheduleVersionBroadcast()
      return
    end
    if event ~= "CHAT_MSG_ADDON" then return end
    local prefix, message, _, sender = ...
    if prefix ~= PREFIX then return end
    if not message or not sender then return end
    -- ignore our own broadcasts (PARTY echoes back to the sender)
    local me = (UnitName and UnitName("player")) or ""
    local short = tostring(sender):match("^([^%-]+)") or sender
    if short == me or sender == me then return end
    -- version ping is a tiny tagged message, not a chunked transfer.
    if message:sub(1, #VER_TAG) == VER_TAG then
      onVersionPing(message:sub(#VER_TAG + 1))
      return
    end
    handleChunk(sender, message)
  end))
  -- on login: announce our version. Peers reply via onVersionPing, which warns
  -- once if we're behind. No persisted "seen version", so no stale/forged nag.
  scheduleVersionBroadcast()
end

-- exposed for tests
Comm._chunkString = chunkString
Comm._handleChunk = handleChunk
Comm._transfers = transfers
Comm._drainSendQueue = function()
  -- test helper: synchronously flush whatever's queued
  while #sendQueue > 0 do pumpSendQueue() end
end
Comm._sendQueueLen = function() return #sendQueue end
