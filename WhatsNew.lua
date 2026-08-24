-- WhatsNew.lua - a one-time "version update" notice shown on the first login after
-- an update. Self-built frame (NO StaticPopup - that path has a taint history),
-- mirroring Comm's proven pattern. HARD REQUIREMENT: must NEVER throw or break
-- login - every entry point is pcall-guarded, so total failure is a silent no-op.
--
-- One language at a time with an EN/한국어 toggle (default = client locale). Stacking
-- both at once was cluttered.
local _, ns = ...
local WhatsNew = {}
ns.WhatsNew = WhatsNew

-- RETIRED (1.10.1): the popup no longer shows on login. Release notes live on
-- CurseForge and the site, so a login-time interruption isn't wanted. The frame and
-- its copy are kept intact so a future release can turn it back on by flipping
-- `enabled` to true and bumping `version` — nothing else needs rewiring.
WhatsNew.enabled = false

-- Bump ONLY when there is news to show. Login compares it to CoolPlanDB.lastWhatsNew;
-- equal → nothing shows. A routine addon bump with no WhatsNew change stays silent.
WhatsNew.version = "1.10.0"

-- Per-language body. Color codes (|c…|r) render in FontStrings.
local BODY = {
  en = table.concat({
    "Raid phases: your plan now follows the boss, not the clock.",
    "",
    "On four bosses in |cffffcc00The Venomous Abyss|r the addon reads the phase change",
    "as it happens and shifts the rest of your plan with it, so a slow or fast phase",
    "no longer pushes every later cue out of place:",
    "",
    "  |cffffcc00Nek'zali the Soulcoiler|r, |cffffcc00Entombed Sentinels|r,",
    "  |cffffcc00The Lost Explorers|r, |cffffcc00The Coiled Altar|r",
    "",
    "Export the plan again from the site to get the phase timing. Older plans keep",
    "working on absolute time. Other raid bosses are unchanged.",
    "",
    "Not working, or you see an error? Tell us on Discord and we will fix it.",
    "",
    "|cff66b3ffcoolplan.team|r",
  }, "\n"),
  ko = table.concat({
    "레이드 페이즈: 이제 플랜이 시계가 아니라 보스를 따라갑니다.",
    "",
    "|cffffcc00맹독 심연|r의 네 보스에서 애드온이 페이즈 전환을 그 자리에서 읽고",
    "남은 플랜을 함께 밀어 줍니다. 페이즈가 빨리 끝나거나 늦어져도 이후 알림이",
    "통째로 어긋나지 않습니다:",
    "",
    "  |cffffcc00영혼살무사 네크잘리|r, |cffffcc00매장된 파수꾼|r,",
    "  |cffffcc00길 잃은 탐험가|r, |cffffcc00똬리의 제단|r",
    "",
    "페이즈 타이밍을 쓰려면 사이트에서 플랜을 다시 내보내 주세요. 기존 플랜은",
    "절대시간 그대로 동작합니다. 다른 레이드 보스는 변경 없습니다.",
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
    if not WhatsNew.enabled then return end
    if type(CoolPlanDB) ~= "table" then return end
    if CoolPlanDB.lastWhatsNew == WhatsNew.version then return end
    CoolPlanDB.lastWhatsNew = WhatsNew.version
    WhatsNew.Show()
  end)
end
