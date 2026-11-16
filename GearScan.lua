-- AH Upgrades: the gear scan (the Scan gear button).
-- A full scan (ForeverCraftAssistant's Scan button, read by Capture.lua) hands over every auction but can only run
-- every so often. This one searches the AH like the Buy tab does, for just what can matter: weapons and armor that
-- you can use, up to your level.
--   1. A browse search: one row per item with its cheapest buyout, paged until the AH says it is complete.
--   2. For items that roll a random enchant ("of the Bear"), the browse row doesn't say which one it is: those are
--      searched one by one, which lists each auction with its real link, so the actual stats get judged.
-- The result replaces this realm's saved listings, like a full scan does, and the list is judged again.
local _, A = ...

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or _G.GetItemInfoInstant
local AH = C_AuctionHouse

local TIMEOUT = 20      -- seconds without an answer from the AH before giving up on a step
local LOAD_WAIT = 4     -- seconds to let the client load item data before telling random-enchant items apart
local DETAIL_LIMIT = 150 -- random-enchant items searched one by one, at most

local state = "idle" -- idle, browse, loading, details
local found          -- group key -> { link, price, n }, as Capture.lua saves them
local rows           -- the browse rows
local queue, qi      -- random-enchant item keys still to search, and which one is being searched
local lastAnswer     -- GetTime() of the last answer from the AH
local token = 0      -- bumped on every start and stop: old timers see they are stale
local pages = 0

function A.GearScanState()
    if state == "browse" then return "browse", pages end
    if state == "details" then return "details", qi or 0, queue and #queue or 0 end
    return state
end

local function Plain(v) return A.Plain(v) end

function A.CanGearScan()
    if not (AH and AH.SendBrowseQuery and AH.GetBrowseResults) then return false, "this client has no AH search" end
    local ah = _G.AuctionHouseFrame
    if not (ah and ah:IsShown()) then return false, "open the Auction House first" end
    if A.CaptureState and A.CaptureState() ~= "idle" then return false, "a full scan is being read" end
    return true
end

local function Fire() A.Fire("SCAN") end

local function Stop(message)
    token = token + 1
    state = "idle"
    found, rows, queue, qi = nil, nil, nil, nil
    if message then A.Print(message) end
    Fire()
end

-- Runs fn once the AH takes another request (its "throttled message system")
local function WhenReady(fn)
    local my = token
    local function try()
        if my ~= token then return end
        if not AH.IsThrottledMessageSystemReady or AH.IsThrottledMessageSystemReady() then
            fn()
        else
            C_Timer.After(0.2, try)
        end
    end
    try()
end

local function SameKey(a, b)
    return type(a) == "table" and type(b) == "table" and a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0)
        and (a.itemSuffix or 0) == (b.itemSuffix or 0) and (a.battlePetSpeciesID or 0) == (b.battlePetSpeciesID or 0)
end

local function Save()
    local n = 0
    for _ in pairs(found) do n = n + 1 end
    A.db.realms[A.RealmKey()] = { t = time(), items = found, count = n, kind = "gear" }
    A.Print("gear scan done: %d gear items you can use. |cff40c0ff/ahu|r shows your upgrades.", n)
    Stop()
    A.Fire("DATA")
end

-- Keeps the cheapest listing per group (item, plus its random enchant when known)
local function Add(key, link, price, n)
    if not key or not price or price <= 0 then return end
    local e = found[key]
    if not e then
        found[key] = { link = link, price = price, n = n or 1 }
    else
        e.n = e.n + (n or 1)
        if price < e.price then e.price, e.link = price, link end
    end
end

------------------------------------------------------------------------
-- 2. Random-enchant items, one search each
------------------------------------------------------------------------

local Next, SkipItem
local ITEM_TIMEOUT = 5 -- seconds to wait for one random-enchant item's auctions

local function ReadItem(key)
    local got = false
    for i = 1, AH.GetNumItemSearchResults(key) or 0 do
        local r = AH.GetItemSearchResultInfo(key, i)
        local link = r and Plain(r.itemLink)
        local buyout = r and Plain(r.buyoutAmount)
        if link and buyout and buyout > 0 then
            Add(A.GroupKey(link), link, buyout / math.max(r.quantity or 1, 1), 1)
            got = true
        end
    end
    return got
end

Next = function()
    qi = qi + 1
    Fire()
    if qi > #queue then
        Save()
        return
    end
    local entry = queue[qi]
    lastAnswer = GetTime()
    WhenReady(function()
        if state ~= "details" or queue[qi] ~= entry then return end -- skipped while waiting for the AH
        lastAnswer = GetTime()
        local ok = pcall(AH.SendSearchQuery, entry.key, { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } }, true)
        if not ok then SkipItem() end
    end)
end

-- No usable answer for the item being searched: keep its browse price, judged on the base item ("+ random")
SkipItem = function()
    local entry = queue and queue[qi]
    if entry and entry.price then
        Add(tostring(entry.key.itemID), "item:" .. entry.key.itemID, entry.price, entry.n)
        queue[qi] = { key = {} } -- a late answer for it no longer matches
    end
    Next()
