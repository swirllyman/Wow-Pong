-- Bot players. A bot only "clicks": it produces the same MOVE events a human does, so it can later be broadcast
-- and watched like a person. It sees what a player sees (the ball's current path) and plays by the same rules:
-- after a reaction delay it guesses where the ball will arrive, with an error that depends on difficulty.

local _, ns = ...
local Sim = ns.Sim

local Bot = {}
ns.Bot = Bot

Bot.LEVELS = { "easy", "normal", "hard" }
Bot.NAMES = { easy = "Easy", normal = "Normal", hard = "Hard" }

-- reaction: seconds before the first click on a new ball path.
-- error: max guess error in board units (triangular distribution), shrunk to 30% for the correction click.
-- correction: fraction of the remaining flight after which the bot re-guesses (nil = never).
-- aim: how far off-centre (fraction of half a paddle) it tries to meet the ball, to send it at an angle.
-- recenter: drifts back toward the middle while the ball is heading away.
Bot.PROFILES = {
-- Reactions were raised ~0.12s when paddles got 35% faster (200 -> 270), which kept the hits per point the same.
    easy = { reaction = 0.58, error = 45, correction = nil, aim = 0, recenter = false },
    normal = { reaction = 0.42, error = 26, correction = 0.5, aim = 0.3, recenter = true },
    hard = { reaction = 0.28, error = 10, correction = 0.6, aim = 0.7, recenter = true },
}

local methods = {}
local mt = { __index = methods }

-- rand: function returning [0, 1), e.g. math.random.
function Bot.new(seat, level, rand)
    if not Bot.PROFILES[level] then level = "normal" end
    return setmetatable({ seat = seat, level = level, profile = Bot.PROFILES[level], rand = rand,
        seen = -1, plan = {}, aimOff = 0 }, mt)
end

-- Plans clicks for the ball's new situation.
function methods:replan(m, now)
    local p = self.profile
    self.plan = {}
    local seat, tA = Sim.arrival(m)
    if seat == self.seat then
        local first = now + p.reaction
        self.plan[1] = { at = first, err = p.error }
        if p.correction and tA > first then
            self.plan[2] = { at = first + (tA - first) * p.correction, err = p.error * 0.3 }
        end
        self.aimOff = (self.rand() * 2 - 1) * p.aim * Sim.PADDLE_H / 2
    elseif p.recenter and m.phase ~= "over" then
        self.plan[1] = { at = now + p.reaction, center = true }
    end
end

-- Call every frame. Returns a MOVE event when the bot clicks, else nil.
function methods:update(m, now)
    if m.phase == "idle" or m.phase == "over" then return nil end
    if m.trajectory ~= self.seen then
        self.seen = m.trajectory
        self:replan(m, now)
    end
    local step = self.plan[1]
    if not step or now < step.at then return nil end
    table.remove(self.plan, 1)
    local y
    if step.center then
        y = Sim.H / 2 + (self.rand() * 2 - 1) * 20
    else
        local seat, tA = Sim.arrival(m)
        if seat ~= self.seat then return nil end
        local _, by = Sim.ballPos(m, tA)
        y = by - self.aimOff + (self.rand() + self.rand() - 1) * step.err
    end
    return { type = "MOVE", t = now, seat = self.seat, y = Sim.clampPaddle(y) }
end
