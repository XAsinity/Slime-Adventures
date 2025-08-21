local FoodDefinitions = {}

FoodDefinitions.Defaults = {
	RestoreFraction = 0.25,
	FeedBufferBonus = 15,
	Charges = 1,
	Consumable = true,
	CooldownOverride = nil,
	RequireOwnership = true,
	ClientPromptRadius = 8,
	ClientRemoveRadius = 10,
	ClientActivationRadius = 4,
	AutoFeedNearby = false,
	AutoFeedCooldown = 1,
	ShowFullnessPercent = false,
	OnlyWhenNotFull = false,
	FullnessHideThreshold = 0.999,
}

FoodDefinitions.Foods = {
	BasicFood = {
		Label = "Basic Food",
		RestoreFraction = 0.25,
		FeedBufferBonus = 15,
		Charges = 1,
		Rarity = "Common",
	},
}

function FoodDefinitions.resolve(id)
	local base = FoodDefinitions.Foods[id]
	if not base then return nil end
	local merged = {}
	for k,v in pairs(FoodDefinitions.Defaults) do merged[k]=v end
	for k,v in pairs(base) do merged[k]=v end
	return merged
end

return FoodDefinitions