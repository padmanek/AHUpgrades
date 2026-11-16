-- AH Upgrades: ranking.
-- Every saved gear listing is judged by PawnForever exactly as its bag arrows are (PawnForever.Upgrades:Check:
-- your weights, your worn gear, the weaker ring/trinket, weapons as a pair, usable by you now), for the spec picked
-- in the list (PawnForever's main scale, or its second one). The upgrades are then sorted by value: % upgrade per
-- gold.
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

------------------------------------------------------------------------
-- Which spec: PawnForever tracks a main scale and, optionally, a second one (its bag arrows show both). The list
-- shows the upgrades for one of them at a time: "main" or "second". Not saved: every opening starts on main.
------------------------------------------------------------------------

A.specView = "main"

-- The main scale and the second one (nil when PawnForever tracks only one)
function A.TrackedScales()
    local p = Pawn()
    if not (p and p.Scales and p.Scales.Main) then return nil, nil end
    local okMain, main = pcall(p.Scales.Main, p.Scales)
    local okSecond, second = false, nil
    if p.Scales.Second then okSecond, second = pcall(p.Scales.Second, p.Scales) end
    return okMain and main or nil, okSecond and second or nil
end

-- The scale the list is for now; falls back to main when there is no second scale
function A.ViewScale()
    local main, second = A.TrackedScales()
    if A.specView == "second" and second then return second, "second" end
    return main, "main"
end

-- A scale's name in its PawnForever colour (the colour of its bag arrows)
function A.ScaleLabel(scale)
    if not scale then return "?" end
    local p = Pawn()
    local ok, color = false, nil
    if p and p.Scales and p.Scales.ColorOf then ok, color = pcall(p.Scales.ColorOf, p.Scales, scale) end
    return ((ok and color and color.hex) or "|cffffffff") .. (scale.name or "?") .. "|r"
end

-- The scale the current results were judged with
function A.RankedScale() return A.rankedScale end

-- Each sort: the column's key and its natural direction (true = highest first). A.db.sortReverse flips the
-- direction. Ties are always broken by best value, then cheapest.
A.SORTS = {
    name = { function(r) return (r.name or ""):lower() end, false },
    slot = { function(r) return r.slotOrder or 99 end, false }, -- paper-doll order, Head to Ranged
    score = { function(r) return r.score or 0 end, true }, -- PawnForever's score with the spec picked
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
        for k, e in pairs(own.items) do
            e.key = e.key or k -- the live re-check (GearScan.lua) finds its entry by this
            list[#list + 1] = e
        end
        A.source = { kind = own.kind == "gear" and "gear" or "scan", t = own.t, count = #list }
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
                list[#list + 1] = { link = "item:" .. id, price = price, n = entry.n or entry.qty or 1, t = entry.t,
                    key = tostring(id) }
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
A.IsRandomEnchant = IsRandomEnchant -- also used by the gear scan (GearScan.lua)

------------------------------------------------------------------------
-- What is in the bags
--
-- PawnForever compares a listing with what is worn. With a second set in the bags (the other spec's gear) that
-- makes it ask you to buy what you already carry. So every worn, bag and bank item (the bank as at the last visit,
-- Bank.lua) is scored with the same scale, and a
-- listing must also beat the best of those that could go in its place: the best one for a slot, the second best
-- for rings and trinkets (you wear two).
------------------------------------------------------------------------

local MIN_GAIN, MIN_POINTS = 2, 0.1 -- as PawnForever: a trade-off has to be worth 2%
local MAIN, OFF = 16, 17

-- Which items stand in for each other: the slot group, with the hands split by kind of weapon so a one-hander is
-- never measured against a two-hander
local function PlaceOf(slot, link)
    if slot == MAIN or slot == OFF then
        if slot == OFF then return "OH" end
        local loc = select(4, GetItemInfoInstant(link))
        return loc == "INVTYPE_2HWEAPON" and "2H" or "MH"
    end
    return SLOT_ORDER[slot]
end
local WEAR_TWO = { [11] = true, [12] = true } -- the ring and trinket groups

-- For each place: the scores of what is worn and of everything owned (worn + bags + bank), best first
local function ReadOwned(pawn, scale)
    local owned = {}
    -- where: nil for worn, "bags" or "bank"
    local function Add(link, slot, where)
        local ok, verdict = pcall(pawn.Upgrades.Check, pawn.Upgrades, link, scale)
        if not (ok and verdict and verdict.score) then return end
        if where and not verdict.usable then return end
        local place = PlaceOf(slot or verdict.slot, link)
        if not place then return end
        local o = owned[place]
        if not o then
            o = { worn = {}, all = {} }
            owned[place] = o
        end
        local entry = { score = verdict.score, link = link, where = where }
        if not where then table.insert(o.worn, entry) end
        table.insert(o.all, entry)
    end
    for slot = 1, 18 do
        local link = A.Plain(GetInventoryItemLink("player", slot))
        if link then Add(link, slot, nil) end
    end
    local seen = {}
    local function AddCarried(link, where)
        if not link or seen[link] then return end
        seen[link] = true
        local _, _, _, loc, _, classID = GetItemInfoInstant(link)
        if (classID == 2 or classID == 4) and not SKIP_LOC[loc or ""] then Add(link, nil, where) end
    end
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            local item = C_Container.GetContainerItemInfo(bag, slot)
            AddCarried(item and A.Plain(item.hyperlink), "bags")
        end
    end
    -- the bank as it was at the last visit (Bank.lua)
    if A.BankLinks then
        for _, link in ipairs((A.BankLinks())) do AddCarried(link, "bank") end
    end
    local byScore = function(a, b) return a.score > b.score end
    for place, o in pairs(owned) do
        table.sort(o.worn, byScore)
        table.sort(o.all, byScore)
        local n = WEAR_TWO[place] and 2 or 1
        o.base = o.all[n] -- what a listing has to beat: nil when a slot is still free
        -- bags and bank only matter when they raise the bar above what is worn (a better item, or one for a free slot)
        o.fromBags = o.base and o.base.score > ((o.worn[n] and o.worn[n].score) or 0) or false
        -- the item that raised it, and where it is
        for i = 1, n do
            local e = o.all[i]
            if e and e.where then
                o.carried = e
                break
            end
        end
    end
    return owned
end

-- nil: bags or bank already hold something as good. false: nothing to change. Otherwise the gain over what you own,
-- the item that sets the bar, and where it is ("bags" or "bank").
local function AgainstBags(owned, verdict, link)
    local o = owned[PlaceOf(verdict.slot, link)]
    if not (o and o.fromBags) or verdict.partner then return false end
    local base = o.base.score
    local points = verdict.score - base
    if base <= 0 then return false end
    local gain = points / base * 100
    if points < MIN_POINTS or gain < MIN_GAIN then return nil end
    local carried = o.carried or o.base
    return gain, carried.link, carried.where or "bags"
end

-- Re-judges every listing. Runs a few milliseconds per frame; items the client hasn't loaded yet are retried in
-- later passes.
function A.Rank()
    runToken = runToken + 1
    local token = runToken
    -- judged into a list of its own: the one shown stays until this one is ready (no flicker on every update)
    local building = {}
    local pawn = Pawn()
    if not pawn then
        status, results = "nopawn", {}
        A.Fire("RESULTS")
        return
    end
    local queue = A.Listings()
    if not queue or #queue == 0 then
        status, results = "nodata", {}
        A.Fire("RESULTS")
        return
    end
    totalToCheck, progress, status = #queue, 0, "working"
    local scale = A.ViewScale()
    A.rankedScale = scale
    local owned = ReadOwned(pawn, scale)
    A.inBags = 0 -- upgrades over what is worn that the bags already match
    local passes, retry = 0, {}
    local i = 1

    local function Step()
        if token ~= runToken then return end
        local started = Milliseconds()
        while i <= #queue do
            local e = queue[i]
            i = i + 1
            local ok, verdict = pcall(pawn.Upgrades.Check, pawn.Upgrades, e.link, scale)
            if ok and verdict == nil then
                retry[#retry + 1] = e -- still loading
            else
                progress = progress + 1
                local bagGain, bagLink, bagWhere
                if ok and verdict and verdict.upgrade and verdict.usable then
                    bagGain, bagLink, bagWhere = AgainstBags(owned, verdict, e.link)
                    if bagGain == nil then A.inBags = A.inBags + 1 end
                end
                if bagGain ~= nil and ok and verdict and verdict.upgrade and verdict.usable then
                    local name, itemLink, quality, _, _, _, _, _, _, icon = GetItemInfo(e.link)
                    local gain = verdict.gain or (verdict.empty and 100) or 50
                    local gold = math.max(e.price / 10000, 0.01)
                    -- no percentage to show when what is worn scores nothing (Pawn: "replaces an item worth nothing")
                    local worthless = not verdict.gain and not verdict.empty and not verdict.points
                    local gainText = worthless and "-" or pawn.Upgrades.GainText(verdict)
                    if bagGain then
                        -- measured against the better item in the bags or bank, not the worn one
                        gain = bagGain
                        gainText = ("+%d%% |cffaaaaaaover %s|r"):format(math.max(1, math.floor(bagGain + 0.5)), bagWhere)
                    end
                    -- From item IDs only (ForeverCraftAssistant data), a random-enchant item is judged without its
                    -- "of the ..." stats: the real one on the AH is likely better, but which one is unknown
                    local random = not e.link:find("|H") and IsRandomEnchant(e.link)
                    if random then gainText = gainText .. " |cffaaaaaa+ random|r" end
                    building[#building + 1] = {
                        key = e.key, entry = e, -- the saved listing it comes from
                        link = (e.link:find("|H") and e.link) or itemLink or e.link, name = name or e.link,
                        price = e.price, n = e.n, slot = A.SLOT_NAMES[verdict.slot] or "", gain = gain,
                        slotOrder = SLOT_ORDER[verdict.slot] or 99,
                        gainText = gainText, value = gain / gold, icon = icon, quality = quality, random = random,
                        vsBag = bagGain and bagLink or nil, vsWhere = bagGain and bagWhere or nil,
                        score = verdict.score,
                        scoreText = verdict.score and ((pawn.Format and pawn.Format(verdict.score)) or ("%.1f"):format(verdict.score)),
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
            results = building -- what is judged so far; the retries add to it
            A.SortResults()
            A.Fire("RESULTS")
            return
        end
        status = "done"
        results = building
        A.SortResults()
        A.Fire("RESULTS")
    end
    A.Fire("RESULTS")
    C_Timer.After(0, Step)
end

------------------------------------------------------------------------
-- Live re-check (GearScan.lua looks the shown rows up on the AH again)
------------------------------------------------------------------------

-- Its cheapest buyout now, and how many are listed: price and value change, and so does the saved listing
function A.LiveUpdate(r, price, n)
    r.price, r.n, r.checked = price, n or r.n, GetTime()
    r.value = r.gain / math.max(price / 10000, 0.01)
    if r.entry then r.entry.price, r.entry.n = price, n or r.entry.n end
    A.SortResults()
    A.Fire("RESULTS")
end

-- Not on the AH any more: off the list, and out of this realm's saved listings
function A.LiveRemove(r)
    for i = #results, 1, -1 do
        if results[i] == r then table.remove(results, i) end
    end
    local own = A.RealmData()
    if own and own.items and r.key and own.items[r.key] == r.entry then
        own.items[r.key] = nil
        own.count = math.max((own.count or 1) - 1, 0)
    end
    A.Fire("RESULTS")
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
-- the bags change what a listing has to beat (and buying one from the list puts it there)
local bagEvents = CreateFrame("Frame")
bagEvents:RegisterEvent("BAG_UPDATE_DELAYED")
bagEvents:SetScript("OnEvent", RankSoon)
A.On("BANK", RankSoon) -- a bank visit recorded what is there
A.On("LOGIN", function()
    local p = _G.PawnForever
    if p and p.On then pcall(p.On, p, "REFRESH", RankSoon) end
end)
