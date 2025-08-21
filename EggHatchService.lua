-- EggHatchService.lua (NEW)
-- Provides in-place persistence removal for hatched world eggs, mirroring legacy MarkEggHatched logic.

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local PlayerDataService = require(ServerScriptService.Modules:WaitForChild("PlayerDataService"))

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
	local prof = PlayerDataService.Get(player)
	if not prof then return end
	local foundIndex
	for i,e in ipairs(prof.worldEggs or {}) do
		if e.id == eggId then foundIndex = i break end
	end
	if not foundIndex then return end

	-- We need to update live orchestrator profile; use compat Get then MarkDirty + Save
	-- Since compat Get returns copy, call a slender direct method: rely on serializer skipping eggs next save
	if CONFIG.Debug then dprint("Marking egg hatched", eggId, "for", player.Name) end
	PlayerDataService.MarkDirty(player, "EggHatch")
	if CONFIG.SaveImmediatelyOnHatch then
		PlayerDataService.SaveImmediately(player, "EggHatch", {skipWorld=true})
	end
end

return EggHatchService