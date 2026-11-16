-- AH Upgrades: the gear scan (the Scan gear button), and the live re-check of the rows on screen.
--
-- Gear scan. A full scan (ForeverCraftAssistant's Scan button, read by Capture.lua) hands over every auction but can
-- only run every so often. This one searches the AH like the Buy tab does, for just what can matter: weapons and
-- armor that you can use, up to your level.
--   1. A browse search: one row per item with its cheapest buyout, paged until the AH says it is complete. Those
--      go in the list straight away; random-enchant items as their base item ("+ random") for now.
--   2. Items that roll a random enchant ("of the Bear") are then searched one by one: that lists each auction with
--      its real link, so the actual stats get judged. The list is updated every few of them.
-- The result replaces this realm's saved listings, like a full scan does. Stopped early, what was found is kept.
--
-- Live re-check. While the Upgrades tab is open at the AH and no scan runs, the rows on screen are looked up again
-- one at a time, every couple of seconds: a new cheapest price is put in, and a row whose item is gone from the AH
-- is taken off the list.
local _, A = ...

local AH = C_AuctionHouse

local TIMEOUT = 20        -- seconds without an answer from the AH before the gear scan gives up
local LOAD_WAIT = 4       -- seconds to let the client load item data before telling random-enchant items apart
local DETAIL_LIMIT = 150  -- random-enchant items searched one by one, at most
local ITEM_TIMEOUT = 5    -- seconds to wait for one item's auctions
local PUBLISH_EVERY = 4   -- seconds between list updates while random-enchant items are searched

local LIVE_GAP = 2        -- seconds between two live look-ups
local LIVE_AGAIN = 30     -- a row is looked up again at most this often
local LIVE_TIMEOUT = 5    -- seconds to wait for a live answer

local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false } }

local function Plain(v) return A.Plain(v) end
local function Fire() A.Fire("SCAN") end

local token = 0 -- bumped on every scan start and stop: old timers and late answers see they are stale

-- Runs fn once the AH takes another request (its "throttled message system"), unless `still()` says it's too late
local function WhenReady(fn, still)
    local function try()
        if still and not still() then return end
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

