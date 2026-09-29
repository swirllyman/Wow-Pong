-- Bets UI: a side panel next to the window while you're at a table (offers with Take / Cancel, the betting status,
-- your result, and a form to post an offer), and the Ledger view in the lobby (who owes whom, with Settled buttons).

local _, ns = ...
local Bets, Table, Net = ns.Bets, ns.Table, ns.Net
local ui = ns._ui

local PANEL_W = 236
local OFFER_ROWS, OFFER_H = 9, 24
local LEDGER_ROWS, LEDGER_H = 9, 26
local REFRESH = 0.25

local function me() return Net.pid() end

local function seatName(seat)
    local t = Table.cur
    local s = t and t.seats[seat]
    return s and s.name or ("Seat " .. seat)
end

local function mySeat()
    return Table.mySeat()
end

---------------------------------------------------------------------------
-- Side panel
---------------------------------------------------------------------------

local function placeBet()
    local copper = Bets.parseGold(ui.betAmount:GetText())
    if not copper then
        ns.print("enter an amount in gold, e.g. 10 or 2.5 (or 1g 50s)")
        return
    end
    if Bets.post(ui.betSide or 1, copper) then
        ui.betAmount:SetText("")
        ui.betAmount:ClearFocus()
    end
    ui.betsAt = nil
end

local function buildPanel()
    local L = ui.lib
    local p = L.newFrame("Frame", "WoWPongBets", ui.frame, "BackdropTemplate")
    ui.betsPanel = p
    p:SetSize(PANEL_W, ui.FRAME_H)
    p:SetPoint("TOPLEFT", ui.frame, "TOPRIGHT", -4, 0)
    L.styleAsPanel(p)
    p:EnableMouse(true)

    local title = L.newText(p, 14)
    title:SetPoint("TOP", p, "TOP", 0, -16)
    title:SetTextColor(1, 0.82, 0)
    title:SetText("Bets")
    local sub = L.newText(p, 10)
    sub:SetPoint("TOP", title, "BOTTOM", 0, -3)
    sub:SetTextColor(0.7, 0.7, 0.7)
    sub:SetText("even money - settled by trade")

    ui.betStatus = L.newText(p, 11)
    ui.betStatus:SetPoint("TOPLEFT", p, "TOPLEFT", 16, -54)
    ui.betStatus:SetWidth(PANEL_W - 32)
    ui.betStatus:SetJustifyH("LEFT")
    ui.betStatus:SetText("")

    ui.offerRows = {}
    for i = 1, OFFER_ROWS do
        local row = L.newFrame("Frame", nil, p)
        row:SetSize(PANEL_W - 28, OFFER_H - 2)
        row:SetPoint("TOPLEFT", p, "TOPLEFT", 14, -86 - (i - 1) * OFFER_H)
        local bg = L.newRect(row, "BACKGROUND", 1, 1, 1, 0.05)
        bg:SetAllPoints(row)
        row.text = L.newText(row, 11)
        row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
        row.text:SetWidth(PANEL_W - 96)
        row.text:SetJustifyH("LEFT")
        row.btn = L.newButton(row, "Take", 56, function()
            local o = row.offer
            if not o then return end
            if o.pid == me() then Bets.withdraw(o.id) else Bets.take(o.id) end
            ui.betsAt = nil
        end)
        row.btn:SetPoint("RIGHT", row, "RIGHT", -2, 0)
        row:Hide()
        ui.offerRows[i] = row
    end
    ui.betMore = L.newText(p, 10)
    ui.betMore:SetPoint("TOPLEFT", p, "TOPLEFT", 18, -86 - OFFER_ROWS * OFFER_H)
    ui.betMore:SetTextColor(0.7, 0.7, 0.7)
    ui.betMore:SetText("")

    -- Post an offer: side, amount (gold), Bet.
    ui.betSideBtn = L.newButton(p, "On: Seat 1", PANEL_W - 32, function()
        ui.betSide = 3 - (ui.betSide or 1)
        ui.betsAt = nil
    end)
    ui.betSideBtn:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 16, 46)
    local eb = L.newFrame("EditBox", "WoWPongBetAmount", p, "InputBoxTemplate")
    ui.betAmount = eb
    if not eb.fontTemplate then
        if ChatFontNormal then eb:SetFontObject(ChatFontNormal) else eb:SetFont(ui.FONT, 12, "") end
    end
    eb:SetSize(90, 20)
    eb:SetAutoFocus(false)
    eb:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", 22, 18)
    eb:SetScript("OnEnterPressed", placeBet)
    eb:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    eb:SetText("")
    local g = L.newText(p, 12)
    g:SetPoint("LEFT", eb, "RIGHT", 4, 0)
    g:SetText("gold")
    ui.betBtn = L.newButton(p, "Bet", 60, placeBet)
    ui.betBtn:SetPoint("BOTTOMRIGHT", p, "BOTTOMRIGHT", -16, 17)

    p:SetScript("OnUpdate", function() ui.renderBets() end)
    p:Hide()
