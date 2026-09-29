"""Unit tests for WoWPong/Sim.lua and Bot.lua (pure logic, no WoW API), run in real Lua via lupa: geometry,
paddle motion, hit/miss judging, scoring, event replay (what spectators will rely on), and full bot-vs-bot
matches at every difficulty, with a balance report.

    pip install lupa
    python tools/test_sim.py
"""
import math
import os
import sys

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.join(HERE, "..", "WoWPong")

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


# Runs whole matches inside Lua (fast): bots on both seats, one client owning everything, fixed frame rate.
HARNESS = r"""
local Sim, Bot = ns.Sim, ns.Bot
function playMatch(l1, l2, fps, seed, maxTime)
    math.randomseed(seed)
    local m = Sim.newMatch()
    local bots = { Bot.new(1, l1, math.random), Bot.new(2, l2, math.random) }
    local auth = { seats = { true, true }, host = true, rand = math.random }
    local now, dt = 0, 1 / fps
    Sim.apply(m, { type = "START", t = 0 })
    local maxY, minY = -1e9, 1e9
    while m.phase ~= "over" and now < (maxTime or 3600) do
        now = now + dt
        Sim.step(m, now, auth)
        for _, b in ipairs(bots) do
            local ev = b:update(m, now)
            if ev then Sim.apply(m, ev) end
        end
        local _, y = Sim.ballPos(m, now)
        maxY, minY = math.max(maxY, y), math.min(minY, y)
    end
    local hits, misses = 0, 0
    for _, ev in ipairs(m.events) do
        if ev.type == "HIT" then hits = hits + 1 elseif ev.type == "MISS" then misses = misses + 1 end
    end
    return m, hits, misses, now, minY, maxY
end

-- Applies m's events, in order, to a fresh match (what a spectator would do).
function replay(m)
    local r = Sim.newMatch()
    for _, ev in ipairs(m.events) do Sim.apply(r, ev) end
    return r
end
"""


def load():
    lua = LuaRuntime(unpack_returned_tuples=True)
    ns = lua.table()
    lua.globals().ns = ns
    loader = lua.eval("function(src, name) return load(src, name) end")
    for f in ("Sim.lua", "Bot.lua"):
        with open(os.path.join(ADDON, f), encoding="utf-8") as fh:
            chunk = loader(fh.read(), "@" + f)
        chunk("WoWPong", ns)
    lua.execute(HARNESS)
    return lua, ns


def close(a, b, eps=1e-6):
    return abs(a - b) < eps


def ev(lua, **kw):
    return lua.table_from(kw)


def test_geometry(lua, ns):
    Sim = ns.Sim
    lo, hi = Sim.BALL_R, Sim.H - Sim.BALL_R
    check(close(Sim.fold(100, lo, hi), 100), "fold leaves in-range values alone")
    check(close(Sim.fold(hi + 10, lo, hi), hi - 10), "fold bounces off the top wall")
    check(close(Sim.fold(lo - 10, lo, hi), lo + 10), "fold bounces off the bottom wall")
    span = hi - lo
    check(close(Sim.fold(lo + 2 * span + 7, lo, hi), lo + 7), "fold handles two bounces")
    check(Sim.clampPaddle(-50) == Sim.PADDLE_H / 2, "paddle target clamped at the bottom")
    check(Sim.clampPaddle(9999) == Sim.H - Sim.PADDLE_H / 2, "paddle target clamped at the top")


def test_paddle(lua, ns):
    Sim = ns.Sim
    m = Sim.newMatch()
    Sim.apply(m, ev(lua, type="START", t=0))
    Sim.apply(m, ev(lua, type="MOVE", t=1, seat=1, y=250))
    speed = Sim.PADDLE_SPEED
    check(close(Sim.paddleY(m, 1, 1), 150), "paddle starts where it was")
    check(close(Sim.paddleY(m, 1, 1.1), 150 + speed * 0.1), "paddle glides at fixed speed")
    check(close(Sim.paddleY(m, 1, 5), 250), "paddle stops at the target")
    check(close(Sim.paddleY(m, 2, 5), 150), "other paddle untouched")
    Sim.apply(m, ev(lua, type="MOVE", t=1.2, seat=1, y=100))   # redirect mid-move
    mid = 150 + speed * 0.2
    check(close(Sim.paddleY(m, 1, 1.2), mid), "re-click keeps the current position")
    check(close(Sim.paddleY(m, 1, 1.3), mid - speed * 0.1), "re-click redirects the paddle")


def serve_straight_at_seat1(lua, ns, paddle_y=None):
    Sim = ns.Sim
    m = Sim.newMatch()
    Sim.apply(m, ev(lua, type="START", t=0))
    if paddle_y is not None:
        Sim.apply(m, ev(lua, type="MOVE", t=0, seat=1, y=paddle_y))
    Sim.apply(m, ev(lua, type="SERVE", t=3, dir=-1, angle=0))
    return m


