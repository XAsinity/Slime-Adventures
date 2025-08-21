-- EggRegistry: central store of egg stats so we don't depend on Tool attributes.
local EggRegistry = {}

-- eggs[eggId] = {
--   OwnerUserId = number,
--   Stats = { Rarity=..., HatchTime=..., BaseSizeScale=..., GrowthRate=..., MaxSizeScale=..., ValueBase=..., ValuePerGrowth=..., RarityWeight=... }
-- }
EggRegistry.eggs = {}

function EggRegistry.Register(eggId, ownerUserId, stats)
	if not eggId or EggRegistry.eggs[eggId] then return end
	EggRegistry.eggs[eggId] = {
		OwnerUserId = ownerUserId,
		Stats = stats,
		CreatedAt = time()
	}
end

function EggRegistry.Consume(eggId)
	local data = EggRegistry.eggs[eggId]
	EggRegistry.eggs[eggId] = nil
	return data
end

function EggRegistry.Get(eggId)
	return EggRegistry.eggs[eggId]
end

return EggRegistry