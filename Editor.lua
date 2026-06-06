-- Import / Export page. The human-readable format means the multiline box IS
-- the editor: paste a plan from coolplan.team, optionally name it, and Load to
-- ADD it to that encounter's saved list (existing plans are kept). Export All
-- dumps each encounter's active plan back out.
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
  help:SetText("Paste a plan from coolplan.team, optionally name it, and Load to ADD it to that boss's saved list (existing plans are kept). You can edit times / spell IDs directly. Export All dumps each boss's active plan.")

  local sf = CreateFrame("ScrollFrame", "CoolPlanEditorScroll", host, "UIPanelScrollFrameTemplate")
  sf:SetPoint("TOPLEFT", 8, -46)
  sf:SetPoint("BOTTOMRIGHT", -28, 86)

  local eb = CreateFrame("EditBox", "CoolPlanEditorBox", sf)
  eb:SetMultiLine(true)
  eb:SetFontObject(ChatFontNormal)
  eb:SetAutoFocus(false)
  eb:EnableMouse(true)
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

  local status = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  status:SetPoint("BOTTOMLEFT", 8, 50)
  status:SetPoint("BOTTOMRIGHT", -8, 50)
  status:SetJustifyH("LEFT")
  host.status = status

  -- name field (bottom-left)
  local nameLabel = host:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  nameLabel:SetPoint("BOTTOMLEFT", 8, 24)
  nameLabel:SetText("Plan name:")
  local nameBox = CreateFrame("EditBox", nil, host, "InputBoxTemplate")
  nameBox:SetSize(150, 20)
  nameBox:SetPoint("LEFT", nameLabel, "RIGHT", 8, 0)
  nameBox:SetAutoFocus(false)
  nameBox:SetScript("OnEscapePressed", ns.wrap(function(self) self:ClearFocus() end))
  host.nameBox = nameBox

  -- buttons (bottom-right)
  local loadBtn = makeButton(host, "Load Plans", 100)
  loadBtn:SetPoint("BOTTOMRIGHT", -8, 18)
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
    -- count encounters so a typed name only applies to a single-encounter import
    local nEnc = 0
    for _ in pairs(plans) do nEnc = nEnc + 1 end
    local typed = host.nameBox:GetText()
    if typed == "" then typed = nil end

    local added, nRem, nBoss = 0, 0, 0
    for id, parsed in pairs(plans) do
      local label = (nEnc == 1) and typed or nil
      nRem = nRem + (parsed.reminders and #parsed.reminders or 0)
      nBoss = nBoss + (parsed.boss and #parsed.boss or 0)
      -- boss abilities ride along on the same plan (one body)
      local idx = ns.DB.AddPlan(id, parsed.name, label, parsed.reminders, parsed.boss)
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

  local exportBtn = makeButton(host, "Export All", 100)
  exportBtn:SetPoint("RIGHT", loadBtn, "LEFT", -8, 0)
  exportBtn:SetScript("OnClick", ns.wrap(function()
    local str = ns.Format.Serialize(ns.DB.ToSerializable(), { source = "addon" })
    host.editbox:SetText(str)
    host.editbox:SetFocus()
    host.editbox:HighlightText()
    host.status:SetText("Exported active plans. Ctrl-C to copy.")
  end))

  local clearBtn = makeButton(host, "Clear Box", 90)
  clearBtn:SetPoint("RIGHT", exportBtn, "LEFT", -8, 0)
  clearBtn:SetScript("OnClick", ns.wrap(function()
    host.editbox:SetText("")
    host.status:SetText("")
  end))

  if ns.Style then
    ns.Style.Apply(host)
    -- the multiline box is a bare EditBox (no template art): give the scroll
    -- area a flat dark panel so it reads as an input surface.
    local C = ns.Style.colors
    local boxbg = sf:CreateTexture(nil, "BACKGROUND")
    boxbg:SetPoint("TOPLEFT", -2, 2)
    boxbg:SetPoint("BOTTOMRIGHT", 2, -2)
    boxbg:SetColorTexture(C.bg[1], C.bg[2], C.bg[3], 0.92)
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
