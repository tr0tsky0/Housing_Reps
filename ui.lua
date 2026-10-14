local addonName, HR = ...
local L = HR.L

HR.expanded = HR.expanded or {} -- per-faction
HR.expansionExpanded = HR.expansionExpanded or {} -- per-expansion

-- Values are the client's expansion index (LE_EXPANSION_*), which both sorts the
-- groups and picks the localized EXPANSION_NAME<n> header. Keep gaps (e.g. 8 is
-- Shadowlands, which has no housing reps) rather than renumbering.
local EXPANSION_ORDER = {
    ["Classic"] = 0,
    ["The Burning Crusade"] = 1,
    ["Wrath of the Lich King"] = 2,
    ["Cataclysm"] = 3,
    ["Mists of Pandaria"] = 4,
    ["Warlords of Draenor"] = 5,
    ["Legion"] = 6,
    ["Battle for Azeroth"] = 7,
    ["Dragonflight"] = 9,
    ["The War Within"] = 10,
    ["Midnight"] = 11
}

local function GetExpansionOrder(exp)
    return EXPANSION_ORDER[exp] or 99 -- unknown/Anniversary/etc go at the end
end

local function GetExpansionDisplayName(exp)
    return HR.GetExpansionName(EXPANSION_ORDER[exp], exp)
end

local function GetVendorName(v)
    return HR.GetNPCName(v.npcID, v.name)
end

local function GetVendorLocation(v)
    local parts = {}
    local zone = HR.GetMapName(v.uiMapID, v.zone)
    if zone then
        table.insert(parts, zone)
    end
    if v.subzone then
        table.insert(parts, v.subzone)
    end
    return parts
end

local function HR_GetVendors(cfg)
    if not cfg or not cfg.vendor then
        return nil
    end

    local vendors = cfg.vendor

    -- If it's a single vendor table, wrap it
    if vendors.npcID or vendors.name then
        vendors = {vendors}
    end

    return vendors
end

local function HR_AddVendorTooltipLines(cfg, reward)
    local vendors = HR_GetVendors(cfg)
    local playerFaction = UnitFactionGroup("player")
    
    if not vendors or #vendors == 0 then
        return
    end

    local function VendorMatchesFaction(v)
        -- If vendor.faction is not set, treat as neutral (always show)
        if not v or not v.faction or v.faction == "" then
            return true
        end
        return playerFaction and v.faction == playerFaction
    end

    local v = nil
    
    -- If this reward specifies a vendor index, and it exists, use that
    if reward and reward.vendor and vendors[reward.vendor] and VendorMatchesFaction(vendors[reward.vendor]) then
        v = vendors[reward.vendor]
    end

    if not v then
        for i = 1, #vendors do
            if VendorMatchesFaction(vendors[i]) then
                v = vendors[i]
                break
            end
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Vendor"], 1, 0.82, 0)

    local vendorName = GetVendorName(v)
    if vendorName then
        GameTooltip:AddLine(vendorName, 0.9, 0.9, 0.9)
    end

    local locParts = GetVendorLocation(v)

    if #locParts > 0 then
        GameTooltip:AddLine(table.concat(locParts, " - "), 0.8, 0.8, 0.8)
    end

    if v.x and v.y then
        GameTooltip:AddLine(string.format("(%.1f, %.1f)", v.x, v.y), 0.7, 0.7, 0.7)
    end

    -- Hint: manual purchase override
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(L["Alt-Click to mark reward as purchased"], 0.8, 0.8, 0.8)
end

