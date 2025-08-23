-- PlayerProfileService.lua
-- Unified profile/persistence module (compatible with PlayerProfileOrchestrator)

local DataStoreService = game:GetService("DataStoreService")
local Players          = game:GetService("Players")
local DATASTORE_NAME   = "PlayerUnified_v1"
local KEY_PREFIX       = "Player_"

local store            = DataStoreService:GetDataStore(DATASTORE_NAME)
local profileCache     = {}
local dirtyPlayers     = {}

local function log(...)
    print("[PlayerProfileService]", ...)
end

local function keyFor(uid)
    return KEY_PREFIX .. tostring(uid)
end

local function deepCopy(v, seen)
    if type(v) ~= "table" then return v end
    seen = seen or {}
    if seen[v] then return seen[v] end
    local t = {}
    seen[v] = t
    for k, val in pairs(v) do
        t[deepCopy(k, seen)] = deepCopy(val, seen)
    end
    return t
end

local function defaultProfile(userId)
    return {
        schemaVersion = 1,
        dataVersion   = 1,
        userId        = userId,
        updatedAt     = os.time(),
        core          = {
            coins     = 0,
            standings = {},
            wipeGen   = 1,
        },
        inventory     = {
            eggTools      = {},
            foodTools     = {},
            capturedSlimes= {},
            worldSlimes   = {},
            worldEggs     = {},
        },
        extra         = {},
    }
end

local function ensureKeys(data, userId)
    if not data.schemaVersion then data.schemaVersion = 1 end
    if not data.dataVersion then data.dataVersion = 1 end
    if not data.userId then data.userId = userId end
    if not data.updatedAt then data.updatedAt = os.time() end
    data.core = data.core or defaultProfile(userId).core
    data.inventory = data.inventory or defaultProfile(userId).inventory
    data.extra = data.extra or {}
    return data
end

local function loadProfile(userId)
    local key = keyFor(userId)
    local data
    local ok, err = pcall(function()
        data = store:GetAsync(key)
    end)
    if not ok or type(data) ~= "table" then
        log("No profile found for userId", userId, "creating default.")
        data = defaultProfile(userId)
    end
    data = ensureKeys(data, userId)
    profileCache[userId] = data
    return data
end

local function saveProfile(userId, reason)
    local profile = profileCache[userId]
    if not profile then return false, "no profile" end
    profile.updatedAt = os.time()
    profile.dataVersion = (profile.dataVersion or 1) + 1
    local key = keyFor(userId)
    local ok, err = pcall(function()
        store:SetAsync(key, profile)
    end)
    if ok then
        log("Saved profile for userId", userId, "reason:", reason or "unspecified")
        dirtyPlayers[userId] = nil
        return true
    else
        log("Save FAILED for userId", userId, "err:", err)
        return false, err
    end
end

local function markDirty(userId)
    dirtyPlayers[userId] = true
end

task.spawn(function()
    while true do
        for userId in pairs(dirtyPlayers) do
            saveProfile(userId, "Periodic")
        end
        task.wait(5)
    end
end)

local PlayerProfileService = {}

function PlayerProfileService.GetProfile(player)
    local userId = player.UserId
    return profileCache[userId] or loadProfile(userId)
end

function PlayerProfileService.Get(player)
    return PlayerProfileService.GetProfile(player)
end

function PlayerProfileService.SetCoins(player, amount)
    local profile = PlayerProfileService.GetProfile(player)
    profile.core = profile.core or {}
    profile.core.coins = amount
    markDirty(player.UserId)
    -- Live update attribute and leaderstats
    player:SetAttribute("CoinsStored", amount)
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        local coins = ls:FindFirstChild("Coins")
        if coins then
            coins.Value = amount
        end
    end
end

function PlayerProfileService.IncrementCoins(player, delta)
    local profile = PlayerProfileService.GetProfile(player)
    profile.core = profile.core or {}
    profile.core.coins = (profile.core.coins or 0) + delta
    markDirty(player.UserId)
    -- Live update attribute and leaderstats
    local newAmount = profile.core.coins
    player:SetAttribute("CoinsStored", newAmount)
    local ls = player:FindFirstChild("leaderstats")
    if ls then
        local coins = ls:FindFirstChild("Coins")
        if coins then
            coins.Value = newAmount
        end
    end
