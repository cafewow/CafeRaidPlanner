local addonName, CRP = ...
_G[addonName] = CRP

CRP.version = "0.1.0-dev"
CRP.raids = {}         -- [raidId] = static raid definition (populated by Data/<Raid>.lua)
CRP.ui = {}            -- UI submodule table
CRP.planner = {}       -- planner submodule table

-- Cross-version shims (TBC Classic 2.5.x vs. retail 11.x+).
-- GetSpellInfo was removed as a global in retail 11.x; C_Spell.GetSpellInfo
-- returns a struct instead of positional values.
if not GetSpellInfo then
    function GetSpellInfo(id)
        if not id then return end
        local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(id)
        if info then return info.name, nil, info.iconID end
    end
end
