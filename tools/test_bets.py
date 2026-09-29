"""Gold bets across fake clients: money parsing, posting/taking/cancelling offers through the bets panel, the
players-only-back-themselves rule, simultaneous takes (the host decides), betting closing at Play Now, settling into
a symmetric ledger, voiding when seats change hands or the host vanishes, host-refereed bot-vs-bot matches, the
lobby Ledger view, and settling up by trade.

    pip install lupa
    python tools/test_bets.py
"""
import sys

from fakewow import Client
from test_net import Network, pilot, match_of, over, score, show, errors

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")

G = 10000   # copper per gold


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def setup(names, latency=0.1):
    clients = [Client(name=n, guid="Player-1-000%d" % (i + 1), start_time=300 + 777.7 * i)
               for i, n in enumerate(names)]
    net = Network(clients, latency)
    net.run(6)
    return net, clients


def pid(c):
    return c.ns.Net.pid()


def panel(c):
    ui = show(c)
    c.run(0.3)
    return ui


def offers(c):
    return list(c.ns.Bets.offers().values())


def rows(c):
    ui = panel(c)
    return [r for r in ui.offerRows.values() if r.shownFlag]


def post_ui(c, side, amount_text):
    """Posts an offer through the panel: pick the side, type the amount, click Bet."""
    ui = panel(c)
    if (ui.betSide or 1) != side:
        ui.betSideBtn.scripts.OnClick(ui.betSideBtn)
    ui.betAmount.SetText(ui.betAmount, amount_text)
    ui.betBtn.scripts.OnClick(ui.betBtn)


def offer_by(c, poster, amount=None):
    for o in offers(c):
        if o.name == poster.name and (amount is None or o.amount == amount):
            return o


def balance(c, other):
    e = c.ns.Bets.ledger()[pid(other)]
    return e.balance if e is not None else 0


def test_money():
    c = Client()
    B = c.ns.Bets
    check(B.money(105030) == "10g 50s 30c" and B.money(0) == "0g" and B.money(250) == "2s 50c", "money formatting")
    check(B.parseGold("10") == 10 * G and B.parseGold("2.5") == 25000 and B.parseGold(" 1g 50s ") == 15000,
          "amounts in gold or g/s/c")
    check(B.parseGold("") is None and B.parseGold("abc") is None and B.parseGold("0") is None
          and B.parseGold("5x") is None, "bad amounts rejected")


def at_table():
    net, (a, b, c, d) = setup(["Alice", "Bob", "Cara", "Dan"])
    a.slash("host")
    net.run(1)
    b.slash("join alice")
    net.run(4)
    c.slash("watch alice")
    d.slash("watch alice")
    net.run(1)
    return net, (a, b, c, d)


