-- AH Upgrades: the list. Shown as an "Upgrades" tab on the Auction House (next to Buy / Sell / Auctions), and as a
-- standalone window with /ahu when the AH is closed.
local _, A = ...

local ROWS, ROW_H = 16, 22
local SLOT_Y, SLOT_H = 46, 32 -- the row of slot buttons: where it starts, and how far it pushes the list down
local SORT_LABEL = { value = "Best value", gain = "Biggest upgrade", price = "Cheapest", slot = "By slot", name = "By name",
    score = "By score" }
-- The Sort button cycles these; slot and name sorting stay on the column headers
local SORT_NEXT = { value = "gain", gain = "price", price = "value", slot = "value", name = "value", score = "value" }
local views = {} -- every built list (the AH tab, the window)

-- Picks a sort: a new column sorts its natural way, the current one again flips it
local function SetSort(key, fromHeader)
    if fromHeader and A.db.sort == key then
        A.db.sortReverse = not A.db.sortReverse
    else
        A.db.sort, A.db.sortReverse = key, false
    end
    A.SortResults()
    for _, other in ipairs(views) do other.offset = 0 end
    A.Refresh()
end

local function coins(c) return C_CurrencyInfo.GetCoinTextureString(math.floor(c + 0.5)) end

local function ago(t)
    local s = time() - t
    if s < 3600 then return ("%d min ago"):format(math.max(1, math.floor(s / 60))) end
    if s < 86400 then return ("%d h ago"):format(math.floor(s / 3600)) end
    return ("%d days ago"):format(math.floor(s / 86400))
end

function A.IsShown()
    for _, v in ipairs(views) do
        if v.frame:IsVisible() then return true end
    end
    return false
end

local GetItemInfo = C_Item and C_Item.GetItemInfo or _G.GetItemInfo

local function SearchAH(link)
    local id = tonumber(link:match("item:(%d+)"))
    local name = id and GetItemInfo(id) -- base name, without "of the Bear": the AH search finds every version
    if not name then return end
    local ah = _G.AuctionHouseFrame
    if not (ah and ah:IsShown() and ah.SearchBar) then
        A.Print("open the Auction House to search for %s.", name)
        return
    end
    local ok = pcall(function()
        if ah.SetDisplayMode and _G.AuctionHouseFrameDisplayMode then ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
        ah.SearchBar:SetSearchText(name)
        ah.SearchBar:StartSearch()
    end)
    if not ok then A.Print("search the AH for: %s", name) end
end

------------------------------------------------------------------------
-- Filling a list
------------------------------------------------------------------------

-- The slot buttons above the list, in paper-doll order. `group` matches Rank.lua's SLOT_ORDER (both rings are one
-- group, both trinkets another).
local SLOT_BUTTONS = {
    { 1, "HeadSlot", "Head" }, { 2, "NeckSlot", "Neck" }, { 3, "ShoulderSlot", "Shoulder" }, { 4, "BackSlot", "Back" },
    { 5, "ChestSlot", "Chest" }, { 6, "WristSlot", "Wrist" }, { 7, "HandsSlot", "Hands" }, { 8, "WaistSlot", "Waist" },
    { 9, "LegsSlot", "Legs" }, { 10, "FeetSlot", "Feet" }, { 11, "Finger0Slot", "Rings" }, { 12, "Trinket0Slot", "Trinkets" },
    { 13, "MainHandSlot", "Main hand" }, { 14, "SecondaryHandSlot", "Off hand" }, { 15, "RangedSlot", "Ranged" },
}
local SLOT_LABEL = {}
for _, s in ipairs(SLOT_BUTTONS) do SLOT_LABEL[s[1]] = s[3] end

