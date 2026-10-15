local _, ns = ...

-------------------------------------------------------------------------------
--  Standalone on-screen displays: the Status Widget (ST/AOE compliance stats)
--  and the Suggestion Widget (live suggested spell). Both mirror EUI's own
--  Standalone Combat Timer UX (shift+click to drag, Lock Position & Disable
--  Click, Show Out of Combat).
-------------------------------------------------------------------------------
local DB = ns.DB
local SpellName = ns.SpellName
local SpeakAlertText = ns.SpeakAlertText
local TruncateFontStringText = ns.TruncateFontStringText
local ColorHex = ns.ColorHex

local _standaloneFrame, _standaloneFS, _standaloneBG, _standaloneBorder

-- Font path resolution mirrors GetSATimerFontOverride in EllesmereUIDamageMeters.lua:
-- "__global"/nil falls back to EUI's own current global font; a specific picked font
-- resolves through the same public EllesmereUI.ResolveFontName used there.
local function GetStandaloneFontPath()
    local key = DB().standaloneFont
    if key and key ~= "__global" and EllesmereUI and EllesmereUI.ResolveFontName then
        local path = EllesmereUI.ResolveFontName(key)
        if path and path ~= "" then return path end
    end
    if EllesmereUI and EllesmereUI.GetFontPath then return EllesmereUI.GetFontPath() end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function GetStandaloneOutlineFlag()
    local outline = DB().standaloneOutline or "INHERIT"
    if outline == "NONE" or outline == "INHERIT" then return "" end
    if outline == "THICKOUTLINE" then return "THICKOUTLINE" end
    return "OUTLINE"
end

local function ApplyStandaloneStyle()
    if not _standaloneFrame or not _standaloneFS then return end
    local db = DB()
    _standaloneFrame:SetFrameStrata(db.standaloneStrata or "HIGH")
    _standaloneFrame:SetSize(math.max(60, db.standaloneWidth or 160), math.max(16, db.standaloneHeight or 20))

    _standaloneFS:SetFont(GetStandaloneFontPath(), db.standaloneSize or 14, GetStandaloneOutlineFlag())
    local c = db.standaloneColor or { r = 1, g = 1, b = 1 }
    _standaloneFS:SetTextColor(c.r or 1, c.g or 1, c.b or 1, 1)
    _standaloneFS:SetJustifyH(db.standaloneAlign or "CENTER")

    if _standaloneBG then
        local bg = db.standaloneBackgroundColor or { r = 0, g = 0, b = 0, a = 0 }
        _standaloneBG:SetColorTexture(bg.r or 0, bg.g or 0, bg.b or 0, bg.a or 0)
    end
    if _standaloneBorder then
        local PP = EllesmereUI and EllesmereUI.PP
        local bc = db.standaloneBorderColor or { r = 0, g = 0, b = 0, a = 1 }
        local borderSize = math.max(0, math.floor((db.standaloneBorderSize or 0) + 0.5))
        if borderSize > 0 and PP and PP.UpdateBorder then
            PP.UpdateBorder(_standaloneBorder, borderSize, bc.r or 0, bc.g or 0, bc.b or 0, bc.a == nil and 1 or bc.a)
            _standaloneBorder:Show()
        else
            _standaloneBorder:Hide()
        end
    end
end

local function RepositionStandalone()
    if not _standaloneFrame then return end
    local db = DB()
    _standaloneFrame:ClearAllPoints()
    local pos = db.standalonePos
    if pos and pos.x and pos.y then
        _standaloneFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        _standaloneFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 150)
    end
    local locked = db.standaloneLocked == true
    _standaloneFrame:SetMovable(not locked)
    _standaloneFrame:EnableMouse(not locked)
end

