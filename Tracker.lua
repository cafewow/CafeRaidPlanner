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
    -- Migration from earlier shape (flat killsByNpc + pullUid, or short-lived
    -- skippedPulls table). Drop silently.
    if s.killsByNpc ~= nil or s.pullUid ~= nil or s.skippedPulls ~= nil then
        s.killsByNpc = nil
        s.pullUid = nil
        s.skippedPulls = nil
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

function Tracker:Slots()
    local pull = CRP.Plan:CurrentPull()
    if not pull then return {} end
    return CRP.Plan:SlotsForPull(pull)
end

-- Size of a slot's accepts set. Fixed slots = 1; pool slots = N. Used to order
-- greedy assignment fixed-first so the more-specific slot consumes its kills
-- before a pool slot would absorb them.
local function acceptsSize(slot)
    local n = 0
    for _ in pairs(slot.accepts) do n = n + 1 end
    return n
end

-- Greedy assignment of `kills` ({[npcId]=count}) into `slots`. Returns a list
-- of per-slot kills consumed (parallel to `slots`), summing kills attributed
-- to each slot. Fixed-first ordering minimizes false-unsatisfied results when
-- the same npcId is referenced by both a fixed and a pool slot in the pull.
local function assignKillsToSlots(slots, kills)
    local remaining = {}
    for nid, c in pairs(kills) do remaining[nid] = c end
    -- Precompute accepts sizes once; the sort comparator runs O(n log n) times
    -- and recomputing per call would walk each slot's accepts repeatedly.
    local sizes, order = {}, {}
    for i = 1, #slots do
        sizes[i] = acceptsSize(slots[i])
        order[i] = i
    end
    table.sort(order, function(a, b) return sizes[a] < sizes[b] end)
    local consumed = {}
    for i = 1, #slots do consumed[i] = 0 end
    for _, i in ipairs(order) do
        local s = slots[i]
        local need = s.count
        for nid in pairs(s.accepts) do
            if need <= 0 then break end
            local got = remaining[nid] or 0
            local take = math.min(got, need)
            remaining[nid] = got - take
            need = need - take
            consumed[i] = consumed[i] + take
        end
    end
    return consumed
end

-- Pull-specific completion check. Pure — no dependency on the cursor. Returns
-- false for pulls with no slots (empty / all-unresolved packs) so they don't
-- masquerade as "complete".
function Tracker:IsPullCompleteFor(pull)
    if not pull then return false end
    local slots = CRP.Plan:SlotsForPull(pull)
    if #slots == 0 then return false end
    local bucket = ensureState().killsByPullUid[pull.id] or {}
    local consumed = assignKillsToSlots(slots, bucket)
    for i, s in ipairs(slots) do
        if consumed[i] < s.count then return false end
    end
    return true
end

function Tracker:IsPullComplete()
    return self:IsPullCompleteFor(CRP.Plan:CurrentPull())
end

-- Exposed so UI.lua's progress display can derive per-slot consumed counts
-- without duplicating the greedy assignment logic.
function Tracker:AssignKillsToSlots(slots, kills)
    return assignKillsToSlots(slots, kills)
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

-- Stamp every required mob in `pull` to its required count. Used by Plan
-- navigation: forward jumps fill the pulls we left behind ("cursor moved past
-- this, treat it as done"). Idempotent — re-filling an already-full pull is a
-- no-op.
function Tracker:FillPull(pull)
    if not pull then return end
    local slots = CRP.Plan:SlotsForPull(pull)
    if #slots == 0 then return end
    -- Overwrite the pull's kills wholesale: for each slot, deposit `count`
    -- against the first npcId in its accepts set. Identity of the deposit
    -- doesn't matter for completion — the matcher only checks per-slot totals.
    local newKills = {}
    for _, s in ipairs(slots) do
        local first
        for nid in pairs(s.accepts) do first = nid; break end
        if first then newKills[first] = (newKills[first] or 0) + s.count end
    end
    ensureState().killsByPullUid[pull.id] = newKills
end

-- Drop all kills for a pull. Used by backward navigation so the destination
-- and any forward-filled pulls in between get a fresh slate to redo.
function Tracker:ClearPull(pull)
    if not pull then return end
    ensureState().killsByPullUid[pull.id] = nil
end

-- Greedy lookahead: find the earliest pull within a small window starting at
-- the current pull whose requirement for npcId isn't satisfied yet. Handles
-- patrols and out-of-order pulls — a pull-2 patrol that wanders into pull 1
-- lands in pull 1 if pull 1 still needs that npcId, otherwise spills forward.
-- Earlier pulls don't need to be considered: forward navigation auto-fills
-- them, so they're at requirement and the matcher would skip past anyway.
local function findPullForKill(npcId)
    local pulls = CRP.Plan:Pulls()
    if #pulls == 0 then return nil end
    local idx = CRP.Plan:CurrentPullIdx()
    local lookahead = CRP.db.global.killLookahead or 3
    local last = math.min(#pulls, idx + lookahead)
    local state = ensureState()
    for i = idx, last do
        local pull = pulls[i]
        if pull then
            local slots = CRP.Plan:SlotsForPull(pull)
            -- Cheap filter: skip pulls that don't accept this npcId in any slot.
            local accepted = false
            for _, s in ipairs(slots) do
                if s.accepts[npcId] then accepted = true; break end
            end
            if accepted then
                local bucket = state.killsByPullUid[pull.id] or {}
                local consumed = assignKillsToSlots(slots, bucket)
                -- Pull is a candidate if at least one slot accepting npcId is
                -- not yet fully consumed. Greedy fixed-first ordering means a
                -- fixed slot is preferred over a pool slot when both could
                -- accept this npcId.
                for i2, s in ipairs(slots) do
                    if s.accepts[npcId] and consumed[i2] < s.count then
                        return pull
                    end
                end
            end
        end
    end
    return nil
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

    local pull = findPullForKill(npcId)
    if not pull then return end

    local kills = killsFor(pull.id)
    kills[npcId] = (kills[npcId] or 0) + 1

    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end

    if Tracker:IsPullComplete() and CRP.db.global.autoAdvance ~= false then
        local pulls = CRP.Plan:Pulls()
        local n = #pulls
        local idx = CRP.Plan:CurrentPullIdx()
        -- Probe forward without side effects to find the first incomplete pull
        -- (or the final pull if all remaining are complete). Overflow kills can
        -- have pre-filled multiple later pulls; we want to land on the first
        -- one that still needs work. Single SetCurrentPullIdx at the end so we
        -- emit at most one CRPPULL broadcast and one Refresh, even on multi-pull skips.
        local target = idx
        while target < n do
            local probe = target + 1
            if Tracker:IsPullCompleteFor(pulls[probe]) then
                target = probe
            else
                target = probe
                break
            end
        end
        if target > idx then
            CRP.Plan:SetCurrentPullIdx(target)
            if target == n and Tracker:IsPullComplete() then
                print("|cff38c24fCafeRaidPlanner:|r final pull complete.")
            else
                print("|cff38c24fCafeRaidPlanner:|r pull complete — advancing to pull " .. target)
            end
        elseif target == n then
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
