-- Wire format for match events: pure string <-> table conversion, no WoW API.
-- An event becomes "<code>,<field>,<field>..." with numbers rounded to fixed precision (trailing zeros dropped);
-- several events join with "|" into one addon message. Clients apply the *decoded* form of their own events too
-- (Codec.normalize), so the sender and every receiver hold bit-identical state.

local _, ns = ...

local Codec = {}
ns.Codec = Codec

-- type -> { code, fields }, and code -> type
local FORMATS = {
    START = { "A", { "t", "win" } },
    SERVE = { "S", { "t", "dir", "angle" } },
    MOVE = { "M", { "t", "seat", "y" } },
    HIT = { "H", { "t", "seat", "x", "y", "vx", "vy", "speed" } },
    MISS = { "X", { "t", "seat" } },
    FORFEIT = { "F", { "t", "seat" } },
}
local BY_CODE = {}
for kind, f in pairs(FORMATS) do BY_CODE[f[1]] = kind end

-- Decimal places per field (default 2).
local PRECISION = { t = 3, angle = 4, seat = 0, dir = 0, win = 0 }

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

-- Match snapshots for spectators who arrive mid-match: every field Sim needs to carry on from here, as one
-- comma-separated string. Times keep 3 decimals, everything else 2.
local PHASE_CODE = { countdown = "c", play = "p", point = "x", over = "o", idle = "i" }
local PHASE_BY_CODE = {}
for k, v in pairs(PHASE_CODE) do PHASE_BY_CODE[v] = k end

function Codec.encodeSnapshot(m)
    local b, p1, p2 = m.ball, m.paddles[1], m.paddles[2]
    local n = Codec.num
    return table.concat({
        PHASE_CODE[m.phase] or "i", m.score[1], m.score[2], m.serveAt and n(m.serveAt, 3) or "",
        m.serveDir or 0, m.hits, m.winner or 0, m.forfeit and 1 or 0,
        n(b.x, 2), n(b.y, 2), n(b.vx, 2), n(b.vy, 2), n(b.speed, 2), n(b.t, 3),
        n(p1.y, 2), n(p1.target, 2), n(p1.t, 3), n(p2.y, 2), n(p2.target, 2), n(p2.t, 3),
        m.pointsToWin, m.longest,
    }, ",")
end

function Codec.decodeSnapshot(s)
    local f = Codec.split(s, ",")
    if #f ~= 22 or not PHASE_BY_CODE[f[1]] then return nil end
    local v = {}
    for i = 2, 22 do
        if i ~= 4 then
            v[i] = tonumber(f[i])
            if not v[i] then return nil end
        end
    end
    local serveDir = v[5] ~= 0 and v[5] or nil
    return {
        phase = PHASE_BY_CODE[f[1]], score = { v[2], v[3] }, serveAt = tonumber(f[4]), serveDir = serveDir,
        hits = v[6], winner = v[7] ~= 0 and v[7] or nil, forfeit = v[8] == 1,
        ball = { x = v[9], y = v[10], vx = v[11], vy = v[12], speed = v[13], t = v[14] },
        paddles = { { y = v[15], target = v[16], t = v[17] }, { y = v[18], target = v[19], t = v[20] } },
        pointsToWin = v[21], longest = v[22],
    }
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
