local _, CRP = ...

-- Small, dependency-free helpers shared across modules. These are domain
-- invariants (the WoW GUID format, realm-suffix stripping) that were previously
-- copy-pasted into Tracker / Comms / UI / Triggers — keeping one copy here means
-- a format change lands in exactly one place. Pure functions, no state.
local util = {}
CRP.util = util

-- npcId out of a creature/vehicle GUID, or nil for anything else (players, pets).
function util.npcIdFromGUID(guid)
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
function util.instanceKeyFromGUID(guid)
    if not guid then return nil end
    local kind, _, serverID, _, zoneUID = strsplit("-", guid)
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    if not serverID or not zoneUID then return nil end
    return serverID .. "-" .. zoneUID
end

-- Strip the realm suffix from a name like "Gustaf-Gehennas" → "Gustaf".
function util.stripRealm(name)
    if not name or name == "" then return name end
    return name:match("^([^-]+)") or name
end
