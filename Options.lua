local _, ns = ...

local DB = ns.DB
local ApplyStandalone = ns.ApplyStandalone
local ApplyStandaloneStyle = ns.ApplyStandaloneStyle
local ApplyStandaloneVisibility = ns.ApplyStandaloneVisibility
local RepositionStandalone = ns.RepositionStandalone
local UpdateStandaloneText = ns.UpdateStandaloneText
local ApplySuggest = ns.ApplySuggest
local ApplySuggestStyle = ns.ApplySuggestStyle
local ApplySuggestVisibility = ns.ApplySuggestVisibility
local RepositionSuggest = ns.RepositionSuggest
local SUGGEST_GLOBAL_SUPPRESSION_DEFAULT = ns.SUGGEST_GLOBAL_SUPPRESSION_DEFAULT

-- Registers our own section via EUI's sanctioned plugin API (PLUGINS_API.md)
-- -- never EUI internals. Runs standalone (OptionalDeps) if EUI isn't loaded.
local function BuildStatusWidgetPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    _, h = W:SectionHeader(parent, "STATUS WIDGET", y); y = y - h

    local function Cfg(k) return DB()[k] end
    local function Set(k, v) DB()[k] = v end

    -- Enabled (+ inline cog: font/size/outline/alignment/frame/
    -- background/border/strata) | Text Color (Pass/Fail swatches)
    local enabledRow
    enabledRow, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enabled",
          getValue = function() return Cfg("standaloneEnabled") == true end,
          setValue = function(v)
              Set("standaloneEnabled", v)
              ApplyStandalone()
              EllesmereUI:RefreshPage()
          end },
        { type = "multiSwatch", text = "Text Color",
          disabled = function() return not Cfg("standaloneEnabled") end,
          disabledTooltip = "Enabled",
          swatches = {
              { tooltip = "Pass Color", hasAlpha = false,
                getValue = function()
                    local c = Cfg("standaloneColor") or { r = 1, g = 1, b = 1 }
                    return c.r, c.g, c.b
                end,
                setValue = function(r, g, b)
                    Set("standaloneColor", { r = r, g = g, b = b })
                    ApplyStandaloneStyle(); UpdateStandaloneText()
                end },
              { tooltip = "Fail Color", hasAlpha = false,
                getValue = function()
                    local c = Cfg("standaloneFailColor") or { r = 1, g = 0, b = 0 }
                    return c.r, c.g, c.b
                end,
                setValue = function(r, g, b)
                    Set("standaloneFailColor", { r = r, g = g, b = b })
                    UpdateStandaloneText()
                end },
          } })
    if not EllesmereUI._prebuilding then
        local rgn = enabledRow._leftRegion
        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
        EllesmereUI.BuildInlineCog(rgn, {
            title = "Status Widget Settings",
            minWidth = 300,
            rows = {
                { type = "dropdown", label = "Font",
                  values = fontValues, order = fontOrder,
                  get = function() return Cfg("standaloneFont") or "__global" end,
                  set = function(v) Set("standaloneFont", v); ApplyStandaloneStyle() end },
                { type = "slider", label = "Font Size", min = 8, max = 40, step = 1,
                  get = function() return Cfg("standaloneSize") or 14 end,
                  set = function(v) Set("standaloneSize", v); ApplyStandaloneStyle() end },
                { type = "dropdown", label = "Font Outline",
                  values = { INHERIT = "Default", NONE = "None", OUTLINE = "Thin", THICKOUTLINE = "Thick" },
                  order = { "INHERIT", "NONE", "OUTLINE", "THICKOUTLINE" },
                  get = function() return Cfg("standaloneOutline") or "INHERIT" end,
                  set = function(v) Set("standaloneOutline", v); ApplyStandaloneStyle() end },
                { type = "dropdown", label = "Alignment",
                  values = { LEFT = "Left", CENTER = "Center", RIGHT = "Right" },
                  order = { "LEFT", "CENTER", "RIGHT" },
                  get = function() return Cfg("standaloneAlign") or "CENTER" end,
                  set = function(v) Set("standaloneAlign", v); ApplyStandaloneStyle() end },
                { type = "slider", label = "Frame Width", min = 60, max = 300, step = 1,
                  get = function() return Cfg("standaloneWidth") or 160 end,
                  set = function(v) Set("standaloneWidth", v); ApplyStandaloneStyle() end },
                { type = "slider", label = "Frame Height", min = 16, max = 60, step = 1,
                  get = function() return Cfg("standaloneHeight") or 20 end,
                  set = function(v) Set("standaloneHeight", v); ApplyStandaloneStyle() end },
                { type = "colorpicker", label = "Background Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("standaloneBackgroundColor") or { r = 0, g = 0, b = 0, a = 0 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("standaloneBackgroundColor", { r = r, g = g, b = b, a = a }); ApplyStandaloneStyle()
                  end },
                { type = "colorpicker", label = "Border Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("standaloneBorderColor") or { r = 0, g = 0, b = 0, a = 1 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("standaloneBorderColor", { r = r, g = g, b = b, a = a }); ApplyStandaloneStyle()
                  end },
                { type = "slider", label = "Border Size", min = 0, max = 4, step = 1,
                  get = function() return Cfg("standaloneBorderSize") or 0 end,
                  set = function(v) Set("standaloneBorderSize", v); ApplyStandaloneStyle() end },
                { type = "dropdown", label = "Frame Strata",
                  values = EllesmereUI.FRAME_STRATA_LABELS,
                  order = EllesmereUI.FRAME_STRATA_ORDER_BASE,
                  get = function() return Cfg("standaloneStrata") or "HIGH" end,
                  set = function(v) Set("standaloneStrata", v); ApplyStandaloneStyle() end },
            },
            icon = EllesmereUI.RESIZE_ICON,
        })
    end
    y = y - h

    -- Lock Position & Disable Click | Show Out of Combat
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Lock Position & Disable Click",
          disabled = function() return not Cfg("standaloneEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Lock the display in place and make it click-through; no dragging and no mouse interaction until unlocked.",
          getValue = function() return Cfg("standaloneLocked") == true end,
          setValue = function(v)
              Set("standaloneLocked", v)
              RepositionStandalone()
          end },
        { type = "toggle", text = "Show Out of Combat",
          disabled = function() return not Cfg("standaloneEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Keep the display visible out of combat, showing the last computed stats.",
          getValue = function() return Cfg("standaloneShowOOC") == true end,
          setValue = function(v)
              Set("standaloneShowOOC", v)
              ApplyStandaloneVisibility()
          end })
    y = y - h

    -- "Hold Shift+Click..." label, alone on its row.
    _, h = W:DualRow(parent, y,
        { type = "label", text = "Hold Shift+Click to Freely Move" },
        { type = "spacer" })
    y = y - h

    return math.abs(y)