local function UpdateStandaloneText()
    if not _standaloneFS then return end
    local label, total, pct, mastery, compliant = ns.BuildStatsSummary()
    local db = DB()
    -- The percentage reflects the LAST cast's compliance: Fail Color when it
    -- missed, Text Color (Pass Color) otherwise -- including before any cast
    -- has been recorded yet.
    local color = compliant == false and (db.standaloneFailColor or { r = 1, g = 0, b = 0 })
        or (db.standaloneColor or { r = 1, g = 1, b = 1 })
    -- Not truncated like the suggestion widget: this string embeds a color
    -- escape code (|cff.../|r) that a naive character-cut could slice
    -- mid-sequence and corrupt. It's short enough in practice not to need it.
    _standaloneFS:SetText(label .. ": " .. total .. "/" .. ColorHex(color) .. pct .. "%|r/" .. mastery)
end

-- Visible while in combat; out of combat it honors Show Out of Combat
-- (keeping the last computed stats on screen instead of clearing them).
local function ApplyStandaloneVisibility()
    if not _standaloneFrame then return end
    local db = DB()
    if not db.standaloneEnabled or not ns.IsSpecSupported() then
        _standaloneFrame:Hide()
        return
    end
    if InCombatLockdown() or db.standaloneShowOOC then
        _standaloneFrame:Show()
    else
        _standaloneFrame:Hide()
    end
end

local function CreateStandaloneFrame()
    if _standaloneFrame then return end
    _standaloneFrame = CreateFrame("Frame", "APLforEUIStandaloneDisplay", UIParent)
    _standaloneFrame:SetSize(160, 20)
    _standaloneFrame:SetClampedToScreen(true)
    _standaloneFrame:SetFrameStrata("HIGH")
    _standaloneFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() and not DB().standaloneLocked then
            self:StartMoving()
        end
    end)
    _standaloneFrame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then DB().standalonePos = { x = left, y = top } end
    end)

    _standaloneBG = _standaloneFrame:CreateTexture(nil, "BACKGROUND")
    _standaloneBG:SetAllPoints()

    _standaloneBorder = CreateFrame("Frame", nil, _standaloneFrame)
    _standaloneBorder:SetAllPoints(_standaloneFrame)
    _standaloneBorder:SetFrameLevel(_standaloneFrame:GetFrameLevel() + 5)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(_standaloneBorder, 0, 0, 0, 1, 1) end

    _standaloneFS = _standaloneFrame:CreateFontString(nil, "OVERLAY")
    _standaloneFS:SetAllPoints()
    ApplyStandaloneStyle()
    RepositionStandalone()
    UpdateStandaloneText()
    _standaloneFrame:Hide()
end

local function ApplyStandalone()
    local db = DB()
    if db.standaloneEnabled then
        if not _standaloneFrame then CreateStandaloneFrame() end
        ApplyStandaloneStyle()
        RepositionStandalone()
        UpdateStandaloneText()
    end
    ApplyStandaloneVisibility()
end

