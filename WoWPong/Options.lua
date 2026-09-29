-- Options: the settings model. Values live in WoWPongDB.opts (account wide); anything not set there reads as its
-- default, so new options need no migration and "Restore defaults" is just emptying the table. Other files read
-- values with ns.opt(key) and hear about changes through Options.listeners. The panel is in OptionsUI.lua.

local _, ns = ...

local Options = {}
ns.Options = Options

Options.defaults = {
    -- Display
    scale = 1,               -- window scale
    lockWindow = false,      -- no dragging the window
    colors = "classic",      -- classic (blue/red by seat), mine (you green, them red), class, retro (white)
    ghosts = "both",         -- target markers: both, mine, off
    trail = "off",           -- ball trail: off, short, long
    hitFlash = true,         -- paddles flash on a hit
    smoothLag = true,        -- predict remote bounces and glide out ball corrections (display only)
    boardAlpha = 0.9,        -- board background opacity
    centerLine = true,
    -- Play
    points = 7,              -- first to this many points: my table's matches, practice and Watch Bots
    holdToSteer = false,     -- holding the mouse on the board keeps moving your target
    autoOpen = true,         -- open the window when someone sits at my table or my match starts
    -- Social
    invites = "ask",         -- ask, friends (friends/guild only, others declined), none (decline all)
    tableNotice = false,     -- print a chat line when someone opens a table
    hideOtherVersions = false,
    betsPanel = true,
    tradeAssist = true,      -- put the gold you owe into the trade window
}

Options.listeners = {}   -- functions(key, value) called after a change (key is nil after a full reset)

local function store()
    if not ns.db then return nil end
    ns.db.opts = ns.db.opts or {}
    return ns.db.opts
end

function Options.get(key)
    local s = store()
    local v = s and s[key]
    if v == nil then return Options.defaults[key] end
    return v
end

local function notify(key, value)
    for _, fn in ipairs(Options.listeners) do
        local ok, err = pcall(fn, key, value)
        if not ok then ns.log("options listener: ERROR " .. tostring(err)) end
    end
end

function Options.set(key, value)
    local s = store()
    if not s then return end
    if value == Options.defaults[key] then value = nil end   -- keep only what differs from the defaults
    s[key] = value
    notify(key, Options.get(key))
end

function Options.reset()
    if not ns.db then return end
    ns.db.opts = {}
    notify(nil, nil)
end

ns.opt = Options.get
