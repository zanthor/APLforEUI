local _, ns = ...

-------------------------------------------------------------------------------
--  Editor building blocks shared by the APL editor pages: editor state,
--  accordion header rows, the condition text box with autocomplete, and
--  small glyph buttons. Patterns mirror EUI's Macro Factory page
--  (EUI_ForeverEssentials_Macros_Options.lua): accordion rows with move /
--  toggle / delete, a multi-line text box, and a suggestion dropdown.
--  Only public EllesmereUI functions are used; no "_" fields.
-------------------------------------------------------------------------------
local Kit = {}
ns.EditorKit = Kit

local ICONS = "Interface\\AddOns\\EllesmereUI\\media\\icons\\"
Kit.ROW_H = 50

-- "|" starts an escape code in WoW text, so an edit box stores a typed or
-- pasted "|" as "||". Write text in escaped and read it back collapsed;
-- APL text never contains a real "||" (it isn't an operator).
function Kit.SetEditText(edit, text)
    edit:SetText(((text or ""):gsub("|", "||")))
end

function Kit.GetEditText(edit)
    return ((edit:GetText() or ""):gsub("|+", "|"))
end

-------------------------------------------------------------------------------
--  Editor state: which spec/APL is being edited and which rows are open.
--  Open rows are remembered by table identity, so they survive rebuilds.
-------------------------------------------------------------------------------
local E = { open = {} }
Kit.state = E

function Kit.SpecID()
    if not E.specID then E.specID = ns.GetSpecID() end
    return E.specID
end

function Kit.Def()
    local def = E.aplID and ns.Store.Get(E.aplID)
    if def and def.specID == Kit.SpecID() then return def end
    def = ns.Engine.ActiveDef(Kit.SpecID())
    E.aplID = def and def.id
    return def
end

function Kit.Editable()
    return ns.Store.IsEditable(Kit.Def())
end

function Kit.SelectSpec(specID)
    E.specID, E.aplID = specID, nil
    wipe(E.open)
    Kit.RebuildAll()
end

function Kit.SelectAPL(id)
    E.aplID = id
    wipe(E.open)
    Kit.RebuildAll()
end

function Kit.IsOpen(t) return E.open[t] == true end
function Kit.Toggle(t)
    E.open[t] = not E.open[t] or nil
    Kit.Rebuild()
end

-- Structural edit on this page: rebuild it. RebuildAll also drops the
-- module's other cached pages (APL switched, or the header changed).
function Kit.Rebuild()
    EllesmereUI:RefreshPage(true)
end

function Kit.RebuildAll()
    local key = EllesmereUI.GetPluginModuleKey and EllesmereUI.GetPluginModuleKey("APLforEUI", "APL")
    if key then EllesmereUI:InvalidateModulePageCache(key) end
    EllesmereUI:RefreshPage(true)
end

function Kit.SpecLabel(specID)
    if GetSpecializationInfoByID then
        local _, name, _, _, _, _, className = GetSpecializationInfoByID(specID)
        if name then return name .. " " .. (className or "") end
    end
    return "Spec " .. tostring(specID)
end

-------------------------------------------------------------------------------
--  Small controls
-------------------------------------------------------------------------------

-- Small icon button (move / remove glyphs), as in the Macro Factory page.
function Kit.Glyph(parent, size, file, onClick, tip)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(size, size)
    b:SetFrameLevel(parent:GetFrameLevel() + 6)
    local t = b:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    if file then t:SetTexture(ICONS .. file) end
    b.tex = t
    b:SetAlpha(0.5)
    b:SetScript("OnEnter", function(self)
        if self:IsEnabled() then self:SetAlpha(0.9) end
        if tip then EllesmereUI.ShowWidgetTooltip(self, tip) end
    end)
    b:SetScript("OnLeave", function(self)
        self:SetAlpha(self:IsEnabled() and 0.5 or 0.15)
        if tip then EllesmereUI.HideWidgetTooltip() end
    end)
    b:SetScript("OnEnable", function(self) self:SetAlpha(0.5) end)
    b:SetScript("OnDisable", function(self) self:SetAlpha(0.15) end)
    b:SetScript("OnClick", onClick)
    return b
end

function Kit.DeleteGlyph(parent, onClick, tip)
    local b = Kit.Glyph(parent, 16, nil, onClick, tip)
    EllesmereUI.SetDeleteIcon(b.tex)
    return b
end

function Kit.Confirm(message, onConfirm)
    EllesmereUI:ShowConfirmPopup({
        title = "APL for EUI", message = message,
        confirmText = "Delete", cancelText = "Cancel",
        onConfirm = onConfirm,
    })
end

-- A note row (dim text across the full width).
function Kit.Note(parent, y, text)
    local W = EllesmereUI.Widgets
    local row, h = W:DualRow(parent, y, { type = "label", text = "" })
    local fs = EllesmereUI.MakeFont(row, 12, nil, 1, 1, 1, EllesmereUI.TEXT_DIM_A)
    fs:SetPoint("LEFT", row, "LEFT", 20, 0)
    fs:SetPoint("RIGHT", row, "RIGHT", -20, 0)
    fs:SetJustifyH("LEFT")
    fs:SetText(text)
    return y - h, row
end

-------------------------------------------------------------------------------
--  Accordion header row: title text, then right-aligned up/down, optional
--  on/off toggle and delete. Clicking the row toggles it open.
--  o = { title, open, depth, editable, index, count, onMove(delta),
--        onDelete, deleteTip, getOn, setOn, onTip, noDim, tooltip, onClick }
--  noDim: the toggle means something other than "enabled" (don't fade).
-------------------------------------------------------------------------------
function Kit.Header(parent, y, o)
    local W = EllesmereUI.Widgets
    local row, h = W:DualRow(parent, y, { type = "label", text = "" })
    local level = row:GetFrameLevel() + 5
    local indent = 20 + (o.depth or 0) * 24

    local title = EllesmereUI.MakeFont(row, 13, nil, 1, 1, 1, 1)
    title:SetPoint("LEFT", row, "LEFT", indent, 0)
    title:SetJustifyH("LEFT")
    title:SetWordWrap(false)
    title:SetText(o.title)
    if o.getOn and not o.noDim and not o.getOn() then title:SetAlpha(0.4) end

    if o.open then
        local ac = EllesmereUI.ELLESMERE_GREEN
        local bar = row:CreateTexture(nil, "ARTWORK", nil, 2)
        bar:SetColorTexture(ac.r, ac.g, ac.b, 1)
        bar:SetPoint("TOPLEFT", row, "TOPLEFT", indent - 20, 0)
        bar:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", indent - 20, 0)
        bar:SetWidth(2)
    end

    local anchor = row
    local anchorPoint, gap = "RIGHT", -20
    local function Place(ctrl, spacing)
        ctrl:SetPoint("RIGHT", anchor, anchorPoint, gap, 0)
        anchor, anchorPoint, gap = ctrl, "LEFT", -(spacing or 14)
    end

    if o.onDelete then
        local del = Kit.DeleteGlyph(row, o.onDelete, o.deleteTip or "Remove")
        del:SetEnabled(o.editable ~= false)
        Place(del)
    end
    if o.setOn then
        local tg, _, snap = EllesmereUI.BuildToggleControl(row, level, o.getOn, function(v)
            o.setOn(v)
            if not o.noDim then title:SetAlpha(v and 1 or 0.4) end
        end)
        tg:SetEnabled(o.editable ~= false)
        snap()
        if o.onTip then
            tg:HookScript("OnEnter", function(self) EllesmereUI.ShowWidgetTooltip(self, o.onTip) end)
            tg:HookScript("OnLeave", function() EllesmereUI.HideWidgetTooltip() end)
        end
        Place(tg)
    end
    if o.onMove then
        local down = Kit.Glyph(row, 18, "eui-arrow-down3.png", function() o.onMove(1) end, "Move down")
        down:SetEnabled(o.editable ~= false and o.index < o.count)
        Place(down)
        local up = Kit.Glyph(row, 18, "eui-arrow-up3.png", function() o.onMove(-1) end, "Move up")
        up:SetEnabled(o.editable ~= false and o.index > 1)
        Place(up, 2)
    end
    title:SetPoint("RIGHT", anchor, anchor == row and "RIGHT" or "LEFT", -12, 0)

    -- Click target over the title area only, so the controls stay clickable.
    local hit = CreateFrame("Button", nil, row)
    hit:SetPoint("TOPLEFT", row, "TOPLEFT", 0, 0)
    hit:SetPoint("BOTTOMRIGHT", row, "BOTTOMRIGHT", -170, 0)
    hit:SetFrameLevel(level - 2)
    local hl = EllesmereUI.SolidTex(hit, "BACKGROUND", 1, 1, 1, 0)
    hl:SetAllPoints(row)
    hit:SetScript("OnEnter", function(self)
        hl:SetColorTexture(1, 1, 1, 0.03)
        local tip = (o.tooltip and (o.tooltip .. "\n\n") or "") .. (o.open and "Click to close." or "Click to edit.")
        EllesmereUI.ShowWidgetTooltip(self, tip)
    end)
    hit:SetScript("OnLeave", function()
        hl:SetColorTexture(1, 1, 1, 0)
        EllesmereUI.HideWidgetTooltip()
    end)
    hit:SetScript("OnClick", o.onClick)
    return y - h, row
end

-- Nesting: children of an open item (a group's lists, a list's entries, a
-- timer's triggers) are built into a frame shifted right by INDENT with the
-- same vertical coordinates, so their rows, fields and accent bars all sit
-- inside their owner. One per parent frame (weak, rebuilt with the page).
Kit.INDENT = 24
local children = setmetatable({}, { __mode = "k" })
function Kit.Child(parent)
    local c = children[parent]
    if not c then
        c = CreateFrame("Frame", nil, parent)
        c:SetPoint("TOPLEFT", parent, "TOPLEFT", Kit.INDENT, 0)
        c:SetSize(math.max(1, parent:GetWidth() - Kit.INDENT), 1)
        children[parent] = c
    end
    return c
end

-- Accent bar from an open header's top (topY) down to the end of its body
-- (bottomY), at the header's own indent, so it's clear which group / list /
-- entry the fields below belong to. Its own frame above the rows (a texture
-- on the page itself would sit under the row backgrounds).
function Kit.OpenSpan(parent, topY, bottomY, depth)
    local f = CreateFrame("Frame", nil, parent)
    f:SetFrameLevel(parent:GetFrameLevel() + 40)
    f:EnableMouse(false)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", EllesmereUI.CONTENT_PAD + (depth or 0) * 24, topY)
    f:SetSize(2, math.max(1, topY - bottomY))
    local ac = EllesmereUI.ELLESMERE_GREEN
    local t = f:CreateTexture(nil, "OVERLAY")
    t:SetAllPoints()
    t:SetColorTexture(ac.r, ac.g, ac.b, 1)
    return f
end

-------------------------------------------------------------------------------
--  Suggestion dropdown under a text field (mirrors AttachSuggest in the
--  Macro Factory page). items(token) returns { { text, label }, ... };
--  picking replaces the token under the cursor.
-------------------------------------------------------------------------------
local suggest

local function HideSuggest()
    if suggest then suggest:Hide(); suggest.owner = nil end
end
Kit.HideSuggest = HideSuggest

-- The dotted name being typed at the end of the text.
local function TokenAt(text)
    return text:match("([%w_%.]*)$") or ""
end

function Kit.AttachSuggest(edit, items)
    local function Pick(text)
        HideSuggest()
        local cur = Kit.GetEditText(edit)
        local token = TokenAt(cur)
        Kit.SetEditText(edit, cur:sub(1, #cur - #token) .. text)
        edit:SetCursorPosition(#(edit:GetText() or ""))
    end
    local function Show()
        if not suggest then
            suggest = CreateFrame("Frame", nil, UIParent)
            suggest:SetFrameStrata("FULLSCREEN_DIALOG")
            suggest:SetClampedToScreen(true)
            EllesmereUI.SolidTex(suggest, "BACKGROUND", 0.067, 0.067, 0.067, 0.97):SetAllPoints()
            EllesmereUI.MakeBorder(suggest, 1, 1, 1, 0.18)
            suggest.rows = {}
            suggest:Hide()
        end
        local list = items(TokenAt(Kit.GetEditText(edit)))
        if #list == 0 then HideSuggest() return end
        for i, it in ipairs(list) do
            local r = suggest.rows[i]
            if not r then
                r = CreateFrame("Button", nil, suggest)
                r:SetHeight(22)
                r.hl = EllesmereUI.SolidTex(r, "BACKGROUND", 1, 1, 1, 0)
                r.hl:SetAllPoints()
                r.label = EllesmereUI.MakeFont(r, 12, nil, 1, 1, 1, 0.8)
                r.label:SetPoint("LEFT", 8, 0)
                r.label:SetPoint("RIGHT", -8, 0)
                r.label:SetJustifyH("LEFT")
                r.label:SetWordWrap(false)
                r:SetScript("OnEnter", function(self)
                    local ac = EllesmereUI.ELLESMERE_GREEN
                    self.hl:SetColorTexture(1, 1, 1, EllesmereUI.DD_ITEM_HL_A)
                    self.label:SetTextColor(ac.r, ac.g, ac.b, 1)
                end)
                r:SetScript("OnLeave", function(self)
                    self.hl:SetColorTexture(1, 1, 1, 0)
                    self.label:SetTextColor(1, 1, 1, 0.8)
                end)
                suggest.rows[i] = r
            end
            r:ClearAllPoints()
            r:SetPoint("TOPLEFT", 1, -1 - (i - 1) * 22)
            r:SetPoint("RIGHT", suggest, "RIGHT", -1, 0)
            r.label:SetText(it.label or it.text)
            -- Mouse down: picks before the field can lose focus.
            r:SetScript("OnMouseDown", function() Pick(it.text) end)
            r:Show()
        end
        for i = #list + 1, #suggest.rows do suggest.rows[i]:Hide() end
        suggest.first = list[1].text
        suggest.owner = edit
        suggest:SetScale(edit:GetEffectiveScale() / UIParent:GetEffectiveScale())
        suggest:SetSize(math.max(edit:GetWidth(), 260), #list * 22 + 2)
        suggest:ClearAllPoints()
        suggest:SetPoint("TOPLEFT", edit, "BOTTOMLEFT", 0, -4)
        suggest:Show()
    end
    edit:HookScript("OnTextChanged", function(_, user) if user then Show() end end)
    edit:HookScript("OnEditFocusLost", function() if suggest and suggest.owner == edit then HideSuggest() end end)
    edit:HookScript("OnTabPressed", function()
        if suggest and suggest.owner == edit and suggest:IsShown() then Pick(suggest.first) end
    end)
end

-------------------------------------------------------------------------------
--  Expression box: a multi-line text field under a full-width row, with a
--  status line (OK / error). Wraps long conditions but stores one line;
--  commits on Enter and on focus loss, Escape reverts.
--  o = { get, set(text), check(text) -> ok, err, suggest(token), editable,
--        height, caption (what this is, e.g. "Only If"), note (extra info) }
-------------------------------------------------------------------------------
function Kit.ExprBox(parent, y, o)
    local pad = EllesmereUI.CONTENT_PAD
    local w = parent:GetWidth() - pad * 2
    local boxH = o.height or 44
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(w, boxH + 30)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", pad, y)

    local box = CreateFrame("Frame", nil, f)
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -4)
    box:SetSize(w - 40, boxH)
    EllesmereUI.SolidTex(box, "BACKGROUND", 0, 0, 0, 0.5):SetAllPoints()
    local brd = EllesmereUI.MakeBorder(box, 1, 1, 1, 0.2)

    local edit = CreateFrame("EditBox", nil, box)
    edit:SetPoint("TOPLEFT", box, "TOPLEFT", 10, -8)
    edit:SetPoint("BOTTOMRIGHT", box, "BOTTOMRIGHT", -10, 6)
    edit:SetMultiLine(true)
    edit:SetAutoFocus(false)
    edit:SetFont(EllesmereUI.EXPRESSWAY, 12, "")
    edit:SetTextColor(1, 1, 1, o.editable == false and 0.5 or 0.9)
    Kit.SetEditText(edit, o.get())
    edit:SetEnabled(o.editable ~= false)

    local status = EllesmereUI.MakeFont(f, 11, nil, 1, 1, 1, 0.7)
    status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -6)
    status:SetPoint("RIGHT", box, "RIGHT", 0, 0)
    status:SetJustifyH("LEFT")
    status:SetWordWrap(false)

    local lead = o.caption and ("|cffffffff" .. o.caption .. ":|r  ") or ""
    local tail = o.note and ("  |cff909090(" .. o.note .. ")|r") or ""
    local function ShowStatus(text)
        local ok, err = o.check(text)
        if ok then
            status:SetTextColor(0.5, 0.9, 0.5, 0.8)
            status:SetText(lead .. ((text:match("^%s*$") and "Always (no condition)") or "OK") .. tail)
        else
            status:SetTextColor(1, 0.4, 0.4, 0.95)
            status:SetText(lead .. (err or "error") .. tail)
        end
        return ok
    end
    ShowStatus(o.get() or "")

    local committed = o.get() or ""
    local function Commit()
        local text = Kit.GetEditText(edit):gsub("[\r\n]+", " ")
        text = text:match("^%s*(.-)%s*$")
        if text ~= committed then
            committed = text
            o.set(text)
        end
    end
    edit:SetScript("OnTextChanged", function(self) ShowStatus(Kit.GetEditText(self)) end)
    edit:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    edit:SetScript("OnEscapePressed", function(self)
        Kit.SetEditText(self, committed)
        self:ClearFocus()
    end)
    edit:SetScript("OnEditFocusGained", function()
        local ac = EllesmereUI.ELLESMERE_GREEN
        brd:SetColor(ac.r, ac.g, ac.b, 0.8)
    end)
    edit:SetScript("OnEditFocusLost", function()
        brd:SetColor(1, 1, 1, 0.2)
        Commit()
    end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function()
        if o.editable ~= false then edit:SetFocus() end
    end)
    if o.suggest and o.editable ~= false then Kit.AttachSuggest(edit, o.suggest) end
    return y - (boxH + 30), edit
end

-------------------------------------------------------------------------------
--  Autocomplete vocabulary for an APL: every dotted name the engine accepts,
--  built from the APL's own names, timers, counters and variables.
-------------------------------------------------------------------------------
local SPELL_READS = {
    { "buff.", ".up" }, { "cooldown.", ".ready" }, { "charges.", "" }, { "charges.", ".full" },
    { "usable.", "" }, { "talent.", "" }, { "override.", "" }, { "prev.", "" },
    { "channeling.", "" }, { "spell.", ".base_cd" }, { "spell.", ".recharge" }, { "holding.", "" },
}
local HEADS = { "buff.", "cooldown.", "charges.", "usable.", "talent.", "override.", "prev.",
    "channeling.", "spell.", "resource.", "timer.", "counter.", "variable.", "combat.time",
    "combat.casts", "holding", "targets", "bloodlust" }

function Kit.Vocabulary(def)
    local all = {}
    for _, h in ipairs(HEADS) do all[#all + 1] = h end
    local names = {}
    for name in pairs(def.names or {}) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        for _, r in ipairs(SPELL_READS) do all[#all + 1] = r[1] .. name .. r[2] end
    end
    for _, t in ipairs(def.timers or {}) do
        all[#all + 1] = "timer." .. t.name .. ".up"
        all[#all + 1] = "timer." .. t.name .. ".remains"
    end
    for _, c in ipairs(def.counters or {}) do all[#all + 1] = "counter." .. c.name end
    for _, v in ipairs(def.variables or {}) do all[#all + 1] = "variable." .. v.name end
    for key in pairs(Enum.PowerType) do
        all[#all + 1] = "resource." .. key:gsub("(%l)(%u)", "%1_%2"):lower()
    end
    return all
end

-- Suggestion source for Kit.ExprBox: up to 10 matches for the current token.
function Kit.Suggester(def)
    local vocab
    return function(token)
        if token == "" then return {} end
        vocab = vocab or Kit.Vocabulary(def)
        local out, t = {}, token:lower()
        for _, v in ipairs(vocab) do
            if v:sub(1, #t) == t and v ~= t then
                out[#out + 1] = { text = v }
                if #out >= 10 then break end
            end
        end
        return out
    end
end

Kit.READ_ONLY_TIP = "This option is read-only on built-in APLs. Duplicate the APL to edit it."

-- Compile problems of def (unknown names, bad expressions, overlapping
-- ranges), listed at the top of the editing tabs. Skipped entries and
-- triggers simply don't run until fixed.
function Kit.Problems(parent, y, def)
    local rt = ns.Engine.GetRuntime(def)
    if #rt.errors == 0 then return y end
    local W = EllesmereUI.Widgets
    local _, h = W:SectionHeader(parent, "PROBLEMS (" .. #rt.errors .. ")", y); y = y - h
    for i = 1, math.min(#rt.errors, 8) do
        y = Kit.Note(parent, y, "|cffff6060" .. rt.errors[i] .. "|r")
    end
    if #rt.errors > 8 then y = Kit.Note(parent, y, "...and " .. (#rt.errors - 8) .. " more.") end
    return y
end

-------------------------------------------------------------------------------
--  Text popup for export (read-only, pre-selected for Ctrl+C) and import
--  (paste, then Import). A plain multi-line box with no byte cap: EUI's
--  profile import absorber keeps only what OnChar delivers, and this format
--  needs its newlines. Built once on EUI's popup shell.
--  o = { title, subtitle, text, readOnly, onConfirm(text) -> ok, errorText }
-------------------------------------------------------------------------------
local textPopup

local function BuildTextPopup()
    local W_, H_ = 640, 470
    local p = {}
    local function Hide() p.dimmer:Hide() end
    p.dimmer, p.frame = EllesmereUI.BuildPopupShell("APLforEUIText", { w = W_, h = H_, clamp = true, onEscape = Hide })
    local f = p.frame

    p.title = EllesmereUI.MakeFont(f, 16, nil, 1, 1, 1, 1)
    p.title:SetPoint("TOP", f, "TOP", 0, -18)
    p.subtitle = EllesmereUI.MakeFont(f, 11, nil, 1, 1, 1, EllesmereUI.TEXT_DIM_A)
    p.subtitle:SetPoint("TOP", p.title, "BOTTOM", 0, -6)

    local box = CreateFrame("Frame", nil, f)
    box:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -62)
    box:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 76)
    EllesmereUI.SolidTex(box, "BACKGROUND", 0, 0, 0, 0.5):SetAllPoints()
    EllesmereUI.MakeBorder(box, 1, 1, 1, 0.2)
    local sf = CreateFrame("ScrollFrame", nil, box)
    sf:SetPoint("TOPLEFT", 10, -8)
    sf:SetPoint("BOTTOMRIGHT", -14, 8)
    sf:SetClipsChildren(true)
    local e = CreateFrame("EditBox", nil, sf)
    e:SetMultiLine(true)
    e:SetAutoFocus(false)
    e:SetMaxLetters(0)
    e:SetFont(EllesmereUI.EXPRESSWAY, 12, "")
    e:SetTextColor(1, 1, 1, 0.9)
    e:SetWidth(W_ - 40 - 30)
    sf:SetScrollChild(e)
    local update = EllesmereUI.AttachSmoothScrollbar(sf, {
        step = 60, thumbMin = 20, rightInset = 0, topInset = 2, level = 5,
        trackAlpha = 0.05, thumbAlpha = 0.22, child = e })
    e:SetScript("OnSizeChanged", function() if update then update() end end)
    e:SetScript("OnCursorChanged", function(_, _, y, _, ch)
        y = -y
        local top, vh = sf:GetVerticalScroll(), sf:GetHeight()
        if y < top then sf:SetVerticalScroll(y) elseif y + ch > top + vh then sf:SetVerticalScroll(y + ch - vh) end
        if update then update() end
    end)
    e:SetScript("OnEscapePressed", Hide)
    e:SetScript("OnTextChanged", function(self, user)
        if p.readOnly and user then Kit.SetEditText(self, p.text); self:HighlightText() end
    end)
    box:EnableMouse(true)
    box:SetScript("OnMouseDown", function() e:SetFocus() end)
    p.edit = e

    p.status = EllesmereUI.MakeFont(f, 11, nil, 1, 0.4, 0.4, 0.95)
    p.status:SetPoint("TOPLEFT", box, "BOTTOMLEFT", 2, -8)
    p.status:SetPoint("RIGHT", box, "RIGHT", 0, 0)
    p.status:SetJustifyH("LEFT")

    p.confirm = EllesmereUI.BuildPopupButton(f, 130, 28, "Import", function()
        local ok, err = p.onConfirm(Kit.GetEditText(p.edit))
        if ok then Hide() else p.status:SetText(err or "Import failed.") end
    end)
    p.confirm:SetPoint("BOTTOMRIGHT", f, "BOTTOM", -6, 18)
    p.close = EllesmereUI.BuildPopupButton(f, 130, 28, "Close", Hide)
    return p
end

function Kit.TextPopup(o)
    textPopup = textPopup or BuildTextPopup()
    local p = textPopup
    p.readOnly, p.text, p.onConfirm = o.readOnly, o.text or "", o.onConfirm
    p.title:SetText(o.title or "")
    p.subtitle:SetText(o.subtitle or "")
    p.status:SetText("")
    Kit.SetEditText(p.edit, p.text)
    p.close:ClearAllPoints()
    if o.onConfirm then
        p.confirm:Show()
        p.close:SetPoint("BOTTOMLEFT", p.frame, "BOTTOM", 6, 18)
    else
        p.confirm:Hide()
        p.close:SetPoint("BOTTOM", p.frame, "BOTTOM", 0, 18)
    end
    p.dimmer:Show()
    C_Timer.After(0.05, function()
        p.edit:SetFocus()
        if p.readOnly then p.edit:HighlightText() end
    end)
    return p
end
