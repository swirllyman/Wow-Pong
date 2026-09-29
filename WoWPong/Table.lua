-- Tables: networked play over the lobby channel. A host opens a table and sits in seat 1; one guest (or a bot run
-- by the host) takes seat 2; anyone can watch. Everything travels on the channel, so spectators just listen.
--
-- Messages (fields after the type; pids are Net.pid() ids, "v" is Net.VERSION):
--   Q;v                                    who's hosting? hosts answer with T
--   T;v;host;hostName;s1pid;s1name;s2pid;s2name;state;score1;score2;matchNo;points
--                                          table state (s2pid "bot:<level>" for a bot, "" when free; state is
--                                          open / ready / playing / over; points: first to this many, the match
--                                          being played or else the next one). Sent on changes, each point, every 30s
--   J;v;host;pid;name                      ask to sit in seat 2
--   L;host;pid                             leave the table (a player leaving mid-match forfeits)
--   X;host                                 host closed the table
--   C;host;pid;guestTime                   guest clock ping -> host answers c;host;pid;guestTime;hostTime
--   Y;host;pid                             guest's clock is synced; ready to play
--   R;host;pid                             guest pressed Play Now
--   K;host;pid                             keepalive while nothing else was sent for a while
--   E;host;matchNo;from;seq;ev|ev|...      match events (Codec)
--   W;host;pid                             a spectator arrived mid-match and wants a snapshot
--   Z;host;matchNo;hostSeq;guestPid;guestSeq;hostTime;<snapshot>
--                                          the match as the host has it (Codec.encodeSnapshot), plus the last
--                                          E seq it holds from each player, so the spectator skips repeats
--   I;v;pid;name;nonce / O;pid;name;nonce;v;to     /pong ping diagnostic and its answers
--
-- Match time is the host's GetTime() minus the table's epoch. The guest measures its offset with C/c pings
-- (keeping the lowest round trip); spectators estimate it from how late events arrive.

local _, ns = ...
local Net, Codec, Game, Sim, Bot = ns.Net, ns.Codec, ns.Game, ns.Sim, ns.Bot

local Table = {}
ns.Table = Table

local TIMEOUT = 10          -- seconds of silence before a player counts as gone (forfeit)
local KEEPALIVE = 3         -- send K after this long without sending anything
local SYNC_PINGS, SYNC_GAP, SYNC_WAIT = 3, 0.4, 4
local MOVE_BATCH_AGE = 0.25 -- a lone MOVE waits at most this long for company when tokens are low
local TOKEN_RESERVE = 4     -- below this many tokens, MOVEs are batched instead of sent at once
local URGENT_RESERVE = 1    -- tokens a MOVE-only batch leaves for the next HIT/MISS/SERVE
local ROOM = Net.MAX_BYTES - 40
local ANNOUNCE_EVERY = 30   -- hosts re-send T this often so lobby lists stay fresh
local EXPIRE = 75           -- a table not announced for this long drops off the list
local IDLE_CLOSE = 600      -- a table with no match for this long closes itself
local QUERY_GAP = 15        -- min seconds between our Q requests
local ANSWER_GAP = 5        -- hosts don't answer a Q if they announced this recently
local SNAPSHOT_GAP = 2      -- hosts send at most one snapshot this often (one serves every waiting spectator)
local SNAPSHOT_RETRY, SNAPSHOT_TRIES = 6, 3

Table.known = {}   -- host pid -> table info from T messages
Table.cur = nil    -- the table this client is at

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function me() return Net.pid() end

local function say(msg) ns.print(msg) end

local function live()
    return Game.match and Game.networked and Game.match.phase ~= "over"
end

local function seatName(s)
    return s and s.name or ""
end

local function seatPid(s)
    if not s then return "" end
    if s.bot then return "bot:" .. s.bot end
    return s.pid
end

local function parseSeat(pid, name)
    if pid == nil or pid == "" then return nil end
    local level = pid:match("^bot:(%a+)$")
    if level then return { pid = pid, bot = Bot.PROFILES[level] and level or "normal", name = name } end
    return { pid = pid, name = name }
end

local function heard(t, pid, now)
    if t and pid then t.lastHeard[pid] = now end
