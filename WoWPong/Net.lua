-- Transport: the hidden lobby channel, a throttle-aware send queue, and dispatch of received messages by type.
-- Knows nothing about tables or matches; Table.lua registers handlers in Net.handlers.
--
-- Every message is "<type>;<field>;...". Addon messages are 255 bytes max and throttled by the client (a burst
-- of ~10, then ~1/s). We keep our own token bucket a little under that so the client never drops a message.

local _, ns = ...
local Codec = ns.Codec

local Net = {}
ns.Net = Net

Net.PREFIX = "WoWPong"
Net.CHANNEL = "WoWPongLobby"
Net.VERSION = 1
Net.MAX_BYTES = 255

local BURST, REGEN = 8, 0.9       -- our token bucket: capacity, tokens per second
local JOIN_DELAY = 5              -- seconds after login before joining the channel (chat channels settle first)

Net.handlers = {}                 -- message type -> function(fields, now)
Net.stats = { sent = 0, received = 0, throttled = 0, failed = 0 }

local tokens = BURST
local lastRefill = nil
local queue = {}                  -- plain messages waiting for a token, FIFO
local lastSentAt = -1e9

---------------------------------------------------------------------------
-- Identity
---------------------------------------------------------------------------

-- Short, realm-unique peer id from the player GUID ("Player-4613-00D70F98" -> "4613-00D70F98").
function Net.pid()
    if not Net.myPid then
        local guid = UnitGUID("player")
        if guid and not ns.isSecret(guid) then Net.myPid = guid:gsub("^Player%-", "") end
    end
    return Net.myPid or "?"
end

-- Display name: the first name (Forever puts the surname in UnitName's realm slot).
function Net.name()
    local name = UnitName("player")
    if not name or ns.isSecret(name) then return "?" end
    return (name:gsub("[;|,]", ""))
end

---------------------------------------------------------------------------
-- Channel
---------------------------------------------------------------------------

function Net.channelId()
    local ok, id = pcall(GetChannelName, Net.CHANNEL)
    if ok and type(id) == "number" and not ns.isSecret(id) then return id end
    return 0
end

local function hideChannelFromChat()
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local frame = _G["ChatFrame" .. i]
        if frame then
            if type(ChatFrame_RemoveChannel) == "function" then
                pcall(ChatFrame_RemoveChannel, frame, Net.CHANNEL)
            elseif type(ChatFrameUtil) == "table" and type(ChatFrameUtil.RemoveChannel) == "function" then
                pcall(ChatFrameUtil.RemoveChannel, frame, Net.CHANNEL)
            end
        end
    end
end

function Net.join(why)
    if Net.channelId() > 0 then
        hideChannelFromChat()
        return
    end
    local joiner = JoinTemporaryChannel or JoinChannelByName
    if not joiner then
        ns.log("net: no channel join API", true)
        return
    end
    local ok, err = pcall(joiner, Net.CHANNEL)
    ns.log("net: join " .. Net.CHANNEL .. " (" .. why .. "): " .. (ok and "ok" or ("ERROR " .. ns.show(err))))
    C_Timer.After(2, function()
        hideChannelFromChat()
        ns.log("net: channel #" .. Net.channelId())
    end)
end

-- Hide our channel's join/leave notices.
local function noticeFilter(_, _, _, _, _, _, _, _, _, _, baseName)
    return baseName ~= nil and not ns.isSecret(baseName) and baseName == Net.CHANNEL
end
if type(ChatFrame_AddMessageEventFilter) == "function" then
    pcall(ChatFrame_AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE", noticeFilter)
elseif type(ChatFrameUtil) == "table" and type(ChatFrameUtil.AddMessageEventFilter) == "function" then
    pcall(ChatFrameUtil.AddMessageEventFilter, "CHAT_MSG_CHANNEL_NOTICE", noticeFilter)
end

---------------------------------------------------------------------------
-- Sending
---------------------------------------------------------------------------

local function refill(now)
    if lastRefill then tokens = math.min(BURST, tokens + (now - lastRefill) * REGEN) end
    lastRefill = now
end

local function restricted()
    local ci = C_ChatInfo
    for _, name in ipairs({ "InChatMessagingLockdown", "AreOutgoingAddonChatMessagesRestricted" }) do
        if type(ci[name]) == "function" then
            local ok, r = pcall(ci[name])
            if ok and r and not ns.isSecret(r) then return true end
        end
    end
    return false
end

local THROTTLED = Enum and Enum.SendAddonMessageResult and Enum.SendAddonMessageResult.AddonMessageThrottle

-- Sends one message right now if a token is available. Returns true when it went out.
function Net.trySend(text)
    local now = GetTime()
    refill(now)
    if tokens < 1 then return false end
    local id = Net.channelId()
    if id == 0 or restricted() then return false end
    if #text > Net.MAX_BYTES then
        ns.log("net: message over 255 bytes dropped: " .. text:sub(1, 40), true)
        return true
    end
    local ok, res = pcall(C_ChatInfo.SendAddonMessage, Net.PREFIX, text, "CHANNEL", tostring(id))
    if not ok then
        Net.stats.failed = Net.stats.failed + 1
        ns.log("net: send ERROR " .. ns.show(res))
        return true   -- a hard error won't fix itself by retrying
    end
    if THROTTLED and res == THROTTLED then
        Net.stats.throttled = Net.stats.throttled + 1
        tokens = 0
        return false
    end
    tokens = tokens - 1
    lastSentAt = now
    Net.stats.sent = Net.stats.sent + 1
    return true
end

-- Queues a message to go out as soon as the budget allows (in order). front = true jumps the queue.
function Net.send(text, front)
    if front then table.insert(queue, 1, text) else queue[#queue + 1] = text end
    Net.flush()
end

function Net.flush()
    while queue[1] and Net.trySend(queue[1]) do table.remove(queue, 1) end
end

function Net.tokens()
    refill(GetTime())
    return tokens
end

function Net.queued() return #queue end
function Net.idleFor() return GetTime() - lastSentAt end

-- Joins fields into a message.
function Net.msg(...)
    local parts = { ... }
    for i = 1, select("#", ...) do parts[i] = tostring(parts[i] == nil and "" or parts[i]) end
    return table.concat(parts, ";")
end

---------------------------------------------------------------------------
-- Receiving
---------------------------------------------------------------------------

ns.on("CHAT_MSG_ADDON", function(prefix, text, dist)
    if ns.isSecret(prefix) or prefix ~= Net.PREFIX then return end
    if ns.isSecret(text) or ns.isSecret(dist) or dist ~= "CHANNEL" then return end
    Net.stats.received = Net.stats.received + 1
    local f = Codec.split(text)
    local fn = Net.handlers[f[1]]
    if fn then fn(f, GetTime()) end
end)

local pump = CreateFrame("Frame")
pump:SetScript("OnUpdate", function()
    Net.flush()
    if Net.onUpdate then Net.onUpdate(GetTime()) end
end)

local firstWorld = true
ns.on("PLAYER_ENTERING_WORLD", function()
    local why = firstWorld and "login" or "zone"
    firstWorld = false
    C_Timer.After(JOIN_DELAY, function() Net.join(why) end)
end)

pcall(C_ChatInfo.RegisterAddonMessagePrefix, Net.PREFIX)
