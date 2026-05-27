local _, CRP = ...

-- Combat HUD: a small row of icons for the current pull's assignments that
-- belong to *me* (same filter as the personal view). Appears on combat start,
-- hides on combat end. Each icon dims with a cooldown swipe when the action
-- isn't currently available (item not in bags / on cooldown, spell on cd).
local HUD = {}
CRP.HUD = HUD

local DEFAULTS = {
    point = "CENTER",
    relPoint = "CENTER",
    x = 0,
    y = -180,
    iconSize = 40,
    spacing = 4,
    scale = 1.0,
    locked = true,
}

local function cfg()
    -- Per-character: people on multiple toons want different placements.
    local db = CRP.db and CRP.db.char
    if not db then return DEFAULTS end
    db.combatHUD = db.combatHUD or {}
    for k, v in pairs(DEFAULTS) do
        if db.combatHUD[k] == nil then db.combatHUD[k] = v end
    end
    return db.combatHUD
end

-- GetItemCooldown moved out of the global namespace in newer clients (Cata
-- Classic moved it to C_Container, retail to C_Item). Pick whichever this
-- client exposes; fall back to "no cooldown info" so the icon still renders.
local function itemCooldown(itemId)
    if GetItemCooldown then return GetItemCooldown(itemId) end
    if C_Container and C_Container.GetItemCooldown then return C_Container.GetItemCooldown(itemId) end
    if C_Item and C_Item.GetItemCooldown then return C_Item.GetItemCooldown(itemId) end
    return 0, 0, 1
end

-- Tracked from PLAYER_REGEN_DISABLED/ENABLED. We don't trust InCombatLockdown()
-- inside the REGEN_DISABLED handler — at that exact moment the engine has fired
-- the event but may not have flipped the lockdown flag yet, so polling it
-- would tell us we're still out of combat.
local combatActive = false

local frame
local iconPool = {}
-- Most recently rendered assignment list — used by lightweight refreshes
-- (cooldown/bag events) so we don't rebuild the layout on every tick.
local currentEntries = {}

local function createIcon(parent)
    local f = CreateFrame("Frame", nil, parent)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetAllPoints()
    -- CooldownFrameTemplate gives us the standard radial swipe + numeric text
    -- that OmniCC etc. already know how to skin.
    f.cd = CreateFrame("Cooldown", nil, f, "CooldownFrameTemplate")
    f.cd:SetAllPoints()
    f.count = f:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
    f.count:SetPoint("BOTTOMRIGHT", -1, 1)
    return f
end

local function acquireIcon(i)
    iconPool[i] = iconPool[i] or createIcon(frame)
    return iconPool[i]
end

local function hideAllIcons()
    for _, f in ipairs(iconPool) do f:Hide() end
end

local function applyDb()
    if not frame then return end
    local c = cfg()
    frame:ClearAllPoints()
    frame:SetPoint(c.point, UIParent, c.relPoint, c.x, c.y)
    frame:SetScale(c.scale)
    frame:EnableMouse(not c.locked)
end

local function ensureFrame()
    if frame then return end
    frame = CreateFrame("Frame", "CafeRaidPlannerCombatHUD", UIParent)
    frame:SetFrameStrata("MEDIUM")
    frame:SetSize(40, 40)
    frame:SetMovable(true)
    frame:SetClampedToScreen(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not cfg().locked then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        local c = cfg()
        c.point, c.relPoint, c.x, c.y = point, relPoint, x, y
    end)
    -- Drag background — only visible when unlocked, so the user can grab even
    -- when the icon row is empty.
    frame.bg = frame:CreateTexture(nil, "BACKGROUND")
    frame.bg:SetAllPoints()
    frame.bg:SetColorTexture(0.2, 0.5, 1, 0.25)
    frame.bg:Hide()
    applyDb()
end

