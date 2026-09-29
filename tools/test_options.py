"""The options dialog in fake clients: opening it (slash, lobby button, minimap, the game's Settings page), tabs and
controls, every option's effect (window scale/lock, colors, target markers, ball trail, hit flash, board, practice
length, hold to steer, auto-open, invites, table notices, other-version tables, bets panel, trade assist, minimap,
echo), confirm buttons, restoring defaults and what gets saved.

    pip install lupa
    python tools/test_options.py
"""
import sys

from fakewow import Client
from test_extras import setup, STUB_LIBS
from test_net import errors

failures = 0
sys.stdout.reconfigure(encoding="utf-8", errors="replace")


def check(cond, msg):
    global failures
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond:
        failures += 1


def click(button, which="LeftButton"):
    button.scripts.OnClick(button, which)


def control(c, key):
    return c.ns._ui.optionRows[key].control


def opt(c, key):
    return c.ns.opt(key)


def color(tex):
    return tuple(round(v, 2) for v in list(tex.color.values())[:3])


STUB_SETTINGS = r"""
Settings = { cats = {} }
function Settings.RegisterCanvasLayoutCategory(frame, name) return { frame = frame, name = name } end
function Settings.RegisterAddOnCategory(cat) table.insert(Settings.cats, cat) end
SettingsPanel = { shown = true }
function HideUIPanel(p) p.shown = false end
"""


def test_opening():
    c = Client(preload=STUB_SETTINGS)
    ui = c.ns._ui
    dlg = c.frame("WoWPongOptions")
    check(dlg is not None and not dlg.shownFlag, "options dialog built hidden")
    c.slash("options")
    check(dlg.shownFlag, "/pong options opens it")
    check(ui.optionPages.Display.shownFlag and not ui.optionPages.Play.shownFlag, "starts on the Display tab")
    check(ui.optionTabs.Display.mark.shownFlag and not ui.optionTabs.Social.mark.shownFlag, "active tab marked")
    check("Hover" in ui.optionsHint.text, "hint line explains itself")
    row = ui.optionRows.trail
    row.scripts.OnEnter(row)
    check("trail" in ui.optionsHint.text, "hovering a row shows its description")
    row.scripts.OnLeave(row)
    click(ui.optionTabs.Social)
    check(ui.optionPages.Social.shownFlag and not ui.optionPages.Display.shownFlag, "tabs switch pages")
    c.slash("config")
    check(not dlg.shownFlag, "/pong config toggles it closed")
    c.slash("")
    c.run(0.6)
    check(ui.optionsBtn.shownFlag, "lobby has an Options button")
    click(ui.optionsBtn)
    check(dlg.shownFlag, "lobby Options button opens it")
    check("WoWPongOptions" in list(c.lua.globals().UISpecialFrames.values()), "Esc closes it")
    dlg.Hide(dlg)
    g = c.lua.globals()
    cats = list(g.Settings.cats.values())
    check(len(cats) == 1 and cats[0].name == "WoW Pong", "registered on the game's Settings > AddOns page")
    check(c.frame("WoWPongSettingsCanvas") is not None, "Settings page built")
    frames = list(g.createdFrames.values())
    opener = [f for f in frames if f.kind == "Button" and f.text == "Open WoW Pong Options"]
    check(len(opener) == 1, "Settings page has an Open button")
    click(opener[0])
    check(dlg.shownFlag and not g.SettingsPanel.shown, "it closes Settings and opens the dialog")
    check(any("/pong options" in l for l in list(c.ns.help.values())), "listed in /pong help")

    plain = Client()
    check(any("no Settings API" in l for l in plain.log()), "no Settings API: logged, slash still works")
    check(not c.errors() and not plain.errors(), "no errors")


