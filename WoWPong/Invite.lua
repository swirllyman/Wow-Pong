-- /pong invite [name]: challenge someone to a match. The invite travels on the lobby channel (not a whisper, whose
-- addressing on Forever is unverified), addressed by player id when you target them, else by name. Accepting seats
-- them at your table, which is opened for you if needed.
--
--   V;v;fromPid;fromName;to;host         to = "p:<pid>" or "n:<lowercase name>" (first name or "first surname")
--   A;v;fromPid;fromName;toPid;answer    answer = yes / no / busy / version

local _, ns = ...
local Net, Table, Game = ns.Net, ns.Table, ns.Game

local Invite = {}
ns.Invite = Invite

local ANSWER_WAIT = 15   -- seconds before telling the inviter there was no answer
local POPUP_WAIT = 15    -- seconds the Accept/Decline popup stays up

Invite.pending = {}      -- to-key -> { label, at }

local function say(msg) ns.print(msg) end

local function seatedInMatch()
    return Game.match and Game.networked and Game.match.phase ~= "over" and Table.mySeat() ~= nil
end

local function addressedToMe(to)
    if to == "p:" .. Net.pid() then return true end
    local name = to:match("^n:(.+)$")
    return name ~= nil and (name == Net.name():lower() or name == Net.fullName():lower())
end

function Invite.send(arg)
    local key, label
    if arg == "" then
        if not (UnitExists and UnitExists("target") and UnitIsPlayer("target")) then
            say("usage: /pong invite <name>, or target a player and type /pong invite")
            return
        end
        local guid = UnitGUID("target")
        if not guid or ns.isSecret(guid) then
            say("can't read your target; try /pong invite <name>")
            return
        end
        key = "p:" .. guid:gsub("^Player%-", "")
        label = ns.show((UnitName("target")))
    else
        key = "n:" .. arg:lower():gsub("[;|]", "")
        label = arg
    end
    if seatedInMatch() then
        say("finish your match first")
        return
    end
    local t = Table.cur
    if not t or t.role ~= "host" then
        Table.host()
        t = Table.cur
    elseif t.seats[2] and not t.seats[2].bot then
        say("your table is full")
        return
    end
    Invite.pending[key] = { label = label, at = GetTime() }
    Net.send(Net.msg("V", Net.VERSION, Net.pid(), Net.name(), key, t.host))
    say("invited " .. label .. " - waiting for an answer...")
    C_Timer.After(ANSWER_WAIT, function()
        local p = Invite.pending[key]
        if p and GetTime() - p.at >= ANSWER_WAIT - 0.01 then
            Invite.pending[key] = nil
            say(label .. " didn't answer (maybe they don't have WoW Pong)")
        end
    end)
end

local function answer(toPid, reply)
    Net.send(Net.msg("A", Net.VERSION, Net.pid(), Net.fullName(), toPid, reply))
end

-- Seats us at the inviter's table once we know it (its announcement may still be on the way).
local function sitAt(host, tries)
    local info = Table.known[host]
    if info then
        Table.sit(info)
        if ns._ui then ns._ui.show() end
    elseif tries > 0 then
        Table.refresh(true)
        C_Timer.After(2.5, function() sitAt(host, tries - 1) end)
    else
        say("couldn't find their table")
    end
end

-- Whether a player id is on our friends list, in our guild or a Battle.net friend's character (the "friends &
-- guild only" invite option). Each API is optional and pcalled; unknown counts as a stranger.
local function asks(fn, ...)
    if type(fn) ~= "function" then return false end
    local ok, r = pcall(fn, ...)
    return ok and r and not ns.isSecret(r) and true or false
end

function Invite.isFriend(pid)
    local guid = "Player-" .. pid
    return asks(C_FriendList and C_FriendList.IsFriend, guid)
        or asks(IsGuildMember, guid)
        or asks(C_BattleNet and C_BattleNet.GetAccountInfoByGUID, guid)
end

local H = Net.handlers

H.V = function(f)
    local fromPid, fromName, to, host = f[3], f[4] or "?", f[5] or "", f[6]
    if fromPid == Net.pid() or not addressedToMe(to) then return end
    if tonumber(f[2]) ~= Net.VERSION then
        answer(fromPid, "version")
        return
    end
    if seatedInMatch() then
        answer(fromPid, "busy")
        return
    end
    local mode = ns.opt("invites")
    if mode == "none" or (mode == "friends" and not Invite.isFriend(fromPid)) then
        ns.log("invite from " .. fromName .. " declined automatically (" .. mode .. ")")
        answer(fromPid, "no")
        return
    end
    ns.log("invite from " .. fromName)
    local ui = ns._ui
    if not ui then return end
    ui.showInvite(fromName .. " challenges you to Pong!", POPUP_WAIT, function()
        answer(fromPid, "yes")
        sitAt(host, 2)
    end, function()
        answer(fromPid, "no")
    end)
end

H.A = function(f)
    if f[5] ~= Net.pid() then return end
    local pid, name, reply = f[3], f[4] or "?", f[6]
    local first = name:match("^(%S+)") or name
    local key
    for _, k in ipairs({ "p:" .. pid, "n:" .. name:lower(), "n:" .. first:lower() }) do
        if Invite.pending[k] then key = k break end
    end
    if not key then return end
    Invite.pending[key] = nil
    local label = name   -- their own spelling, surname included
    if reply == "yes" then
        say(label .. " accepted!")
    elseif reply == "busy" then
        say(label .. " is in a match right now")
    elseif reply == "version" then
        say(label .. " has a different WoW Pong version")
    else
        say(label .. " declined")
    end
end

ns.commands.invite = function(arg) Invite.send(arg) end
table.insert(ns.help, "/pong invite [name] - challenge someone (or your target) to a match")
