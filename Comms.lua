local _, CRP = ...

-- Comms: AceComm-backed plan/pull sync between raid leader and receivers.
--
--   CRPPLAN   Full plan payload { envelope, currentPullIdx }. Sent by RL/assist
--             via "RAID"/"PARTY" (broadcast) or "WHISPER" (answering CRPREQ).
--             Receivers prompt the user before replacing the local plan, unless
--             CRP.db.global.autoApplyIncomingPlan is true.
--
--   CRPPULL   "<planUid>:<idx>" — pull-index change. Sent by RL on navigation.
--             Receivers apply only if planUid matches their loaded plan's id.
--
--   CRPREQ    Empty signal. Sent by a client that opened the window with no
--             plan loaded; anyone with a plan whispers a CRPPLAN back.

local Comms = {}
CRP.Comms = Comms

local PREFIX_PLAN = "CRPPLAN"
local PREFIX_PULL = "CRPPULL"
local PREFIX_REQ  = "CRPREQ"

local AceSerializer = LibStub("AceSerializer-3.0")
local LibDeflate = LibStub("LibDeflate")

-- Pack a message table into a wire payload: Serialize → Deflate → addon-safe
-- encoding. Shrinks a ~40 KB plan envelope to ~5 KB, which matters because
-- ChatThrottleLib caps outgoing addon traffic and BULK priority is the slowest
-- lane. At NORMAL priority a compressed plan delivers in a couple of seconds
-- instead of nearly a minute.
local function encodePayload(tbl)
    local serialized = AceSerializer:Serialize(tbl)
    local compressed = LibDeflate:CompressDeflate(serialized)
    return LibDeflate:EncodeForWoWAddonChannel(compressed)
end

local function decodePayload(encoded)
    local compressed = LibDeflate:DecodeForWoWAddonChannel(encoded)
    if not compressed then return nil end
    local serialized = LibDeflate:DecompressDeflate(compressed)
    if not serialized then return nil end
    local ok, tbl = AceSerializer:Deserialize(serialized)
    if not ok then return nil end
    return tbl
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function stripRealm(name)
    if not name or name == "" then return name end
    return name:match("^([^-]+)") or name
end

local function channel()
    if IsInRaid() then return "RAID" end
    if IsInGroup() then return "PARTY" end
    return nil
end

local function isSelf(sender)
    return stripRealm(sender) == UnitName("player")
end

-- True if `sender` is currently raid leader, raid assistant, or (in a party)
-- the party leader. GetRaidRosterInfo rank: 2 = leader, 1 = assist, 0 = member.
local function senderHasAuthority(sender)
    local want = stripRealm(sender)
    if IsInRaid() then
        for i = 1, GetNumGroupMembers() do
            local name, rank = GetRaidRosterInfo(i)
            if name and stripRealm(name) == want then
                return (rank or 0) >= 1
            end
        end
        return false
    elseif IsInGroup() then
        -- Party: only leader has authority.
        local numMembers = GetNumGroupMembers()
        for i = 1, numMembers - 1 do
            local unit = "party" .. i
            if stripRealm(UnitName(unit) or "") == want then
                return UnitIsGroupLeader(unit)
            end
        end
        if stripRealm(UnitName("player") or "") == want then
            return UnitIsGroupLeader("player")
        end
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Receive prompt
-- ---------------------------------------------------------------------------

StaticPopupDialogs["CRP_CONFIRM_IMPORT"] = {
    text = "%s",                    -- filled via StaticPopup_Show(…, summary)
    button1 = ACCEPT or "Accept",
    button2 = CANCEL or "Cancel",
    OnAccept = function(self)
        local data = self.data
        if data and data.envelope then
            Comms:_ApplyIncoming(data.envelope, data.currentPullIdx, data.sender)
        end
    end,
    timeout = 60,
    hideOnEscape = true,
    whileDead = true,
    preferredIndex = 3,
}