local function HR_SetVendorWaypoint(cfg)
    if not cfg or not cfg.vendor then
        print("|cff33ff99Housing Reps|r: " .. L["No vendor data for this faction yet."])
        return
    end

    local vendors = HR_GetVendors(cfg)
    if not vendors or not vendors[1] then
        print("|cff33ff99Housing Reps|r: " .. L["This vendor doesn't have waypoint coords yet."])
        return
    end

    local v = vendors[1] -- default to first vendor (Thalyssra for Nightfallen)

    if not v.uiMapID or not v.x or not v.y then
        print("|cff33ff99Housing Reps|r: " .. L["This vendor doesn't have waypoint coords yet."])
        return
    end

    if not C_Map or not UiMapPoint or not C_Map.SetUserWaypoint then
        print("|cff33ff99Housing Reps|r: " .. L["Waypoints aren't supported on this client."])
        return
    end

    local wx = v.x / 100
    local wy = v.y / 100

    local point = UiMapPoint.CreateFromCoordinates(v.uiMapID, wx, wy)
    C_Map.SetUserWaypoint(point)

    if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then
        C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    end

    local name = GetVendorName(v) or L["vendor"]
    local whereParts = GetVendorLocation(v)

    local whereText = ""
    if #whereParts > 0 then
        whereText = " (" .. table.concat(whereParts, " - ") .. ")"
    end

    print("|cff33ff99Housing Reps|r: " .. string.format(L["Waypoint set to %s%s."], name, whereText))
end

-------------------------------------------------------
-- Main frame
-------------------------------------------------------

local frame = CreateFrame("Frame", "HR_MainFrame", UIParent, "BackdropTemplate")
frame:SetSize(650, 600)
frame:SetPoint("CENTER")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", frame.StartMoving)
frame:SetScript("OnDragStop", frame.StopMovingOrSizing)
frame:Hide()

frame:SetBackdrop({
    bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile = false,
    tileSize = 0,
    edgeSize = 16,
    insets = {
        left = 4,
        right = 4,
        top = 4,
        bottom = 4
    }
})

frame.title = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
frame.title:SetPoint("TOP", 0, -10)
frame.title:SetText(L["Housing Reputations"])

local close = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
close:SetPoint("TOPRIGHT", -5, -5)

-- Checkbox state comes from SavedVariables, which don't exist yet while this file
-- runs. Always go through the live HousingRepsDB table (never a cached local), and
-- let HR.ApplySettingsToUI set the initial ticks once the saved data has loaded.

-- Hide Completed toggle
local hideChk = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
hideChk:SetPoint("TOPLEFT", 10, -30)
hideChk.text:SetText(L["Hide Completed"])
HR.hideCompletedCheck = hideChk

hideChk:SetScript("OnClick", function(self)
    HousingRepsDB.settings.hideCompleted = self:GetChecked() and true or false
    HR.BuildUI()
end)

-- Account-Wide Progress checkbox
local accountChk = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
accountChk:SetPoint("LEFT", hideChk.text, "RIGHT", 20, 0) -- follows the label, whose length varies by locale
accountChk.text:SetText(L["Account-Wide"])
HR.accountWideCheck = accountChk

accountChk:SetScript("OnClick", function(self)
    HousingRepsDB.settings.accountWide = self:GetChecked() and true or false
    ResolveHousingFactions()
    HR.BuildUI()
end)

function HR.ApplySettingsToUI()
    local settings = HousingRepsDB.settings
    hideChk:SetChecked(settings.hideCompleted == true)
    accountChk:SetChecked(settings.accountWide ~= false) -- default ON
end

-------------------------------------------------------
-- Scrollframe
-------------------------------------------------------

local scrollFrame = CreateFrame("ScrollFrame", "HR_ScrollFrame", frame, "UIPanelScrollFrameTemplate")
scrollFrame:SetPoint("TOPLEFT", 20, -65)
scrollFrame:SetPoint("BOTTOMRIGHT", -35, 20)

local scrollChild = CreateFrame("Frame")
scrollChild:SetWidth(580)
scrollFrame:SetScrollChild(scrollChild)

HR.frame = frame
HR.scrollChild = scrollChild

-------------------------------------------------------
-- Widget cleanup
-------------------------------------------------------

local activeWidgets = {}

function HR.ClearWidgets()
    for _, w in ipairs(activeWidgets) do
        w:Hide()
    end
    wipe(activeWidgets)
end

-------------------------------------------------------
-- Header row
-------------------------------------------------------

function HR.CreateHeader(text, y)
    local header = CreateFrame("Frame", nil, HR.scrollChild)
    header:SetSize(580, 28)
    header:SetPoint("TOPLEFT", 0, y)

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.12, 0.12, 0.8)

    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 8, 0)
    fs:SetText(text)

    table.insert(activeWidgets, header)
    return y - 32
end

