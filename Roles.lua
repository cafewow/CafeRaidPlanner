local _, CRP = ...

-- Per-viewer role resolution for role-targeted assignments. A manual override
-- (CRP.db.char.role) wins; otherwise we infer from talents/spec the same way
-- the reference WeakAura does. Three roles only — melee and ranged both fold
-- into "damage" (Blizzard's DAMAGER). Consumed by CRP.ui.IsMyAssignment, so the
-- role gate applies to both the personal view and the combat HUD.
local Roles = {}
CRP.Roles = Roles

local VALID = { tank = true, healer = true, damage = true }
Roles.VALID = VALID

-- True iff the player knows any of the given spell ids (talent/spec markers).
local function knowsAny(...)
    for i = 1, select("#", ...) do
        local id = select(i, ...)
        if IsPlayerSpell and IsPlayerSpell(id) then return true end
    end
    return false
end

-- Talent/spec inference, mirroring the reference WA's class checks. The melee vs
-- ranged split the reference tracks is irrelevant here — both are "damage" — so
-- only the tank/healer markers need testing; everything else falls through.
local function detect()
    local class = (UnitClassBase and UnitClassBase("player"))
        or select(2, UnitClass("player"))
    if class == "DRUID" then
        if knowsAny(17116) then return "healer" end                          -- Nature's Swiftness (resto)
        if knowsAny(16933, 16930, 16932, 16929, 16931) then return "tank" end -- Thick Hide (feral/bear)
        return "damage"
    elseif class == "PALADIN" then
        if knowsAny(20930) then return "healer" end                          -- Holy Shock
        if knowsAny(20925) then return "tank" end                            -- Holy Shield
        return "damage"
    elseif class == "PRIEST" then
        if knowsAny(15473) then return "damage" end                          -- Shadowform
        return "healer"
    elseif class == "SHAMAN" then
        if knowsAny(16190) then return "healer" end                          -- Mana Tide Totem (resto)
        return "damage"
    elseif class == "WARRIOR" then
        if knowsAny(23922, 30356, 25258) then return "tank" end              -- Shield Slam
        return "damage"
    end
    -- HUNTER / MAGE / WARLOCK / ROGUE are always damage.
    return "damage"
end

-- The active role: the manual override if set & valid, else talent inference.
function Roles:Get()
    local override = CRP.db and CRP.db.char and CRP.db.char.role
    if override and VALID[override] then return override end
    return detect()
end

-- True when no manual override is in effect (role is coming from talents).
function Roles:IsAuto()
    local override = CRP.db and CRP.db.char and CRP.db.char.role
    return not (override and VALID[override])
end

-- Set the manual override. nil / "auto" clears it (back to talent inference).
-- Returns the resulting active role.
function Roles:SetOverride(role)
    if CRP.db and CRP.db.char then
        if role == nil or role == "auto" then
            CRP.db.char.role = nil
        elseif VALID[role] then
            CRP.db.char.role = role
        end
    end
    self._lastDetected = self:Get()   -- resync so the next Recheck doesn't double-refresh
    return self:Get()
end

-- Re-evaluate the detected role and refresh the personal view if it changed.
-- Only auto mode reacts — a manual override is fixed regardless of talents. The
-- changed-only guard matters because SPELLS_CHANGED fires often (every spell
-- learned, every talent tweak); we don't want to redraw the window each time.
-- Wired to GROUP_JOINED / ZONE_CHANGED_NEW_AREA / SPELLS_CHANGED / PLAYER_ENTERING_WORLD
-- in Core.lua. The combat HUD reads the role live as it rebuilds, so it needs no
-- explicit poke here.
function Roles:Recheck()
    if not self:IsAuto() then return end
    local now = detect()
    if now == self._lastDetected then return end
    self._lastDetected = now
    if CRP.ui and CRP.ui.Window and CRP.ui.Window.Refresh then
        CRP.ui.Window:Refresh()
    end
end
