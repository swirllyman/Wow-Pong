"""Fake WoW client for tests: a lupa Lua runtime with a stubbed WoW API that loads the real addon files (in .toc
order). Several clients can be wired together by tests/routers to exchange addon messages.

Secret values are simulated by the Lua table SECRET_MARK-tagged objects: issecretvalue() returns true for them and
comparing/concatenating them raises an error, like the real client.
"""
import os
import re

from lupa import LuaRuntime

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON_DIR = os.path.join(HERE, "..", "WoWPong")
TOC = os.path.join(ADDON_DIR, "WoWPong.toc")

FAKE_WOW = r"""
now = 1000
serverNow = 1790000000
chat = {}
outbox = {}      -- addon messages sent: {prefix, text, dist, target}
bnOutbox = {}
timers = {}
joined = {}      -- channel name -> id

local secretMT = {
    __tostring = function() error("attempt to use a secret value") end,
    __eq = function() error("attempt to compare a secret value") end,
    __lt = function() error("attempt to compare a secret value") end,
    __le = function() error("attempt to compare a secret value") end,
    __concat = function() error("attempt to concatenate a secret value") end,
    __index = function() error("attempt to index a secret value") end,
}
function MakeSecret(v) return setmetatable({ secretValue = v }, secretMT) end
function issecretvalue(v) return type(v) == "table" and getmetatable(v) == secretMT end
function unpack(t, i, j) return table.unpack(t, i, j) end
function table.maxn(t) local m = 0 for k in pairs(t) do if type(k) == "number" and k > m then m = k end end return m end

-- frames
local methods = {}
local function mock(kind)
    local o = { kind = kind, scripts = {}, events = {}, shownFlag = true }   -- new frames start shown
    return setmetatable(o, { __index = function(t, k)
        if methods[k] then return methods[k] end
        if type(k) == "string" and k:match("^%u") then return function() end end
    end })
end
function methods.SetScript(self, n, f) self.scripts[n] = f end
function methods.RegisterEvent(self, e)
    if not self.listed then self.listed = true; allFrames[#allFrames + 1] = self end
    self.events[e] = true
end
-- Like the real client: frames start shown, and Show/Hide fire OnShow/OnHide only when visibility changes.
function methods.Show(self)
    local was = self.shownFlag
    self.shownFlag = true
    if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
end
function methods.Hide(self)
    local was = self.shownFlag
    self.shownFlag = false
    if was and self.scripts.OnHide then self.scripts.OnHide(self) end
end
function methods.IsShown(self) return self.shownFlag or false end
-- Anchors are recorded so position save/restore code sees real values (layout itself isn't simulated).
function methods.SetPoint(self, point, rel, relPoint, x, y)
    self.points = self.points or {}
    table.insert(self.points, { point, rel, relPoint or point, x or 0, y or 0 })
end
function methods.ClearAllPoints(self) self.points = {} end
function methods.GetPoint(self, i)
    local p = self.points and self.points[i or 1]
    if p then return p[1], p[2], p[3], p[4], p[5] end
end
function methods.GetNumPoints(self) return self.points and #self.points or 0 end
-- Like the real client: FontStrings and EditBoxes error on SetText until a font is set (SetFont / SetFontObject /
-- a font template).
function methods.SetText(self, t)
    if (self.kind == "FontString" or self.kind == "EditBox") and not self.font and not self.fontTemplate then
        error(self.kind .. ":SetText(): Font not set", 2)
    end
    self.text = t
end
function methods.SetFontObject(self, obj) self.font = { object = obj } end
function methods.GetText(self) return self.text or "" end
function methods.SetTextColor(self, r, g, b, a) self.textColor = { r, g, b, a } end
function methods.SetColorTexture(self, r, g, b, a) self.color = { r, g, b, a } end
function methods.SetVertexColor(self, r, g, b, a) self.color = { r, g, b, a } end
function methods.SetFont(self, path, size, flags) self.font = { path = path, size = size, flags = flags } end
function methods.CreateFontString(self, name, layer, template)
    local fs = mock("FontString")
    fs.fontTemplate = template
    if type(name) == "string" then _G[name] = fs end
    return fs
end
function methods.CreateTexture(self, name, layer, template)
    local t = mock("Texture")
    if type(name) == "string" then _G[name] = t end
    return t
end
function methods.SetSize(self, w, h) self.width, self.height = w, h end
function methods.SetWidth(self, w) self.width = w end
function methods.SetHeight(self, h) self.height = h end
function methods.GetWidth(self) return self.width or 0 end
function methods.GetHeight(self) return self.height or 0 end
-- Focus fires OnEditFocusGained/Lost like a real EditBox, for the typing-hint line.
function methods.SetFocus(self)
    self.focused = true
    if self.scripts.OnEditFocusGained then self.scripts.OnEditFocusGained(self) end
end
function methods.ClearFocus(self)
    self.focused = false
    if self.scripts.OnEditFocusLost then self.scripts.OnEditFocusLost(self) end
end
function methods.HasFocus(self) return self.focused or false end
function methods.HighlightText(self) self.highlighted = true end
function methods.SetMultiLine(self, v) self.multiline = v end
function methods.GetEffectiveScale(self) return 1 end
function methods.GetBottom(self) return 0 end
cursorY = 0
function GetCursorPosition() return 0, cursorY end

-- Every frame ever created, so RunFrames can fire OnUpdate like the real client does each rendered frame.
createdFrames = {}
function RunFrames(sec, fps)
    local dt = 1 / fps
    local n = math.floor(sec * fps + 0.5)
    for _ = 1, n do
        Advance(dt)
        for _, f in ipairs(createdFrames) do
            if f.shownFlag and f.scripts.OnUpdate then f.scripts.OnUpdate(f, dt) end
        end
    end
end

allFrames = {}
function CreateFrame(kind, name, parent, template)
    local f = mock(kind)
    createdFrames[#createdFrames + 1] = f
    f.fontTemplate = (kind == "EditBox" and template) or nil
    if type(name) == "string" then _G[name] = f end
    return f
end
UIParent = mock("Frame")
UISpecialFrames = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
ChatFrame1 = mock("chatframe")
NUM_CHAT_WINDOWS = 1
function ChatFrame_RemoveChannel() end
filters = {}
function ChatFrame_AddMessageEventFilter(e, f) filters[e] = f end
sentChat = {}
function SendChatMessage(text, channel) table.insert(sentChat, { text = text, channel = channel }) end

function FireEvent(event, ...)
    for _, f in ipairs(allFrames) do
        if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
    end
end

-- time
function GetTime() return now end
function GetServerTime() return math.floor(serverNow) end
function time() return math.floor(serverNow) end
date = os.date
C_Timer = {}
function C_Timer.After(d, f) table.insert(timers, { at = now + d, f = f }) end
function C_Timer.NewTicker(d, f)
    local t = { at = now + d, f = f, every = d }
    function t.Cancel() t.cancelled = true end
    table.insert(timers, t)
    return t
end
function Advance(sec)
    local target = now + sec
    while true do
        local best
        for _, t in ipairs(timers) do
            if not t.cancelled and t.at <= target and (not best or t.at < best.at) then best = t end
        end
        if not best then break end
        now = math.max(now, best.at)
        if best.every then best.at = best.at + best.every else best.cancelled = true end
        best.f()
    end
    now = target
    serverNow = serverNow + sec
end
C_DateAndTime = {
    GetCurrentCalendarTime = function() return { year = 2026, month = 9, monthDay = 24, hour = 12, minute = 0 } end,
    GetSecondsUntilDailyReset = function() return 3600 end,
}
function GetGameTime() return 12, 0 end

-- identity (set per client by the test)
ME = { name = "John", realm = "", nrealm = "Forever", guid = "Player-1-0001", secretName = false }
function UnitName(u)
    -- Forever returns the surname in the realm slot ("Bear", "Joegre"); ME.surname models that.
    if u == "player" then return ME.secretName and MakeSecret(ME.name) or ME.name, ME.surname end
    if u == "target" and TARGET then return TARGET.name, nil end
end
function UnitFullName(u) if u == "player" then return ME.name, ME.nrealm end end
function GetUnitName(u, full)
    if u == "player" then return ME.name end
    if u == "target" and TARGET then return TARGET.name end
end
function UnitGUID(u)
    if u == "player" then return ME.guid end
    if u == "target" and TARGET then return TARGET.guid end
end
function UnitIsPlayer(u) return u == "target" and TARGET ~= nil end
function GetPlayerInfoByGUID(guid)
    local who = guid == ME.guid and ME or (TARGET and TARGET.guid == guid and TARGET) or PEERS[guid]
    if who then return "Mage", "MAGE", "Human", "Human", 2, who.name, "" end
end
PEERS = {}
function GetRealmName() return ME.nrealm end
function GetNormalizedRealmName() return ME.nrealm end
function Ambiguate(n, mode) return (n:gsub("%-.*$", "")) end
function GetBuildInfo() return "1.60.1", "70009", "Sep 1 2026", 16001 end
WOW_PROJECT_ID = 99
function InCombatLockdown() return inCombat or false end
function IsInInstance() return false, "none" end
function GetInstanceInfo() return "Elwynn", "none", 0 end
function IsEncounterInProgress() return false end
inGuild = true
function IsInGuild() return inGuild end
function GetGuildInfo() return "Test Guild", "Member", 1 end
inGroup = true
function IsInGroup() return inGroup end
function IsInRaid() return false end
LE_PARTY_CATEGORY_INSTANCE = 2
C_GuildInfo = { GuildRoster = function() end }
function GetNumGuildMembers() return 2, 2 end
function GetGuildRosterInfo(i) return "Member" .. i .. "-Forever", "Rank", 1, 60, "Mage", "Zone", "", "", true, 0,
    "MAGE", 0, 0, false, false, 5, "Player-1-000" .. i end
C_FriendList = {
    GetNumFriends = function() return 1 end,
    GetNumOnlineFriends = function() return 1 end,
    GetFriendInfoByIndex = function(i) return { name = "Friend", connected = true, guid = "Player-1-0099" } end,
}
BNET_CLIENT_WOW = "WoW"
function BNGetNumFriends() return BN_FRIENDS and #BN_FRIENDS or 0, 0 end
C_BattleNet = {
    GetFriendAccountInfo = function(i) return BN_FRIENDS and BN_FRIENDS[i] end,
    GetGameAccountInfoByGUID = function() return { characterName = ME.name, realmName = ME.nrealm } end,
}
function BNGetInfo() return 1, "Tag#1", 7 end
function BNSendGameData(id, prefix, text) table.insert(bnOutbox, { id = id, prefix = prefix, text = text }) end

function GetChannelName(name)
    if type(name) == "string" then return joined[name] or 0, name end
    return 0
end
function JoinTemporaryChannel(name) joined[name] = 5 end
function GetChannelList() return 5, "WoWPongLobby", false end

C_ChatInfo = {}
registeredPrefixes = {}
function C_ChatInfo.RegisterAddonMessagePrefix(p)
    assert(#p <= 16, "prefix too long")
    registeredPrefixes[p] = true
    return 0
end
function C_ChatInfo.SendAddonMessage(prefix, text, dist, target)
    assert(type(text) == "string" and not issecretvalue(text), "bad text")
    assert(#text <= 255, "addon message over 255 bytes: " .. #text)
    table.insert(outbox, { prefix = prefix, text = text, dist = dist, target = target })
    return 0
end
Enum = { SendAddonMessageResult = { Success = 0, AddonMessageThrottle = 3 } }

SlashCmdList = {}
"""


