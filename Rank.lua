-- AH Upgrades: ranking.
-- Every saved gear listing is judged by PawnForever exactly as its green bag arrows are (PawnForever.Upgrades:Check:
-- your weights, your worn gear, the weaker ring/trinket, weapons as a pair, usable by you now). The upgrades are
-- then sorted by value: % upgrade per gold.
local _, A = ...

local results = {}     -- { link, name, price, n, slot, gainText, gain, value, icon, quality }
local status = "idle"  -- idle, working, done, nopawn, nodata
local progress, totalToCheck = 0, 0
local runToken = 0

A.SLOT_NAMES = {
    [1] = "Head", [2] = "Neck", [3] = "Shoulder", [5] = "Chest", [6] = "Waist", [7] = "Legs", [8] = "Feet",
    [9] = "Wrist", [10] = "Hands", [11] = "Ring", [12] = "Ring", [13] = "Trinket", [14] = "Trinket", [15] = "Back",
    [16] = "Main hand", [17] = "Off hand", [18] = "Ranged",
}

-- Paper-doll order; both ring slots sort together, as do both trinket slots
local SLOT_ORDER = { [1] = 1, [2] = 2, [3] = 3, [15] = 4, [5] = 5, [9] = 6, [10] = 7, [6] = 8, [7] = 9, [8] = 10,
    [11] = 11, [12] = 11, [13] = 12, [14] = 12, [16] = 13, [17] = 14, [18] = 15 }

local function Pawn()
    local p = _G.PawnForever
    if p and p.ready and p.Upgrades and p.Upgrades.Check then return p end
end

function A.Results() return results end
function A.RankStatus() return status, progress, totalToCheck end

-- Each sort: the column's key and its natural direction (true = highest first). A.db.sortReverse flips the
-- direction. Ties are always broken by best value, then cheapest.
A.SORTS = {
    name = { function(r) return (r.name or ""):lower() end, false },
    slot = { function(r) return r.slotOrder or 99 end, false }, -- paper-doll order, Head to Ranged
    gain = { function(r) return r.gain end, true },
    price = { function(r) return r.price end, false },
    value = { function(r) return r.value end, true },
}

function A.SortResults()
    local s = A.SORTS[A.db.sort] or A.SORTS.value
    local key, desc = s[1], s[2]
    if A.db.sortReverse then desc = not desc end
    table.sort(results, function(a, b)
        local ka, kb = key(a), key(b)
        if ka ~= kb then
            if desc then return ka > kb end
            return ka < kb
        end
        if a.value ~= b.value then return a.value > b.value end
        return a.price < b.price
    end)
end

local BUDGET_MS = 10
local function Milliseconds() return debugprofilestop and debugprofilestop() or GetTime() * 1000 end
local GetItemInfo = C_Item and C_Item.GetItemInfo or _G.GetItemInfo

------------------------------------------------------------------------
-- Where the listings come from
--
-- 1. Our own capture of this realm's last full scan: real links, random enchants included.
-- 2. Otherwise ForeverCraftAssistant's saved prices (item IDs only): this realm, or else the realm with the most
--    prices for your faction (labeled). Random-enchant items there are judged on their base item only.
------------------------------------------------------------------------

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or _G.GetItemInfoInstant
local SKIP_LOC = { [""] = true, INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true,
    INVTYPE_QUIVER = true, INVTYPE_AMMO = true, INVTYPE_NON_EQUIP_IGNORE = true }

local function FCARealmPrices()
    local root = _G.ForeverCraftAssistantDB
    local realms = type(root) == "table" and type(root.realms) == "table" and root.realms
    if not realms then return nil end
    local own = A.RealmKey()
    if realms[own] and type(realms[own].prices) == "table" and next(realms[own].prices) then
        return realms[own].prices, nil, realms[own].lastScanAt
    end
    local faction = "%-" .. (UnitFactionGroup("player") or "Neutral") .. "$"
    local best, bestN
    for key, data in pairs(realms) do
        if key:find(faction) and type(data.prices) == "table" then
            local n = 0
            for _ in pairs(data.prices) do n = n + 1 end
            if n > 0 and (not bestN or n > bestN) then best, bestN = key, n end
        end
    end
    if best then return realms[best].prices, (best:gsub("%-%a+$", "")), realms[best].lastScanAt end
end

