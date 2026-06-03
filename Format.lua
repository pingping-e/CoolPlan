-- CoolPlan v1 plan format: parse + serialize.
-- Byte-for-byte mirror of the website's lib/export/coolplan-format.ts so plans
-- round-trip between coolplan.team and this addon. Keep the two in sync.

local _, ns = ...
local Format = {}
ns.Format = Format

local MAGIC = "COOLPLAN"
local VERSION = 1
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

-- plans = { [encounterID] = { name = "...", reminders = { {timeMs, spellId, player, category?, spellName?, alert?}, ... } } }
function Format.Serialize(plans, meta)
  local lines = { MAGIC .. " v" .. VERSION }

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

    local rs = {}
    for _, r in ipairs(enc.reminders) do rs[#rs + 1] = r end
    table.sort(rs, function(a, b) return a.timeMs < b.timeMs end)

    for _, r in ipairs(rs) do
      local fields = {
        Format.FormatTime(r.timeMs),
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
      table.sort(bs, function(a, b) return a.timeMs < b.timeMs end)
      for _, b in ipairs(bs) do
        local fields = { "@boss", Format.FormatTime(b.timeMs), tostring(b.spellId), sanitize(b.type), sanitize(b.spellName) }
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
  if ver ~= VERSION then
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
        if current and trim(f[1]) == "@boss" then
          -- boss ability row: @boss | time | spellId | type? | spellName?
          local sid = tonumber(f[3])
          if sid then
            local b = { timeMs = Format.ParseTime(f[2]), spellId = sid }
            local ty = trim(f[4] or ""); if ty ~= "" then b.type = ty end
            local bn = trim(f[5] or ""); if bn ~= "" then b.spellName = bn end
            current.boss = current.boss or {}
            current.boss[#current.boss + 1] = b
          end
        elseif #f >= 3 and current then
          local spellId = tonumber(f[2])
          if spellId then
            local r = {
              timeMs = Format.ParseTime(f[1]),
              spellId = spellId,
              player = trim(f[3]),
            }
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
