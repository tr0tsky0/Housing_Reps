local addonName, HR = ...

HousingRepsDB = HousingRepsDB or {}

local function HR_EnsureSettings()
    HousingRepsDB = HousingRepsDB or {}

    local settings = HousingRepsDB.settings
    if not settings then
        settings = {
            accountWide = true,
            hideCompleted = false
        }
        HousingRepsDB.settings = settings
    end

    -- Minimap button settings (persistent)
    settings.minimap = settings.minimap or {}
    if settings.minimap.enabled == nil then
        settings.minimap.enabled = true
    end
    if type(settings.minimap.angle) ~= "number" then
        settings.minimap.angle = 220 -- consistent default
    end

    HousingRepsDB.purchasedItems = HousingRepsDB.purchasedItems or {}
end

-- Run once on load to make sure settings exists for this session
HR_EnsureSettings()

-- Shape:
-- HousingRepsDB = {
--   chars = {
--     ["Name-Realm"] = {
--       faction = "Alliance" / "Horde" / "Neutral",
--       lastSeen = 1234567890,
--       reps = {
--         [factionID] = {
--           kind = "standard" | "renown" | "friendship",
--           -- standard:
--           reaction = number,
--           current = number,
--           currentThreshold = number,
--           nextThreshold = number,
--           -- renown:
--           renownLevel = number,
--           -- friendship:
--           standing = number,
--         },
--       },
--     },
--   },
-- }

local REACTION_FROM_NAME = {
    Neutral = 4,
    Friendly = 5,
    Honored = 6,
    Revered = 7,
    Exalted = 8
}

local FRIENDSHIP_LEVEL_FROM_NAME = {
    -- Standard (Tillers-style)
    Stranger = 1,
    Acquaintance = 2,
    Buddy = 3,
    Friend = 4,
    ["Good Friend"] = 5,
    ["Best Friend"] = 6,
    -- Silvermoon Court sub-factions (Midnight)
    Interloper = 1,
    Guest = 2,
    Socialite = 3,
    Trendsetter = 4,
    Host = 5,
    Luminary = 6,
}

local function GetFriendshipTierFromLabel(label)
    if type(label) ~= "string" then
        return 0
    end

    -- Support Brawler-style ranks ("Rank 3")
    local rank = label:match("[Rr]ank%s*(%d+)")
    if rank then
        return tonumber(rank) or 0
    end

    return FRIENDSHIP_LEVEL_FROM_NAME[label] or 0
end

function HR.UseAccountWide()
    -- If the UI is loaded, trust the checkbox first
    if HR.accountWideCheck then
        return HR.accountWideCheck:GetChecked() and true or false
    end

    -- Fallback to SavedVariables (e.g. before the frame is created)
    local settings = HousingRepsDB and HousingRepsDB.settings
    if settings and settings.accountWide ~= nil then
        return settings.accountWide
    end

    return true -- default: ON
end

function HR.HideCompleted()
    -- If the UI is loaded, trust the checkbox first
    if HR.hideCompletedCheck then
        return HR.hideCompletedCheck:GetChecked() and true or false
    end

    -- Fallback to SavedVariables
    local settings = HousingRepsDB and HousingRepsDB.settings
    return settings and settings.hideCompleted == true
end

local function HR_GetCharKey()
    local name, realm = UnitName("player"), GetRealmName()
    return string.format("%s-%s", name or "Unknown", realm or "Unknown")
end

