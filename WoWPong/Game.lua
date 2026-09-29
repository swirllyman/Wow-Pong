-- The current match on this client: owns the Sim match, the bots, which seats/host duties are ours, and the match
-- clock, and drives them every frame. Local matches (practice, bot demo) live entirely here; for networked ones
-- Table.lua calls Game.begin, sends what Game.onLocalEvent hands it, and feeds received events to Game.receive.

local _, ns = ...
local Sim, Bot, Codec = ns.Sim, ns.Bot, ns.Codec

local Game = {}
ns.Game = Game

Game.match = nil        -- Sim match, or nil when nothing is running
Game.names = {}         -- display name per seat
Game.bots = {}
Game.humanSeat = nil    -- the seat this player clicks for, if any
Game.auth = nil         -- see Sim.step
Game.base = 0           -- match time = GetTime() - base (the host's clock, for networked matches)
Game.networked = false
Game.onLocalEvent = nil -- function(ev): an event created here was applied (Table broadcasts it)
Game.listeners = {}     -- functions(ev) called for every applied event, local or remote
Game.onOver = nil       -- function(match): a match this client played in ended (Stats records it)
Game.opponent = nil     -- who the local human faces: { kind = "human", pid, name } or { kind = "bot", level }

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function() Game.tick(Game.clock()) end)
Game.driver = driver

function Game.clock()
    return GetTime() - Game.base
end

local function onApplied(ev)
    local m = Game.match
    if m.phase == "over" and (ev.type == "MISS" or ev.type == "FORFEIT") then
        ns.log(string.format("match over: %s %d - %d %s, winner %s%s", Game.names[1] or "?", m.score[1], m.score[2],
            Game.names[2] or "?", Game.names[m.winner] or "?", m.forfeit and " (forfeit)" or ""))
        if Game.humanSeat and Game.onOver then Game.onOver(m) end
    end
    for _, fn in ipairs(Game.listeners) do fn(ev) end
end

local function created(ev)
    onApplied(ev)
    if Game.networked and Game.onLocalEvent then Game.onLocalEvent(ev) end
end

-- Starts a new match. opts = {
--   names = { name1, name2 }, seats = { [seat] = true if this client judges it }, host = bool,
--   humanSeat = seat or nil, bots = { [seat] = level }, base = clock base, networked = bool,
--   opponent = see Game.opponent }
function Game.begin(opts)
    Game.match = Sim.newMatch()
    Game.names = opts.names
    Game.humanSeat = opts.humanSeat
    Game.opponent = opts.opponent
    Game.bots = {}
    for seat, level in pairs(opts.bots or {}) do Game.bots[#Game.bots + 1] = Bot.new(seat, level, math.random) end
    Game.networked = opts.networked or false
    Game.auth = { seats = opts.seats, host = opts.host, rand = math.random,
        normalize = Game.networked and Codec.normalize or nil }
    Game.base = opts.base or 0
    driver:Show()
end

-- Starts a local match. seatDefs[i] = { kind = "human" } or { kind = "bot", level = "easy"|"normal"|"hard" }.
function Game.startLocal(seatDefs)
    local names, bots, humanSeat = {}, {}, nil
    for seat, def in ipairs(seatDefs) do
        if def.kind == "bot" then
            local level = Bot.PROFILES[def.level] and def.level or "normal"
            bots[seat] = level
            names[seat] = "Bot (" .. Bot.NAMES[level] .. ")"
        else
            humanSeat = seat
            names[seat] = ns.show((UnitName("player")))
        end
    end
    local opponent = humanSeat and bots[3 - humanSeat] and { kind = "bot", level = bots[3 - humanSeat] } or nil
    Game.begin({ names = names, seats = { true, true }, host = true, humanSeat = humanSeat, bots = bots,
        opponent = opponent })
    Game.push({ type = "START", t = Game.clock() })
    ns.log("local match: " .. names[1] .. " vs " .. names[2])
end

function Game.stop()
    Game.match, Game.bots, Game.humanSeat, Game.networked, Game.opponent = nil, {}, nil, false, nil
    driver:Hide()
end

-- Applies an event created on this client (a click, a bot move, a host decision).
function Game.push(ev)
    if not Game.match then return end
    if Game.networked then ev = Codec.normalize(ev) end
    if Sim.apply(Game.match, ev) then created(ev) end
end

-- Applies an event received from another client.
function Game.receive(ev)
    if Game.match and Sim.apply(Game.match, ev) then onApplied(ev) end
end

-- The local player clicked the board at board-y `y`.
function Game.click(y)
    local m = Game.match
    if not m or not Game.humanSeat or m.phase == "over" or m.phase == "idle" then return end
    Game.push({ type = "MOVE", t = Game.clock(), seat = Game.humanSeat, y = y })
end

function Game.tick(now)
    local m = Game.match
    if not m then return end
    for _, ev in ipairs(Sim.step(m, now, Game.auth)) do created(ev) end
    if m.phase == "over" then return end
    for _, bot in ipairs(Game.bots) do
        local ev = bot:update(m, now)
        if ev then Game.push(ev) end
    end
end
