local addonName, HR = ...

-------------------------------------------------------
-- Addon strings
-- Keys are the English text. Any key without a translation falls back to
-- itself, so enUS needs no table and a partial translation is safe.
-------------------------------------------------------

local L = setmetatable({}, {
    __index = function(_, key)
        return key
    end
})
HR.L = L

local locale = GetLocale()

-- Translations live in Locales/<locale>.lua, which load right after this file.

-------------------------------------------------------
-- Client-provided names
-- Each helper asks the game for the name in the client language and falls
-- back to the English text from data.lua when the API has nothing.
-------------------------------------------------------

local function IsUsableString(s)
    if type(s) ~= "string" or s == "" then
        return false
    end
    if issecretvalue and issecretvalue(s) then
        return false
    end
    return true
end

-- Faction name: standard, friendship and major factions each have their own API,
-- and Encounters (Delves/Prey) only answer to C_MajorFactions.
function HR.GetFactionName(factionID)
    local cfg = HOUSING_REP_CONFIG and HOUSING_REP_CONFIG[factionID]

    if C_Reputation and C_Reputation.GetFactionDataByID then
        local data = C_Reputation.GetFactionDataByID(factionID)
        if data and IsUsableString(data.name) then
            return data.name
        end
    end

    if C_MajorFactions and C_MajorFactions.GetMajorFactionData then
        local data = C_MajorFactions.GetMajorFactionData(factionID)
        if data and IsUsableString(data.name) then
            return data.name
        end
    end

    if C_GossipInfo and C_GossipInfo.GetFriendshipReputation then
        local info = C_GossipInfo.GetFriendshipReputation(factionID)
        if info and IsUsableString(info.name) then
            return info.name
        end
    end

    return (cfg and cfg.label) or ("Faction " .. tostring(factionID))
end

-- Standard standing label (Friendly, Honored, ...), gendered where the locale has it
function HR.GetStandingLabel(reaction)
    if not reaction or reaction <= 0 then
        return UNKNOWN or L["Unknown"]
    end

    local token = "FACTION_STANDING_LABEL" .. reaction
    local label = UnitSex("player") == 3 and _G[token .. "_FEMALE"]
    if not IsUsableString(label) then
        label = _G[token]
    end
    if IsUsableString(label) then
        return label
    end

    return (L["Standing %d"]):format(reaction)
end

-- "Renown 8"
local RENOWN_FORMAT = (type(RENOWN_LEVEL_LABEL) == "string" and RENOWN_LEVEL_LABEL:find("%%d")) and
                          RENOWN_LEVEL_LABEL or L["Renown %d"]

function HR.GetRenownLabel(level)
    if not level then
        return (RENOWN_FORMAT:gsub("%%d", "?"))
    end
    return RENOWN_FORMAT:format(level)
end

-- Expansion name. data.lua keeps English keys as stable IDs; ui.lua maps them to
-- the client's expansion index, which EXPANSION_NAME<n> turns into a name.
function HR.GetExpansionName(expansionIndex, fallback)
    local name = expansionIndex and _G["EXPANSION_NAME" .. expansionIndex]
    if IsUsableString(name) then
        return name
    end
    return fallback
end

-- Zone name from the vendor's uiMapID
function HR.GetMapName(uiMapID, fallback)
    if uiMapID and C_Map and C_Map.GetMapInfo then
        local info = C_Map.GetMapInfo(uiMapID)
        if info and IsUsableString(info.name) then
            return info.name
        end
    end
    return fallback
end

-- NPC name, read from the client's creature cache via a unit hyperlink tooltip.
-- Returns the fallback until the client has seen (or been sent) that creature.
local npcNameCache = {}

function HR.GetNPCName(npcID, fallback)
    if not npcID then
        return fallback
    end

    local cached = npcNameCache[npcID]
    if cached then
        return cached
    end

    if C_TooltipInfo and C_TooltipInfo.GetHyperlink then
        local ok, data = pcall(C_TooltipInfo.GetHyperlink, ("unit:Creature-0-0-0-0-%d-0000000000"):format(npcID))
        local line = ok and data and data.lines and data.lines[1]
        local name = line and line.leftText
        if IsUsableString(name) then
            npcNameCache[npcID] = name
            return name
        end
    end

    return fallback
end

-- Item name/link; the API wants item data loaded first, so request it when missing.
local GetItemInfoFn = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local itemLoadRequested = {}

function HR.GetItemNameAndLink(itemID)
    if not itemID or itemID <= 0 then
        return nil, nil
    end

    local name, link = GetItemInfoFn(itemID)
    if not name and not itemLoadRequested[itemID] and C_Item and C_Item.RequestLoadItemDataByID then
        itemLoadRequested[itemID] = true
        C_Item.RequestLoadItemDataByID(itemID)
    end
    return name, link
end

-------------------------------------------------------
-- Friendship rank names
-- The API only names the rank a character currently holds, so we remember
-- each one we see. Required ranks a character has reached show localized;
-- the rest fall back to the English name in data.lua.
-------------------------------------------------------

function HR.RememberFriendshipRankName(factionID, tier, name)
    if not factionID or not tier or tier <= 0 or not IsUsableString(name) then
        return
    end

    HousingRepsDB.friendshipRankNames = HousingRepsDB.friendshipRankNames or {}
    local names = HousingRepsDB.friendshipRankNames
    if names.locale ~= locale then
        -- Client language changed: names from the old locale are no use
        wipe(names)
        names.locale = locale
    end

    names[factionID] = names[factionID] or {}
    names[factionID][tier] = name
end

function HR.GetFriendshipRankName(factionID, tier, fallback)
    local names = HousingRepsDB and HousingRepsDB.friendshipRankNames
    if names and names.locale == locale and names[factionID] and names[factionID][tier] then
        return names[factionID][tier]
    end
    return fallback
end