-- Returns the listings to judge, and a description of where they came from (or nil when there are none)
function A.Listings()
    local list = {}
    local own = A.RealmData()
    if own and own.items and next(own.items) then
        for _, e in pairs(own.items) do list[#list + 1] = e end
        A.source = { kind = "scan", t = own.t, count = #list }
        return list
    end
    local prices, otherRealm, scannedAt = FCARealmPrices()
    if not prices then
        A.source = nil
        return nil
    end
    for id, entry in pairs(prices) do
        id = tonumber(id)
        local listed = (entry.qty or 0) > 0
        local price = entry.min or entry.mkt
        if id and listed and price and price > 0 then
            local _, _, _, equipLoc, _, classID = GetItemInfoInstant(id)
            if (classID == 2 or classID == 4) and not SKIP_LOC[equipLoc or ""] then
                list[#list + 1] = { link = "item:" .. id, price = price, n = entry.n or entry.qty or 1, t = entry.t }
            end
        end
    end
    A.source = { kind = "fca", realm = otherRealm, t = scannedAt, count = #list }
    return list
end

-- An item that rolls a random enchant ("of the Bear"), seen by item ID only: its real stats are unknown
local function IsRandomEnchant(link)
    if not (C_TooltipInfo and C_TooltipInfo.GetHyperlink and ITEM_RANDOM_ENCHANT) then return false end
    local ok, data = pcall(C_TooltipInfo.GetHyperlink, link)
    for _, line in ipairs(ok and data and data.lines or {}) do
        if line.leftText == ITEM_RANDOM_ENCHANT then return true end
    end
    return false
end

-- Re-judges every listing. Runs a few milliseconds per frame; items the client hasn't loaded yet are retried in
-- later passes.
function A.Rank()
    runToken = runToken + 1
    local token = runToken
    wipe(results)
    local pawn = Pawn()
    if not pawn then
        status = "nopawn"
        A.Fire("RESULTS")
        return
    end
    local queue = A.Listings()
    if not queue or #queue == 0 then
        status = "nodata"
        A.Fire("RESULTS")
        return
    end
    totalToCheck, progress, status = #queue, 0, "working"
    local passes, retry = 0, {}
    local i = 1

    local function Step()
        if token ~= runToken then return end
        local started = Milliseconds()
        while i <= #queue do
            local e = queue[i]
            i = i + 1
            local ok, verdict = pcall(pawn.Upgrades.Check, pawn.Upgrades, e.link)
            if ok and verdict == nil then
                retry[#retry + 1] = e -- still loading
            else
                progress = progress + 1
                if ok and verdict and verdict.upgrade and verdict.usable then
                    local name, itemLink, quality, _, _, _, _, _, _, icon = GetItemInfo(e.link)
                    local gain = verdict.gain or (verdict.empty and 100) or 50
                    local gold = math.max(e.price / 10000, 0.01)
                    local gainText = pawn.Upgrades.GainText(verdict)
                    -- From item IDs only (ForeverCraftAssistant data), a random-enchant item is judged without its
                    -- "of the ..." stats: the real one on the AH is likely better, but which one is unknown
                    local random = not e.link:find("|H") and IsRandomEnchant(e.link)
                    if random then gainText = gainText .. " |cffaaaaaa+ random|r" end
                    results[#results + 1] = {
                        link = (e.link:find("|H") and e.link) or itemLink or e.link, name = name or e.link,
                        price = e.price, n = e.n, slot = A.SLOT_NAMES[verdict.slot] or "", gain = gain,
                        slotOrder = SLOT_ORDER[verdict.slot] or 99,
                        gainText = gainText, value = gain / gold, icon = icon, quality = quality, random = random,
                    }
                end
            end
            if Milliseconds() - started > BUDGET_MS then break end
        end
        if i <= #queue then
            C_Timer.After(0, Step)
            return
        end
        if #retry > 0 and passes < 4 then
            passes = passes + 1
            queue, retry, i = retry, {}, 1
            C_Timer.After(1, Step) -- give the client a moment to load them
            A.SortResults()
            A.Fire("RESULTS")
            return
        end
        status = "done"
        A.SortResults()
        A.Fire("RESULTS")
    end
    A.Fire("RESULTS")
    C_Timer.After(0, Step)
end

-- New scan data, or something PawnForever cares about changed (gear, talents, weights, level): judge again when the
-- window is open, or on next open.
A.dirty = true
local soon = false
local function RankSoon()
    A.dirty = true
    if soon or not (A.IsShown and A.IsShown()) then return end
    soon = true
    C_Timer.After(1, function() -- bursts of changes (equipping a set, looting) collapse into one pass
        soon = false
        if A.IsShown() then A.dirty = false; A.Rank() end
    end)
end
A.On("DATA", RankSoon)
A.On("LOGIN", function()
    local p = _G.PawnForever
    if p and p.On then pcall(p.On, p, "REFRESH", RankSoon) end
end)
