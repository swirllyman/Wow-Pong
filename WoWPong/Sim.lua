-- The Pong simulation: pure logic, no WoW API, so every client (both players and all spectators) can run the
-- same match from the same event list. A match only changes through Sim.apply(match, event); between events,
-- ball and paddle positions are functions of time, so frame rate never affects the outcome.
--
-- Events (all carry t, an absolute match time in seconds):
--   START   win                            countdown, then the host serves; win = points to win (1-21)
--   SERVE   dir (1 = toward seat 2), angle ball leaves the centre
--   MOVE    seat, y                        a player (or bot) clicked: paddle glides toward y
--   HIT     seat, x, y, vx, vy, speed      the seat's owner judged a hit; carries the new ball path
--   MISS    seat                           the seat's owner judged a miss; the other seat scores
--   FORFEIT seat                           that seat gives up; the other seat wins
--
-- Coordinates are board units, origin bottom-left, y up. Ball and paddle positions are their centres.

local _, ns = ...

local Sim = {}
ns.Sim = Sim

Sim.W, Sim.H = 480, 300
Sim.PADDLE_W, Sim.PADDLE_H = 8, 60
Sim.PADDLE_INSET = 16            -- gap between the board edge and the back of a paddle
Sim.BALL_R = 5                   -- half the ball's size (it's drawn as a square)
-- Speeds were tuned with bot-vs-bot runs (tools/test_sim.py prints a balance report); retune after playtests.
Sim.PADDLE_SPEED = 270           -- units/s toward the clicked target
Sim.BALL_SPEED = 240             -- serve speed, units/s
Sim.BALL_SPEEDUP = 1.12          -- speed multiplier per paddle hit
Sim.BALL_SPEED_MAX = 650
Sim.MAX_BOUNCE = math.rad(60)    -- exit angle for a hit on the very edge of a paddle
Sim.SERVE_ANGLE = math.rad(30)   -- serves leave at a random angle within +-this
Sim.POINTS_TO_WIN = 7            -- default; START carries the match's own target
Sim.MAX_POINTS = 21
Sim.COUNTDOWN = 3                -- seconds from START to the first serve
Sim.POINT_DELAY = 1.5            -- seconds from a miss to the next serve

-- Paddle centre x per seat, and the ball-centre x at which the ball meets each paddle's face.
Sim.PADDLE_X = { Sim.PADDLE_INSET + Sim.PADDLE_W / 2, Sim.W - Sim.PADDLE_INSET - Sim.PADDLE_W / 2 }
Sim.PLANE = { Sim.PADDLE_INSET + Sim.PADDLE_W + Sim.BALL_R, Sim.W - Sim.PADDLE_INSET - Sim.PADDLE_W - Sim.BALL_R }
-- Largest |ballY - paddleY| that still counts as a hit.
Sim.REACH = Sim.PADDLE_H / 2 + Sim.BALL_R

---------------------------------------------------------------------------
-- Geometry
---------------------------------------------------------------------------

