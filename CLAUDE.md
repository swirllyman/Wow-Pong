# WoW Pong

A World of Warcraft: **Forever** addon: 1v1 click-to-move Pong with spectators. `/pong` (or `/wowpong`) opens the
window. Players click the board and their paddle glides toward the click at a fixed speed, so predicting where the
ball will arrive is the skill.

## Plan and status

1. **Local game** (bot vs bot and practice vs bot), done and tested headlessly, **not yet tried in-game**. The
   footer buttons (Practice vs Bot / Bot level / Watch Bots / Stop) are temporary until the lobby exists.
2. **Networked play**, done and tested headlessly with 2-3 fake clients, **not yet tried in-game** (addon messages
   between real players on Forever are still unverified; the user tests with a guildmate). Slash-command tables:
   `/pong host`, `join <name>`, `watch <name>`, `bot [level]`, `start`, `leave`, `tables`, `ping`, `net`.
3. **Lobby UI**: table list, seat buttons, Spectate, on top of Table.lua's protocol. Hosts will need a periodic T
   announcement (and table expiry) so lists stay fresh; seat 1 is currently always the host.
4. **Spectating mid-match**: late joiners currently wait for the next START; add a snapshot from the host.
5. **Extras**: LibDBIcon minimap button, per-character win/loss stats, `/pong invite Name` whisper challenge.

## Design decisions (from the user, don't re-ask)

- Lobby on a hidden custom channel; many tables. Each paddle's owner judges hit/miss for their own paddle; the
  table host serves and ends the match. Disconnect/reload/leave = instant forfeit. Combat changes nothing.
- Fixed board for everyone (seat 1 always left). Everyone sees both players' target markers (ghost paddles).
- First to 7. Hit position sets the exit angle (up to 60 degrees), the ball speeds up per hit up to a cap.
- Bot runs on the host, is spectatable, Easy/Normal/Hard. Either seated player presses Play Now (3s countdown).
- Results only in the Pong UI, never chat. No sounds.
- Ask the user design questions as **multiple choice** (AskUserQuestion), never as prose lists.

## How the simulation works (`Sim.lua`)

- Pure Lua, no WoW API. A match changes only via `Sim.apply(match, event)`; events are START, SERVE, MOVE, HIT,
  MISS, FORFEIT, each with an absolute time `t`. Replaying the same event list gives the same match (tested), which
  is what spectators and the remote player will rely on.
- Between events everything is analytic: `Sim.ballPos(m, t)` folds the ball's y between the walls, and
  `Sim.paddleY(m, seat, t)` moves the paddle toward its target. Frame rate never changes the outcome.
- `Sim.step(m, now, auth)` creates the events this client is responsible for: the host serves (random angle via
  `auth.rand`), and owners of `auth.seats` judge arrivals at the exact arrival time. HIT events carry the new ball
  path, so other clients never recompute the physics and float differences can't desync them.
- While in play the UI holds the ball at the paddle face until the verdict arrives, so network lag will show as a
  brief pause, never as the ball passing through a paddle.
- Board is 480x300 units drawn 1:1; tuning constants are at the top of Sim.lua. `tools/test_sim.py` prints a bot
  balance report; retune after playtests.

## Networking (`Net.lua`, `Table.lua`)

- Everything goes over the hidden channel `WoWPongLobby` (prefix `WoWPong`), joined 5s after entering the world,
  removed from chat frames, join notices filtered. Spectators just listen and never send.
- Message list and fields are documented at the top of Table.lua. Peers are identified by `Net.pid()` (GUID minus
  `Player-`), never by name; names are display only (first name).
- Match time = host `GetTime()` minus the table epoch. The guest syncs with 3 C/c pings (lowest round trip wins);
  spectators take the minimum of (arrival - event time). Events carry absolute match time.
- Authority: host = seat 1, serves, runs a seat-2 bot, sends FORFEIT when the guest is silent 10s or leaves. Guest
  judges only its own paddle. Receivers check who may send what (`allowed`). If the host goes silent or closes,
  everyone else applies FORFEIT for seat 1 locally.
