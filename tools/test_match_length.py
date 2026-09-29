"""Match length (first to 1/3/5/7) and the rally counter: START carries the target, the header button and
/pong points, the host's choice reaching guests, spectators and the lobby, late spectators' snapshots, the live
rally text, and the longest rally in stats.

    pip install lupa
    python tools/test_match_length.py
"""
import sys

from fakewow import Client
from test_net import Network, pilot, match_of, over, score, show, rows, errors, setup, info_of

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def click(button, which="LeftButton"):
    button.scripts.OnClick(button, which)


def enabled(button):
    return not button.disabled


def test_sim_and_codec():
    c = Client()
    ns, lua = c.ns, c.lua
    ev = ns.Codec.normalize(lua.table_from({"type": "START", "t": 1.5, "win": 3}))
    check(ev.win == 3 and ns.Codec.encodeEvent(ev) == "A,1.5,3", "START carries the target")
    m = ns.Sim.newMatch()
    ns.Sim.apply(m, ev)
    check(m.pointsToWin == 3, "and the match uses it")
    for bad in (0, 22, 2.5):
        m2 = ns.Sim.newMatch()
        ns.Sim.apply(m2, lua.table_from({"type": "START", "t": 0, "win": bad}))
        check(m2.pointsToWin == 7, "a START with win=%s keeps the default" % bad)

    # Longest rally: hits count up, reset on serve, the best is kept.
    ns.Sim.apply(m, lua.table_from({"type": "SERVE", "t": 4.5, "dir": -1, "angle": 0}))
    for i in range(3):
        seat, t = ns.Sim.arrival(m)
        ns.Sim.apply(m, lua.table_from({"type": "HIT", "t": t, "seat": seat, "x": ns.Sim.PLANE[seat], "y": 150,
                                        "vx": 240 if seat == 1 else -240, "vy": 0, "speed": 240}))
    check(m.hits == 3 and m.longest == 3, "rally of 3")
    seat, t = ns.Sim.arrival(m)
    ns.Sim.apply(m, lua.table_from({"type": "MISS", "t": t, "seat": seat}))
    ns.Sim.apply(m, lua.table_from({"type": "SERVE", "t": t + 1.5, "dir": 1, "angle": 0}))
    seat, t = ns.Sim.arrival(m)
    ns.Sim.apply(m, lua.table_from({"type": "HIT", "t": t, "seat": seat, "x": ns.Sim.PLANE[seat], "y": 150,
                                    "vx": -240, "vy": 0, "speed": 240}))
    check(m.hits == 1 and m.longest == 3, "next rally starts over, the longest stays")

    s = ns.Codec.encodeSnapshot(m)
    r = ns.Sim.newMatch()
    ns.Sim.restore(r, ns.Codec.decodeSnapshot(s))
    check(r.pointsToWin == 3 and r.longest == 3 and r.hits == 1, "snapshots carry target and longest rally")
    check(len(s) < 190, "snapshot still small (%d bytes)" % len(s))
    check(not c.errors(), "no errors")