end

local function OnItemResults(key)
    if state ~= "details" or not queue or not queue[qi] or not SameKey(key, queue[qi].key) then return end
    lastAnswer = GetTime()
    if AH.HasFullItemSearchResults and not AH.HasFullItemSearchResults(key) then
        WhenReady(function() pcall(AH.RequestMoreItemSearchResults, key) end)
        return
    end
    if ReadItem(key) then
        queue[qi] = { key = {} } -- answered: a late duplicate event no longer matches
        Next()
    else
        SkipItem()
    end
end

------------------------------------------------------------------------
-- 1. The browse search
------------------------------------------------------------------------

-- Every browse row: plain items are saved as they are; random-enchant ones go to the queue
local function Sort()
    queue, qi = {}, 0
    for _, r in ipairs(rows) do
        local key = r.itemKey
        local id = key and Plain(key.itemID)
        local price = Plain(r.minPrice)
        if id and price and price > 0 and A.IsGear(id) then
            local random = (Plain(key.itemSuffix) or 0) ~= 0 or A.IsRandomEnchant("item:" .. id)
            if random and #queue < DETAIL_LIMIT then
                queue[#queue + 1] = { key = key, price = price, n = Plain(r.totalQuantity) or 1 }
            else
                Add(tostring(id), "item:" .. id, price, Plain(r.totalQuantity) or 1)
            end
        end
    end
    state = "details"
    Next()
end

-- Item data first: telling random-enchant items apart reads their tooltip
local function LoadThenSort()
    state = "loading"
    Fire()
    local load = C_Item and C_Item.RequestLoadItemDataByID
    local cached = C_Item and C_Item.IsItemDataCachedByID
    for _, r in ipairs(rows) do
        local id = r.itemKey and Plain(r.itemKey.itemID)
        if id and load then pcall(load, id) end
    end
    local my, started = token, GetTime()
    local function check()
        if my ~= token then return end
        local waiting = false
        if cached then
            for _, r in ipairs(rows) do
                local id = r.itemKey and Plain(r.itemKey.itemID)
                if id and not cached(id) then waiting = true break end
            end
        end
        if waiting and GetTime() - started < LOAD_WAIT then
            C_Timer.After(0.25, check)
        else
            Sort()
        end
    end
    check()
end

local function OnBrowseResults()
    if state ~= "browse" then return end
    lastAnswer = GetTime()
    pages = pages + 1
    Fire()
    if AH.HasFullBrowseResults and not AH.HasFullBrowseResults() then
        WhenReady(function() pcall(AH.RequestMoreBrowseResults) end)
        return
    end
    rows = {}
    for _, r in ipairs(AH.GetBrowseResults() or {}) do rows[#rows + 1] = r end
    LoadThenSort()
end

local function Filters()
    local F = Enum.AuctionHouseFilter or {}
    local list = { F.UsableOnly }
    for _, name in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality",
        "LegendaryQuality", "ArtifactQuality", "HeirloomQuality" }) do
        if F[name] then list[#list + 1] = F[name] end
    end
    return list
end

function A.GearScan()
    if state ~= "idle" then
        Stop("gear scan stopped.")
        return
    end
    local ok, why = A.CanGearScan()
    if not ok then
        A.Print("can't scan: %s.", why)
        return
    end
    token = token + 1
    state, found, pages, lastAnswer = "browse", {}, 0, GetTime()
    Fire()
    local query = {
        searchString = "",
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
        filters = Filters(),
        itemClassFilters = { { classID = Enum.ItemClass.Weapon }, { classID = Enum.ItemClass.Armor } },
        minLevel = 0,
        maxLevel = UnitLevel("player") or 0,
    }
    local my = token
    WhenReady(function()
        lastAnswer = GetTime()
        local sent, err = pcall(AH.SendBrowseQuery, query)
        if not sent then
            Stop("|cffff6060the AH refused the search:|r " .. tostring(err))
        end
    end)
    -- Watchdog: an item search that gets no answer is skipped; a browse search that gets none ends the scan
    local function watch()
        if my ~= token or state == "idle" then return end
        local quiet = GetTime() - lastAnswer
        if state == "details" and quiet > ITEM_TIMEOUT then
            lastAnswer = GetTime()
            SkipItem()
        elseif state == "browse" and quiet > TIMEOUT then
            Stop("|cffff6060the AH stopped answering; gear scan stopped (the saved listings are unchanged).|r")
            return
        end
        C_Timer.After(1, watch)
    end
    C_Timer.After(1, watch)
end

local ev = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED" }) do
    pcall(ev.RegisterEvent, ev, event)
end
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        OnBrowseResults()
    else
        OnItemResults(arg1)
    end
end)
A.On("AH_CLOSED", function()
    if state ~= "idle" then Stop("the AH closed; gear scan stopped (the saved listings are unchanged).") end
end)
