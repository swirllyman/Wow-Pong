-- The Pong window: header with names, the board (paddles, ghost targets, ball, scores, status), the lobby, and a
-- mode-dependent footer. Only reads Game/Sim state and sends clicks to Game.click; it never changes a match
-- directly. Display options (OptionsUI.lua) are applied here. All widgets live on `ui` (ns._ui for tests).

local _, ns = ...
local Sim, Game, Bot, Table = ns.Sim, ns.Game, ns.Bot, ns.Table

local ui = {}
ns._ui = ui

---------------------------------------------------------------------------
-- Look and feel
---------------------------------------------------------------------------

local FONT = "Fonts\\FRIZQT__.TTF"   -- FontStrings error on SetText until they have a font
local WHITE = "Interface\\Buttons\\WHITE8X8"
local INSET = 16                      -- the dialog border is ~12px wide
local HEADER_H, FOOTER_H = 58, 48
local FRAME_W, FRAME_H = Sim.W + 2 * INSET, HEADER_H + Sim.H + FOOTER_H
local SEAT_COLOR = { { 0.35, 0.65, 1 }, { 1, 0.45, 0.35 } }
local MINE_COLOR, THEIRS_COLOR, RETRO_COLOR = { 0.35, 0.9, 0.4 }, { 1, 0.4, 0.35 }, { 0.95, 0.95, 0.95 }
local GHOST_ALPHA = 0.3
local CENTER_DASHES = 15
local TRAIL_MAX, TRAIL_GAP = 8, 0.018           -- trail dots and the time between them
local TRAIL_LEN = { off = 0, short = 4, long = TRAIL_MAX }
local FLASH_TIME = 0.18                         -- seconds a paddle glows after a hit
local STEER_GAP, STEER_GAP_NET, STEER_MIN = 0.05, 0.25, 6   -- hold to steer: min seconds / units between moves
local POINTS_CHOICES = { 1, 3, 5, 7 }           -- the match length button (header) cycles these

---------------------------------------------------------------------------
-- Small helpers
---------------------------------------------------------------------------

-- Tries CreateFrame with a template, falls back to a plain frame if the template doesn't exist on this client.
local function newFrame(kind, name, parent, template)
    if template then
        local ok, f = pcall(CreateFrame, kind, name, parent, template)
        if ok and f then return f end
    end
    local ok2, f2 = pcall(CreateFrame, kind, name, parent)
    if ok2 and f2 then return f2 end
    return CreateFrame(kind)
end

-- Best-effort WoW dialog look; falls back to a flat texture if SetBackdrop isn't available.
local function styleAsPanel(f)
    local ok = pcall(f.SetBackdrop, f, {
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 32,
        insets = { left = 11, right = 12, top = 12, bottom = 11 },
    })
    if not ok then
        f.bg = f:CreateTexture(nil, "BACKGROUND")
        f.bg:SetAllPoints(f)
        f.bg:SetColorTexture(0.05, 0.04, 0.02, 0.96)
    end
end

local function newText(parent, size, layer)
    local fs = parent:CreateFontString(nil, layer or "OVERLAY")
    fs:SetFont(FONT, size, "OUTLINE")
    return fs
end

local function newRect(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "ARTWORK")
    t:SetColorTexture(r, g, b, a or 1)
    return t
end

local function newButton(parent, label, width, onClick)
    local b = newFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    if not b:GetFontString() then   -- plain-frame fallback: give it a label and a face ourselves
        local fs = newText(b, 12)
        fs:SetPoint("CENTER", b, "CENTER", 0, 0)
        b:SetFontString(fs)
        local bg = newRect(b, "BACKGROUND", 0.25, 0.2, 0.1, 0.9)
        bg:SetAllPoints(b)
    end
    b:SetText(label)
    b:SetScript("OnClick", onClick)
    return b
end

-- Places a board texture's centre at board coordinates (x, y).
local function place(tex, x, y)
    tex:ClearAllPoints()
    tex:SetPoint("CENTER", ui.board, "BOTTOMLEFT", x, y)
end

---------------------------------------------------------------------------
-- Building the window
---------------------------------------------------------------------------

