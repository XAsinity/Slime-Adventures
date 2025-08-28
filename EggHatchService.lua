-- EggHatchService.lua (UPDATED)
-- Provides in-place persistence removal for hatched world eggs, using PlayerProfileService.

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local PlayerProfileService = require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

local EggHatchService = {}

local CONFIG = {
	SaveImmediatelyOnHatch = true,
	Debug = true,
}

local function dprint(...)
	if CONFIG.Debug then print("[EggHatch]", ...) end
end

function EggHatchService.MarkEggHatched(player, eggId)
	if not player or not eggId then return end
	local profile = PlayerProfileService.GetProfile(player)
	if not profile or not profile.inventory or not profile.inventory.worldEggs then return end

	local foundIndex
	for i, e in ipairs(profile.inventory.worldEggs) do
		if e.id == eggId then
			foundIndex = i
			break
		end
	end
	if not foundIndex then return end

	-- Remove the egg from inventory.worldEggs
	table.remove(profile.inventory.worldEggs, foundIndex)
	PlayerProfileService.SaveNow(player, "EggHatch")

	if CONFIG.Debug then dprint("Marked egg hatched", eggId, "for", player.Name) end

	if CONFIG.SaveImmediatelyOnHatch then
		PlayerProfileService.ForceFullSaveNow(player, "EggHatchImmediate")
	end
end

return EggHatchService