function HR.CreateExpansionHeader(expKey, text, y)
    local header = CreateFrame("Button", nil, HR.scrollChild)
    header:SetSize(580, 28)
    header:SetPoint("TOPLEFT", 0, y)

    local bg = header:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.12, 0.12, 0.12, 0.9)

    local toggleFS = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    toggleFS:SetPoint("LEFT", 8, 0)

    local expanded = HR.expansionExpanded[expKey]
    if expanded == nil then
        expanded = false
    end -- default: collapsed

    toggleFS:SetText(expanded and "-" or "+")

    local fs = header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetPoint("LEFT", 24, 0)
    fs:SetText(text)

    header:SetScript("OnClick", function()
        local cur = HR.expansionExpanded[expKey]
        if cur == nil then
            cur = true
        end
        HR.expansionExpanded[expKey] = not cur
        HR.BuildUI()
    end)

    table.insert(activeWidgets, header)
    return y - 32
end

-------------------------------------------------------
-- One reputation line
-------------------------------------------------------

function HR.CreateRepLine(factionID, y)
    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]

    -- Try to get standard reputation data; may be nil if the character
    -- hasn't "seen" this faction yet or it's renown/friendship-only.
    local data = (C_Reputation and C_Reputation.GetFactionDataByID) and C_Reputation.GetFactionDataByID(factionID) or
                     nil

    local name = HR.GetFactionName(factionID)
    local standingID = data and data.reaction or 0
    local current = data and data.currentStanding
    local curThresh = data and data.currentReactionThreshold
    local nextThresh = data and data.nextReactionThreshold

    local isComplete = HR.IsRepComplete(factionID)

    local hideCompleted = HR.HideCompleted()
    if HR.hideCompletedCheck then
        hideCompleted = HR.hideCompletedCheck:GetChecked() and true or false
    end

    if hideCompleted and isComplete then
        return y
    end

    local line = CreateFrame("Button", nil, HR.scrollChild)
    line:SetSize(580, 22)
    line:SetPoint("TOPLEFT", 0, y)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    -- +/- indicator
    local toggleFS = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    toggleFS:SetPoint("LEFT", 2, 0)
    toggleFS:SetText("")

    -- Faction icon (Alliance / Horde)
    local icon
    if cfg and cfg.faction and (cfg.faction == "Alliance" or cfg.faction == "Horde") then
        icon = line:CreateTexture(nil, "OVERLAY")
        icon:SetSize(14, 14)
        icon:SetPoint("LEFT", toggleFS, "RIGHT", 2, 0)

        if cfg.faction == "Alliance" then
            icon:SetTexture("Interface\\FriendsFrame\\PlusManz-Alliance")
        else
            icon:SetTexture("Interface\\FriendsFrame\\PlusManz-Horde")
        end
    end

    local text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    if icon then
        text:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    else
        text:SetPoint("LEFT", 18, 0)
    end
    text:SetText(name)

    ----------------------------------------------------------------
    -- Standing / progress text: standard vs renown vs friendship
    ----------------------------------------------------------------
    local standingName = UNKNOWN or L["Unknown"]
    local progress = ""

    if cfg and cfg.kind == "renown" then
        local mf = C_MajorFactions and C_MajorFactions.GetMajorFactionData and
                       C_MajorFactions.GetMajorFactionData(factionID)
        standingName = HR.GetRenownLabel(mf and mf.renownLevel)

    elseif cfg and cfg.kind == "friendship" then
        local info = C_GossipInfo and C_GossipInfo.GetFriendshipReputation and
                         C_GossipInfo.GetFriendshipReputation(factionID)
        standingName = (info and (info.reaction or info.friendshipText)) or L["Friend"]

    else
        -- Standard reputation factions (or unknown standard, which will fall back to "Unknown")
        standingName = HR.GetStandingLabel(standingID)

        if data and current and curThresh and nextThresh and nextThresh > curThresh then
            local cur = current - curThresh
            local total = nextThresh - curThresh
            progress = string.format(" (%d/%d)", cur, total)
        end
    end

    -- standingName / progress currently describe THIS character

    -- These are what we actually show in the right-hand column
    local displayStandingName = standingName
    local displayProgress = progress

    if HR.UseAccountWide and HR.UseAccountWide() then
        local best = HR.GetBestDisplayInfo(factionID)
        if best then
            displayStandingName = best.standingName
            displayProgress = best.progressText or ""
        end
    end

    local fs = line:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    fs:SetPoint("RIGHT", -10, 0)
    fs:SetText(displayStandingName .. displayProgress)

    ----------------------------------------------------------------
    -- Colour & highlight (grey out opposing faction)
    ----------------------------------------------------------------
    local playerFaction = UnitFactionGroup("player") -- "Alliance" / "Horde" / "Neutral"
    local isOpposite = false
    if cfg and cfg.faction and playerFaction then
        if (cfg.faction == "Alliance" and playerFaction == "Horde") or
            (cfg.faction == "Horde" and playerFaction == "Alliance") then
            isOpposite = true
        end
    end

    if isOpposite then
        text:SetTextColor(0.5, 0.5, 0.5)
    elseif isComplete then
        text:SetTextColor(0.3, 1.0, 0.3) -- green for complete
    else
        text:SetTextColor(0.9, 0.9, 0.9)
    end

    line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight")

    -- +/- indicator based on expansion state
    if cfg and cfg.rewards and #cfg.rewards > 0 then
        toggleFS:SetText(HR.expanded[factionID] and "-" or "+")
    else
        toggleFS:SetText("")
    end

    ----------------------------------------------------------------
    -- Click to expand/collapse rewards (if any)
    ----------------------------------------------------------------
    line:SetScript("OnClick", function(_, button)
        if button == "RightButton" then
            -- Right-click: set waypoint to vendor (if we have data)
            HR_SetVendorWaypoint(cfg)
            return
        end

        -- Left-click: expand/collapse rewards (existing behaviour)
        if button == "LeftButton" then
            if cfg and cfg.rewards and #cfg.rewards > 0 then
                HR.expanded[factionID] = not HR.expanded[factionID]
                HR.BuildUI()
            end
        end
    end)

    line:SetScript("OnEnter", function()
        GameTooltip:SetOwner(line, "ANCHOR_RIGHT")
        GameTooltip:AddLine(name, 1, 1, 1)

        -- Pull account-best info
        local best = HR.GetBestDisplayInfo(factionID)

        if best then
            --
            -- Show account-best standing
            --
            local text = best.standingName .. (best.progressText or "")
            GameTooltip:AddLine(text, 0.8, 0.8, 0.8)

            --
            -- Current character’s standing (optional but helpful)
            --
            if standingName and progress then
                local mine = standingName .. progress
                GameTooltip:AddLine(L["This character: "] .. mine, 0.6, 0.6, 0.6)
            end

            --
            -- Which character is best?
            --
            local myKey = UnitName("player") .. "-" .. GetRealmName()
            if best.sourceChar ~= myKey then
                GameTooltip:AddLine(L["Best reputation on: "] .. best.sourceChar, 0.6, 0.9, 1)
            end
        else
            -- No best data yet: fallback to your normal behaviour
            GameTooltip:AddLine(standingName .. progress, 0.8, 0.8, 0.8)
        end

        GameTooltip:Show()
    end)

    line:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    table.insert(activeWidgets, line)
    return y - 24