-------------------------------------------------------------------------------
--  Suggestion widget: a second movable/lockable display showing the LIVE
--  suggested spell (icon + name), re-evaluated on a ticker so it follows
--  cooldowns/resources/auras changing between casts, not just at cast time.
-------------------------------------------------------------------------------
local _suggestFrame, _suggestIcon, _suggestFS, _suggestBG, _suggestBorder
local _suggestTicker
local _lastSuggestedSpellID, _lastSuggestedStep
-- One shared deadline covers both suppression windows: a cast resets it to
-- now + half of Global Suppression (never stacking -- a later cast always
-- wins, it doesn't extend on top of an existing one), and the full Global
-- Suppression value resets it again every time the displayed suggestion
-- actually changes, holding a newly shown pick stable before the next one
-- is allowed to replace it.
local _suggestSuppressUntil = 0
local SUGGEST_GLOBAL_SUPPRESSION_DEFAULT = 0.3
local SUGGEST_POST_CAST_FRACTION = 0.5

local function GetSuggestGlobalSuppression()
    return DB().suggestGlobalSuppression or SUGGEST_GLOBAL_SUPPRESSION_DEFAULT
end

-- Called by Tracking for every reported cast.
function ns.OnCastSuppressSuggest(now)
    _suggestSuppressUntil = now + GetSuggestGlobalSuppression() * SUGGEST_POST_CAST_FRACTION
end

local function GetSuggestFontPath()
    local key = DB().suggestFont
    if key and key ~= "__global" and EllesmereUI and EllesmereUI.ResolveFontName then
        local path = EllesmereUI.ResolveFontName(key)
        if path and path ~= "" then return path end
    end
    if EllesmereUI and EllesmereUI.GetFontPath then return EllesmereUI.GetFontPath() end
    return STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
end

local function GetSuggestOutlineFlag()
    local outline = DB().suggestOutline or "INHERIT"
    if outline == "NONE" or outline == "INHERIT" then return "" end
    if outline == "THICKOUTLINE" then return "THICKOUTLINE" end
    return "OUTLINE"
end

-- Icon renders at its full configured size, unclamped -- it sits OUTSIDE the
-- bordered text box (see LayoutSuggestWidget), so it never competes with the
-- frame/border for space.
local function GetSuggestIconSize()
    return math.max(8, DB().suggestIconSize or 24)
end

-- Icon anchored OUTSIDE the text's bordered frame, on whichever side is
-- configured -- re-anchored from scratch since the side (and whether the
-- icon shows at all) can change live.
local function LayoutSuggestWidget()
    if not _suggestFrame then return end
    local db = DB()
    local showIcon = db.suggestShowIcon ~= false
    _suggestIcon:ClearAllPoints()
    if not showIcon then
        _suggestIcon:Hide()
        return
    end
    local iconSize = GetSuggestIconSize()
    _suggestIcon:Show()
    _suggestIcon:SetSize(iconSize, iconSize)
    local anchor = db.suggestIconAnchor or "LEFT"
    local gap = 4
    if anchor == "RIGHT" then
        _suggestIcon:SetPoint("LEFT", _suggestFrame, "RIGHT", gap, 0)
    elseif anchor == "TOP" then
        _suggestIcon:SetPoint("BOTTOM", _suggestFrame, "TOP", 0, gap)
    elseif anchor == "BOTTOM" then
        _suggestIcon:SetPoint("TOP", _suggestFrame, "BOTTOM", 0, -gap)
    else -- LEFT
        _suggestIcon:SetPoint("RIGHT", _suggestFrame, "LEFT", -gap, 0)
    end
end

-- Available width for the suggestion text -- the icon no longer shares the
-- frame's space (it's anchored outside it), so this is just the frame width.
local function GetSuggestTextMaxWidth()
    if not _suggestFrame then return nil end
    return _suggestFrame:GetWidth() - 6
end

local function ApplySuggestStyle()
    if not _suggestFrame or not _suggestFS then return end
    local db = DB()
    _suggestFrame:SetFrameStrata(db.suggestStrata or "HIGH")
    _suggestFrame:SetSize(math.max(40, db.suggestWidth or 160), math.max(16, db.suggestHeight or 32))

    _suggestFS:SetFont(GetSuggestFontPath(), db.suggestSize or 14, GetSuggestOutlineFlag())
    TruncateFontStringText(_suggestFS, _suggestFS._fullText or "", GetSuggestTextMaxWidth())
    local c = db.suggestTextColor or { r = 1, g = 1, b = 1 }
    _suggestFS:SetTextColor(c.r or 1, c.g or 1, c.b or 1, 1)

    if _suggestBG then
        local bg = db.suggestBackgroundColor or { r = 0, g = 0, b = 0, a = 0 }
        _suggestBG:SetColorTexture(bg.r or 0, bg.g or 0, bg.b or 0, bg.a or 0)
    end
    if _suggestBorder then
        local PP = EllesmereUI and EllesmereUI.PP
        local bc = db.suggestBorderColor or { r = 0, g = 0, b = 0, a = 1 }
        local borderSize = math.max(0, math.floor((db.suggestBorderSize or 0) + 0.5))
        if borderSize > 0 and PP and PP.UpdateBorder then
            PP.UpdateBorder(_suggestBorder, borderSize, bc.r or 0, bc.g or 0, bc.b or 0, bc.a == nil and 1 or bc.a)
            _suggestBorder:Show()
        else
            _suggestBorder:Hide()
        end
    end
    LayoutSuggestWidget()