def test_display():
    c = Client(name="Bear")
    ui = c.ns._ui
    frame = c.frame("WoWPongFrame")
    size = control(c, "scale")
    check(size.value.text == "100%", "window size shows 100%")
    click(size.up)
    check(abs(opt(c, "scale") - 1.1) < 1e-9 and abs(frame.scale - 1.1) < 1e-9, "> grows the window at once")
    for _ in range(10):
        click(size.up)
    check(abs(opt(c, "scale") - 1.5) < 1e-9 and size.value.text == "150%", "capped at 150%")
    check(size.up.disabled and not size.down.disabled, "> disabled at the top")
    for _ in range(20):
        click(size.down)
    check(abs(opt(c, "scale") - 0.7) < 1e-9, "floored at 70%")

    moved = []
    frame.StartMoving = lambda self: moved.append(1)
    frame.scripts.OnDragStart(frame)
    check(len(moved) == 1, "window drags by default")
    click(control(c, "lockWindow"))
    check(opt(c, "lockWindow") and control(c, "lockWindow").check.shownFlag, "lock checkbox ticks")
    frame.scripts.OnDragStart(frame)
    check(len(moved) == 1, "locked window doesn't drag")
    lock_row = ui.optionRows.lockWindow
    lock_row.scripts.OnMouseDown(lock_row)
    check(not opt(c, "lockWindow"), "clicking a toggle's label flips it too")

    alpha = control(c, "boardAlpha")
    click(alpha.down)
    check(abs(ui.boardBg.color[4] - 0.8) < 1e-9, "board darkness changes the background")
    click(control(c, "centerLine"))
    check(not any(d.shownFlag for d in ui.dashes.values()), "center line hidden")

    c.slash("practice easy")
    c.run(0.2)
    check(color(ui.paddles[1]) == (0.35, 0.65, 1.0), "classic: seat 1 blue")
    colors = control(c, "colors")
    click(colors)
    c.run(0.05)
    check(colors.text == "Me vs them" and color(ui.paddles[1]) == (0.35, 0.9, 0.4)
          and color(ui.paddles[2]) == (1.0, 0.4, 0.35), "me vs them: you green, the bot red")
    click(colors)
    c.run(0.05)
    check(color(ui.paddles[1]) == (0.25, 0.78, 0.92) and color(ui.paddles[2]) == (1.0, 0.45, 0.35),
          "class colors: you in your class color, the bot keeps its seat color")
    click(colors)
    c.run(0.05)
    check(color(ui.paddles[1]) == (0.95, 0.95, 0.95) and color(ui.paddles[2]) == (0.95, 0.95, 0.95),
          "retro: all white")
    click(colors, "RightButton")
    check(colors.text == "Class colors", "right-click cycles back")

    c.click_board(250)
    c.run(0.1)
    check(ui.ghosts[1].shownFlag, "target marker shown by default")
    ghosts = control(c, "ghosts")
    click(ghosts)
    c.click_board(60)
    c.run(0.1)
    check(opt(c, "ghosts") == "mine" and ui.ghosts[1].shownFlag, "mine only: still see your own")
    click(ghosts)
    c.click_board(250)
    c.run(0.1)
    check(not ui.ghosts[1].shownFlag, "off: no markers")

    c.run(3)
    m = c.ns.Game.match
    check(m.phase == "play", "ball in play")
    check(not any(d.shownFlag for d in ui.trail.values()), "no trail by default")
    def most_dots(sec):
        """Most trail dots seen over `sec` (right after a hit or a miss the trail is short or gone)."""
        best = 0
        for _ in range(int(sec * 60)):
            c.run(1 / 60)
            best = max(best, sum(1 for d in ui.trail.values() if d.shownFlag))
        return best

    trail = control(c, "trail")
    click(trail)
    shown = most_dots(2)
    check(opt(c, "trail") == "short" and shown == 4, "short trail: 4 dots (%d)" % shown)
    click(trail)
    shown = most_dots(2)
    check(shown == 8, "long trail: 8 dots (%d)" % shown)

    # Hit flash: watch a bot game until a paddle returns the ball.
    c.ns.Options.set("colors", "classic")
    c.slash("demo hard hard")
    m = c.ns.Game.match
    for _ in range(3000):
        c.run(1 / 60)
        if m.hits > 0:
            break
    seat = next(e.seat for e in m.events.values() if e.type == "HIT")
    c.run(1 / 60)
    base = (0.35, 0.65, 1.0) if seat == 1 else (1.0, 0.45, 0.35)
    col = color(ui.paddles[seat])
    check(col != base and all(a >= b for a, b in zip(col, base)), "a paddle flashes toward white on a hit")
    c.run(0.5)
    check(color(ui.paddles[seat]) == base, "and fades back")
    click(control(c, "hitFlash"))
    ui.flash[seat] = c.lua.globals().now
    c.run(1 / 60)
    check(color(ui.paddles[seat]) == base, "no flash when turned off")
    check(not c.errors(), "no errors")


