-- SlimeCaptureService.lua
-- Now uses PlayerProfileService for persistence and dirty marking

local Players            = game:GetService("Players")
local ReplicatedStorage  = game:GetService("ReplicatedStorage")
local HttpService        = game:GetService("HttpService")
local RunService         = game:GetService("RunService")
local ServerModules      = game:GetService("ServerScriptService").Modules
local PlayerProfileService = require(ServerModules:WaitForChild("PlayerProfileService"))

local Remotes       = ReplicatedStorage:WaitForChild("Remotes")
local PickupRequest = Remotes:WaitForChild("SlimePickupRequest")
local PickupResult  = Remotes:WaitForChild("SlimePickupResult")

local TOOL_TEMPLATES = ReplicatedStorage:WaitForChild("ToolTemplates")
local TOOL_TEMPLATE  = TOOL_TEMPLATES:FindFirstChild("CapturedSlimeTool")

local CONFIG = {
    MaxCaptureDistance      = 60,
    ValuePerGrowth          = 1.0,
    BASE_WEIGHT_LBS         = 15,
    PlayerCaptureCooldown   = 1.0,
    StripScriptsInToolCopy  = true,
    Debug                   = false,

    USE_GENERIC_CAPTURED_TOOL_NAME = true,
    GENERIC_CAPTURED_NAME          = "CapturedSlime",

    ImmediateSave             = true,
    SaveReason                = "PostCapture",
    WaitHeartbeatBeforeSave   = true,
    SaveDelayAfterDestroy     = 0.05,
}

local lastCaptureAt = {}

local function dprint(...)
    if CONFIG.Debug then
        print("[SlimeCaptureService]", ...)
    end
end

local function toHex6(c)
    if typeof(c) ~= "Color3" then return "FFFFFF" end
    return string.format("%02X%02X%02X",
        math.floor(c.R*255+0.5),
        math.floor(c.G*255+0.5),
        math.floor(c.B*255+0.5))
end

local function findPrimary(model)
    if model.PrimaryPart then return model.PrimaryPart end
    for _,c in ipairs(model:GetChildren()) do
        if c:IsA("BasePart") then
            model.PrimaryPart = c
            return c
        end
    end
    return nil
end

local function computeValueBase(valueFull, perGrowth)
    valueFull   = (valueFull and valueFull > 0) and valueFull or 150
    perGrowth   = perGrowth or CONFIG.ValuePerGrowth
    local denom = 1 + perGrowth
    if denom <= 0 then denom = 1 end
    return math.max(1, math.floor(valueFull / denom))
end

local function computeWeightLbs(slime)
    local scale = slime:GetAttribute("CurrentSizeScale") or 1
    if scale <= 0 then scale = 1 end
    return (scale ^ 3) * CONFIG.BASE_WEIGHT_LBS
end

local function cloneVisual(slime, tool)
    local clone = slime:Clone()
    local partCount = 0
    if CONFIG.StripScriptsInToolCopy then
        for _,d in ipairs(clone:GetDescendants()) do
            if d:IsA("Script") or d:IsA("LocalScript") or d:IsA("ModuleScript") then
                d:Destroy()
            elseif d:IsA("BasePart") then
                d.CanCollide = false
                d.CanTouch   = false
                d.CanQuery   = false
                d.Massless   = true
                d.Anchored   = false
                partCount += 1
            end
        end
    else
        for _,d in ipairs(clone:GetDescendants()) do
            if d:IsA("BasePart") then
                d.CanCollide = false
                d.Massless   = true
                partCount += 1
            end
        end
    end
    clone.Name = "SlimeVisual"
    clone.Parent = tool
    tool:SetAttribute("SlimmedVisualParts", partCount)
    return clone
end