local function HR_SnapshotRepsForCurrentChar()
    if not HOUSING_REP_CONFIG then
        return
    end

    HousingRepsDB.chars = HousingRepsDB.chars or {}

    local key = HR_GetCharKey()
    local entry = HousingRepsDB.chars[key] or {}
    entry.faction = UnitFactionGroup("player")
    entry.lastSeen = time()
    entry.reps = entry.reps or {}

    for factionID, cfg in pairs(HOUSING_REP_CONFIG) do
        local rec = entry.reps[factionID] or {
            kind = cfg.kind
        }

        if cfg.kind == "renown" then
            if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
                local data = C_MajorFactions.GetMajorFactionData(factionID)
                if data then
                    rec.renownLevel = data.renownLevel or 0
                end
            end

        elseif cfg.kind == "friendship" then
            if C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
                local info = C_GossipInfo.GetFriendshipReputation(factionID)
                if info then
                    rec.standing = info.standing or info.friendshipReaction or 0
                    rec.reactionText = info.reaction or info.friendshipText

                    -- Locale-proof: use numeric tier when available
                    rec.friendshipTier = 0
                    if info.friendshipFactionID and C_GossipInfo.GetFriendshipReputationRanks then
                        local ranks = C_GossipInfo.GetFriendshipReputationRanks(info.friendshipFactionID)
                        rec.friendshipTier = (ranks and ranks.currentLevel) or 0
                    end

                    -- Fallback: English label map (better than nothing)
                    if rec.friendshipTier == 0 then
                        rec.friendshipTier = GetFriendshipTierFromLabel(rec.reactionText)
                    end
                end
            end

        else
            if C_Reputation and C_Reputation.GetFactionDataByID then
                local data = C_Reputation.GetFactionDataByID(factionID)
                if data then
                    rec.reaction = data.reaction or 0
                    rec.current = data.currentStanding or 0
                    rec.currentThreshold = data.currentReactionThreshold or 0
                    rec.nextThreshold = data.nextReactionThreshold or 0
                end
            end
        end

        entry.reps[factionID] = rec
    end

    HousingRepsDB.chars[key] = entry
end

local function HR_CompareRepRecords(cfg, a, b)
    if not a then
        return false
    end
    if not b then
        return true
    end

    if cfg.kind == "renown" then
        return (a.renownLevel or 0) > (b.renownLevel or 0)

    elseif cfg.kind == "friendship" then
        local ta, tb = a.friendshipTier or 0, b.friendshipTier or 0
        if ta ~= tb then
            return ta > tb
        end
        return (a.standing or 0) > (b.standing or 0)

    else
        -- Standard: compare reaction first, then current within that standing.
        local ra, rb = a.reaction or 0, b.reaction or 0
        if ra ~= rb then
            return ra > rb
        end
        return (a.current or 0) > (b.current or 0)
    end
end

function HR.GetBestRepRecord(factionID)
    if not HousingRepsDB or not HousingRepsDB.chars then
        return nil, nil
    end

    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
    if not cfg then
        return nil, nil
    end

    local bestRec, bestCharKey

    for charKey, data in pairs(HousingRepsDB.chars) do
        local rec = data.reps and data.reps[factionID]
        if rec and HR_CompareRepRecords(cfg, rec, bestRec) then
            bestRec = rec
            bestCharKey = charKey
        end
    end

    return bestRec, bestCharKey
end

function HR.GetBestDisplayInfo(factionID)
    local cfg = HOUSING_REP_CONFIG[factionID]
    if not cfg then
        return nil
    end

    local bestRec, bestCharKey = HR.GetBestRepRecord(factionID)
    if not bestRec then
        return nil
    end

    local display = {}

    if cfg.kind == "renown" then
        display.standingName = "Renown " .. (bestRec.renownLevel or 0)
        display.progressText = "" -- renown doesn't need fractional progress

    elseif cfg.kind == "friendship" then
        -- Prefer the saved reaction text like “Best Friend”
        local name = bestRec.reactionText
        if not name then
            -- Fallback for old DB entries that only have the raw number
            local standing = bestRec.standing or 0
            name = "Standing " .. standing
        end

        display.standingName = name
        display.progressText = ""

    else
        -- Standard faction
        local reaction = bestRec.reaction or 0
        local name = _G["FACTION_STANDING_LABEL" .. reaction] or ("Standing " .. reaction)

        local cur = bestRec.current or 0
        local cThr = bestRec.currentThreshold or 0
        local nThr = bestRec.nextThreshold or 0

        if nThr > cThr then
            display.progressText = string.format(" (%d/%d)", cur - cThr, nThr - cThr)
        else
            display.progressText = ""
        end

        display.standingName = name
    end

    display.sourceChar = bestCharKey
    return display
end

local housingCatalogPrimed = false

