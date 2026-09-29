# WoW Pong

**1v1 Pong inside World of Warcraft, with spectators.** Open a table, challenge a guildmate, and let anyone else watch. Click the board and your paddle glides toward the click at a fixed speed. The skill is predicting where the ball will end up.

Type `/pong` to open the lobby.

Made for **World of Warcraft: Forever** (Interface 16001).

---

## How to play

- Click anywhere on the board and your paddle heads for that height. Everyone sees the same board: the table's host plays on the left, the challenger on the right.
- Where the ball meets your paddle sets its angle: the edges send it off at up to 60 degrees. The ball speeds up with every hit.
- Miss the ball and your opponent scores. **First to 7** by default. The table's host can pick first to 1, 3, 5 or 7.
- Both players' target markers are shown, so you (and anyone watching) can see where each paddle is heading.
- Leaving, disconnecting or reloading during a match counts as a forfeit.

## Features

- **Lobby.** See every open table with its players and live score. Sit down or watch with one click, or open your own table.
- **Spectating.** Watch any match, even one that's already underway. You catch up within a few seconds.
- **Bots** in three difficulties (Easy, Normal, Hard). Practice against one alone, watch two bots play, or add one to your table. The host can even put bots in both seats and let people watch or bet.
- **Rally counter.** The current rally is shown during play, and the longest rally when the match ends.
- **Stats**, per character: wins and losses against players (with forfeits, streaks, points and head-to-head records), your record against each bot difficulty, and your longest rallies.
- **Invites.** `/pong invite <name>` (or your target) sends a challenge with Accept and Decline buttons.
- **Gold bets.** Players can post even-money bets on themselves and anyone at the table can take them. The addon **can't move gold**: it keeps an honor ledger of who owes whom and fills in the amount when you open a trade with that person.
- **Minimap button** and **addon compartment** entry. The tooltip shows your record.
- **Quiet.** Everything happens in the Pong window. The addon never posts results to chat and plays no sounds.

## Options

Open the options with the lobby's **Options** button, with `/pong options`, by middle-clicking or shift-clicking the minimap button, or from the game's **Settings > AddOns** page.

- **Display:** window size and lock, paddle colors (blue vs red, me vs them, class colors, retro white), target markers, ball trail, hit flash, board darkness, center line.
- **Play:** bot difficulty, match length, hold the mouse button to steer, open the window when your match starts.
- **Social:** who can invite you (everyone, friends and guild, nobody), a chat notice when a table opens, hide tables running a different version, bets panel, trade fill-in.
- **General:** minimap button, reset window position, reset stats, restore defaults.

Options apply to every character on your account. Stats and the bet ledger are kept separately for each character.

## Commands

| Command | What it does |
|---|---|
| `/pong` | Open the lobby (or close the window) |
| `/pong practice [easy\|normal\|hard]` | Play against a bot |
| `/pong demo [level] [level]` | Watch two bots play |
| `/pong points 1\|3\|5\|7` | Match length for your table and practice |
| `/pong host` | Open a table (you take seat 1) |
| `/pong join <name>` / `/pong watch <name>` | Sit at someone's table, or watch it |
| `/pong bot [level]` | (Host) put a bot in seat 2 |
| `/pong start` / `/pong leave` | Play Now / leave the table |
| `/pong invite [name]` | Challenge someone (or your target) |
| `/pong tables` | List the tables you can see |
| `/pong stats` / `/pong ledger` | Your record / who owes whom from bets |
| `/pong options` | Open the options window |
| `/pong minimap` | Show or hide the minimap button |
| `/pong ping` / `/pong net` | Check who can hear you / message stats |

## How it works

There's no server. Players talk to each other with addon messages on a hidden chat channel. Each player decides whether their own paddle hit or missed, and the table's host serves and ends the match. Every client replays the same event list through a deterministic simulation, so players and spectators see the same match. Addon messages are rate-limited, so the addon batches and prioritizes what it sends to stay under the game's limit.

Both players need the same version of the addon. The lobby marks tables running a different version.

## Installation

Copy the `WoWPong` folder into `World of Warcraft\_classic_beta_\Interface\AddOns\` and restart the game.

## Development

The `tools` folder has headless tests that load the real addon files into a fake WoW client (Python with [lupa](https://pypi.org/project/lupa/)):

```bash
pip install lupa
```

```bash
python tools/test_sim.py
```

The other suites are `test_ui.py`, `test_net.py` (several fake clients over a simulated channel with latency; takes a few minutes), `test_extras.py`, `test_bets.py`, `test_options.py` and `test_match_length.py`.

## Credits

Bundles [LibStub](https://www.wowace.com/projects/libstub), [CallbackHandler-1.0](https://www.wowace.com/projects/callbackhandler), [LibDataBroker-1.1](https://github.com/tekkub/libdatabroker-1-1) and [LibDBIcon-1.0](https://www.wowace.com/projects/libdbicon-1-0), used under their own licenses.