end

function HR.CreateRewardLine(factionID, reward, y)
    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
    if not cfg or not reward then
        return y
    end

    local unlocked = HR.IsRewardUnlocked(factionID, reward)
    -- Try to query decor ownership if this reward has an item
    local collected
    local itemID = reward.itemID

    if itemID and itemID > 0 and HR.IsDecorCollectedForItem then
        collected = HR.IsDecorCollectedForItem(itemID)
        -- collected is true / false / nil
    end

    local hideCompleted = HR.HideCompleted()
    if HR.hideCompletedCheck then
        hideCompleted = HR.hideCompletedCheck:GetChecked() and true or false
    end

    if hideCompleted and collected then
        return y
    end

    -- Button for the reward line
    local frame = CreateFrame("Button", nil, HR.scrollChild)
    frame:SetSize(560, 18)
    frame:SetPoint("TOPLEFT", 20, y) -- indented under the faction line
    frame:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    ----------------------------------------------------------------
    -- Item text / link
    ----------------------------------------------------------------
    local itemName, itemLink = HR.GetItemNameAndLink(itemID)

    local displayText = itemLink or itemName or reward.itemName or L["Unknown item"]

    -- stash item info on the frame so clicks can use it
    frame.itemID = itemID

    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    text:SetPoint("LEFT", 10, 0)
    text:SetText("- " .. displayText)

    ----------------------------------------------------------------
    -- Status text (Unlocked / current vs required)
    ----------------------------------------------------------------
    local status = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    status:SetPoint("RIGHT", -10, 0)

    if unlocked then
        if collected == true then
            -- Either the API sees copies right now, or we've seen it once and cached it
            status:SetText(L["Purchased"])
            status:SetTextColor(0.3, 1.0, 0.3) -- green
        else
            -- Either:
            --  - API says sum == 0 (could be never bought, OR fully placed and bugged), or
            --  - API is unavailable / returned something weird (collected == nil)
            -- From the user's POV, it's just "you can buy this, but we can't confirm ownership".
            status:SetText(L["Available (*)"])
            status:SetTextColor(1.0, 0.9, 0.3) -- yellow
        end
    else
        local currentLabel, neededLabel = HR.GetRewardProgress(factionID, reward)
        status:SetText(string.format("%s / %s", currentLabel or "?", neededLabel or "?"))
        status:SetTextColor(1.0, 0.3, 0.3) -- red
    end

    ----------------------------------------------------------------
    -- Tooltip for the reward item
    ----------------------------------------------------------------
    if itemID and itemID > 0 then
        frame:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetItemByID(self.itemID)

            -- Append vendor info specific to this reward
            HR_AddVendorTooltipLines(cfg, reward)

            GameTooltip:Show()
        end)

        frame:SetScript("OnLeave", function()
            GameTooltip:Hide()
        end)

        ----------------------------------------------------------------
        -- Modified clicks: shift-click to chat, ctrl-click to dress-up, alt-click to mark as purchased
        ----------------------------------------------------------------
        frame:SetScript("OnClick", function(self, button)
            if not self.itemID or self.itemID <= 0 then
                return
            end

            -- Alt + Left-click: manually mark this decor as purchased
            if button == "LeftButton" and IsAltKeyDown() then
                if HR.MarkDecorAsPurchased then
                    HR.MarkDecorAsPurchased(self.itemID)
                else
                    -- Failsafe if something weird happens with loading order
                    HousingRepsDB = HousingRepsDB or {}
                    HousingRepsDB.purchasedItems = HousingRepsDB.purchasedItems or {}
                    HousingRepsDB.purchasedItems[self.itemID] = true
                end

                local _, link = HR.GetItemNameAndLink(self.itemID)
                link = link or ("item:" .. self.itemID)

                print("|cff33ff99Housing Reps|r: " .. string.format(L["Marked %s as purchased."], link))

                -- Rebuild so the line flips from "Available (*)" to "Purchased"
                if HR.BuildUI then
                    HR.BuildUI()
                end
                return
            end

            -- Otherwise, fall back to normal modified-click handling
            if not IsModifiedClick() then
                return
            end

            local _, link = HR.GetItemNameAndLink(self.itemID)
            link = link or ("item:" .. self.itemID)

            if link then
                HandleModifiedItemClick(link)
            end
        end)
    end

    table.insert(activeWidgets, frame)
    return y - 18
