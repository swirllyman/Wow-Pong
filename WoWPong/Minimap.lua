-- Minimap button (LibDBIcon, bundled in Libs/) and the addon compartment entry. Left-click opens the lobby,
-- right-click opens your stats, middle-click (or shift-click) the options. Works without the libraries too: then
-- only the compartment entry exists.

local _, ns = ...

local ICON = "Interface\\AddOns\\WoWPong\\Media\\icon"

local Minimap = {}
ns.Minimap = Minimap

local function open(stats, options)
    local ui = ns._ui
    if not ui or not ui.frame then return end
    if options then
        if ui.toggleOptions then ui.toggleOptions() end
    elseif stats then
        ui.showingStats = true
        ui.lobbyAt = nil
        ui.show()
    else
        ui.showingStats = false
        ui.lobbyAt = nil
        ui.toggle()
    end
end

local function wantsOptions(button)
    return button == "MiddleButton" or (type(IsShiftKeyDown) == "function" and IsShiftKeyDown() and true or false)
end

-- Called from the TOC's AddonCompartmentFunc.
function WoWPong_OnCompartmentClick(_, button)
    open(button == "RightButton", wantsOptions(button))
end

local function register()
    local stub = _G.LibStub
    local ldb = stub and stub("LibDataBroker-1.1", true)
    local icon = stub and stub("LibDBIcon-1.0", true)
    if not (ldb and icon) then
        ns.log("minimap: libraries not available")
        return
    end
    local launcher = ldb:NewDataObject("WoWPong", {
        type = "launcher",
        text = "WoW Pong",
        icon = ICON,
        OnClick = function(_, button) open(button == "RightButton", wantsOptions(button)) end,
        OnTooltipShow = function(tip)
            tip:AddLine("WoW Pong")
            tip:AddLine(ns.Stats.summary(), 1, 1, 1)
            tip:AddLine("Left-click: tables", 0.8, 0.8, 0.8)
            tip:AddLine("Right-click: your stats", 0.8, 0.8, 0.8)
            tip:AddLine("Middle- or Shift-click: options", 0.8, 0.8, 0.8)
        end,
    })
    ns.db.minimap = ns.db.minimap or { hide = false }
    local ok, err = pcall(icon.Register, icon, "WoWPong", launcher, ns.db.minimap)
    if not ok then
        ns.log("minimap: register ERROR " .. ns.show(err))
        return
    end
    Minimap.icon = icon
    Minimap.applyLock()
end

-- Shows/hides the button and locks/unlocks dragging it, from ns.db.minimap (the options panel changes these).
function Minimap.setHidden(hide)
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.hide = hide
    if Minimap.icon then
        if hide then Minimap.icon:Hide("WoWPong") else Minimap.icon:Show("WoWPong") end
    end
end

function Minimap.applyLock()
    local icon = Minimap.icon
    if not icon then return end
    local fn = ns.db.minimap.lock and icon.Lock or icon.Unlock
    if type(fn) == "function" then pcall(fn, icon, "WoWPong") end
end

function Minimap.setLocked(lock)
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.lock = lock or nil
    Minimap.applyLock()
end

table.insert(ns.onLoaded, register)

ns.commands.minimap = function()
    Minimap.setHidden(not (ns.db.minimap and ns.db.minimap.hide))
    ns.print("minimap button " .. (ns.db.minimap.hide and "hidden" or "shown"))
end
table.insert(ns.help, "/pong minimap - show or hide the minimap button")
