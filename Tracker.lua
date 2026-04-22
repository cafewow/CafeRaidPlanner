local _, CRP = ...

local Tracker = {}
CRP.Tracker = Tracker

-- Dedupe of UNIT_DIED events within the same lockout (in-memory only).
local processedGUIDs = {}

-- Persistent tracker state:
--   CRP.db.global.trackerState = {
--     lockoutKey     = "<serverID>-<instanceID>",   -- GUID fingerprint of current lockout
--     killsByPullUid = { [pullUid] = { [npcId] = count } },
--   }
-- Switching pulls doesn't wipe — it just changes which slice we display.
-- Lockout change wipes the entire killsByPullUid map. /crp clearkills wipes too.
local function ensureState()
    local s = CRP.db.global.trackerState
    if not s then
        s = { lockoutKey = nil, killsByPullUid = {} }
        CRP.db.global.trackerState = s
    end
    if type(s.killsByPullUid) ~= "table" then s.killsByPullUid = {} end
    -- Migration from earlier shape (flat killsByNpc + pullUid). Drop silently.
    if s.killsByNpc ~= nil or s.pullUid ~= nil then
        s.killsByNpc = nil
        s.pullUid = nil
    end
    return s
end

function Tracker:LockoutKey()
    return ensureState().lockoutKey
end

-- Kills attributed to the current pull. Returns a read-only view; mutations
-- go through killsFor(pullId) below.
function Tracker:Kills()
    local pull = CRP.Plan:CurrentPull()
    if not pull then return {} end
    return ensureState().killsByPullUid[pull.id] or {}
end

local function killsFor(pullId)
    local state = ensureState()
    state.killsByPullUid[pullId] = state.killsByPullUid[pullId] or {}
    return state.killsByPullUid[pullId]
end

local function npcIdFromGUID(guid)
    if not guid then return nil end
    local kind, _, _, _, _, npcId = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return tonumber(npcId)
end

-- Lockout fingerprint. Field names from the WoW GUID format are misleading:
-- the field often called "instanceID" (4) is actually the map id — it stays the
-- same across dungeon resets. The per-instance unique value is in "zoneUID"
-- (5), which increments every time a fresh instance is spawned (after a reset
-- or a new lockout). Verified empirically on Classic Anniversary: RFC mobs
-- before reset had zoneUID=323977, after reset zoneUID=324052, while field 4
-- (mapID 389 = Ragefire Chasm) stayed constant.
local function instanceKeyFromGUID(guid)
    if not guid then return nil end
    local kind, _, serverID, _, zoneUID = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    if not serverID or not zoneUID then return nil end
    return serverID .. "-" .. zoneUID
end

function Tracker:Requirements()
    local pull = CRP.Plan:CurrentPull()
    if not pull then return {} end
    return CRP.Plan:MobRequirementsForPull(pull)
end

function Tracker:IsPullComplete()
    local reqs = self:Requirements()
    if not next(reqs) then return false end
    local kills = self:Kills()
    for npcId, need in pairs(reqs) do
        if (kills[npcId] or 0) < need then return false end
    end
    return true
end

-- Wipe only the current pull's kills.
function Tracker:ResetCurrentPull()
    local pull = CRP.Plan:CurrentPull()
    if not pull then return end
    ensureState().killsByPullUid[pull.id] = {}
end

-- Wipe everything including the lockout fingerprint. Called from /crp clearkills
-- and from Plan:Clear / Plan:Import (new plan → prior kills meaningless).
function Tracker:Clear()
    local state = ensureState()
    state.killsByPullUid = {}
    state.lockoutKey = nil
    wipe(processedGUIDs)
end

local function onMobDied(destGUID)
    if not destGUID or processedGUIDs[destGUID] then return end
    processedGUIDs[destGUID] = true

    local npcId = npcIdFromGUID(destGUID)
    if not npcId then return end

    local state = ensureState()
    local lockoutKey = instanceKeyFromGUID(destGUID)

    if CRP.db.global.debug then
        local f1, f2, f3, f4, f5, f6, f7 = strsplit("-", destGUID)
        print(string.format(
            "|cff8888ffCRP debug|r GUID=%s  kind=%s unit=%s serverID=%s instanceID=%s zoneUID=%s npcID=%s spawnUID=%s  lockoutKey=%s  prev=%s",
            destGUID, tostring(f1), tostring(f2), tostring(f3), tostring(f4),
            tostring(f5), tostring(f6), tostring(f7),
            tostring(lockoutKey), tostring(state.lockoutKey)))
    end

    if lockoutKey and state.lockoutKey and state.lockoutKey ~= lockoutKey then
        -- Different instance — wipe all pull kills so we don't carry stale state
        -- from a prior lockout into this one.
        state.killsByPullUid = {}
        wipe(processedGUIDs)
        processedGUIDs[destGUID] = true
    end
    if lockoutKey then state.lockoutKey = lockoutKey end

    local pull = CRP.Plan:CurrentPull()
    if not pull then return end

    local reqs = Tracker:Requirements()
    if not reqs[npcId] then return end

    local kills = killsFor(pull.id)
    kills[npcId] = (kills[npcId] or 0) + 1

    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end

    if Tracker:IsPullComplete() and CRP.db.global.autoAdvance ~= false then
        local n = #CRP.Plan:Pulls()
        local idx = CRP.Plan:CurrentPullIdx()
        if idx < n then
            print("|cff38c24fCafeRaidPlanner:|r pull complete — advancing to pull " .. (idx + 1))
            CRP.Plan:Next()
        else
            print("|cff38c24fCafeRaidPlanner:|r final pull complete.")
        end
    end
end

function Tracker:OnCombatLog()
    local _, subevent, _, _, _, _, _, destGUID, destName = CombatLogGetCurrentEventInfo()
    if subevent == "UNIT_DIED" or subevent == "PARTY_KILL" then
        -- Enrich the runtime name cache so subsequent pulls / reloads have a
        -- fallback name for this npcId even if the share envelope didn't.
        local npcId = npcIdFromGUID(destGUID)
        if npcId and destName then CRP.Plan:CacheNpcName(npcId, destName) end
        onMobDied(destGUID)
    end
end
