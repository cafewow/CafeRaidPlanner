local _, CRP = ...

local Plan = {}
CRP.Plan = Plan

-- Returns the current plan envelope {v, preset, packs} or nil if none imported.
function Plan:Current()
    return CRP.db and CRP.db.global and CRP.db.global.plan
end

function Plan:Import(envelope)
    if type(envelope) ~= "table" or type(envelope.preset) ~= "table" then return false end
    CRP.db.global.plan = envelope
    CRP.db.global.currentPullIdx = 1
    if CRP.Tracker and CRP.Tracker.Clear then
        CRP.Tracker:Clear()     -- new plan → pull uids changed, prior kills meaningless
    end
    return true
end

function Plan:Clear()
    CRP.db.global.plan = nil
    CRP.db.global.currentPullIdx = 1
    if CRP.Tracker and CRP.Tracker.Clear then
        CRP.Tracker:Clear()
    end
end

function Plan:Pulls()
    local p = self:Current()
    return p and p.preset and p.preset.pulls or {}
end

function Plan:CurrentPullIdx()
    return (CRP.db and CRP.db.global and CRP.db.global.currentPullIdx) or 1
end

function Plan:CurrentPull()
    local pulls = self:Pulls()
    local idx = self:CurrentPullIdx()
    return pulls[idx], idx
end

function Plan:SetCurrentPullIdx(idx)
    local n = #self:Pulls()
    if n == 0 then
        CRP.db.global.currentPullIdx = 1
        return
    end
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    local prev = CRP.db.global.currentPullIdx
    CRP.db.global.currentPullIdx = idx
    -- Intentionally don't reset tracker state: kills are stored per-pull-uid,
    -- so navigating between pulls should just show each pull's own progress.
    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end
    -- Broadcast pull idx when RL/assist navigates, so receivers stay in sync.
    -- Guard prev ~= idx so receivers applying an incoming CRPPULL don't bounce
    -- it back into the channel.
    if prev ~= idx and CRP.Comms and CRP.Comms.CanPush and CRP.Comms:CanPush() then
        CRP.Comms:PushPull()
    end
end

function Plan:Next()
    self:SetCurrentPullIdx(self:CurrentPullIdx() + 1)
end

function Plan:Prev()
    self:SetCurrentPullIdx(self:CurrentPullIdx() - 1)
end

-- Look up a pack by id in the current plan.
function Plan:PackById(packId)
    local p = self:Current()
    if not p then return nil end
    for _, pack in ipairs(p.packs) do
        if pack.id == packId then return pack end
    end
    return nil
end

-- Runtime cache of npcId → name enriched from combat log destName. Useful when
-- the share envelope doesn't have a name for a given npc (e.g., the user added
-- a raw-ID mob that isn't in any scraped db).
local nameCache = {}

function Plan:CacheNpcName(npcId, name)
    if not npcId or not name or name == "" then return end
    nameCache[npcId] = name
end

-- Priority: envelope's npcNames → runtime cache → nil.
function Plan:NpcName(npcId)
    if not npcId then return nil end
    local p = self:Current()
    if p and p.npcNames then
        local n = p.npcNames[tostring(npcId)]
        if n and n ~= "" then return n end
    end
    return nameCache[npcId]
end

-- Aggregate mob counts across all packs in the given pull. Bosses are ordinary
-- packs (with a slug + icon) whose members list contains the boss npcId, so
-- this loop captures them naturally — no special case needed.
function Plan:MobRequirementsForPull(pull)
    local out = {}
    if not pull then return out end
    for _, packId in ipairs(pull.packIds or {}) do
        local pack = self:PackById(packId)
        if pack and pack.members then
            for _, m in ipairs(pack.members) do
                out[m.npcId] = (out[m.npcId] or 0) + (m.count or 1)
            end
        end
    end
    return out
end
