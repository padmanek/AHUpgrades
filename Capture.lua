-- AH Upgrades: capture.
-- A full AH scan (C_AuctionHouse.ReplicateItems, what ForeverCraftAssistant's Scan button does) hands the client a
-- list of every auction. Each row's item link carries the random enchant ("of the Bear") and so the real stats.
-- This file reads that same list when it arrives and keeps the gear: cheapest buyout per item + random enchant,
-- per realm and faction. It never asks the AH for anything itself.
local ADDON, A = ...
_G.AHUpgrades = A

A.prefix = "|cff40c0ffAH Upgrades|r: "
function A.Print(msg, ...)
    if select("#", ...) > 0 then msg = msg:format(...) end
    DEFAULT_CHAT_FRAME:AddMessage(A.prefix .. msg)
end

function A.Plain(v)
    if v == nil or (issecretvalue and issecretvalue(v)) then return nil end
    return v
end

function A.RealmKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("%s+", "")
    return realm .. "-" .. (UnitFactionGroup("player") or "Neutral")
end

function A.RealmData()
    return A.db and A.db.realms[A.RealmKey()]
end

-- Callbacks between files
local listeners = {}
function A.On(name, fn)
    listeners[name] = listeners[name] or {}
    table.insert(listeners[name], fn)
end
function A.Fire(name, ...)
    for _, fn in ipairs(listeners[name] or {}) do fn(...) end
end

local WEAPON, ARMOR = 2, 4
local SKIP_LOC = { [""] = true, INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true,
    INVTYPE_QUIVER = true, INVTYPE_AMMO = true, INVTYPE_NON_EQUIP_IGNORE = true }

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or _G.GetItemInfoInstant

local function IsGear(itemID)
    local _, _, _, equipLoc, _, classID = GetItemInfoInstant(itemID)
    return (classID == WEAPON or classID == ARMOR) and not SKIP_LOC[equipLoc or ""]
end

-- The stats-relevant identity of a link: "ID", plus its random enchant when it has one.
-- "item:ID:enchant:gem1:gem2:gem3:gem4:suffix:unique:level:spec:mods:context:numBonus:bonus1:..."
-- Classic links carry the random enchant in the suffix field ("ID:suffix"). WoW Forever puts it in the bonus IDs
-- instead ("Helm of the Monkey" = item 10379 with bonus 12721), one per item, and only random-enchant items have
-- any: "ID:b12721". Second result: true when the link has a random enchant.
local function GroupKey(link)
    local itemString = link:match("|H(item:[^|]+)|h") or link
    local fields = {}
    for f in (itemString .. ":"):gmatch("([^:]*):") do fields[#fields + 1] = f end
    local id = fields[2]
    if not id or id == "" then return nil end
    local key, random = id, false
    local suffix = fields[8]
    if suffix and suffix ~= "" and suffix ~= "0" then key, random = key .. ":" .. suffix, true end
    local bonuses = {}
    for k = 1, tonumber(fields[14]) or 0 do
        local b = fields[14 + k]
        if b and b ~= "" then bonuses[#bonuses + 1] = b end
    end
    if #bonuses > 0 then
        table.sort(bonuses)
        key, random = key .. ":b" .. table.concat(bonuses, "."), true
    end
    return key, random
end

-- Items seen with a random enchant, remembered across scans: the gear scan's browse search lists them as the bare
-- item, and this tells it which ones to look up one by one
local function NoteRandom(link)
    local key, random = GroupKey(link)
    local id = random and tonumber(key:match("^(%d+)"))
    if id and A.db then
        A.db.randomIDs = A.db.randomIDs or {}
        A.db.randomIDs[id] = true
    end
end
A.GroupKey, A.IsGear, A.NoteRandom = GroupKey, IsGear, NoteRandom -- also used by the gear scan (GearScan.lua)

-- The AH gives each random enchant of an item a browse row of its own (its item key's itemSuffix), while auction
-- links name it by bonus ID. Each item search teaches which suffix goes with which roll (A.db.rollSuffix), so one
-- roll can be looked up, or opened, by itself.
local function RollPart(key) return key and key:match("^%d+:(.+)$") end

function A.LearnSuffix(itemKey, link)
    local suffix = itemKey and A.Plain(itemKey.itemSuffix)
    local part = suffix and suffix ~= 0 and A.db and RollPart(GroupKey(link))
    if not part then return end
    A.db.rollSuffix = type(A.db.rollSuffix) == "table" and A.db.rollSuffix or {}
    A.db.rollSuffix[part] = suffix
end

-- The browse-row suffix of a row's random enchant ("9801:b12728"), when one has been seen
function A.SuffixFor(rowKey)
    local part = RollPart(rowKey)
    return part and A.db and type(A.db.rollSuffix) == "table" and A.db.rollSuffix[part] or nil
end

------------------------------------------------------------------------
-- Reading the replicate list
------------------------------------------------------------------------

local STABLE = 2.0       -- seconds without new rows = the list is complete
local BUDGET_MS = 8      -- per frame while reading
local RETRY_FOR = 30     -- seconds to wait for item data the client hasn't loaded

local state = "idle"     -- idle, waiting, reading, loading
local lastCount, lastChange, total, index
local found, pending, pendingSince
local ticker

local function Milliseconds() return debugprofilestop and debugprofilestop() or GetTime() * 1000 end

local function AddRow(i, items)
    local _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID, hasAllInfo = C_AuctionHouse.GetReplicateItemInfo(i)
    if not itemID or itemID == 0 or not buyout or buyout <= 0 then return true end
    if not IsGear(itemID) then return true end
    local link = A.Plain(C_AuctionHouse.GetReplicateItemLink(i))
    if not link or not hasAllInfo then
        if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
        return false
    end
    local key = GroupKey(link)
    if not key then return true end
    NoteRandom(link)
    local price = buyout / math.max(count or 1, 1)
    local e = items[key]
    if not e then
        items[key] = { link = link, price = price, n = 1 }
    else
        e.n = e.n + 1
        if price < e.price then e.price, e.link = price, link end
    end
    return true
end

local function Save()
    local n = 0
    for _ in pairs(found) do n = n + 1 end
    A.db.realms[A.RealmKey()] = { t = time(), items = found, count = n }
    state = "idle"
    if ticker then ticker:Cancel(); ticker = nil end
    A.Print("saved %d gear listings from the AH scan. |cff40c0ff/ahu|r shows your upgrades.", n)
    A.Fire("DATA")
end

local function LoadStep()
    -- retry rows whose item data was still loading
    local still = {}
    for _, i in ipairs(pending) do
        if not AddRow(i, found) then still[#still + 1] = i end
    end
    pending = still
    if #pending == 0 or GetTime() - pendingSince > RETRY_FOR then
        Save()
    end
end

local function ReadStep()
    if state ~= "reading" then return end
    local started = Milliseconds()
    while index < total do
        if not AddRow(index, found) then pending[#pending + 1] = index end
        index = index + 1
        if index % 100 == 0 and Milliseconds() - started > BUDGET_MS then break end
    end
    if index < total then
        C_Timer.After(0, ReadStep)
    elseif #pending > 0 then
        state, pendingSince = "loading", GetTime()
        ticker = C_Timer.NewTicker(0.5, LoadStep)
    else
        Save()
    end
end

local waitingSince

local function Stop()
    state = "idle"
    if ticker then ticker:Cancel(); ticker = nil end
end

local function Poll()
    if state ~= "waiting" then return end
    if GetTime() - waitingSince > 120 then Stop() return end -- the list never arrived
    local count = C_AuctionHouse.GetNumReplicateItems() or 0
    if count ~= lastCount then
        lastCount, lastChange = count, GetTime()
        return
    end
    if count > 0 and GetTime() - lastChange >= STABLE then
        ticker:Cancel(); ticker = nil
        state, total, index, found, pending = "reading", count, 0, {}, {}
        C_Timer.After(0, ReadStep)
    end
end

local function OnReplicateUpdate()
    if not (C_AuctionHouse and C_AuctionHouse.GetReplicateItemInfo and C_AuctionHouse.GetReplicateItemLink) then return end
    if state ~= "idle" then
        if state == "waiting" then lastChange = GetTime() end
        return
    end
    state, lastCount, lastChange, waitingSince = "waiting", -1, GetTime(), GetTime()
    ticker = C_Timer.NewTicker(0.25, Poll)
end

------------------------------------------------------------------------
-- Events
------------------------------------------------------------------------

local ev = CreateFrame("Frame")
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_LOGIN")
pcall(ev.RegisterEvent, ev, "REPLICATE_ITEM_LIST_UPDATE")
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_SHOW")
pcall(ev.RegisterEvent, ev, "AUCTION_HOUSE_CLOSED")
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= ADDON then return end
        AHUpgradesDB = type(AHUpgradesDB) == "table" and AHUpgradesDB or {}
        local db = AHUpgradesDB
        db.realms = type(db.realms) == "table" and db.realms or {}
        if db.sort == nil then db.sort = "value" end
        db.randomIDs = type(db.randomIDs) == "table" and db.randomIDs or {}
        A.db = db
        -- learn the random-enchant items from the saved listings too (scans made before randomIDs existed)
        for _, realm in pairs(db.realms) do
            for _, e in pairs(type(realm) == "table" and type(realm.items) == "table" and realm.items or {}) do
                if type(e) == "table" and type(e.link) == "string" then NoteRandom(e.link) end
            end
        end
    elseif event == "PLAYER_LOGIN" then
        A.Fire("LOGIN")
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        OnReplicateUpdate()
    elseif event == "AUCTION_HOUSE_SHOW" then
        A.Fire("AH_SHOW")
    elseif event == "AUCTION_HOUSE_CLOSED" then
        -- The list is gone once the AH closes: a half-read scan must not replace the last complete one
        if state ~= "idle" then
            Stop()
            A.Print("the AH closed before the scan was read; kept the previous data.")
        end
        A.Fire("AH_CLOSED")
    end
end)

function A.CaptureState() return state end