-- Equip assignments only make sense between pulls — you can't swap gear in
-- combat. Everything else only makes sense *during* combat. One frame, two
-- modes; combat-state toggles which assignment kinds we surface.
local function entriesForPull()
    if not (CRP.Plan and CRP.ui and CRP.ui.IsMyAssignment) then return {} end
    local pull = CRP.Plan:CurrentPull()
    if not pull or not pull.assignments then return {} end
    local inCombat = combatActive
    local out = {}
    for _, a in ipairs(pull.assignments) do
        local k = a.kind
        local relevant
        if inCombat then
            relevant = (k == "spell" or k == "kick" or k == "item")
        else
            relevant = (k == "equip")
        end
        -- Reminders have no actionable gate (no item/spell to check) — skip
        -- them in the HUD. The main window still surfaces them in Pull Notes.
        if relevant and type(a.id) == "number" and CRP.ui.IsMyAssignment(a) then
            -- Item/equip assignments only appear if the player actually has
            -- the item in their bags. A grenade you don't carry or a swap
            -- piece you sold off is noise, not a prompt — drop it entirely.
            -- (On-cooldown-but-in-bags still appears, dimmed with the swipe.)
            if a.kind == "item" or a.kind == "equip" then
                if (GetItemCount(a.id) or 0) > 0 then out[#out + 1] = a end
            else
                out[#out + 1] = a
            end
        end
    end
    return out
end

-- Set an icon's texture, cooldown swipe, item count, and dim/bright state from
-- a single assignment. Re-callable on cooldown/bag events without re-layout.
local function paintIcon(icon, a)
    local texture, start, duration, ready, count
    if a.kind == "item" or a.kind == "equip" then
        local _, _, _, _, _, _, _, _, _, tex = GetItemInfo(a.id)
        texture = tex
        count = GetItemCount(a.id) or 0
        if count <= 0 then
            ready = false
        else
            local s, d = itemCooldown(a.id)
            start, duration = s, d
            ready = (d or 0) == 0
        end
    else
        -- Assignment id is rank-specific; query the cooldown by name so we
        -- track whichever rank the player actually has (same fix as knowsSpell).
        -- Use a statement, not `a and b or c` — the ternary form collapses to
        -- one return value and silently drops `duration`.
        local name, _, tex = GetSpellInfo(a.id)
        texture = tex
        local s, d
        if name then s, d = GetSpellCooldown(name)
        else         s, d = GetSpellCooldown(a.id) end
        start, duration = s, d
        ready = (d or 0) == 0
    end
    icon.tex:SetTexture(texture or "Interface\\Icons\\INV_Misc_QuestionMark")
    if start and duration and duration > 1.5 then
        -- GCD (≤1.5s) creates flicker noise; ignore.
        icon.cd:SetCooldown(start, duration)
    else
        -- Cooldown:Clear() is retail-only; SetCooldown(0,0) is the BCC-safe
        -- way to hide the swipe.
        icon.cd:SetCooldown(0, 0)
    end
    icon.tex:SetVertexColor(ready and 1 or 0.35, ready and 1 or 0.35, ready and 1 or 0.35)
    if (a.kind == "item" or a.kind == "equip") and count and count > 1 then
        icon.count:SetText(count)
        icon.count:Show()
    else
        icon.count:Hide()
    end
end

local function shouldShow()
    if not cfg().locked then return true end  -- preview while configuring
    -- Out of combat we still want to show equip prompts; the entry-list filter
    -- (entriesForPull) decides what's relevant, and Refresh hides the frame if
    -- the resulting list is empty.
    return true
end

function HUD:Refresh()
    ensureFrame()
    if not shouldShow() then
        frame:Hide()
        return
    end
    local entries = entriesForPull()
    currentEntries = entries
    if #entries == 0 and cfg().locked then
        frame:Hide()
        return
    end
    local c = cfg()
    local size = c.iconSize
    local spacing = c.spacing
    hideAllIcons()
    if #entries == 0 then
        -- Unlocked preview with no real entries — show a placeholder so the
        -- user can drag/scale the frame.
        frame:SetSize(size, size)
        local icon = acquireIcon(1)
        icon:SetSize(size, size)
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", frame, "LEFT", 0, 0)
        icon.tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        icon.tex:SetVertexColor(1, 1, 1)
        -- Cooldown:Clear() is retail-only; SetCooldown(0,0) is the BCC-safe
        -- way to hide the swipe.
        icon.cd:SetCooldown(0, 0)
        icon.count:Hide()
        icon:Show()
    else
        frame:SetSize(#entries * size + math.max(0, #entries - 1) * spacing, size)
        for i, a in ipairs(entries) do
            local icon = acquireIcon(i)
            icon:SetSize(size, size)
            icon:ClearAllPoints()
            icon:SetPoint("LEFT", frame, "LEFT", (i - 1) * (size + spacing), 0)
            paintIcon(icon, a)
            icon:Show()
        end
    end
    frame.bg:SetShown(not c.locked)
    frame:Show()
end

-- Lightweight refresh: re-paint existing icons without rebuilding layout. Used
-- by SPELL_UPDATE_COOLDOWN / BAG_UPDATE which can fire many times per second.
function HUD:RepaintIcons()
    if not frame or not frame:IsShown() then return end
    for i, a in ipairs(currentEntries) do
        local icon = iconPool[i]
        if icon and icon:IsShown() then paintIcon(icon, a) end
    end
end

function HUD:SetLocked(locked)
    cfg().locked = locked and true or false
    applyDb()
    self:Refresh()
end

function HUD:ResetPosition()
    local c = cfg()
    c.point, c.relPoint = DEFAULTS.point, DEFAULTS.relPoint
    c.x, c.y = DEFAULTS.x, DEFAULTS.y
    applyDb()
end

function HUD:SetScale(v)        cfg().scale = v;     applyDb();        self:Refresh() end
function HUD:SetIconSize(v)     cfg().iconSize = v;                    self:Refresh() end
function HUD:SetSpacing(v)      cfg().spacing = v;                     self:Refresh() end

-- Diagnostic: print what the HUD sees in the current pull. Use when icons
-- aren't appearing and you need to know whether the filter, the data, or the
-- visibility is the problem.
function HUD:Diagnose()
    print("|cff66ccffCRP HUD diag|r ----")
    print("  InCombatLockdown: " .. tostring(InCombatLockdown()) ..
          "  combatActive(tracked): " .. tostring(combatActive))
    print("  Player: " .. tostring(UnitName("player")))
    if not CRP.Plan then print("  CRP.Plan: missing"); return end
    local pull, idx = CRP.Plan:CurrentPull()
    print("  Current pull idx: " .. tostring(idx))
    if not pull then print("  No current pull (no plan imported?)"); return end
    print("  Pull name: " .. tostring(pull.name) .. ", assignments: " .. #(pull.assignments or {}))
    for i, a in ipairs(pull.assignments or {}) do
        local mine = CRP.ui and CRP.ui.IsMyAssignment and CRP.ui.IsMyAssignment(a)
        print(string.format("    [%d] kind=%s id=%s player=%q mine=%s",
            i, tostring(a.kind), tostring(a.id), tostring(a.player or ""), tostring(mine)))
    end
    if frame then
        print("  Frame: shown=" .. tostring(frame:IsShown()) ..
              " size=" .. frame:GetWidth() .. "x" .. frame:GetHeight())
    else
        print("  Frame not yet created")
    end
end

-- Force the HUD to render the in-combat set even when out of combat. Just
-- flips our tracked combat flag; doesn't touch the global InCombatLockdown.
function HUD:SetTestMode(on)
    combatActive = on and true or false
    self:Refresh()
end

local eventFrame
function HUD:Init()
    cfg()  -- seed defaults into the DB
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("BAG_UPDATE")
    eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    eventFrame:SetScript("OnEvent", function(_, ev)
        local ok, err
        if ev == "PLAYER_REGEN_DISABLED" then
            combatActive = true
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
            return
        elseif ev == "PLAYER_REGEN_ENABLED" then
            combatActive = false
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
            return
        elseif ev == "PLAYER_ENTERING_WORLD" then
            combatActive = InCombatLockdown() and true or false
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
            return
        elseif ev == "GET_ITEM_INFO_RECEIVED" then
            -- Item icons may have rendered as the fallback question mark if
            -- the client hadn't cached the item yet; repaint when it arrives.
            HUD:RepaintIcons()
            return
        elseif ev == "BAG_UPDATE" then
            -- A bag change can add or remove an entry (e.g. using the last
            -- grenade), not just affect dim state, so full refresh.
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
            return
        else
            HUD:RepaintIcons()
        end
    end)
end

-- Called by Plan:SetCurrentPullIdx so the HUD swaps to the new pull's icons
-- mid-combat (e.g. auto-advance after a kill).
function HUD:OnPullChanged()
    -- Always refresh: out-of-combat pull advances change the set of equip
    -- icons we should be displaying.
    self:Refresh()
end

-- Tiny AceGUI options dialog. Reuses the lib that's already loaded for the
-- main window, so we don't pull in AceConfig just for four sliders.
local optionsWindow
function HUD:ShowOptions()
    local AceGUI = LibStub and LibStub("AceGUI-3.0", true)
    if not AceGUI then
        print("|cffff9933CRP:|r AceGUI-3.0 not available.")
        return
    end
    if optionsWindow then
        optionsWindow:Show()
        return
    end
    local c = cfg()
    local w = AceGUI:Create("Frame")
    optionsWindow = w
    w:SetTitle("CafeRaidPlanner — Combat HUD")
    w:SetLayout("Flow")
    w:SetWidth(360)
    w:SetHeight(320)
    w:SetCallback("OnClose", function(widget)
        optionsWindow = nil
        AceGUI:Release(widget)
        -- Re-lock on close so the user doesn't leave a draggable frame behind.
        HUD:SetLocked(true)
    end)

    local function fullWidth(widget)
        widget:SetFullWidth(true)
        w:AddChild(widget)
        return widget
    end

    local lock = AceGUI:Create("CheckBox")
    lock:SetLabel("Unlock (drag to position)")
    lock:SetValue(not c.locked)
    lock:SetCallback("OnValueChanged", function(_, _, v) HUD:SetLocked(not v) end)
    fullWidth(lock)

    local scale = AceGUI:Create("Slider")
    scale:SetLabel("Scale")
    scale:SetSliderValues(0.5, 2.0, 0.05)
    scale:SetValue(c.scale)
    scale:SetCallback("OnValueChanged", function(_, _, v) HUD:SetScale(v) end)
    fullWidth(scale)

    local size = AceGUI:Create("Slider")
    size:SetLabel("Icon size")
    size:SetSliderValues(16, 80, 1)
    size:SetValue(c.iconSize)
    size:SetCallback("OnValueChanged", function(_, _, v) HUD:SetIconSize(v) end)
    fullWidth(size)

    local spacing = AceGUI:Create("Slider")
    spacing:SetLabel("Spacing")
    spacing:SetSliderValues(0, 20, 1)
    spacing:SetValue(c.spacing)
    spacing:SetCallback("OnValueChanged", function(_, _, v) HUD:SetSpacing(v) end)
    fullWidth(spacing)

    local reset = AceGUI:Create("Button")
    reset:SetText("Reset position")
    reset:SetCallback("OnClick", function() HUD:ResetPosition() end)
    fullWidth(reset)

    -- Open in preview mode so position/size changes are visible immediately.
    HUD:SetLocked(false)
end