-- Folds v into [lo, hi] as if it bounced off both ends (the ball's y between the top and bottom walls).
function Sim.fold(v, lo, hi)
    local span = hi - lo
    local m = (v - lo) % (2 * span)
    if m > span then m = 2 * span - m end
    return lo + m
end

function Sim.clampPaddle(y)
    local half = Sim.PADDLE_H / 2
    return math.max(half, math.min(Sim.H - half, y))
end

---------------------------------------------------------------------------
-- Match state
---------------------------------------------------------------------------

function Sim.newMatch(opts)
    opts = opts or {}
    local mid = Sim.H / 2
    return {
        phase = "idle",   -- idle, countdown, play, point (ball flying out after a miss), over
        pointsToWin = opts.pointsToWin or Sim.POINTS_TO_WIN,
        score = { 0, 0 },
        paddles = { { y = mid, target = mid, t = 0 }, { y = mid, target = mid, t = 0 } },
        ball = { x = Sim.W / 2, y = mid, vx = 0, vy = 0, speed = 0, t = 0 },
        hits = 0,          -- paddle hits in the current rally
        longest = 0,       -- longest rally (hits) this match
        serveAt = nil,     -- when the host serves next (countdown and point phases)
        serveDir = nil,    -- direction of the next serve; nil = random
        winner = nil,
        forfeit = false,
        trajectory = 0,    -- bumps whenever the ball's situation changes (start, serve, hit, miss); bots watch it
        events = {},       -- every applied event, in order
    }
end

-- Paddle centre y for seat at time t: it glides from its last position toward the clicked target.
function Sim.paddleY(m, seat, t)
    local p = m.paddles[seat]
    local d = p.target - p.y
    local travel = Sim.PADDLE_SPEED * math.max(0, t - p.t)
    if travel >= math.abs(d) then return p.target end
    return d > 0 and p.y + travel or p.y - travel
end

-- Ball centre at time t on path b ({ x, y, vx, vy, t }, e.g. m.ball or a HIT event), bouncing off the walls.
function Sim.pathPos(b, t)
    local dt = math.max(0, t - b.t)
    return b.x + b.vx * dt, Sim.fold(b.y + b.vy * dt, Sim.BALL_R, Sim.H - Sim.BALL_R)
end

-- Ball centre at time t on its current path.
function Sim.ballPos(m, t)
    return Sim.pathPos(m.ball, t)
end

-- The seat the ball is heading for and when it reaches that paddle's face, or nil when the ball isn't in play.
function Sim.arrival(m)
    if m.phase ~= "play" then return nil end
    local b = m.ball
    local seat = b.vx < 0 and 1 or 2
    return seat, b.t + (Sim.PLANE[seat] - b.x) / b.vx
end

-- The HIT or MISS event for the ball reaching seat's paddle. Only the seat's owner calls this; everyone else
-- applies the event it sends. Where the ball meets the paddle sets the exit angle, and each hit speeds it up.
function Sim.judge(m, seat)
    local _, t = Sim.arrival(m)
    local _, by = Sim.ballPos(m, t)
    local off = (by - Sim.paddleY(m, seat, t)) / Sim.REACH
    if math.abs(off) > 1 then return { type = "MISS", t = t, seat = seat } end
    local speed = math.min(m.ball.speed * Sim.BALL_SPEEDUP, Sim.BALL_SPEED_MAX)
    local angle = off * Sim.MAX_BOUNCE
    local dir = seat == 1 and 1 or -1
    return { type = "HIT", t = t, seat = seat, x = Sim.PLANE[seat], y = by,
        vx = dir * speed * math.cos(angle), vy = speed * math.sin(angle), speed = speed }
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local apply = {}

function apply.START(m, ev)
    m.phase = "countdown"
    m.score = { 0, 0 }
    m.winner, m.forfeit, m.serveDir = nil, false, nil
    local win = tonumber(ev.win)
    if win and win >= 1 and win <= Sim.MAX_POINTS and win == math.floor(win) then m.pointsToWin = win end
    m.hits, m.longest = 0, 0
    m.serveAt = ev.t + Sim.COUNTDOWN
    m.ball = { x = Sim.W / 2, y = Sim.H / 2, vx = 0, vy = 0, speed = 0, t = ev.t }
    m.trajectory = m.trajectory + 1
end

function apply.SERVE(m, ev)
    local speed = Sim.BALL_SPEED
    m.phase = "play"
    m.hits = 0
    m.serveAt = nil
    m.ball = { x = Sim.W / 2, y = Sim.H / 2, vx = ev.dir * speed * math.cos(ev.angle),
        vy = speed * math.sin(ev.angle), speed = speed, t = ev.t }
    m.trajectory = m.trajectory + 1
end

function apply.MOVE(m, ev)
    local p = m.paddles[ev.seat]
    p.y = Sim.paddleY(m, ev.seat, ev.t)
    p.target = Sim.clampPaddle(ev.y)
    p.t = ev.t
end

function apply.HIT(m, ev)
    m.hits = m.hits + 1
    if m.hits > m.longest then m.longest = m.hits end
    m.ball = { x = ev.x, y = ev.y, vx = ev.vx, vy = ev.vy, speed = ev.speed, t = ev.t }
    m.trajectory = m.trajectory + 1
end

-- The ball keeps flying off the board; the next serve goes toward whoever missed.
function apply.MISS(m, ev)
    local other = 3 - ev.seat
    m.score[other] = m.score[other] + 1
    m.trajectory = m.trajectory + 1
    if m.score[other] >= m.pointsToWin then
        m.phase, m.winner, m.serveAt = "over", other, nil
    else
        m.phase = "point"
        m.serveAt = ev.t + Sim.POINT_DELAY
        m.serveDir = ev.seat == 1 and -1 or 1
    end
end

function apply.FORFEIT(m, ev)
    m.phase, m.winner, m.forfeit, m.serveAt = "over", 3 - ev.seat, true, nil
    m.trajectory = m.trajectory + 1
end

-- Overwrites m with a snapshot (Codec.decodeSnapshot) so a late spectator can carry on from there.
function Sim.restore(m, s)
    m.phase, m.score, m.serveAt, m.serveDir = s.phase, s.score, s.serveAt, s.serveDir
    m.hits, m.winner, m.forfeit = s.hits, s.winner, s.forfeit
    m.pointsToWin, m.longest = s.pointsToWin, s.longest
    m.ball, m.paddles = s.ball, s.paddles
    m.trajectory = m.trajectory + 1
end

-- Applies one event. Returns false for an unknown type or once the match is over (nothing changes then), except
-- MOVE: a move batched just before the final miss can arrive after it, and only touches that player's paddle.
function Sim.apply(m, ev)
    local fn = apply[ev.type]
    if not fn or (m.phase == "over" and ev.type ~= "START" and ev.type ~= "MOVE") then return false end
    fn(m, ev)
    m.events[#m.events + 1] = ev
    return true
end

-- Creates, applies and returns the events this client is responsible for at time `now`:
-- the host serves, and each locally owned seat judges the ball reaching its own paddle.
-- auth = { seats = { [1] = bool, [2] = bool }, host = bool, rand = function() -> [0, 1),
--          normalize = optional function(ev) -> ev, applied before the event (networked matches round it) }
function Sim.step(m, now, auth)
    local out = {}
    for _ = 1, 20 do   -- bounded catch-up after a long frame
        local ev
        if (m.phase == "countdown" or m.phase == "point") and auth.host and now >= m.serveAt then
            local dir = m.serveDir or (auth.rand() < 0.5 and -1 or 1)
            ev = { type = "SERVE", t = m.serveAt, dir = dir, angle = (auth.rand() * 2 - 1) * Sim.SERVE_ANGLE }
        elseif m.phase == "play" then
            local seat, t = Sim.arrival(m)
            if auth.seats[seat] and now >= t then ev = Sim.judge(m, seat) end
        end
        if not ev then break end
        if auth.normalize then ev = auth.normalize(ev) end
        Sim.apply(m, ev)
        out[#out + 1] = ev
    end
    return out
end