end

-------------------------------------------------------
-- Build UI
-------------------------------------------------------

function HR.BuildUI()
    HR.ClearWidgets()
    local y = 0

    local list = HR.resolved or {}

    ----------------------------------------------------------------
    -- Settings / mode flags
    local useAccount = HR.UseAccountWide()
    local hideCompleted = HR.HideCompleted()
    local playerFaction = UnitFactionGroup("player")

    -- If the checkboxes exist, their visual state wins at runtime
    if HR.accountWideCheck then
        useAccount = HR.accountWideCheck:GetChecked() and true or false
    end

    if HR.hideCompletedCheck then
        hideCompleted = HR.hideCompletedCheck:GetChecked() and true or false
    end

    ----------------------------------------------------------------
    -- Collect and sort factions
    ----------------------------------------------------------------
    local ordered = {}
    for factionID in pairs(list) do
        table.insert(ordered, factionID)
    end

    table.sort(ordered, function(a, b)
        local cfgA = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[a]
        local cfgB = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[b]

        local expA = cfgA and cfgA.expansion or "Unknown"
        local expB = cfgB and cfgB.expansion or "Unknown"

        local orderA = GetExpansionOrder(expA)
        local orderB = GetExpansionOrder(expB)

        if orderA ~= orderB then
            return orderA < orderB
        end

        -- Same expansion: sort alphabetically by (localized) name
        return HR.GetFactionName(a) < HR.GetFactionName(b)
    end)

    ----------------------------------------------------------------
    -- Expansion completion stats (respecting current view:
    -- account-wide vs current character + faction filtering)
    ----------------------------------------------------------------
    local expStats = {}

    for _, factionID in ipairs(ordered) do
        local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
        if cfg then
            -- When account-wide is OFF, ignore opposite-faction reps
            local sameFaction = (not cfg.faction) or (cfg.faction == playerFaction)
            if useAccount or sameFaction then
                local exp = cfg.expansion or "Unknown"
                local stats = expStats[exp] or {
                    done = 0,
                    total = 0
                }

                if cfg.rewards and #cfg.rewards > 0 then
                    for _, reward in ipairs(cfg.rewards) do
                        stats.total = stats.total + 1

                        local completed = false
                        local itemID = reward.itemID

                        if itemID and itemID > 0 and HR.IsDecorCollectedForItem then
                            local collected = HR.IsDecorCollectedForItem(itemID)
                            completed = (collected == true)
                        else
                            completed = HR.IsRewardUnlocked(factionID, reward)
                        end

                        if completed then
                            stats.done = stats.done + 1
                        end
                    end
                end

                expStats[exp] = stats
            end
        end
    end

    ----------------------------------------------------------------
    -- Hide whole expansions when:
    --  - Hide Completed is ON, AND
    --  - Every *visible* reward in that expansion is unlocked
    ----------------------------------------------------------------
    local expansionsToHide = {}
    if hideCompleted then
        for exp, stats in pairs(expStats) do
            if stats.total > 0 and stats.done == stats.total then
                expansionsToHide[exp] = true
            end
        end
    end

    ----------------------------------------------------------------
    -- Render expansion headers + faction rows
    ----------------------------------------------------------------
    local currentExpansion = nil

    for _, factionID in ipairs(ordered) do
        local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
        if cfg then
            local exp = cfg.expansion or "Unknown"

            -- 1) Faction filtering:
            --    - Account-wide ON  -> show all factions
            --    - Account-wide OFF -> hide opposite-faction reps
            local sameFaction = (not cfg.faction) or (cfg.faction == playerFaction)

            if useAccount or sameFaction then

                -- 2) Skip fully-complete expansions when requested
                if not expansionsToHide[exp] then

                    -- New expansion header?
                    if exp ~= currentExpansion then
                        local stats = expStats[exp] or {
                            done = 0,
                            total = 0
                        }
                        local headerText = GetExpansionDisplayName(exp)

                        if stats.total > 0 then
                            headerText = string.format("%s (%d/%d)", headerText, stats.done, stats.total)
                        end

                        y = HR.CreateExpansionHeader(exp, headerText, y)
                        currentExpansion = exp
                    end

                    -- Respect expansion collapse state
                    local expanded = HR.expansionExpanded[exp]
                    if expanded == nil then
                        expanded = false -- default collapsed
                    end

                    if expanded then
                        local oldY = y
                        y = HR.CreateRepLine(factionID, y)

                        -- If a line was actually created (e.g. not hidden by Hide Completed),
                        -- and it has rewards, draw them when that faction is expanded
                        if y ~= oldY and cfg.rewards and #cfg.rewards > 0 and HR.expanded[factionID] then
                            for _, reward in ipairs(cfg.rewards) do
                                y = HR.CreateRewardLine(factionID, reward, y)
                            end
                            y = y - 4 -- gap after reward block
                        end
                    end
                end
            end
        end
    end

    HR.scrollChild:SetHeight(math.abs(y) + 20)
end
