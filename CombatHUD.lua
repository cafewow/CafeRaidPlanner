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
    enabled = true,
    direction = "horizontal",   -- "horizontal" | "vertical"
    -- Restrict the HUD to raid/dungeon instances. Default on — outside an
    -- instance, the planner is just a tool, not an active overlay. Toggle off
    -- for testing on a target dummy in town.
    instanceOnly = true,
    -- If an assignment's cooldown has more than this many seconds remaining,
    -- hide it from the HUD entirely rather than dimming it. Stops things like
    -- a sapper used on pull 1 from staying on screen across pulls 2/3/4.
    -- 0 = never hide (always dim with swipe — original behavior).
    hideThresholdSec = 5,
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

-- Seconds of cooldown remaining for an assignment, or 0 if none / unknown.
-- Filters at the GCD floor (1.5s) so a global cooldown blip doesn't read as
-- "this thing is on cooldown."
local function cooldownRemaining(a)
    local s, d
    if a.kind == "item" or a.kind == "equip" then
        s, d = itemCooldown(a.id)
    else
        local name = GetSpellInfo(a.id)
        if name then s, d = GetSpellCooldown(name)
        else         s, d = GetSpellCooldown(a.id) end
    end
    if s and d and d > 1.5 then
        local remain = (s + d) - GetTime()
        if remain > 0 then return remain end
    end
    return 0
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

-- WoW icon textures ship with a ~7% bevel border that looks chunky next to
-- modern HUDs. Crop it the same way WeakAuras' "zoom" option does, so icons
-- show only the inner art region.
local ICON_TEXCOORD = { 0.07, 0.93, 0.07, 0.93 }

local ICON_BORDER = 1

local function createIcon(parent)
    local f = CreateFrame("Frame", nil, parent)
    -- Black backdrop fills the icon's whole footprint; the art texture insets
    -- by ICON_BORDER on each side, leaving a clean black frame around it.
    f.border = f:CreateTexture(nil, "BACKGROUND")
    f.border:SetAllPoints()
    f.border:SetColorTexture(0, 0, 0, 1)
    f.tex = f:CreateTexture(nil, "ARTWORK")
    f.tex:SetPoint("TOPLEFT", ICON_BORDER, -ICON_BORDER)
    f.tex:SetPoint("BOTTOMRIGHT", -ICON_BORDER, ICON_BORDER)
    f.tex:SetTexCoord(ICON_TEXCOORD[1], ICON_TEXCOORD[2], ICON_TEXCOORD[3], ICON_TEXCOORD[4])
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

-- Refresh once per second so cooldowns expiring naturally (and entries
-- crossing the hide-threshold) come back into view without waiting for the
-- player to take an action. Cooldown events fire on start but aren't reliable
-- on natural finish; this ticker covers both gaps cheaply. Lives on its own
-- always-shown frame so it keeps firing even when the HUD frame is hidden
-- (e.g. all entries currently filtered out by the cooldown threshold).
local TICKER_INTERVAL = 1.0
local tickerFrame
local tickerElapsed = 0
local function startTicker()
    if tickerFrame then return end
    tickerFrame = CreateFrame("Frame")
    tickerFrame:SetScript("OnUpdate", function(_, elapsed)
        tickerElapsed = tickerElapsed + elapsed
        if tickerElapsed < TICKER_INTERVAL then return end
        tickerElapsed = 0
        if combatActive or not cfg().locked then HUD:Refresh() end
    end)
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

