local _, CRP = ...

local Plan = {}
CRP.Plan = Plan

-- Dedupe of pull-pack unresolved-warnings within the current plan. Cleared on
-- Plan:Import / Plan:Clear since pull and pack ids regenerate per plan.
local warnedUnresolved = {}

-- Lazy { [packId] = pack } lookup map. PackById is called once per pack per
-- pull on every Window:Refresh, so the O(packs·packsPerPull) scan over a 30-
-- pack plan was the heaviest part of a refresh. Cleared whenever the plan
-- changes; built on first access via ensurePackIndex().
local packIndex = nil
local function ensurePackIndex()
    if packIndex then return packIndex end
    local p = Plan:Current()
    packIndex = {}
    if p and p.packs then
        for _, pack in ipairs(p.packs) do
            packIndex[pack.id] = pack
        end
    end
    return packIndex
end
local function invalidatePackIndex() packIndex = nil end

-- Returns the current plan envelope {v, preset, packs} or nil if none imported.
function Plan:Current()
    return CRP.db and CRP.db.global and CRP.db.global.plan
end

function Plan:Import(envelope)
    if type(envelope) ~= "table" or type(envelope.preset) ~= "table" then return false end
    CRP.db.global.plan = envelope
    CRP.db.global.currentPullIdx = 1
    wipe(warnedUnresolved)
    invalidatePackIndex()
    if CRP.Tracker and CRP.Tracker.Clear then
        CRP.Tracker:Clear()     -- new plan → pull uids changed, prior kills meaningless
    end
    if CRP.HUD and CRP.HUD.OnPullChanged then
        CRP.HUD:OnPullChanged()
    end
    return true
end

function Plan:Clear()
    CRP.db.global.plan = nil
    CRP.db.global.currentPullIdx = 1
    wipe(warnedUnresolved)
    invalidatePackIndex()
    if CRP.Tracker and CRP.Tracker.Clear then
        CRP.Tracker:Clear()
    end
    if CRP.HUD and CRP.HUD.OnPullChanged then
        CRP.HUD:OnPullChanged()
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

-- `silent = true` suppresses the pull-idx broadcast. Used by the comms layer
-- when applying a remote CRPPULL/CRPPLAN so N assists don't all echo the same
-- idx back into the channel after every navigation.
function Plan:SetCurrentPullIdx(idx, silent)
    local pulls = self:Pulls()
    local n = #pulls
    if n == 0 then
        CRP.db.global.currentPullIdx = 1
        if CRP.HUD and CRP.HUD.OnPullChanged then
            CRP.HUD:OnPullChanged()
        end
        return
    end
    if idx < 1 then idx = 1 end
    if idx > n then idx = n end
    local prev = CRP.db.global.currentPullIdx or 1
    CRP.db.global.currentPullIdx = idx

    -- Cursor is the source of truth for completion. Forward jumps stamp every
    -- pull we just left as fully killed (pulls in [prev, idx-1]); backward
    -- jumps clear the destination plus any forward-filled pulls in between
    -- (pulls in [idx, prev-1]) so they're a fresh slate to redo. The previous
    -- current pull is left untouched on backward nav — its kill state reflects
    -- what actually happened while we were on it.
    if CRP.Tracker and idx ~= prev then
        if idx > prev then
            for i = prev, idx - 1 do
                CRP.Tracker:FillPull(pulls[i])
            end
        else
            for i = idx, prev - 1 do
                CRP.Tracker:ClearPull(pulls[i])
            end
        end
    end

    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end
    if CRP.HUD and CRP.HUD.OnPullChanged then
        CRP.HUD:OnPullChanged()
    end
    if not silent and prev ~= idx and CRP.Comms and CRP.Comms:CanPush() then
        CRP.Comms:PushPull()
    end
end

function Plan:Next()
    self:SetCurrentPullIdx(self:CurrentPullIdx() + 1)
end

function Plan:Prev()
    self:SetCurrentPullIdx(self:CurrentPullIdx() - 1)
end

-- A prep step: authored in the planner with no mobs, surfaced by the HUD
-- between pulls (out of combat) for buffs / summons / gear swaps. The `prep`
-- flag rides along in the preset (share format is a JSON passthrough), so it's
-- present here untouched. We key off the explicit flag rather than "has no
-- slots" so a misconfigured empty real pull isn't mistaken for prep.
function Plan:IsPrepPull(pull)
    return pull ~= nil and pull.prep == true
end

