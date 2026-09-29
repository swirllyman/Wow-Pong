"""Drives the Pong window in the fake client like a player: open/close, practice vs a bot with board clicks,
watching bots to the end, stop, difficulty cycling, and no errors in the saved log.

    pip install lupa
    python tools/test_ui.py
"""
import sys

from fakewow import Client

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def test_window():
    c = Client()
    frame = c.frame("WoWPongFrame")
    check(frame is not None and not frame.IsShown(frame), "window built hidden")
    c.slash("")
    check(frame.IsShown(frame), "/pong opens the window")
    c.run(0.2)
    check(c.ns._ui.status.text == "WoW Pong", "idle board shows the title")
    c.slash("")
    check(not frame.IsShown(frame), "/pong again closes it")
    check("WoWPongFrame" in list(c.lua.globals().UISpecialFrames.values()), "Esc closes the window")
    c.slash("help")
    check(any("/pong practice" in l for l in c.chat()), "/pong help lists commands")
    check(not c.errors(), "no errors")


def test_practice():
    c = Client(name="Bear")
    c.slash("practice hard")
    ns, ui = c.ns, c.ns._ui
    m = ns.Game.match
    check(ns.Game.humanSeat == 1 and ns.Game.names[1] == "Bear", "practice seats you on the left")
    check(ns.Game.names[2] == "Bot (Hard)", "bot named by difficulty")
    c.run(0.5)
    check(ui.status.text == "3", "countdown shown")
    check("Click the board" in ui.hint.text, "click hint during the countdown")
    c.click_board(250)
    check(m.paddles[1].target == 250, "board click sets your paddle target")
    c.run(0.1)
    check(ui.ghosts[1].shownFlag, "ghost target visible while the paddle travels")
    c.click_board(9999)
    check(m.paddles[1].target == ns.Sim.H - ns.Sim.PADDLE_H / 2, "clicks past the edge are clamped")
    c.run(3)
    check(m.phase == "play" and ui.ball.shownFlag, "ball in play after the countdown")
    check(ui.status.text == "" and ui.hint.text == "", "status clears in play")
    # Don't move: the hard bot should win 7-0 against a parked paddle... unless the serve hits it.
    c.run(240, fps=30)
    check(m.phase == "over" and m.winner == 2, "the bot wins against an idle player")
    check(ui.status.text == "Bot (Hard) wins!", "winner announced")
    check(any("match over" in l for l in c.log()), "result logged")
    c.slash("stop")
    check(ns.Game.match is None, "/pong stop ends the match")
    c.run(0.1)
    check(not ui.ball.shownFlag, "ball hidden with no match")
    check(not c.errors(), "no errors")


def test_demo_and_levels():
    c = Client()
    ns, ui = c.ns, c.ns._ui
    check(ui.levelBtn.text == "Bot: Normal", "difficulty defaults to normal")
    ui.levelBtn.scripts.OnClick(ui.levelBtn)
    check(ui.levelBtn.text == "Bot: Hard" and ns.db.level == "hard", "difficulty button cycles and saves")
    ui.levelBtn.scripts.OnClick(ui.levelBtn)
    check(ns.db.level == "easy", "cycles back to easy")
    ui.demoBtn.scripts.OnClick(ui.demoBtn)
    check(c.frame("WoWPongFrame").IsShown(c.frame("WoWPongFrame")), "Watch Bots opens the window")
    check(ns.Game.humanSeat is None and ns.Game.names[1] == "Bot (Easy)", "two bots at the chosen level")
    c.click_board(10)
    check(ns.Game.match.paddles[1].target != 10, "clicks do nothing while spectating")
    c.run(900, fps=20)
    m = ns.Game.match
    check(m.phase == "over" and max(m.score[1], m.score[2]) == 7, "bot match plays to 7")
    c.slash("demo hard easy")
    check(ns.Game.names[1] == "Bot (Hard)" and ns.Game.names[2] == "Bot (Easy)", "/pong demo takes two levels")
    c.run(1)
    ui.stopBtn.scripts.OnClick(ui.stopBtn)
    check(ns.Game.match is None, "Stop button ends the match")
    check(not c.errors(), "no errors")


if __name__ == "__main__":
    test_window()
    test_practice()
    test_demo_and_levels()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all ui tests passed")
