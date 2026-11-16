-- AH Upgrades: the bank.
-- The bank can only be read while it is open, so each visit records the gear in it (per character, in the saved
-- variables). Rank.lua counts that gear as owned, like the bags: a listing has to beat it too.
local _, A = ...

local GetItemInfoInstant = C_Item and C_Item.GetItemInfoInstant or _G.GetItemInfoInstant
local SKIP_LOC = { [""] = true, INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true,
    INVTYPE_QUIVER = true, INVTYPE_AMMO = true, INVTYPE_NON_EQUIP_IGNORE = true }

local function CharKey()
    local realm = (GetNormalizedRealmName and GetNormalizedRealmName()) or (GetRealmName() or ""):gsub("%s+", "")
    return (UnitName("player") or "?") .. "-" .. realm
end

-- Every container the bank can have on this client: the classic bank and its bags, or the newer bank tabs
local function BankContainers()
    local list, seen = {}, {}
    local function Add(id)
        if type(id) == "number" and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    Add(_G.BANK_CONTAINER)
    local first = (_G.NUM_TOTAL_EQUIPPED_BAG_SLOTS or _G.NUM_BAG_SLOTS or 4) + 1
    local count = _G.NUM_BANKBAGSLOTS
        or (Constants and Constants.InventoryConstants and Constants.InventoryConstants.NumCharacterBankSlots) or 7
    for id = first, first + count - 1 do Add(id) end
    if Enum and Enum.BagIndex then
        Add(Enum.BagIndex.Bank)
        for i = 1, 6 do Add(Enum.BagIndex["CharacterBankTab_" .. i]) end
    end
    return list
end

local bankOpen = false

-- Records the gear in the bank. Only while it is open: otherwise the client has nothing to say.
local function Save()
    if not (bankOpen and A.db and C_Container) then return end
    local links, n = {}, 0
    local read = false
    for _, bag in ipairs(BankContainers()) do
        local ok, slots = pcall(C_Container.GetContainerNumSlots, bag)
        slots = ok and A.Plain(slots) or 0
        if slots > 0 then read = true end
        for slot = 1, slots do
            local okInfo, item = pcall(C_Container.GetContainerItemInfo, bag, slot)
            local link = okInfo and item and A.Plain(item.hyperlink)
            if link then
                local _, _, _, loc, _, classID = GetItemInfoInstant(link)
                if (classID == 2 or classID == 4) and not SKIP_LOC[loc or ""] then
                    n = n + 1
                    links[n] = link
                end
            end
        end
    end
    if not read then return end -- the bank did not answer: keep what was saved before
    A.db.bank = type(A.db.bank) == "table" and A.db.bank or {}
    A.db.bank[CharKey()] = { t = time(), links = links }
    A.Fire("BANK")
end

-- Bagnon's cache (BagBrother) of this character's bank: BrotherBags[realm][owner][bag].items, each item an item
-- string payload ("12345::::::::21:1489::11", ";count" after stacks). On WoW Forever the realm key is "forever"
-- and the owner "Name Realm". Bank bags are -1 (classic bank) and everything after the equipped bags (bank tabs).
local function BagnonBank()
    local root = _G.BrotherBags
    if type(root) ~= "table" then return nil end
    local name, realm = UnitFullName("player")
    if not name then return nil end
    realm = realm or (GetNormalizedRealmName and GetNormalizedRealmName())
    local owners = { (realm and (name .. " " .. realm)) or name, name }
    local lastBag = _G.NUM_TOTAL_EQUIPPED_BAG_SLOTS or _G.NUM_BAG_SLOTS or 4
    for _, realmKey in ipairs({ "forever", (GetNormalizedRealmName and GetNormalizedRealmName()) or "" }) do
        local byOwner = type(root[realmKey]) == "table" and root[realmKey]
        for _, owner in ipairs(owners) do
            local cache = byOwner and type(byOwner[owner]) == "table" and byOwner[owner]
            if cache then
                local links, found = {}, false
                for bag, data in pairs(cache) do
                    if type(bag) == "number" and (bag == -1 or bag > lastBag) and type(data) == "table" then
                        found = true
                        for _, s in pairs(type(data.items) == "table" and data.items or {}) do
                            local payload = type(s) == "string" and s:match("^([^;]+)")
                            if payload and payload:match("^%d+") then
                                local link = "item:" .. payload
                                local _, _, _, loc, _, classID = GetItemInfoInstant(link)
                                if (classID == 2 or classID == 4) and not SKIP_LOC[loc or ""] then links[#links + 1] = link end
                            end
                        end
                    end
                end
                if found then return links end
            end
        end
    end
    return nil
end

-- The gear in this character's bank: our own record from the last visit, or else Bagnon's cache of it. Also says
-- when it was recorded (ours only) and where the list came from ("ahu", "bagnon", or nil when there is none).
function A.BankLinks()
    local saved = A.db and type(A.db.bank) == "table" and A.db.bank[CharKey()]
    if saved then return saved.links or {}, saved.t, "ahu" end
    local bagnon = BagnonBank()
    if bagnon then return bagnon, nil, "bagnon" end
    return {}, nil, nil
end

local pending = false
local function SaveSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.5, function()
        pending = false
        Save()
    end)
end

local BANKER = Enum and Enum.PlayerInteractionType and Enum.PlayerInteractionType.Banker
local ev = CreateFrame("Frame")
for _, event in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "PLAYER_INTERACTION_MANAGER_FRAME_SHOW",
    "PLAYER_INTERACTION_MANAGER_FRAME_HIDE", "PLAYERBANKSLOTS_CHANGED", "BAG_UPDATE_DELAYED", "PLAYER_LOGIN" }) do
    pcall(ev.RegisterEvent, ev, event)
end
ev:SetScript("OnEvent", function(_, event, arg1)
    if event == "BANKFRAME_OPENED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_SHOW" and BANKER and arg1 == BANKER) then
        bankOpen = true
        SaveSoon()
    elseif event == "BANKFRAME_CLOSED" or (event == "PLAYER_INTERACTION_MANAGER_FRAME_HIDE" and BANKER and arg1 == BANKER) then
        if bankOpen then Save() end -- still readable as it closes: what was moved last counts
        bankOpen = false
    elseif event == "PLAYER_LOGIN" then
        -- ask the client to load the saved items, so they can be scored when the list first opens
        local load = C_Item and C_Item.RequestLoadItemDataByID
        for _, link in ipairs((A.BankLinks())) do
            local id = tonumber(link:match("item:(%d+)"))
            if id and load then pcall(load, id) end
        end
    elseif bankOpen then
        SaveSoon() -- something moved in or out while at the bank
    end
end)
