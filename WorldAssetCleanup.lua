-- WorldAssetCleanup.lua
-- Version: v1.2-delay (extends v1.1)
-- Changes:
--   * Increased default GraceSecondsPostLeave to allow InventoryService / serializers to perform
--     ForceFinalSerialize before destruction (prevents final worldEggs/worldSlimes=0 snapshot).
--   * Added configurable DestroyKinds table for targeted cleanup.
--   * Added instrumentation summarizing counts destroyed.
--
local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")

local WorldAssetCleanup = {}

local CONFIG = {
	DestroyOnLeave        = true,
	Debug                 = true,
	GraceSecondsPostLeave = 2.5,   -- was 0; must exceed final flush window
	DestroyKinds = {
		Egg   = true,
		Slime = true,
	},
	DestroyIfHasAttributes = { "EggId", "SlimeId", "Placed" },
}

local function dprint(...)
	if CONFIG.Debug then print("[WorldAssetCleanup]", ...) end
end

local function shouldDestroy(model)
	if CONFIG.DestroyKinds[model.Name] then return true end
	for _,attr in ipairs(CONFIG.DestroyIfHasAttributes) do
		if model:GetAttribute(attr) ~= nil then
			return true
		end
	end
	return false
end

local function destroyOwnedModels(userId)
	local destroyed = 0
	for _,desc in ipairs(Workspace:GetDescendants()) do
		if desc:IsA("Model") then
			local owner = desc:GetAttribute("OwnerUserId")
			if owner == userId and shouldDestroy(desc) then
				local ok = pcall(function() desc:Destroy() end)
				if ok then destroyed += 1 end
			end
		end
	end
	dprint(("Destroyed %d owned world models for userId=%s"):format(destroyed, tostring(userId)))
end

function WorldAssetCleanup.Init()
	if not CONFIG.DestroyOnLeave then
		dprint("DestroyOnLeave disabled.")
		return
	end
	Players.PlayerRemoving:Connect(function(player)
		task.delay(CONFIG.GraceSecondsPostLeave, function()
			destroyOwnedModels(player.UserId)
		end)
	end)
	game:BindToClose(function()
		for _,plr in ipairs(Players:GetPlayers()) do
			destroyOwnedModels(plr.UserId)
		end
	end)
	dprint("Initialized (DestroyOnLeave="..tostring(CONFIG.DestroyOnLeave)..", Delay="..CONFIG.GraceSecondsPostLeave..")")
end

return WorldAssetCleanup