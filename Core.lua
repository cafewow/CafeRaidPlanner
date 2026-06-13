local _, CRP = ...

local AceAddon = LibStub("AceAddon-3.0")
local AceDB = LibStub("AceDB-3.0")

-- AceComm-3.0 embed gives Core :SendCommMessage / :RegisterComm used by Comms.lua.
local Core = AceAddon:NewAddon("CafeRaidPlanner", "AceConsole-3.0", "AceComm-3.0")
CRP.Core = Core

local defaults = {
    global = {
        plan = nil,                 -- envelope {v, preset, packs} imported from web
        currentPullIdx = 1,
        autoAdvance = true,         -- advance current pull when all required mobs die
        autoApplyIncomingPlan = false, -- true → skip receive prompt and apply silently
        autoShow = true,            -- open window on raid zone-in and after importing a pushed plan
        revealOnClick = false,      -- chrome reveal trigger: false → hover, true → click inside the window
        killLookahead = 3,          -- greedy matcher window: kills overflow into the next N pulls
        trackerState = {            -- persisted kill progress, keyed by instance lockout
            lockoutKey = nil,
            killsByPullUid = {},
        },
    },
    char = {
        viewMode = "raid",          -- "raid" | "my" — swapped via header toggle
        -- Manual role override for role-targeted assignments. nil = auto-detect
        -- from talents (see Roles.lua). Set via /crp role or the options dropdown.
        role = nil,                 -- nil | "tank" | "healer" | "damage"
        window = {
            position = nil,         -- { point, relPoint, x, y }; nil → center
            raidSize = nil,         -- { w, h } — resizes persist per mode
            mySize   = nil,
        },
        -- Combat HUD placement/appearance — per character (people on multiple
        -- toons want different placements). Read via CombatHUD's cfg() accessor;
        -- AceDB fills these defaults, so the HUD no longer self-seeds.
        combatHUD = {
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
            -- instance, the planner is just a tool, not an active overlay. Toggle
            -- off for testing on a target dummy in town.
            instanceOnly = true,
            -- If an assignment's cooldown has more than this many seconds
            -- remaining, hide it from the HUD entirely rather than dimming it.
            -- Stops a sapper used on pull 1 from staying on screen across pulls
            -- 2/3/4. 0 = never hide (always dim with swipe — original behavior).
            hideThresholdSec = 5,
        },
    },
}

local eventFrame

function Core:OnInitialize()
    self.db = AceDB:New("CafeRaidPlannerDB", defaults, true)
    CRP.db = self.db

    self:RegisterChatCommand("crp", "SlashHandler")
    self:RegisterChatCommand("caferaidplanner", "SlashHandler")

    if CRP.Comms and CRP.Comms.Init then
        CRP.Comms:Init()
    end

    if CRP.HUD and CRP.HUD.Init then
        CRP.HUD:Init()
    end

    eventFrame = CreateFrame("Frame", "CafeRaidPlannerEventFrame")
    eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
    -- Re-evaluate the auto-detected role when talents/group/zone change so the
    -- personal view tracks the player's current spec (Roles:Recheck no-ops in
    -- manual mode and when the detected role hasn't actually changed).
    eventFrame:RegisterEvent("GROUP_JOINED")
    eventFrame:RegisterEvent("ZONE_CHANGED_NEW_AREA")
    eventFrame:RegisterEvent("SPELLS_CHANGED")
    eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "GET_ITEM_INFO_RECEIVED" then
            if CRP.ui and CRP.ui.Window then
                CRP.ui.Window:OnItemInfoReceived(arg1, arg2)
            end
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            if CRP.Tracker and CRP.Tracker.OnCombatLog then
                CRP.Tracker:OnCombatLog()
            end
        elseif event == "PLAYER_ENTERING_WORLD" then
            if CRP.Roles then CRP.Roles:Recheck() end
            if CRP.db.global.autoShow then
                local inInstance, instanceType = IsInInstance()
                if inInstance and instanceType == "raid" and CRP.ui and CRP.ui.Window then
                    CRP.ui.Window:Show()
                end
            end
        elseif event == "GROUP_JOINED" or event == "ZONE_CHANGED_NEW_AREA"
            or event == "SPELLS_CHANGED" then
            if CRP.Roles then CRP.Roles:Recheck() end
        end
    end)
end

function Core:OnEnable()
    -- UI is built lazily on first show.
end

