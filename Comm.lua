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
-- no external deps — this addon stays dependency-free). All callbacks are
-- wrapped with ns.wrap / ns.safecall per the addon's error-isolation rule.

local _, ns = ...
local Comm = {}
ns.Comm = Comm

local PREFIX = "CoolPlan"
Comm.PREFIX = PREFIX

-- One addon message is <=255 bytes INCLUDING the "CoolPlan" prefix (8) + a
-- separator the server inserts (1). Our header "transferId|seq|total|" is up to
-- ~40 bytes (transferId ~28: a 12-char name + '-' + ms + '-' + counter, plus
-- seq/total digits + 3 pipes). 200 payload + 40 header + 9 = 249 < 255, with
-- margin to spare.
local CHUNK_BYTES   = 200
local SEND_INTERVAL = 0.15          -- seconds between chunks (rate-limit safe)

-- Abuse guards (a hostile/oversized sender must not be able to grow memory).
local MAX_CHUNKS      = 400          -- ~80 KB max per transfer (200 * 400)
local MAX_TOTAL_BYTES = MAX_CHUNKS * CHUNK_BYTES
local TRANSFER_TIMEOUT = 30          -- seconds to receive all chunks before giving up
local MAX_LIVE_TRANSFERS = 8         -- simultaneous in-flight inbound transfers

-- ── outbound ────────────────────────────────────────────────────────────────
local sendQueue = {}                 -- list of pending chunk bodies
local sendTicker = nil
local idCounter = 0

local function inParty()
  -- works solo? no. We want a real party (5-man) or raid.
  if IsInGroup and IsInGroup() then return true end
  if IsInRaid and IsInRaid() then return true end
  return false
end

local function channel()
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
    return
  end
  local body = table.remove(sendQueue, 1)
  if C_ChatInfo and C_ChatInfo.SendAddonMessage then
    C_ChatInfo.SendAddonMessage(PREFIX, body, channel())
  end
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

-- Public: share the active plan of the encounter we're scheduling, or — if not
-- in an encounter — every encounter's active plan (whole library).
function Comm.ShareActive()
  if not inParty() then
    ns.Print("not in a party — join a group to share a plan.")
    return
  end

  local lib = ns.DB.Library()
  local hasAny = false
  for _ in pairs(lib) do hasAny = true; break end
  if not hasAny then
    ns.Print("no saved plans to share. /coolplan edit to import one first.")
    return
  end

  -- Prefer the encounter currently armed; otherwise export all active plans.
  local onlyId = nil
  if ns.Scheduler and ns.Scheduler.ActiveEncounter then
    local a = ns.Scheduler.ActiveEncounter()
    if a and a ~= -1 and lib[a] then onlyId = a end
  end

  local payload = ns.DB.ToSerializable(onlyId)
  local nEnc = 0
  for _ in pairs(payload) do nEnc = nEnc + 1 end
  if nEnc == 0 then
    ns.Print("no active plan to share.")
    return
  end

  local str = ns.Format.Serialize(payload, { source = "share" })
  local ok, total = broadcast(str)
  if ok then
    ns.Print(("sharing %d plan(s) to %s (%d chunk%s)…"):format(
      nEnc, channel():lower(), total, total == 1 and "" or "s"))
  end
end

-- Public: share one specific encounter's active plan (used by Manager rows).
function Comm.ShareEncounter(id)
  if not inParty() then
    ns.Print("not in a party — join a group to share a plan.")
    return
  end
  local lib = ns.DB.Library()
  if not lib[id] then return end
  local str = ns.Format.Serialize(ns.DB.ToSerializable(id), { source = "share" })
  local ok, total = broadcast(str)
  if ok then
    ns.Print(("sharing %s to %s (%d chunk%s)…"):format(
      lib[id].name or ("encounter " .. id), channel():lower(), total, total == 1 and "" or "s"))
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
      -- too many concurrent senders — ignore new ones rather than grow memory.
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
        -- missing a chunk despite the count (shouldn't happen) — bail safely.
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

-- Parse the reassembled plan and present an accept prompt.
function Comm.OnReceived(sender, str)
  local plans, _, err = ns.Format.Parse(str)
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
  for id, parsed in pairs(plans) do
    local label = "Shared from " .. tostring(sender)
    local idx = ns.DB.AddPlan(id, parsed.name, label, parsed.reminders, parsed.boss)
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
    title:SetText("|cff66b3ffCoolPlan|r — shared plan")
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
  prompt.body:SetText(("|cffffd200%s|r shared\n|cff88ccff%s|r\n\nAdd it to your saved plans?"):format(
    tostring(sender), tostring(bossName)))
  prompt:Show()
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
  listener:SetScript("OnEvent", ns.wrap(function(_, event, ...)
    if event ~= "CHAT_MSG_ADDON" then return end
    local prefix, message, _, sender = ...
    if prefix ~= PREFIX then return end
    if not message or not sender then return end
    -- ignore our own broadcasts (PARTY echoes back to the sender)
    local me = (UnitName and UnitName("player")) or ""
    local short = tostring(sender):match("^([^%-]+)") or sender
    if short == me or sender == me then return end
    handleChunk(sender, message)
  end))
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
