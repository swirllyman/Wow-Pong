-- The options dialog: four tabs (Display, Play, Social, General) of rows built from the SPECS below, each row a
-- label plus a checkbox, a cycling choice button (right-click goes back), a < value > stepper, or an action button
-- (dangerous ones ask for a second click). Changes apply at once. Opened from the lobby's Options button,
-- /pong options, a middle/shift-click on the minimap button, or the game's own Settings > AddOns page.

local _, ns = ...
local Options, Bot, Table = ns.Options, ns.Bot, ns.Table
local ui = ns._ui

local W, H = 400, 404
local ROW_H, ROWS_TOP = 30, 76
local CONTROL_W = 150
local CONFIRM_TIME = 4
local TABS = { "Display", "Play", "Social", "General" }

---------------------------------------------------------------------------
-- What's on each tab
---------------------------------------------------------------------------

local function percent(v) return string.format("%d%%", math.floor(v * 100 + 0.5)) end

local function levelChoices()
    local out = {}
    for _, l in ipairs(Bot.LEVELS) do out[#out + 1] = { l, Bot.NAMES[l] } end
    return out
end

local function resetWindowPosition()
    ns.db.pos = nil
    ui.frame:ClearAllPoints()
    ui.frame:SetPoint("CENTER", UIParent, "CENTER", 0, 60)
end

local SPECS = {
    Display = {
        { key = "scale", kind = "range", label = "Window size", min = 0.7, max = 1.5, step = 0.1, fmt = percent,
            desc = "Scales the Pong window and the bets panel." },
        { key = "lockWindow", kind = "toggle", label = "Lock window position",
            desc = "The window can't be dragged while this is on." },
        { key = "colors", kind = "choice", label = "Paddle colors",
            choices = { { "classic", "Blue vs red" }, { "mine", "Me vs them" }, { "class", "Class colors" },
                { "retro", "Retro white" } },
            desc = "Blue vs red: by seat. Me vs them: you're green, your opponent red. Class colors: each "
                .. "player's class (bots keep blue/red). Retro: all white, like 1972." },
        { key = "ghosts", kind = "choice", label = "Target markers",
            choices = { { "both", "Both players" }, { "mine", "Mine only" }, { "off", "Off" } },
            desc = "The faint paddle showing where a paddle is heading." },
        { key = "trail", kind = "choice", label = "Ball trail",
            choices = { { "off", "Off" }, { "short", "Short" }, { "long", "Long" } },
            desc = "A fading trail behind the ball." },
        { key = "hitFlash", kind = "toggle", label = "Flash paddles on hits",
            desc = "A paddle glows white for a moment when it returns the ball." },
        { key = "boardAlpha", kind = "range", label = "Board darkness", min = 0.4, max = 1, step = 0.1,
            fmt = percent, desc = "How opaque the board's black background is." },
        { key = "centerLine", kind = "toggle", label = "Center line", desc = "The dashed line down the middle." },
    },
    Play = {
        { id = "level", kind = "choice", label = "Bot difficulty", choices = levelChoices(),
            get = function() return ns.db.level or "normal" end,
            set = function(v)
                ns.db.level = v
                if ui.levelBtn then ui.levelBtn:SetText("Bot: " .. Bot.NAMES[v]) end
            end,
            desc = "For Practice vs Bot, Watch Bots and the bots you add to your table." },
        { key = "points", kind = "choice", label = "Match length",
            choices = { { 1, "First to 1" }, { 3, "First to 3" }, { 5, "First to 5" }, { 7, "First to 7" } },
            desc = "Matches at the table you host, Practice vs Bot and Watch Bots. Players at someone else's "
                .. "table play to that host's setting." },
        { key = "holdToSteer", kind = "toggle", label = "Hold to steer",
            desc = "Hold the mouse button on the board and your paddle keeps heading for the cursor. "
                .. "Off: each click sets one target." },
        { key = "smoothLag", kind = "toggle", label = "Smooth network lag",
            desc = "The ball bounces off the other player's paddle right away instead of waiting for their "
                .. "client to confirm the hit, and late updates glide into place instead of jumping. "
                .. "Only changes what you see, never the score." },
        { key = "autoOpen", kind = "toggle", label = "Open window for my matches",
            desc = "Opens the Pong window when someone sits at your table or your match starts." },
    },
    Social = {
        { key = "invites", kind = "choice", label = "Invites",
            choices = { { "ask", "Ask me" }, { "friends", "Friends & guild" }, { "none", "Decline all" } },
            desc = "Friends & guild: invites from anyone else are declined for you. "
                .. "Declined players are told you declined." },
        { key = "tableNotice", kind = "toggle", label = "Tell me when a table opens",
            desc = "A chat line when someone opens a new table." },
        { key = "hideOtherVersions", kind = "toggle", label = "Hide other-version tables",
            desc = "Leaves tables you can't join (a different WoW Pong version) out of the lobby." },
        { key = "betsPanel", kind = "toggle", label = "Show the bets panel",
            desc = "The panel beside the window at a table. Your ledger stays in the lobby either way." },
        { key = "tradeAssist", kind = "toggle", label = "Fill in gold I owe",
            desc = "When you open a trade with someone you owe from bets, their gold goes into the window "
                .. "(you still press Trade)." },
    },
    General = {
        { id = "minimap", kind = "toggle", label = "Minimap button",
            get = function() return not (ns.db.minimap and ns.db.minimap.hide) end,
            set = function(v) ns.Minimap.setHidden(not v) end,
            desc = "Also /pong minimap. The addon compartment entry is always there." },
        { id = "minimapLock", kind = "toggle", label = "Lock minimap button",
            get = function() return ns.db.minimap and ns.db.minimap.lock or false end,
            set = function(v) ns.Minimap.setLocked(v) end,
            desc = "Stops the minimap button from being dragged around the minimap." },
        { id = "echo", kind = "toggle", label = "Echo debug log to chat",
            get = function() return ns.db.echo or false end,
            set = function(v) ns.db.echo = v or nil end,
            desc = "Prints every line of WoW Pong's debug log to chat. Noisy; for bug hunting." },
        { id = "resetPos", kind = "button", label = "Window position", text = "Center it",
            run = resetWindowPosition, desc = "Puts the Pong window back in the middle of the screen." },
        { id = "clearLog", kind = "button", label = "Debug log", text = "Clear",
            run = function()
                ns.db.log = {}
                ns.print("log cleared")
            end,
            desc = "Empties the saved debug log." },
        { id = "resetStats", kind = "button", label = "This character's stats", text = "Reset", confirm = true,
            run = function()
                ns.cdb.stats = nil
                ns.print("stats reset")
            end,
            desc = "Forgets every win, loss and head-to-head record of this character. Can't be undone." },
        { id = "defaults", kind = "button", label = "Everything above", text = "Restore defaults",
            confirm = true,
            run = function()
                Options.reset()
                ns.db.level = nil
                ns.db.echo = nil
                ns.Minimap.setHidden(false)
                ns.Minimap.setLocked(false)
                if ui.levelBtn then ui.levelBtn:SetText("Bot: " .. Bot.NAMES.normal) end
                resetWindowPosition()
                ns.print("options restored to defaults")
            end,
            desc = "Every option on every tab back to how it started (stats and the ledger are kept)." },
    },
}
ui.optionSpecs = SPECS

local function getValue(spec)
    if spec.get then return spec.get() end
    return Options.get(spec.key)
end

local function setValue(spec, v)
    if spec.set then spec.set(v) else Options.set(spec.key, v) end
    ui.refreshOptions()
end

---------------------------------------------------------------------------
-- Controls
---------------------------------------------------------------------------

local function choiceIndex(spec, v)
    for i, c in ipairs(spec.choices) do
        if c[1] == v then return i end
    end
    return 1
end

local function newCheck(parent, spec)
    local L = ui.lib
    local b = L.newFrame("Button", nil, parent)
    b:SetSize(26, 26)
    local box = b:CreateTexture(nil, "ARTWORK")
    box:SetTexture("Interface\\Buttons\\UI-CheckBox-Up")
    box:SetAllPoints(b)
    b.check = b:CreateTexture(nil, "OVERLAY")
    b.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    b.check:SetAllPoints(b)
    pcall(b.SetHighlightTexture, b, "Interface\\Buttons\\UI-CheckBox-Highlight", "ADD")
    b:SetScript("OnClick", function() setValue(spec, not getValue(spec)) end)
    b.update = function()
        b.checked = getValue(spec) and true or false
        L.setShown(b.check, b.checked)
    end
    return b
end

local function newChoice(parent, spec)
    local b = ui.lib.newButton(parent, "", CONTROL_W, function(_, button)
        local n = #spec.choices
        local i = choiceIndex(spec, getValue(spec))
        i = (button == "RightButton") and ((i - 2) % n + 1) or (i % n + 1)
        setValue(spec, spec.choices[i][1])
    end)
    pcall(b.RegisterForClicks, b, "LeftButtonUp", "RightButtonUp")
    b.update = function() b:SetText(spec.choices[choiceIndex(spec, getValue(spec))][2]) end
    return b
end

local function newRange(parent, spec)
    local L = ui.lib
    local f = L.newFrame("Frame", nil, parent)
    f:SetSize(CONTROL_W, 22)
    local function nudge(dir)
        local v = getValue(spec) + dir * spec.step
        v = math.floor(v / spec.step + 0.5) * spec.step   -- no float creep after many clicks
        setValue(spec, math.max(spec.min, math.min(spec.max, v)))
    end
    f.down = L.newButton(f, "<", 26, function() nudge(-1) end)
    f.down:SetPoint("LEFT", f, "LEFT", 0, 0)
    f.up = L.newButton(f, ">", 26, function() nudge(1) end)
    f.up:SetPoint("RIGHT", f, "RIGHT", 0, 0)
    f.value = L.newText(f, 13)
    f.value:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.value:SetText("")
    f.nudge = nudge
    f.update = function()
        local v = getValue(spec)
        f.value:SetText(spec.fmt and spec.fmt(v) or tostring(v))
        L.setEnabled(f.down, v > spec.min + 1e-6)
        L.setEnabled(f.up, v < spec.max - 1e-6)
    end
    return f
end

-- An action button; with spec.confirm the first click only arms it ("Sure? Click again") for a few seconds.
local function newAction(parent, spec)
    local b
    b = ui.lib.newButton(parent, spec.text, CONTROL_W, function()
        if spec.confirm and not (b.armedUntil and GetTime() < b.armedUntil) then
            b.armedUntil = GetTime() + CONFIRM_TIME
            b:SetText("Sure? Click again")
            return
        end
        b.armedUntil = nil
        b:SetText(spec.text)
        spec.run()
        ui.refreshOptions()
    end)
    b.update = function()
        if b.armedUntil and GetTime() >= b.armedUntil then
            b.armedUntil = nil
            b:SetText(spec.text)
        end
    end
    return b
end

local BUILDERS = { toggle = newCheck, choice = newChoice, range = newRange, button = newAction }

---------------------------------------------------------------------------
-- The dialog
---------------------------------------------------------------------------

local function setHint(text)
    ui.optionsHint:SetText(text or "Hover over an option for details. Changes apply right away.")
end

local function buildRow(page, spec, i)
    local L = ui.lib
    local row = L.newFrame("Frame", nil, page)
    row:SetSize(W - 40, ROW_H - 4)
    row:SetPoint("TOPLEFT", page, "TOPLEFT", 0, -(i - 1) * ROW_H)
    local bg = L.newRect(row, "BACKGROUND", 1, 1, 1, i % 2 == 0 and 0.03 or 0.07)
    bg:SetAllPoints(row)
    row.label = L.newText(row, 12)
    row.label:SetPoint("LEFT", row, "LEFT", 8, 0)
    row.label:SetJustifyH("LEFT")
    row.label:SetTextColor(0.95, 0.9, 0.75)
    row.label:SetText(spec.label)
    row.control = BUILDERS[spec.kind](row, spec)
    if spec.kind == "toggle" then
        row.control:SetPoint("RIGHT", row, "RIGHT", -CONTROL_W + 22, 0)
    else
        row.control:SetPoint("RIGHT", row, "RIGHT", -4, 0)
    end
    row.spec = spec
    -- Hovering shows the description; clicking a toggle's label flips it too.
    local function enter() setHint(spec.desc) end
    local function leave() setHint(nil) end
    row:EnableMouse(true)
    row:SetScript("OnEnter", enter)
    row:SetScript("OnLeave", leave)
    local hover = row.control.down and { row.control.down, row.control.up } or { row.control }
    for _, w in ipairs(hover) do
        w:SetScript("OnEnter", enter)
        w:SetScript("OnLeave", leave)
    end
    if spec.kind == "toggle" then
        row:SetScript("OnMouseDown", function() setValue(spec, not getValue(spec)) end)
    end
    return row
end

function ui.selectOptionsTab(name)
    ui.optionsTab = name
    for _, tab in ipairs(TABS) do
        ui.lib.setShown(ui.optionPages[tab], tab == name)
        ui.lib.setShown(ui.optionTabs[tab].mark, tab == name)
    end
    setHint(nil)
    ui.refreshOptions()
end

local function build()
    local L = ui.lib
    local f = L.newFrame("Frame", "WoWPongOptions", UIParent, "BackdropTemplate")
    ui.options = f
    f:SetSize(W, H)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    L.styleAsPanel(f)
    table.insert(UISpecialFrames, "WoWPongOptions")   -- Esc closes it

    local close = L.newFrame("Button", nil, f, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", f, "TOPRIGHT", -4, -4)
    close:SetScript("OnClick", function() f:Hide() end)
    local title = L.newText(f, 14)
    title:SetPoint("TOP", f, "TOP", 0, -16)
    title:SetTextColor(1, 0.82, 0)
    title:SetText("WoW Pong Options")

    ui.optionTabs, ui.optionPages, ui.optionRows = {}, {}, {}
    local tabW = (W - 40) / #TABS
    for i, name in ipairs(TABS) do
        local tab = L.newButton(f, name, tabW - 4, function() ui.selectOptionsTab(name) end)
        tab:SetPoint("TOPLEFT", f, "TOPLEFT", 20 + (i - 1) * tabW + 2, -40)
        tab.mark = L.newRect(tab, "OVERLAY", 1, 0.82, 0, 0.9)
        tab.mark:SetHeight(2)
        tab.mark:SetPoint("BOTTOMLEFT", tab, "BOTTOMLEFT", 4, -4)
        tab.mark:SetPoint("BOTTOMRIGHT", tab, "BOTTOMRIGHT", -4, -4)
        ui.optionTabs[name] = tab

        local page = L.newFrame("Frame", nil, f)
        page:SetPoint("TOPLEFT", f, "TOPLEFT", 20, -ROWS_TOP)
        page:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -20, 56)
        ui.optionPages[name] = page
        for r, spec in ipairs(SPECS[name]) do
            ui.optionRows[spec.key or spec.id] = buildRow(page, spec, r)
        end
    end

    ui.optionsHint = L.newText(f, 11)
    ui.optionsHint:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 22, 18)
    ui.optionsHint:SetWidth(W - 44)
    ui.optionsHint:SetHeight(36)
    ui.optionsHint:SetJustifyH("LEFT")
    ui.optionsHint:SetJustifyV("TOP")
    ui.optionsHint:SetTextColor(0.75, 0.75, 0.75)

    f:SetScript("OnShow", function() ui.refreshOptions() end)
    f:SetScript("OnUpdate", function()   -- disarms confirm buttons that weren't clicked again
        for _, row in pairs(ui.optionRows) do
            if row.control.armedUntil then row.control.update() end
        end
    end)
    ui.selectOptionsTab(TABS[1])
    f:Hide()
