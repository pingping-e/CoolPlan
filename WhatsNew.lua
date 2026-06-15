-- WhatsNew.lua - a one-time "version update" notice shown on the first login after
-- an update. Self-built frame (NO StaticPopup - that path has a taint history),
-- mirroring Comm's proven pattern. HARD REQUIREMENT: must NEVER throw or break
-- login - every entry point is pcall-guarded, so total failure is a silent no-op.
--
-- One language at a time with an EN/한국어 toggle (default = client locale). Stacking
-- both at once was cluttered. The "re-export your plans" step is emphasized because
-- the fix does NOT apply to already-imported plans until they are re-exported.
local _, ns = ...
local WhatsNew = {}
ns.WhatsNew = WhatsNew

-- Bump ONLY when there is news to show. Login compares it to CoolPlanDB.lastWhatsNew;
-- equal → nothing shows. A routine addon bump with no WhatsNew change stays silent.
WhatsNew.version = "1.6.0"

-- Per-language body. Color codes (|c…|r) render in FontStrings. The "Important" line
-- is gold so the re-export requirement stands out.
local BODY = {
  en = table.concat({
    "Version update: the 6 phase-shifting bosses now work correctly with your cooldown plan.",
    "",
    "Affected bosses:",
    "|cffffcc00Commander Kroluk|r (Windrunner Spire)  /  |cffffcc00Crawth|r (Algeth'ar Academy)  /  |cffffcc00Gemellus|r (Magisters' Terrace)",
    "|cffffcc00Lothraxion|r (Nexus-Point Xenas)  /  |cffffcc00L'ura|r (Seat of the Triumvirate)  /  |cffffcc00Vordaza|r (Maisara Caverns)",
    "",
    "|cffffcc00Important:|r only these bosses' plans need a refresh from the site (re-grabbing all is fine too, other bosses are not affected).",
    "",
    "Not working, or you see an error? Tell us on Discord and we will fix it.",
    "",
    "|cff66b3ffcoolplan.team|r",
  }, "\n"),
  ko = table.concat({
    "버전 업데이트: 6종 가변형 페이즈 보스도 이제 플랜대로 정확히 작동합니다.",
    "",
    "적용 보스:",
    "|cffffcc00지휘관 크롤루크|r (윈드러너 첨탑)  /  |cffffcc00크로스|r (알게타르 대학)  /  |cffffcc00제멜루스|r (마법학자의 정원)",
    "|cffffcc00로스락시온|r (공결탑 제나스)  /  |cffffcc00르우라|r (삼두정의 권좌)  /  |cffffcc00보르다자|r (마이사라 동굴)",
    "",
    "|cffffcc00중요:|r 해당 보스의 플랜만 새로 받으면 됩니다 (전체를 받아도 무방, 다른 보스는 영향 없음).",
    "",
    "제대로 동작하지 않거나 오류가 발생하면 디스코드로 알려 주세요. 신속히 수정하겠습니다.",
    "",
    "|cff66b3ffcoolplan.team|r",
  }, "\n"),
}

local WIDTH = 760
local frame, lang

local function defaultLang()
  local ok, loc = pcall(GetLocale)
  if ok and loc == "koKR" then return "ko" end
  return "en"
end

-- Set the displayed language: swap body text, relabel the toggle (it shows the OTHER
-- language), and re-fit the frame to the content. The frame WIDTH auto-fits the widest
-- line so the shorter language (KO) isn't padded with a big right margin. Measured at a
-- wide width so nothing wraps → GetStringWidth is the widest line's natural width;
-- clamped to a sane range and run inside the callers' pcall, so it can't misbehave.
local function setLang(l)
  lang = (l == "ko") and "ko" or "en"
  if not frame then return end
  local body = frame.body
  body:SetWidth(WIDTH - 40)
  body:SetText(BODY[lang] or "")
  local natW = body:GetStringWidth() or (WIDTH - 40)
  local contentW = math.max(360, math.min(natW + 2, WIDTH - 40))
  body:SetWidth(contentW)
  frame:SetWidth(contentW + 40)
  frame.toggle:SetText(lang == "en" and "한국어" or "English")
  local bh = body:GetStringHeight() or 240
  frame:SetHeight(56 + bh + 56)
end

local function build()
  frame = CreateFrame("Frame", "CoolPlanWhatsNew", UIParent, "BackdropTemplate")
  frame:SetSize(WIDTH, 220)
  frame:SetPoint("CENTER", 0, 80)
  frame:SetFrameStrata("FULLSCREEN_DIALOG")
  frame:SetMovable(true)
  frame:EnableMouse(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", frame.StartMoving)
  frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
  if ns.Style and ns.Style.Panel then
    ns.Style.Panel(frame, 0.98)
  elseif frame.SetBackdrop then
    frame:SetBackdrop({
      bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
      edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
      tile = true, tileSize = 32, edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
  end

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  title:SetPoint("TOPLEFT", 20, -16)
  title:SetText("|cff66b3ffCoolPlan|r  |cff888888v" .. WhatsNew.version .. "|r")

  -- EN/한국어 toggle (top-right). Shows the language you'd switch TO.
  local toggle = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  toggle:SetSize(96, 22)
  toggle:SetPoint("TOPRIGHT", -16, -14)
  toggle:SetScript("OnClick", (ns.wrap or function(f) return f end)(function()
    setLang(lang == "en" and "ko" or "en")
  end))
  frame.toggle = toggle

  local body = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  body:SetPoint("TOPLEFT", 20, -52)
  body:SetWidth(WIDTH - 40)
  body:SetJustifyH("LEFT")
  body:SetJustifyV("TOP")
  body:SetSpacing(3)
  frame.body = body

  local ok = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  ok:SetSize(120, 24)
  ok:SetText("OK")
  ok:SetPoint("BOTTOM", 0, 16)
  ok:SetScript("OnClick", (ns.wrap or function(f) return f end)(function()
    if frame then frame:Hide() end
  end))
  frame.ok = ok

  if ns.Style and ns.Style.Apply then pcall(ns.Style.Apply, frame) end

  -- ESC closes (safe - the taint issue was StaticPopupDialogs reassignment, not this).
  if UISpecialFrames and not tContains(UISpecialFrames, "CoolPlanWhatsNew") then
    table.insert(UISpecialFrames, "CoolPlanWhatsNew")
  end

  setLang(lang or defaultLang())
end

-- Force-show (also used by /coolplan whatsnew for preview). Never propagates errors.
function WhatsNew.Show()
  pcall(function()
    lang = lang or defaultLang()
    if not frame then build() end
    if frame then frame:Show() end
  end)
end

-- Show ONCE per version. Records the version FIRST so a show-failure can't turn into
-- a login-after-login nag. Whole thing is pcall'd: a failure here is a silent no-op.
function WhatsNew.MaybeShow()
  pcall(function()
    if type(CoolPlanDB) ~= "table" then return end
    if CoolPlanDB.lastWhatsNew == WhatsNew.version then return end
    CoolPlanDB.lastWhatsNew = WhatsNew.version
    WhatsNew.Show()
  end)
end
