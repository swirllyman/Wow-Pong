-- WoW Pong: shared core (namespace, saved variables, log, events, slash commands).
-- Other files share `ns` and register their slash subcommands in ns.commands.

local ADDON, ns = ...

ns.ADDON = ADDON
ns.commands = {}   -- subcommand name -> function(argString)
ns.help = {}       -- ordered list of help lines

local MAX_LOG_LINES = 3000

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

-- True if addon code may not compare, index or do math with v (Midnight "secret" values).
function ns.isSecret(v)
    if type(issecretvalue) ~= "function" then return false end
    local ok, r = pcall(issecretvalue, v)
    return ok and r or false
end

-- Safe, printable description of any value, never erroring on secrets.
function ns.show(v)
    if v == nil then return "nil" end
    if ns.isSecret(v) then return "<secret>" end
    local ok, s = pcall(tostring, v)
    if not ok then return "<tostring blocked>" end
    return s
end

function ns.print(msg)
    DEFAULT_CHAT_FRAME:AddMessage("|cff66ccffWoW Pong|r " .. msg)
end

---------------------------------------------------------------------------
-- Log (saved to WoWPongDB.log; read after the user plays)
---------------------------------------------------------------------------

local pendingLog = {}   -- lines logged before ADDON_LOADED

local function stamp()
    local t = (type(GetServerTime) == "function") and GetServerTime() or time()
    return date("!%H:%M:%S", t)
end

-- Appends a line to the saved log. echo=true also prints it to chat.
function ns.log(msg, echo)
    local line = stamp() .. " " .. msg
    local log = ns.db and ns.db.log or pendingLog
    log[#log + 1] = line
    while #log > MAX_LOG_LINES do table.remove(log, 1) end
    if echo or (ns.db and ns.db.echo) then ns.print(msg) end
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

local handlers = {}   -- event -> list of functions
local eventFrame = CreateFrame("Frame")
ns.eventFrame = eventFrame

-- Registers fn for event. Registration itself is pcalled and logged, since some events are forbidden.
function ns.on(event, fn)
    if not handlers[event] then
        handlers[event] = {}
        local ok, err = pcall(eventFrame.RegisterEvent, eventFrame, event)
        if not ok then ns.log("register event " .. event .. ": ERROR " .. tostring(err)) end
    end
    table.insert(handlers[event], fn)
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for _, fn in ipairs(list) do
        local ok, err = pcall(fn, ...)
        if not ok then ns.log("handler " .. event .. ": ERROR " .. tostring(err), true) end
    end
end)

-- Files add functions here to run once saved variables are available.
ns.onLoaded = {}

ns.on("ADDON_LOADED", function(name)
    if name ~= ADDON then return end
    WoWPongDB = WoWPongDB or {}
    ns.db = WoWPongDB
    ns.db.log = ns.db.log or {}
    WoWPongCharDB = WoWPongCharDB or {}   -- per character: stats
    ns.cdb = WoWPongCharDB
    for _, line in ipairs(pendingLog) do ns.db.log[#ns.db.log + 1] = line end
    pendingLog = {}
    for _, fn in ipairs(ns.onLoaded) do fn() end
end)

---------------------------------------------------------------------------
-- Slash commands: /pong <subcommand> [args] (also /wowpong). ns.commands[""] handles a bare /pong.
---------------------------------------------------------------------------

SLASH_WOWPONG1 = "/pong"
SLASH_WOWPONG2 = "/wowpong"
SlashCmdList.WOWPONG = function(input)
    input = input or ""
    local cmd, rest = input:match("^%s*(%S*)%s*(.-)%s*$")
    cmd = (cmd or ""):lower()
    local fn = ns.commands[cmd]
    if fn and cmd ~= "help" then
        local ok, err = pcall(fn, rest or "")
        if not ok then ns.log("/pong " .. cmd .. ": ERROR " .. tostring(err), true) end
        return
    end
    ns.print("commands:")
    for _, line in ipairs(ns.help) do ns.print("  " .. line) end
end

ns.commands.help = function() end   -- handled by the fallback above
ns.commands.log = function(arg)
    local n = tonumber(arg) or 20
    local log = ns.db.log
    for i = math.max(1, #log - n + 1), #log do DEFAULT_CHAT_FRAME:AddMessage(log[i]) end
end
ns.commands.echo = function()
    ns.db.echo = not ns.db.echo
    ns.print("echo log to chat: " .. tostring(ns.db.echo))
end
ns.commands.clearlog = function()
    ns.db.log = {}
    ns.print("log cleared")
end
table.insert(ns.help, "/pong log [n] - show the last n log lines")
table.insert(ns.help, "/pong echo - toggle echoing every log line to chat")
table.insert(ns.help, "/pong clearlog - empty the saved log")