end

local function RepositionSuggest()
    if not _suggestFrame then return end
    local db = DB()
    _suggestFrame:ClearAllPoints()
    local pos = db.suggestPos
    if pos and pos.x and pos.y then
        _suggestFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    else
        _suggestFrame:SetPoint("CENTER", UIParent, "CENTER", 0, 100)
    end
    local locked = db.suggestLocked == true
    _suggestFrame:SetMovable(not locked)
    _suggestFrame:EnableMouse(not locked)
end

-- /apl debug <step> watch list: TTS-announces whenever one of these specific
-- APL steps gets suggested, independent of the normal suggestion TTS alias
-- toggle -- for isolating exactly when a given rule fires without staring at
-- the widget. Keyed by the step's string form ("A13", "13", "O1") so ST's
-- plain-number steps and AOE's "A"-prefixed strings compare the same way.
local _debugWatchSteps = {}
local function NormalizeStepKey(step)
    if step == nil then return nil end
    return tostring(step):upper()
end

-- Pulls the live pick straight from the evaluator (not from cast reports), so
-- it tracks cooldowns/resources/auras changing between casts too.
local function UpdateSuggestWidget()
    if not _suggestFS or not _suggestIcon then return end
    if GetTime() < _suggestSuppressUntil then return end
    local spellID, step = ns.EvaluateExpected()
    if not spellID then
        -- Nothing applies (design.md "No match"): show nothing.
        if _lastSuggestedSpellID ~= nil then
            _lastSuggestedSpellID, _lastSuggestedStep = nil, nil
            _suggestFS._fullText = ""
            _suggestFS:SetText("")
            _suggestIcon:SetTexture(nil)
        end
        return
    end
    local spec = ns.GetActiveSpec()
    if spellID == _lastSuggestedSpellID and step == _lastSuggestedStep then return end
    _lastSuggestedSpellID, _lastSuggestedStep = spellID, step
    _suggestSuppressUntil = GetTime() + GetSuggestGlobalSuppression()
    _suggestFS._fullText = (step and (step .. ": ") or "") .. SpellName(spellID)
    TruncateFontStringText(_suggestFS, _suggestFS._fullText, GetSuggestTextMaxWidth())
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(spellID)
    _suggestIcon:SetTexture(info and info.iconID)
    if DB().suggestTTSEnabled then
        local alias = spec and spec.ttsAlias and spec.ttsAlias[spellID]
        if alias then SpeakAlertText(alias) end
    end
    local stepKey = NormalizeStepKey(step)
    if stepKey and _debugWatchSteps[stepKey] then
        SpeakAlertText(stepKey)
    end
end

-- Visible while in combat; out of combat it honors Show Out of Combat. The
-- ticker only runs while shown, so there is zero background cost otherwise.
local function ApplySuggestVisibility()
    if not _suggestFrame then return end
    local db = DB()
    if not db.suggestEnabled or not ns.IsSpecSupported() then
        _suggestFrame:Hide()
        if _suggestTicker then _suggestTicker:Cancel(); _suggestTicker = nil end
        return
    end
    if InCombatLockdown() or db.suggestShowOOC then
        _suggestFrame:Show()
        if not _suggestTicker then
            _lastSuggestedSpellID, _lastSuggestedStep = nil, nil
            UpdateSuggestWidget()
            _suggestTicker = C_Timer.NewTicker(0.2, UpdateSuggestWidget)
        end
    else
        _suggestFrame:Hide()
        if _suggestTicker then _suggestTicker:Cancel(); _suggestTicker = nil end
    end
