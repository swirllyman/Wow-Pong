"""Networked play between several fake clients wired through a simulated lobby channel with latency: event codec,
hosting/joining/watching, clock sync across clients whose clocks differ, full matches that every client agrees
on, the send throttle, forfeits on silence and on leaving, bot tables, table-full, version mismatch, /pong ping.

    pip install lupa
    python tools/test_net.py
"""
import random
import sys

from fakewow import Client

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


# Lua-side autopilot: a Bot that clicks for the local human seat through Game.click, like a player would.
AUTOPILOT = r"""
local ns = NS
local pilot = CreateFrame("Frame")
pilot:SetScript("OnUpdate", function()
    local G = ns.Game
    local m = G.match
    if not PILOT_LEVEL or not m or not G.humanSeat or not G.networked then return end
    if not PILOT or PILOT.seat ~= G.humanSeat or PILOT.match ~= m then
        PILOT = ns.Bot.new(G.humanSeat, PILOT_LEVEL, math.random)
        PILOT.match = m
    end
    local ev = PILOT:update(m, G.clock())
    if ev then G.click(ev.y) end
end)
"""


class Network:
    """Delivers CHANNEL addon messages to every connected client (the sender too, like WoW) after a latency."""

    def __init__(self, clients, latency=0.1, jitter=0.0, seed=1):
        self.clients = list(clients)
        self.latency, self.jitter = latency, jitter
        self.rng = random.Random(seed)
        self.time = 0.0
        self.inflight = []   # (deliver_at, order, text, sender)
        self.order = 0
        self.cut = set()     # clients whose messages vanish (disconnected)
        self.drop = lambda text, sender: False   # per-message loss filter
        self.sent = []       # (sender name, text) of everything put on the channel
        for c in self.clients:
            g = c.lua.globals()
            g.NS = c.ns
            c.lua.execute(AUTOPILOT)

    def run(self, sec, fps=30):
        dt = 1.0 / fps
        for _ in range(int(round(sec * fps))):
            for c in self.clients:
                c.lua.globals().RunFrames(dt, fps)
                for m in c.take_outbox():
                    if m["dist"] != "CHANNEL" or c in self.cut or self.drop(m["text"], c):
                        continue
                    self.sent.append((c.name, m["text"]))
                    delay = self.latency + self.rng.random() * self.jitter
                    # Messages from one sender stay in order, like a real chat channel.
                    last = max([d for d, _, _, s in self.inflight if s is c], default=0)
                    self.order += 1
                    self.inflight.append((max(self.time + delay, last), self.order, m["text"], c))
            self.time += dt
            due = sorted([x for x in self.inflight if x[0] <= self.time], key=lambda x: (x[0], x[1]))
            self.inflight = [x for x in self.inflight if x[0] > self.time]
            for _, _, text, sender in due:
                for c in self.clients:
                    if c not in self.cut:
                        c.fire("CHAT_MSG_ADDON", "WoWPong", text, "CHANNEL", sender.name, "", 0, 5)

    def until(self, cond, limit, fps=30):
        waited = 0.0
        while waited < limit and not cond():
            self.run(0.5, fps)
            waited += 0.5
        return cond()


def pilot(client, level):
    client.lua.globals().PILOT_LEVEL = level


def match_of(c):
    return c.ns.Game.match


def over(c):
    m = match_of(c)
    return m is not None and m.phase == "over"


def score(c):
    m = match_of(c)
    return (m.score[1], m.score[2], m.winner, bool(m.forfeit)) if m is not None else None


def setup(latency=0.1, jitter=0.0, n=3):
    names = ["Alice", "Bob", "Cara", "Dan"][:n]
    clients = [Client(name=nm, guid="Player-1-000%d" % (i + 1), start_time=1000 + 3777.123 * i)
               for i, nm in enumerate(names)]
    net = Network(clients, latency, jitter)
    net.run(6)   # everyone joins the channel 5s after login
    return net, clients


def errors(clients):
    return [e for c in clients for e in c.errors()]


def throttled(c):
    return c.lua.globals().throttle.dropped


