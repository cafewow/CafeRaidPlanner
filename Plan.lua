local _, CRP = ...

local Plan = {}
CRP.Plan = Plan

-- Dedupe of pull-pack unresolved-warnings within the current plan. Cleared on
-- Plan:Import / Plan:Clear since pull and pack ids regenerate per plan.
local warnedUnresolved = {}

-- Lazy { [packId] = pack } lookup map. PackById is called once per pack per
-- pull on every Window:Refresh, so the O(packs·packsPerPull) scan over a 30-
-- pack plan was the heaviest part of a refresh. Cleared whenever the active
-- plan changes; built on first access via ensurePackIndex().
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

-- The plan library is a dynamic key set, so it's created on first use rather
-- than seeded as an AceDB default.
local function ensurePlans()
    local g = CRP.db and CRP.db.global
    if not g then return {} end
    if type(g.plans) ~= "table" then g.plans = {} end
    return g.plans
end

-- Any plan id in the library (used to pick a fallback active plan after a
-- delete). Deterministic-ish: prefers the lexically-first id so the choice is
-- stable across calls rather than depending on pairs() order.
local function anyPlanId(plans)
    local best
    for id in pairs(plans) do
        if not best or id < best then best = id end
    end
    return best
end

-- Returns the active plan envelope {v, preset, packs} or nil if none loaded.
function Plan:Current()
    local g = CRP.db and CRP.db.global
    if not g or not g.currentPlanId then return nil end
    return ensurePlans()[g.currentPlanId]
end

-- Reset the live runtime state to the start of whatever plan is now active.
-- Only one plan is ever loaded, so switching/importing discards the previous
-- plan's cursor and kills — they don't matter once we've moved on.
local function loadActive()
    CRP.db.global.currentPullIdx = 1
    wipe(warnedUnresolved)
    invalidatePackIndex()
    if CRP.Tracker and CRP.Tracker.Clear then CRP.Tracker:Clear() end
    if CRP.HUD and CRP.HUD.OnPullChanged then CRP.HUD:OnPullChanged() end
end

-- Import an envelope into the library and make it active. Keyed by preset id so
-- a re-import (or a re-pushed plan) replaces that entry rather than piling up
-- duplicates; a genuinely different plan gets its own slot and coexists as a
-- dormant envelope. Returns true, planId.
function Plan:Import(envelope)
    if type(envelope) ~= "table" or type(envelope.preset) ~= "table" then return false end
    local id = envelope.preset.id
    if not id or id == "" then id = "plan-" .. tostring(time()) end
    ensurePlans()[id] = envelope
    CRP.db.global.currentPlanId = id
    loadActive()
    return true, id
end

-- Switch the active plan to a stored one. The previous plan's runtime data is
-- discarded (loadActive resets the cursor and clears the tracker) — only the
-- loaded plan is ever tracked.
function Plan:Select(id)
    local plans = ensurePlans()
    if not plans[id] then return false end
    if CRP.db.global.currentPlanId ~= id then
        CRP.db.global.currentPlanId = id
        loadActive()
    end
    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end
    return true
end

-- Remove a stored plan. If it was active, fall back to any remaining plan (or
-- nil → empty state) and reset the runtime state onto it.
function Plan:Delete(id)
    local plans = ensurePlans()
    if not plans[id] then return false end
    plans[id] = nil
    if CRP.db.global.currentPlanId == id then
        CRP.db.global.currentPlanId = anyPlanId(plans)
        loadActive()
    end
    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end
    return true
end