-- Flatten the consecutive run of prep steps starting at `startIdx` into one
-- assignment list. Prep steps are an unordered between-pull checklist, so the
-- HUD merges a [prep, prep, ...] run rather than treating each as its own
-- cursor stop — otherwise the later steps' assignments would never be visible
-- (nothing advances the cursor prep→prep out of combat). The planner keeps them
-- separate purely for authoring tidiness.
local function mergedPrepAssignments(pulls, startIdx)
    local out = {}
    for i = startIdx, #pulls do
        local p = pulls[i]
        if not (CRP.Plan and CRP.Plan:IsPrepPull(p)) then break end
        if p.assignments then
            for _, a in ipairs(p.assignments) do out[#out + 1] = a end
        end
    end
    return out
end

-- Equip assignments only make sense between pulls — you can't swap gear in
-- combat. Everything else only makes sense *during* combat. One frame, three
-- modes: on a prep step we show its merged checklist; otherwise combat-state
-- toggles between equip (out of combat) and cooldowns/items/kicks (in combat).
local function entriesForPull()
    if not (CRP.Plan and CRP.ui and CRP.ui.IsMyAssignment) then return {} end
    local pull, idx = CRP.Plan:CurrentPull()
    if not pull then return {} end

    -- Prep step: render the merged consecutive-prep checklist. These are
    -- pre-pull actions (buffs/summons/swaps); combat-start advances the cursor
    -- off the run (Plan:AdvancePastPrep), so in practice this renders out of
    -- combat. We surface the same ownable, icon-able kinds either way.
    local prepMode = CRP.Plan:IsPrepPull(pull)
    local source = prepMode and mergedPrepAssignments(CRP.Plan:Pulls(), idx) or pull.assignments
    if not source then return {} end

    local inCombat = combatActive
    local out = {}
    for _, a in ipairs(source) do
        local k = a.kind
        local relevant
        if prepMode then
            relevant = (k == "spell" or k == "item" or k == "equip")
        elseif inCombat then
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
            local hasItem = true
            if a.kind == "item" or a.kind == "equip" then
                hasItem = (GetItemCount(a.id) or 0) > 0
            end
            -- Hide entries whose cooldown still has more than `hideThresholdSec`
            -- left — a sapper used on pull 1 shouldn't linger on pull 2/3/4.
            -- Threshold == 0 disables hiding (caller wants the old dim-only UX).
            -- Equip prompts are exempt: on-use trinkets etc. still need a
            -- swap reminder even while their on-use CD is ticking down — the
            -- internal CD doesn't represent "this swap is unnecessary."
            local th = cfg().hideThresholdSec or 0
            local hiddenByCd = a.kind ~= "equip" and th > 0 and cooldownRemaining(a) > th
            if hasItem and not hiddenByCd then out[#out + 1] = a end
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
            -- GCD (≤1.5s) doesn't count as "on cooldown" for HUD purposes —
            -- the swipe gate at line ~240 skips it for the same reason, so
            -- treating it as not-ready here would dim the icon with no visible
            -- swipe to explain it (every spellcast greys the whole HUD).
            ready = (d or 0) <= 1.5
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
        -- GCD (≤1.5s) isn't "on cooldown" for HUD purposes — same gate as the
        -- item branch and the swipe below. GetSpellCooldown reports the active
        -- GCD against every spell while it's ticking, so `== 0` would dim the
        -- icon on every cast with no swipe to explain it (the symptom: a
        -- Bloodlust icon flickering light/shadowed as the shaman casts).
        ready = (d or 0) <= 1.5
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

-- Tracked from PLAYER_ENTERING_WORLD / ZONE_CHANGED_NEW_AREA. Polling
-- IsInInstance() inside shouldShow would work, but the cached flag means the
-- 1-Hz ticker doesn't hit the API every tick.
local inInstance = false
local function refreshInstanceFlag()
    local inside, kind = IsInInstance()
    inInstance = inside and (kind == "raid" or kind == "party") or false
end

local function shouldShow()
    if not cfg().enabled then return false end
    if not cfg().locked then return true end  -- preview while configuring
    if cfg().instanceOnly and not inInstance then return false end
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
        -- Horizontal grows right from the frame's LEFT anchor; vertical grows
        -- down from TOP. The frame's screen anchor (point/relPoint) is the
        -- icon row's leading corner either way, so resizing the frame doesn't
        -- shift where icon #1 lives.
        local horizontal = c.direction ~= "vertical"
        local long = #entries * size + math.max(0, #entries - 1) * spacing
        if horizontal then
            frame:SetSize(long, size)
        else
            frame:SetSize(size, long)
        end
        for i, a in ipairs(entries) do
            local icon = acquireIcon(i)
            icon:SetSize(size, size)
            icon:ClearAllPoints()
            if horizontal then
                icon:SetPoint("LEFT", frame, "LEFT", (i - 1) * (size + spacing), 0)
            else
                icon:SetPoint("TOP", frame, "TOP", 0, -((i - 1) * (size + spacing)))
            end
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
function HUD:SetEnabled(v)      cfg().enabled = v and true or false;   self:Refresh() end
function HUD:SetDirection(d)    cfg().direction = d == "vertical" and "vertical" or "horizontal"; self:Refresh() end
function HUD:SetHideThreshold(v) cfg().hideThresholdSec = math.max(0, v or 0); self:Refresh() end
function HUD:SetInstanceOnly(v)  cfg().instanceOnly = v and true or false;     self:Refresh() end

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
    refreshInstanceFlag()
    startTicker()
    eventFrame = CreateFrame("Frame")
    eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
    eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("SPELL_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("BAG_UPDATE_COOLDOWN")
    eventFrame:RegisterEvent("BAG_UPDATE")
    eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    eventFrame:SetScript("OnEvent", function(_, ev)
        local ok, err
        if ev == "PLAYER_REGEN_DISABLED" then
            combatActive = true
            -- A prep step can't auto-advance on a kill (no mobs), so combat
            -- start is its exit trigger: jump past the prep run to the real
            -- pull. SetCurrentPullIdx already refreshes the HUD, so the Refresh
            -- below is just the no-prep-step path.
            if CRP.Plan and CRP.Plan.AdvancePastPrep then
                pcall(CRP.Plan.AdvancePastPrep, CRP.Plan)
            end
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
            refreshInstanceFlag()
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
            return
        elseif ev == "ZONE_CHANGED_NEW_AREA" then
            refreshInstanceFlag()
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
            return
        elseif ev == "GET_ITEM_INFO_RECEIVED" then
            -- Item icons may have rendered as the fallback question mark if
            -- the client hadn't cached the item yet; repaint when it arrives.
            HUD:RepaintIcons()
            return
        else
            -- BAG_UPDATE can add/remove entries (last grenade consumed).
            -- SPELL_UPDATE_COOLDOWN / BAG_UPDATE_COOLDOWN can also add/remove
            -- entries when the hide-on-cooldown threshold is in play. Cheap
            -- enough at this entry-count scale — always full refresh.
            ok, err = pcall(HUD.Refresh, HUD)
            if not ok then print("|cffff3333CRP HUD error:|r " .. tostring(err)) end
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

-- HUD options live in Options.lua now (shared window with General settings).
