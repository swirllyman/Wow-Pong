-- The current match on this client: owns the Sim match, the bots, and which seats/host duties are ours, and
-- drives them every frame. For now matches are local only (practice vs a bot, or bot vs bot); networking will
-- hook Game.push to broadcast events and feed received ones through Sim.apply.

local _, ns = ...
local Sim, Bot = ns.Sim, ns.Bot

local Game = {}
ns.Game = Game

Game.match = nil       -- Sim match, or nil when nothing is running
Game.names = {}        -- display name per seat
Game.bots = {}
Game.humanSeat = nil   -- the seat this player clicks for, if any
Game.auth = nil        -- see Sim.step

local driver = CreateFrame("Frame")
driver:Hide()
driver:SetScript("OnUpdate", function() Game.tick(GetTime()) end)
Game.driver = driver

local function onApplied(ev)
    local m = Game.match
    if m.phase == "over" and (ev.type == "MISS" or ev.type == "FORFEIT") then
        ns.log(string.format("match over: %s %d - %d %s, winner %s%s", Game.names[1], m.score[1], m.score[2],
            Game.names[2], Game.names[m.winner], m.forfeit and " (forfeit)" or ""))
    end
end

-- Applies an event created on this client (a click, a bot move).
function Game.push(ev)
    if Game.match and Sim.apply(Game.match, ev) then onApplied(ev) end
end

-- Starts a local match. seatDefs[i] = { kind = "human" } or { kind = "bot", level = "easy"|"normal"|"hard" }.
function Game.startLocal(seatDefs)
    Game.match = Sim.newMatch()
    Game.bots, Game.names, Game.humanSeat = {}, {}, nil
    for seat, def in ipairs(seatDefs) do
        if def.kind == "bot" then
            local bot = Bot.new(seat, def.level, math.random)
            Game.bots[#Game.bots + 1] = bot
            Game.names[seat] = "Bot (" .. Bot.NAMES[bot.level] .. ")"
        else
            Game.humanSeat = seat
            Game.names[seat] = ns.show((UnitName("player")))
        end
    end
    Game.auth = { seats = { true, true }, host = true, rand = math.random }
    Game.push({ type = "START", t = GetTime() })
    ns.log("local match: " .. Game.names[1] .. " vs " .. Game.names[2])
    driver:Show()
end

function Game.stop()
    Game.match, Game.bots, Game.humanSeat = nil, {}, nil
    driver:Hide()
end

-- The local player clicked the board at board-y `y`.
function Game.click(y)
    local m = Game.match
    if not m or not Game.humanSeat or m.phase == "over" or m.phase == "idle" then return end
    Game.push({ type = "MOVE", t = GetTime(), seat = Game.humanSeat, y = y })
end

function Game.tick(now)
    local m = Game.match
    if not m then return end
    for _, ev in ipairs(Sim.step(m, now, Game.auth)) do onApplied(ev) end
    if m.phase == "over" then return end
    for _, bot in ipairs(Game.bots) do
        local ev = bot:update(m, now)
        if ev then Game.push(ev) end
    end
end
