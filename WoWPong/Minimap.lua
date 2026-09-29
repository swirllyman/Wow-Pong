-- Minimap button (LibDBIcon, bundled in Libs/) and the addon compartment entry. Left-click opens the lobby,
-- right-click opens your stats. Works without the libraries too: then only the compartment entry exists.

local _, ns = ...

local ICON = "Interface\\AddOns\\WoWPong\\Media\\icon"

local Minimap = {}
ns.Minimap = Minimap

local function open(stats)
    local ui = ns._ui
    if not ui or not ui.frame then return end
    if stats then
        ui.showingStats = true
        ui.lobbyAt = nil
        ui.show()
    else
        ui.showingStats = false
        ui.lobbyAt = nil
        ui.toggle()
    end
end

-- Called from the TOC's AddonCompartmentFunc.
function WoWPong_OnCompartmentClick(_, button)
    open(button == "RightButton")
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
        OnClick = function(_, button) open(button == "RightButton") end,
        OnTooltipShow = function(tip)
            tip:AddLine("WoW Pong")
            tip:AddLine(ns.Stats.summary(), 1, 1, 1)
            tip:AddLine("Left-click: tables", 0.8, 0.8, 0.8)
            tip:AddLine("Right-click: your stats", 0.8, 0.8, 0.8)
        end,
    })
    ns.db.minimap = ns.db.minimap or { hide = false }
    local ok, err = pcall(icon.Register, icon, "WoWPong", launcher, ns.db.minimap)
    if not ok then
        ns.log("minimap: register ERROR " .. ns.show(err))
        return
    end
    Minimap.icon = icon
end

table.insert(ns.onLoaded, register)

ns.commands.minimap = function()
    ns.db.minimap = ns.db.minimap or {}
    ns.db.minimap.hide = not ns.db.minimap.hide
    if Minimap.icon then
        if ns.db.minimap.hide then Minimap.icon:Hide("WoWPong") else Minimap.icon:Show("WoWPong") end
    end
    ns.print("minimap button " .. (ns.db.minimap.hide and "hidden" or "shown"))
end
table.insert(ns.help, "/pong minimap - show or hide the minimap button")