def test_book_and_settle():
    net, (a, b, c, d) = at_table()
    ui = panel(c)
    check(ui.betsPanel.shownFlag, "bets panel shows at a table")
    check("Betting open" in ui.betStatus.text, "betting is open before Play Now")

    post_ui(c, 1, "10")   # Cara: 10g on Alice
    net.run(1)
    for x in (a, b, c, d):
        o = offer_by(x, c)
        check(o is not None and o.amount == 10 * G and o.side == 1, "%s sees Cara's 10g on Alice" % x.name)
    r = rows(d)
    check(len(r) == 1 and "Cara: 10g on Alice" in r[0].text.text and r[0].btn.text == "Take", "Dan's row: Take")
    check(rows(c)[0].btn.text == "Cancel", "Cara's own row: Cancel")

    # Players may only back themselves.
    ub = panel(b)
    check(ub.betSide == 2 and ub.betSideBtn.disabled, "Bob's bets are locked to himself")
    check(not b.ns.Bets.post(1, G), "Bob can't bet on Alice")
    ua = panel(a)
    check(ua.offerRows[1].btn.disabled, "Alice can't take a bet on herself")

    # Dan and Bob both take Cara's offer at once: the host decides, one wins.
    o = offer_by(d, c)
    d.ns.Bets.take(o.id)
    b.ns.Bets.take(o.id)
    net.run(1.5)
    taker = offer_by(a, c).takerName
    check(taker in ("Dan", "Bob") and all(offer_by(x, c).takerName == taker for x in (a, b, c, d)),
          "a double take resolves to one taker everywhere (%s)" % taker)

    # Bob backs himself 5g; Alice takes it. Cara posts 2g and withdraws it. Dan leaves 3g unmatched.
    b.ns.Bets.post(2, 5 * G)
    net.run(1)
    a.ns.Bets.take(offer_by(a, b).id)
    c.ns.Bets.post(2, 2 * G)
    net.run(1)
    c.ns.Bets.withdraw(offer_by(c, c, 2 * G).id)
    d.ns.Bets.post(2, 3 * G)
    net.run(1.5)
    check(offer_by(d, c, 2 * G) is None, "withdrawn offer gone")
    check(offer_by(b, b).status == "matched" and offer_by(b, b).takerName == "Alice", "Alice took Bob's 5g")
    check(offer_by(a, d, 3 * G).status == "open", "Dan's 3g still open")

    # Play Now closes betting; the unmatched 3g dies.
    b.slash("start")
    net.run(1)
    check(offer_by(c, d, 3 * G) is None, "unmatched offer void when the match starts")
    check(not c.ns.Bets.post(1, G), "no new bets once the match is on")
    check("Betting closed" in panel(c).betStatus.text, "panel says betting is closed")
    pilot(a, "hard")
    pilot(b, "normal")
    net.until(lambda: all(over(x) for x in (a, b, c, d)), 600)
    net.run(2)
    w = score(a)[2]
    wname = "Alice" if w == 1 else "Bob"
    # Cara (10g on Alice) vs taker; Alice vs Bob 5g.
    tk = {"Dan": d, "Bob": b}[taker]
    cara = 10 * G if w == 1 else -10 * G
    check(balance(c, tk) == cara and balance(tk, c) == -cara, "Cara vs %s settled both ways (%s won)" % (taker, wname))
    ab = 5 * G if w == 1 else -5 * G   # Alice took Bob's 5g on himself
    check(balance(a, b) == ab and balance(b, a) == -ab, "Alice vs Bob settled both ways")
    check(balance(d, c) == (0 if taker != "Dan" else -cara) and balance(c, d) == (0 if taker != "Dan" else cara),
          "no debt from the dead 3g offer")
    check(not c.ns.cdb.pendingBets or len(list(c.ns.cdb.pendingBets.values())) == 0, "nothing left pending")
    uc = panel(c)
    check(("won" in uc.betStatus.text) or ("lost" in uc.betStatus.text), "panel shows Cara's result")

    # Ledger view in the lobby.
    c.slash("leave")
    net.run(1)
    uc = show(c)
    uc.ledgerBtn.scripts.OnClick(uc.ledgerBtn)
    c.run(0.6)
    lrows = [r for r in uc.ledgerRows.values() if r.shownFlag]
    check(uc.lobbyTitle.text == "Ledger" and len(lrows) == 1 and taker in lrows[0].text.text,
          "Ledger lists Cara's balance with %s" % taker)
    check(not any(r.shownFlag for r in uc.rows.values()), "table rows hidden behind the ledger")
    c.slash("ledger")
    check(any(("owes you" in l or "you owe" in l) for l in c.chat()), "/pong ledger prints balances")
    lrows[0].btn.scripts.OnClick(lrows[0].btn)
    c.run(0.6)
    check(balance(c, tk) == 0 and not any(r.shownFlag for r in uc.ledgerRows.values()), "Settled clears it")
    uc.statsBtn.scripts.OnClick(uc.statsBtn)
    c.run(0.6)
    check(uc.lobbyTitle.text == "Your stats" and not uc.ledger.shownFlag, "Stats replaces the ledger view")
    check(not errors((a, b, c, d)), "no errors: %s" % errors((a, b, c, d))[:3])


def test_seat_change_voids():
    net, (a, b, c, d) = at_table()
    c.ns.Bets.post(1, 4 * G)
    net.run(1)
    d.ns.Bets.take(offer_by(d, c).id)
    net.run(1)
    check(offer_by(c, c).status == "matched", "bet on")
    b.slash("leave")   # the opponent leaves before Play Now
    net.run(2)
    check(len(offers(c)) == 0 and len(offers(d)) == 0, "a seat changing hands voids the book")
    check(not c.ns.cdb.pendingBets or len(list(c.ns.cdb.pendingBets.values())) == 0, "Cara's bet void")
    check(not d.ns.cdb.pendingBets or len(list(d.ns.cdb.pendingBets.values())) == 0, "Dan's bet void")
    check(balance(c, d) == 0, "no debts")


def test_host_vanishes_voids():
    net, (a, b, c, d) = at_table()
    c.ns.Bets.post(1, 4 * G)
    net.run(1)
    d.ns.Bets.take(offer_by(d, c).id)
    net.run(1)
    a.slash("start")
    net.run(4)
    net.cut.add(a)
    net.run(14)
    check(balance(c, d) == 0 and balance(d, c) == 0, "host vanished mid-match: bets void")
    check(not c.ns.cdb.pendingBets or len(list(c.ns.cdb.pendingBets.values())) == 0, "nothing pending")