def test_codec():
    c = Client()
    Codec = c.ns.Codec
    lua = c.lua
    ev = lua.table_from({"type": "HIT", "t": 12.3456789, "seat": 2, "x": 459.0, "y": 150.123456,
                         "vx": -412.5, "vy": 0.0, "speed": 412.5})
    s = Codec.encodeEvent(ev)
    check(s == "H,12.346,2,459,150.12,-412.5,0,412.5", "HIT encodes compactly: " + s)
    back = Codec.decodeEvent(s)
    check(back.type == "HIT" and back.seat == 2 and abs(back.y - 150.12) < 1e-9, "HIT decodes")
    n = Codec.normalize(back)
    check(Codec.encodeEvent(n) == s, "normalize is stable")
    check(Codec.encodeEvent(lua.table_from({"type": "SERVE", "t": 3, "dir": -1, "angle": -0.00001}))
          == "S,3,-1,0", "negative zero and integers trimmed")
    check(Codec.decodeEvent("Q,1,2") is None and Codec.decodeEvent("M,1,2") is None, "bad events rejected")
    parts = [Codec.encodeEvent(lua.table_from({"type": "MOVE", "t": 100 + i * 0.123, "seat": 1, "y": 123.45}))
             for i in range(30)]
    bodies = list(Codec.pack(lua.table_from(parts), 215).values())
    check(len(bodies) > 1 and all(len(b) <= 215 for b in bodies), "pack splits into messages that fit")
    check(sum(b.count("|") + 1 for b in bodies) == 30, "pack keeps every event")
    split = list(Codec.split("a;;b;").values())
    check(split == ["a", "", "b", ""], "split keeps empty fields")


def test_join_sync_and_match():
    net, (a, b, c) = setup(latency=0.12, jitter=0.03)
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(4)
    T = b.ns.Table
    check(T.cur is not None and T.cur.role == "guest" and T.mySeat() == 2, "Bob sits in seat 2 at Alice's table")
    check(a.ns.Table.cur.seats[2].name == "Bob", "host sees Bob in seat 2")
    check(T.cur.synced and a.ns.Table.cur.guestReady, "guest synced its clock and told the host")
    # Clocks differ by ~3777s between the clients; the guest's estimate of match time should be ~exact.
    ta = a.lua.eval("GetTime()") - a.ns.Table.cur.base
    tb = b.lua.eval("GetTime()") - T.cur.base
    check(abs(ta - tb) < 0.05, "guest's match clock matches the host's (off by %.3fs)" % abs(ta - tb))
    check(a.ns.Table.canStart() and T.canStart(), "Play Now enabled for both players")
    a.frame("WoWPongFrame").Show(a.frame("WoWPongFrame"))
    a.run(0.05)
    check(a.ns._ui.playBtn.IsEnabled(a.ns._ui.playBtn), "Play Now button enabled in the window")

    c.slash("watch alice")
    net.run(1)
    check(c.ns.Table.cur.role == "spectator", "Cara watches")
    check(not c.ns.Table.canStart(), "spectators can't start")

    b.slash("start")   # guest presses Play Now
    net.run(1)
    check(all(match_of(x) is not None for x in (a, b, c)), "guest's Play Now starts the match everywhere")
    check(b.ns.Game.humanSeat == 2 and a.ns.Game.humanSeat == 1 and c.ns.Game.humanSeat is None,
          "each client controls the right seat")
    pilot(a, "hard")
    pilot(b, "normal")
    net.until(lambda: over(a) and over(b) and over(c), 600)
    check(over(a) and over(b) and over(c), "match finished on all three clients")
    check(score(a) == score(b) == score(c), "all clients agree on the result: %s / %s / %s"
          % (score(a), score(b), score(c)))
    check(max(score(a)[:2]) == 7 and not score(a)[3], "played to 7, no forfeit")
    ma = match_of(a)
    hits = sum(1 for e in ma.events.values() if e.type == "HIT")
    check(hits > 10, "real rallies happened (%d hits)" % hits)
    check(all(throttled(x) == 0 for x in (a, b, c)), "the client never dropped a message for throttling")
    gaps = [l for x in (a, b, c) for l in x.log() if "seq gap" in l]
    check(not gaps, "no lost messages")
    # Spectator saw paddles where the players put them (compare final paddle targets).
    same_paddles = all(abs(match_of(c).paddles[s].target - ma.paddles[s].target) < 1e-9 for s in (1, 2))
    check(same_paddles, "spectator's paddles match the players'")
    c.frame("WoWPongFrame").Show(c.frame("WoWPongFrame"))
    c.run(0.05)
    check(c.ns._ui.status.text.endswith("wins!"), "spectator's window shows the winner")

    # Rematch by the host.
    check(a.ns.Table.canStart(), "rematch available")
    a.slash("start")
    net.run(1)
    check(a.ns.Table.cur.matchNo == 2 and b.ns.Table.cur.matchNo == 2 and c.ns.Table.cur.matchNo == 2,
          "rematch reaches everyone")
    check(match_of(b).phase in ("countdown", "play"), "guest is in the new match")
    check(not errors((a, b, c)), "no errors: %s" % errors((a, b, c))[:3])