end

-- CDM glow (Glow.lua): glows the suggested spell's Cooldown Manager icon.
local function BuildCDMGlowPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    _, h = W:SectionHeader(parent, "CDM GLOW", y); y = y - h

    local function Cfg(k) return DB()[k] end
    local function Set(k, v) DB()[k] = v; ns.ApplyCDMGlow() end
    local off = function() return not ns.CDMGlowEnabled() end

    local styleValues, styleOrder = {}, {}
    local styles = EllesmereUI.Glows and EllesmereUI.Glows.STYLES or {}
    for _, idx in ipairs(ns.CDM_GLOW_STYLES) do
        if styles[idx] then
            styleValues[idx] = styles[idx].name
            styleOrder[#styleOrder + 1] = idx
        end
    end
    local function Style() return Cfg("cdmGlowStyle") or 6 end
    local function IsBlackout() return styles[Style()] and styles[Style()].solidFill end

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enabled",
          tooltip = "Glow the suggested spell's icon in the Cooldown Manager, in combat. Works for spells tracked by the Cooldown Manager (Essential and Utility bars).",
          getValue = function() return ns.CDMGlowEnabled() end,
          setValue = function(v)
              if v then Set("cdmGlow", nil) else Set("cdmGlow", false) end
              EllesmereUI:RefreshPage()
          end },
        { type = "dropdown", text = "Glow Style", values = styleValues, order = styleOrder,
          tooltip = "Only styles that keep animating in restricted combat are offered.",
          disabled = off, disabledTooltip = "Enabled",
          getValue = Style,
          setValue = function(v) Set("cdmGlowStyle", v); EllesmereUI:RefreshPage() end })
    y = y - h

    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Custom Color",
          tooltip = "Off: the style's own colors (black for Blackout).",
          disabled = off, disabledTooltip = "Enabled",
          getValue = function() return Cfg("cdmGlowColor") ~= nil end,
          setValue = function(v)
              Set("cdmGlowColor", v and { r = 1, g = 0.82, b = 0 } or nil)
              EllesmereUI:RefreshPage()
          end },
        { type = "colorpicker", text = "Glow Color", hasAlpha = false,
          disabled = function() return off() or Cfg("cdmGlowColor") == nil end,
          disabledTooltip = "Custom Color",
          getValue = function()
              local c = Cfg("cdmGlowColor") or { r = 1, g = 0.82, b = 0 }
              return c.r, c.g, c.b
          end,
          setValue = function(r, g, b) Set("cdmGlowColor", { r = r, g = g, b = b }) end })
    y = y - h

    -- Always shown; only unlocked for the Blackout style.
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Blackout Opacity", min = 0.1, max = 1.0, step = 0.05,
          disabled = function() return off() or not IsBlackout() end,
          disabledTooltip = "This option only applies to the Blackout glow style.",
          getValue = function() return Cfg("cdmGlowAlpha") or 0.5 end,
          setValue = function(v) Set("cdmGlowAlpha", v) end },
        { type = "spacer" })
    y = y - h

    return math.abs(y)