local function HR_PrimeHousingCatalog()
    if housingCatalogPrimed or not C_HousingCatalog then
        return
    end

    if C_HousingCatalog.CreateCatalogSearcher then
        -- pcall just in case Blizzard decides to be dramatic
        pcall(C_HousingCatalog.CreateCatalogSearcher)
    end

    housingCatalogPrimed = true
end

-- Returns:
--   true, sum   -> decor is (or has been) in the catalogue
--   false, sum  -> API knows the decor and reports 0 copies
--   nil,  nil   -> API not available / error
function HR.IsDecorCollectedForItem(itemID)
    if not itemID or itemID <= 0 then
        return nil, nil
    end

    HR_EnsureSettings()
    HousingRepsDB.purchasedItems = HousingRepsDB.purchasedItems or {}
    local purchasedItems = HousingRepsDB.purchasedItems

    -- 1) If we've ever marked this item as purchased, trust that and skip the API
    if purchasedItems[itemID] then
        return true, nil
    end

    -- 2) Otherwise, query the housing catalogue
    if not C_HousingCatalog or not C_HousingCatalog.GetCatalogEntryInfoByItem then
        return nil, nil
    end

    HR_PrimeHousingCatalog()

    local ok, info = pcall(C_HousingCatalog.GetCatalogEntryInfoByItem, itemID, true)
    if not ok or not info then
        return nil, nil
    end

    local quantity = tonumber(info.quantity) or 0
    local redeemable = tonumber(info.remainingRedeemable) or 0
    local placed = tonumber(info.numPlaced) or 0
    local sum = quantity + redeemable + placed

    -- Guard against any nonsense values (including old overflow weirdness)
    if sum > 0 and sum < 1000000 then
        -- Mark permanently purchased for this account
        purchasedItems[itemID] = true
        return true, sum
    elseif sum == 0 then
        -- API found an entry, but reports no owned copies (or none tracked)
        return false, 0
    end

    return nil, nil
end

function HR.MarkDecorAsPurchased(itemID)
    if not itemID or itemID <= 0 then
        return
    end

    HR_EnsureSettings()
    HousingRepsDB.purchasedItems = HousingRepsDB.purchasedItems or {}
    HousingRepsDB.purchasedItems[itemID] = true
end

-------------------------------------------------------
-- Resolved factions (factionID => true if this toon has data)
-------------------------------------------------------
HR.resolved = {}

function ResolveHousingFactions()
    HR.resolved = HR.resolved or {}

    -- Clear old state
    for k in pairs(HR.resolved) do
        HR.resolved[k] = nil
    end

    local accountWide = HR.UseAccountWide()
    local playerFaction = UnitFactionGroup("player")

    for factionID, cfg in pairs(HOUSING_REP_CONFIG) do
        local include = true

        if not accountWide then
            -- Per-character view: hide opposite-faction reps
            if cfg.faction and cfg.faction ~= playerFaction then
                include = false
            end
        end

        if include then
            HR.resolved[factionID] = true
        end
    end
end

-------------------------------------------------------
-- Reward unlock logic
-------------------------------------------------------

local function parseFriendshipRequired(reward)
    if not reward then
        return nil
    end

    -- Best option: numeric in data.lua (localisation-proof)
    if type(reward.requiredFriendshipLevel) == "number" then
        return reward.requiredFriendshipLevel
    end

    local rs = reward.requiredStanding
    if type(rs) == "string" then
        -- Support Brawler-style ranks ("Rank 5")
        local rank = rs:match("[Rr]ank%s*(%d+)")
        if rank then
            return tonumber(rank)
        end

        -- Tillers-style labels
        local tier = FRIENDSHIP_LEVEL_FROM_NAME[rs]
        if tier then
            return tier
        end
    end

    return nil
end

local function parseRenownRequired(requiredStanding)
    if not requiredStanding then
        return nil
    end
    local num = requiredStanding:match("Renown%s+(%d+)")
    return num and tonumber(num) or nil
end