def test_high_latency():
    net, (a, b) = setup(latency=0.3, jitter=0.1, n=2)
    a.slash("host")
    net.run(1)
    b.slash("join Alice")
    net.run(5)
    a.slash("start")
    pilot(a, "normal")
    pilot(b, "normal")
    net.until(lambda: over(a) and over(b), 900)
    check(over(a) and over(b) and score(a) == score(b), "300ms+ latency: match completes and both agree %s"
          % (score(a),))
    check(throttled(a) == 0 and throttled(b) == 0, "no throttled sends at high latency")
    check(not errors((a, b)), "no errors")


def test_disconnect_forfeit():
    net, (a, b, c) = setup()
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    c.slash("watch alice")
    net.run(4)
    a.slash("start")
    pilot(a, "hard")
    pilot(b, "hard")
    net.run(8)
    check(match_of(a).phase != "over", "match under way")
    net.cut.add(b)   # Bob's client vanishes (crash, /reload, disconnect)
    net.run(12)
    check(over(a) and score(a)[2] == 1 and score(a)[3], "host awards a forfeit win after Bob goes quiet")
    check(over(c) and score(c)[2] == 1 and score(c)[3], "spectator sees the forfeit")
    check(a.ns.Table.cur.seats[2] is None, "Bob's seat is freed")
    check(not errors((a, b, c)), "no errors")


def test_host_leaves():
    net, (a, b, c) = setup()
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    c.slash("watch alice")
    net.run(4)
    a.slash("start")
    net.run(5)
    a.slash("leave")
    net.run(1)
    check(over(b) and score(b)[2] == 2 and score(b)[3], "host leaving mid-match forfeits to the guest")
    check(over(c) and score(c)[2] == 2, "spectator sees it too")
    check(b.ns.Table.cur is None and c.ns.Table.cur is None, "table closed for everyone")
    check(any("closed the table" in l for l in b.chat()), "guest told the table closed")


def test_host_vanishes():
    net, (a, b) = setup(n=2)
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(4)
    a.slash("start")
    net.run(5)
    net.cut.add(a)
    net.run(12)
    check(over(b) and score(b)[2] == 2 and score(b)[3], "guest wins by forfeit when the host goes quiet")
    check(b.ns.Table.cur is None, "guest drops the dead table")


def test_idle_keepalive():
    net, (a, b) = setup(n=2)
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(30)
    check(a.ns.Table.cur.seats[2] is not None and b.ns.Table.cur is not None,
          "keepalives hold an idle table together for 30s")


def test_bot_table():
    net, (a, c) = setup(n=2)
    a.slash("host")
    a.slash("bot hard")
    net.run(1)
    c.slash("watch alice")
    net.run(1)
    check(c.ns.Table.cur.seats[2].bot == "hard", "spectator sees the bot in seat 2")
    check(a.ns.Table.canStart(), "host can start against the bot right away")
    a.slash("start")
    pilot(a, "normal")
    net.until(lambda: over(a) and over(c), 900)
    check(over(c) and score(a) == score(c), "bot match plays out identically for the spectator %s" % (score(c),))
    check(not errors((a, c)), "no errors")


def test_full_table_and_versions():
    net, (a, b, c) = setup()
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(4)
    c.slash("join alice")
    net.run(3)
    check(c.ns.Table.cur is not None and c.ns.Table.cur.role == "spectator", "third player watches a full table")
    check(a.ns.Table.cur.seats[2].name == "Bob", "Bob keeps his seat")
    # A host on another addon version.
    c.slash("leave")
    c.fire("CHAT_MSG_ADDON", "WoWPong", "T;99;9-9999;Zed;9-9999;Zed;;", "CHANNEL", "Zed", "", 0, 5)
    c.slash("join zed")
    check(any("different WoW Pong version" in l for l in c.chat()), "joining a different version is refused")
    check(c.ns.Table.cur is None, "not seated after refusal")