def test_local():
    c = Client(name="Bear")
    ui = show(c)
    btn = ui.pointsBtn
    check(btn.text == "First to 7" and enabled(btn), "lobby: header shows First to 7, changeable")
    click(btn)
    c.run(0.1)
    check(c.ns.opt("points") == 1 and btn.text == "First to 1", "click cycles 7 -> 1")
    click(btn)
    click(btn)
    check(c.ns.opt("points") == 5, "then 3, 5")
    click(btn, "RightButton")
    check(c.ns.opt("points") == 3, "right-click goes back")
    c.slash("points 9")
    check(c.ns.opt("points") == 3, "/pong points rejects 9")
    c.slash("points 1")
    check(c.ns.opt("points") == 1, "/pong points 1")

    c.slash("practice hard")
    c.run(0.7)
    m = match_of(c)
    check(m.pointsToWin == 1 and ui.pointsBtn.text == "First to 1", "practice plays to 1")
    check(not enabled(ui.pointsBtn), "can't change it mid-match")
    check("First to 1" in ui.hint.text, "hint says first to 1")
    # Park the paddle mid-board; watch the rally counter while the bot returns the ball.
    seen = False
    for _ in range(6000):
        c.run(1 / 60)
        if m.hits > 0 and m.phase == "play":
            seen = seen or ui.rally.text == "Rally %d" % m.hits
        if m.phase == "over":
            break
    check(seen, "live rally counter shows the hits")
    check(m.phase == "over" and max(m.score[1], m.score[2]) == 1, "match ends at 1")
    c.run(0.1)
    check(ui.rally.text == ("Longest rally: %d" % m.longest if m.longest > 0 else ""),
          "after the match: longest rally (%r)" % ui.rally.text)
    check(enabled(ui.pointsBtn), "changeable again after a local match")
    b = c.ns.Stats.data().bots.hard
    check(b.bestRally == m.longest, "bot record keeps the longest rally (%d)" % b.bestRally)
    check(any("Longest rally" in l for l in c.ns.Stats.lines().values()), "stats panel shows it")
    check(not c.errors(), "no errors")


def test_networked():
    net, (a, b, c, d) = setup(n=4, latency=0.15, jitter=0.05)
    a.slash("points 3")
    a.slash("host")
    net.run(1)
    c.slash("tables")
    net.run(2)
    uc = show(c)
    r = rows(uc)
    check(r and "first to 3" in r[0].detail.text, "lobby row says first to 3 (%r)" % (r and r[0].detail.text))
    b.slash("join alice")
    net.run(4)
    ua, ub = show(a), show(b)
    check(ua.pointsBtn.text == "First to 3" and enabled(ua.pointsBtn), "host can change it at the table")
    check(ub.pointsBtn.text == "First to 3" and not enabled(ub.pointsBtn), "guest sees it, can't change it")
    click(ub.pointsBtn)
    check(b.ns.opt("points") == 7, "guest's click does nothing")

    # Host switches to 5 before starting: guest and the lobby hear it.
    click(ua.pointsBtn)
    net.run(2)
    check(ub.pointsBtn.text == "First to 5", "guest sees the host's change")
    check(info_of(c, a).points == 5, "lobby list too")

    a.slash("start")
    pilot(a, "hard")
    pilot(b, "normal")
    net.run(1)
    check(not enabled(ua.pointsBtn), "host can't change it mid-match")
    click(ua.pointsBtn)
    check(a.ns.opt("points") == 5, "click ignored mid-match")
    net.until(lambda: sum(score(a)[:2]) >= 1, 300)
    net.run(1)
    d.slash("watch alice")
    net.run(8)
    check(match_of(d) is not None and match_of(d).pointsToWin == 5, "late spectator gets the target from the snapshot")
    net.until(lambda: over(a) and over(b) and over(d), 900)
    check(max(score(a)[:2]) == 5 and score(a) == score(b) == score(d), "match ends at 5 for all %s" % (score(a),))
    ma, mb, md = match_of(a), match_of(b), match_of(d)
    check(ma.longest == mb.longest and ma.longest > 0, "everyone agrees on the longest rally (%d)" % ma.longest)
    sa, sb = a.ns.Stats.data().human, b.ns.Stats.data().human
    check(sa.bestRally == ma.longest and sb.bestRally == ma.longest, "both players' stats keep it")
    check(d.ns.Stats.data().human.bestRally == 0, "spectators' stats don't")
    net.run(0.2)
    check(ub.rally.text == "Longest rally: %d" % ma.longest, "guest sees the longest rally after the match")

    # Rematch at 1.
    a.slash("points 1")
    net.run(2)
    a.slash("start")
    net.until(lambda: over(a) and over(b), 300)
    check(max(score(b)[:2]) == 1 and match_of(b).pointsToWin == 1, "rematch plays to 1")
    check(not errors((a, b, c, d)), "no errors: %s" % errors((a, b, c, d))[:3])


if __name__ == "__main__":
    test_sim_and_codec()
    test_local()
    test_networked()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all match length tests passed")