end

function PlayerProfileService.GetCoins(player)
    local profile = PlayerProfileService.GetProfile(player)
    return (profile.core and profile.core.coins) or 0
end

function PlayerProfileService.SetStanding(player, faction, value)
    local profile = PlayerProfileService.GetProfile(player)
    profile.core = profile.core or {}
    profile.core.standings = profile.core.standings or {}
    profile.core.standings[faction] = value
    markDirty(player.UserId)
end

function PlayerProfileService.GetStanding(player, faction)
    local profile = PlayerProfileService.GetProfile(player)
    profile.core = profile.core or {}
    profile.core.standings = profile.core.standings or {}
    return profile.core.standings[faction] or 0
end

function PlayerProfileService.AddInventoryItem(player, category, itemData)
    local profile = PlayerProfileService.GetProfile(player)
    profile.inventory = profile.inventory or defaultProfile(player.UserId).inventory
    if profile.inventory[category] then
        table.insert(profile.inventory[category], itemData)
        markDirty(player.UserId)
    end
end

function PlayerProfileService.RemoveInventoryItem(player, category, itemIdField, itemId)
    local profile = PlayerProfileService.GetProfile(player)
    profile.inventory = profile.inventory or defaultProfile(player.UserId).inventory
    local items = profile.inventory[category]
    if items then
        for i = #items, 1, -1 do
            if items[i][itemIdField] == itemId then
                table.remove(items, i)
                markDirty(player.UserId)
                break
            end
        end
    end
end

function PlayerProfileService.SaveNow(player, reason)
    saveProfile(player.UserId, reason or "Manual")
end

function PlayerProfileService.ForceFullSaveNow(player, reason)
    saveProfile(player.UserId, reason or "ForceFullSave")
end

local EXIT_SAVE_ATTEMPTS      = 3
local EXIT_SAVE_BACKOFF       = 0.4
local EXIT_SAVE_VERIFY_DELAY  = 0.15

local function performVerifiedWrite(userId, snapshot, attempt)
    local key = keyFor(userId)
    local okUpdate, errUpdate = pcall(function()
        store:UpdateAsync(key, function()
            return snapshot
        end)
    end)
    if not okUpdate then
        log(string.format("Attempt %d UpdateAsync failed userId=%d err=%s", attempt, userId, tostring(errUpdate)))
        return false
    end
    task.wait(EXIT_SAVE_VERIFY_DELAY)
    local stored
    local okRead, errRead = pcall(function()
        stored = store:GetAsync(key)
    end)
    if not okRead or type(stored) ~= "table" then
        log(string.format("Attempt %d verify failed userId=%d", attempt, userId))
        return false
    end
    local sv = stored.dataVersion or -1
    local pv = snapshot.dataVersion or -1
    if sv < pv then
        log(string.format("Attempt %d version mismatch userId=%d stored=%s expected>=%s",
            attempt, userId, tostring(sv), tostring(pv)))
        return false
    end
    log(string.format("Attempt %d SUCCESS userId=%d dataVersion=%s", attempt, userId, tostring(sv)))
    return true
end

local function tripleExitSave(player)
    local userId = player.UserId
    local snapshot = deepCopy(profileCache[userId] or defaultProfile(userId))
    local startT = os.clock()
    for attempt = 1, EXIT_SAVE_ATTEMPTS do
        local ok = performVerifiedWrite(userId, snapshot, attempt)
        if ok then
            log(string.format("Verified exit save complete attempt=%d userId=%d elapsed=%.2fs",
                attempt, userId, os.clock()-startT))
            return
        end
        if attempt < EXIT_SAVE_ATTEMPTS then
            task.wait(EXIT_SAVE_BACKOFF)
        else
            log(string.format("FINAL FAILURE userId=%d after %d attempts (snapshot dv=%s)",
                userId, attempt, tostring(snapshot.dataVersion)))
        end
    end
end

Players.PlayerRemoving:Connect(tripleExitSave)

game:BindToClose(function()
    for _, player in ipairs(Players:GetPlayers()) do
        tripleExitSave(player)
    end
    task.wait(0.5)
end)

return PlayerProfileService