def test_judge(lua, ns):
    Sim = ns.Sim
    m = serve_straight_at_seat1(lua, ns)
    seat, t = Sim.arrival(m)
    check(seat == 1, "ball served left heads for seat 1")
    check(close(t, 3 + (240 - Sim.PLANE[1]) / Sim.BALL_SPEED), "arrival time at seat 1's paddle face")
    hit = Sim.judge(m, 1)
    check(hit.type == "HIT", "centred paddle hits")
    check(hit.vx > 0 and close(hit.vy, 0), "centre hit returns straight")
    check(close(hit.speed, Sim.BALL_SPEED * Sim.BALL_SPEEDUP), "hit speeds the ball up")
    Sim.apply(m, hit)
    seat2, _ = Sim.arrival(m)
    check(seat2 == 2 and m.hits == 1, "after the hit the ball heads for seat 2")

    # Edge hit: ball meets the paddle at its very top -> steepest angle upward.
    m = serve_straight_at_seat1(lua, ns, paddle_y=150 - Sim.REACH + 0.001)
    hit = Sim.judge(m, 1)
    angle = math.atan2(hit.vy, hit.vx)
    check(hit.type == "HIT" and close(angle, Sim.MAX_BOUNCE, 1e-3), "edge hit leaves at the max angle")

    m = serve_straight_at_seat1(lua, ns, paddle_y=250)
    miss = Sim.judge(m, 1)
    check(miss.type == "MISS", "paddle out of reach misses")
    Sim.apply(m, miss)
    check(m.score[2] == 1 and m.score[1] == 0, "miss scores for the other seat")
    check(m.phase == "point" and m.serveDir == -1, "next serve goes toward the player who missed")
    check(close(m.serveAt, miss.t + Sim.POINT_DELAY), "next serve after the point delay")

    # Speed cap.
    m = serve_straight_at_seat1(lua, ns)
    m.ball.speed = Sim.BALL_SPEED_MAX
    check(close(Sim.judge(m, 1).speed, Sim.BALL_SPEED_MAX), "ball speed capped")


def test_step_authority(lua, ns):
    Sim = ns.Sim
    rand = lua.eval("function() return 0.25 end")
    m = Sim.newMatch()
    Sim.apply(m, ev(lua, type="START", t=0))
    guest = lua.table_from({"seats": lua.table_from({1: False, 2: True}), "host": False, "rand": rand})
    host = lua.table_from({"seats": lua.table_from({1: True, 2: False}), "host": True, "rand": rand})
    check(len(Sim.step(m, 10, guest)) == 0, "non-host never serves")
    out = Sim.step(m, 2.9, host)
    check(len(out) == 0, "host waits for the countdown")
    out = Sim.step(m, 3.0, host)
    check(len(out) == 1 and out[1].type == "SERVE" and out[1].t == 3, "host serves at the end of the countdown")
    check(out[1].dir == -1, "first serve direction comes from rand")
    seat, t = Sim.arrival(m)
    check(len(Sim.step(m, t + 1, guest)) == 0, "only the owner of seat %d judges" % seat)
    out = Sim.step(m, t + 0.001, host)
    check(len(out) == 1 and out[1].t == t, "owner judges at the exact arrival time, not the frame time")
    m2 = Sim.newMatch()
    Sim.apply(m2, ev(lua, type="FORFEIT", t=1, seat=2))
    check(m2.phase == "over" and m2.winner == 1 and m2.forfeit, "forfeit ends the match")
    check(not Sim.apply(m2, ev(lua, type="SERVE", t=2, dir=1, angle=0)), "no play after the match is over")
    check(Sim.apply(m2, ev(lua, type="MOVE", t=2, seat=1, y=10)) and m2.phase == "over",
          "a late-arriving move still lands after the match (paddles stay in sync)")


def test_replay(lua, ns):
    Sim = ns.Sim
    m, hits, misses, _, _, _ = lua.globals().playMatch("hard", "normal", 60, 42)
    r = lua.globals().replay(m)
    same = (r.phase == m.phase and r.winner == m.winner and r.score[1] == m.score[1] and r.score[2] == m.score[2])
    for t in (0, 5.5, 30.25, 123.4):
        for seat in (1, 2):
            same = same and close(Sim.paddleY(r, seat, t), Sim.paddleY(m, seat, t))
        bx, by = Sim.ballPos(m, t)
        rx, ry = Sim.ballPos(r, t)
        same = same and close(bx, rx) and close(by, ry)
    check(same, "replaying the event list reproduces the match exactly (spectators)")
    check(misses == m.score[1] + m.score[2], "every miss is a point")


def test_matches(lua, ns):
    play = lua.globals().playMatch
    levels = ["hard", "normal", "easy"]
    n = 20
    print("\nbot balance, %d matches each at 30 fps (left level vs right level):" % n)
    report = {}
    all_ok = True
    for i, a in enumerate(levels):
        for b in levels[i:]:
            wins_a, hits_total, points, secs = 0, 0, 0, 0
            for seed in range(n):
                m, hits, misses, now, lo, hi = play(a, b, 30, 1000 + seed, 1200)
                ok = (m.phase == "over" and max(m.score[1], m.score[2]) == 7 and
                      lo >= ns.Sim.BALL_R - 1e-6 and hi <= ns.Sim.H - ns.Sim.BALL_R + 1e-6)
                all_ok = all_ok and ok
                wins_a += 1 if m.winner == 1 else 0
                hits_total += hits
                points += misses
                secs += now
            report[(a, b)] = wins_a / n
            print("  %-6s vs %-6s  left wins %3d%%   hits/point %4.1f   avg match %3.0fs"
                  % (a, b, 100 * wins_a / n, hits_total / max(points, 1), secs / n))
    print()
    check(all_ok, "every match ends 7-x with the ball inside the walls")
    check(report[("hard", "easy")] >= 0.8, "hard beats easy most of the time")
    check(report[("normal", "easy")] >= 0.6, "normal beats easy more often than not")
    check(report[("hard", "normal")] >= 0.6, "hard beats normal more often than not")
    m30 = play("normal", "normal", 30, 7)[0]
    m144 = play("normal", "normal", 144, 7)[0]
    check(m30.phase == "over" and m144.phase == "over", "matches finish at 30 and 144 fps")


if __name__ == "__main__":
    lua, ns = load()
    test_geometry(lua, ns)
    test_paddle(lua, ns)
    test_judge(lua, ns)
    test_step_authority(lua, ns)
    test_replay(lua, ns)
    test_matches(lua, ns)
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all sim tests passed")
