-- PreExitInventorySync.lua
-- Registers a pre-exit callback with PlayerProfileService to force
-- a last-moment raw enumeration of live tool inventories (food, egg, captured slimes).
-- Ensures immediate-leave purchases are always persisted, regardless of gating.

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerProfileService = require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

local function collectTools(player)
    local bp = player:FindFirstChildOfClass("Backpack")
    local char = player.Character
    local function grab(container, pred, out)
        if not container then return end
        for _,c in ipairs(container:GetChildren()) do
            if c:IsA("Tool") and pred(c) then
                out[#out+1] = c
            end
        end
    end
    local food, eggs, caps = {}, {}, {}
    grab(bp,   function(t) return t:GetAttribute("FoodItem") or t:GetAttribute("FoodId") end, food)
    grab(char, function(t) return t:GetAttribute("FoodItem") or t:GetAttribute("FoodId") end, food)
    grab(bp,   function(t) return t:GetAttribute("EggId") and not t:GetAttribute("Placed") end, eggs)
    grab(char, function(t) return t:GetAttribute("EggId") and not t:GetAttribute("Placed") end, eggs)
    grab(bp,   function(t) return t:GetAttribute("SlimeItem") or t:GetAttribute("SlimeId") end, caps)
    grab(char, function(t) return t:GetAttribute("SlimeItem") or t:GetAttribute("SlimeId") end, caps)
    return food, eggs, caps
end

local function buildFoodEntry(tool)
    return {
        nm  = tool.Name,
        fid = tool:GetAttribute("FoodId") or tool.Name,
        rf  = tool:GetAttribute("RestoreFraction"),
        fb  = tool:GetAttribute("FeedBufferBonus"),
        cs  = tool:GetAttribute("Consumable"),
        ch  = tool:GetAttribute("Charges"),
        cd  = tool:GetAttribute("FeedCooldownOverride"),
        ow  = tool:GetAttribute("OwnerUserId"),
        uid = tool:GetAttribute("ToolUniqueId"),
    }
end

local function buildEggEntry(tool)
    return {
        nm  = tool.Name,
        id  = tool:GetAttribute("EggId"),
        ra  = tool:GetAttribute("Rarity"),
        ht  = tool:GetAttribute("HatchTime"),
        vb  = tool:GetAttribute("ValueBase"),
        vg  = tool:GetAttribute("ValuePerGrowth"),
        ws  = tool:GetAttribute("WeightScalar"),
        ms  = tool:GetAttribute("MovementScalar"),
        mb  = tool:GetAttribute("MutationRarityBonus"),
        ou  = tool:GetAttribute("OwnerUserId"),
    }
end

local function buildCapEntry(tool)
    return {
        nm  = tool.Name,
        id  = tool:GetAttribute("SlimeId"),
        ra  = tool:GetAttribute("Rarity"),
        gp  = tool:GetAttribute("GrowthProgress"),
        cv  = tool:GetAttribute("CurrentValue"),
        vf  = tool:GetAttribute("ValueFull"),
        vb  = tool:GetAttribute("ValueBase"),
        vg  = tool:GetAttribute("ValuePerGrowth"),
        ms  = tool:GetAttribute("MutationStage"),
        ti  = tool:GetAttribute("Tier"),
        wt  = tool:GetAttribute("WeightPounds"),
        ff  = tool:GetAttribute("FedFraction"),
        bc  = tool:GetAttribute("BodyColor"),
        ac  = tool:GetAttribute("AccentColor"),
        ec  = tool:GetAttribute("EyeColor"),
        ca  = tool:GetAttribute("CapturedAt"),
        mv  = tool:GetAttribute("MovementScalar"),
        ws  = tool:GetAttribute("WeightScalar"),
        mb  = tool:GetAttribute("MutationRarityBonus"),
        mx  = tool:GetAttribute("MaxSizeScale"),
        st  = tool:GetAttribute("StartSizeScale"),
        css = tool:GetAttribute("CurrentSizeScale"),
        lr  = tool:GetAttribute("SizeLuckRolls"),
        fb  = tool:GetAttribute("FeedBufferSeconds"),
        fx  = tool:GetAttribute("FeedBufferMax"),
        hd  = tool:GetAttribute("HungerDecayRate"),
        cf  = tool:GetAttribute("CurrentFullness"),
        fs  = tool:GetAttribute("FeedSpeedMultiplier"),
        lu  = tool:GetAttribute("LastHungerUpdate"),
    }
end

local function syncInventoryOnExit(player)
    if not player.Parent then return end
    local foodTools, eggTools, capTools = collectTools(player)

    local foodEntries = {}
    for _,t in ipairs(foodTools) do
        foodEntries[#foodEntries+1] = buildFoodEntry(t)
    end

    local eggEntries = {}
    for _,t in ipairs(eggTools) do
        eggEntries[#eggEntries+1] = buildEggEntry(t)
    end

    local capEntries = {}
    for _,t in ipairs(capTools) do
        capEntries[#capEntries+1] = buildCapEntry(t)
    end

    local profile = PlayerProfileService.GetProfile(player)
    profile.inventory = profile.inventory or {}
    profile.inventory.foodTools      = foodEntries
    profile.inventory.eggTools       = eggEntries
    profile.inventory.capturedSlimes = capEntries

    print(string.format(
        "[PreExitSync] %s food=%d eggs=%d captured=%d",
        player.Name, #foodEntries, #eggEntries, #capEntries))

    PlayerProfileService.MarkDirty(player, "PreExitSync")
end

Players.PlayerRemoving:Connect(syncInventoryOnExit)

return true