end

local function newTable(role, host, hostName)
    return { role = role, host = host, hostName = hostName, seats = {}, matchNo = 0, lastHeard = {},
        seq = 0, lastSeq = {}, pending = {}, pendingSince = nil, buffer = {} }
end

function Table.mySeat()
    local t = Table.cur
    if not t then return nil end
    for seat = 1, 2 do
        if t.seats[seat] and t.seats[seat].pid == me() then return seat end
    end
end

---------------------------------------------------------------------------
-- Announcing (host)
---------------------------------------------------------------------------

local function tableState(t)
    local m = Game.networked and Game.match
    if m and m.phase ~= "over" then return "playing", m end
    if m then return "over", m end
    return t.seats[2] and "ready" or "open", nil
end

-- Points to win at this table: the match in progress, or else the host's setting for the next one.
function Table.points()
    local t = Table.cur
    if not t then return nil end
    local m = Game.networked and Game.match
    if m and m.phase ~= "over" then return m.pointsToWin end
    if t.role == "host" then return ns.opt("points") end
    return t.points or Sim.POINTS_TO_WIN
end

local function announce()
    local t = Table.cur
    if not t or t.role ~= "host" then return end
    local state, m = tableState(t)
    Net.sendLow(Net.msg("T", Net.VERSION, t.host, t.hostName, seatPid(t.seats[1]), seatName(t.seats[1]),
        seatPid(t.seats[2]), seatName(t.seats[2]), state, m and m.score[1] or 0, m and m.score[2] or 0,
        t.matchNo, Table.points()), "T")
    t.lastAnnounce = GetTime()
    t.announceAt = nil
end

-- Announces within a second, folding several quick changes into one message.
local function announceSoon()
    local t = Table.cur
    if t and t.role == "host" and not t.announceAt then t.announceAt = GetTime() + 1 end
end

---------------------------------------------------------------------------
-- Matches
---------------------------------------------------------------------------

local function beginMatch(t, matchNo)
    t.matchNo = matchNo
    t.seq = 0
    t.lastSeq = {}
    t.pending = {}
    t.buffer = {}
    local mySeat = Table.mySeat()
    local s1, s2 = t.seats[1], t.seats[2]
    local host = t.role == "host"
    local bots
    if host then
        bots = {}
        if s1 and s1.bot then bots[1] = s1.bot end
        if s2 and s2.bot then bots[2] = s2.bot end
    end
    local opponent
    local other = mySeat and t.seats[3 - mySeat]
    if other and other.bot then
        opponent = { kind = "bot", level = other.bot }
    elseif other then
        opponent = { kind = "human", pid = other.pid, name = other.name }
    end
    Game.begin({
        opponent = opponent,
        names = { seatName(s1), seatName(s2) },
        seats = { host, (host and s2 and s2.bot ~= nil) or (mySeat == 2) },
        host = host,
        humanSeat = mySeat,
        bots = bots,
        base = t.base,
        networked = true,
    })
end

-- Players can start; so can the host while a bot sits in its seat (it referees a bot match).
function Table.canStart()
    local t = Table.cur
    if not t or live() then return false end
    local s2 = t.seats[2]
    if not (t.seats[1] and s2) then return false end
    if t.role == "host" then return s2.bot ~= nil or t.guestReady == true end
    return Table.mySeat() ~= nil and t.synced == true
end

-- Seat occupants changed (someone joined/left, a bot was added/removed/swapped in). Bets.lua voids the book.
local function seatsChanged(t)
    if Table.onSeatsChanged then Table.onSeatsChanged(t) end
end

-- Play Now: the host starts right away; a guest asks the host.
function Table.start()
    local t = Table.cur
    if not Table.canStart() then
        if t and t.role == "guest" and not t.synced then say("still syncing with the host...") end
        return false
    end
    if t.role == "host" then
        beginMatch(t, t.matchNo + 1)
        Game.push({ type = "START", t = Game.clock(), win = ns.opt("points") })
        ns.log("net match " .. t.matchNo .. ": " .. Game.names[1] .. " vs " .. Game.names[2])
    else
        Net.send(Net.msg("R", t.host, me()))
    end
    return true