function HR.CompareRepToRequirement(cfg, reward, state)
    if not cfg or not reward or not state then
        return false
    end

    local requiredStanding = reward.requiredStanding

    -- Renown-style requirements, e.g. "Renown 8"
    if cfg.kind == "renown" or (requiredStanding and requiredStanding:match("^Renown")) then
        local requiredRenown = parseRenownRequired(requiredStanding) or 0
        return (state.renown or 0) >= requiredRenown
    end

    -- Friendship-style: compare friendship tier level
    if cfg.kind == "friendship" then
        local requiredTier = parseFriendshipRequired(reward) or 1
        return (state.friendshipTier or 0) >= requiredTier
    end

    -- Standard faction reputation: compare reaction tier (Friendly, Honored, etc.)
    local requiredReaction = 8 -- default Exalted
    if requiredStanding and REACTION_FROM_NAME[requiredStanding] then
        requiredReaction = REACTION_FROM_NAME[requiredStanding]
    end

    return (state.reaction or 0) >= requiredReaction
end

-- Returns true if a single reward is unlocked
function HR.IsRewardUnlockedCurrentChar(factionID, reward)
    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
    if not cfg or not reward then
        return false
    end

    local requiredStanding = reward.requiredStanding

    -- Renown-style (Valdrakken, Flame's Radiance)
    if cfg.kind == "renown" or (requiredStanding and requiredStanding:match("^Renown")) then
        local requiredRenown = parseRenownRequired(requiredStanding) or 0
        if requiredRenown <= 0 then
            return false
        end

        if not C_MajorFactions or not C_MajorFactions.GetMajorFactionData then
            return false
        end

        local data = C_MajorFactions.GetMajorFactionData(factionID)
        if not data or not data.renownLevel then
            return false
        end

        return data.renownLevel >= requiredRenown
    end

    -- Friendship-style (Tillers farmers)
    if cfg.kind == "friendship" then
        if not C_GossipInfo or not C_GossipInfo.GetFriendshipReputation then
            return false
        end

        local info = C_GossipInfo.GetFriendshipReputation(factionID)
        if not info then
            return false
        end

        -- Friendship has its own tiers
        local requiredTier = parseFriendshipRequired(reward) or 1

        -- Prefer numeric tier (locale-proof)
        local tier = 0
        if info.friendshipFactionID and C_GossipInfo.GetFriendshipReputationRanks then
            local ranks = C_GossipInfo.GetFriendshipReputationRanks(info.friendshipFactionID)
            tier = (ranks and ranks.currentLevel) or 0
        end

        -- Fallback: label map (English-only)
        if tier == 0 then
            tier = GetFriendshipTierFromLabel(info.reaction or info.friendshipText or info.text)
        end

        return tier >= requiredTier
    end

    -- Standard faction reputation
    if not C_Reputation or not C_Reputation.GetFactionDataByID then
        return false
    end

    local data = C_Reputation.GetFactionDataByID(factionID)
    if not data then
        return false
    end

    local reaction = data.reaction or 0
    local requiredReaction = 8 -- default to Exalted

    if requiredStanding and REACTION_FROM_NAME[requiredStanding] then
        requiredReaction = REACTION_FROM_NAME[requiredStanding]
    end

    return reaction >= requiredReaction
end

function HR.IsRewardUnlocked(factionID, reward)
    local cfg = HOUSING_REP_CONFIG[factionID]
    if not cfg then
        return false
    end

    local useAccount = HR.UseAccountWide()

    local standingName, current, currentThreshold, nextThreshold
    local reaction, renown, friendship, friendshipTier

    if useAccount then
        -- Use account-wide best
        local bestRec = select(1, HR.GetBestRepRecord(factionID))
        if not bestRec then
            return false
        end

        if cfg.kind == "renown" then
            renown = bestRec.renownLevel or 0

        elseif cfg.kind == "friendship" then
            friendship = bestRec.standing or 0
            friendshipTier = bestRec.friendshipTier or 0

        else
            reaction = bestRec.reaction or 0
            current = bestRec.current or 0
            currentThreshold = bestRec.currentThreshold or 0
            nextThreshold = bestRec.nextThreshold or 0
        end
    else
        -- Use current character
        return HR.IsRewardUnlockedCurrentChar(factionID, reward)
    end

    -- Check if this best rep meets the requirement
    return HR.CompareRepToRequirement(cfg, reward, {
        renown = renown,
        friendship = friendship,
        friendshipTier = friendshipTier,
        reaction = reaction,
        current = current,
        currentThreshold = currentThreshold,
        nextThreshold = nextThreshold
    })
end

-- Returns two strings: currentLabel, requiredLabel
function HR.GetRewardProgress(factionID, reward)
    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
    if not cfg or not reward then
        return nil, reward and reward.requiredStanding
    end

    local requiredStanding = reward.requiredStanding

    -- Renown-style
    if cfg.kind == "renown" or (requiredStanding and requiredStanding:match("^Renown")) then
        local requiredRenown = parseRenownRequired(requiredStanding) or 0

        local current = "Renown 0"
        if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
            local data = C_MajorFactions.GetMajorFactionData(factionID)
            if data and data.renownLevel then
                current = string.format("Renown %d", data.renownLevel)
            end
        end

        local needed = requiredRenown > 0 and string.format("Renown %d", requiredRenown) or
                           (requiredStanding or "Renown ?")
        return current, needed
    end

    -- Friendship-style (Tillers etc.)
    if cfg.kind == "friendship" then
        local current = "Unknown"
        if C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
            local info = C_GossipInfo.GetFriendshipReputation(factionID)
            if info then
                -- Blizzard usually provides 'reaction' as a string like "Good Friend"
                current = info.reaction or info.friendshipText or current
            end
        end

        local needed = requiredStanding or "Best Friend"
        return current, needed
    end

    -- Standard reputation
    local current = "Unknown"
    if C_Reputation and C_Reputation.GetFactionDataByID then
        local data = C_Reputation.GetFactionDataByID(factionID)
        if data and data.reaction then
            current = _G["FACTION_STANDING_LABEL" .. data.reaction] or current
        end
    end

    local needed = requiredStanding or "Exalted"
    return current, needed
end

-------------------------------------------------------
-- Faction completion logic
-- A faction is "complete" if all its listed rewards are unlocked.
-------------------------------------------------------

function HR.IsRepComplete(factionID)
    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]
    if not cfg or not cfg.rewards or #cfg.rewards == 0 then
        return false
    end

    for _, reward in ipairs(cfg.rewards) do
        local itemID = reward.itemID

        if itemID and itemID > 0 and HR.IsDecorCollectedForItem then
            local collected = HR.IsDecorCollectedForItem(itemID)
            if collected ~= true then
                -- Rep might be high enough, but decor isn’t in the library yet.
                return false
            end
        else
            -- Non-decor / no housing API: fall back to traditional “unlocked”.
            if not HR.IsRewardUnlocked(factionID, reward) then
                return false
            end
        end
    end

    return true