end

local function BuildSuggestionWidgetPage(parent, yOffset)
    local W = EllesmereUI.Widgets
    local y = yOffset
    local _, h

    _, h = W:SectionHeader(parent, "SUGGESTION WIDGET", y); y = y - h

    local function Cfg(k) return DB()[k] end
    local function Set(k, v) DB()[k] = v end

    -- Enabled (+ inline cog: font/size/outline, icon show/size/anchor, frame,
    -- background/border/strata) | Text Color
    local enabledRow
    enabledRow, h = W:DualRow(parent, y,
        { type = "toggle", text = "Enabled",
          getValue = function() return Cfg("suggestEnabled") == true end,
          setValue = function(v)
              Set("suggestEnabled", v)
              ApplySuggest()
              EllesmereUI:RefreshPage()
          end },
        { type = "colorpicker", text = "Text Color", hasAlpha = false,
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          getValue = function()
              local c = Cfg("suggestTextColor") or { r = 1, g = 1, b = 1 }
              return c.r, c.g, c.b
          end,
          setValue = function(r, g, b)
              Set("suggestTextColor", { r = r, g = g, b = b })
              ApplySuggestStyle()
          end })
    if not EllesmereUI._prebuilding then
        local rgn = enabledRow._leftRegion
        local fontValues, fontOrder = EllesmereUI.BuildFontDropdownData()
        EllesmereUI.BuildInlineCog(rgn, {
            title = "Suggestion Widget Settings",
            minWidth = 300,
            rows = {
                { type = "dropdown", label = "Font",
                  values = fontValues, order = fontOrder,
                  get = function() return Cfg("suggestFont") or "__global" end,
                  set = function(v) Set("suggestFont", v); ApplySuggestStyle() end },
                { type = "slider", label = "Font Size", min = 8, max = 40, step = 1,
                  get = function() return Cfg("suggestSize") or 14 end,
                  set = function(v) Set("suggestSize", v); ApplySuggestStyle() end },
                { type = "dropdown", label = "Font Outline",
                  values = { INHERIT = "Default", NONE = "None", OUTLINE = "Thin", THICKOUTLINE = "Thick" },
                  order = { "INHERIT", "NONE", "OUTLINE", "THICKOUTLINE" },
                  get = function() return Cfg("suggestOutline") or "INHERIT" end,
                  set = function(v) Set("suggestOutline", v); ApplySuggestStyle() end },
                { type = "toggle", label = "Show Spell Icon",
                  get = function() return Cfg("suggestShowIcon") ~= false end,
                  set = function(v) Set("suggestShowIcon", v); ApplySuggestStyle() end },
                { type = "slider", label = "Icon Size", min = 8, max = 64, step = 1,
                  disabled = function() return Cfg("suggestShowIcon") == false end,
                  disabledTooltip = "Show Spell Icon",
                  get = function() return Cfg("suggestIconSize") or 24 end,
                  set = function(v) Set("suggestIconSize", v); ApplySuggestStyle() end },
                { type = "dropdown", label = "Icon Anchor",
                  disabled = function() return Cfg("suggestShowIcon") == false end,
                  disabledTooltip = "Show Spell Icon",
                  values = { LEFT = "Left", RIGHT = "Right", TOP = "Top", BOTTOM = "Bottom" },
                  order = { "LEFT", "RIGHT", "TOP", "BOTTOM" },
                  get = function() return Cfg("suggestIconAnchor") or "LEFT" end,
                  set = function(v) Set("suggestIconAnchor", v); ApplySuggestStyle() end },
                { type = "slider", label = "Frame Width", min = 40, max = 300, step = 1,
                  get = function() return Cfg("suggestWidth") or 160 end,
                  set = function(v) Set("suggestWidth", v); ApplySuggestStyle() end },
                { type = "slider", label = "Frame Height", min = 16, max = 80, step = 1,
                  get = function() return Cfg("suggestHeight") or 32 end,
                  set = function(v) Set("suggestHeight", v); ApplySuggestStyle() end },
                { type = "colorpicker", label = "Background Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("suggestBackgroundColor") or { r = 0, g = 0, b = 0, a = 0 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("suggestBackgroundColor", { r = r, g = g, b = b, a = a }); ApplySuggestStyle()
                  end },
                { type = "colorpicker", label = "Border Color", hasAlpha = true,
                  get = function()
                      local c = Cfg("suggestBorderColor") or { r = 0, g = 0, b = 0, a = 1 }
                      return c.r, c.g, c.b, c.a
                  end,
                  set = function(r, g, b, a)
                      Set("suggestBorderColor", { r = r, g = g, b = b, a = a }); ApplySuggestStyle()
                  end },
                { type = "slider", label = "Border Size", min = 0, max = 4, step = 1,
                  get = function() return Cfg("suggestBorderSize") or 0 end,
                  set = function(v) Set("suggestBorderSize", v); ApplySuggestStyle() end },
                { type = "dropdown", label = "Frame Strata",
                  values = EllesmereUI.FRAME_STRATA_LABELS,
                  order = EllesmereUI.FRAME_STRATA_ORDER_BASE,
                  get = function() return Cfg("suggestStrata") or "HIGH" end,
                  set = function(v) Set("suggestStrata", v); ApplySuggestStyle() end },
            },
            icon = EllesmereUI.RESIZE_ICON,
        })
    end
    y = y - h

    -- Lock Position & Disable Click | Show Out of Combat
    _, h = W:DualRow(parent, y,
        { type = "toggle", text = "Lock Position & Disable Click",
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Lock the display in place and make it click-through; no dragging and no mouse interaction until unlocked.",
          getValue = function() return Cfg("suggestLocked") == true end,
          setValue = function(v)
              Set("suggestLocked", v)
              RepositionSuggest()
          end },
        { type = "toggle", text = "Show Out of Combat",
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Keep the display visible out of combat, showing the current live suggestion.",
          getValue = function() return Cfg("suggestShowOOC") == true end,
          setValue = function(v)
              Set("suggestShowOOC", v)
              ApplySuggestVisibility()
          end })
    y = y - h

    -- "Hold Shift+Click..." label | Enable TTS
    _, h = W:DualRow(parent, y,
        { type = "label", text = "Hold Shift+Click to Freely Move" },
        { type = "toggle", text = "Enable TTS",
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Speaks a short name for the suggested spell whenever it changes. Only spells with a configured alias are spoken for now.",
          getValue = function() return Cfg("suggestTTSEnabled") == true end,
          setValue = function(v) Set("suggestTTSEnabled", v) end })
    y = y - h

    -- Global Suppression
    _, h = W:DualRow(parent, y,
        { type = "slider", text = "Global Suppression", min = 0.1, max = 1.0, step = 0.1,
          disabled = function() return not Cfg("suggestEnabled") end,
          disabledTooltip = "Enabled",
          tooltip = "Seconds the suggestion holds steady after a cast, and again after it changes -- a new cast always restarts the hold fresh rather than stacking.",
          getValue = function() return Cfg("suggestGlobalSuppression") or SUGGEST_GLOBAL_SUPPRESSION_DEFAULT end,
          setValue = function(v) Set("suggestGlobalSuppression", v) end },
        { type = "spacer" })
    y = y - h

    return math.abs(y)