end

local function CreateSuggestFrame()
    if _suggestFrame then return end
    _suggestFrame = CreateFrame("Frame", "APLforEUISuggestionWidget", UIParent)
    _suggestFrame:SetSize(160, 32)
    _suggestFrame:SetClampedToScreen(true)
    _suggestFrame:SetFrameStrata("HIGH")
    _suggestFrame:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" and IsShiftKeyDown() and not DB().suggestLocked then
            self:StartMoving()
        end
    end)
    _suggestFrame:SetScript("OnMouseUp", function(self)
        self:StopMovingOrSizing()
        local left, top = self:GetLeft(), self:GetTop()
        if left and top then DB().suggestPos = { x = left, y = top } end
    end)

    _suggestBG = _suggestFrame:CreateTexture(nil, "BACKGROUND")
    _suggestBG:SetAllPoints()

    _suggestBorder = CreateFrame("Frame", nil, _suggestFrame)
    _suggestBorder:SetAllPoints(_suggestFrame)
    _suggestBorder:SetFrameLevel(_suggestFrame:GetFrameLevel() + 5)
    local PP = EllesmereUI and EllesmereUI.PP
    if PP and PP.CreateBorder then PP.CreateBorder(_suggestBorder, 0, 0, 0, 1, 1) end

    _suggestIcon = _suggestFrame:CreateTexture(nil, "ARTWORK")
    _suggestFS = _suggestFrame:CreateFontString(nil, "OVERLAY")
    _suggestFS:SetPoint("CENTER", _suggestFrame, "CENTER", 0, 0)

    ApplySuggestStyle()
    RepositionSuggest()
    _suggestFrame:Hide()
end

local function ApplySuggest()
    local db = DB()
    if db.suggestEnabled then
        if not _suggestFrame then CreateSuggestFrame() end
        ApplySuggestStyle()
        RepositionSuggest()
    end
    ApplySuggestVisibility()
end

local _standaloneCombatFrame = CreateFrame("Frame")
_standaloneCombatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
_standaloneCombatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
_standaloneCombatFrame:SetScript("OnEvent", function()
    ApplyStandaloneVisibility()
    ApplySuggestVisibility()
end)

ns.SUGGEST_GLOBAL_SUPPRESSION_DEFAULT = SUGGEST_GLOBAL_SUPPRESSION_DEFAULT
ns.ApplyStandalone = ApplyStandalone
ns.ApplyStandaloneStyle = ApplyStandaloneStyle
ns.ApplyStandaloneVisibility = ApplyStandaloneVisibility
ns.RepositionStandalone = RepositionStandalone
ns.UpdateStandaloneText = UpdateStandaloneText
ns.ApplySuggest = ApplySuggest
ns.ApplySuggestStyle = ApplySuggestStyle
ns.ApplySuggestVisibility = ApplySuggestVisibility
ns.RepositionSuggest = RepositionSuggest

ns.slashCommands.debug = function(rest)
    if rest == "" then
        local keys = {}
        for key in pairs(_debugWatchSteps) do keys[#keys + 1] = key end
        table.sort(keys)
        print("APL debug watch: " .. (#keys > 0 and table.concat(keys, ", ") or "(none)"))
        return
    end
    if rest:lower() == "clear" then
        wipe(_debugWatchSteps)
        print("APL debug watch: cleared.")
        return
    end
    local key = NormalizeStepKey(rest)
    if _debugWatchSteps[key] then
        _debugWatchSteps[key] = nil
        print("APL debug watch: stopped watching step " .. key .. ".")
    else
        _debugWatchSteps[key] = true
        print("APL debug watch: now watching step " .. key .. " (TTS announces when it's suggested).")
    end
end