end
-------------------------------------------------------
-- Events
-------------------------------------------------------
-------------------------------------------------------
-- Main frame toggle helper
-------------------------------------------------------

local function HR_ToggleMainFrame()
    if not HR.frame then
        return
    end

    if HR.frame:IsShown() then
        HR.frame:Hide()
    else
        -- Freshen data when opening the window
        HR_SnapshotRepsForCurrentChar()
        ResolveHousingFactions()
        if HR.BuildUI then
            HR.BuildUI()
        end
        HR.frame:Show()
    end
end

-------------------------------------------------------
-- Minimap button
-------------------------------------------------------
local HR_UpdateMinimapButtonPosition
local HR_CreateMinimapButton

HR_UpdateMinimapButtonPosition = function()
    if not HR.minimapButton or not Minimap then
        return
    end

    HR_EnsureSettings()
    local minimap = HousingRepsDB.settings.minimap
    local angle = minimap.angle or 220

    local w = Minimap:GetWidth() or 140
    local radius = (w / 2) + 6

    local x = math.cos(math.rad(angle)) * radius
    local y = math.sin(math.rad(angle)) * radius

    HR.minimapButton:ClearAllPoints()
    HR.minimapButton:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

local function HR_SetMinimapButtonEnabled(enabled)
    HR_EnsureSettings()
    HousingRepsDB.settings.minimap.enabled = enabled and true or false

    if not HR.minimapButton then
        HR_CreateMinimapButton()
    end
    if HR.minimapButton then
        if HousingRepsDB.settings.minimap.enabled then
            HR.minimapButton:Show()
            HR_UpdateMinimapButtonPosition()
        else
            HR.minimapButton:Hide()
        end
    end
