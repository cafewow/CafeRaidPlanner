local _, CRP = ...

local AceAddon = LibStub("AceAddon-3.0")
local AceDB = LibStub("AceDB-3.0")

-- Note: we deliberately do NOT mix in AceEvent-3.0. On retail, AceEvent shares
-- one frame across all addons using it; if any of them taints that frame, our
-- RegisterEvent calls fire ADDON_ACTION_FORBIDDEN. We own our event frame
-- below, which keeps us out of that shared taint path.
local Core = AceAddon:NewAddon("CafeRaidPlanner", "AceConsole-3.0")
CRP.Core = Core

local defaults = {
    global = {
        plan = nil,                 -- envelope {v, preset, packs} imported from web
        currentPullIdx = 1,
        autoAdvance = true,         -- advance current pull when all required mobs die
        trackerState = {            -- persisted kill progress, keyed by instance lockout
            lockoutKey = nil,
            pullUid = nil,
            killsByNpc = {},
        },
    },
    char = {
        viewMode = "raid",          -- "raid" | "my" — swapped via header toggle
        window = {
            position = nil,         -- { point, relPoint, x, y }; nil → center
            raidSize = nil,         -- { w, h } — resizes persist per mode
            mySize   = nil,
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

    eventFrame = CreateFrame("Frame", "CafeRaidPlannerEventFrame")
    eventFrame:RegisterEvent("GET_ITEM_INFO_RECEIVED")
    eventFrame:RegisterEvent("COMBAT_LOG_EVENT_UNFILTERED")
    eventFrame:SetScript("OnEvent", function(_, event, arg1, arg2)
        if event == "GET_ITEM_INFO_RECEIVED" then
            if CRP.ui and CRP.ui.Window then
                CRP.ui.Window:OnItemInfoReceived(arg1, arg2)
            end
        elseif event == "COMBAT_LOG_EVENT_UNFILTERED" then
            if CRP.Tracker and CRP.Tracker.OnCombatLog then
                CRP.Tracker:OnCombatLog()
            end
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
    else
        self:Print("Usage: /crp [show | import | next | prev | reset | clearkills | auto on|off | my | raid]")
    end
end