-- Combat-start advance for prep steps. A mob-less step can't auto-advance on a
-- kill, so the HUD calls this from PLAYER_REGEN_DISABLED: if the cursor sits on
-- a prep step (or a consecutive run of them), jump to the first following real
-- pull so kill tracking and the in-combat HUD reflect what we're actually
-- fighting. No-op when not on a prep step, or when the run is trailing (no real
-- pull after it — staying put is harmless). The forward-fill in
-- SetCurrentPullIdx is a no-op on the skipped prep steps (they have no slots).
function Plan:AdvancePastPrep()
    local pulls = self:Pulls()
    local idx = self:CurrentPullIdx()
    if not self:IsPrepPull(pulls[idx]) then return end
    local target = idx
    while target <= #pulls and self:IsPrepPull(pulls[target]) do
        target = target + 1
    end
    if target > #pulls then return end
    self:SetCurrentPullIdx(target)
end

-- Kill-driven advance. The caller (Tracker, after recording a kill that
-- completed the current pull) has already decided we *should* advance; this owns
-- *where* the cursor goes. Probe forward without side effects to the first pull
-- that still needs work — skipping any already-complete pulls, e.g. ones
-- pre-filled by overflow kills — then move there with a single SetCurrentPullIdx
-- so a multi-pull skip emits at most one CRPPULL broadcast + one Refresh. Plan
-- owns cursor movement; Tracker only answers "is this pull complete?".
function Plan:AdvanceToNextIncomplete()
    local pulls = self:Pulls()
    local n = #pulls
    local idx = self:CurrentPullIdx()
    local target = idx
    while target < n do
        local probe = target + 1
        if CRP.Tracker:IsPullCompleteFor(pulls[probe]) then
            target = probe
        else
            target = probe
            break
        end
    end
    if target > idx then
        self:SetCurrentPullIdx(target)
        if target == n and CRP.Tracker:IsPullComplete() then
            print("|cff38c24fCafeRaidPlanner:|r final pull complete.")
        else
            print("|cff38c24fCafeRaidPlanner:|r pull complete — advancing to pull " .. target)
        end
    elseif target == n then
        print("|cff38c24fCafeRaidPlanner:|r final pull complete.")
    end
end

-- Look up a pack by id in the current plan.
function Plan:PackById(packId)
    return ensurePackIndex()[packId]
end

-- Boss packs referenced by a pull. The web app marks boss packs with a slug
-- (they're otherwise ordinary packs). Several callers need "which of this pull's
-- packs are bosses" — the UI for the pull's display name, Triggers for the
-- bossPct watch set — so the slug detection lives here, next to the pack data,
-- rather than being re-iterated in each consumer.
function Plan:BossPacks(pull)
    local out = {}
    if not (pull and pull.packIds) then return out end
    for _, packId in ipairs(pull.packIds) do
        local pack = self:PackById(packId)
        if pack and pack.slug then out[#out + 1] = pack end
    end
    return out
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

-- Return an ordered list of slot requirements for the pull. Each slot is
-- { accepts = {[npcId]=true, ...}, count = N, variable = true|nil }.
-- Fixed packs contribute one slot per member (1-element accepts). Variable
-- packs contribute one pool slot per pack whose accepts is the full pool and
-- count is the pack's total. Bosses are ordinary packs (slug + icon) whose
-- members list contains the boss npcId, captured naturally as a fixed slot.
function Plan:SlotsForPull(pull)
    local slots = {}
    if not pull then return slots end
    for _, packId in ipairs(pull.packIds or {}) do
        local pack = self:PackById(packId)
        local empty = pack and (not pack.members or #pack.members == 0)
        if not pack or empty then
            -- A pull that references a missing/empty pack will silently render
            -- fewer mobs than authored and (if it's the only pack) can never
            -- reach IsPullComplete. Print once per (pull, packId) so the user
            -- sees the broken reference without spamming on every refresh.
            local key = tostring(pull.id) .. ":" .. tostring(packId)
            if not warnedUnresolved[key] then
                warnedUnresolved[key] = true
                local pullName = (pull.name and pull.name ~= "" and pull.name) or ("#" .. tostring(pull.id))
                if pack then
                    print(("|cffff9933CRP:|r pull '%s' references pack #%d which has no mobs."):format(pullName, packId))
                else
                    print(("|cffff9933CRP:|r pull '%s' references missing pack #%d — re-import the plan."):format(pullName, packId))
                end
            end
        elseif pack.variable then
            local accepts, total = {}, 0
            for _, m in ipairs(pack.members) do
                accepts[m.npcId] = true
                total = total + (m.count or 1)
            end
            if total > 0 then
                slots[#slots + 1] = { accepts = accepts, count = total, variable = true }
            end
        else
            for _, m in ipairs(pack.members) do
                slots[#slots + 1] = {
                    accepts = { [m.npcId] = true },
                    count = m.count or 1,
                }
            end
        end
    end
    return slots
end
