-- Gold bets on networked matches: even-money offers that someone backing the other seat takes, an honor-system
-- ledger of who owes whom, and help settling up by trade. No gold ever moves by itself (the addon can't): the ledger
-- records debts, a trade with someone you owe pre-fills the amount, and a completed trade updates the balance.
--
-- The table host referees the book. Anyone at a table may post an offer while no match is running (betting closes
-- when Play Now is pressed); a seated player may only back themselves. Messages (round = the match number the bets
-- are for, i.e. the table's matchNo + 1 while betting is open):
--   B;host;round;id;pid;name;side;copper   post an offer: <copper> on seat <side>
--   U;host;round;id;pid;name               ask to take offer <id> (backing the other seat) -> the host decides
--   N;host;round;id;pid                    poster withdraws an open offer -> the host decides
--   M;host;round;id;takerPid;takerName     host: offer taken, the bet is on
--   D;host;round;id                        host: offer withdrawn or invalid; id "*" voids the whole round's book
--                                          (seats changed hands)
--   G;host;round;winnerSeat                host: the match ended; everyone with a bet settles
-- Unmatched offers die when the match starts. If the host vanishes before G, the round's bets are void.

local _, ns = ...
local Net, Table, Game = ns.Net, ns.Table, ns.Game

local Bets = {}
ns.Bets = Bets

local PENDING_EXPIRE = 2 * 3600   -- a bet whose result never came is dropped after this long (seconds)
local LOG_KEEP = 20               -- ledger history lines kept per person

Bets.book = nil       -- the current table's book: { host, round, offers = { id -> offer }, order = { id, ... } }
Bets.myOffers = {}    -- id -> offer I posted (any table), so a take reaches me even after I've left
Bets.results = {}     -- host -> text of my last result there, for the bets panel

local counter = 0

local function me() return Net.pid() end
local function say(msg) ns.print(msg) end

local function serverTime()
    return (type(GetServerTime) == "function") and GetServerTime() or time()
end

---------------------------------------------------------------------------
-- Money
---------------------------------------------------------------------------

-- 105030 -> "10g 50s 30c"; 0 -> "0g".
function Bets.money(copper)
    copper = math.floor(math.abs(copper) + 0.5)
    local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
    local parts = {}
    if g > 0 then parts[#parts + 1] = g .. "g" end
    if s > 0 then parts[#parts + 1] = s .. "s" end
    if c > 0 then parts[#parts + 1] = c .. "c" end
    return #parts > 0 and table.concat(parts, " ") or "0g"
end

-- "10" / "2.5" (gold) or "10g 50s 3c" -> copper; nil when not a positive amount.
function Bets.parseGold(text)
    text = (text or ""):lower():gsub("%s+", "")
    if text == "" then return nil end
    local copper
    if text:match("^%d+%.?%d*$") then
        copper = math.floor(tonumber(text) * 10000 + 0.5)
    else
        local rest = text
        copper = 0
        for amount, unit in text:gmatch("(%d+)([gsc])") do
            copper = copper + tonumber(amount) * ({ g = 10000, s = 100, c = 1 })[unit]
        end
        rest = rest:gsub("%d+[gsc]", "")
        if rest ~= "" then return nil end
    end
    if not copper or copper <= 0 then return nil end
    return copper
end

---------------------------------------------------------------------------
-- Ledger (per character): pid -> { name, balance (copper; > 0 means they owe me), log }
---------------------------------------------------------------------------

function Bets.ledger()
    ns.cdb.ledger = ns.cdb.ledger or {}
    return ns.cdb.ledger
end

local function pendingList()
    ns.cdb.pendingBets = ns.cdb.pendingBets or {}
    return ns.cdb.pendingBets
end

function Bets.adjust(pid, name, delta, note)
    local l = Bets.ledger()
    local e = l[pid] or { balance = 0, log = {} }
    e.name = name or e.name or "?"
    e.balance = e.balance + delta
    table.insert(e.log, 1, { at = serverTime(), delta = delta, note = note })
    while #e.log > LOG_KEEP do table.remove(e.log) end
    l[pid] = e
end

-- Clears a balance by hand (paid by mail, forgiven, ...).
function Bets.settle(pid)
    local e = Bets.ledger()[pid]
    if not e or e.balance == 0 then return end
    Bets.adjust(pid, e.name, -e.balance, "marked settled")
end

-- People with a non-zero balance, largest first: { { pid, name, balance }, ... }.
function Bets.balances()
    local out = {}
    for pid, e in pairs(Bets.ledger()) do
        if e.balance ~= 0 then out[#out + 1] = { pid = pid, name = e.name, balance = e.balance } end
    end
    table.sort(out, function(a, b) return math.abs(a.balance) > math.abs(b.balance) end)
    return out
end

---------------------------------------------------------------------------
-- The book
---------------------------------------------------------------------------

local function live()
    return Game.match and Game.networked and Game.match.phase ~= "over"
end

-- The round bets are open for at the current table, or nil while a match is running.
function Bets.openRound()
    local t = Table.cur
    if not t or live() then return nil end
    return t.matchNo + 1
end

-- The current table's book for `round` (a newer round starts a fresh book; an older one is ignored).
local function bookFor(host, round)
    local t = Table.cur
    if not t or t.host ~= host then return nil end
    local b = Bets.book
    if not b or b.host ~= host or round > b.round then
        b = { host = host, round = round, offers = {}, order = {} }
        Bets.book = b
    end
    if round < b.round then return nil end
    return b
end

-- Seated players may only back themselves.
local function mayBack(pid, side)
    local t = Table.cur
    if not t then return false end
    for seat = 1, 2 do
        local s = t.seats[seat]
        if s and not s.bot and s.pid == pid and side ~= seat then return false end
    end
    return true
end

local function seatName(seat)
    local t = Table.cur
    local s = t and t.seats[seat]
    return s and s.name or ("Seat " .. seat)
end

local function isHost(host)
    local t = Table.cur
    return t and t.role == "host" and t.host == host
end

local function addOffer(b, o)
    if b.offers[o.id] then return end
    b.offers[o.id] = o
    b.order[#b.order + 1] = o.id
end

-- Offers of the current book in posting order.
function Bets.offers()
    local out = {}
    local b, t = Bets.book, Table.cur
    if not (b and t and b.host == t.host) then return out end
    for _, id in ipairs(b.order) do
        local o = b.offers[id]
        if o and o.status ~= "void" then out[#out + 1] = o end
    end
    return out
end

---------------------------------------------------------------------------
-- Matched bets waiting for a result, and settling them
---------------------------------------------------------------------------

local function addPending(o, iAmPoster)
    local cpPid = iAmPoster and o.takerPid or o.pid
    local cpName = iAmPoster and o.takerName or o.name
    local mySide = iAmPoster and o.side or (3 - o.side)
    local list = pendingList()
    for _, p in ipairs(list) do
        if p.id == o.id then return end
    end
    list[#list + 1] = { host = o.host, round = o.round, id = o.id, mySide = mySide, amount = o.amount,
        cpPid = cpPid, cpName = cpName, desc = o.desc, at = serverTime() }
end

-- Settles (winner = seat) or voids (winner = nil) my bets on host's round.
local function resolve(host, round, winner)
    local list = pendingList()
    local won, lost, n = 0, 0, 0
    for i = #list, 1, -1 do
        local p = list[i]
        if p.host == host and (round == nil or p.round == round) then
            table.remove(list, i)
            if winner then
                n = n + 1
                local note = Bets.money(p.amount) .. " on " .. p.desc
                if winner == p.mySide then
                    won = won + p.amount
                    Bets.adjust(p.cpPid, p.cpName, p.amount, "won " .. note)
                else
                    lost = lost + p.amount
                    Bets.adjust(p.cpPid, p.cpName, -p.amount, "lost " .. note)
                end
            end
        end
    end
    for id, o in pairs(Bets.myOffers) do
        if o.host == host and (round == nil or o.round == round) then Bets.myOffers[id] = nil end
    end
    if winner and n > 0 then
        local text
        if won > 0 and lost > 0 then
            text = string.format("You won %s and lost %s", Bets.money(won), Bets.money(lost))
        elseif won > 0 then
            text = "You won " .. Bets.money(won) .. "! Collect it from your ledger"
        else
            text = "You lost " .. Bets.money(lost) .. " - see your ledger"
        end
        Bets.results[host] = text
        ns.log("bets settled at " .. host .. " round " .. tostring(round) .. ": " .. text)
    end
end

-- Drops bets whose result never came.
local function expirePending()
    local list, now = pendingList(), serverTime()
    for i = #list, 1, -1 do
        if now - (list[i].at or now) > PENDING_EXPIRE then table.remove(list, i) end
    end
end

---------------------------------------------------------------------------
-- Actions
---------------------------------------------------------------------------

-- Why `side` can't be backed by me right now, or nil if it can.
function Bets.cantPost(side)
    local t = Table.cur
    if not t then return "not at a table" end
    if not Bets.openRound() then return "betting is closed while a match is on" end
    if not (t.seats[1] and t.seats[2]) then return "wait until both seats are filled" end
    if not mayBack(me(), side) then return "players can only bet on themselves" end
end

function Bets.post(side, copper)
    local why = Bets.cantPost(side)
    if why then
        say(why)
        return false
    end
    local t, round = Table.cur, Bets.openRound()
    counter = counter + 1
    local id = me() .. "." .. string.format("%x%x", math.random(0, 4095), counter)
    local o = { host = t.host, round = round, id = id, pid = me(), name = Net.name(), side = side, amount = copper,
        status = "open", desc = seatName(side) .. " vs " .. seatName(3 - side) }
    addOffer(bookFor(t.host, round), o)
    Bets.myOffers[id] = o
    Net.send(Net.msg("B", t.host, round, id, me(), Net.name(), side, copper))
    return true
end

-- Host: the offer is taken.
local function confirmTake(b, o, takerPid, takerName)
    o.status, o.takerPid, o.takerName = "matched", takerPid, takerName
    Net.send(Net.msg("M", b.host, b.round, o.id, takerPid, takerName))
    if o.pid == me() then addPending(o, true) end
    if takerPid == me() then addPending(o, false) end
end

-- Host: the offer is gone.
local function drop(b, id)
    local o = b.offers[id]
    if o then o.status = "void" end
    Bets.myOffers[id] = nil
    Net.send(Net.msg("D", b.host, b.round, id))
end

local function canTake(o, pid)
    return o.status == "open" and o.pid ~= pid and mayBack(pid, 3 - o.side) and Bets.openRound() == o.round
end

function Bets.take(id)
    local b = Bets.book
    local o = b and b.offers[id]
    if not o then return false end
    if not canTake(o, me()) then
        say(o.pid == me() and "that's your own offer" or "you can't take that bet")
        return false
    end
    if isHost(b.host) then
        confirmTake(b, o, me(), Net.name())
    else
        o.taking = true
        Net.send(Net.msg("U", b.host, b.round, id, me(), Net.name()))
    end
    return true
end

function Bets.withdraw(id)
    local b = Bets.book
    local o = b and b.offers[id]
    if not o or o.pid ~= me() or o.status ~= "open" then return false end
    if isHost(b.host) then
        drop(b, id)
    else
        Net.send(Net.msg("N", b.host, b.round, id, me()))
    end
    return true
end

-- Host: seats changed hands, so every bet of the open round is off.
Table.onSeatsChanged = function(t)
    local b = Bets.book
    if not b or b.host ~= t.host or b.round ~= t.matchNo + 1 or #b.order == 0 then return end
    for _, id in ipairs(b.order) do b.offers[id].status = "void" end
    resolve(t.host, b.round, nil)
    Net.send(Net.msg("D", t.host, b.round, "*"))
end

-- The host is gone before announcing a result: bets there are void.
Table.onClosed = function(host)
    resolve(host, nil, nil)
    if Bets.book and Bets.book.host == host then Bets.book = nil end
end

-- Betting closes when a match starts (unmatched offers die); the host announces the winner when it ends.
Game.listeners[#Game.listeners + 1] = function(ev)
    local t = Table.cur
    if not t or not Game.networked then return end
    if ev.type == "START" then
        local b = Bets.book
        if b and b.host == t.host and b.round == t.matchNo then
            for _, o in pairs(b.offers) do
                if o.status == "open" then o.status = "void" end
            end
        end
        for id, o in pairs(Bets.myOffers) do
            if o.host == t.host and o.round == t.matchNo and o.status ~= "matched" then Bets.myOffers[id] = nil end
        end
        Bets.results[t.host] = nil
    elseif t.role == "host" and Game.match.phase == "over" and (ev.type == "MISS" or ev.type == "FORFEIT") then
        Net.send(Net.msg("G", t.host, t.matchNo, Game.match.winner))
        resolve(t.host, t.matchNo, Game.match.winner)
    end
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

local H = Net.handlers

H.B = function(f)
    local host, round, id, pid, name = f[2], tonumber(f[3]), f[4], f[5], f[6] or "?"
    local side, copper = tonumber(f[7]), tonumber(f[8])
    if pid == me() or not (round and id and side and copper) or copper <= 0 or (side ~= 1 and side ~= 2) then
        return
    end
    local b = bookFor(host, round)
    if not b then return end
    local valid = Bets.openRound() == round and mayBack(pid, side)
    if isHost(host) and not valid then
        Net.send(Net.msg("D", host, round, id))
        return
    end
    if not valid then return end
    addOffer(b, { host = host, round = round, id = id, pid = pid, name = name, side = side, amount = copper,
        status = "open", desc = seatName(side) .. " vs " .. seatName(3 - side) })
end

H.U = function(f)
    local host, round, id, pid, name = f[2], tonumber(f[3]), f[4], f[5], f[6] or "?"
    if not isHost(host) then return end
    local b = Bets.book
    local o = b and b.round == round and b.offers[id]
    if o and canTake(o, pid) then confirmTake(b, o, pid, name) end
end

H.N = function(f)
    local host, round, id, pid = f[2], tonumber(f[3]), f[4], f[5]
    if not isHost(host) then return end
    local b = Bets.book
    local o = b and b.round == round and b.offers[id]
    if o and o.pid == pid and o.status == "open" then drop(b, id) end
end

H.M = function(f)
    local host, round, id, takerPid, takerName = f[2], tonumber(f[3]), f[4], f[5], f[6] or "?"
    if isHost(host) then return end   -- our own confirmation
    local b = Bets.book
    local o = (b and b.host == host and b.round == round and b.offers[id]) or Bets.myOffers[id]
    if not o then return end
    o.status, o.takerPid, o.takerName, o.taking = "matched", takerPid, takerName, nil
    if o.pid == me() then addPending(o, true) end
    if takerPid == me() then addPending(o, false) end
end

H.D = function(f)
    local host, round, id = f[2], tonumber(f[3]), f[4]
    if isHost(host) then return end
    local b = Bets.book
    if id == "*" then
        if b and b.host == host and b.round == round then
            for _, o in pairs(b.offers) do o.status = "void" end
        end
        resolve(host, round, nil)
        return
    end
    local o = b and b.host == host and b.offers[id]
    if o then o.status = "void" end
    Bets.myOffers[id] = nil
end

H.G = function(f)
    local host, round, winner = f[2], tonumber(f[3]), tonumber(f[4])
    if isHost(host) or not round or (winner ~= 1 and winner ~= 2) then return end
    resolve(host, round, winner)
end

---------------------------------------------------------------------------
-- Settling up by trade
---------------------------------------------------------------------------

local trade = nil   -- { pid, name, give, get } for the trade window that's open

local function tradePartner()
    local guid = UnitGUID("npc")
    if not guid or ns.isSecret(guid) then return nil end
    local name = UnitName("npc")
    return (guid:gsub("^Player%-", "")), (name and not ns.isSecret(name)) and name or "?"
end

ns.on("TRADE_SHOW", function()
    local pid, name = tradePartner()
    trade = pid and { pid = pid, name = name, give = 0, get = 0 } or nil
    local e = pid and Bets.ledger()[pid]
    if not e or e.balance == 0 then return end
    if e.balance < 0 then
        local owed = -e.balance
        local ok = ns.opt("tradeAssist") and type(SetTradeMoney) == "function" and pcall(SetTradeMoney, owed)
        say(string.format("you owe %s %s from Pong bets%s", name, Bets.money(owed),
            ok and " - it's in the trade window" or ""))
    else
        say(string.format("%s owes you %s from Pong bets", name, Bets.money(e.balance)))
    end
end)

ns.on("TRADE_ACCEPT_UPDATE", function()
    if not trade then return end
    local okG, give = pcall(GetPlayerTradeMoney)
    local okT, get = pcall(GetTargetTradeMoney)
    trade.give = (okG and tonumber(give)) or 0
    trade.get = (okT and tonumber(get)) or 0
end)

ns.on("UI_INFO_MESSAGE", function(_, message)
    if not trade or ns.isSecret(message) or message ~= ERR_TRADE_COMPLETE then return end
    local e = Bets.ledger()[trade.pid]
    local net = trade.give - trade.get   -- what I paid them
    if e and net ~= 0 then
        Bets.adjust(trade.pid, trade.name, net, (net > 0 and "paid " or "received ") .. Bets.money(net) .. " by trade")
        ns.log("ledger: trade with " .. trade.name .. " " .. net .. "c")
    end
    trade = nil
end)

table.insert(ns.onLoaded, expirePending)

---------------------------------------------------------------------------
-- Slash
---------------------------------------------------------------------------

ns.commands.ledger = function()
    local list = Bets.balances()
    if #list == 0 then say("nobody owes anybody anything") end
    for _, e in ipairs(list) do
        if e.balance > 0 then
            say(string.format("  %s owes you %s", e.name, Bets.money(e.balance)))
        else
            say(string.format("  you owe %s %s", e.name, Bets.money(-e.balance)))
        end
    end
end
table.insert(ns.help, "/pong ledger - who owes whom from bets")
