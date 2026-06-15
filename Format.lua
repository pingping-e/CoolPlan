-- CoolPlan plan format: parse + serialize.
-- Byte-for-byte mirror of the website's lib/export/coolplan-format.ts so plans
-- round-trip between coolplan.team and this addon. Keep the two in sync.
--
-- v1: absolute pull-relative times only. v2 (superset, back-compat): adds an
-- optional per-encounter @phase table + phase-anchored row times (`pN+M:SS.T`)
-- for phase-GATED bosses, so the Scheduler can re-anchor each phase live. A plan
-- with no phase data serializes byte-identically to v1.

local _, ns = ...
local Format = {}
ns.Format = Format

local MAGIC = "COOLPLAN"
local VERSION = 1          -- baseline (absolute-time)
local VERSION_PHASED = 2   -- adds @phase table + pN+ anchored times
Format.VERSION = VERSION

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function sanitize(s)
  if s == nil then return "" end
  -- Strip the delimiter ';', the WoW escape char '|', and newlines.
  return (tostring(s):gsub("[;|\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ms -> "M:SS.T"
function Format.FormatTime(ms)
  if not ms or ms < 0 then ms = 0 end
  local totalSec = math.floor(ms / 1000)
  local m = math.floor(totalSec / 60)
  local s = totalSec % 60
  local tenths = math.floor((ms % 1000) / 100)
  return string.format("%d:%02d.%d", m, s, tenths)
end

-- "M:SS.T" or plain seconds -> ms
function Format.ParseTime(str)
  str = trim(str)
  local mm, rest = str:match("^(%d+):(.+)$")
  if mm then
    local r = tonumber(rest) or 0
    return math.floor((tonumber(mm) * 60 + r) * 1000 + 0.5)
  end
  local n = tonumber(str)
  if not n then return 0 end
  return math.floor(n * 1000 + 0.5)
end

-- A row's time field: "M:SS.T" (absolute) or "pN+M:SS.T" (offset from phase N's
-- live anchor). Returns ms, phaseIndex (phaseIndex nil when absolute).
function Format.ParseTimeField(str)
  str = trim(str)
  local pidx, rest = str:match("^[pP](%d+)%+(.*)$")
  if pidx then
    return Format.ParseTime(rest), tonumber(pidx)
  end
  return Format.ParseTime(str), nil
end

local function serializeTime(ms, phaseIndex)
  local t = Format.FormatTime(ms)
  if phaseIndex and phaseIndex > 1 then
    return "p" .. phaseIndex .. "+" .. t
  end
  return t
end

-- Group rows by phase (major key) then offset, so the document reads in play order.
local function rowKey(r)
  local phase = (r.phaseIndex and r.phaseIndex > 1) and r.phaseIndex or 1
  return phase * 1e9 + (r.timeMs or 0)
end

local function splitLines(text)
  local out = {}
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    out[#out + 1] = line
  end
  return out
end

-- Split a row into fields on ';' (current) or '|' (legacy). Normalize the old
-- pipe delimiter to ';' first so a single pass handles both.
local function splitFields(s)
  s = s:gsub("|", ";")
  local t = {}
  for field in (s .. ";"):gmatch("(.-);") do
    t[#t + 1] = field
  end
  return t
end

-- "@phase ; index ; label ; kind? ; (spellId|pct)? ; occurrence? ; unitCount?"
local function serializePhase(p)
  local fields = { "@phase", tostring(p.index), sanitize(p.label), "", "", "", "" }
  local t = p.trigger
  if t then
    fields[4] = t.kind or ""
    if t.kind == "health" then
      fields[5] = (t.pct ~= nil) and tostring(t.pct) or ""
    elseif t.kind ~= "rotation-resume" then
      fields[5] = (t.spellId ~= nil) and tostring(t.spellId) or ""
      fields[6] = (t.occurrence ~= nil) and tostring(t.occurrence) or ""
    end
    if t.unitCount ~= nil then fields[7] = tostring(t.unitCount) end
  end
  local n = #fields
  while n > 3 and fields[n] == "" do n = n - 1 end
  local row = {}
  for k = 1, n do row[k] = fields[k] end
  return table.concat(row, ";")
end

local function hasPhases(plans)
  for _, enc in pairs(plans) do
    if enc.phases and #enc.phases > 0 then return true end
  end
  return false
end

-- plans = { [encounterID] = { name, reminders = { {timeMs, spellId, player, category?, spellName?, alert?, phaseIndex?}, ... },
--                             boss? = { {timeMs, spellId, type?, spellName?, phaseIndex?}, ... },
--                             phases? = { {index, label, trigger?={kind, spellId?, occurrence?, pct?}}, ... } } }
function Format.Serialize(plans, meta)
  local version = hasPhases(plans) and VERSION_PHASED or VERSION
  local lines = { MAGIC .. " v" .. version }

  if meta then
    local parts = {}
    for k, v in pairs(meta) do
      if v ~= nil and v ~= "" then parts[#parts + 1] = k .. "=" .. sanitize(v) end
    end
    table.sort(parts)
    if #parts > 0 then lines[#lines + 1] = "@meta " .. table.concat(parts, "; ") end
  end

  local ids = {}
  for id in pairs(plans) do ids[#ids + 1] = id end
  table.sort(ids)

  for _, id in ipairs(ids) do
    local enc = plans[id]
    lines[#lines + 1] = ""
    lines[#lines + 1] = "[encounter] id=" .. id .. "; name=" .. sanitize(enc.name)

    if enc.phases then
      local ps = {}
      for _, p in ipairs(enc.phases) do ps[#ps + 1] = p end
      table.sort(ps, function(a, b) return a.index < b.index end)
      for _, p in ipairs(ps) do lines[#lines + 1] = serializePhase(p) end
    end

    local rs = {}
    for _, r in ipairs(enc.reminders) do rs[#rs + 1] = r end
    table.sort(rs, function(a, b) return rowKey(a) < rowKey(b) end)

    for _, r in ipairs(rs) do
      local fields = {
        serializeTime(r.timeMs, r.phaseIndex),
        tostring(r.spellId),
        sanitize(r.player),
        sanitize(r.category),
        sanitize(r.spellName),
        sanitize(r.alert),
      }
      local n = #fields
      while n > 3 and fields[n] == "" do n = n - 1 end
      local row = {}
      for k = 1, n do row[k] = fields[k] end
      lines[#lines + 1] = table.concat(row, ";")
    end

    if enc.boss then
      local bs = {}
      for _, b in ipairs(enc.boss) do bs[#bs + 1] = b end
      table.sort(bs, function(a, b) return rowKey(a) < rowKey(b) end)
      for _, b in ipairs(bs) do
        local fields = { "@boss", serializeTime(b.timeMs, b.phaseIndex), tostring(b.spellId), sanitize(b.type), sanitize(b.spellName) }
        local n = #fields
        while n > 3 and fields[n] == "" do n = n - 1 end
        local row = {}
        for k = 1, n do row[k] = fields[k] end
        lines[#lines + 1] = table.concat(row, ";")
      end
    end
  end

  return table.concat(lines, "\n")
end

-- returns plans, meta  (or nil, nil, errorMessage)
function Format.Parse(text)
  local lines = splitLines(text or "")

  local i = 1
  while i <= #lines and trim(lines[i]) == "" do i = i + 1 end
  local header = trim(lines[i] or "")
  local ver = header:match("^COOLPLAN%s+v(%d+)")
  if not ver then
    return nil, nil, "Not a CoolPlan string (missing 'COOLPLAN v1' header)."
  end
  ver = tonumber(ver)
  if ver ~= VERSION and ver ~= VERSION_PHASED then
    -- A higher version = a plan from a newer site than this addon supports.
    -- Tell the user to update rather than showing a bare "unsupported" code.
    if ver > VERSION_PHASED then
      return nil, nil, "This plan needs a newer CoolPlan (made for v" .. ver .. "). Please update the addon."
    end
    return nil, nil, "Unsupported CoolPlan version: v" .. ver .. "."
  end

  local plans = {}
  local meta = {}
  local current = nil

  for j = i + 1, #lines do
    local line = trim(lines[j])
    if line == "" or line:sub(1, 1) == "#" then
      -- skip comment / blank
    elseif line:match("^@meta") then
      local body = line:gsub("^@meta%s*", "")
      for pair in (body .. ";"):gmatch("(.-);") do
        local k, v = pair:match("^%s*(.-)%s*=%s*(.-)%s*$")
        if k and k ~= "" then meta[k] = v end
      end
    else
      local id, name = line:match("^%[encounter%]%s+id=(%d+)%s*;%s*name=(.*)$")
      if id then
        current = { name = trim(name), reminders = {} }
        plans[tonumber(id)] = current
      else
        local f = splitFields(line)
        local tag = trim(f[1])
        if current and tag == "@phase" then
          -- phase row: @phase | index | label | kind? | (spellId|pct)? | occurrence?
          local idx = tonumber(f[2])
          if idx then
            local phase = { index = idx, label = trim(f[3] or "") }
            local kind = trim(f[4] or "")
            -- Hand-mirror of PHASE_TRIGGER_KINDS (lib/timeline/types/catalog.ts, the
            -- canonical list). Keep in sync when adding a kind - the site's round-trip
            -- + catalog vitest guard the TS/JSON side, this Lua list is manual.
            if kind == "cast" or kind == "removedebuff" or kind == "applybuff"
               or kind == "removebuff" or kind == "rotation-resume" or kind == "interrupt"
               or kind == "health" then
              local trig = { kind = kind }
              if kind == "health" then
                trig.pct = tonumber(f[5])
              elseif kind ~= "rotation-resume" then
                -- rotation-resume carries no spellId - detected live via the timeline.
                trig.spellId = tonumber(f[5])
                trig.occurrence = tonumber(f[6])
              end
              trig.unitCount = tonumber(f[7])
              phase.trigger = trig
            end
            current.phases = current.phases or {}
            current.phases[#current.phases + 1] = phase
          end
        elseif current and tag == "@boss" then
          -- boss ability row: @boss | time | spellId | type? | spellName?
          local sid = tonumber(f[3])
          if sid then
            local ms, pidx = Format.ParseTimeField(f[2] or "")
            local b = { timeMs = ms, spellId = sid }
            if pidx then b.phaseIndex = pidx end
            local ty = trim(f[4] or ""); if ty ~= "" then b.type = ty end
            local bn = trim(f[5] or ""); if bn ~= "" then b.spellName = bn end
            current.boss = current.boss or {}
            current.boss[#current.boss + 1] = b
          end
        elseif #f >= 3 and current then
          local spellId = tonumber(f[2])
          if spellId then
            local ms, pidx = Format.ParseTimeField(f[1] or "")
            local r = {
              timeMs = ms,
              spellId = spellId,
              player = trim(f[3]),
            }
            if pidx then r.phaseIndex = pidx end
            local cat = trim(f[4] or ""); if cat ~= "" then r.category = cat end
            local sn = trim(f[5] or ""); if sn ~= "" then r.spellName = sn end
            local al = trim(f[6] or ""); if al ~= "" then r.alert = al end
            current.reminders[#current.reminders + 1] = r
          end
        end
      end
    end
  end

  return plans, meta
end