end

-- Hosts re-announce when the score or match state changes, and track idleness.
Game.listeners[#Game.listeners + 1] = function(ev)
    local t = Table.cur
    if not t or t.role ~= "host" or not Game.networked then return end
    if ev.type == "START" or ev.type == "MISS" or ev.type == "FORFEIT" then announceSoon() end
    if ev.type == "START" or Game.match.phase == "over" then t.idleSince = GetTime() end
end

-- The host changing the match length re-announces the table (a match in progress keeps its own).
table.insert(ns.Options.listeners, function(key)
    if key == "points" or key == nil then announceSoon() end
end)

-- Local events of a networked match wait here until the send policy lets them out.
Game.onLocalEvent = function(ev)
    local t = Table.cur
    if not t then return end
    t.pending[#t.pending + 1] = Codec.encodeEvent(ev)
    t.pendingSince = t.pendingSince or GetTime()
end

local function flushEvents(t, now)
    if #t.pending == 0 then return end
    local urgent = false
    for _, e in ipairs(t.pending) do
        if e:sub(1, 1) ~= "M" then urgent = true break end
    end
    if not urgent then
        -- MOVEs never take the last token: a HIT/MISS/SERVE waiting a second for one is what the other side
        -- feels as lag (and the MOVEs ride along with it anyway).
        if Net.tokens() < URGENT_RESERVE + 1 then return end
        if Net.tokens() < TOKEN_RESERVE and now - t.pendingSince < MOVE_BATCH_AGE then return end
    end
    for _, body in ipairs(Codec.pack(t.pending, ROOM)) do
        local text = Net.msg("E", t.host, t.matchNo, me(), t.seq + 1, body)
        if not Net.trySend(text) then break end
        t.seq = t.seq + 1
        local n = select(2, body:gsub("|", "")) + 1
        for _ = 1, n do table.remove(t.pending, 1) end
    end
    t.pendingSince = (#t.pending > 0) and now or nil
end

-- Whether `from` may send this event: the host speaks for seat 1, a host-run bot, and match control;
-- the guest only for its own paddle.
local function allowed(t, from, ev)
    local own = ev.type == "MOVE" or ev.type == "HIT" or ev.type == "MISS"
    if from == t.host then
        if own and ev.seat == 2 then return t.seats[2] ~= nil and t.seats[2].bot ~= nil end
        return true
    end
    local s2 = t.seats[2]
    return s2 ~= nil and s2.pid == from and own and ev.seat == 2
end

-- Forfeit for a seat whose player vanished. The host broadcasts it; others apply it locally when the host itself
-- is the one gone.
local function forfeit(t, seat, why)
    if not live() then return end
    ns.log("forfeit seat " .. seat .. ": " .. why)
    if t.role == "host" then
        Game.push({ type = "FORFEIT", t = Game.clock(), seat = seat })
    else
        Game.receive({ type = "FORFEIT", t = Game.clock(), seat = seat })
    end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

function Table.host()
    Table.leave(true)
    Game.stop()
    local t = newTable("host", me(), Net.name())
    t.epoch = GetTime()
    t.base = t.epoch
    t.seats[1] = { pid = me(), name = Net.name() }
    t.idleSince = GetTime()
    Table.cur = t
    announce()
    ns.log("hosting table")
end

function Table.addBot(level)
    local t = Table.cur
    if not t or t.role ~= "host" then
        say("host a table first (/pong host)")
        return
    end
    if live() then return end
    if t.seats[2] and not t.seats[2].bot then
        say(t.seats[2].name .. " is in seat 2")
        return
    end
    level = Bot.PROFILES[level or ""] and level or ns.db.level or "normal"
    t.seats[2] = { pid = "bot:" .. level, bot = level, name = "Bot (" .. Bot.NAMES[level] .. ")" }
    if Game.networked then Game.stop() end   -- the old result belongs to the previous opponent
    seatsChanged(t)
    announce()
end

function Table.removeBot()
    local t = Table.cur
    if not t or t.role ~= "host" or live() or not (t.seats[2] and t.seats[2].bot) then return end
    t.seats[2] = nil
    if Game.networked then Game.stop() end
    seatsChanged(t)
    announce()
end

-- Host: hand seat 1 to a bot (and referee a bot match), or take it back.
function Table.hostSeatBot(level)
    local t = Table.cur
    if not t or t.role ~= "host" or live() then return end
    level = Bot.PROFILES[level or ""] and level or ns.db.level or "normal"
    t.seats[1] = { pid = "bot:" .. level, bot = level, name = "Bot (" .. Bot.NAMES[level] .. ")" }
    if Game.networked then Game.stop() end
    seatsChanged(t)
    announce()
end

function Table.hostSit()
    local t = Table.cur
    if not t or t.role ~= "host" or live() or not (t.seats[1] and t.seats[1].bot) then return end
    t.seats[1] = { pid = me(), name = Net.name() }
    if Game.networked then Game.stop() end
    seatsChanged(t)
    announce()
end

-- Tables heard from recently, sorted by host name.
function Table.list()
    local now, out = GetTime(), {}
    for host, info in pairs(Table.known) do
        if now - info.heardAt > EXPIRE then
            Table.known[host] = nil
        else
            out[#out + 1] = info
        end
    end
    table.sort(out, function(a, b) return a.hostName:lower() < b.hostName:lower() end)
    return out
end

-- Asks hosts to announce (at most every QUERY_GAP seconds), e.g. when the lobby opens.
function Table.refresh(force)
    local now = GetTime()
    if not force and Table.lastQuery and now - Table.lastQuery < QUERY_GAP then return end
    if Net.channelId() == 0 then return end
    Table.lastQuery = now
    Net.sendLow(Net.msg("Q", Net.VERSION), "Q")
end

-- Whether a lobby row's seat 2 can be taken: free, or a bot between matches.
function Table.canSit(info)
    local s2 = info.seats[2]
    return info.version == Net.VERSION and (not s2 or (s2.bot ~= nil and info.state ~= "playing"))
end

local function findTable(name)
    name = (name or ""):lower()
    for _, info in ipairs(Table.list()) do
        if info.hostName:lower() == name then return info end
    end
end

local function afterLookup(name, fn)
    local info = findTable(name)
    if info then return fn(info) end
    Table.refresh(true)
    say("looking for " .. name .. "'s table...")
    C_Timer.After(2.5, function()
        info = findTable(name)
        if info then fn(info) else say("no table hosted by " .. name .. " found") end
    end)
end

local function adopt(info, role)
    local t = newTable(role, info.host, info.hostName)
    t.seats = { info.seats[1], info.seats[2] }
    t.points = info.points
    -- Between matches, carry on the host's match count (bets are for matchNo + 1). Mid-match, the snapshot or the
    -- next START sets it.
    if info.state ~= "playing" and info.state ~= "over" then t.matchNo = info.matchNo or 0 end
    t.lastHeard[info.host] = GetTime()
    return t
end

-- Sit in seat 2 of a table from the list.
function Table.sit(info)
    if info.version ~= Net.VERSION then
        say(info.hostName .. " runs a different WoW Pong version; update both to play")
        return
    end
    Table.leave(true)
    Game.stop()
    Table.cur = adopt(info, "guest")
    Net.send(Net.msg("J", Net.VERSION, info.host, me(), Net.name()))
end

-- Asks the host for a snapshot of the match in progress (retried a couple of times).
function Table.requestSnapshot(t)
    if t.snapGaveUp then return end
    t.awaiting = true
    t.snapTries = (t.snapTries or 0) + 1
    Net.send(Net.msg("W", t.host, me()))
    C_Timer.After(SNAPSHOT_RETRY, function()
        if Table.cur ~= t or not t.awaiting then return end
        if t.snapTries < SNAPSHOT_TRIES then
            Table.requestSnapshot(t)
        else
            t.awaiting, t.snapGaveUp = false, true
            ns.log("no snapshot from " .. t.hostName .. "; waiting for the next match")
        end
    end)
end

function Table.spectate(info)
    Table.leave(true)
    Game.stop()
    local t = adopt(info, "spectator")
    Table.cur = t
    if info.state == "playing" or info.state == "over" then Table.requestSnapshot(t) end
end

function Table.join(name)
    if name == "" then
        say("usage: /pong join <host name>")
        return
    end
    afterLookup(name, Table.sit)
end

function Table.watch(name)
    if name == "" then
        say("usage: /pong watch <host name>")
        return
    end
    afterLookup(name, Table.spectate)
end

-- quiet = true when leaving because we're switching tables (no chat message).
function Table.leave(quiet)
    local t = Table.cur
    if not t then return end
    if t.role == "host" then
        if live() then Game.push({ type = "FORFEIT", t = Game.clock(), seat = 1 }) end
        flushEvents(t, math.huge)
        Net.send(Net.msg("X", t.host))
        if Table.onClosed then Table.onClosed(t.host) end
    elseif t.role == "guest" then
        -- Leaving mid-match forfeits: the host announces it; record it here too.
        if live() and Table.mySeat() then
            Game.receive({ type = "FORFEIT", t = Game.clock(), seat = Table.mySeat() })
        end
        Net.send(Net.msg("L", t.host, me()))
    end
    if Game.networked then Game.stop() end
    Table.cur = nil
    if not quiet then say("left the table") end
end

---------------------------------------------------------------------------
-- Clock sync (guest)
---------------------------------------------------------------------------

local function finishSync(t)
    t.synced = true
    Net.send(Net.msg("Y", t.host, me()))
    ns.log(string.format("clock synced with %s, round trip %.3fs", t.hostName, t.bestRtt))
end

local function startSync(t)
    t.syncing, t.synced, t.bestRtt, t.replies = true, false, nil, 0
    for i = 0, SYNC_PINGS - 1 do
        C_Timer.After(i * SYNC_GAP, function()
            if Table.cur == t then Net.send(Net.msg("C", t.host, me(), string.format("%.3f", GetTime()))) end
        end)
    end
    C_Timer.After(SYNC_WAIT, function()
        if Table.cur ~= t or t.synced then return end
        if t.bestRtt then
            finishSync(t)
        else
            say("no reply from the host; leaving the table")
            Table.leave(true)
        end
    end)
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local H = Net.handlers

H.Q = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "host" then return end
    if t.lastAnnounce and now - t.lastAnnounce < ANSWER_GAP then return end
    C_Timer.After(math.random() * 1.5, function()
        if Table.cur == t and not (t.lastAnnounce and GetTime() - t.lastAnnounce < ANSWER_GAP) then announce() end
    end)
end

H.T = function(f, now)
    local host = f[3]
    if host == me() then return end
    local info = { version = tonumber(f[2]), host = host, hostName = f[4] or "?",
        seats = { parseSeat(f[5], f[6]), parseSeat(f[7], f[8]) }, heardAt = now,
        state = f[9] or "open", score = { tonumber(f[10]) or 0, tonumber(f[11]) or 0 },
        matchNo = tonumber(f[12]) or 0, points = tonumber(f[13]) or Sim.POINTS_TO_WIN }
    local new = Table.known[host] == nil
    Table.known[host] = info
    if new and Table.onTableSeen then Table.onTableSeen(info, now) end
    local t = Table.cur
    if not t or t.host ~= host or t.role == "host" then return end
    heard(t, host, now)
    t.seats = info.seats
    t.points = info.points
    if t.role == "guest" then
        local s2 = t.seats[2]
        if s2 and s2.pid == me() then
            if not t.syncing then startSync(t) end
        elseif not live() then
            say(t.hostName .. "'s table is full; watching instead")
            t.role = "spectator"
        end
    end
end

H.X = function(f)
    Table.known[f[2]] = nil
    if Table.onClosed then Table.onClosed(f[2]) end
    local t = Table.cur
    if not t or t.host ~= f[2] or t.role == "host" then return end
    forfeit(t, 1, "host closed the table")
    say(t.hostName .. " closed the table")
    Table.cur = nil
end

H.J = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "host" or f[3] ~= t.host then return end
    local pid, name = f[4], f[5]
    if tonumber(f[2]) ~= Net.VERSION then return end
    local s2 = t.seats[2]
    if s2 and s2.pid ~= pid and not (s2.bot and not live()) then
        announce()   -- they'll see the seat is taken
        return
    end
    local changed = not (s2 and s2.pid == pid)
    if changed and Game.networked and not live() then Game.stop() end   -- new opponent
    t.seats[2] = { pid = pid, name = name }
    t.guestReady = false
    heard(t, pid, now)
    if changed then seatsChanged(t) end
    announce()
    say(name .. " joined your table")
    if changed and Table.onGuestJoined then Table.onGuestJoined(t) end
end

H.L = function(f)
    local t = Table.cur
    if not t or t.role ~= "host" or f[2] ~= t.host then return end
    local s2 = t.seats[2]
    if not s2 or s2.pid ~= f[3] then return end
    forfeit(t, 2, s2.name .. " left")
    t.seats[2] = nil
    seatsChanged(t)
    announce()
    say(s2.name .. " left your table")
end

H.C = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "host" or f[2] ~= t.host then return end
    heard(t, f[3], now)
    local reply = Net.msg("c", t.host, f[3], f[4], string.format("%.3f", GetTime() - t.epoch))
    if not Net.trySend(reply) then Net.send(reply, true) end
end

H.c = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "guest" or f[2] ~= t.host or f[3] ~= me() then return end
    heard(t, t.host, now)
    local sent, hostTime = tonumber(f[4]), tonumber(f[5])
    if not sent or not hostTime then return end
    local rtt = now - sent
    if not t.bestRtt or rtt < t.bestRtt then
        t.bestRtt = rtt
        t.base = now - (hostTime + rtt / 2)
    end
    t.replies = t.replies + 1
    if t.replies >= SYNC_PINGS and not t.synced then finishSync(t) end
end

H.Y = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "host" or f[2] ~= t.host then return end
    if t.seats[2] and t.seats[2].pid == f[3] then
        t.guestReady = true
        heard(t, f[3], now)
    end
end

H.R = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "host" or f[2] ~= t.host then return end
    if t.seats[2] and t.seats[2].pid == f[3] then
        heard(t, f[3], now)
        t.guestReady = true
        Table.start()
    end
end

H.K = function(f, now)
    local t = Table.cur
    if t and t.host == f[2] then heard(t, f[3], now) end
end

-- Applies one E message's events, skipping repeats of what a snapshot already covered.
local function applyStream(t, from, seq, events)
    local last = t.lastSeq[from]
    if last and seq <= last then return end
    if last and seq ~= last + 1 then ns.log(string.format("net: %s seq gap %d -> %d", from, last, seq)) end
    t.lastSeq[from] = seq
    for _, ev in ipairs(events) do Game.receive(ev) end
end

H.E = function(f, now)
    local t = Table.cur
    local from = f[4]
    if not t or t.host ~= f[2] or from == me() then return end
    heard(t, from, now)
    local matchNo, seq = tonumber(f[3]), tonumber(f[5])
    if not matchNo or not seq then return end
    local events = {}
    for s in (f[6] or ""):gmatch("[^|]+") do
        local ev = Codec.decodeEvent(s)
        if ev and allowed(t, from, ev) then events[#events + 1] = ev end
    end
    if #events == 0 then return end

    if t.role == "spectator" then
        -- Estimate the host clock from the earliest-looking arrival.
        for _, ev in ipairs(events) do
            local b = now - ev.t
            if not t.base or b < t.base then t.base = b end
        end
        if Game.networked then Game.base = t.base end
    end

    if matchNo > t.matchNo then
        if events[1].type ~= "START" then
            -- Arrived mid-match: keep these until the host's snapshot says where the match stands.
            if t.role == "spectator" then
                t.buffer[#t.buffer + 1] = { matchNo = matchNo, from = from, seq = seq, events = events }
                if not t.awaiting then Table.requestSnapshot(t) end
            end
            return
        end
        t.awaiting = false
        beginMatch(t, matchNo)
    elseif matchNo < t.matchNo or not Game.networked then
        return
    end
    applyStream(t, from, seq, events)
end

H.W = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "host" or f[2] ~= t.host then return end
    -- A retry that crossed the snapshot we just sent is already answered.
    if t.lastSnapshot and now - t.lastSnapshot < SNAPSHOT_RETRY / 2 then return end
    if Game.networked and Game.match then t.snapshotWanted = true end
end

-- Host: one snapshot answers every spectator waiting. During a match the send budget is always nearly spent, so
-- the snapshot jumps the queue: our unsent events are sealed into numbered E messages placed right before it, and
-- the snapshot's seq tells spectators to skip everything up to and including them.
local function sendSnapshot(t, now)
    if not t.snapshotWanted or now - (t.lastSnapshot or -1e9) < SNAPSHOT_GAP then return end
    t.snapshotWanted = false
    if not (Game.networked and Game.match) then return end
    local out = {}
    for _, body in ipairs(Codec.pack(t.pending, ROOM)) do
        t.seq = t.seq + 1
        out[#out + 1] = Net.msg("E", t.host, t.matchNo, me(), t.seq, body)
    end
    t.pending, t.pendingSince = {}, nil
    local s2 = t.seats[2]
    local guest = (s2 and not s2.bot) and s2.pid or ""
    out[#out + 1] = Net.msg("Z", t.host, t.matchNo, t.seq, guest, guest ~= "" and (t.lastSeq[guest] or 0) or 0,
        Codec.num(Game.clock(), 3), Codec.encodeSnapshot(Game.match))
    Net.sendFirst(out)
    t.lastSnapshot = now
end

H.Z = function(f, now)
    local t = Table.cur
    if not t or t.role ~= "spectator" or f[2] ~= t.host or not t.awaiting then return end
    local matchNo, hostSeq, guestSeq, hostTime = tonumber(f[3]), tonumber(f[4]), tonumber(f[6]), tonumber(f[7])
    local snap = f[8] and Codec.decodeSnapshot(f[8])
    if not (matchNo and hostSeq and guestSeq and hostTime and snap) or matchNo < t.matchNo then return end
    heard(t, t.host, now)
    local b = now - hostTime
    if not t.base or b < t.base then t.base = b end
    local buffered = t.buffer
    beginMatch(t, matchNo)
    Sim.restore(Game.match, snap)
    t.lastSeq[t.host] = hostSeq
    if f[5] ~= "" then t.lastSeq[f[5]] = guestSeq end
    t.awaiting = false
    for _, item in ipairs(buffered) do
        if item.matchNo == matchNo then applyStream(t, item.from, item.seq, item.events) end
    end
    ns.log("caught up with " .. t.hostName .. "'s match " .. matchNo .. " from a snapshot")
end

-- /pong ping diagnostic
local pingSent = {}   -- nonce -> GetTime()
H.I = function(f, now)
    if f[3] == me() then return end
    ns.log("ping from " .. (f[4] or "?") .. " (v" .. (f[2] or "?") .. ")")
    Net.send(Net.msg("O", me(), Net.name(), f[5], Net.VERSION, f[3]), true)
end
H.O = function(f, now)
    if f[6] ~= me() then return end
    local sent = pingSent[f[4]]
    local rtt = sent and string.format("%.2fs", now - sent) or "?"
    ns.log("pong from " .. (f[3] or "?") .. " (v" .. (f[5] or "?") .. ") in " .. rtt, true)
end

function Table.ping()
    local nonce = string.format("%04x", math.random(0, 65535))
    pingSent[nonce] = GetTime()
    if Net.channelId() == 0 then say("not in the WoW Pong channel yet; try again in a few seconds") return end
    Net.send(Net.msg("I", Net.VERSION, me(), Net.name(), nonce))
    say("ping sent on the WoW Pong channel; replies show up here (see /pong log)")
end

---------------------------------------------------------------------------
-- Per-frame upkeep: send events, keepalives, timeouts
---------------------------------------------------------------------------

Net.onUpdate = function(now)
    local t = Table.cur
    if not t then return end
    flushEvents(t, now)
    local seated = t.role == "host" or Table.mySeat() ~= nil
    if seated and Net.idleFor() >= KEEPALIVE and Net.queued() == 0 then
        Net.sendLow(Net.msg("K", t.host, me()), "K")
    end
    if t.role == "host" then
        local s2 = t.seats[2]
        if s2 and not s2.bot and now - (t.lastHeard[s2.pid] or now) > TIMEOUT then
            forfeit(t, 2, s2.name .. " went quiet")
            say(s2.name .. " disconnected")
            t.seats[2] = nil
            seatsChanged(t)
            announce()
        end
        if not live() and now - t.idleSince > IDLE_CLOSE then
            Table.leave(true)
            say("your table closed after " .. math.floor(IDLE_CLOSE / 60) .. " minutes without a match")
            return
        end
        if (t.announceAt and now >= t.announceAt) or now - (t.lastAnnounce or 0) >= ANNOUNCE_EVERY then
            announce()
        end
        sendSnapshot(t, now)
    elseif now - (t.lastHeard[t.host] or now) > TIMEOUT then
        forfeit(t, 1, "host went quiet")
        say(t.hostName .. "'s table is gone (no word for " .. TIMEOUT .. "s)")
        Table.cur = nil
        if Table.onClosed then Table.onClosed(t.host) end
    end
end

---------------------------------------------------------------------------
-- Status for the window
---------------------------------------------------------------------------

-- Header names and a status line while no networked match is being played.
function Table.status()
    local t = Table.cur
    if not t then return nil end
    local s2 = t.seats[2]
    if t.role == "host" then
        if not s2 then return "Waiting for an opponent", "Anyone can sit down from the lobby, or add a bot" end
        if not s2.bot and not t.guestReady then return "Syncing with " .. s2.name .. "...", "" end
        return "Ready", "Press Play Now"
    elseif t.role == "guest" then
        if not t.synced then return "Joining " .. t.hostName .. "'s table...", "" end
        return "Ready", "Press Play Now"
    end
    if t.awaiting then return "Watching " .. t.hostName .. "'s table", "Catching up with the match..." end
    return "Watching " .. t.hostName .. "'s table", "Waiting for the next match"
end

function Table.names()
    local t = Table.cur
    if not t then return nil end
    return seatName(t.seats[1]), seatName(t.seats[2])
end

-- One-line summary of a listed table's state, e.g. "Playing 3-2 (to 5)" or "Open seat, first to 7".
function Table.describe(info)
    local s, points = info.score, info.points or Sim.POINTS_TO_WIN
    if info.state == "playing" then return string.format("Playing %d-%d (to %d)", s[1], s[2], points) end
    local state = "Open seat"
    if info.state == "over" then
        state = string.format("Finished %d-%d", s[1], s[2])
    elseif info.state == "ready" then
        state = "Ready"
    end
    return string.format("%s, first to %d", state, points)
end

local function printList()
    local list = Table.list()
    for _, info in ipairs(list) do
        local s2 = info.seats[2]
        say(string.format("  %s's table: %s vs %s - %s", info.hostName, seatName(info.seats[1]),
            s2 and s2.name or "(open)", Table.describe(info)))
    end
    if #list == 0 then say("no tables seen yet") end
    Table.refresh(true)
end

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------

ns.commands.host = function() Table.host() end
ns.commands.join = function(arg) Table.join(arg) end
ns.commands.watch = function(arg) Table.watch(arg) end
ns.commands.bot = function(arg) Table.addBot(arg:lower()) end
ns.commands.start = function() Table.start() end
ns.commands.leave = function() Table.leave() end
ns.commands.tables = function() printList() end
ns.commands.ping = function() Table.ping() end
ns.commands.net = function()
    local s = Net.stats
    say(string.format("channel #%d, sent %d, received %d, throttled %d, failed %d, queued %d, tokens %.1f",
        Net.channelId(), s.sent, s.received, s.throttled, s.failed, Net.queued(), Net.tokens()))
end
table.insert(ns.help, "/pong host - open a table (you take seat 1)")
table.insert(ns.help, "/pong join <name> - sit at <name>'s table; /pong watch <name> - spectate it")
table.insert(ns.help, "/pong bot [level] - (host) put a bot in seat 2")
table.insert(ns.help, "/pong start - Play Now; /pong leave - leave the table")
table.insert(ns.help, "/pong tables - list tables; /pong ping - check who can hear you; /pong net - stats")
