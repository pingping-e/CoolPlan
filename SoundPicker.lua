-- Sound selection on top of the generic ns.Picker. Backed by LibSharedMedia-3.0
-- so the list matches the shared sound registry MRT / BigWigs / WeakAuras / the
-- SharedMedia addon all contribute to. "Raid Warning" is pinned as the default
-- (played via SOUNDKIT in the hybrid Reminders.PlaySound, so it works even with
-- no LSM contributors installed).

local _, ns = ...
local SoundPicker = {}
ns.SoundPicker = SoundPicker

local LSM = LibStub and LibStub("LibSharedMedia-3.0", true)

-- A small baseline so the list is never empty on clients without other media
-- addons. Most players also run SharedMedia/BigWigs which register hundreds more
-- — those appear automatically (shared registry).
if LSM then
  LSM:Register("sound", "Alarm Clock", "Sound\\Interface\\AlarmClockWarning3.ogg")
  LSM:Register("sound", "Ready Check", "Sound\\Interface\\ReadyCheck.ogg")
  LSM:Register("sound", "Bell Toll",   "Sound\\Doodad\\BellTollAlliance.ogg")
end

-- "Raid Warning" pinned first (value = SOUNDKIT name), then every LSM sound,
-- alphabetical.
local function buildSoundList()
  local items = { { text = "Raid Warning", value = "RAID_WARNING" } }
  if LSM then
    local names = {}
    for _, name in ipairs(LSM:List("sound")) do
      if name ~= "None" and strlower(name) ~= "raid warning" then
        names[#names + 1] = name
      end
    end
    table.sort(names, function(a, b) return strlower(a) < strlower(b) end)
    for _, n in ipairs(names) do items[#items + 1] = { text = n, value = n } end
  end
  return items
end

-- Open anchored under `anchor`. `onPick(value)` fires on each click (live
-- preview); the popup stays open so the user can audition several sounds.
function SoundPicker.Show(anchor, current, onPick)
  ns.Picker.Open(anchor, {
    title = "Sound",
    width = 244,
    search = true,
    keepOpen = true,
    current = current,
    getItems = buildSoundList,
    onPick = onPick,
  })
end

function SoundPicker.IsShown() return ns.Picker.IsShown() end
function SoundPicker.Hide() ns.Picker.Hide() end