-- List stored plans for the picker / slash list. Each row:
-- { id, name, pulls, packs, active }. Sorted by name (case-insensitive).
function Plan:List()
    local plans = ensurePlans()
    local activeId = CRP.db and CRP.db.global and CRP.db.global.currentPlanId
    local out = {}
    for id, env in pairs(plans) do
        local preset = env and env.preset
        out[#out + 1] = {
            id = id,
            name = (preset and preset.name and preset.name ~= "" and preset.name) or "Unnamed plan",
            pulls = (preset and preset.pulls and #preset.pulls) or 0,
            packs = (env and env.packs and #env.packs) or 0,
            active = (id == activeId),
        }
    end
    -- Sort by name, then id as a stable tiebreak so the suffixing below is
    -- deterministic across calls when names collide.
    table.sort(out, function(a, b)
        if a.name:lower() ~= b.name:lower() then return a.name:lower() < b.name:lower() end
        return a.id < b.id
    end)
    -- Plans are keyed by id, so same-named plans coexist; disambiguate them for
    -- display only (the first keeps its name, the next becomes "Name (2)", …),
    -- mirroring the web planner so the picker rows aren't indistinguishable.
    local seen = {}
    for _, row in ipairs(out) do
        local key = row.name:lower()
        seen[key] = (seen[key] or 0) + 1
        if seen[key] > 1 then
            row.name = string.format("%s (%d)", row.name, seen[key])
        end
    end
    return out
end

-- Delete the active plan (the /crp reset command). Falls through to Delete,
-- which selects a remaining plan or drops to the empty state.
function Plan:Clear()
    local id = CRP.db and CRP.db.global and CRP.db.global.currentPlanId
    if id then self:Delete(id) end
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

-- True iff the pull references at least one mob to kill. A pull with no packs,
-- or only empty/missing packs, has nothing to fight. Cheaper than SlotsForPull
-- (no slot-table allocation) since it only needs existence, not counts.
function Plan:HasMobs(pull)
    if not (pull and pull.packIds) then return false end
    for _, packId in ipairs(pull.packIds) do
        local pack = self:PackById(packId)
        if pack and pack.members and #pack.members > 0 then
            return true
        end
    end
    return false
end

-- A prep step: surfaced by the HUD between pulls (out of combat) for buffs /
-- summons / gear swaps. Either explicitly flagged in the planner (`prep`, which
-- rides along in the preset since the share format is a JSON passthrough) OR any
-- step with no mobs to kill. A mob-less step can never auto-advance on a kill,
-- so treating it as prep is what lets AdvancePastPrep move the cursor off it at
-- combat start — otherwise forgetting the flag traps the cursor there. (We used
-- to require the explicit flag to avoid mistaking a misconfigured empty pull for
-- prep, but getting stuck is the worse failure; SlotsForPull still warns on
-- genuinely broken pack references.)
function Plan:IsPrepPull(pull)
    if pull == nil then return false end
    if pull.prep == true then return true end
    return not self:HasMobs(pull)
end

-- An assignment carries something worth showing iff it's a non-empty reminder or
-- a picked spell/item/equip/kick (numeric id). Mirrors the UI's `hasContent`.
local function assignmentHasContent(a)
    if not a then return false end
    if a.kind == "reminder" then
        return a.text ~= nil and a.text ~= ""
    end
    return type(a.id) == "number"
end

-- A step with nothing to it at all: no mobs, no note, no real assignments. These
-- are almost always an accidental blank pull, and there's literally nothing for
-- the HUD to show, so auto-advance passes straight through rather than parking
-- the cursor on a blank box. (A mob-less step that *does* carry a note or
-- assignments is a real prep step — IsPrepPull true, IsEmptyStep false — and
-- still gets dwelt on out of combat so people can read it.) The `prep` flag is
-- ignored here: an explicitly-flagged but contentless step is still nothing to
-- show, so it's skippable too.
function Plan:IsEmptyStep(pull)
    if not pull then return false end
    if self:HasMobs(pull) then return false end
    if pull.note and pull.note ~= "" then return false end
    for _, a in ipairs(pull.assignments or {}) do
        if assignmentHasContent(a) then return false end
    end
    return true
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
        -- Pass through pulls that are already done (e.g. pre-filled by overflow
        -- kills) and steps that are entirely empty (nothing to show — see
        -- IsEmptyStep), stopping at the first pull that actually needs attention:
        -- a real incomplete pull, or a prep step carrying notes/assignments.
        if CRP.Tracker:IsPullCompleteFor(pulls[probe]) or self:IsEmptyStep(pulls[probe]) then
            target = probe
        else
            target = probe
            break
        end
    end
    -- Progression chatter is debug-only — the cursor moving in the HUD/window is
    -- the real feedback. Advancement itself (SetCurrentPullIdx) is unconditional.
    local debug = CRP.db and CRP.db.global and CRP.db.global.debug
    if target > idx then
        self:SetCurrentPullIdx(target)
        if debug then
            if target == n and CRP.Tracker:IsPullComplete() then
                print("|cff38c24fCafeRaidPlanner:|r final pull complete.")
            else
                print("|cff38c24fCafeRaidPlanner:|r pull complete — advancing to pull " .. target)
            end
        end
    elseif target == n and debug then
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