end

function ui.refreshOptions()
    if not ui.optionRows then return end
    for _, row in pairs(ui.optionRows) do row.control.update() end
    local lock = ui.optionRows.minimapLock
    ui.lib.setEnabled(lock.control, not (ns.db.minimap and ns.db.minimap.hide))
end

function ui.showOptions(tab)
    if tab then ui.selectOptionsTab(tab) end
    ui.options:Show()
end

function ui.toggleOptions()
    if ui.options:IsShown() then ui.options:Hide() else ui.showOptions() end
end

---------------------------------------------------------------------------
-- The game's Settings > AddOns page: a short blurb and a button that opens the dialog
---------------------------------------------------------------------------

local function registerSettings()
    local L = ui.lib
    local canvas = L.newFrame("Frame", "WoWPongSettingsCanvas", UIParent)
    canvas:Hide()
    local title = L.newText(canvas, 16)
    title:SetPoint("TOPLEFT", canvas, "TOPLEFT", 16, -16)
    title:SetTextColor(1, 0.82, 0)
    title:SetText("WoW Pong")
    local blurb = L.newText(canvas, 12)
    blurb:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -10)
    blurb:SetWidth(420)
    blurb:SetJustifyH("LEFT")
    blurb:SetText("1v1 click-to-move Pong with spectators. Type /pong to open the lobby.\n\n"
        .. "The options live in their own window, so you can tweak them while you watch the board.")
    local open = L.newButton(canvas, "Open WoW Pong Options", 200, function()
        if SettingsPanel and type(HideUIPanel) == "function" then pcall(HideUIPanel, SettingsPanel) end
        ui.showOptions()
    end)
    open:SetPoint("TOPLEFT", blurb, "BOTTOMLEFT", 0, -16)
    ui.settingsCanvas = canvas

    local ok, err = pcall(function()
        if Settings and Settings.RegisterCanvasLayoutCategory then
            local cat = Settings.RegisterCanvasLayoutCategory(canvas, "WoW Pong")
            Settings.RegisterAddOnCategory(cat)
            ui.settingsCategory = cat
        elseif InterfaceOptions_AddCategory then
            canvas.name = "WoW Pong"
            InterfaceOptions_AddCategory(canvas)
        else
            ns.log("options: no Settings API; /pong options only")
        end
    end)
    if not ok then ns.log("options: settings registration ERROR " .. ns.show(err)) end
end

table.insert(ns.onLoaded, function()
    build()
    registerSettings()
end)

ns.commands.options = function() ui.toggleOptions() end
ns.commands.config = ns.commands.options
ns.commands.settings = ns.commands.options
table.insert(ns.help, 5, "/pong options - the options window (also /pong config)")
