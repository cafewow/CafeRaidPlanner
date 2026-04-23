local _, CRP = ...

local Share = {}
CRP.Share = Share

local json = _G.CafeRaidPlanner_json
local LibDeflate = LibStub and LibStub("LibDeflate", true)

-- base64 (standard alphabet) decode. base64url is pre-normalized before entry.
local B64_CHARS = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local B64_LOOKUP = {}
for i = 1, #B64_CHARS do
    B64_LOOKUP[B64_CHARS:sub(i, i)] = i - 1
end

local function b64decode(s)
    local out = {}
    local bits, bitsCount = 0, 0
    for i = 1, #s do
        local c = s:sub(i, i)
        if c == "=" then break end
        local v = B64_LOOKUP[c]
        if v == nil then return nil, "invalid base64 character " .. c end
        bits = bits * 64 + v
        bitsCount = bitsCount + 6
        while bitsCount >= 8 do
            bitsCount = bitsCount - 8
            local div = 2 ^ bitsCount
            local byte = math.floor(bits / div)
            bits = bits - byte * div
            out[#out + 1] = string.char(byte)
        end
    end
    return table.concat(out)
end

-- Decode a paste-string emitted by the web app (crp1.<base64url(deflate(JSON))>).
-- Returns the envelope table {v, preset, packs} or (nil, err).
function Share:Decode(str)
    if type(str) ~= "string" then
        return nil, "not a string"
    end
    if not json then
        return nil, "JSON library not loaded"
    end
    if not LibDeflate then
        return nil, "LibDeflate not loaded"
    end

    local trimmed = str:gsub("^%s+", ""):gsub("%s+$", "")
    if not trimmed:match("^crp1%.") then
        return nil, "missing crp1. prefix"
    end
    local body = trimmed:sub(6)                       -- strip "crp1."
    body = body:gsub("-", "+"):gsub("_", "/")         -- base64url → base64
    local padNeeded = (4 - (#body % 4)) % 4
    body = body .. string.rep("=", padNeeded)

    local bin, err = b64decode(body)
    if not bin then return nil, "base64: " .. tostring(err) end

    -- Web app uses pako.deflate() which produces zlib-wrapped output (RFC 1950).
    -- Try zlib first; fall back to raw deflate in case a future envelope switches.
    local decompressed = LibDeflate:DecompressZlib(bin)
    if not decompressed then
        decompressed = LibDeflate:DecompressDeflate(bin)
    end
    if not decompressed then return nil, "decompression failed" end

    local ok, result = pcall(json.decode, decompressed)
    if not ok then return nil, "json parse: " .. tostring(result) end

    if type(result) ~= "table" or type(result.preset) ~= "table" or type(result.packs) ~= "table" then
        return nil, "malformed envelope"
    end

    -- Web format is v3 (bosses baked into packs). v1/v2 payloads may also parse,
    -- but missing/obsolete fields just render as empty rather than hard-breaking.
    return result
end