def test_ping_and_tables():
    net, (a, b) = setup(n=2)
    a.slash("host")
    net.run(1)
    b.slash("ping")
    net.run(2)
    check(any("pong from Alice" in l for l in b.log()), "/pong ping gets an answer from Alice")
    b.slash("tables")
    check(any("Alice's table" in l for l in b.chat()), "/pong tables lists Alice's table")
    b.slash("net")
    check(any("channel #5" in l for l in b.chat()), "/pong net shows stats")
    b.slash("join nobody")
    net.run(3)
    check(any("no table hosted by nobody" in l for l in b.chat()), "joining an unknown host says so")


def test_practice_leaves_table():
    net, (a, b) = setup(n=2)
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(4)
    b.slash("practice")
    net.run(1)
    check(b.ns.Table.cur is None and not b.ns.Game.networked, "starting practice leaves the table")
    check(a.ns.Table.cur.seats[2] is None, "host sees the seat free again")


def show(c):
    f = c.frame("WoWPongFrame")
    f.Show(f)
    c.run(0.6)
    return c.ns._ui


def enabled(button):
    return not button.disabled


def rows(ui):
    return [r for r in ui.rows.values() if r.shownFlag]


def test_lobby():
    net, (a, b, c, d) = setup(n=4)
    ua = show(a)
    ua.openBtn.scripts.OnClick(ua.openBtn)
    net.run(1)
    ua = show(a)
    check(a.ns.Table.cur.role == "host" and ua.board.shownFlag and not ua.lobby.shownFlag,
          "Open a Table switches to the table view")
    check(ua.botBtn.shownFlag and ua.levelBtn.shownFlag and not ua.practiceBtn.shownFlag, "host footer: bot controls")
    check(ua.status.text == "Waiting for an opponent", "host waits for an opponent")

    ub = show(b)
    r = rows(ub)
    check(len(r) == 1 and r[0].host.text == "Alice's table", "Bob's lobby lists Alice's table")
    check("Alice vs (open)" in r[0].detail.text and "Open seat" in r[0].detail.text, "row shows the open seat")
    check(enabled(r[0].sit) and enabled(r[0].watch), "Sit and Watch enabled")
    r[0].sit.scripts.OnClick(r[0].sit)
    net.run(4)
    ub = show(b)
    check(b.ns.Table.mySeat() == 2 and ub.board.shownFlag, "Sit puts Bob in seat 2 and shows the table")
    check(ub.playBtn.shownFlag and enabled(ub.playBtn) and not ub.botBtn.shownFlag, "guest footer: Play Now, no bot")
    check(ub.stopBtn.text == "Leave", "guest can leave")

    uc = show(c)
    net.run(1)
    uc = show(c)
    r = rows(uc)
    check(len(r) == 1 and "Alice vs Bob" in r[0].detail.text and "Ready" in r[0].detail.text, "full table is Ready")
    check(not enabled(r[0].sit) and enabled(r[0].watch), "can't sit at a full table, can watch")
    r[0].watch.scripts.OnClick(r[0].watch)
    net.run(1)
    uc = show(c)
    check(c.ns.Table.cur.role == "spectator" and not uc.playBtn.shownFlag, "Watch spectates, no Play Now")

    ud = show(d)
    ub.playBtn.scripts.OnClick(ub.playBtn)
    pilot(a, "hard")
    pilot(b, "easy")
    net.until(lambda: match_of(a) is not None and match_of(a).score[1] + match_of(a).score[2] >= 2, 120)
    net.run(3)
    ud = show(d)
    r = rows(ud)
    import re
    live_score = re.search(r"Playing (\d+)-(\d+)", r[0].detail.text) if r else None
    check(live_score is not None and int(live_score.group(1)) + int(live_score.group(2)) >= 2,
          "lobby shows the live score: %s" % (r[0].detail.text if r else None))
    check(not enabled(r[0].sit) and enabled(r[0].watch), "can watch a match in progress")
    net.until(lambda: over(a), 600)
    net.run(3)
    ud = show(d)
    check("Finished" in rows(ud)[0].detail.text, "lobby shows the final score")

    # Leaving puts Bob back in the lobby; the host's bot button works.
    ub.stopBtn.scripts.OnClick(ub.stopBtn)
    net.run(1)
    ub = show(b)
    check(b.ns.Table.cur is None and ub.lobby.shownFlag, "Leave returns to the lobby")
    ua = show(a)
    check(enabled(ua.botBtn) and ua.botBtn.text == "Add Bot", "host can add a bot once the seat is free")
    ua.botBtn.scripts.OnClick(ua.botBtn)
    ua = show(a)
    check(a.ns.Table.cur.seats[2].bot is not None and ua.botBtn.text == "Remove Bot", "Add Bot seats a bot")
    net.run(2)
    ub = show(b)
    r = rows(ub)
    check(enabled(r[0].sit), "a bot's seat can be taken between matches")
    ua.botBtn.scripts.OnClick(ua.botBtn)
    check(a.ns.Table.cur.seats[2] is None, "Remove Bot frees the seat")
    check(not errors((a, b, c, d)), "no errors: %s" % errors((a, b, c, d))[:3])


