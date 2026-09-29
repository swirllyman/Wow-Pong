-- The Pong window: header with names, the board (paddles, ghost targets, ball, scores, status), and a temporary
-- control bar (practice vs bot, watch bots, stop) until the lobby replaces it. Only reads Game/Sim state and
-- sends clicks to Game.click; it never changes a match directly. All widgets live on `ui` (ns._ui for tests).

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
local GHOST_ALPHA = 0.3
local CENTER_DASHES = 15

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
    local bg = newRect(board, "BACKGROUND", 0, 0, 0, 0.92)
    bg:SetAllPoints(board)

    -- dashed centre line
    local dashH = Sim.H / (CENTER_DASHES * 2)
    for i = 0, CENTER_DASHES - 1 do
        local d = newRect(board, "BORDER", 1, 1, 1, 0.18)
        d:SetSize(2, dashH)
        place(d, Sim.W / 2, dashH / 2 + i * dashH * 2 + dashH / 2)
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

    ui.status = newText(board, 22)
    ui.status:SetPoint("CENTER", board, "CENTER", 0, 20)
    ui.status:SetTextColor(1, 0.82, 0)
    ui.hint = newText(board, 12)
    ui.hint:SetPoint("TOP", ui.status, "BOTTOM", 0, -8)
    ui.hint:SetTextColor(0.8, 0.8, 0.8)

    -- Click to move: convert the cursor to board coordinates.
    board:EnableMouse(true)
    board:SetScript("OnMouseDown", function(self)
        local _, cy = GetCursorPosition()
        local y = cy / self:GetEffectiveScale() - (self:GetBottom() or 0)
        Game.click(y)
    end)
end

local function levelLabel()
    return "Bot: " .. Bot.NAMES[ns.db.level or "normal"]
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
    ui.levelBtn:SetPoint("LEFT", ui.practiceBtn, "RIGHT", 6, 0)
    ui.demoBtn = newButton(frame, "Watch Bots", 100, function() ui.startDemo() end)
    ui.demoBtn:SetPoint("LEFT", ui.levelBtn, "RIGHT", 6, 0)
    ui.stopBtn = newButton(frame, "Stop", 60, function()
        if Table.cur then Table.leave() else Game.stop() end
    end)
    ui.stopBtn:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -INSET, 16)
    ui.playBtn = newButton(frame, "Play Now", 80, function() Table.start() end)
    ui.playBtn:SetPoint("RIGHT", ui.stopBtn, "LEFT", -6, 0)
end

local function build()
    local frame = newFrame("Frame", "WoWPongFrame", UIParent, "BackdropTemplate")
    ui.frame = frame
    frame:SetSize(FRAME_W, FRAME_H)
    frame:SetFrameStrata("HIGH")
    frame:SetClampedToScreen(true)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
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

    buildBoard(frame)
    buildFooter(frame)
    frame:SetScript("OnUpdate", function() ui.render(Game.clock()) end)
    frame:Hide()
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

function ui.render(now)
    local m = Game.match
    setEnabled(ui.playBtn, Table.canStart())
    ui.stopBtn:SetText(Table.cur and "Leave" or "Stop")
    if not m then
        local n1, n2 = Table.names()
        for seat = 1, 2 do
            place(ui.paddles[seat], Sim.PADDLE_X[seat], Sim.H / 2)
            ui.ghosts[seat]:Hide()
            ui.scores[seat]:SetText("0")
        end
        ui.names[1]:SetText(n1 or "")
        ui.names[2]:SetText(n2 or "")
        ui.ball:Hide()
        local status, hint = Table.status()
        ui.status:SetText(status or "WoW Pong")
        ui.hint:SetText(hint or "Practice against a bot, or watch two bots play.")
        return
    end

    for seat = 1, 2 do
        local y = Sim.paddleY(m, seat, now)
        place(ui.paddles[seat], Sim.PADDLE_X[seat], y)
        local target = m.paddles[seat].target
        if math.abs(target - y) > 0.5 then
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

    ui.status:SetText(statusText(m, now))
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
    Game.startLocal({ { kind = "human" }, { kind = "bot", level = level } })
    ui.show()
end

function ui.startDemo(level1, level2)
    Table.leave(true)
    local level = ns.db.level or "normal"
    Game.startLocal({ { kind = "bot", level = level1 or level }, { kind = "bot", level = level2 or level } })
    ui.show()
end

table.insert(ns.onLoaded, build)

ns.commands[""] = function() ui.toggle() end
ns.commands.practice = function(arg) ui.startPractice(parseLevel(arg)) end
ns.commands.demo = function(arg)
    local a, b = arg:match("^(%S*)%s*(%S*)")
    ui.startDemo(parseLevel(a), parseLevel(b))
end
ns.commands.stop = function() Game.stop() end
-- Table commands open the window too.
for _, name in ipairs({ "host", "join", "watch", "bot", "start" }) do
    local fn = ns.commands[name]
    ns.commands[name] = function(arg)
        fn(arg)
        ui.show()
    end
end
table.insert(ns.help, 1, "/pong - open or close the Pong window")
table.insert(ns.help, 2, "/pong practice [easy|normal|hard] - play against a bot")
table.insert(ns.help, 3, "/pong demo [level] [level] - watch two bots play")
table.insert(ns.help, 4, "/pong stop - end the current match")
