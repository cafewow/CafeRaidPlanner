local _, CRP = ...

-- Assignment-reveal triggers: decide when an individual assignment surfaces
-- *within* a pull (distinct from pull-cursor progression, which Plan/Tracker
-- own). This module owns the fight clock, the latch map, and a registry of
-- per-type evaluators. The HUD (and, later, the main window) consume it via
-- Triggers:IsRevealed; new trigger types register an evaluator below without
-- touching the renderers. Lifecycle is driven by the HUD's combat events
-- through the On* hooks — this module subscribes to nothing itself, so there's
-- a single, ordered place the state transitions happen.
local Triggers = {}
CRP.Triggers = Triggers

-- encounterStart: clock for `time` triggers. Anchored at combat start, re-
-- anchored precisely on ENCOUNTER_START (boss pulls), and per-pull while in a
-- continuous fight (so a timer on a pull entered mid-chain measures from when
-- that pull became current). Reset only when combat ends — ENCOUNTER_END
-- deliberately leaves it running, since it can fire while adds keep us in combat.
local encounterStart = nil
-- latched: assignments that have already fired, keyed by the assignment table
-- itself (stable across the 1Hz refresh). Latching keeps a revealed assignment
-- visible even if its condition flickers (e.g. a boss healing back above a %).
local latched = {}
-- testMode: HUD layout preview reveals every triggered assignment (conditions
-- can't fire out of combat).
local testMode = false

-- ===== boss-health sourcing (for bossPct) ====================================

-- Shared GUID parsing (also used by Tracker). Util.lua loads first.
local npcIdFromGUID = CRP.util.npcIdFromGUID

-- The npcIds a bossPct trigger should watch for `pull`. Prefer boss packs (Plan
-- owns that detection) so the trigger tracks the boss, not a low-health add
-- sharing the pull; fall back to every mob in the pull if there's no boss.
local function watchNpcIds(pull)
    local set = {}
    if not (pull and CRP.Plan) then return set end
    local bossPacks = CRP.Plan:BossPacks(pull)
    if #bossPacks > 0 then
        for _, pack in ipairs(bossPacks) do
            for _, m in ipairs(pack.members or {}) do set[m.npcId] = true end
        end
        return set
    end
    for _, packId in ipairs(pull.packIds or {}) do
        local pack = CRP.Plan:PackById(packId)
        if pack and pack.members then
            for _, m in ipairs(pack.members) do set[m.npcId] = true end
        end
    end
    return set
end

-- Best-effort boss health %, sourced from any unit we can see whose npcId is in
-- `set`: our target/focus plus visible nameplates. BCC has no boss1-5 frames
-- (those are WotLK+), so this is the only path — it works when someone near has
-- the boss targeted or nameplated (usually true for a stacked raid) and returns
-- nil otherwise. Lowest match wins so we don't read a fresh add over the boss.
local function bossHealthPct(set)
    if not next(set) then return nil end
    local best
    local function consider(unit)
        if not UnitExists(unit) then return end
        local npcId = npcIdFromGUID(UnitGUID(unit))
        if not npcId or not set[npcId] then return end
        local maxHp = UnitHealthMax(unit)
        if not maxHp or maxHp <= 0 then return end
        local pct = UnitHealth(unit) / maxHp * 100
        if not best or pct < best then best = pct end
    end
    consider("target")
    consider("focus")
    if C_NamePlate and C_NamePlate.GetNamePlates then
        for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
            if plate.namePlateUnitToken then consider(plate.namePlateUnitToken) end
        end
    end
    return best
end

-- Per-frame memo: every bossPct assignment in one refresh evaluates against the
-- same boss health, and GetTime() is constant within a frame, so we compute the
-- watch-set + health scan once per (frame, pull) instead of once per assignment.
local healthTime, healthPull, healthVal
local function bossPctFor(pull)
    local now = GetTime()
    if now == healthTime and pull == healthPull then return healthVal end
    healthTime, healthPull = now, pull
    healthVal = bossHealthPct(watchNpcIds(pull))
    return healthVal
end

-- ===== evaluator registry ====================================================

-- (trigger, pull) -> boolean "fired this instant". Add a new trigger type here
-- plus a matching variant in the web app's RevealTrigger union; the latch /
-- test-mode / clock plumbing in IsRevealed stays generic.
local EVALUATORS = {
    time = function(r)
        return encounterStart ~= nil and (GetTime() - encounterStart) >= (r.afterSec or 0)
    end,
    bossPct = function(r, pull)
        local pct = bossPctFor(pull)
        return pct ~= nil and pct <= (r.below or 0)
    end,
}

-- Public: is this assignment revealed right now? No trigger = always. Latches on
-- first fire so it stays revealed for the rest of the fight.
function Triggers:IsRevealed(a, pull)
    local r = a and a.reveal
    if not r then return true end
    if testMode then return true end
    if latched[a] then return true end
    local ev = EVALUATORS[r.type]
    local fired = ev ~= nil and ev(r, pull) or false
    if fired then latched[a] = true end
    return fired
end

-- ===== lifecycle hooks (driven by the HUD's combat events) ===================

function Triggers:OnCombatStart()
    -- Anchor at combat start; ENCOUNTER_START re-anchors precisely just after on
    -- boss pulls. Only-if-nil so we don't stomp a clock already set this combat.
    if not encounterStart then encounterStart = GetTime() end
end

function Triggers:OnCombatEnd()
    encounterStart = nil
    wipe(latched)
end

function Triggers:OnEncounterStart()
    encounterStart = GetTime()
    wipe(latched)
end

function Triggers:OnEncounterEnd()
    -- Keep the clock running (adds may hold us in combat); OnCombatEnd resets it.
    wipe(latched)
end

function Triggers:OnPullChanged(inCombat)
    -- New pull → fresh latches. Mid-combat (a trash chain advancing pulls), re-
    -- anchor so `time` triggers measure from when this pull became current, not
    -- from the start of the whole combat.
    wipe(latched)
    if inCombat then encounterStart = GetTime() end
end

function Triggers:SetTestMode(on)
    testMode = on and true or false
end
