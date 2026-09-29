"""Step 5 extras in fake clients: per-character win/loss stats (players, bots, forfeits, head-to-head, stats panel),
/pong invite (by name, by target, surnames, accept/decline/busy/no answer/full table), and the minimap button and
addon compartment entry (with stub libraries, and without any).

    pip install lupa
    python tools/test_extras.py
"""
import sys

from fakewow import Client
from test_net import Network, pilot, match_of, over, score, show, rows, errors

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def setup(specs, latency=0.1):
    """specs: list of (name, surname)."""
    clients = [Client(name=n, surname=s, guid="Player-1-000%d" % (i + 1), start_time=500 + 911.7 * i)
               for i, (n, s) in enumerate(specs)]
    net = Network(clients, latency)
    net.run(6)
    return net, clients


def stats(c):
    return c.ns.Stats.data()


def pid(c):
    return c.ns.Net.pid()


def play_to_end(net, a, b, la="hard", lb="easy"):
    a.slash("start")
    pilot(a, la)
    pilot(b, lb)
    net.until(lambda: over(a) and over(b), 600)


def test_stats():
    net, (a, b, c) = setup([("Alice", None), ("Bob", None), ("Cara", None)])
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    c.slash("watch alice")
    net.run(4)
    play_to_end(net, a, b)
    sa, sb = stats(a), stats(b)
    wa = score(a)[2] == 1
    winner, loser = (sa, sb) if wa else (sb, sa)
    check(winner.human.wins == 1 and winner.human.losses == 0, "winner gets a win")
    check(loser.human.losses == 1 and loser.human.wins == 0, "loser gets a loss")
    check(winner.human.streak == 1 and winner.human.bestStreak == 1 and loser.human.streak == 0, "streaks")
    s1, s2 = score(a)[0], score(a)[1]
    check(sa.human.pointsFor == s1 and sa.human.pointsAgainst == s2 and sb.human.pointsFor == s2,
          "points for and against")
    h2h = sa.opponents[pid(b)]
    check(h2h is not None and h2h.name == "Bob" and h2h.wins + h2h.losses == 1, "head-to-head keyed by player id")
    cs = stats(c)
    check(cs.human.wins + cs.human.losses == 0, "spectating doesn't count")

    # Rematch: Bob leaves mid-match -> forfeit loss for Bob, forfeit win for Alice.
    a.slash("start")
    net.run(8)
    b.slash("leave")
    net.run(2)
    check(sb.human.forfeitLosses == 1 and sb.human.losses == (2 if wa else 1), "leaving mid-match is a forfeit loss")
    check(sa.human.forfeitWins == 1, "and a forfeit win for the host")
    check(sa.opponents[pid(b)].wins + sa.opponents[pid(b)].losses == 2, "head-to-head counts both")

    # Bot games are kept apart.
    a.slash("bot hard")
    net.run(1)
    a.slash("start")
    net.until(lambda: over(a), 600)
    check(sa.bots.hard.wins + sa.bots.hard.losses == 1, "bot match counted under bots")
    check(sa.human.wins + sa.human.losses == 2, "and not in the player record")
    a.slash("practice easy")
    pilot(a, None)
    a.run(200, fps=20)
    check(sa.bots.easy.losses == 1, "local practice counts as a bot game (idle player loses to easy)")

    lines = list(a.ns.Stats.lines().values())
    check(lines[0].startswith("Vs players: ") and "forfeits: 1 won" in lines[0], "stats text: player record")
    check(any(l.startswith("Vs bots: Easy 0-1") for l in lines), "stats text: bot record")
    check(any("Bob" in l for l in lines), "stats text: head-to-head")
    a.slash("stats")
    check(any("Vs players" in l for l in a.chat()), "/pong stats prints the record")
    a.slash("stop")
    ua = show(a)
    ua.statsBtn.scripts.OnClick(ua.statsBtn)
    a.run(0.6)
    check(ua.lobbyTitle.text == "Your stats" and ua.statsLines[1].text.startswith("Vs players"),
          "Stats button shows the record in the lobby")
    check(not any(r.shownFlag for r in ua.rows.values()), "table rows hidden behind the stats")
    ua.statsBtn.scripts.OnClick(ua.statsBtn)
    a.run(0.6)
    check(ua.lobbyTitle.text == "Tables" and ua.statsLines[1].text == "", "and back to the tables")
    check(not errors((a, b, c)), "no errors: %s" % errors((a, b, c))[:3])


def popup(c):
    return c.frame("WoWPongInvite")


