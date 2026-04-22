local _, CRP = ...

-- Comms module. Intentionally a scaffold right now — the wire protocol is
-- sketched out but the actual AceComm registration and chunked transmission
-- lives inside TODO blocks. The public surface (PushPull, PushPlan, CanPush,
-- etc.) is final so UI callsites and future implementation can land without
-- further shape changes.
--
-- Protocol sketch (to be implemented in phase C):
--
--   Prefix "CRPPULL"   RL broadcasts current pull index.
--                      Payload: "<planUid>:<pullIdx>"
--                      Receivers apply iff their loaded plan's preset.id
--                      matches planUid AND sender is group leader/assist.
--
--   Prefix "CRPPLAN"   RL pushes full plan envelope.
--                      Payload: AceSerializer(envelope), chunked by AceComm.
--                      Receivers prompt "Raid leader sent a plan — import?".
--
--   Prefix "CRPREQ"    Late joiner asks whoever has a plan to push it.
--                      Payload: "" (empty, just a signal).
--                      Anyone who has a matching plan responds with CRPPLAN.
--
-- Channel selection:
--   IsInRaid()     → "RAID"
--   IsInGroup()    → "PARTY"
--   otherwise      → no-op (nothing to sync with).

local Comms = {}
CRP.Comms = Comms

local PREFIX_PULL = "CRPPULL"
local PREFIX_PLAN = "CRPPLAN"
local PREFIX_REQ  = "CRPREQ"

-- ---------------------------------------------------------------------------
-- Capability checks
-- ---------------------------------------------------------------------------

-- True iff the user is in a group large enough to sync with AND has authority
-- to push (leader in party, leader-or-assist in raid). Other addons that sync
-- raid state (BigWigs, MRT, MDT's LiveSession) use the same rule.
function Comms:CanPush()
    if IsInRaid() then
        return UnitIsGroupLeader("player") or (UnitIsGroupAssistant and UnitIsGroupAssistant("player"))
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    end
    return false
end

local function currentChannel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

-- ---------------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------------

-- Broadcast the current pull index to the raid. No-op if not permitted.
function Comms:PushPull()
    if not self:CanPush() then return false, "not in a group you lead" end
    local envelope = CRP.Plan:Current()
    if not envelope then return false, "no plan loaded" end
    local idx = CRP.Plan:CurrentPullIdx()
    local planUid = (envelope.preset and envelope.preset.id) or ""
    local channel = currentChannel()
    if not channel then return false, "no channel" end

    -- TODO(phase C): register PREFIX_PULL with AceComm and send the payload.
    --   local AceComm = LibStub("AceComm-3.0")
    --   AceComm:SendCommMessage(PREFIX_PULL, planUid..":"..tostring(idx), channel)
    print(string.format("|cff8888ffCRP:|r (stub) would push pull %d (plan %s) on %s",
        idx, planUid, channel))
    return true
end

-- Broadcast the entire plan envelope so receivers can import it without
-- needing a paste string.
function Comms:PushPlan()
    if not self:CanPush() then return false, "not in a group you lead" end
    local envelope = CRP.Plan:Current()
    if not envelope then return false, "no plan loaded" end

    -- TODO(phase C): serialize + deflate (or just serialize; AceComm already
    -- handles chunking). Then send on PREFIX_PLAN.
    --   local AceSerializer = LibStub("AceSerializer-3.0")
    --   local payload = AceSerializer:Serialize(envelope)
    --   AceComm:SendCommMessage(PREFIX_PLAN, payload, currentChannel(), nil, "BULK")
    print("|cff8888ffCRP:|r (stub) would push full plan")
    return true
end

-- Ask whoever has a plan to send it. Used by a late-joiner who opens the
-- window and sees "No plan imported".
function Comms:RequestPlan()
    local channel = currentChannel()
    if not channel then return false, "no channel" end
    -- TODO(phase C): AceComm:SendCommMessage(PREFIX_REQ, "", channel)
    print("|cff8888ffCRP:|r (stub) would request plan from group")
    return true
end

-- ---------------------------------------------------------------------------
-- Incoming (registered in :Init, handlers implement in phase C)
-- ---------------------------------------------------------------------------

function Comms:Init()
    -- TODO(phase C): register AceComm prefixes and wire handlers.
    --   local AceComm = LibStub("AceComm-3.0")
    --   AceComm:RegisterComm(PREFIX_PULL, function(_, _, payload, _, sender) ... end)
    --   AceComm:RegisterComm(PREFIX_PLAN, function(_, _, payload, _, sender) ... end)
    --   AceComm:RegisterComm(PREFIX_REQ,  function(_, _, payload, _, sender) ... end)
    --
    -- Receive guardrails to apply in all handlers:
    --   - Reject messages from self.
    --   - For CRPPULL/CRPPLAN: check sender is UnitIsGroupLeader / assistant.
    --   - For CRPPULL: verify planUid matches locally loaded plan; ignore otherwise.
    --   - For CRPPLAN: prompt user before replacing the local plan.
end
