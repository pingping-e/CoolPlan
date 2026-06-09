-- Import / Export page. The human-readable format means the multiline box IS
-- the editor: paste a plan from coolplan.team, optionally name it, and Load to
-- ADD it to that encounter's saved list (existing plans are kept). The only
-- export here is "Export current character" (gear/talents → website compare);
-- plan export/share lives in the Manager (per-plan Export + Send).
-- Embedded into the Window shell via Editor.BuildPage(host).

local _, ns = ...
local Editor = {}
ns.Editor = Editor

local page  -- the content host (set by BuildPage)

local function makeButton(parent, text, w)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(w, 22)
  b:SetText(text)
  return b
end

function Editor.BuildPage(host)
  page = host

  local help = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  help:SetPoint("TOPLEFT", 8, -8)
  help:SetPoint("TOPRIGHT", -8, -8)
  help:SetJustifyH("LEFT")
  help:SetText("Paste a plan from coolplan.team and Load to add it (name optional, edits allowed). Export current character copies your gear/talents for the website compare page.")

  local sf = CreateFrame("ScrollFrame", "CoolPlanEditorScroll", host, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 8, -46)
  sf:SetPoint("BOTTOMRIGHT", -28, 86)

  local eb = CreateFrame("EditBox", "CoolPlanEditorBox", sf)
  eb:SetMultiLine(true)
  -- Use the SAME FontObject the picker/timeline use (GameFontHighlightSmall):
  -- a FontObject carries the client's glyph FALLBACK chain, so characters missing
  -- from the primary .ttf (e.g. simplified-Chinese on a KR client) fall back to a
  -- secondary font and render. SetFont(path,...) does NOT keep that fallback, so
  -- the same 2002.TTF showed boxes in the EditBox while the picker rendered fine.
  eb:SetFontObject(GameFontHighlightSmall)
  eb:SetAutoFocus(false)
  eb:EnableMouse(true)
  -- Read as a real input: pad the text off the border and make the caret blink
  -- clearly when focused (so it's obvious you can type/paste here).
  if eb.SetTextInsets then eb:SetTextInsets(6, 6, 6, 6) end
  if eb.SetBlinkSpeed then eb:SetBlinkSpeed(0.5) end
  -- The box IS the editor: make the EditBox fill the scroll viewport (so the
  -- whole dark area is one clickable input surface) and grow taller as text is
  -- added. Width tracks the scroll frame; height = max(viewport, content).
  -- Plans can be many KB; lift the letter cap so a long paste isn't truncated.
  -- (Do NOT call SetMaxBytes(0) — it was blocking input on some clients.)
  if eb.SetMaxLetters then eb:SetMaxLetters(0) end

  -- size the editbox to the scroll viewport; called on build, resize, text edit.
  local function fitEditBox()
    local vw = (sf:GetWidth() or 0)
    local vh = (sf:GetHeight() or 0)
    if vw < 50 then vw = 540 end
    if vh < 50 then vh = 340 end
    eb:SetWidth(vw)
    -- never shorter than the viewport so the empty box is a big click target;
    -- grow with the text's natural string height when it overflows.
    local needed = vh
    local sh = eb.GetStringHeight and eb:GetStringHeight() or 0
    if sh and sh + 8 > needed then needed = sh + 8 end
    eb:SetHeight(needed)
  end

  eb:SetScript("OnEscapePressed", ns.wrap(function(self) self:ClearFocus() end))
  eb:SetScript("OnTextChanged", ns.wrap(function()
    fitEditBox()
    sf:UpdateScrollChildRect()
  end))
  sf:SetScrollChild(eb)
  fitEditBox()
  -- Clicking anywhere in the scroll area (including empty space below the text)
  -- focuses the box, so typing / Ctrl-V always lands. The EditBox now fills the
  -- viewport, so a click on it focuses directly too.
  sf:EnableMouse(true)
  sf:SetScript("OnMouseDown", ns.wrap(function() eb:SetFocus() end))
  -- keep the input area filling the box when the window is resized
  host._onResize = ns.wrap(function() fitEditBox(); sf:UpdateScrollChildRect() end)
  host.editbox = eb

  -- Placeholder hint shown only while the box is empty & unfocused, so it's
  -- obvious this is where you paste. Cleared the moment you focus or type.
  local placeholder = eb:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  placeholder:SetPoint("TOPLEFT", 7, -7)
  placeholder:SetText("Paste a plan from coolplan.team here, or click \"Export current character\"...")
  local function syncPlaceholder()
    placeholder:SetShown((eb:GetText() or "") == "" and not eb:HasFocus())
  end
  eb:HookScript("OnTextChanged", ns.wrap(syncPlaceholder))
  eb:HookScript("OnEditFocusGained", ns.wrap(syncPlaceholder))
  eb:HookScript("OnEditFocusLost", ns.wrap(syncPlaceholder))
  syncPlaceholder()

  local status = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", 8, 50)
  status:SetPoint("BOTTOMRIGHT", -8, 50)
  status:SetJustifyH("LEFT")
  host.status = status

  -- Bottom action row. One baseline (ROW_Y) for the name field and all three
  -- buttons so they read as a single, aligned strip. Two logical groups:
  --   LEFT  = the import unit: [Plan name: ___] [Load Plans]
  --   RIGHT = the rest:        [Clear Box] [Export current character]
  -- The empty middle is the gap between the two groups.
  local ROW_Y = 18
  local GAP = 10

  -- LEFT group: name field (box at a fixed x so its label has room) + Load.
  local nameBox = CreateFrame("EditBox", nil, host, "InputBoxTemplate")
  nameBox:SetSize(150, 22)
  nameBox:SetPoint("BOTTOMLEFT", 78, ROW_Y)
  nameBox:SetAutoFocus(false)
  nameBox:SetScript("OnEscapePressed", ns.wrap(function(self) self:ClearFocus() end))
  host.nameBox = nameBox

  local nameLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nameLabel:SetPoint("RIGHT", nameBox, "LEFT", -8, 0) -- vertically centered on the box
  nameLabel:SetText("Plan name:")

  -- Load sits right after the name box → "name this, then load" reads as a unit.
  local loadBtn = makeButton(host, "Load Plans", 100)
  loadBtn:SetPoint("BOTTOMLEFT", nameBox, "BOTTOMRIGHT", GAP + 4, 0)
  loadBtn:SetScript("OnClick", ns.wrap(function()
    local raw = host.editbox:GetText()
    -- WoW EditBoxes can store a typed/pasted "|" as a doubled "||" (the engine
    -- preserves it so it isn't read as a |c / |r / |T… escape). Our row
    -- delimiter is a single "|", so collapse doubled pipes before parsing.
    -- Harmless for clean strings (the format never contains "||").
    local text = raw:gsub("||", "|")
    local plans, _, err = ns.Format.Parse(text)
    if not plans then
      host.status:SetText("|cffff5555" .. (err or "parse error") .. "|r")
      return
    end
    local typed = host.nameBox:GetText()
    if typed == "" then typed = nil end

    local added, nRem, nBoss = 0, 0, 0
    for id, parsed in pairs(plans) do
      -- a typed name applies to every imported encounter (so a whole-dungeon
      -- import can be named once, e.g. "raid night"); nil falls back to "Plan N".
      local label = typed
      nRem = nRem + (parsed.reminders and #parsed.reminders or 0)
      nBoss = nBoss + (parsed.boss and #parsed.boss or 0)
      -- boss abilities + phase table ride along on the same plan (one body)
      local idx = ns.DB.AddPlan(id, parsed.name, label, parsed.reminders, parsed.boss, parsed.phases)
      if idx ~= 0 then added = added + 1 end
    end
    host.nameBox:SetText("")
    if nRem == 0 and nBoss == 0 then
      -- Encounters parsed but no cooldown rows. Surface the first data row
      -- exactly as stored (pipes shown literally so chat doesn't eat them) to
      -- pin down any remaining delimiter mangling by the EditBox.
      local sample
      for line in (raw .. "\n"):gmatch("(.-)\r?\n") do
        local t = (line:gsub("^%s+", ""):gsub("%s+$", ""))
        if t:match("^%d") then sample = t; break end
      end
      if sample then
        local _, pipes = sample:gsub("|", "|")
        ns.Print(("import debug: first row has %d pipe(s), len %d: %s"):format(
          pipes, #sample, (sample:gsub("|", "||"))))
      end
      host.status:SetText(("|cffffcc00Added %d plan(s) but 0 cooldowns parsed (text length %d — not truncated). See chat for a diagnostic line.|r"):format(
        added, #raw))
    else
      host.status:SetText(("|cff66ff66Added %d plan(s): %d cooldowns, %d boss cues.|r"):format(
        added, nRem, nBoss))
    end
    if ns.Manager then ns.Manager.Refresh() end
    if ns.Timeline then ns.Timeline.Refresh() end
  end))

  -- RIGHT group, anchored to the bottom-right corner and growing leftward.
  -- "Export current character" is the page's one true export (gear/talents →
  -- coolplan.team compare; Send can't do this), so it takes the corner. Plan
  -- export-as-string was removed here — it lives in the Manager (per-plan Export)
  -- + Send. "Clear Box" (a textbox utility) sits just left of it.
  local charBtn = makeButton(host, "Export current character", 175)
  charBtn:SetPoint("BOTTOMRIGHT", -8, ROW_Y)
  charBtn:SetScript("OnClick", ns.wrap(function()
    if ns.LoadoutExport then
      ns.LoadoutExport.Export() -- fills + highlights the paste box
    else
      host.status:SetText("|cffff5555loadout export unavailable.|r")
    end
  end))

  local clearBtn = makeButton(host, "Clear Box", 90)
  clearBtn:SetPoint("BOTTOMRIGHT", charBtn, "BOTTOMLEFT", -GAP, 0)
  clearBtn:SetScript("OnClick", ns.wrap(function()
    host.editbox:SetText("")
    host.status:SetText("")
  end))

  if ns.Style then
    ns.Style.Apply(host)
    local C = ns.Style.colors
    -- The multiline box is a bare EditBox (no template art). Wrap the scroll
    -- area in a bordered, dark inset panel so it clearly reads as an input
    -- field (vs. just text on the page), and light the border brand-accent
    -- while it's focused — together with the blinking caret that signals "type
    -- here".
    local boxFrame = CreateFrame(
      "Frame", nil, host, BackdropTemplateMixin and "BackdropTemplate" or nil)
    boxFrame:SetPoint("TOPLEFT", sf, "TOPLEFT", -5, 5)
    -- sf stops short of the right edge to clear the scrollbar; extend the border
    -- past it so the whole input (incl. scrollbar gutter) sits inside the frame.
    boxFrame:SetPoint("BOTTOMRIGHT", sf, "BOTTOMRIGHT", 22, -5)
    if sf.GetFrameLevel then
      boxFrame:SetFrameLevel(math.max(0, sf:GetFrameLevel() - 1))
    end
    ns.Style.InsetPanel(boxFrame, 0.92)
    host._boxFrame = boxFrame

    local function setBorder(focused)
      if not boxFrame.SetBackdropBorderColor then return end
      local b = focused and C.accent or C.border
      boxFrame:SetBackdropBorderColor(b[1], b[2], b[3], 1)
    end
    eb:HookScript("OnEditFocusGained", ns.wrap(function() setBorder(true) end))
    eb:HookScript("OnEditFocusLost", ns.wrap(function() setBorder(false) end))

    if eb.SetTextColor then eb:SetTextColor(C.text[1], C.text[2], C.text[3]) end
    if status.SetTextColor then status:SetTextColor(C.subtle[1], C.subtle[2], C.subtle[3]) end
  end
end

-- Open the Import/Export page and drop a string into the box (used by the
-- manager's per-plan export). Builds the page lazily via the shell first.
function Editor.SetText(str)
  ns.Window.Open("import")
  if page and page.editbox then
    page.editbox:SetText(str or "")
    page.editbox:SetFocus()
    page.editbox:HighlightText()
    page.status:SetText("Exported. Ctrl-C to copy.")
  end
end

function Editor.Open()
  ns.Window.Open("import")
end

ns.Window.RegisterPage("import", "Import / Export", Editor.BuildPage)