end

local function offerText(o)
    local color = o.status == "matched" and "|cff80ff80" or "|cffffffff"
    local text = string.format("%s%s: %s on %s|r", color, o.name, Bets.money(o.amount), seatName(o.side))
    if o.status == "matched" then text = text .. " |cffaaaaaa- " .. (o.takerName or "?") .. "|r" end
    return text
end

function ui.renderBets()
    local now = GetTime()
    if ui.betsAt and now - ui.betsAt < REFRESH then return end
    ui.betsAt = now
    local L = ui.lib
    local t = Table.cur
    if not t then return end

    local open = Bets.openRound() ~= nil
    local full = t.seats[1] ~= nil and t.seats[2] ~= nil
    local status
    if not open then
        status = "|cffff8080Betting closed|r - match in progress"
    elseif not full then
        status = "Bets open once both seats are filled"
    else
        status = "|cff80ff80Betting open|r until Play Now. Unmatched offers are void then."
    end
    local result = Bets.results[t.host]
    if result and open then status = status .. "\n|cffffd100" .. result .. "|r" end
    ui.betStatus:SetText(status)

    local offers = Bets.offers()
    for i, row in ipairs(ui.offerRows) do
        local o = offers[i]
        row.offer = o
        if o then
            row.text:SetText(offerText(o))
            if o.status == "matched" then
                L.setShown(row.btn, false)
            elseif o.pid == me() then
                row.btn:SetText("Cancel")
                L.setShown(row.btn, true)
                L.setEnabled(row.btn, open)
            else
                row.btn:SetText(o.taking and "..." or "Take")
                L.setShown(row.btn, true)
                local seat = mySeat()
                L.setEnabled(row.btn, open and not o.taking and (not seat or seat == 3 - o.side))
            end
            row:Show()
        else
            row:Hide()
        end
    end
    ui.betMore:SetText(#offers > OFFER_ROWS and ("+" .. (#offers - OFFER_ROWS) .. " more") or "")

    local seat = mySeat()
    if seat then ui.betSide = seat end
    ui.betSide = ui.betSide or 1
    ui.betSideBtn:SetText("On: " .. seatName(ui.betSide))
    L.setEnabled(ui.betSideBtn, open and not seat)
    L.setEnabled(ui.betBtn, Bets.cantPost(ui.betSide) == nil)
end

---------------------------------------------------------------------------
-- Ledger (lobby)
---------------------------------------------------------------------------

local function buildLedger()
    local L = ui.lib
    local f = L.newFrame("Frame", "WoWPongLedger", ui.lobby)
    ui.ledger = f
    f:SetPoint("TOPLEFT", ui.lobby, "TOPLEFT", 6, -32)
    f:SetPoint("BOTTOMRIGHT", ui.lobby, "BOTTOMRIGHT", -6, 6)
    ui.ledgerRows = {}
    for i = 1, LEDGER_ROWS do
        local row = L.newFrame("Frame", nil, f)
        row:SetSize(ns.Sim.W - 12, LEDGER_H - 2)
        row:SetPoint("TOPLEFT", f, "TOPLEFT", 0, -(i - 1) * LEDGER_H)
        local bg = L.newRect(row, "BACKGROUND", 1, 1, 1, 0.05)
        bg:SetAllPoints(row)
        row.text = L.newText(row, 12)
        row.text:SetPoint("LEFT", row, "LEFT", 8, 0)
        row.btn = L.newButton(row, "Settled", 70, function()
            if row.pid then Bets.settle(row.pid) end
            ui.lobbyAt = nil
        end)
        row.btn:SetPoint("RIGHT", row, "RIGHT", -4, 0)
        row:Hide()
        ui.ledgerRows[i] = row
    end
    ui.ledgerNote = L.newText(f, 11)
    ui.ledgerNote:SetPoint("BOTTOM", f, "BOTTOM", 0, 6)
    ui.ledgerNote:SetTextColor(0.7, 0.7, 0.7)
    ui.ledgerNote:SetText("")
    f:Hide()
end

function ui.renderLedger()
    ui.ledger:Show()
    local list = Bets.balances()
    for i, row in ipairs(ui.ledgerRows) do
        local e = list[i]
        row.pid = e and e.pid
        if e then
            if e.balance > 0 then
                row.text:SetText(string.format("|cff80ff80%s owes you %s|r", e.name, Bets.money(e.balance)))
            else
                row.text:SetText(string.format("|cffff8080You owe %s %s|r", e.name, Bets.money(-e.balance)))
            end
            row:Show()
        else
            row:Hide()
        end
    end
    if #list == 0 then
        ui.ledgerNote:SetText("Nobody owes anybody anything.")
    else
        ui.ledgerNote:SetText("Trading with someone fills in / records the gold. 'Settled' clears a balance by hand.")
    end
end

function ui.hideLedger()
    if ui.ledger then ui.ledger:Hide() end
end

table.insert(ns.onLoaded, function()
    buildPanel()
    buildLedger()
end)