function Core:SlashHandler(input)
    input = (input or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
    if input == "" or input == "show" or input == "toggle" then
        CRP.ui.Window:Toggle()
    elseif input == "hide" or input == "close" then
        CRP.ui.Window:Hide()
    elseif input == "import" then
        CRP.ui.Window:Show()
        CRP.ui.Window:ShowImport()
    elseif input == "next" then
        CRP.Plan:Next()
    elseif input == "prev" then
        CRP.Plan:Prev()
    elseif input == "reset" then
        CRP.Plan:Clear()
        CRP.ui.Window:Refresh()
        self:Print("Plan cleared.")
    elseif input == "clearkills" or input == "clear kills" then
        if CRP.Tracker then CRP.Tracker:Clear() end
        if CRP.ui.Window then CRP.ui.Window:Refresh() end
        self:Print("Kill progress cleared.")
    elseif input == "auto on" or input == "auto" then
        CRP.db.global.autoAdvance = true
        self:Print("Auto-advance: on.")
    elseif input == "auto off" then
        CRP.db.global.autoAdvance = false
        self:Print("Auto-advance: off.")
    elseif input == "autoimport on" then
        CRP.db.global.autoApplyIncomingPlan = true
        self:Print("Auto-import incoming plans: on.")
    elseif input == "autoimport off" then
        CRP.db.global.autoApplyIncomingPlan = false
        self:Print("Auto-import incoming plans: off (will prompt).")
    elseif input == "autoshow on" or input == "autoshow" then
        CRP.db.global.autoShow = true
        self:Print("Auto-show window on raid entry / plan import: on.")
    elseif input == "autoshow off" then
        CRP.db.global.autoShow = false
        self:Print("Auto-show window on raid entry / plan import: off.")
    elseif input == "reveal click" then
        CRP.db.global.revealOnClick = true
        self:Print("Window chrome reveals on click.")
    elseif input == "reveal hover" then
        CRP.db.global.revealOnClick = false
        self:Print("Window chrome reveals on hover.")
    elseif input == "role" or input:match("^role%s") then
        local arg = input:match("^role%s+(%S+)")
        if arg == "tank" or arg == "healer" or arg == "damage" then
            CRP.Roles:SetOverride(arg)
            self:Print("Your role is set to " .. arg .. " (manual override).")
            if CRP.ui and CRP.ui.Window then CRP.ui.Window:Refresh() end
        elseif arg == "auto" then
            CRP.Roles:SetOverride(nil)
            self:Print("Your role is now auto-detected from talents: " .. CRP.Roles:Get() .. ".")
            if CRP.ui and CRP.ui.Window then CRP.ui.Window:Refresh() end
        elseif not arg then
            self:Print(string.format("Role: %s (%s). Set with /crp role tank|healer|damage|auto.",
                CRP.Roles:Get(), CRP.Roles:IsAuto() and "auto-detected" or "manual"))
        else
            self:Print("Unknown role '" .. arg .. "'. Use /crp role tank|healer|damage|auto.")
        end
    elseif input == "push" then
        local ok, err = CRP.Comms:PushPlan()
        if not ok and err then self:Print("Push failed: " .. err) end
    elseif input == "debug on" or input == "debug" then
        CRP.db.global.debug = true
        self:Print("Debug: on. Each tracked kill will print its GUID.")
    elseif input == "debug off" then
        CRP.db.global.debug = false
        self:Print("Debug: off.")
    elseif input == "my" or input == "raid" then
        CRP.db.char.viewMode = input
        if CRP.ui.Window then CRP.ui.Window:Refresh() end
        self:Print("View mode: " .. input .. ".")
    elseif input == "options" or input == "config" or input == "hud" then
        if CRP.Options then CRP.Options:Show() end
    elseif input == "hud diag" then
        if CRP.HUD then CRP.HUD:Diagnose() end
    elseif input == "hud test" or input == "hud test on" then
        if CRP.HUD then CRP.HUD:SetTestMode(true); self:Print("HUD test mode: on (faking combat).") end
    elseif input == "hud test off" then
        if CRP.HUD then CRP.HUD:SetTestMode(false); self:Print("HUD test mode: off.") end
    else
        self:Print("Usage: /crp [show | import | next | prev | reset | clearkills | push | hud | auto on|off | autoimport on|off | autoshow on|off | reveal click|hover | role tank|healer|damage|auto | my | raid]")
    end
end