def test_invites():
    net, (a, b, c) = setup([("Alice", "Stormwind"), ("Bob", "Joegre"), ("Cara", None)])
    a.slash("invite bob")
    net.run(1)
    check(a.ns.Table.cur is not None and a.ns.Table.cur.role == "host", "inviting opens a table")
    pb = popup(b)
    check(pb.shownFlag and pb.text.text == "Alice challenges you to Pong!", "Bob gets the challenge popup")
    check(not popup(c).shownFlag, "only Bob")
    pb.accept.scripts.OnClick(pb.accept)
    net.run(4)
    check(b.ns.Table.mySeat() == 2 and a.ns.Table.cur.seats[2].name == "Bob", "accepting seats Bob at Alice's table")
    check(any("Bob Joegre accepted!" in l for l in a.chat()), "Alice told Bob accepted, by his full name")
    check(a.ns.Table.canStart(), "ready to play")

    # Busy: Bob is mid-match when Cara invites him.
    a.slash("start")
    net.run(5)
    c.slash("invite Bob Joegre")   # full name with surname
    net.run(2)
    check(any("Bob Joegre is in a match right now" in l for l in c.chat()),
          "inviting a busy player says so")
    check(not popup(b).shownFlag, "no popup during a match")

    # Decline, by target.
    a.slash("leave")
    net.run(2)
    b.slash("leave")
    net.run(1)
    c.lua.globals().TARGET = c.lua.table_from({"name": "Alice", "guid": a.guid})
    c.slash("invite")
    net.run(1)
    pa = popup(a)
    check(pa.shownFlag and "Cara" in pa.text.text, "invite by target reaches Alice")
    pa.decline.scripts.OnClick(pa.decline)
    net.run(1)
    check(any("Alice Stormwind declined" in l for l in c.chat()), "Cara told Alice declined")

    # Nobody by that name.
    c.slash("invite zed")
    net.run(16)
    check(any("zed didn't answer" in l for l in c.chat()), "no answer after 15s")

    # Popup ignored: expires, inviter hears nothing back.
    c.slash("invite alice")
    net.run(1)
    check(popup(a).shownFlag, "popup up")
    net.run(16)
    check(not popup(a).shownFlag, "popup goes away unanswered")
    check(any("alice didn't answer" in l for l in c.chat()), "inviter told there was no answer")

    # Full table.
    c.slash("bot easy")
    net.run(1)
    b.slash("join cara")
    net.run(4)
    c.slash("invite alice")
    check(any("your table is full" in l for l in c.chat()), "can't invite to a full table")
    check(not errors((a, b, c)), "no errors: %s" % errors((a, b, c))[:3])


def test_invite_replaces_bot():
    net, (a, b) = setup([("Alice", None), ("Bob", None)])
    a.slash("host")
    a.slash("bot normal")
    net.run(1)
    a.slash("invite bob")
    net.run(1)
    pb = popup(b)
    pb.accept.scripts.OnClick(pb.accept)
    net.run(4)
    check(a.ns.Table.cur.seats[2].name == "Bob", "an accepted invite takes the bot's seat")


STUB_LIBS = r"""
REGISTERED = {}
local ldb = { NewDataObject = function(self, name, obj) REGISTERED.obj = obj return obj end }
local icon = {
    Register = function(self, name, obj, db) REGISTERED.name, REGISTERED.db = name, db end,
    Hide = function(self, name) REGISTERED.hidden = true end,
    Show = function(self, name) REGISTERED.hidden = false end,
}
function LibStub(name, silent)
    if name == "LibDataBroker-1.1" then return ldb end
    if name == "LibDBIcon-1.0" then return icon end
end
"""


def test_minimap():
    c = Client(preload=STUB_LIBS)
    g = c.lua.globals()
    check(g.REGISTERED.name == "WoWPong" and g.REGISTERED.obj.icon.endswith("Media\\icon"),
          "launcher registered with LibDBIcon using the bundled icon")
    obj = g.REGISTERED.obj
    obj.OnClick(None, "LeftButton")
    frame = c.frame("WoWPongFrame")
    check(frame.shownFlag, "left-click opens the window")
    obj.OnClick(None, "LeftButton")
    check(not frame.shownFlag, "left-click again closes it")
    obj.OnClick(None, "RightButton")
    c.run(0.6)
    check(frame.shownFlag and c.ns._ui.lobbyTitle.text == "Your stats", "right-click opens your stats")
    tip = c.lua.eval("{ lines = {}, AddLine = function(self, t) table.insert(self.lines, t) end }")
    obj.OnTooltipShow(tip)
    lines = list(tip.lines.values())
    check(lines[0] == "WoW Pong" and "vs players" in lines[1], "tooltip shows the record")
    c.slash("minimap")
    check(g.REGISTERED.hidden and c.ns.db.minimap.hide, "/pong minimap hides the button and remembers it")
    c.slash("minimap")
    check(not g.REGISTERED.hidden, "and shows it again")

    plain = Client()
    check(any("libraries not available" in l for l in plain.log()), "no libraries: logged, no error")
    plain.lua.globals().WoWPong_OnCompartmentClick(None, "LeftButton")
    check(plain.frame("WoWPongFrame").shownFlag, "addon compartment entry opens the window")
    check(not plain.errors() and not c.errors(), "no errors")


if __name__ == "__main__":
    test_stats()
    test_invites()
    test_invite_replaces_bot()
    test_minimap()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all extras tests passed")