- Throttle: our token bucket (8 burst, 0.9/s) stays under the client's (10, 1/s). Non-MOVE events go out at once;
  MOVEs batch while tokens < 4 (max 0.25s wait). A bot-vs-bot networked match uses ~1 message/s per player, right
  at the limit: check `/pong net` (throttled count) in real playtests.
- Latency costs the receiving player reaction time (the opponent's hit shows up late and the ball jumps ahead);
  that's the fair, symmetric choice. Visual smoothing of the jump is a possible polish item.

## Layout

| Path | What |
|---|---|
| `WoWPong/WoWPong.toc` | Interface 16001 (Forever build 1.60.1). SavedVariables `WoWPongDB` (log, window position, bot level) |
| `WoWPong/Core.lua` | Namespace, `ns.isSecret/show`, saved log (`ns.log`), event dispatch (`ns.on`), `/pong` dispatcher (`ns.commands`, `ns.help`), `ns.onLoaded` |
| `WoWPong/Codec.lua` | Pure event wire format (`encodeEvent`/`decodeEvent`/`normalize`/`pack`/`split`) |
| `WoWPong/Sim.lua` | The deterministic simulation (above) |
| `WoWPong/Bot.lua` | Bots: react after a delay, guess the arrival point with difficulty-based error, optional correction click, aim off-centre for angles. They emit ordinary MOVE events |
| `WoWPong/Game.lua` | The current match on this client: seats, bots, authority, match clock (`Game.clock()`), driver frame calling `Game.tick`, `Game.click`, `Game.push` (local events -> `Game.onLocalEvent`), `Game.receive` (remote) |
| `WoWPong/Net.lua` | Channel join/hide, token-bucket sending (`trySend`, queued `send`), CHAT_MSG_ADDON dispatch to `Net.handlers`, `Net.onUpdate` pump |
| `WoWPong/Table.lua` | Tables and networked matches: host/join/watch/bot/start/leave, clock sync, event batching, keepalives, timeouts and forfeits, `/pong ping` and `/pong net`, `Table.status()` for the window |
| `WoWPong/UI.lua` | The window, board, rendering, click-to-move, temp footer controls (incl. Play Now, Stop/Leave), `/pong`, `/pong practice [level]`, `/pong demo [l1] [l2]`, `/pong stop` |
| `tools/fakewow.py` | Fake WoW client (lupa) adapted from AzerothWordle: loads the real files in .toc order; `run(sec, fps)` fires OnUpdate on shown frames, `click_board(y)`, per-client `start_time`, the client's addon-message throttle |
| `tools/test_net.py` | Several fake clients through a simulated channel with latency/jitter/disconnects: codec, join + clock sync, full matches all clients agree on, 300ms latency, forfeits, host leaving/vanishing, keepalive, bot table, full table, version mismatch, ping |
| `tools/test_sim.py` | Sim + Bot unit tests, event replay, full bot matches at every level with a balance report |
| `tools/test_ui.py` | Drives the window: open/close, practice with clicks, bot win, demo to 7, stop, level cycling |

## Working on it

- **Game install:** `C:\Program Files (x86)\World of Warcraft\_classic_beta_\`. `Interface\AddOns\WoWPong` is a
  **junction** to this project's `WoWPong/`, so edits are live. `/reload` picks up Lua changes; new files need a
  full client restart.
- **Log:** `WoWPongDB.log`, written on reload/logout to `…\_classic_beta_\WTF\Account\<account>\SavedVariables\WoWPong.lua`.
  `/pong log [n]`, `/pong echo`.
- **Tests:** `pip install lupa`, then `python tools/test_sim.py`, `python tools/test_ui.py` and
  `python tools/test_net.py` (a few minutes). lupa runs Lua 5.5;
  addon code must stay Lua 5.1.
- **Forever quirks** (see `../AzerothWordle/CLAUDE.md` for the full list and the comms probe): secret values
  (guard with `ns.isSecret`), players have a surname in the realm slot of `UnitName`, identify players by GUID,
  hidden channel numbers vary (look up with `GetChannelName`), addon messages are 255 bytes and throttled (burst
  ~10, then ~1/s), max 200 locals per scope.
- Edit Lua with the file tools, not Bash heredocs (they collapse backslashes in texture paths).