end

HR_CreateMinimapButton = function()
    if HR.minimapButton or not Minimap then
        return
    end

    HR_EnsureSettings()
    local minimap = HousingRepsDB.settings.minimap

    local button = CreateFrame("Button", "HousingRepsMinimapButton", Minimap)
    HR.minimapButton = button

    button:SetSize(32, 32)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(Minimap:GetFrameLevel() + 5)

    button:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")

    local icon = button:CreateTexture(nil, "BACKGROUND")
    icon:SetTexture("Interface\\AddOns\\HousingReps\\Assets\\minimap-icon.png")
    icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    icon:SetSize(20, 20)
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetDrawLayer("OVERLAY", 1)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetSize(54, 54)
    border:SetPoint("CENTER", button, "CENTER", 10, -10)

    button:SetScript("OnClick", function(self, buttonName)
        if buttonName == "LeftButton" then
            HR_ToggleMainFrame()
        end
    end)

    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOPLEFT")
        GameTooltip:AddLine("Housing Reps", 1, 0.82, 0)
        GameTooltip:AddLine("Left-click to toggle window", 1, 1, 1)
        GameTooltip:Show()
    end)

    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    -- Drag + persist angle (normalised)
    button:RegisterForDrag("LeftButton")
    button:SetScript("OnDragStart", function(self)
        HR_EnsureSettings()
        self:SetScript("OnUpdate", function(self)
            GameTooltip:Hide()

            local minimap = HousingRepsDB.settings.minimap
            local mx, my = Minimap:GetCenter()
            local cx, cy = GetCursorPosition()
            local scale = UIParent:GetEffectiveScale()
            cx, cy = cx / scale, cy / scale

            local angle = math.deg(math.atan2(cy - my, cx - mx))
            if angle < 0 then
                angle = angle + 360
            end

            minimap.angle = angle
            HR_UpdateMinimapButtonPosition()
        end)
    end)

    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
    end)

    HR_UpdateMinimapButtonPosition()

    -- Apply enabled setting immediately
    if minimap.enabled == false then
        button:Hide()
    end
end

local f = CreateFrame("Frame")
f:RegisterEvent("PLAYER_LOGIN")
f:RegisterEvent("PLAYER_ENTERING_WORLD")
f:RegisterEvent("PLAYER_LOGOUT")

f:SetScript("OnEvent", function(self, event)
    if event == "PLAYER_LOGIN" or event == "PLAYER_ENTERING_WORLD" then
        HR_EnsureSettings()
        HR_SnapshotRepsForCurrentChar()

        if HousingRepsDB.settings.minimap.enabled ~= false then
            HR_CreateMinimapButton()
        end

    elseif event == "PLAYER_LOGOUT" then
        -- One last snapshot so account-wide view is up to date next time
        HR_SnapshotRepsForCurrentChar()
    end
end)

-------------------------------------------------------
-- Slash commands
-------------------------------------------------------

SLASH_HOUSINGREPS1 = "/housingreps"
SLASH_HOUSINGREPS2 = "/hreps"

local function HR_SlashHandler(msg)
    msg = (msg or ""):lower():match("^%s*(.-)%s*$")

    if msg == "minimap" or msg == "mm" then
        HR_EnsureSettings()
        local cur = HousingRepsDB.settings.minimap.enabled ~= false
        HR_SetMinimapButtonEnabled(not cur)

        print(string.format("|cff33ff99Housing Reps|r: Minimap button %s.", (not cur) and "enabled" or "disabled"))
        return
    end

    -- default behaviour
    HR_ToggleMainFrame()
end

SlashCmdList["HOUSINGREPS"] = HR_SlashHandler