def test_bot_match():
    net, (a, c, d) = setup(["Alice", "Cara", "Dan"])
    a.slash("host")
    ua = show(a)
    ua.levelBtn.scripts.OnClick(ua.levelBtn)   # Normal -> Hard
    ua.seatBtn.scripts.OnClick(ua.seatBtn)     # a hard bot takes Alice's seat
    a.slash("bot easy")
    net.run(1)
    t = a.ns.Table.cur
    check(t.seats[1].bot == "hard" and t.seats[2].bot == "easy", "bot vs bot table")
    ua = show(a)
    check(ua.seatBtn.text == "Take My Seat", "host can take the seat back")
    check(a.ns.Table.canStart() and a.ns.Table.mySeat() is None, "host referees: can start without a seat")
    c.slash("watch alice")
    d.slash("watch alice")
    net.run(2)
    check(c.ns.Table.cur.seats[1].name == "Bot (Hard)", "spectators see the bots")
    a.ns.Bets.post(2, 7 * G)          # the unseated host may back either side
    net.run(1)
    c.ns.Bets.take(offer_by(c, a).id)  # Cara backs the hard bot
    d.ns.Bets.post(1, 1 * G)
    net.run(1)
    a.ns.Bets.take(offer_by(a, d).id)  # the host takes one too
    net.run(1)
    a.slash("start")
    net.until(lambda: all(over(x) for x in (a, c, d)), 600)
    net.run(2)
    w = score(a)[2]
    check(score(c) == score(a) == score(d), "everyone saw the same bot match")
    exp_ac = 7 * G if w == 2 else -7 * G
    check(balance(a, c) == exp_ac and balance(c, a) == -exp_ac, "host vs Cara settled")
    exp_ad = 1 * G if w == 2 else -1 * G
    check(balance(a, d) == exp_ad and balance(d, a) == -exp_ad, "host vs Dan settled")
    check(a.ns.Stats.data().human.wins + a.ns.Stats.data().human.losses == 0, "refereeing doesn't touch stats")
    ua = show(a)
    ua.seatBtn.scripts.OnClick(ua.seatBtn)
    check(a.ns.Table.mySeat() == 1, "host sits back down")
    check(not errors((a, c, d)), "no errors: %s" % errors((a, c, d))[:3])


def test_trade_assist():
    c = Client(name="Cara", guid="Player-1-0003")
    B = c.ns.Bets
    dan_pid = "1-0004"
    B.adjust(dan_pid, "Dan", -12 * G, "lost 12g on a test")
    g = c.lua.globals()
    g.NPC = c.lua.table_from({"name": "Dan", "guid": "Player-1-0004"})
    c.fire("TRADE_SHOW")
    check(g.tradeMoney.set == 12 * G, "trading with someone you owe fills in the gold")
    check(any("you owe Dan 12g" in l for l in c.chat()), "and says why")
    c.fire("TRADE_ACCEPT_UPDATE", 1, 1)
    c.fire("UI_INFO_MESSAGE", 0, "Trade complete.")
    check(B.ledger()[dan_pid].balance == 0, "completed trade clears the debt")
    # Someone who owes you pays part of it.
    B.adjust(dan_pid, "Dan", 5 * G, "won 5g")
    g.tradeMoney.player, g.tradeMoney.target, g.tradeMoney.set = 0, 2 * G, None
    c.fire("TRADE_SHOW")
    check(g.tradeMoney.set is None and any("Dan owes you 5g" in l for l in c.chat()), "reminder when they owe you")
    c.fire("TRADE_ACCEPT_UPDATE", 1, 1)
    c.fire("UI_INFO_MESSAGE", 0, "Trade complete.")
    check(B.ledger()[dan_pid].balance == 3 * G, "partial payment recorded (3g left)")
    # Unrelated trade partner: nothing changes.
    g.NPC = c.lua.table_from({"name": "Zed", "guid": "Player-1-0099"})
    c.fire("TRADE_SHOW")
    c.fire("TRADE_ACCEPT_UPDATE", 1, 1)
    c.fire("UI_INFO_MESSAGE", 0, "Trade complete.")
    check(B.ledger()["1-0099"] is None, "trades with others don't touch the ledger")
    check(not c.errors(), "no errors")


if __name__ == "__main__":
    test_money()
    test_book_and_settle()
    test_seat_change_voids()
    test_host_vanishes_voids()
    test_bot_match()
    test_trade_assist()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all bets tests passed")