function Comms:_ApplyIncoming(envelope, currentPullIdx, sender)
    if type(envelope) ~= "table" or type(envelope.preset) ~= "table" then return end
    CRP.Plan:Import(envelope)
    -- silent=true: don't re-broadcast our acceptance back into the channel.
    CRP.Plan:SetCurrentPullIdx(type(currentPullIdx) == "number" and currentPullIdx or 1, true)
    print(("|cff38c24fCRP:|r imported plan from %s (%d pulls, %d packs)."):format(
        stripRealm(sender or "?"),
        #(envelope.preset.pulls or {}),
        #(envelope.packs or {})))
end

-- ---------------------------------------------------------------------------
-- Capability checks
-- ---------------------------------------------------------------------------

function Comms:CanPush()
    if IsInRaid() then
        return UnitIsGroupLeader("player") or UnitIsGroupAssistant("player")
    elseif IsInGroup() then
        return UnitIsGroupLeader("player")
    end
    return false
end

-- ---------------------------------------------------------------------------
-- Outgoing
-- ---------------------------------------------------------------------------

function Comms:PushPlan()
    if not self:CanPush() then return false, "not in a group you lead" end
    local envelope = CRP.Plan:Current()
    if not envelope then return false, "no plan loaded" end
    local ch = channel()
    if not ch then return false, "not in a group" end
    local payload = encodePayload({
        envelope = envelope,
        currentPullIdx = CRP.Plan:CurrentPullIdx(),
    })
    CRP.Core:SendCommMessage(PREFIX_PLAN, payload, ch, nil, "NORMAL")
    print(("|cff8888ffCRP:|r pushed plan (%d pulls, %d packs, %d bytes) to %s."):format(
        #(envelope.preset.pulls or {}), #(envelope.packs or {}), #payload, ch:lower()))
    return true
end

function Comms:PushPull()
    if not self:CanPush() then return false, "not in a group you lead" end
    local envelope = CRP.Plan:Current()
    if not envelope then return false, "no plan loaded" end
    local ch = channel()
    if not ch then return false, "not in a group" end
    local uid = (envelope.preset and envelope.preset.id) or ""
    local payload = uid .. ":" .. tostring(CRP.Plan:CurrentPullIdx())
    CRP.Core:SendCommMessage(PREFIX_PULL, payload, ch, nil, "NORMAL")
    return true
end

function Comms:RequestPlan()
    local ch = channel()
    if not ch then return false, "not in a group" end
    CRP.Core:SendCommMessage(PREFIX_REQ, "", ch)
    return true
end

-- ---------------------------------------------------------------------------
-- Incoming
-- ---------------------------------------------------------------------------

function Comms:Init()
    -- AceComm fires registered function callbacks with 4 positional args:
    -- (prefix, message, distribution, sender). No implicit self.
    CRP.Core:RegisterComm(PREFIX_PLAN, function(_, message, _, sender)
        if isSelf(sender) then return end
        if not senderHasAuthority(sender) then return end
        local msg = decodePayload(message)
        if type(msg) ~= "table" or type(msg.envelope) ~= "table" then return end
        if CRP.db.global.autoApplyIncomingPlan then
            Comms:_ApplyIncoming(msg.envelope, msg.currentPullIdx, sender)
        else
            local env = msg.envelope
            local summary = ("%s sent a raid plan (%d pulls, %d packs).\n\nImport? Your current plan and kill progress will be replaced."):format(
                stripRealm(sender), #(env.preset.pulls or {}), #(env.packs or {}))
            StaticPopup_Show("CRP_CONFIRM_IMPORT", summary, nil, {
                envelope = env,
                currentPullIdx = msg.currentPullIdx,
                sender = sender,
            })
        end
    end)

    CRP.Core:RegisterComm(PREFIX_PULL, function(_, message, _, sender)
        if isSelf(sender) then return end
        if not senderHasAuthority(sender) then return end
        local uid, idxStr = message:match("^([^:]*):(%d+)$")
        if not uid or not idxStr then return end
        local envelope = CRP.Plan:Current()
        if not envelope or not envelope.preset or envelope.preset.id ~= uid then return end
        CRP.Plan:SetCurrentPullIdx(tonumber(idxStr), true)  -- silent, no echo
    end)

    CRP.Core:RegisterComm(PREFIX_REQ, function(_, _, _, sender)
        if isSelf(sender) then return end
        -- Anyone holding a plan answers, so late joiners can bootstrap from any
        -- group member (not just the leader). Reply privately to avoid spam.
        local envelope = CRP.Plan:Current()
        if not envelope then return end
        local payload = encodePayload({
            envelope = envelope,
            currentPullIdx = CRP.Plan:CurrentPullIdx(),
        })
        CRP.Core:SendCommMessage(PREFIX_PLAN, payload, "WHISPER", Ambiguate(sender, "none"), "NORMAL")
    end)
end