end

if EllesmereUI and EllesmereUI.RegisterPlugin then
    EllesmereUI.RegisterPlugin("APLforEUI", {
        label = "APL for EUI",
        modules = {
            {
                key = "APL",
                title = "APL",
                description = "Create and edit APLs, and choose the one that runs for each spec.",
                pages = { "APLs", "Lists", "Building Blocks" },
                -- Custom frames (condition boxes, builder rows) can't run
                -- under the search pre-build's stub widgets.
                searchPrebuild = false,
                buildPage = function(pageName, parent, yOffset)
                    -- getHeaderBuilder only tells EUI's page cache that a
                    -- header exists; the page draws it, as EUI's own pages
                    -- do (EUI_AuraBuffReminders_Options.lua).
                    EllesmereUI:SetContentHeader(ns.Editor.BuildHeader)
                    if pageName == "Lists" then return ns.Editor.BuildListsPage(parent, yOffset) end
                    if pageName == "Building Blocks" then return ns.Editor.BuildBlocksPage(parent, yOffset) end
                    return ns.Editor.BuildAPLsPage(parent, yOffset)
                end,
                getHeaderBuilder = function() return ns.Editor.BuildHeader end,
                onModuleLeave = function() ns.EditorKit.HideSuggest() end,
            },
            {
                key = "Widgets",
                title = "Widgets",
                description = "Standalone on-screen displays for the ST/AOE compliance stats and the live APL suggestion.",
                pages = { "Status Widget", "Suggestion Widget", "CDM Glow" },
                buildPage = function(pageName, parent, yOffset)
                    if pageName == "Suggestion Widget" then
                        return BuildSuggestionWidgetPage(parent, yOffset)
                    end
                    if pageName == "CDM Glow" then
                        return BuildCDMGlowPage(parent, yOffset)
                    end
                    return BuildStatusWidgetPage(parent, yOffset)
                end,
            },
        },
    })
end