def test_play():
    c = Client(name="Bear")
    ui = c.ns._ui
    level = control(c, "level")
    check(level.text == "Normal", "bot difficulty shows the saved level")
    click(level)
    check(c.ns.db.level == "hard" and ui.levelBtn.text == "Bot: Hard", "changing it updates the footer button")
    click(ui.levelBtn)
    c.slash("options")
    check(level.text == "Easy", "and the footer button's changes show in the dialog")

    length = control(c, "points")
    click(length, "RightButton")
    click(length, "RightButton")
    check(opt(c, "points") == 3 and length.text == "First to 3", "match length: first to 3")
    c.slash("demo")
    m = c.ns.Game.match
    check(m.pointsToWin == 3, "Watch Bots uses it")
    c.run(400, fps=20)
    check(m.phase == "over" and max(m.score[1], m.score[2]) == 3, "a bot match ends at 3")
    c.slash("practice")
    check(c.ns.Game.match.pointsToWin == 3, "so does practice")
    c.run(0.5)
    check("First to 3" in ui.hint.text, "the hint says so")

    # Hold to steer: off, holding the button does nothing more.
    board = c.frame("WoWPongBoard")
    g = c.lua.globals()
    c.run(3)
    m = c.ns.Game.match
    g.cursorY = 100
    board.scripts.OnMouseDown(board, "LeftButton")
    g.cursorY = 220
    c.run(0.3)
    check(m.paddles[1].target == 100, "without hold to steer, a held button keeps the first target")
    board.scripts.OnMouseUp(board, "LeftButton")
    click(control(c, "holdToSteer"))
    board.scripts.OnMouseDown(board, "LeftButton")
    g.cursorY = 80
    c.run(0.3)
    check(m.paddles[1].target == 80, "with it, the target follows the cursor while held")
    board.scripts.OnMouseUp(board, "LeftButton")
    g.cursorY = 200
    c.run(0.3)
    check(m.paddles[1].target == 80, "and stops following on release")
    check(not c.errors(), "no errors")


def test_social():
    net, (a, b, c) = setup([("Alice", None), ("Bob", None), ("Cara", None)])
    ga = a.lua.globals()

    # Auto-open: Alice's window is closed when Bob sits down.
    a.slash("host")
    a.frame("WoWPongFrame").Hide(a.frame("WoWPongFrame"))
    net.run(1)
    b.slash("join alice")
    net.run(4)
    check(a.frame("WoWPongFrame").shownFlag, "host's window opens when someone sits down")
    b.frame("WoWPongFrame").Hide(b.frame("WoWPongFrame"))
    a.slash("start")
    net.run(2)
    check(b.frame("WoWPongFrame").shownFlag, "guest's window opens when the match starts")
    ua = a.ns._ui
    check(ua.betsPanel.shownFlag, "bets panel at a table by default")
    click(control(a, "betsPanel"))
    a.run(0.1)
    check(not ua.betsPanel.shownFlag, "turned off: hidden")
    click(control(a, "betsPanel"))
    a.run(0.1)
    check(ua.betsPanel.shownFlag, "and back")
    a.slash("leave")
    b.slash("leave")
    net.run(2)

    # Invites: decline all.
    click(control(b, "invites"), "RightButton")
    check(b.ns.opt("invites") == "none", "invites: decline all")
    a.slash("invite bob")
    net.run(2)
    check(not b.frame("WoWPongInvite").shownFlag, "no popup")
    check(any("Bob declined" in l for l in a.chat()), "inviter hears it was declined")

    # Friends & guild only.
    click(control(b, "invites"), "RightButton")
    check(b.ns.opt("invites") == "friends", "invites: friends & guild")
    b.lua.execute('C_FriendList.IsFriend = function(guid) return guid == "%s" end' % a.guid)
    c.slash("invite bob")
    net.run(2)
    check(not b.frame("WoWPongInvite").shownFlag and any("Bob declined" in l for l in c.chat()),
          "a stranger is declined")
    a.slash("invite bob")
    net.run(2)
    check(b.frame("WoWPongInvite").shownFlag, "a friend gets the popup")
    pb = b.frame("WoWPongInvite")
    click(pb.decline)
    b.lua.execute("C_FriendList.IsFriend = nil; IsGuildMember = function() return true end")
    c.slash("invite bob")
    net.run(2)
    check(pb.shownFlag, "a guildmate gets the popup too")
    click(pb.decline)
    a.slash("leave")
    c.slash("leave")
    net.run(2)

    # Table notices: nothing during the first minute (existing tables), then new ones are announced.
    click(control(b, "tableNotice"))
    net.run(50)
    before = len(b.chat())
    c.slash("host")
    net.run(2)
    check(any("Cara opened a Pong table" in l for l in b.chat()[before:]), "Bob hears Cara opened a table")
    check(not any("opened a Pong table" in l for l in a.chat()), "only if you asked for it")
    c.slash("leave")
    net.run(2)

    # Other-version tables.
    ub = b.ns._ui
    b.frame("WoWPongFrame").Show(b.frame("WoWPongFrame"))
    known = b.ns.Table.known
    known["old-host"] = b.lua.table_from({"version": 1, "host": "old-host", "hostName": "Oldie",
                                          "seats": b.lua.table_from({}), "heardAt": b.lua.globals().now,
                                          "state": "open", "score": b.lua.table_from({1: 0, 2: 0}),
                                          "matchNo": 0})
    ub.lobbyAt = None
    b.run(0.1)
    check(any(r.shownFlag and "Oldie" in r.host.text for r in ub.rows.values()), "old-version table listed")
    click(control(b, "hideOtherVersions"))
    b.run(0.1)
    check(not any(r.shownFlag and "Oldie" in r.host.text for r in ub.rows.values()), "and hidden on request")

    # Trade assist.
    gb = b.lua.globals()
    b.ns.Bets.adjust(str(a.ns.Net.pid()), "Alice", -50000, "test")
    gb.NPC = b.lua.table_from({"name": "Alice", "guid": a.guid})
    b.fire("TRADE_SHOW")
    check(gb.tradeMoney.set == 50000, "trade assist fills in the gold you owe")
    gb.tradeMoney.set = None
    b.fire("TRADE_CLOSED")
    click(control(b, "tradeAssist"))
    b.fire("TRADE_SHOW")
    check(gb.tradeMoney.set is None and any("you owe Alice" in l for l in b.chat()),
          "turned off: only a reminder")
    check(not errors((a, b, c)), "no errors: %s" % errors((a, b, c))[:3])


