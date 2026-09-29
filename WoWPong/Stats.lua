-- Per-character win/loss records (WoWPongCharDB.stats). Matches against real players make up the main record
-- (wins, losses, forfeits, streaks, points, head-to-head by opponent); bot games are kept apart per difficulty,
-- local practice included. Spectating never counts.

local _, ns = ...
local Game, Bot = ns.Game, ns.Bot

local Stats = {}
ns.Stats = Stats

local HEAD_TO_HEAD_SHOWN = 7

local function blankHuman()
    return { wins = 0, losses = 0, forfeitWins = 0, forfeitLosses = 0, streak = 0, bestStreak = 0,
        pointsFor = 0, pointsAgainst = 0, bestRally = 0 }
end

-- The stats table, created and filled in with defaults as needed.
function Stats.data()
    local c = ns.cdb
    c.stats = c.stats or {}
    local s = c.stats
    s.human = s.human or blankHuman()
    s.human.bestRally = s.human.bestRally or 0
    s.bots = s.bots or {}
    for _, level in ipairs(Bot.LEVELS) do
        s.bots[level] = s.bots[level] or { wins = 0, losses = 0 }
        s.bots[level].bestRally = s.bots[level].bestRally or 0
    end
    s.opponents = s.opponents or {}   -- pid -> { name, wins, losses, last = server time }
    return s
end

-- Records a finished match from `seat`'s point of view against `opponent` (see Game.opponent).
function Stats.record(m, seat, opponent)
    if not (seat and opponent and m.winner) then return end
    local s = Stats.data()
    local won = m.winner == seat
    if opponent.kind == "bot" then
        local b = s.bots[opponent.level]
        if not b then return end
        if won then b.wins = b.wins + 1 else b.losses = b.losses + 1 end
        b.bestRally = math.max(b.bestRally, m.longest or 0)
        return
    end
    local h = s.human
    if won then
        h.wins = h.wins + 1
        h.streak = h.streak + 1
        h.bestStreak = math.max(h.bestStreak, h.streak)
        if m.forfeit then h.forfeitWins = h.forfeitWins + 1 end
    else
        h.losses = h.losses + 1
        h.streak = 0
        if m.forfeit then h.forfeitLosses = h.forfeitLosses + 1 end
    end
    h.bestRally = math.max(h.bestRally, m.longest or 0)
    h.pointsFor = h.pointsFor + m.score[seat]
    h.pointsAgainst = h.pointsAgainst + m.score[3 - seat]
    if opponent.pid then
        local o = s.opponents[opponent.pid] or { wins = 0, losses = 0 }
        o.name = opponent.name or o.name or "?"
        if won then o.wins = o.wins + 1 else o.losses = o.losses + 1 end
        o.last = GetServerTime and GetServerTime() or time()
        s.opponents[opponent.pid] = o
    end
    ns.log(string.format("stats: %s vs %s, record now %d-%d", won and "won" or "lost", ns.show(opponent.name),
        h.wins, h.losses))
end

Game.onOver = function(m)
    Stats.record(m, Game.humanSeat, Game.opponent)
end

-- Short record for tooltips: "12-5 vs players".
function Stats.summary()
    local h = Stats.data().human
    return string.format("%d-%d vs players", h.wins, h.losses)
end

-- Display lines for the stats panel and /pong stats.
function Stats.lines()
    local s = Stats.data()
    local h = s.human
    local lines = {}
    local forfeits = ""
    if h.forfeitWins + h.forfeitLosses > 0 then
        forfeits = string.format("  (forfeits: %d won, %d lost)", h.forfeitWins, h.forfeitLosses)
    end
    lines[#lines + 1] = string.format("Vs players: %d wins, %d losses%s", h.wins, h.losses, forfeits)
    lines[#lines + 1] = string.format("Streak %d (best %d)    Points %d - %d", h.streak, h.bestStreak,
        h.pointsFor, h.pointsAgainst)
    local bots = {}
    for _, level in ipairs(Bot.LEVELS) do
        local b = s.bots[level]
        bots[#bots + 1] = string.format("%s %d-%d", Bot.NAMES[level], b.wins, b.losses)
    end
    lines[#lines + 1] = "Vs bots: " .. table.concat(bots, "    ")
    local rallies = {}
    for _, level in ipairs(Bot.LEVELS) do
        rallies[#rallies + 1] = string.format("%s %d", Bot.NAMES[level], s.bots[level].bestRally)
    end
    lines[#lines + 1] = string.format("Longest rally: %d vs players    vs bots: %s", h.bestRally,
        table.concat(rallies, "  "))

    local opponents = {}
    for _, o in pairs(s.opponents) do opponents[#opponents + 1] = o end
    table.sort(opponents, function(a, b)
        local ga, gb = a.wins + a.losses, b.wins + b.losses
        if ga ~= gb then return ga > gb end
        return (a.last or 0) > (b.last or 0)
    end)
    if #opponents > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "Head-to-head:"
        for i = 1, math.min(HEAD_TO_HEAD_SHOWN, #opponents) do
            local o = opponents[i]
            lines[#lines + 1] = string.format("    %s  %d-%d", o.name, o.wins, o.losses)
        end
    end
    return lines
end

ns.commands.stats = function()
    for _, line in ipairs(Stats.lines()) do
        if line ~= "" then ns.print(line) end
    end
end
table.insert(ns.help, "/pong stats - your win/loss record")