def test_lobby_freshness():
    net, (a, d) = setup(n=2)
    a.slash("host")
    net.run(200)
    ud = show(d)
    check(len(rows(ud)) == 1, "periodic announcements keep the table listed (200s, no queries)")
    sent_before = a.ns.Net.stats.sent
    net.run(60)
    check(a.ns.Net.stats.sent - sent_before <= 25, "an idle table costs few messages (%d/min)"
          % (a.ns.Net.stats.sent - sent_before))
    net.cut.add(a)
    net.run(80)
    ud = show(d)
    check(len(rows(ud)) == 0, "a vanished host's table drops off the list")

    net2, (e, f) = setup(n=2)
    e.slash("host")
    net2.run(590)
    check(e.ns.Table.cur is not None, "table still open before 10 minutes")
    net2.run(15)
    check(e.ns.Table.cur is None, "table closes after 10 minutes without a match")
    check(any("10 minutes" in l for l in e.chat()), "host told why")
    uf = show(f)
    check(len(rows(uf)) == 0, "closed table leaves others' lists at once")


def test_lobby_pages_and_versions():
    c = Client()
    c.run(6)
    for i in range(8):
        c.fire("CHAT_MSG_ADDON", "WoWPong", "T;2;9-%04d;Host%d;9-%04d;Host%d;;;open;0;0" % (i, i, i, i),
               "CHANNEL", "x", "", 0, 5)
    c.fire("CHAT_MSG_ADDON", "WoWPong", "T;1;9-9999;Zed;9-9999;Zed;;", "CHANNEL", "Zed", "", 0, 5)
    ui = show(c)
    check(len(rows(ui)) == 6 and ui.pageText.text == "1 / 2", "9 tables: 6 per page, 2 pages")
    ui.nextBtn.scripts.OnClick(ui.nextBtn)
    c.run(0.6)
    r = rows(ui)
    check(len(r) == 3 and ui.pageText.text == "2 / 2", "second page holds the rest")
    zed = [x for x in r if x.host.text == "Zed's table"]
    check(zed and "Different WoW Pong version" in zed[0].detail.text, "old-version table marked")
    check(zed and not enabled(zed[0].sit) and not enabled(zed[0].watch), "old-version table can't be joined")


def test_snapshot_codec():
    c = Client()
    ns, lua = c.ns, c.lua
    m = ns.Sim.newMatch()
    ns.Sim.apply(m, lua.table_from({"type": "START", "t": 0}))
    ns.Sim.apply(m, lua.table_from({"type": "MOVE", "t": 1, "seat": 1, "y": 250}))
    ns.Sim.apply(m, lua.table_from({"type": "SERVE", "t": 3, "dir": -1, "angle": 0.3}))
    s = ns.Codec.encodeSnapshot(m)
    check(len(s) < 180, "snapshot fits comfortably in a message (%d bytes)" % len(s))
    snap = ns.Codec.decodeSnapshot(s)
    r = ns.Sim.newMatch()
    ns.Sim.restore(r, snap)
    same = r.phase == "play" and r.score[1] == 0 and abs(r.serveAt or 0) == 0
    for t in (3.5, 4.2):
        bx, by = ns.Sim.ballPos(m, t)
        rx, ry = ns.Sim.ballPos(r, t)
        same = same and abs(bx - rx) < 0.01 and abs(by - ry) < 0.01
        same = same and abs(ns.Sim.paddleY(m, 1, t) - ns.Sim.paddleY(r, 1, t)) < 0.01
    check(same, "restored snapshot continues the same ball and paddles")
    check(ns.Codec.decodeSnapshot("p,1,2") is None, "bad snapshot rejected")


def start_match(net, a, b, level_a="hard", level_b="normal"):
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(4)
    a.slash("start")
    pilot(a, level_a)
    pilot(b, level_b)


