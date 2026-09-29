"""Smooth network lag (display only): a ball reaching a paddle someone else judges bounces at once along our
predicted path, the real verdict glides in over a few frames instead of jumping, a predicted miss still waits at
the paddle face, turning the option off brings back the old hold-and-jump, and the match itself never changes.

    pip install lupa
    python tools/test_smoothing.py
"""
import sys

from test_net import pilot, match_of, over, score, show, errors, setup

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

# Units in one 30fps frame that count as a jump: the fastest ball (650/s) moves ~22, and the catch-up after a late
# verdict runs it up to ~2.5x along its path (seen: <= 53); late verdicts with smoothing off jump 69-190.
BIG = 65


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def ball_xy(ui):
    p = ui.ball.points[1]
    return p[4], p[5]


def play(smooth, seconds=40):
    """A normal-vs-normal match at 200-300ms, watching the guest's window. Returns the big frame-to-frame jumps
    of the drawn ball in play, how often the guest drew a bounce before the real HIT arrived, and the clients."""
    net, (a, b) = setup(latency=0.2, jitter=0.1, n=2)
    for c in (a, b):
        c.ns.Options.set("smoothLag", smooth)
    ui = show(b)
    a.slash("host")
    net.run(1)
    b.slash("join Alice")
    net.run(4)
    a.slash("start")
    pilot(a, "normal")
    pilot(b, "normal")
    jumps, early, held = 0, 0, 0
    prev = None
    for _ in range(seconds * 30):
        net.run(1 / 30)
        m = match_of(b)
        if m is None:
            continue
        cur = None
        if ui.ball.shownFlag and m.phase in ("play", "point", "over") and not (m.phase == "play" and m.hits == 0):
            cur = ball_xy(ui)
        if cur and prev:
            d = ((cur[0] - prev[0]) ** 2 + (cur[1] - prev[1]) ** 2) ** 0.5
            if d > BIG:
                jumps += 1
        prev = cur
        if m.phase == "play":
            seat, t_a = b.ns.Sim.arrival(m)
            now = b.ns.Game.clock()
            if seat == 1 and now > t_a + 0.05:   # Alice's verdict still pending on Bob's screen
                x = ball_xy(ui)[0]
                if x > b.ns.Sim.PLANE[1] + 1:
                    early += 1
                elif abs(x - b.ns.Sim.PLANE[1]) < 0.01:
                    held += 1
        if over(a) and over(b):
            break
    net.until(lambda: over(a) and over(b), 600)
    return jumps, early, held, a, b


def test_smoothing():
    on_jumps, on_early, on_held, a, b = play(True)
    check(over(a) and over(b) and score(a) == score(b), "on: match completes, both agree %s" % (score(a),))
    check(on_early > 0, "on: the guest draws the bounce before the host's HIT arrives (%d frames)" % on_early)
    check(not errors((a, b)), "on: no errors")

    off_jumps, off_early, off_held, a, b = play(False)
    check(over(a) and over(b) and score(a) == score(b), "off: match completes, both agree %s" % (score(a),))
    check(off_early == 0 and off_held > 0, "off: the ball waits at the host's paddle face (%d frames)" % off_held)
    check(off_jumps > 0, "off: late verdicts make the ball jump (%d big jumps)" % off_jumps)
    check(on_jumps <= off_jumps / 4, "on: far fewer big jumps (%d vs %d)" % (on_jumps, off_jumps))
    check(not errors((a, b)), "off: no errors")


def test_predicted_miss_waits():
    net, (a, b) = setup(latency=0.3, n=2)
    ui = show(b)
    a.slash("host")
    net.run(1)
    b.slash("join Alice")
    net.run(4)
    a.slash("start")
    pilot(b, "hard")
    # Alice never moves, so any ball not heading for her paddle's middle is a miss she judges late.
    ns = b.ns
    seen = False
    for _ in range(60 * 30):
        net.run(1 / 30)
        m = match_of(b)
        if m is None or m.phase != "play":
            continue
        seat, t_a = ns.Sim.arrival(m)
        if seat == 1 and ns.Game.clock() > t_a + 0.05 and ns.Sim.judge(m, 1).type == "MISS":
            seen = True
            check(abs(ball_xy(ui)[0] - ns.Sim.PLANE[1]) < 0.01, "a predicted miss waits at the paddle face")
            break
    check(seen, "saw a pending miss")
    check(not errors((a, b)), "no errors")


if __name__ == "__main__":
    test_smoothing()
    test_predicted_miss_waits()
    print("\n%s" % ("all passed" if failures == 0 else "%d FAILED" % failures))
    sys.exit(1 if failures else 0)