local function weldVisual(tool)
    local handle = tool:FindFirstChild("Handle")
    local visual = tool:FindFirstChild("SlimeVisual")
    if not (handle and visual and visual:IsA("Model")) then return end
    local prim = visual.PrimaryPart or findPrimary(visual)
    if not prim then return end
    visual:PivotTo(handle.CFrame)
    local weld = Instance.new("WeldConstraint")
    weld.Part0 = handle
    weld.Part1 = prim
    weld.Parent = handle
    for _,p in ipairs(visual:GetDescendants()) do
        if p:IsA("BasePart") and p ~= prim then
            local w = Instance.new("WeldConstraint")
            w.Part0 = prim
            w.Part1 = p
            w.Parent = p
            p.CanCollide = false
            p.Massless   = true
        end
    end
end

local FULL_ATTR_LIST = {
    "GrowthProgress","CurrentValue","ValueFull","ValueBase","ValuePerGrowth",
    "MutationStage","Tier","WeightPounds","FedFraction","BodyColor","AccentColor","EyeColor",
    "MovementScalar","WeightScalar","MutationRarityBonus",
    "MaxSizeScale","StartSizeScale","CurrentSizeScale","SizeLuckRolls",
    "FeedBufferSeconds","FeedBufferMax","HungerDecayRate","CurrentFullness",
    "FeedSpeedMultiplier","LastHungerUpdate","Rarity",
}

local function normalizeHex(val, fallback)
    if typeof(val)=="Color3" then return toHex6(val) end
    if type(val)=="string" then
        val = val:gsub("^#","")
        if #val==6 then return val:upper() end
    end
    if typeof(fallback)=="Color3" then return toHex6(fallback) end
    return "FFFFFF"
end

local function buildTool(slime, player)
    if not TOOL_TEMPLATE then
        return nil, "Missing CapturedSlimeTool template"
    end
    local tool = TOOL_TEMPLATE:Clone()
    tool:SetAttribute("PersistentCaptured", true)

    if CONFIG.USE_GENERIC_CAPTURED_TOOL_NAME then
        tool.Name = CONFIG.GENERIC_CAPTURED_NAME
    else
        tool.Name = "CapturedSlime"
    end

    local slimeId       = slime:GetAttribute("SlimeId") or HttpService:GenerateGUID(false)
    local growth        = math.clamp(slime:GetAttribute("GrowthProgress") or 0, 0, 1)
    local valueFull     = slime:GetAttribute("ValueFull") or 150
    local valuePerGrowth= slime:GetAttribute("ValuePerGrowth") or CONFIG.ValuePerGrowth
    local currentValue  = slime:GetAttribute("CurrentValue") or math.floor(valueFull * growth)
    local valueBase     = slime:GetAttribute("ValueBase") or computeValueBase(valueFull, valuePerGrowth)
    local weightLbs     = computeWeightLbs(slime)
    local rarity        = slime:GetAttribute("Rarity") or "Common"

    local prim          = findPrimary(slime)
    local baseBodyColor = prim and prim.Color or Color3.new(1,1,1)

    local bodyHex  = normalizeHex(slime:GetAttribute("BodyColor"), baseBodyColor)
    local accentHex= normalizeHex(slime:GetAttribute("AccentColor"), Color3.new(1,1,1))
    local eyeHex   = normalizeHex(slime:GetAttribute("EyeColor"), Color3.new(0,0,0))

    tool:SetAttribute("SlimeItem", true)
    tool:SetAttribute("SlimeId", slimeId)
    tool:SetAttribute("OwnerUserId", player.UserId)
    tool:SetAttribute("CapturedAt", os.time())

    tool:SetAttribute("GrowthProgress", growth)
    tool:SetAttribute("ValueFull", valueFull)
    tool:SetAttribute("ValueBase", valueBase)
    tool:SetAttribute("ValuePerGrowth", valuePerGrowth)
    tool:SetAttribute("CurrentValue", currentValue)
    tool:SetAttribute("WeightPounds", weightLbs)
    tool:SetAttribute("Rarity", rarity)

    tool:SetAttribute("BodyColor", bodyHex)
    tool:SetAttribute("AccentColor", accentHex)
    tool:SetAttribute("EyeColor", eyeHex)

    for _,attr in ipairs(FULL_ATTR_LIST) do
        if tool:GetAttribute(attr) == nil then
            local v = slime:GetAttribute(attr)
            if v ~= nil then
                if (attr=="BodyColor" or attr=="AccentColor" or attr=="EyeColor") then
                    v = normalizeHex(v, nil)
                end
                tool:SetAttribute(attr, v)
            end
        end
    end

    cloneVisual(slime, tool)
    weldVisual(tool)
    return tool