-- The results under the max price; with `counts`, also how many of them there are per slot
local function Filtered(out, counts)
    wipe(out)
    if counts then wipe(counts) end
    local max = A.db.maxGold and A.db.maxGold * 10000
    local slot = A.db.slotFilter
    for _, r in ipairs(A.Results()) do
        if not max or r.price <= max then
            if counts then counts[r.slotOrder or 99] = (counts[r.slotOrder or 99] or 0) + 1 end
            if not slot or r.slotOrder == slot then out[#out + 1] = r end
        end
    end
    return out
end

local function SetSlotFilter(group)
    A.db.slotFilter = group
    for _, other in ipairs(views) do other.offset = 0 end
    A.Refresh()
end

-- Main or second spec: the list is judged again with that spec's PawnForever scale
local function SetSpecView(view)
    if A.specView == view then return end
    A.specView = view
    for _, other in ipairs(views) do other.offset = 0 end
    A.dirty = false
    A.Rank()
end

-- The spec named in texts: "for Feral" (only once there is a second spec to tell it from)
local function ForSpec()
    local _, second = A.TrackedScales()
    local scale = A.RankedScale()
    if not (second and scale) then return "" end
    return " for " .. A.ScaleLabel(scale)
end

local function StatusText()
    local status, done, total = A.RankStatus()
    if A.CaptureState() ~= "idle" then return "|cffffd100Reading the AH scan...|r" end
    local scan, a, b = A.GearScanState()
    if scan == "browse" then
        return ("|cffffd100Scanning the AH for gear you can use...|r (%d page%s)"):format(a, a == 1 and "" or "s")
    elseif scan == "loading" then
        return "|cffffd100Scanning the AH: loading item data...|r"
    elseif scan == "details" then
        return ("|cffffd100Scanning the AH: random enchants, %d of %d...|r"):format(math.min(a, b), b)
    end
    if status == "nopawn" then return "|cffff6060PawnForever is not loaded: it supplies the stat weights.|r" end
    if status == "nodata" then
        return "|cffff6060No AH data yet.|r Press Scan gear (or ForeverCraftAssistant's Scan) at the AH."
    end
    local src = A.source or {}
    local from
    if src.kind == "gear" then
        from = "this realm's gear scan"
    elseif src.kind == "scan" then
        from = "this realm's scan"
    else
        from = "ForeverCraftAssistant prices" .. (src.realm and (" from |cffffd100" .. src.realm .. "|r") or "")
    end
    local when = src.t and (", " .. ago(src.t)) or ""
    if status == "working" then
        return ("Checking %d of %d gear items%s (%s%s)..."):format(done, total, ForSpec(), from, when)
    end
    local bags = (A.inBags or 0) > 0 and ("; %d skipped, already owned"):format(A.inBags) or ""
    return ("%d upgrades%s among %d gear items (%s%s)%s"):format(#A.Results(), ForSpec(), src.count or 0, from, when, bags)
end

local function RefreshView(v)
    if not v.frame:IsVisible() then return end
    local list = Filtered(v.list, v.counts)
    local total = 0
    for _, n in pairs(v.counts) do total = total + n end
    v.allButton:SetText(("All (%d)"):format(total))
    v.allButton:SetAlpha(A.db.slotFilter and 0.7 or 1)
    for _, b in ipairs(v.slotButtons) do
        local n = v.counts[b.group] or 0
        b.count:SetText(n > 0 and n or "")
        b.icon:SetDesaturated(n == 0)
        b.icon:SetAlpha(n > 0 and 1 or 0.35)
        b.selected:SetShown(A.db.slotFilter == b.group)
    end
    v.offset = math.max(0, math.min(v.offset, #list - ROWS))
    for i = 1, ROWS do
        local row, r = v.rows[i], list[v.offset + i]
        row.data = r
        if r then
            row.icon:SetTexture(r.icon or 134400)
            row.name:SetText(r.link)
            row.slot:SetText(r.slot)
            row.score:SetText(r.scoreText or "")
            row.gain:SetText(r.gainText)
            row.price:SetText(coins(r.price))
            row.value:SetText(("%.0f%%/g"):format(r.value))
            row:Show()
        else
            row:Hide()
        end
    end
    v.status:SetText(StatusText())
    v.sortButton:SetText("Sort: " .. (SORT_LABEL[A.db.sort] or SORT_LABEL.value) .. (A.db.sortReverse and " (rev)" or ""))
    -- Arrow next to the sorted column: down = highest/first at the top
    local s = A.SORTS[A.db.sort] or A.SORTS.value
    local down = s[2]
    if A.db.sortReverse then down = not down end
    for _, h in ipairs(v.headers) do
        if h.key == (A.SORTS[A.db.sort] and A.db.sort or "value") then
            h.arrow:ClearAllPoints()
            if h.right then h.arrow:SetPoint("RIGHT", h.text, "LEFT", -2, 0)
            else h.arrow:SetPoint("LEFT", h.text, "RIGHT", 2, 0) end
            if down then h.arrow:SetTexCoord(0, 0.5625, 0, 1) else h.arrow:SetTexCoord(0, 0.5625, 1, 0) end
            h.arrow:Show()
        else
            h.arrow:Hide()
        end
    end
    if not v.maxBox:HasFocus() then v.maxBox:SetText(A.db.maxGold and tostring(A.db.maxGold) or "") end
    v.footer:SetText(#list > 0 and ("%d-%d of %d   (mouse wheel to scroll)"):format(v.offset + 1, math.min(v.offset + ROWS, #list), #list) or
        (A.RankStatus() == "done" and (A.db.slotFilter
            and ("No %s upgrades%s here (or under your max price). Click All for every slot."):format((SLOT_LABEL[A.db.slotFilter] or ""):lower(), ForSpec())
            or ("No upgrades%s in this scan (or under your max price)."):format(ForSpec())) or ""))
    -- Spec switch: main always, second only when PawnForever tracks one
    local main, second = A.TrackedScales()
    local _, view = A.ViewScale()
    for _, b in ipairs(v.specButtons) do
        local scale = b.view == "second" and second or main
        b:SetShown(scale ~= nil)
        if scale then
            b:SetText(A.ScaleLabel(scale))
            local on = view == b.view
            if on then b:LockHighlight() else b:UnlockHighlight() end
            b:SetAlpha(on and 1 or 0.6)
            b.selected:SetShown(on and second ~= nil)
        end
    end
    local scanning = A.GearScanState() ~= "idle"
    v.scanButton:SetText(scanning and "Stop scan" or "Scan gear")
    v.scanButton:SetEnabled(scanning or (A.CanGearScan()))
    v.liveFrame:SetShown(v == A.ahView and A.LiveActive and A.LiveActive() or false)
end

function A.Refresh()
    for _, v in ipairs(views) do RefreshView(v) end
end

-- The rows on screen in the AH's Upgrades tab, for the live re-check (GearScan.lua); none when it isn't shown
function A.LiveTargets()
    local v = A.ahView
    if not (v and v.frame:IsVisible()) then return {} end
    local list = {}
    for i = 1, ROWS do
        local r = v.list[v.offset + i]
        if r then list[#list + 1] = r end
    end
    return list
end

A.On("RESULTS", A.Refresh)
A.On("DATA", A.Refresh)
A.On("SCAN", A.Refresh)

-- Each visit to the AH (and each /ahu window) starts on the main spec; flipping between the Upgrades tab and
-- Buy / Sell / Auctions during a visit keeps the spec picked
local function StartOnMain()
    if A.specView ~= "main" then
        A.specView = "main"
        A.dirty = true
    end
end

local function OnListShown()
    if A.dirty or A.RankStatus() == "idle" then
        A.dirty = false
        A.Rank()
    end
    A.Refresh()
end

------------------------------------------------------------------------
-- Building a list inside a frame
------------------------------------------------------------------------

local function Label(parent, template, width, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY", template or "GameFontHighlightSmall")
    if width then fs:SetWidth(width) end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- columns: x offset, width, header, justify, sort key
local COLS = {
    { 30, 196, "Item", "LEFT", "name" }, { 232, 64, "Slot", "LEFT", "slot" }, { 300, 44, "Score", "RIGHT", "score" },
    { 356, 112, "Upgrade", "LEFT", "gain" }, { 472, 92, "Price", "LEFT", "price" }, { 568, 52, "Value", "RIGHT", "value" },
}
local LIST_W = 640

-- Builds the list into `host` (any frame); the list's own frame is `content`, 640 wide, centered at the top.
local function BuildList(host, top)
    local v = { offset = 0, list = {}, rows = {} }
    local content = CreateFrame("Frame", nil, host)
    content:SetSize(LIST_W, 80 + SLOT_H + ROWS * ROW_H)
    content:SetPoint("TOP", host, "TOP", 0, top or 0)
    v.frame = host

    v.status = Label(content, "GameFontHighlightSmall", 470)
    v.status:SetPoint("TOPLEFT", 12, 0)

    -- Scan gear: our own AH search for weapons and armor you can use (GearScan.lua); again to stop it
    local scan = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    scan:SetSize(96, 20)
    scan:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, 3)
    scan:SetScript("OnClick", function() A.GearScan() end)
    scan:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Scan gear")
        GameTooltip:AddLine("Searches the AH for weapons and armor you can use, up to your level: much quicker than a "
            .. "full scan, and it can run any time.", 1, 1, 1, true)
        GameTooltip:AddLine("Items with a random enchant (\"of the Bear\") are looked up one by one, so their real "
            .. "stats count.", 0.7, 0.7, 0.7, true)
        local ok, why = A.CanGearScan()
        if A.GearScanState() ~= "idle" then
            GameTooltip:AddLine("Click to stop.", 1, 0.82, 0)
        elseif not ok then
            GameTooltip:AddLine("Can't scan now: " .. why .. ".", 1, 0.4, 0.4, true)
        end
        GameTooltip:Show()
    end)
    scan:SetScript("OnLeave", GameTooltip_Hide)
    v.scanButton = scan

    -- "Live" next to it while the rows on screen are being looked up again
    local liveFrame = CreateFrame("Frame", nil, content)
    liveFrame:SetSize(40, 20)
    liveFrame:SetPoint("RIGHT", scan, "LEFT", -6, 0)
    liveFrame:EnableMouse(true)
    local liveText = Label(liveFrame, "GameFontNormalSmall", nil, "RIGHT")
    liveText:SetPoint("RIGHT", 0, 0)
    liveText:SetText("|cff40ff40Live|r")
    liveFrame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("Live prices")
        GameTooltip:AddLine("The rows on screen are looked up on the AH again, one every couple of seconds: a new "
            .. "cheapest price is put in, and an item that is gone is taken off the list.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    liveFrame:SetScript("OnLeave", GameTooltip_Hide)
    liveFrame:Hide()
    v.liveFrame = liveFrame

    local sortButton = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    sortButton:SetSize(150, 22)
    sortButton:SetPoint("TOPLEFT", 10, -18)
    sortButton:SetScript("OnClick", function() SetSort(SORT_NEXT[A.db.sort] or "value") end)
    v.sortButton = sortButton

    local maxLabel = Label(content, "GameFontNormalSmall")
    maxLabel:SetPoint("LEFT", sortButton, "RIGHT", 14, 0)
    maxLabel:SetText("Max gold:")
    local maxBox = CreateFrame("EditBox", nil, content, "InputBoxTemplate")
    maxBox:SetSize(50, 20)
    maxBox:SetPoint("LEFT", maxLabel, "RIGHT", 8, 0)
    maxBox:SetAutoFocus(false)
    local function ApplyMax(box)
        A.db.maxGold = tonumber(box:GetText())
        box:ClearFocus()
        for _, other in ipairs(views) do other.offset = 0 end
        A.Refresh()
    end
    maxBox:SetScript("OnEnterPressed", ApplyMax)
    maxBox:SetScript("OnEscapePressed", function(box) box:ClearFocus(); A.Refresh() end)
    v.maxBox = maxBox

    local recheck = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    recheck:SetSize(80, 22)
    recheck:SetPoint("LEFT", maxBox, "RIGHT", 14, 0)
    recheck:SetText("Recheck")
    recheck:SetScript("OnClick", function() A.Rank() end)

    -- Spec switch, right-aligned on this row: PawnForever's main scale and its second one, each in its colour
    v.specButtons = {}
    local SPEC_TIP = {
        main = "Upgrades for your main PawnForever scale.",
        second = "Upgrades for the second scale PawnForever tracks.",
    }
    for i, view in ipairs({ "second", "main" }) do -- built right to left
        local b = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
        b:SetSize(108, 22)
        if i == 1 then b:SetPoint("TOPRIGHT", content, "TOPRIGHT", -10, -18)
        else b:SetPoint("RIGHT", v.specButtons[1], "LEFT", -4, 0) end
        b.view = view
        b.selected = b:CreateTexture(nil, "OVERLAY")
        b.selected:SetTexture("Interface\\Buttons\\UI-Listbox-Highlight2")
        b.selected:SetBlendMode("ADD")
        b.selected:SetVertexColor(1, 0.82, 0, 0.35)
        b.selected:SetPoint("TOPLEFT", 3, -3)
        b.selected:SetPoint("BOTTOMRIGHT", -3, 3)
        b.selected:Hide()
        b:SetScript("OnClick", function(self) SetSpecView(self.view) end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(self:GetText() or "")
            GameTooltip:AddLine(SPEC_TIP[self.view], 1, 1, 1, true)
            local _, second = A.TrackedScales()
            if not second then
                GameTooltip:AddLine("Pick a second scale in PawnForever's options to switch between two specs here.", 0.7, 0.7, 0.7, true)
            end
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        v.specButtons[i] = b
    end

    -- Slot buttons: show only one slot's upgrades; click it again (or All) for every slot
    v.counts, v.slotButtons = {}, {}
    local all = CreateFrame("Button", nil, content, "UIPanelButtonTemplate")
    all:SetSize(72, 24)
    all:SetPoint("TOPLEFT", 10, -SLOT_Y)
    all:SetScript("OnClick", function() SetSlotFilter(nil) end)
    v.allButton = all
    local prevButton = all
    for _, s in ipairs(SLOT_BUTTONS) do
        local b = CreateFrame("Button", nil, content)
        b:SetSize(26, 26)
        b:SetPoint("LEFT", prevButton, "RIGHT", prevButton == all and 8 or 3, 0)
        b.group = s[1]
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetAllPoints()
        local okSlot, _, texture = pcall(GetInventorySlotInfo, s[2])
        b.icon:SetTexture(okSlot and texture or 134400)
        b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        b.count:SetPoint("BOTTOMRIGHT", -1, 1)
        b.selected = b:CreateTexture(nil, "OVERLAY")
        b.selected:SetTexture("Interface\\Buttons\\CheckButtonHilight")
        b.selected:SetBlendMode("ADD")
        b.selected:SetAllPoints()
        b.selected:Hide()
        b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
        b:SetScript("OnClick", function(self)
            SetSlotFilter(A.db.slotFilter ~= self.group and self.group or nil)
        end)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText(s[3])
            local n = v.counts[self.group] or 0
            GameTooltip:AddLine(n == 1 and "1 upgrade" or ("%d upgrades"):format(n), 1, 1, 1)
            GameTooltip:AddLine(A.db.slotFilter == self.group and "Click again to show every slot." or "Click to show only these.", 0.7, 0.7, 0.7)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", GameTooltip_Hide)
        v.slotButtons[#v.slotButtons + 1] = b
        prevButton = b
    end

    -- Column headers: click to sort by that column, click again to flip it
    v.headers = {}
    for _, c in ipairs(COLS) do
        local h = CreateFrame("Button", nil, content)
        h:SetSize(c[2], 16)
        h:SetPoint("TOPLEFT", c[1] - 8, -46 - SLOT_H)
        h.text = Label(h, "GameFontNormalSmall", nil, c[4])
        h.text:SetText(c[3])
        h.right = c[4] == "RIGHT"
        if h.right then h.text:SetPoint("RIGHT", 0, 0) else h.text:SetPoint("LEFT", 0, 0) end
        h.arrow = h:CreateTexture(nil, "OVERLAY")
        h.arrow:SetTexture("Interface\\Buttons\\UI-SortArrow")
        h.arrow:SetSize(9, 8)
        h.arrow:Hide()
        h.key = c[5]
        h:SetScript("OnClick", function(self) SetSort(self.key, true) end)
        h:SetScript("OnEnter", function(self)
            self.text:SetTextColor(1, 1, 1)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:SetText("Sort by " .. c[3]:lower())
            GameTooltip:AddLine("Click again to reverse.", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end)
        h:SetScript("OnLeave", function(self)
            self.text:SetTextColor(NORMAL_FONT_COLOR:GetRGB())
            GameTooltip:Hide()
        end)
        v.headers[#v.headers + 1] = h
    end

    for i = 1, ROWS do
        local row = CreateFrame("Button", nil, content)
        row:SetSize(620, ROW_H)
        row:SetPoint("TOPLEFT", 8, -62 - SLOT_H - (i - 1) * ROW_H)
        row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        row:RegisterForClicks("LeftButtonUp")
        row.icon = row:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.icon:SetPoint("LEFT", 2, 0)
        row.name = Label(row, "GameFontHighlightSmall", COLS[1][2])
        row.name:SetPoint("LEFT", COLS[1][1] - 8, 0)
        row.slot = Label(row, "GameFontHighlightSmall", COLS[2][2])
        row.slot:SetPoint("LEFT", COLS[2][1] - 8, 0)
        row.score = Label(row, "GameFontHighlightSmall", COLS[3][2], "RIGHT")
        row.score:SetPoint("LEFT", COLS[3][1] - 8, 0)
        row.gain = Label(row, "GameFontHighlightSmall", COLS[4][2])
        row.gain:SetPoint("LEFT", COLS[4][1] - 8, 0)
        row.gain:SetTextColor(0.25, 1, 0.25)
        row.price = Label(row, "GameFontHighlightSmall", COLS[5][2])
        row.price:SetPoint("LEFT", COLS[5][1] - 8, 0)
        row.value = Label(row, "GameFontHighlightSmall", COLS[6][2], "RIGHT")
        row.value:SetPoint("LEFT", COLS[6][1] - 8, 0)
        row:SetScript("OnEnter", function(self)
            if not self.data then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(self.data.link)
            GameTooltip:AddLine(("%d listed, cheapest %s"):format(self.data.n, coins(self.data.price)), 0.6, 0.6, 0.6)
            if self.data.checked then
                GameTooltip:AddLine(("Checked on the AH %d s ago."):format(math.floor(GetTime() - self.data.checked)), 0.6, 0.6, 0.6)
            end
            if self.data.random then
                GameTooltip:AddLine("Judged without its random enchant: the ones on the AH have extra stats.", 0.6, 0.6, 0.6, true)
            end
            if self.data.vsBag then
                local where = self.data.vsWhere == "bank" and "in your bank (as at your last visit)" or "in your bags"
                GameTooltip:AddLine("Upgrade over " .. self.data.vsBag .. ", which you already have " .. where .. ".", 0.6, 0.6, 0.6, true)
            end
            GameTooltip:Show()
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnClick", function(self)
            if not self.data then return end
            if IsShiftKeyDown() then
                if ChatEdit_InsertLink then ChatEdit_InsertLink(self.data.link) end
            else
                SearchAH(self.data.link)
            end
        end)
        v.rows[i] = row
    end

    v.footer = Label(content, "GameFontDisableSmall")
    v.footer:SetPoint("TOPLEFT", 12, -66 - SLOT_H - ROWS * ROW_H)
    local hint = Label(content, "GameFontDisableSmall", nil, "RIGHT")
    hint:SetPoint("TOPRIGHT", -12, -66 - SLOT_H - ROWS * ROW_H)
    hint:SetText("Click: search AH   Shift-click: link")

    host:EnableMouseWheel(true)
    host:SetScript("OnMouseWheel", function(_, delta)
        v.offset = math.max(0, v.offset - delta * 3)
        RefreshView(v)
    end)
    host:HookScript("OnShow", OnListShown)
    views[#views + 1] = v
    return v
end

------------------------------------------------------------------------
-- The Upgrades tab on the Auction House
------------------------------------------------------------------------

local tab, panel

local function ShowPanel(on)
    if not panel then return end
    local ah = _G.AuctionHouseFrame
    if on then
        panel:Show()
        -- only the tabs' look changes; the AH's own state (which mode it is in) is left alone
        if PanelTemplates_DeselectTab and ah and ah.Tabs then
            for _, t in ipairs(ah.Tabs) do pcall(PanelTemplates_DeselectTab, t) end
        end
        if PanelTemplates_SelectTab then pcall(PanelTemplates_SelectTab, tab) end
    else
        panel:Hide()
        if PanelTemplates_DeselectTab then pcall(PanelTemplates_DeselectTab, tab) end
    end
end

local function CreateTab(ah)
    local last = (ah.Tabs and ah.Tabs[#ah.Tabs]) or ah.AuctionsTab
    if not last then return false end
    -- The tab lives in a holder of its own, not directly on the AH: tab templates add themselves to their parent's
    -- Tabs list, and an extra entry there (with no AH mode behind it) is what broke Buy/Sell/Auctions.
    local holder = CreateFrame("Frame", nil, ah)
    holder:SetAllPoints(ah)
    holder:SetFrameLevel(ah:GetFrameLevel() + 2)
    local ok, b = pcall(CreateFrame, "Button", "AHUpgradesTab", holder, "PanelTabButtonTemplate")
    if not (ok and b) then
        b = CreateFrame("Button", "AHUpgradesTab", holder, "UIPanelButtonTemplate")
        b:SetSize(100, 24)
    end
    tab = b
    -- same spacing as between Blizzard's own tabs
    local x, y = -15, 0
    local first, second = ah.Tabs and ah.Tabs[1], ah.Tabs and ah.Tabs[2]
    if second and second.GetPoint then
        local _, rel, _, px, py = second:GetPoint(1)
        if rel == first and px then x, y = px, py or 0 end
    end
    tab:ClearAllPoints()
    tab:SetPoint("LEFT", last, "RIGHT", x, y)
    tab:SetText("Upgrades")
    if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
    tab:SetScript("OnClick", function()
        PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
        ShowPanel(true)
    end)
    tab:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText("AH Upgrades")
        GameTooltip:AddLine("Gear on the AH that beats what you wear, by your PawnForever weights.", 1, 1, 1, true)
        GameTooltip:AddLine("Uses the last full scan (ForeverCraftAssistant's Scan button).", 0.7, 0.7, 0.7, true)
        GameTooltip:Show()
    end)
    tab:SetScript("OnLeave", GameTooltip_Hide)
    tab:Show()
    return true
end

local function CreatePanel(ah)
    -- Covers the AH's content area (between its title bar and the tabs) while the tab is selected
    panel = CreateFrame("Frame", nil, ah, "BackdropTemplate")
    panel:SetPoint("TOPLEFT", ah, "TOPLEFT", 4, -24)
    panel:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -4, 4)
    -- a strata above the AH's own content, so none of it draws over the list
    panel:SetFrameStrata("HIGH")
    panel:SetToplevel(true)
    panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8X8" })
    panel:SetBackdropColor(0.06, 0.06, 0.08, 1)
    panel:EnableMouse(true)
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 14, -10)
    title:SetText("AH Upgrades")
    local sub = panel:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    sub:SetPoint("LEFT", title, "RIGHT", 8, -1)
    sub:SetText("by your PawnForever weights")
    panel:Hide()
    A.ahView = BuildList(panel, -34)
end

A.On("AH_SHOW", function()
    StartOnMain()
    local ah = _G.AuctionHouseFrame
    if not ah then return end
    if not tab then
        if A.tabTried then return end -- it failed once this session: don't stack half-built copies
        A.tabTried = true
        -- the list first: a tab with nothing behind it is worse than no tab
        local ok, err = pcall(CreatePanel, ah)
        if not ok then
            A.lastError = "list: " .. tostring(err)
            if panel then panel:Hide() end
            A.Print("|cffff6060could not build the Upgrades tab:|r %s", tostring(err))
            return
        end
        ok, err = pcall(CreateTab, ah)
        if not ok or not tab then
            A.lastError = "tab: " .. tostring(err)
            A.Print("|cffff6060could not add the Upgrades tab:|r %s. /ahu opens the list as a window.", tostring(err))
            return
        end
        -- picking Buy / Sell / Auctions (or searching from our list) hands the AH back to Blizzard
        if ah.SetDisplayMode then hooksecurefunc(ah, "SetDisplayMode", function() ShowPanel(false) end) end
    end
    ShowPanel(false)
end)
A.On("AH_CLOSED", function() ShowPanel(false) end)

------------------------------------------------------------------------
-- Standalone window (/ahu with the AH closed)
------------------------------------------------------------------------

local window

local function BuildWindow()
    window = CreateFrame("Frame", "AHUpgradesFrame", UIParent, "BackdropTemplate")
    window:SetSize(LIST_W, 120 + SLOT_H + ROWS * ROW_H)
    window:SetPoint("CENTER")
    window:SetFrameStrata("HIGH")
    window:SetBackdrop({
        bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border", edgeSize = 14,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    window:SetBackdropColor(0.05, 0.05, 0.08, 0.95)
    window:SetMovable(true)
    window:EnableMouse(true)
    window:RegisterForDrag("LeftButton")
    window:SetScript("OnDragStart", window.StartMoving)
    window:SetScript("OnDragStop", window.StopMovingOrSizing)
    window:SetClampedToScreen(true)
    tinsert(UISpecialFrames, "AHUpgradesFrame") -- Escape closes it
    local title = window:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 12, -10)
    title:SetText("AH Upgrades")
    local close = CreateFrame("Button", nil, window, "UIPanelCloseButton")
    close:SetPoint("TOPRIGHT", 0, 0)
    window:Hide()
    BuildList(window, -34)
end

SLASH_AHUPGRADES1, SLASH_AHUPGRADES2 = "/ahu", "/ahupgrades"
SlashCmdList.AHUPGRADES = function(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")
    if msg == "debug" then
        local ah = _G.AuctionHouseFrame
        local s = tostring
        A.Print("AH frame %s, shown %s; tab %s%s; list %s; last error: %s", ah and "found" or "missing",
            s(ah and ah:IsShown()), tab and "made" or "not made",
            tab and (", visible " .. s(tab:IsVisible()) .. ", size " .. s(math.floor(tab:GetWidth())) .. "x" .. s(math.floor(tab:GetHeight()))) or "",
            panel and "made" or "not made", A.lastError or "none")
        if ah and ah:IsShown() and not tab then
            A.tabTried = false
            A.Fire("AH_SHOW") -- try again now
        end
        return
    end
    if msg == "status" then
        local data = A.RealmData()
        A.Print("%s: %s", A.RealmKey(), data and ("%d gear listings, scanned %s"):format(data.count or 0, ago(data.t)) or "no scan yet")
        local links, t, from = A.BankLinks()
        if from == "ahu" then
            A.Print("bank: %d gear items, recorded %s", #links, ago(t))
        elseif from == "bagnon" then
            A.Print("bank: %d gear items from Bagnon's cache (visit the bank to record it here)", #links)
        else
            A.Print("bank: not seen yet, visit it once so its gear counts")
        end
        return
    end
    local ah = _G.AuctionHouseFrame
    if tab and ah and ah:IsShown() then
        if not panel:IsShown() then
            ShowPanel(true)
        elseif not (ah.SetDisplayMode and _G.AuctionHouseFrameDisplayMode
                and pcall(ah.SetDisplayMode, ah, AuctionHouseFrameDisplayMode.Buy)) then
            ShowPanel(false) -- back to Buy normally; this only if that isn't possible
        end
        return
    end
    if not window then BuildWindow() end
    if not window:IsShown() then StartOnMain() end
    window:SetShown(not window:IsShown())
end