class Client:
    """One fake WoW client running the real addon."""

    def __init__(self, name="John", guid="Player-1-0001", realm="Forever", secret_name=False, surname=None):
        self.lua = LuaRuntime(unpack_returned_tuples=True)
        self.lua.execute(FAKE_WOW)
        g = self.lua.globals()
        g.ME.name, g.ME.guid, g.ME.nrealm, g.ME.secretName = name, guid, realm, secret_name
        g.ME.surname = surname
        self.name, self.guid = name, guid
        ns = self.lua.table()
        loader = self.lua.execute("return function(src, name, ns) return load(src, name) end")
        for f in self.toc_files():
            path = os.path.join(ADDON_DIR, f)
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
            chunk = loader(src, "@" + f, ns)
            if chunk is None:
                raise SyntaxError(f)
            chunk("WoWPong", ns)
        self.ns = ns
        self.fire("ADDON_LOADED", "WoWPong")
        self.fire("PLAYER_ENTERING_WORLD", True, False)

    @staticmethod
    def toc_files():
        with open(TOC, encoding="utf-8") as fh:
            return [l.strip() for l in fh if l.strip() and not l.startswith("#")]

    def fire(self, event, *args):
        self.lua.globals().FireEvent(event, *args)

    def slash(self, text):
        self.lua.globals().SlashCmdList.WOWPONG(text)

    def run(self, sec, fps=60):
        """Advances time frame by frame, firing OnUpdate on every shown frame like the real client."""
        self.lua.globals().RunFrames(sec, fps)

    def click_board(self, y):
        """Clicks the Pong board at board-y (the fake board's bottom sits at screen y 0, scale 1)."""
        g = self.lua.globals()
        g.cursorY = y
        board = g.WoWPongBoard
        board.scripts.OnMouseDown(board, "LeftButton")

    def advance(self, sec):
        self.lua.globals().Advance(sec)

    def secret(self, value):
        return self.lua.globals().MakeSecret(value)

    def take_outbox(self):
        g = self.lua.globals()
        msgs = [dict(m.items()) for m in g.outbox.values()]
        g.outbox = self.lua.table()
        return msgs

    def log(self):
        return list(self.lua.globals().WoWPongDB.log.values())

    def errors(self):
        return [l for l in self.log() if re.search(r"(handler|/pong) .*ERROR", l)]

    def frame(self, name):
        """A global frame by its CreateFrame name, e.g. client.frame("WoWPongFrame")."""
        return self.lua.globals()[name]

    def set_guild(self, value):
        self.lua.globals().inGuild = value

    def set_group(self, value):
        self.lua.globals().inGroup = value

    def sent_chat(self):
        g = self.lua.globals()
        msgs = [dict(m.items()) for m in g.sentChat.values()]
        g.sentChat = self.lua.table()
        return msgs

    def chat(self):
        """Lines printed to the default chat frame (ns.print et al.), e.g. for 'no guild or group' notices."""
        return list(self.lua.globals().chat.values())
