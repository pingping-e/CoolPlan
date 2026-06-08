-- Character loadout export.
--
-- Produces a `COOLPLAN-LOADOUT v1` string describing THIS character's equipped
-- gear, selected talent nodes, and combat stats — to paste into coolplan.team's
-- "compare me vs a top player" page. One-way export only (the website does the
-- import / diff); this addon never parses a loadout string back.
--
-- Byte-compatible with the site parser at lib/loadout/coolplan-loadout-format.ts.
-- Keep the two in sync. Row delimiter '|', multi-value ':'. Header lines are
-- emitted verbatim. The site sanitizer collapses stray '|'/':'/newlines, so we
-- only emit numbers and a sanitized name in @meta.

local _, ns = ...
local LoadoutExport = {}
ns.LoadoutExport = LoadoutExport

local MAGIC = "COOLPLAN-LOADOUT"
local VERSION = 1

-- ── helpers ─────────────────────────────────────────────────────────────────

local function trim(s)
  return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Name/meta values can only safely carry word chars + spaces. Strip the row /
-- multi delimiters and newlines defensively (mirrors the site's sanitize()).
local function sanitize(s)
  if s == nil then return "" end
  return (tostring(s):gsub("[|:\r\n]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- Join a list of positive integer ids with ':' (drops 0 / nil / non-positive).
local function joinMulti(ids)
  local out = {}
  for _, v in ipairs(ids or {}) do
    local n = tonumber(v)
    if n and n > 0 then out[#out + 1] = tostring(math.floor(n)) end
  end
  return table.concat(out, ":")
end

-- Build a '|'-delimited row, trimming trailing-empty optional fields but always
-- keeping the first `keep` fields (matches the site serializer's behaviour).
local function joinRow(fields, keep)
  local n = #fields
  while n > keep and (fields[n] == nil or fields[n] == "") do n = n - 1 end
  local row = {}
  for k = 1, n do
    local v = fields[k]
    -- Empty MIDDLE field -> "0", NOT "". An empty field renders as "||", which
    -- WoW's text engine treats as an escaped literal pipe and collapses to a
    -- single "|" on copy/paste — shifting every later field left (e.g. an item's
    -- enchant gets read as a gem, and the enchant goes missing). Trailing empties
    -- are already trimmed above, so "0" only ever lands in interior gaps where the
    -- parser reads it back as "none" (bonus/gems filter >0; enchant 0 = none).
    row[k] = (v == nil or v == "") and "0" or tostring(v)
  end
  return table.concat(row, "|")
end

-- ── class token map (Blizzard classFile → WCL no-space PascalCase) ────────────
-- UnitClass returns localized name + an UPPERCASE classFile token
-- ("DEATHKNIGHT"). WCL spells classes as no-space PascalCase ("DeathKnight").
local CLASS_TOKEN = {
  DEATHKNIGHT = "DeathKnight",
  DEMONHUNTER = "DemonHunter",
  DRUID       = "Druid",
  EVOKER      = "Evoker",
  HUNTER      = "Hunter",
  MAGE        = "Mage",
  MONK        = "Monk",
  PALADIN     = "Paladin",
  PRIEST      = "Priest",
  ROGUE       = "Rogue",
  SHAMAN      = "Shaman",
  WARLOCK     = "Warlock",
  WARRIOR     = "Warrior",
}

-- ── slot map (Blizzard INVSLOT 1-based → WCL 0-based) ─────────────────────────
-- Cosmetic slots (shirt=4, tabard=19) are intentionally excluded. Ranged(18)
-- no longer exists on retail; mainhand/offhand cover weapons.
--   INVSLOT_HEAD     1  -> 0    INVSLOT_HANDS    10 -> 9
--   INVSLOT_NECK     2  -> 1    INVSLOT_FINGER1  11 -> 10
--   INVSLOT_SHOULDER 3  -> 2    INVSLOT_FINGER2  12 -> 11
--   INVSLOT_CHEST    5  -> 4    INVSLOT_TRINKET1 13 -> 12
--   INVSLOT_WAIST    6  -> 5    INVSLOT_TRINKET2 14 -> 13
--   INVSLOT_LEGS     7  -> 6    INVSLOT_BACK     15 -> 14
--   INVSLOT_FEET     8  -> 7    INVSLOT_MAINHAND 16 -> 15
--   INVSLOT_WRIST    9  -> 8    INVSLOT_OFFHAND  17 -> 16
-- WCL slot = blizzSlot - 1 for every kept slot (chest 5->4 skips the shirt
-- gap at 4), so a single subtraction reproduces the table exactly.
local INV_SLOTS = { 1, 2, 3, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17 }

-- ── itemLink parsing ──────────────────────────────────────────────────────────
-- Retail item link payload (1-based field positions):
--   1 itemId         5 gem3         9  linkLevel      13 numBonus
--   2 enchant        6 gem4         10 specID         14 bonus1
--   3 gem1           7 suffix       11 modifiersMask  15 bonus2 ...
--   4 gem2           8 unique       12 itemContext
-- i.e. item:itemId:enchant:gem1:gem2:gem3:gem4:suffix:unique:linkLevel:specID:
--        modifiersMask:itemContext:numBonus:bonus1:...:bonusN:...
-- numBonus is the 13th field; the bonus ids follow it. Fields after the bonus
-- list (upgrade/crafting blocks) are ignored — we only need itemId, enchant,
-- gems, and the bonus ids.
local function parseItemLink(link)
  if not link then return nil end
  -- Capture the WHOLE payload (anything up to the closing pipe), NOT just
  -- digits/colons. CRAFTED items append a modifiers block that includes the
  -- crafter's GUID (e.g. "Player-970-0A1B2C3D") — letters that a
  -- `[%-%d:]+` class can't span, so the old pattern failed to match the link at
  -- all and the crafted slot (often the embellished waist/feet/wrist) was
  -- silently dropped from the export.
  local payload = link:match("|Hitem:([^|]+)|h") or link:match("^item:(.+)$")
  if not payload then return nil end

  -- Split on ':' keeping EVERY segment so indices stay aligned even past the
  -- numeric head (the crafter GUID etc. → 0). We only read the numeric head
  -- (itemId, enchant, gems, numBonus, bonus ids), which sits before that block.
  local parts = {}
  for n in (payload .. ":"):gmatch("(.-):") do
    parts[#parts + 1] = tonumber(n) or 0
  end

  local itemId  = parts[1] or 0
  local enchant = parts[2] or 0
  local gems = {}
  for g = 3, 6 do
    local gem = parts[g] or 0
    if gem > 0 then gems[#gems + 1] = gem end
  end

  -- numBonus lives at index 13 (itemId,enchant,4 gems,suffix,unique,linkLevel,
  -- specID,modifiersMask,itemContext = 12 fields → numBonus is the 13th); the
  -- bonus ids follow it.
  local bonusIDs = {}
  local numBonus = parts[13] or 0
  if numBonus and numBonus > 0 then
    for b = 1, numBonus do
      local bid = parts[13 + b]
      if bid and bid > 0 then bonusIDs[#bonusIDs + 1] = bid end
    end
  end

  return itemId, enchant, gems, bonusIDs
end

-- Current (scaled) item level for an equipped slot. Prefer the modern
-- ItemLocation API; fall back to GetDetailedItemLevelInfo on the link.
local function slotItemLevel(blizzSlot, link)
  if C_Item and ItemLocation and ItemLocation.CreateFromEquipmentSlot then
    local loc = ItemLocation:CreateFromEquipmentSlot(blizzSlot)
    if loc and C_Item.DoesItemExist and C_Item.DoesItemExist(loc) then
      local ilvl = C_Item.GetCurrentItemLevel(loc)
      if ilvl and ilvl > 0 then return math.floor(ilvl) end
    end
  end
  if link and GetDetailedItemLevelInfo then
    local ilvl = GetDetailedItemLevelInfo(link)
    if ilvl and ilvl > 0 then return math.floor(ilvl) end
  end
  return 0
end

-- ── gather: gear ──────────────────────────────────────────────────────────────
function LoadoutExport.GatherGear()
  local rows = {}
  for _, blizzSlot in ipairs(INV_SLOTS) do
    local link = GetInventoryItemLink and GetInventoryItemLink("player", blizzSlot)
    if link then
      local itemId, enchant, gems, bonusIDs = parseItemLink(link)
      if itemId and itemId > 0 then
        local wclSlot = blizzSlot - 1 -- see INV_SLOTS note: kept slots are contiguous-1
        rows[#rows + 1] = {
          slot    = wclSlot,
          id      = itemId,
          ilvl    = slotItemLevel(blizzSlot, link),
          bonus   = joinMulti(bonusIDs),
          gems    = joinMulti(gems),
          enchant = (enchant and enchant > 0) and tostring(enchant) or "",
        }
      end
    end
  end
  table.sort(rows, function(a, b) return a.slot < b.slot end)
  return rows
end

-- ── gather: talents (C_Traits node enumeration) ───────────────────────────────
-- Walk the active config's trees, emit every purchased node as
-- `nodeID|spellId|rank`. nodeID is the Blizzard/C_Traits node id, which equals
-- WCL's talentTree[].nodeID (the diff matches on nodeID). spellId is the active
-- entry's definition spellId (display only; 0 if unresolved).
function LoadoutExport.GatherTalents()
  local rows = {}
  if not (C_ClassTalents and C_Traits and C_ClassTalents.GetActiveConfigID) then
    return rows
  end
  local configID = C_ClassTalents.GetActiveConfigID()
  if not configID then return rows end

  local configInfo = C_Traits.GetConfigInfo(configID)
  if not configInfo or not configInfo.treeIDs then return rows end

  -- The ACTIVE hero subtree. GetTreeNodes returns every hero subtree's nodes,
  -- and unselected subtrees' nodes can still report rank > 0, so without this we
  -- export TWO hero trees (e.g. Master of Harmony AND Conduit). Keep only the
  -- active subtree's hero nodes; class/spec nodes have no subTreeID.
  local activeSubTree
  if C_ClassTalents.GetActiveHeroTalentSpec then
    activeSubTree = C_ClassTalents.GetActiveHeroTalentSpec()
  end
  -- GetActiveHeroTalentSpec can be nil transiently (right after /reload or zone-in).
  -- With no active subtree the filter below would let BOTH hero subtrees through →
  -- the export includes the off-spec hero tree (false diff on the website). Derive
  -- it from the picks: the hero subTreeID with the most purchased nodes is the one
  -- the player actually chose.
  if not activeSubTree then
    local counts, best, bestN = {}, nil, 0
    for _, treeID in ipairs(configInfo.treeIDs) do
      for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
        local node = C_Traits.GetNodeInfo(configID, nodeID)
        local sub = node and node.subTreeID
        local rank = node and (node.activeRank or node.ranksPurchased or 0)
        if sub and sub > 0 and rank and rank > 0 then
          counts[sub] = (counts[sub] or 0) + 1
          if counts[sub] > bestN then best, bestN = sub, counts[sub] end
        end
      end
    end
    activeSubTree = best
  end

  local seen = {}
  for _, treeID in ipairs(configInfo.treeIDs) do
    local nodes = C_Traits.GetTreeNodes(treeID)
    for _, nodeID in ipairs(nodes or {}) do
      if not seen[nodeID] then
        local node = C_Traits.GetNodeInfo(configID, nodeID)
        -- Drop hero nodes that belong to a NON-active subtree.
        local sub = node and node.subTreeID
        local wrongHeroTree = sub and sub > 0 and activeSubTree and sub ~= activeSubTree
        if node and not wrongHeroTree then
          local rank = node.activeRank or node.ranksPurchased or 0
          if rank and rank > 0 then
            seen[nodeID] = true
            -- resolve the active entry's spellId (display only)
            local spellId = 0
            local activeEntry = node.activeEntry
            local entryID = activeEntry and activeEntry.entryID
            if not entryID and node.entryIDs and node.entryIDs[1] then
              entryID = node.entryIDs[1]
            end
            if entryID then
              local entry = C_Traits.GetEntryInfo(configID, entryID)
              local defID = entry and entry.definitionID
              if defID then
                local def = C_Traits.GetDefinitionInfo(defID)
                if def and def.spellID then spellId = def.spellID end
              end
            end
            rows[#rows + 1] = { nodeID = nodeID, id = spellId, rank = rank }
          end
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.nodeID < b.nodeID end)
  return rows
end

-- ── gather: stats ─────────────────────────────────────────────────────────────
-- Labels match the site's canonical stat keys (Strength/Agility/Intellect/
-- Stamina/Crit/Haste/Mastery/Versatility, + Dodge/Parry/Armor for tanks).
-- Values are integer combat ratings / primary-stat amounts. The diff only shows
-- deltas, so exact units matter less than producing the same label both sides.
function LoadoutExport.GatherStats()
  local rows = {}
  local function add(label, value)
    local n = tonumber(value)
    if n then rows[#rows + 1] = { label = label, value = math.floor(n + 0.5) } end
  end

  -- Primary + stamina (effective amounts). UnitStat indices: 1=Str 2=Agi 3=Sta
  -- 4=Int. The "effective" (2nd) return includes buffs/gear.
  if UnitStat then
    local _, eStr = UnitStat("player", 1)
    local _, eAgi = UnitStat("player", 2)
    local _, eSta = UnitStat("player", 3)
    local _, eInt = UnitStat("player", 4)
    -- Emit only the meaningful primary stat(s) + stamina. We include all so the
    -- site can pick; zero/low values are harmless (diff is per-label).
    add("Strength", eStr)
    add("Agility", eAgi)
    add("Intellect", eInt)
    add("Stamina", eSta)
  end

  -- Secondary ratings (integer rating, not %). CR_* constants on retail:
  --   CR_CRIT_SPELL/MELEE/RANGED share a value; melee is representative.
  if GetCombatRating then
    local CRIT  = CR_CRIT_MELEE or 10
    local HASTE = CR_HASTE_MELEE or 18
    local MAST  = CR_MASTERY or 26
    local VERS  = CR_VERSATILITY_DAMAGE_DONE or 29
    add("Crit", GetCombatRating(CRIT))
    add("Haste", GetCombatRating(HASTE))
    add("Mastery", GetCombatRating(MAST))
    add("Versatility", GetCombatRating(VERS))

    -- Tank avoidance ratings (only meaningful for tanks; emitted when nonzero).
    local DODGE = CR_DODGE or 3
    local PARRY = CR_PARRY or 4
    local dodge = GetCombatRating(DODGE)
    local parry = GetCombatRating(PARRY)
    if dodge and dodge > 0 then add("Dodge", dodge) end
    if parry and parry > 0 then add("Parry", parry) end

    -- Tertiary ratings (Leech / Avoidance / Speed). Use the named CR_* globals
    -- (present on retail); emit always so they line up with WCL's stat block in
    -- the site comparison even when 0.
    if CR_LIFESTEAL then add("Leech", GetCombatRating(CR_LIFESTEAL)) end
    if CR_AVOIDANCE then add("Avoidance", GetCombatRating(CR_AVOIDANCE)) end
    if CR_SPEED then add("Speed", GetCombatRating(CR_SPEED)) end
  end

  -- Armor (effective armor amount).
  if UnitArmor then
    local base, effective = UnitArmor("player")
    local armor = effective or base
    if armor and armor > 0 then add("Armor", armor) end
  end

  table.sort(rows, function(a, b) return a.label < b.label end)
  return rows
end

-- ── meta ──────────────────────────────────────────────────────────────────────
function LoadoutExport.GatherMeta()
  local name = (UnitName and UnitName("player")) or "Unknown"

  local classToken = ""
  if UnitClass then
    local _, classFile = UnitClass("player")
    classToken = CLASS_TOKEN[classFile or ""] or (classFile and trim(classFile)) or ""
  end

  local spec, specID = "", 0
  if GetSpecialization and GetSpecializationInfo then
    local idx = GetSpecialization()
    if idx then
      -- GetSpecializationInfo returns: id, name, description, icon, role, ...
      local sid, specName = GetSpecializationInfo(idx)
      if specName then spec = trim(specName) end
      if sid then specID = sid end
    end
  end

  local ilvl = 0
  if GetAverageItemLevel then
    local _, equipped = GetAverageItemLevel()
    if equipped and equipped > 0 then ilvl = math.floor(equipped + 0.5) end
  end

  return { name = name, class = classToken, spec = spec, specID = specID, ilvl = ilvl }
end

-- ── serialize ──────────────────────────────────────────────────────────────────
function LoadoutExport.Build()
  local lines = { MAGIC .. " v" .. VERSION }

  local meta = LoadoutExport.GatherMeta()
  local metaParts = {}
  metaParts[#metaParts + 1] = "name=" .. sanitize(meta.name)
  if meta.class ~= "" then metaParts[#metaParts + 1] = "class=" .. sanitize(meta.class) end
  if meta.spec ~= "" then metaParts[#metaParts + 1] = "spec=" .. sanitize(meta.spec) end
  -- specID is the locale-proof spec key the site matches on (spec NAMES export
  -- in the client locale and won't match WCL's English names).
  if meta.specID and meta.specID > 0 then
    metaParts[#metaParts + 1] = "specID=" .. tostring(meta.specID)
  end
  metaParts[#metaParts + 1] = "ilvl=" .. tostring(meta.ilvl or 0)
  -- "; " separator matches the site serializer (serializeImportedLoadout) so the
  -- string round-trips byte-identically; the parser tolerates either spacing.
  lines[#lines + 1] = "@meta " .. table.concat(metaParts, "; ")

  lines[#lines + 1] = "@gear slot|id|ilvl|bonus|gems|ench"
  for _, g in ipairs(LoadoutExport.GatherGear()) do
    lines[#lines + 1] = joinRow({ g.slot, g.id, g.ilvl, g.bonus, g.gems, g.enchant }, 3)
  end

  lines[#lines + 1] = "@talent nodeID|id|rank"
  for _, t in ipairs(LoadoutExport.GatherTalents()) do
    lines[#lines + 1] = joinRow({ t.nodeID, t.id, t.rank }, 3)
  end

  local stats = LoadoutExport.GatherStats()
  if #stats > 0 then
    lines[#lines + 1] = "@stat label|value"
    for _, s in ipairs(stats) do
      lines[#lines + 1] = joinRow({ sanitize(s.label), s.value }, 2)
    end
  end

  return table.concat(lines, "\n")
end

-- ── UI entry: dump into the Import/Export box for Ctrl-C ──────────────────────
function LoadoutExport.Export()
  local str = LoadoutExport.Build()
  if ns.Editor and ns.Editor.SetText then
    -- Opens the Import/Export page, fills + highlights the multiline box, and
    -- sets a "Ctrl-C to copy" status. Reuses the existing copy UX.
    ns.Editor.SetText(str)
  elseif ns.Print then
    -- No editor available (shouldn't happen): print so it's still copyable.
    ns.Print("character export (copy from chat is lossy; open /coolplan):")
    print(str)
  end
  return str
end
