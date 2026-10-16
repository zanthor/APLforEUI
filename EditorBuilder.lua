local _, ns = ...

-------------------------------------------------------------------------------
--  Condition editor: one stored text, two views. Text view is the
--  autocompleting box (EditorKit.ExprBox); Builder view edits an AND/OR
--  group of "[is/is not] <read> [op value]" rows (Expression.lua's builder
--  form) and writes the same text back. Text that doesn't fit the builder
--  (arithmetic, functions) stays in Text view.
-------------------------------------------------------------------------------
local Kit = ns.EditorKit
local Expr = ns.Expr
local Engine = ns.Engine

local E = Kit.state
E.forms = E.forms or setmetatable({}, { __mode = "k" })

-- One view for every condition in the editor, chosen in the header and
-- remembered per account.
function Kit.ConditionMode()
    return ns.DB().conditionMode == "text" and "text" or "builder"
end

function Kit.SetConditionMode(mode)
    ns.DB().conditionMode = mode == "text" and "text" or nil
    Kit.RebuildAll()
end

-- What a builder row can read. source: where its subjects come from.
-- numeric: compared with an operator and a value; otherwise a yes/no read.
local CATEGORIES = {
    { key = "buff", label = "Buff active", tpl = "buff.%s.up", source = "names" },
    { key = "cooldown", label = "Cooldown ready", tpl = "cooldown.%s.ready", source = "names" },
    { key = "usable", label = "Usable", tpl = "usable.%s", source = "names" },
    { key = "talent", label = "Talent known", tpl = "talent.%s", source = "names" },
    { key = "charges", label = "Charges", tpl = "charges.%s", source = "names", numeric = true },
    { key = "charges_full", label = "Charges full", tpl = "charges.%s.full", source = "names" },
    { key = "prev", label = "Last cast was", tpl = "prev.%s", source = "names" },
    { key = "channeling", label = "Channeling", tpl = "channeling.%s", source = "names" },
    { key = "override", label = "Button now is", tpl = "override.%s", source = "names", numeric = true, valueIsName = true },
    { key = "base_cd", label = "Base cooldown", tpl = "spell.%s.base_cd", source = "names", numeric = true },
    { key = "resource", label = "Resource", tpl = "resource.%s", source = "powers", numeric = true },
    { key = "timer_up", label = "Timer running", tpl = "timer.%s.up", source = "timers" },
    { key = "timer_remains", label = "Timer remaining", tpl = "timer.%s.remains", source = "timers", numeric = true },
    { key = "counter", label = "Counter", tpl = "counter.%s", source = "counters", numeric = true },
    { key = "variable", label = "Variable", tpl = "variable.%s", source = "variables", optionalOp = true },
    { key = "combat_time", label = "Combat time", tpl = "combat.time", numeric = true },
    { key = "combat_casts", label = "Casts this combat", tpl = "combat.casts", numeric = true },
    { key = "targets", label = "Targets", tpl = "targets", numeric = true },
    { key = "bloodlust", label = "Bloodlust active", tpl = "bloodlust" },
}
local CAT_BY_KEY, CAT_VALUES, CAT_ORDER = {}, {}, {}
for _, c in ipairs(CATEGORIES) do
    CAT_BY_KEY[c.key] = c
    CAT_VALUES[c.key] = c.label
    CAT_ORDER[#CAT_ORDER + 1] = c.key
end

local OPS = { ">=", ">", "=", "!=", "<", "<=" }
local OP_VALUES = {}
for _, op in ipairs(OPS) do OP_VALUES[op] = op end
local OPT_OPS = { "", ">=", ">", "=", "!=", "<", "<=" }
local OPT_OP_VALUES = { [""] = "is true" }
for _, op in ipairs(OPS) do OPT_OP_VALUES[op] = op end

-- 4 ways a group can combine its rows: op + neg.
local GROUP_VALUES = { ["and"] = "All of these", ["or"] = "Any of these", nand = "Not all of these", nor = "None of these" }
local GROUP_ORDER = { "and", "or", "nand", "nor" }

local function Subjects(def, source)
    local out = {}
    if source == "names" then
        for name in pairs(def.names or {}) do out[#out + 1] = name end
    elseif source == "timers" then
        for _, t in ipairs(def.timers or {}) do out[#out + 1] = t.name end
    elseif source == "counters" then
        for _, c in ipairs(def.counters or {}) do out[#out + 1] = c.name end
    elseif source == "variables" then
        for _, v in ipairs(def.variables or {}) do out[#out + 1] = v.name end
    elseif source == "powers" then
        for key in pairs(Enum.PowerType) do
            out[#out + 1] = (key:gsub("(%l)(%u)", "%1_%2"):lower())
        end
    end
    table.sort(out)
    return out
end

-- "buff.hotjs.up" -> category, subject. Fixed reads ("targets") have no subject.
local function SplitRef(ref)
    for _, c in ipairs(CATEGORIES) do
        if not c.tpl:find("%s", 1, true) then
            if ref == c.tpl then return c, nil end
        else
            local pattern = "^" .. c.tpl:gsub("%.", "%%."):gsub("%%s", "([%%w_]+)") .. "$"
            local subject = ref:match(pattern)
            if subject then return c, subject end
        end
    end
    return nil
end

local function MakeRef(c, subject)
    if not c.tpl:find("%s", 1, true) then return c.tpl end
    return c.tpl:format(subject or "")
end

-- A complete new row, so the builder never holds a half-filled one.
local function NewRow(def)
    local names = Subjects(def, "names")
    if names[1] then return { k = "cond", neg = false, ref = MakeRef(CAT_BY_KEY.buff, names[1]) } end
    return { k = "cond", neg = false, ref = "targets", op = ">=", value = "2" }
end

-------------------------------------------------------------------------------
--  Builder view
-------------------------------------------------------------------------------
local ROW_H = 36

-- One frame per builder line, placed like the page's own rows.
local function Line(parent, y, depth)
    local pad = EllesmereUI.CONTENT_PAD
    local f = CreateFrame("Frame", nil, parent)
    f:SetSize(parent:GetWidth() - pad * 2, ROW_H)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", pad + 20 + depth * 24, y)
    return f
end

local function Dropdown(f, w, values, order, get, set, editable)
    local dd = EllesmereUI.BuildDropdownControl(f, w, f:GetFrameLevel() + 2, values, order, get, set)
    dd:SetEnabled(editable)
    return dd
end

local function BuildGroup(parent, y, def, group, depth, ctx)
    local editable = ctx.editable

    -- Group line: optional caption ("Only If"), how the rows combine, and
    -- add buttons.
    local f = Line(parent, y, depth)
    local caption
    if depth == 0 and ctx.caption then
        caption = EllesmereUI.MakeFont(f, 13, nil, 1, 1, 1, 1)
        caption:SetPoint("LEFT", f, "LEFT", 0, 0)
        caption:SetText(ctx.caption)
    end
    local mode = Dropdown(f, 170, GROUP_VALUES, GROUP_ORDER,
        function() return (group.neg and "n" or "") .. group.op end,
        function(v)
            group.neg = v:sub(1, 1) == "n"
            group.op = group.neg and v:sub(2) or v
            ctx.commit()
        end, editable)
    if caption then mode:SetPoint("LEFT", caption, "RIGHT", 12, 0)
    else mode:SetPoint("LEFT", f, "LEFT", 0, 0) end
    local addRow = EllesmereUI.BuildPopupButton(f, 100, 26, "+ Condition", function()
        group.items[#group.items + 1] = NewRow(def)
        ctx.commit()
    end)
    addRow:SetPoint("LEFT", mode, "RIGHT", 12, 0)
    addRow:SetEnabled(editable)
    local last = addRow
    if depth < 2 then
        local addGroup = EllesmereUI.BuildPopupButton(f, 80, 26, "+ Group", function()
            group.items[#group.items + 1] = { k = "group", op = "or", neg = false, items = { NewRow(def) } }
            ctx.commit()
        end)
        addGroup:SetPoint("LEFT", addRow, "RIGHT", 8, 0)
        addGroup:SetEnabled(editable)
        last = addGroup
    end
    if ctx.parentGroup then
        local parentItems = ctx.parentGroup.items
        local del = Kit.DeleteGlyph(f, function()
            for i, it in ipairs(parentItems) do
                if it == group then table.remove(parentItems, i) break end
            end
            ctx.commit()
        end, "Remove group")
        del:SetPoint("LEFT", last, "RIGHT", 12, 0)
        del:SetEnabled(editable)
    end
    y = y - ROW_H

    if #group.items == 0 then
        local note = Line(parent, y, depth + 1)
        local fs = EllesmereUI.MakeFont(note, 12, nil, 1, 1, 1, EllesmereUI.TEXT_DIM_A)
        fs:SetPoint("LEFT", note, "LEFT", 0, 0)
        fs:SetText("No conditions: always true.")
        y = y - ROW_H
    end

    for i, item in ipairs(group.items) do
        if item.k == "group" then
            local saved = ctx.parentGroup
            ctx.parentGroup = group
            y = BuildGroup(parent, y, def, item, depth + 1, ctx)
            ctx.parentGroup = saved
        else
            local row = Line(parent, y, depth + 1)
            local cat, subject = SplitRef(item.ref)
            cat = cat or CAT_BY_KEY.targets

            local isDD = Dropdown(row, 105, { is = "is", isnot = "is not" }, { "is", "isnot" },
                function() return item.neg and "isnot" or "is" end,
                function(v) item.neg = v == "isnot"; ctx.commit() end, editable)
            isDD:SetPoint("LEFT", row, "LEFT", 0, 0)

            local catDD = Dropdown(row, 150, CAT_VALUES, CAT_ORDER,
                function() return cat.key end,
                function(v)
                    local c = CAT_BY_KEY[v]
                    local subs = c.source and Subjects(def, c.source) or {}
                    item.ref = MakeRef(c, subs[1])
                    if c.numeric then item.op, item.value = item.op or ">=", item.value or "1"
                    else item.op, item.value = nil, nil end
                    ctx.commit()
                end, editable)
            catDD:SetPoint("LEFT", isDD, "RIGHT", 6, 0)
            local anchor = catDD

            if cat.source then
                local subs = Subjects(def, cat.source)
                local subValues = {}
                for _, s in ipairs(subs) do subValues[s] = s end
                if subject and not subValues[subject] then
                    subValues[subject] = subject .. " (missing)"
                    subs[#subs + 1] = subject
                end
                local subDD = Dropdown(row, 170, subValues, subs,
                    function() return subject end,
                    function(v) item.ref = MakeRef(cat, v); ctx.commit() end, editable)
                subDD:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
                anchor = subDD
            end

            if cat.numeric or cat.optionalOp then
                local ops, opValues = OPS, OP_VALUES
                if cat.optionalOp then ops, opValues = OPT_OPS, OPT_OP_VALUES end
                local opDD = Dropdown(row, 100, opValues, ops,
                    function() return item.op or "" end,
                    function(v)
                        if v == "" then item.op, item.value = nil, nil
                        else item.op = v; item.value = item.value or "1" end
                        ctx.commit()
                    end, editable)
                opDD:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
                anchor = opDD
                if item.op then
                    local box = CreateFrame("EditBox", nil, row)
                    box:SetSize(cat.valueIsName and 150 or 70, 26)
                    box:SetPoint("LEFT", anchor, "RIGHT", 6, 0)
                    box:SetAutoFocus(false)
                    box:SetFont(EllesmereUI.EXPRESSWAY, 12, "")
                    box:SetTextInsets(6, 6, 0, 0)
                    box:SetTextColor(1, 1, 1, 0.9)
                    EllesmereUI.SolidTex(box, "BACKGROUND", 0, 0, 0, 0.5):SetAllPoints()
                    EllesmereUI.MakeBorder(box, 1, 1, 1, 0.2)
                    Kit.SetEditText(box, item.value)
                    box:SetEnabled(editable)
                    local function Commit(self)
                        local v = Kit.GetEditText(self):match("^%s*(.-)%s*$")
                        if v ~= "" and v ~= item.value then item.value = v; ctx.commit() end
                    end
                    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
                    box:SetScript("OnEditFocusLost", Commit)
                    box:SetScript("OnEscapePressed", function(self) Kit.SetEditText(self, item.value); self:ClearFocus() end)
                    anchor = box
                end
            end

            local del = Kit.DeleteGlyph(row, function()
                table.remove(group.items, i)
                ctx.commit()
            end, "Remove condition")
            del:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
            del:SetEnabled(editable)
            y = y - ROW_H
        end
    end
    return y
end

-------------------------------------------------------------------------------
--  The editor: mode switch, then the chosen view.
--  o = { owner (table the condition belongs to; remembers its working form),
--        get, set(text), editable, label }
-------------------------------------------------------------------------------
function Kit.Condition(parent, y, def, o)
    local text = o.get() or ""
    local form, why = Expr.ToForm(text)
    -- Keep a working form across rebuilds while it still matches the text,
    -- so group structure the text alone can't express (e.g. an empty
    -- group) isn't thrown away.
    local kept = E.forms[o.owner]
    if kept and Expr.FromForm(kept) == text then form = kept end
    local mode = Kit.ConditionMode()
    -- Builder view, but this text has no builder form: show it as text and
    -- say why, instead of hiding it.
    local textOnly = mode == "builder" and not form
    if not form then mode = "text" end

    if mode == "text" then
        return (Kit.ExprBox(parent, y, {
            caption = o.label,
            note = textOnly and ("text only: " .. tostring(why)) or nil,
            get = o.get,
            set = function(t) E.forms[o.owner] = nil; o.set(t) end,
            check = function(t) return Engine.CheckExpr(def, t) end,
            suggest = Kit.Suggester(def),
            editable = o.editable,
        }))
    end

    E.forms[o.owner] = form
    local ctx = {
        editable = o.editable,
        caption = o.label,
        commit = function()
            o.set(Expr.FromForm(form))
            Kit.Rebuild()
        end,
    }
    return BuildGroup(parent, y, def, form, 0, ctx)
end