-- Every auction of an item search with a buyout: link, price per item
local function ItemAuctions(key)
    local list = {}
    for i = 1, AH.GetNumItemSearchResults(key) or 0 do
        local r = AH.GetItemSearchResultInfo(key, i)
        local link = r and Plain(r.itemLink)
        local buyout = r and Plain(r.buyoutAmount)
        if link and buyout and buyout > 0 then
            list[#list + 1] = { link = link, price = buyout / math.max(r.quantity or 1, 1) }
        end
    end
    return list
end

------------------------------------------------------------------------
-- The gear scan
------------------------------------------------------------------------

local state = "idle" -- idle, browse, loading, details
local found          -- group key -> { link, price, n, key }, as Capture.lua saves them
local rows           -- the browse rows
local queue, qi      -- random-enchant items to search one by one, and which one is being searched
local lastAnswer     -- GetTime() of the last answer from the AH
local pages = 0
local published, lastPublish = false, 0

function A.GearScanState()
    if state == "browse" then return "browse", pages end
    if state == "details" then return "details", qi or 0, queue and #queue or 0 end
    return state
end

function A.CanGearScan()
    if not (AH and AH.SendBrowseQuery and AH.GetBrowseResults) then return false, "this client has no AH search" end
    local ah = _G.AuctionHouseFrame
    if not (ah and ah:IsShown()) then return false, "open the Auction House first" end
    if A.CaptureState and A.CaptureState() ~= "idle" then return false, "a full scan is being read" end
    return true
end

-- Keeps the cheapest listing per group (item, plus its random enchant when known)
local function Add(key, link, price, n)
    if not key or not price or price <= 0 then return end
    local e = found[key]
    if not e then
        found[key] = { link = link, price = price, n = n or 1, key = key }
    else
        e.n = e.n + (n or 1)
        if price < e.price then e.price, e.link = price, link end
    end
end

-- Puts what was found so far in as this realm's listings; the list is judged again
local function Publish()
    local n = 0
    for _ in pairs(found) do n = n + 1 end
    A.db.realms[A.RealmKey()] = { t = time(), items = found, count = n, kind = "gear" }
    published, lastPublish = true, GetTime()
    A.Fire("DATA")
    return n
end

local function Stop(message)
    token = token + 1
    state = "idle"
    found, rows, queue, qi = nil, nil, nil, nil
    if message then A.Print(message) end
    Fire()
end

-- Ends the scan early: what was found so far stays, if any of it is in already
local function StopEarly(why)
    if published then
        local n = Publish()
        Stop(("%s; kept the %d gear items found so far."):format(why, n))
    else
        Stop(why .. " (the saved listings are unchanged).")
    end
end

local function Done()
    local n = Publish()
    Stop(("gear scan done: %d gear items you can use. |cff40c0ff/ahu|r shows your upgrades."):format(n))
end

-- 2. Random-enchant items, one search each

local Next

-- Done with the item being searched (answered, skipped or failed)
local function Advance()
    if queue and queue[qi] then queue[qi] = { key = {} } end -- a late answer for it no longer matches
    Next()
end

Next = function()
    qi = qi + 1
    Fire()
    if qi > #queue then
        Done()
        return
    end
    if GetTime() - lastPublish >= PUBLISH_EVERY then Publish() end
    local entry, my = queue[qi], token
    lastAnswer = GetTime()
    WhenReady(function()
        lastAnswer = GetTime()
        if not pcall(AH.SendSearchQuery, entry.key, PRICE_SORT, true) then Advance() end
    end, function() return my == token and state == "details" and queue[qi] == entry end)
end

local function OnScanItem(key)
    local entry = queue and queue[qi]
    if not (entry and SameKey(key, entry.key)) then return false end
    lastAnswer = GetTime()
    if AH.HasFullItemSearchResults and not AH.HasFullItemSearchResults(key) then
        WhenReady(function() pcall(AH.RequestMoreItemSearchResults, key) end)
        return true
    end
    local auctions = ItemAuctions(key)
    if #auctions > 0 then
        -- the real ones replace the base-item stand-in
        local stand = tostring(entry.key.itemID)
        if found[stand] and found[stand].standIn then found[stand] = nil end
        for _, a in ipairs(auctions) do Add(A.GroupKey(a.link), a.link, a.price, 1) end
    end
    Advance()
    return true
end

-- 1. The browse search

-- Every browse row: in the list as it is; random-enchant ones also queued for a search of their own
local function Sort()
    queue, qi = {}, 0
    for _, r in ipairs(rows) do
        local key = r.itemKey
        local id = key and Plain(key.itemID)
        local price = Plain(r.minPrice)
        if id and price and price > 0 and A.IsGear(id) then
            local n = Plain(r.totalQuantity) or 1
            Add(tostring(id), "item:" .. id, price, n)
            local random = (Plain(key.itemSuffix) or 0) ~= 0 or A.IsRandomEnchant("item:" .. id)
            if random and #queue < DETAIL_LIMIT then
                found[tostring(id)].standIn = true -- judged on the base item ("+ random") until searched
                queue[#queue + 1] = { key = key, price = price, n = n }
            end
        end
    end
    Publish() -- everything but the random enchants' real stats is in the list now
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

local function OnScanBrowse()
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

-- Every quality, as the Buy tab asks by default (and, for the gear scan, only what you can use). Also used by a
-- click on a row (UI.lua), when the Buy tab's own filters can't be cleared.
local function Filters(usableOnly)
    local F = Enum.AuctionHouseFilter or {}
    local list = {}
    if usableOnly and F.UsableOnly then list[1] = F.UsableOnly end
    for _, name in ipairs({ "PoorQuality", "CommonQuality", "UncommonQuality", "RareQuality", "EpicQuality",
        "LegendaryQuality", "ArtifactQuality", "HeirloomQuality" }) do
        if F[name] then list[#list + 1] = F[name] end
    end
    return list
end
A.BrowseFilters = Filters

function A.GearScan()
    if state ~= "idle" then
        StopEarly("gear scan stopped")
        return
    end
    local ok, why = A.CanGearScan()
    if not ok then
        A.Print("can't scan: %s.", why)
        return
    end
    token = token + 1
    state, found, pages, lastAnswer, published = "browse", {}, 0, GetTime(), false
    Fire()
    local query = {
        searchString = "",
        sorts = PRICE_SORT,
        filters = Filters(true),
        itemClassFilters = { { classID = Enum.ItemClass.Weapon }, { classID = Enum.ItemClass.Armor } },
        minLevel = 0,
        maxLevel = UnitLevel("player") or 0,
    }
    local my = token
    WhenReady(function()
        lastAnswer = GetTime()
        local sent, err = pcall(AH.SendBrowseQuery, query)
        if not sent then Stop("|cffff6060the AH refused the search:|r " .. tostring(err)) end
    end, function() return my == token end)
    -- Watchdog: an item search with no answer is skipped; a browse search with none ends the scan
    local function watch()
        if my ~= token or state == "idle" then return end
        local quiet = GetTime() - lastAnswer
        if state == "details" and quiet > ITEM_TIMEOUT then
            lastAnswer = GetTime()
            Advance()
        elseif state == "browse" and quiet > TIMEOUT then
            StopEarly("|cffff6060the AH stopped answering; gear scan stopped|r")
            return
        end
        C_Timer.After(1, watch)
    end
    C_Timer.After(1, watch)
end

------------------------------------------------------------------------
-- Live re-check of the rows on screen
------------------------------------------------------------------------

local live = { index = 0, last = 0 } -- .row: being looked up, .phase: "browse" or "items", .key, .sent
local liveOn = false

local function LiveReady()
    if state ~= "idle" or (A.CaptureState and A.CaptureState() ~= "idle") then return false end
    if not (AH and AH.SendBrowseQuery and AH.SendSearchQuery) then return false end
    local ah = _G.AuctionHouseFrame
    return ah and ah:IsShown() and A.LiveTargets and #A.LiveTargets() > 0 or false
end

function A.LiveActive() return liveOn end

-- /ahu live: says in chat what each look-up does
local function LiveLog(msg, ...)
    if A.db and A.db.liveLog then A.Print("|cff40ff40live|r: " .. msg, ...) end
end

-- .asked: our query has gone out; answers before that belong to someone else's search and are ignored
local function LiveDone() live.row, live.phase, live.key, live.asked = nil, nil, nil, false end

local function ItemIDOf(r) return tonumber(r.link and r.link:match("item:(%d+)")) end

-- The row's group: "id" (any copy counts) or "id:suffix" (that random enchant only)
local function Matches(r, link)
    if not (r.key and r.key:find(":", 1, true)) then return true end
    return A.GroupKey(link) == r.key
end

local function LiveApply(r, price, n)
    if price then
        LiveLog("%s: %d listed, cheapest %s", r.link, n or 0, C_CurrencyInfo.GetCoinTextureString(math.floor(price + 0.5)))
        A.LiveUpdate(r, price, n)
    else
        LiveLog("%s: gone from the AH, taken off the list", r.link)
        A.LiveRemove(r)
    end
    LiveDone()
end

local function OnLiveBrowse()
    local r = live.row
    local id = ItemIDOf(r)
    local all = AH.GetBrowseResults() or {}
    local keys, best, total = {}, nil, 0
    for _, b in ipairs(all) do
        local key = b.itemKey
        if key and Plain(key.itemID) == id then
            keys[#keys + 1] = key
            local price = Plain(b.minPrice)
            if price and price > 0 and (not best or price < best) then best = price end
            total = total + (Plain(b.totalQuantity) or 0)
        end
    end
    if #keys == 0 then
        -- other items by that name, and more pages to come: ours may be further on. An empty answer is final.
        if #all > 0 and AH.HasFullBrowseResults and not AH.HasFullBrowseResults() then
            live.sent = GetTime()
            WhenReady(function() pcall(AH.RequestMoreBrowseResults) end)
            return
        end
        LiveApply(r, nil) -- not on the AH any more
        return
    end
    if not (r.key and r.key:find(":", 1, true)) then
        LiveApply(r, best, total)
        return
    end
    -- a random enchant: only its auctions count, which the item search lists
    live.phase, live.key, live.sent, live.asked = "items", keys[1], GetTime(), false
    WhenReady(function()
        live.sent = GetTime()
        local ok, err = pcall(AH.SendSearchQuery, keys[1], PRICE_SORT, true)
        live.asked = ok
        if not ok then
            LiveLog("|cffff6060the AH refused the item search:|r %s", tostring(err))
            LiveDone()
        end
    end, function() return live.row == r end)
end

local function OnLiveItem(key)
    if live.phase ~= "items" or not SameKey(key, live.key) then return end
    local auctions = ItemAuctions(key)
    if #auctions > 0 and AH.HasFullItemSearchResults and not AH.HasFullItemSearchResults(key) then
        live.sent = GetTime()
        WhenReady(function() pcall(AH.RequestMoreItemSearchResults, key) end)
        return
    end
    local r = live.row
    local best, n = nil, 0
    for _, a in ipairs(auctions) do
        if Matches(r, a.link) then
            n = n + 1
            if not best or a.price < best then best = a.price end
        end
    end
    LiveApply(r, best, n)
end

-- One look-up: the next row on screen that wasn't looked at lately
local function LiveStep()
    local wasOn = liveOn
    liveOn = LiveReady()
    if liveOn ~= wasOn then Fire() end
    if not liveOn then
        LiveDone()
        return
    end
    local now = GetTime()
    if live.row then
        if now - live.sent > LIVE_TIMEOUT then -- no answer: try another
            LiveLog("%s: no answer from the AH (%s search%s)", live.row.link, live.phase or "?",
                live.asked and "" or ", never sent: the AH was busy")
            LiveDone()
        end
        return
    end
    if now - live.last < LIVE_GAP then return end
    local targets = A.LiveTargets()
    for _ = 1, #targets do
        live.index = live.index % #targets + 1
        local r = targets[live.index]
        local id = ItemIDOf(r)
        local name = id and C_Item.GetItemInfo(id)
        if name and now - (r.checked or 0) >= LIVE_AGAIN then
            r.checked = now
            live.row, live.phase, live.sent, live.last = r, "browse", now, now
            -- as the Buy tab searches: by name, every quality, no level limits (0 = none)
            local query = { searchString = name, sorts = PRICE_SORT, filters = Filters(false), itemClassFilters = {},
                minLevel = 0, maxLevel = 0 }
            live.asked = false
            LiveLog("checking %s", r.link)
            WhenReady(function()
                live.sent = GetTime()
                local ok, err = pcall(AH.SendBrowseQuery, query)
                live.asked = ok
                if not ok then
                    A.lastError = "live search: " .. tostring(err)
                    LiveLog("|cffff6060the AH refused the search:|r %s", tostring(err))
                    LiveDone()
                end
            end, function() return live.row == r end)
            return
        end
    end
end
C_Timer.NewTicker(0.5, function()
    local ok, err = pcall(LiveStep)
    if not ok then
        A.lastError = "live: " .. tostring(err)
        LiveDone()
    end
end)

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "ITEM_SEARCH_RESULTS_UPDATED", "ITEM_SEARCH_RESULTS_ADDED" }) do
    pcall(ev.RegisterEvent, ev, event)
end
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if state == "browse" then
            OnScanBrowse()
        elseif state == "idle" and live.phase == "browse" and live.asked then
            OnLiveBrowse()
        end
    elseif state == "details" then
        OnScanItem(arg1)
    elseif state == "idle" and live.asked then
        OnLiveItem(arg1)
    end
end)
A.On("AH_CLOSED", function()
    LiveDone()
    if state ~= "idle" then StopEarly("the AH closed; gear scan stopped") end
end)