def test_general():
    c = Client(preload=STUB_LIBS + "\nLOCKED = nil\n")
    c.lua.execute("""
        local icon = LibStub("LibDBIcon-1.0")
        icon.Lock = function(self, name) LOCKED = true end
        icon.Unlock = function(self, name) LOCKED = false end
    """)
    g = c.lua.globals()
    ui = c.ns._ui
    obj = g.REGISTERED.obj
    obj.OnClick(None, "MiddleButton")
    check(c.frame("WoWPongOptions").shownFlag, "middle-clicking the minimap button opens the options")
    obj.OnClick(None, "MiddleButton")
    check(not c.frame("WoWPongOptions").shownFlag, "and closes them")
    tip = c.lua.eval("{ lines = {}, AddLine = function(self, t) table.insert(self.lines, t) end }")
    obj.OnTooltipShow(tip)
    check(any("options" in l for l in tip.lines.values()), "tooltip mentions it")
    g.WoWPong_OnCompartmentClick(None, "MiddleButton")
    check(c.frame("WoWPongOptions").shownFlag, "the compartment entry too")

    mm = control(c, "minimap")
    check(mm.checked, "minimap button checkbox on")
    click(mm)
    check(g.REGISTERED.hidden and c.ns.db.minimap.hide, "unticking hides the button")
    check(control(c, "minimapLock").disabled, "lock greyed out while hidden")
    click(mm)
    click(control(c, "minimapLock"))
    check(g.LOCKED is True and c.ns.db.minimap.lock, "lock minimap button")
    click(control(c, "minimapLock"))
    check(g.LOCKED is False, "and unlock")
    click(control(c, "echo"))
    check(c.ns.db.echo, "echo toggle")
    c.ns.log("hello there")
    check(any("hello there" in l for l in c.chat()), "echo prints log lines")
    click(control(c, "echo"))

    c.slash("practice")
    c.run(200, fps=20)
    check(c.ns.Stats.data().bots.normal.losses + c.ns.Stats.data().bots.normal.wins == 1, "a bot game recorded")
    reset = control(c, "resetStats")
    click(reset)
    check(reset.text == "Sure? Click again" and c.ns.cdb.stats is not None, "first click only arms it")
    c.run(5)
    check(reset.text == "Reset", "disarms after a few seconds")
    click(reset)
    click(reset)
    check(c.ns.cdb.stats is None, "two clicks reset the stats")

    click(control(c, "trail"))
    click(control(c, "scale").up)
    click(control(c, "level"))
    frame = c.frame("WoWPongFrame")
    c.ns.db.pos = c.lua.table_from({1: "TOP", 2: "TOP", 3: 5, 4: -5})
    stored = dict(c.ns.db.opts.items())
    check(set(stored) == {"trail", "scale"}, "only changed options are saved (%s)" % sorted(stored))
    defaults = control(c, "defaults")
    click(defaults)
    click(defaults)
    check(len(dict(c.ns.db.opts.items())) == 0 and opt(c, "trail") == "off", "restore defaults empties them")
    check(c.ns.db.level is None and ui.levelBtn.text == "Bot: Normal" and c.ns.db.pos is None,
          "bot level and window position too")
    check(abs(frame.scale - 1) < 1e-9 and control(c, "scale").value.text == "100%", "and it shows at once")
    click(control(c, "resetPos"))
    check(frame.points[1][1] == "CENTER", "Center it recenters the window")
    check(not c.errors(), "no errors")


if __name__ == "__main__":
    test_opening()
    test_display()
    test_play()
    test_social()
    test_general()
    if failures:
        print("%d FAILED" % failures)
        sys.exit(1)
    print("all options tests passed")