end

local function validate(player, slime)
    if typeof(slime) ~= "Instance" or not slime:IsA("Model") or slime.Name ~= "Slime" then
        return false, "Not a slime."
    end
    if slime:GetAttribute("Capturing") then
        return false, "Busy."
    end
    local char = player.Character
    if not char then return false, "No character." end
    local hrp = char:FindFirstChild("HumanoidRootPart")
    if not hrp then return false, "No HRP." end
    local prim = findPrimary(slime)
    if not prim then return false, "Invalid slime." end
    if (prim.Position - hrp.Position).Magnitude > CONFIG.MaxCaptureDistance then
        return false, "Too far."
    end
    local owner = slime:GetAttribute("OwnerUserId")
    if owner and owner ~= 0 and owner ~= player.UserId then
        return false, "Owned."
    end
    local now = os.clock()
    if now - (lastCaptureAt[player.UserId] or 0) < CONFIG.PlayerCaptureCooldown then
        return false, "Cooldown."
    end
    return true
end

local function perform(player, slime)
    local ok, err = validate(player, slime)
    if not ok then return false, err end
    lastCaptureAt[player.UserId] = os.clock()

    slime:SetAttribute("Capturing", true)
    slime:SetAttribute("Retired", true)

    local tool, terr = buildTool(slime, player)
    if not tool then
        slime:SetAttribute("Capturing", nil)
        slime:SetAttribute("Retired", nil)
        return false, terr
    end

    -- Ensure unique id for persistence dedupe
    if not tool:GetAttribute("ToolUniqueId") then
        tool:SetAttribute("ToolUniqueId", HttpService:GenerateGUID(false))
    end

    local backpack = player:FindFirstChildOfClass("Backpack")
    if not backpack then
        tool:Destroy()
        slime:SetAttribute("Capturing", nil)
        slime:SetAttribute("Retired", nil)
        return false, "No backpack."
    end

    tool.Parent = backpack
    slime:Destroy()

    -- Add to PlayerProfileService inventory
    PlayerProfileService.AddInventoryItem(player, "capturedSlimes", {
        SlimeId = tool:GetAttribute("SlimeId"),
        ToolUniqueId = tool:GetAttribute("ToolUniqueId"),
        CapturedAt = tool:GetAttribute("CapturedAt"),
        OwnerUserId = player.UserId,
        Rarity = tool:GetAttribute("Rarity"),
        WeightPounds = tool:GetAttribute("WeightPounds"),
        CurrentValue = tool:GetAttribute("CurrentValue"),
        GrowthProgress = tool:GetAttribute("GrowthProgress"),
    })

    if CONFIG.ImmediateSave then
        if CONFIG.WaitHeartbeatBeforeSave then
            RunService.Heartbeat:Wait()
        end
        if CONFIG.SaveDelayAfterDestroy and CONFIG.SaveDelayAfterDestroy > 0 then
            task.wait(CONFIG.SaveDelayAfterDestroy)
        end
        PlayerProfileService.ForceFullSaveNow(player, CONFIG.SaveReason)
    end

    return true, {
        ToolName       = tool.Name,
        WeightPounds   = tool:GetAttribute("WeightPounds"),
        CurrentValue   = tool:GetAttribute("CurrentValue"),
        GrowthProgress = tool:GetAttribute("GrowthProgress"),
        Rarity         = tool:GetAttribute("Rarity"),
    }
end

PickupRequest.OnServerEvent:Connect(function(player, slime)
    local success, dataOrErr = perform(player, slime)
    PickupResult:FireClient(player, {
        success = success,
        message = success and "Captured slime." or tostring(dataOrErr),
        data    = success and dataOrErr or nil
    })
end)

return true