def info_of(client, host):
    return client.ns.Table.known[host.ns.Net.pid()]


def test_late_spectator():
    net, (a, b, c, d) = setup(n=4, latency=0.15, jitter=0.1)
    start_match(net, a, b)
    net.until(lambda: sum(score(a)[:2]) >= 2, 300)
    net.run(1.3)   # mid-rally
    c.slash("tables")
    net.run(2)
    uc = show(c)
    r = rows(uc)
    r[0].watch.scripts.OnClick(r[0].watch)
    d.slash("watch alice")   # a second spectator at the same moment
    net.run(0.3)
    status = c.ns.Table.status()
    check(status is not None and "Catching up" in status[1], "spectator shows it's catching up")
    net.run(8)
    check(match_of(c) is not None and match_of(d) is not None, "late spectators get the match in progress")
    check(score(c)[:2] == score(a)[:2], "late spectator shows the current score %s" % (score(c),))
    zs = [t for n, t in net.sent if t.startswith("Z;")]
    check(len(zs) == 1, "one snapshot served both spectators (%d sent)" % len(zs))
    check(any("caught up" in l for l in c.log()), "spectator logged catching up")
    net.until(lambda: over(a) and over(b) and over(c) and over(d), 600)
    check(score(a) == score(b) == score(c) == score(d), "late spectators agree on the final result %s / %s"
          % (score(a), score(c)))
    ma, mc = match_of(a), match_of(c)
    same = all(abs(mc.paddles[s].target - ma.paddles[s].target) < 0.01 for s in (1, 2))
    check(same, "late spectator's paddles end where the players' do")
    gaps = [l for l in c.log() + d.log() if "seq gap" in l]
    check(not gaps, "no gaps after catching up: %s" % gaps[:2])

    # Next match starts normally for them.
    a.slash("start")
    net.run(2)
    check(match_of(c).phase in ("countdown", "play") and c.ns.Table.cur.matchNo == 2, "rematch reaches them")
    check(not errors((a, b, c, d)), "no errors: %s" % errors((a, b, c, d))[:3])


def test_late_spectator_bot_and_finished():
    net, (a, c) = setup(n=2)
    a.slash("host")
    a.slash("bot easy")
    net.run(1)
    a.slash("start")
    pilot(a, "hard")
    net.run(20)
    c.slash("watch alice")
    net.run(8)
    check(match_of(c) is not None and score(c)[:2] == score(a)[:2], "late spectator catches up on a bot match")
    net.until(lambda: over(a) and over(c), 600)
    check(score(a) == score(c), "bot match result agrees")
    net.run(3)
    e = Client(name="Eve", guid="Player-1-0009", start_time=42.5)
    net.clients.append(e)
    e.lua.globals().NS = e.ns
    net.run(40)   # joins the channel, hears the next periodic announcement
    e.slash("watch alice")
    net.run(4)
    check(over(e) and score(e) == score(a), "watching a finished table shows the result")
    ue = show(e)
    check(ue.status.text.endswith("wins!"), "and the winner in the window")


def test_snapshot_lost():
    net, (a, b, c) = setup()
    start_match(net, a, b)
    net.run(10)
    net.drop = lambda text, sender: text.startswith("Z;")
    c.slash("watch alice")
    net.run(22)
    check(match_of(c) is None and c.ns.Table.cur.snapGaveUp, "spectator gives up after a few unanswered requests")
    ws = [t for n, t in net.sent if n == "Cara" and t.startswith("W;")]
    check(len(ws) == 3, "asked 3 times (%d)" % len(ws))
    net.drop = lambda text, sender: False
    net.until(lambda: over(a), 600)
    a.slash("start")
    net.run(2)
    check(match_of(c) is not None and match_of(c).phase in ("countdown", "play"),
          "and simply picks up the next match")


if __name__ == "__main__":
    test_codec()
    test_join_sync_and_match()
    test_high_latency()
    test_disconnect_forfeit()
    test_host_leaves()
    test_host_vanishes()
    test_idle_keepalive()
    test_bot_table()
    test_full_table_and_versions()
    test_ping_and_tables()
    test_practice_leaves_table()
    test_lobby()
    test_lobby_freshness()
    test_lobby_pages_and_versions()
    test_snapshot_codec()
    test_late_spectator()
    test_late_spectator_bot_and_finished()
    test_snapshot_lost()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all net tests passed")
