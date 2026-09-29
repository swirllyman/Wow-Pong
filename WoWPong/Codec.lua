-- Wire format for match events: pure string <-> table conversion, no WoW API.
-- An event becomes "<code>,<field>,<field>..." with numbers rounded to fixed precision (trailing zeros dropped);
-- several events join with "|" into one addon message. Clients apply the *decoded* form of their own events too
-- (Codec.normalize), so the sender and every receiver hold bit-identical state.

local _, ns = ...

local Codec = {}
ns.Codec = Codec

-- type -> { code, fields }, and code -> type
local FORMATS = {
    START = { "A", { "t" } },
    SERVE = { "S", { "t", "dir", "angle" } },
    MOVE = { "M", { "t", "seat", "y" } },
    HIT = { "H", { "t", "seat", "x", "y", "vx", "vy", "speed" } },
    MISS = { "X", { "t", "seat" } },
    FORFEIT = { "F", { "t", "seat" } },
}
local BY_CODE = {}
for kind, f in pairs(FORMATS) do BY_CODE[f[1]] = kind end

-- Decimal places per field (default 2).
local PRECISION = { t = 3, angle = 4, seat = 0, dir = 0 }

function Codec.num(v, places)
    local s = string.format("%." .. places .. "f", v)
    if s:find("%.") then s = s:gsub("0+$", ""):gsub("%.$", "") end
    if s == "-0" then s = "0" end
    return s
end

function Codec.encodeEvent(ev)
    local f = FORMATS[ev.type]
    if not f then return nil end
    local parts = { f[1] }
    for _, name in ipairs(f[2]) do
        parts[#parts + 1] = Codec.num(ev[name] or 0, PRECISION[name] or 2)
    end
    return table.concat(parts, ",")
end

function Codec.decodeEvent(s)
    local code = s:sub(1, 1)
    local kind = BY_CODE[code]
    if not kind then return nil end
    local ev = { type = kind }
    local i = 0
    local names = FORMATS[kind][2]
    for field in s:sub(3):gmatch("[^,]+") do
        i = i + 1
        local name = names[i]
        local v = tonumber(field)
        if not name or not v then return nil end
        ev[name] = v
    end
    if i ~= #names then return nil end
    return ev
end

-- The event exactly as receivers will see it.
function Codec.normalize(ev)
    return Codec.decodeEvent(Codec.encodeEvent(ev))
end

-- Splits a message on ";" keeping empty fields.
function Codec.split(text, sep)
    sep = sep or ";"
    local out = {}
    local start = 1
    while true do
        local i = text:find(sep, start, true)
        if not i then
            out[#out + 1] = text:sub(start)
            return out
        end
        out[#out + 1] = text:sub(start, i - 1)
        start = i + 1
    end
end

-- Packs encoded events into as few "|"-joined bodies as fit in `room` bytes each.
function Codec.pack(encoded, room)
    local bodies, cur = {}, nil
    for _, e in ipairs(encoded) do
        if cur and #cur + 1 + #e <= room then
            cur = cur .. "|" .. e
        else
            if cur then bodies[#bodies + 1] = cur end
            cur = e
        end
    end
    if cur then bodies[#bodies + 1] = cur end
    return bodies
end