local function buildBoard(frame)
    local board = newFrame("Frame", "WoWPongBoard", frame)
    ui.board = board
    board:SetSize(Sim.W, Sim.H)
    board:SetPoint("TOP", frame, "TOP", 0, -HEADER_H)
    ui.boardBg = newRect(board, "BACKGROUND", 0, 0, 0, 0.92)
    ui.boardBg:SetAllPoints(board)

    -- dashed centre line
    ui.dashes = {}
    local dashH = Sim.H / (CENTER_DASHES * 2)
    for i = 0, CENTER_DASHES - 1 do
        local d = newRect(board, "BORDER", 1, 1, 1, 0.18)
        d:SetSize(2, dashH)
        place(d, Sim.W / 2, dashH / 2 + i * dashH * 2 + dashH / 2)
        ui.dashes[#ui.dashes + 1] = d
    end

    ui.scores, ui.paddles, ui.ghosts = {}, {}, {}
    for seat = 1, 2 do
        local c = SEAT_COLOR[seat]
        local score = newText(board, 36, "BORDER")
        score:SetTextColor(c[1], c[2], c[3], 0.55)
        score:SetPoint("TOP", board, "TOPLEFT", Sim.W * (seat == 1 and 0.36 or 0.64), -10)
        score:SetText("0")
        ui.scores[seat] = score

        local ghost = newRect(board, "ARTWORK", c[1], c[2], c[3], GHOST_ALPHA)
        ghost:SetSize(Sim.PADDLE_W, Sim.PADDLE_H)
        ghost:Hide()
        ui.ghosts[seat] = ghost

        local paddle = newRect(board, "OVERLAY", c[1], c[2], c[3], 1)
        paddle:SetSize(Sim.PADDLE_W, Sim.PADDLE_H)
        place(paddle, Sim.PADDLE_X[seat], Sim.H / 2)
        ui.paddles[seat] = paddle
    end

    ui.ball = newRect(board, "OVERLAY", 1, 1, 1, 1)
    ui.ball:SetSize(Sim.BALL_R * 2, Sim.BALL_R * 2)
    ui.ball:Hide()
    ui.trail = {}
    for i = 1, TRAIL_MAX do
        local dot = newRect(board, "ARTWORK", 1, 1, 1, 0.45 * (1 - i / (TRAIL_MAX + 1)))
        local size = Sim.BALL_R * 2 * (1 - 0.5 * i / TRAIL_MAX)
        dot:SetSize(size, size)
        dot:Hide()
        ui.trail[i] = dot
    end
    ui.flash = {}

    ui.status = newText(board, 22)
    ui.status:SetPoint("CENTER", board, "CENTER", 0, 20)
    ui.status:SetTextColor(1, 0.82, 0)
    ui.hint = newText(board, 12)
    ui.hint:SetPoint("TOP", ui.status, "BOTTOM", 0, -8)
    ui.hint:SetTextColor(0.8, 0.8, 0.8)
    ui.rally = newText(board, 12, "BORDER")
    ui.rally:SetPoint("BOTTOM", board, "BOTTOM", 0, 8)
    ui.rally:SetTextColor(1, 1, 1, 0.6)
    ui.rally:SetText("")

    -- Click to move: convert the cursor to board coordinates. With "hold to steer", ui.steer keeps following the
    -- cursor until the button comes up (see steer()).
    board:EnableMouse(true)
    board:SetScript("OnMouseDown", function()
        local y = ui.cursorY()
        Game.click(y)
        if ns.opt("holdToSteer") then ui.steering = { y = y, at = GetTime() } end
    end)
    board:SetScript("OnMouseUp", function() ui.steering = nil end)
    board:SetScript("OnHide", function() ui.steering = nil end)
end

function ui.cursorY()
    local _, cy = GetCursorPosition()
    return cy / ui.board:GetEffectiveScale() - (ui.board:GetBottom() or 0)
end

local function levelLabel()
    return "Bot: " .. Bot.NAMES[ns.db.level or "normal"]
end

-- The lobby: tables heard on the channel, a row each with Sit / Watch, plus Open a Table.
local LOBBY_ROWS, ROW_H, LOBBY_TOP = 6, 40, 32
local STATS_LINES = 13

local function buildLobby(frame)
    local lobby = newFrame("Frame", "WoWPongLobby", frame)
    ui.lobby = lobby
    lobby:SetSize(Sim.W, Sim.H)
    lobby:SetPoint("TOP", frame, "TOP", 0, -HEADER_H)
    local bg = newRect(lobby, "BACKGROUND", 0, 0, 0, 0.6)
    bg:SetAllPoints(lobby)

    ui.lobbyTitle = newText(lobby, 14)
    ui.lobbyTitle:SetPoint("TOPLEFT", lobby, "TOPLEFT", 8, -8)
    ui.lobbyTitle:SetTextColor(1, 0.82, 0)
    ui.lobbyTitle:SetText("Tables")
    ui.openBtn = newButton(lobby, "Open a Table", 110, function() Table.host() end)
    ui.openBtn:SetPoint("TOPRIGHT", lobby, "TOPRIGHT", -6, -5)
    ui.statsBtn = newButton(lobby, "Stats", 60, function()
        ui.showingStats = not ui.showingStats
        ui.showingLedger = false
        ui.lobbyAt = nil
    end)
    ui.statsBtn:SetPoint("RIGHT", ui.openBtn, "LEFT", -6, 0)
    ui.ledgerBtn = newButton(lobby, "Ledger", 64, function()
        ui.showingLedger = not ui.showingLedger
        ui.showingStats = false
        ui.lobbyAt = nil
    end)
    ui.ledgerBtn:SetPoint("RIGHT", ui.statsBtn, "LEFT", -6, 0)
    ui.optionsBtn = newButton(lobby, "Options", 70, function() if ui.toggleOptions then ui.toggleOptions() end end)
    ui.optionsBtn:SetPoint("RIGHT", ui.ledgerBtn, "LEFT", -6, 0)

    -- Stats panel, drawn over the table rows.
    ui.statsLines = {}
    for i = 1, STATS_LINES do
        local fs = newText(lobby, 12)
        fs:SetPoint("TOPLEFT", lobby, "TOPLEFT", 14, -LOBBY_TOP - 4 - (i - 1) * 20)
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(0.9, 0.9, 0.9)
        fs:SetText("")
        ui.statsLines[i] = fs
    end

    ui.rows = {}
    for i = 1, LOBBY_ROWS do
        local row = newFrame("Frame", nil, lobby)
        row:SetSize(Sim.W - 12, ROW_H - 4)
        row:SetPoint("TOPLEFT", lobby, "TOPLEFT", 6, -LOBBY_TOP - (i - 1) * ROW_H)
        local rbg = newRect(row, "BACKGROUND", 1, 1, 1, 0.05)
        rbg:SetAllPoints(row)
        row.host = newText(row, 13)
        row.host:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
        row.host:SetTextColor(1, 0.82, 0)
        row.detail = newText(row, 11)
        row.detail:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", 8, 5)
        row.detail:SetTextColor(0.8, 0.8, 0.8)
        row.watch = newButton(row, "Watch", 60, function() if row.info then Table.spectate(row.info) end end)
        row.watch:SetPoint("RIGHT", row, "RIGHT", -6, 0)
        row.sit = newButton(row, "Sit", 50, function() if row.info then Table.sit(row.info) end end)
        row.sit:SetPoint("RIGHT", row.watch, "LEFT", -4, 0)
        row:Hide()
        ui.rows[i] = row
    end

    ui.empty = newText(lobby, 13)
    ui.empty:SetPoint("CENTER", lobby, "CENTER", 0, 0)
    ui.empty:SetTextColor(0.8, 0.8, 0.8)
    ui.empty:SetText("")

    ui.page = 1
    ui.pageText = newText(lobby, 11)
    ui.pageText:SetPoint("BOTTOM", lobby, "BOTTOM", 0, 8)
    ui.pageText:SetText("")
    ui.prevBtn = newButton(lobby, "<", 26, function() ui.page = math.max(1, ui.page - 1) ui.lobbyAt = nil end)
    ui.prevBtn:SetPoint("RIGHT", ui.pageText, "LEFT", -8, 0)
    ui.nextBtn = newButton(lobby, ">", 26, function() ui.page = ui.page + 1 ui.lobbyAt = nil end)
    ui.nextBtn:SetPoint("LEFT", ui.pageText, "RIGHT", 8, 0)
    lobby:Hide()
end

local function buildFooter(frame)
    ui.practiceBtn = newButton(frame, "Practice vs Bot", 120, function() ui.startPractice() end)
    ui.practiceBtn:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", INSET, 16)
    ui.levelBtn = newButton(frame, levelLabel(), 110, function()
        local cur = ns.db.level or "normal"
        for i, l in ipairs(Bot.LEVELS) do
            if l == cur then ns.db.level = Bot.LEVELS[i % #Bot.LEVELS + 1] break end
        end
        ui.levelBtn:SetText(levelLabel())
    end)
    ui.demoBtn = newButton(frame, "Watch Bots", 100, function() ui.startDemo() end)
    ui.demoBtn:SetPoint("LEFT", ui.levelBtn, "RIGHT", 6, 0)
    ui.botBtn = newButton(frame, "Add Bot", 90, function()
        local t = Table.cur
        if t and t.seats[2] and t.seats[2].bot then Table.removeBot() else Table.addBot(ns.db.level) end
    end)
    ui.botBtn:SetPoint("LEFT", ui.levelBtn, "RIGHT", 6, 0)
    -- Host: hand seat 1 to a bot (then referee a bot match) or take it back.
    ui.seatBtn = newButton(frame, "Bot in My Seat", 110, function()
        local t = Table.cur
        if t and t.seats[1] and t.seats[1].bot then Table.hostSit() else Table.hostSeatBot(ns.db.level) end
    end)
    ui.seatBtn:SetPoint("LEFT", ui.botBtn, "RIGHT", 6, 0)
    ui.stopBtn = newButton(frame, "Stop", 60, function()
        if Table.cur then Table.leave(true) else Game.stop() end
    end)
    ui.stopBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -INSET, 16)
    ui.playBtn = newButton(frame, "Play Now", 80, function() Table.start() end)
    ui.playBtn:SetPoint("RIGHT", ui.stopBtn, "LEFT", -6, 0)
end

-- Which buttons show: the lobby (solo options), a table (host/guest/spectator controls), or a local match.
local function setShown(w, on)
    if on then w:Show() else w:Hide() end
end

local function applyMode(mode)
    local t = Table.cur
    local isHost = t and t.role == "host"
    setShown(ui.lobby, mode == "lobby")
    setShown(ui.board, mode ~= "lobby")
    setShown(ui.practiceBtn, mode == "lobby")
    setShown(ui.demoBtn, mode == "lobby")
    setShown(ui.levelBtn, mode == "lobby" or isHost)
    setShown(ui.botBtn, isHost)
    setShown(ui.seatBtn, isHost)
    if ui.betsPanel then setShown(ui.betsPanel, mode == "table" and t ~= nil and ns.opt("betsPanel")) end
    setShown(ui.playBtn, t ~= nil and t.role ~= "spectator")
    setShown(ui.stopBtn, mode ~= "lobby")
    ui.levelBtn:ClearAllPoints()
    if mode == "lobby" then
        ui.levelBtn:SetPoint("LEFT", ui.practiceBtn, "RIGHT", 6, 0)
    else
        ui.levelBtn:SetPoint("BOTTOMLEFT", ui.frame, "BOTTOMLEFT", INSET, 16)
    end
    if mode == "lobby" and ui.mode ~= "lobby" then
        ui.lobbyAt = nil
        Table.refresh()
    end
    ui.mode = mode
    ui.modeKey = mode .. (t and t.role or "")
end

-- Invite popup: "X challenges you to Pong!" with Accept / Decline; disappears unanswered after a while.
local function buildInvite()
    local pop = newFrame("Frame", "WoWPongInvite", UIParent, "BackdropTemplate")
    ui.invite = pop
    pop:SetSize(300, 96)
    pop:SetFrameStrata("DIALOG")
    pop:SetPoint("TOP", UIParent, "TOP", 0, -140)
    pop:EnableMouse(true)
    styleAsPanel(pop)
    pop.text = newText(pop, 13)
    pop.text:SetPoint("TOP", pop, "TOP", 0, -22)
    pop.text:SetTextColor(1, 0.82, 0)
    pop.text:SetText("")
    pop.accept = newButton(pop, "Accept", 90, function()
        pop:Hide()
        if pop.onAccept then pop.onAccept() end
    end)
    pop.accept:SetPoint("BOTTOMRIGHT", pop, "BOTTOM", -6, 18)
    pop.decline = newButton(pop, "Decline", 90, function()
        pop:Hide()
        if pop.onDecline then pop.onDecline() end
    end)
    pop.decline:SetPoint("BOTTOMLEFT", pop, "BOTTOM", 6, 18)
    pop:SetScript("OnUpdate", function(self)
        if GetTime() >= (self.expires or 0) then self:Hide() end
    end)
    pop:Hide()
end

function ui.showInvite(text, wait, onAccept, onDecline)
    local pop = ui.invite
    pop.text:SetText(text)
    pop.onAccept, pop.onDecline = onAccept, onDecline
    pop.expires = GetTime() + wait
    pop:Show()
end

local function build()
    buildInvite()
    local frame = newFrame("Frame", "WoWPongFrame", UIParent, "BackdropTemplate")
    ui.frame = frame
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", function(self)
        if not ns.opt("lockWindow") then self:StartMoving() end
    end)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint(1)
        ns.db.pos = { point, relPoint, x, y }
    end)
    local pos = ns.db.pos
    if pos then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
    end
    styleAsPanel(frame)
    table.insert(UISpecialFrames, "WoWPongFrame")   -- Esc closes it

    local close = newFrame("Button", nil, frame, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() frame:Hide() end)

    local title = newText(frame, 14)
    title:SetPoint("TOP", frame, "TOP", 0, -14)
    title:SetTextColor(1, 0.82, 0)
    title:SetText("WoW Pong")

    ui.names = {}
    for seat = 1, 2 do
        local n = newText(frame, 13)
        local c = SEAT_COLOR[seat]
        n:SetTextColor(c[1], c[2], c[3])
        if seat == 1 then
            n:SetPoint("BOTTOMLEFT", frame, "TOPLEFT", INSET + 4, -HEADER_H + 6)
        else
            n:SetPoint("BOTTOMRIGHT", frame, "TOPRIGHT", -INSET - 4, -HEADER_H + 6)
        end
        n:SetText("")
        ui.names[seat] = n
    end

    -- Match length: first to 1/3/5/7. Editable in the lobby, by a host between matches and after a local match;
    -- otherwise it just shows the length being played (or the host's choice for the next match).
    ui.pointsBtn = newButton(frame, "First to 7", 90, function(_, button) ui.cyclePoints(button == "RightButton") end)
    pcall(ui.pointsBtn.RegisterForClicks, ui.pointsBtn, "LeftButtonUp", "RightButtonUp")
    ui.pointsBtn:SetPoint("TOPLEFT", frame, "TOPLEFT", INSET, -10)

    buildBoard(frame)
    buildLobby(frame)
    buildFooter(frame)
    frame:SetScript("OnUpdate", function() ui.render(Game.clock()) end)
    frame:SetScript("OnShow", function() Table.refresh() end)
    frame:Hide()
    ui.applyOptions()
end

---------------------------------------------------------------------------
-- Drawing (every frame while shown)
---------------------------------------------------------------------------

local function statusText(m, now)
    if m.phase == "countdown" then return tostring(math.ceil(m.serveAt - now)) end
    if m.phase == "over" then
        return (Game.names[m.winner] or "?") .. " wins!" .. (m.forfeit and " (forfeit)" or "")
    end
    return ""
end

local function setEnabled(button, on)
    if on then button:Enable() else button:Disable() end
    button:SetAlpha(on and 1 or 0.5)
end

-- The match length the header button shows, and whether this client may change it right now.
local function pointsState()
    local t, m = Table.cur, Game.match
    if t then
        local live = Game.networked and m and m.phase ~= "over"
        return Table.points(), t.role == "host" and not live
    end
    if m and m.phase ~= "over" then return m.pointsToWin, false end
    return ns.opt("points"), true
end

function ui.cyclePoints(back)
    if not select(2, pointsState()) then return end
    local cur, n = ns.opt("points"), #POINTS_CHOICES
    local i = n
    for k, v in ipairs(POINTS_CHOICES) do
        if v == cur then i = k end
    end
    i = back and ((i - 2) % n + 1) or (i % n + 1)
    ns.Options.set("points", POINTS_CHOICES[i])
end

local function updatePointsBtn()
    local value, editable = pointsState()
    local label = "First to " .. tostring(value)
    if ui.pointsBtn:GetText() ~= label then ui.pointsBtn:SetText(label) end
    setEnabled(ui.pointsBtn, editable)
end

-- "Rally 12" while the ball is in play (and just after the point), the match's longest rally once it's over.
local function rallyText(m)
    if m.phase == "over" then
        return m.longest > 0 and ("Longest rally: " .. m.longest) or ""
    end
    if (m.phase == "play" or m.phase == "point") and m.hits > 0 then return "Rally " .. m.hits end
    return ""
end

local function renderStats()
    local lines = ns.Stats.lines()
    for i, fs in ipairs(ui.statsLines) do fs:SetText(lines[i] or "") end
    for _, row in ipairs(ui.rows) do row:Hide() end
    ui.empty:SetText("")
    ui.pageText:SetText("")
    setShown(ui.prevBtn, false)
    setShown(ui.nextBtn, false)
    ui.statsBtn:SetText("Tables")
    ui.lobbyTitle:SetText("Your stats")
end

function ui.renderLobby()
    local now = GetTime()
    if ui.lobbyAt and now - ui.lobbyAt < 0.5 then return end
    ui.lobbyAt = now
    if ui.hideLedger then ui.hideLedger() end
    if ui.showingStats then return renderStats() end
    if ui.showingLedger and ui.renderLedger then
        for _, row in ipairs(ui.rows) do row:Hide() end
        for _, fs in ipairs(ui.statsLines) do fs:SetText("") end
        ui.empty:SetText("")
        ui.pageText:SetText("")
        setShown(ui.prevBtn, false)
        setShown(ui.nextBtn, false)
        ui.statsBtn:SetText("Stats")
        ui.lobbyTitle:SetText("Ledger")
        return ui.renderLedger()
    end
    ui.statsBtn:SetText("Stats")
    ui.lobbyTitle:SetText("Tables")
    for _, fs in ipairs(ui.statsLines) do fs:SetText("") end
    local list = Table.list()
    if ns.opt("hideOtherVersions") then
        local same = {}
        for _, info in ipairs(list) do
            if info.version == ns.Net.VERSION then same[#same + 1] = info end
        end
        list = same
    end
    local pages = math.max(1, math.ceil(#list / LOBBY_ROWS))
    ui.page = math.min(ui.page, pages)
    for i, row in ipairs(ui.rows) do
        local info = list[(ui.page - 1) * LOBBY_ROWS + i]
        row.info = info
        if info then
            local s1, s2 = info.seats[1], info.seats[2]
            row.host:SetText(info.hostName .. "'s table")
            if info.version ~= ns.Net.VERSION then
                row.detail:SetText("Different WoW Pong version")
            else
                row.detail:SetText(string.format("%s vs %s  -  %s", s1 and s1.name or "?",
                    s2 and s2.name or "(open)", Table.describe(info)))
            end
            setEnabled(row.sit, Table.canSit(info))
            setEnabled(row.watch, info.version == ns.Net.VERSION)
            row:Show()
        else
            row:Hide()
        end
    end
    if #list > 0 then
        ui.empty:SetText("")
    elseif ns.Net.channelId() == 0 then
        ui.empty:SetText("Connecting to the WoW Pong channel...")
    else
        ui.empty:SetText("No tables yet. Open one, or practice against a bot.")
    end
    ui.pageText:SetText(pages > 1 and (ui.page .. " / " .. pages) or "")
    setShown(ui.prevBtn, pages > 1)
    setShown(ui.nextBtn, pages > 1)
end

---------------------------------------------------------------------------
-- Colors, hit flashes, the ball trail and hold to steer (display options)
---------------------------------------------------------------------------

local function mySeat()
    return Game.humanSeat or Table.mySeat()
end

-- The player id in a seat (nil for bots and empty seats).
local function seatPid(seat)
    local t = Table.cur
    if t then
        local s = t.seats[seat]
        return s and not s.bot and s.pid or nil
    end
    if Game.match and Game.humanSeat == seat then return ns.Net.pid() end
end

local function classColor(pid)
    if not pid or type(GetPlayerInfoByGUID) ~= "function" then return nil end
    local ok, _, classFile = pcall(GetPlayerInfoByGUID, "Player-" .. pid)
    if not ok or not classFile or ns.isSecret(classFile) then return nil end
    local c = RAID_CLASS_COLORS and RAID_CLASS_COLORS[classFile]
    if c then return { c.r, c.g, c.b } end
end

function ui.seatColor(seat)
    local scheme = ns.opt("colors")
    if scheme == "retro" then return RETRO_COLOR end
    local me = mySeat()
    if scheme == "mine" and me then return seat == me and MINE_COLOR or THEIRS_COLOR end
    if scheme == "class" then
        local c = classColor(seatPid(seat))
        if c then return c end
    end
    return SEAT_COLOR[seat]
end

-- Recolors names, scores and markers when who sits where (or the scheme) changes, and every second anyway since a
-- player's class may only become known later.
local function updateColors()
    local now = GetTime()
    local key = ns.opt("colors") .. ";" .. (mySeat() or 0) .. ";" .. (seatPid(1) or "") .. ";" .. (seatPid(2) or "")
    if key == ui.colorKey and now - (ui.colorsAt or 0) < 1 then return end
    ui.colorKey, ui.colorsAt = key, now
    ui.colors = {}
    for seat = 1, 2 do
        local c = ui.seatColor(seat)
        ui.colors[seat] = c
        ui.ghosts[seat]:SetColorTexture(c[1], c[2], c[3], GHOST_ALPHA)
        ui.scores[seat]:SetTextColor(c[1], c[2], c[3], 0.55)
        ui.names[seat]:SetTextColor(c[1], c[2], c[3])
    end
end

-- Paints a paddle in its seat color, blended toward white for a moment after it hits the ball.
local function paintPaddle(seat)
    local c = ui.colors[seat]
    local k = 0
    local hitAt = ui.flash[seat]
    if hitAt and ns.opt("hitFlash") then k = math.max(0, 1 - (GetTime() - hitAt) / FLASH_TIME) end
    ui.paddles[seat]:SetColorTexture(c[1] + (1 - c[1]) * k, c[2] + (1 - c[2]) * k, c[3] + (1 - c[3]) * k, 1)
end

-- Dots where the ball was a moment ago, back to its last paddle hit (or the serve).
local function drawTrail(m, t)
    local n = (m.phase == "play" or m.phase == "point") and (TRAIL_LEN[ns.opt("trail")] or 0) or 0
    for i, dot in ipairs(ui.trail) do
        local tt = t - i * TRAIL_GAP
        local shown = false
        if i <= n and tt > m.ball.t then
            local x, y = Sim.ballPos(m, tt)
            if x >= 0 and x <= Sim.W then
                place(dot, x, y)
                shown = true
            end
        end
        setShown(dot, shown)
    end
end

-- Hold to steer: while the button is down on the board, the target follows the cursor (rate-limited, more so in
-- networked matches where moves are messages).
local function steer()
    local st = ui.steering
    if not st then return end
    local down = type(IsMouseButtonDown) ~= "function" or IsMouseButtonDown("LeftButton")
    if not (ns.opt("holdToSteer") and Game.humanSeat and down) then
        ui.steering = nil
        return
    end
    local now, y = GetTime(), ui.cursorY()
    local gap = Game.networked and STEER_GAP_NET or STEER_GAP
    if math.abs(y - st.y) >= STEER_MIN and now - st.at >= gap then
        Game.click(y)
        st.y, st.at = y, now
    end
end

Game.listeners[#Game.listeners + 1] = function(ev)
    if ev.type == "HIT" then ui.flash[ev.seat] = GetTime() end
    -- Your networked match starting (e.g. the guest pressed Play Now) opens the window if it was closed.
    if ev.type == "START" and Game.networked and Game.humanSeat and ns.opt("autoOpen") and ui.frame
        and not ui.frame:IsShown() then
        ui.frame:Show()
    end
end

Table.onGuestJoined = function()
    if ns.opt("autoOpen") and ui.frame and not ui.frame:IsShown() then ui.frame:Show() end
end

-- "Tell me when a table opens": a new, never-played table heard unprompted. Tables first heard in the minute after
-- login, or right after our own "who's hosting?" query, already existed, so they stay quiet.
local loadedAt = GetTime()
local NOTICE_QUIET, NOTICE_QUERY_GAP = 45, 5

Table.onTableSeen = function(info, now)
    if not ns.opt("tableNotice") or info.version ~= ns.Net.VERSION then return end
    if info.state ~= "open" or info.matchNo ~= 0 or now - loadedAt < NOTICE_QUIET then return end
    if Table.lastQuery and now - Table.lastQuery < NOTICE_QUERY_GAP then return end
    if Game.match and Game.networked and Game.match.phase ~= "over" then return end
    ns.print(info.hostName .. " opened a Pong table - type /pong to sit down")
end

-- Applies window-level options (at build and after every option change).
function ui.applyOptions()
    if not ui.frame then return end
    ui.frame:SetScale(ns.opt("scale"))
    ui.boardBg:SetColorTexture(0, 0, 0, ns.opt("boardAlpha"))
    for _, d in ipairs(ui.dashes) do setShown(d, ns.opt("centerLine")) end
    ui.colorKey, ui.modeKey, ui.lobbyAt = nil, nil, nil
end

table.insert(ns.Options.listeners, function() ui.applyOptions() end)

function ui.render(now)
    local mode = (Table.cur or Game.match) and "table" or "lobby"
    if mode .. (Table.cur and Table.cur.role or "") ~= ui.modeKey then applyMode(mode) end
    updatePointsBtn()
    if mode == "lobby" then
        ui.renderLobby()
        return
    end
    updateColors()
    local m = Game.match
    local t = Table.cur
    setEnabled(ui.playBtn, Table.canStart())
    ui.stopBtn:SetText(t and "Leave" or "Stop")
    if t and t.role == "host" then
        local s1 = t.seats[1]
        ui.seatBtn:SetText((s1 and s1.bot) and "Take My Seat" or "Bot in My Seat")
        setEnabled(ui.seatBtn, not (m and Game.networked and m.phase ~= "over"))
        local s2 = t.seats[2]
        ui.botBtn:SetText((s2 and s2.bot) and "Remove Bot" or "Add Bot")
        setEnabled(ui.botBtn, not (m and Game.networked and m.phase ~= "over") and (not s2 or s2.bot ~= nil))
    end
    if not m then
        local n1, n2 = Table.names()
        for _, dot in ipairs(ui.trail) do dot:Hide() end
        for seat = 1, 2 do
            place(ui.paddles[seat], Sim.PADDLE_X[seat], Sim.H / 2)
            paintPaddle(seat)
            ui.ghosts[seat]:Hide()
            ui.scores[seat]:SetText("0")
        end
        ui.names[1]:SetText(n1 or "")
        ui.names[2]:SetText(n2 or "")
        ui.ball:Hide()
        ui.rally:SetText("")
        local status, hint = Table.status()
        ui.status:SetText(status or "")
        ui.hint:SetText(hint or "")
        return
    end

    steer()
    local ghosts = ns.opt("ghosts")
    for seat = 1, 2 do
        local y = Sim.paddleY(m, seat, now)
        place(ui.paddles[seat], Sim.PADDLE_X[seat], y)
        paintPaddle(seat)
        local target = m.paddles[seat].target
        local wanted = ghosts == "both" or (ghosts == "mine" and seat == Game.humanSeat)
        if wanted and math.abs(target - y) > 0.5 then
            place(ui.ghosts[seat], Sim.PADDLE_X[seat], target)
            ui.ghosts[seat]:Show()
        else
            ui.ghosts[seat]:Hide()
        end
        ui.scores[seat]:SetText(tostring(m.score[seat]))
        ui.names[seat]:SetText(Game.names[seat] or "")
    end

    -- In play the ball waits at a paddle's face until that seat's owner judges it, so it never visibly passes
    -- through a paddle while a verdict is pending. After a miss it flies off the board.
    local t = now
    if m.phase == "play" then
        local _, tA = Sim.arrival(m)
        t = math.min(now, tA)
    end
    local bx, by = Sim.ballPos(m, t)
    if bx < -Sim.BALL_R or bx > Sim.W + Sim.BALL_R then
        ui.ball:Hide()
    else
        place(ui.ball, bx, by)
        ui.ball:Show()
    end
    drawTrail(m, t)

    ui.status:SetText(statusText(m, now))
    ui.rally:SetText(rallyText(m))
    if m.phase == "countdown" and Game.humanSeat then
        ui.hint:SetText("Click the board to move your paddle. First to " .. m.pointsToWin .. ".")
    elseif m.phase == "over" and Table.canStart() then
        ui.hint:SetText("Press Play Now for a rematch")
    else
        ui.hint:SetText("")
    end
end

---------------------------------------------------------------------------
-- Actions and slash commands
---------------------------------------------------------------------------

local function parseLevel(s)
    s = (s or ""):lower()
    if Bot.PROFILES[s] then return s end
end

function ui.show()
    ui.frame:Show()
end

function ui.toggle()
    if ui.frame:IsShown() then ui.frame:Hide() else ui.frame:Show() end
end

function ui.startPractice(level)
    Table.leave(true)
    level = level or ns.db.level or "normal"
    Game.startLocal({ { kind = "human" }, { kind = "bot", level = level } }, ns.opt("points"))
    ui.show()
end

function ui.startDemo(level1, level2)
    Table.leave(true)
    local level = ns.db.level or "normal"
    Game.startLocal({ { kind = "bot", level = level1 or level }, { kind = "bot", level = level2 or level } },
        ns.opt("points"))
    ui.show()
end

-- Widget helpers for other UI files (BetsUI.lua).
ui.lib = { newFrame = newFrame, styleAsPanel = styleAsPanel, newText = newText, newRect = newRect,
    newButton = newButton, setShown = setShown, setEnabled = setEnabled }
ui.FRAME_H, ui.FONT = FRAME_H, FONT

table.insert(ns.onLoaded, build)

ns.commands[""] = function() ui.toggle() end
ns.commands.practice = function(arg) ui.startPractice(parseLevel(arg)) end
ns.commands.demo = function(arg)
    local a, b = arg:match("^(%S*)%s*(%S*)")
    ui.startDemo(parseLevel(a), parseLevel(b))
end
ns.commands.stop = function() Game.stop() end
ns.commands.points = function(arg)
    local n = tonumber(arg)
    local ok = false
    for _, v in ipairs(POINTS_CHOICES) do
        if v == n then ok = true end
    end
    if not ok then
        ns.print("usage: /pong points 1|3|5|7 (now first to " .. ns.opt("points") .. ")")
        return
    end
    ns.Options.set("points", n)
    ns.print("matches you host or practice are now first to " .. n)
end
-- Table commands open the window too.
for _, name in ipairs({ "host", "join", "watch", "bot", "start", "invite" }) do
    local fn = ns.commands[name]
    ns.commands[name] = function(arg)
        fn(arg)
        ui.show()
    end
end
table.insert(ns.help, 1, "/pong - open the lobby (or close the window)")
table.insert(ns.help, 2, "/pong practice [easy|normal|hard] - play against a bot")
table.insert(ns.help, 3, "/pong demo [level] [level] - watch two bots play")
table.insert(ns.help, 4, "/pong stop - end the current match")
table.insert(ns.help, 5, "/pong points 1|3|5|7 - match length for your table and practice")
