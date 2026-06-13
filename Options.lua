local _, CRP = ...

-- Single options dialog with tabs. Replaces the various /crp …on/off slash
-- commands; those still work as shortcuts, but the UI is the discoverable path.
local Options = {}
CRP.Options = Options

local AceGUI

local window
local function getAceGUI()
    AceGUI = AceGUI or (LibStub and LibStub("AceGUI-3.0", true))
    return AceGUI
end

local function addFullWidth(parent, widget)
    widget:SetFullWidth(true)
    parent:AddChild(widget)
    return widget
end

local function toggle(parent, label, get, set)
    local cb = AceGUI:Create("CheckBox")
    cb:SetLabel(label)
    cb:SetValue(get() and true or false)
    cb:SetCallback("OnValueChanged", function(_, _, v) set(v and true or false) end)
    return addFullWidth(parent, cb)
end

local function slider(parent, label, min, max, step, get, set)
    local s = AceGUI:Create("Slider")
    s:SetLabel(label)
    s:SetSliderValues(min, max, step)
    s:SetValue(get())
    s:SetCallback("OnValueChanged", function(_, _, v) set(v) end)
    return addFullWidth(parent, s)
end

local function buildGeneral(container)
    container:SetLayout("Flow")
    local g = CRP.db.global

    toggle(container, "Auto-advance pull when all required mobs die",
        function() return g.autoAdvance end,
        function(v) g.autoAdvance = v end)

    toggle(container, "Auto-import incoming plans (skip the confirm prompt)",
        function() return g.autoApplyIncomingPlan end,
        function(v) g.autoApplyIncomingPlan = v end)

    toggle(container, "Auto-show window when entering a raid",
        function() return g.autoShow end,
        function(v) g.autoShow = v end)

    toggle(container, "Reveal window chrome on click instead of hover",
        function() return g.revealOnClick end,
        function(v) g.revealOnClick = v end)

    -- Role override for role-targeted assignments. "auto" clears the override
    -- and falls back to talent detection (Roles.lua); the label shows what auto
    -- currently resolves to so the player can sanity-check it.
    local role = AceGUI:Create("Dropdown")
    local autoText = CRP.Roles and (" (now: " .. CRP.Roles:Get() .. ")") or ""
    role:SetLabel("My role (for role-based assignments)")
    role:SetList({ auto = "Auto-detect" .. autoText, tank = "Tank", healer = "Healer", damage = "Damage" })
    role:SetValue((CRP.Roles and not CRP.Roles:IsAuto() and CRP.db.char.role) or "auto")
    role:SetCallback("OnValueChanged", function(_, _, v)
        if CRP.Roles then CRP.Roles:SetOverride(v) end
        if CRP.ui and CRP.ui.Window then CRP.ui.Window:Refresh() end
    end)
    addFullWidth(container, role)

    toggle(container, "Debug: print kill GUIDs to chat",
        function() return g.debug end,
        function(v) g.debug = v end)
end

local function buildHUD(container)
    container:SetLayout("Flow")
    if not (CRP.HUD and CRP.db.char.combatHUD) then
        local lbl = AceGUI:Create("Label")
        lbl:SetText("Combat HUD module not loaded.")
        addFullWidth(container, lbl)
        return
    end
    local c = CRP.db.char.combatHUD

    -- Open in preview mode (unlocked) so position/size sliders are visible.
    -- Skip the preview if the HUD is disabled — no point unlocking a frame
    -- that's about to stay hidden.
    if c.enabled then CRP.HUD:SetLocked(false) end

    toggle(container, "Enable Combat HUD",
        function() return c.enabled end,
        function(v)
            CRP.HUD:SetEnabled(v)
            if v then CRP.HUD:SetLocked(false) end  -- re-enter preview
        end)

    toggle(container, "Unlock (drag to position)",
        function() return not c.locked end,
        function(v) CRP.HUD:SetLocked(not v) end)

    toggle(container, "Only show in raids/dungeons (recommended)",
        function() return c.instanceOnly ~= false end,
        function(v) CRP.HUD:SetInstanceOnly(v) end)

    local dir = AceGUI:Create("Dropdown")
    dir:SetLabel("Growth direction")
    dir:SetList({ horizontal = "Horizontal", vertical = "Vertical" })
    dir:SetValue(c.direction or "horizontal")
    dir:SetCallback("OnValueChanged", function(_, _, v) CRP.HUD:SetDirection(v) end)
    addFullWidth(container, dir)

    slider(container, "Scale", 0.5, 2.0, 0.05,
        function() return c.scale end,
        function(v) CRP.HUD:SetScale(v) end)

    slider(container, "Icon size", 16, 80, 1,
        function() return c.iconSize end,
        function(v) CRP.HUD:SetIconSize(v) end)

    slider(container, "Spacing", 0, 20, 1,
        function() return c.spacing end,
        function(v) CRP.HUD:SetSpacing(v) end)

    slider(container, "Hide when cooldown above (seconds, 0 = never hide)", 0, 300, 1,
        function() return c.hideThresholdSec or 0 end,
        function(v) CRP.HUD:SetHideThreshold(v) end)

    local reset = AceGUI:Create("Button")
    reset:SetText("Reset position")
    reset:SetCallback("OnClick", function() CRP.HUD:ResetPosition() end)
    addFullWidth(container, reset)

    local help = AceGUI:Create("Label")
    help:SetText("\nIn combat: shows spells, items, and kicks assigned to you for the current pull.\nOut of combat: shows equip prompts. The frame hides automatically if there's nothing to do.")
    addFullWidth(container, help)
end

function Options:Show()
    if not getAceGUI() then
        print("|cffff9933CRP:|r AceGUI-3.0 not available.")
        return
    end
    if window then window:Show(); return end

    window = AceGUI:Create("Frame")
    window:SetTitle("CafeRaidPlanner — Options")
    window:SetLayout("Fill")
    -- Sized for the taller tab (Combat HUD: three toggles, a dropdown, four
    -- sliders, a button and the help text). The General tab is shorter, but a
    -- fixed default keeps the close button visible on both without forcing the
    -- user to resize. AceGUI Frames are still user-resizable from here.
    window:SetWidth(440)
    window:SetHeight(560)
    window:SetCallback("OnClose", function(w)
        window = nil
        -- Re-lock the HUD on close so we don't leave a draggable frame behind.
        if CRP.HUD then CRP.HUD:SetLocked(true) end
        AceGUI:Release(w)
    end)

    local tabs = AceGUI:Create("TabGroup")
    tabs:SetLayout("Flow")
    tabs:SetTabs({
        { value = "general", text = "General" },
        { value = "hud",     text = "Combat HUD" },
    })
    tabs:SetCallback("OnGroupSelected", function(c, _, group)
        c:ReleaseChildren()
        if group == "general" then buildGeneral(c)
        elseif group == "hud"  then buildHUD(c) end
    end)
    tabs:SelectTab("general")
    window:AddChild(tabs)
end
