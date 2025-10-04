-- FoodDefinitions
-- Defensive, non-yielding definitions for food items.
-- - Small, stable default values that match the client/server expectations in FoodClient/FoodService.
-- - resolve(id) returns a merged table (Defaults <- Food entry) or nil if id not found.
-- - Safe to require at runtime (the file itself does not yield). If other code used WaitForChild before requiring,
--   ensure you create this ModuleScript before runtime scripts call WaitForChild (or update callers to use FindFirstChild).

local FoodDefinitions = {}

local FoodDefinitions = {}

FoodDefinitions.Defaults = {
	RestoreFraction = 0.25,
	FeedBufferBonus = 15,
	Charges = 1,
	Consumable = true,
	CooldownOverride = nil,
	RequireOwnership = true,
	-- client-visible tuning
	ClientPromptRadius = 8,
	ClientRemoveRadius = 10,         -- if omitted for a food, caller will derive from ClientPromptRadius + pad
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
		VisualModel = "SlimeFoodBasic",

		-- DEBUG / TESTING: allow feeding non-owned slimes
		RequireOwnership = false,

		-- (if you still want the larger radii for testing)
		ClientPromptRadius = 25,
		ClientActivationRadius = 10,
	},
}

-- Utility: shallow-merge defaults + overrides into new table
local function mergeDefaults(defaults, overrides)
	local out = {}
	for k, v in pairs(defaults) do out[k] = v end
	if type(overrides) == "table" then
		for k, v in pairs(overrides) do out[k] = v end
	end
	if out.ClientPromptRadius == nil then out.ClientPromptRadius = defaults.ClientPromptRadius end
	if out.ClientActivationRadius == nil then out.ClientActivationRadius = defaults.ClientActivationRadius end
	if out.ClientRemoveRadius == nil then
		out.ClientRemoveRadius = (out.ClientPromptRadius or defaults.ClientPromptRadius) + 2
	end
	return out
end


-- Resolve a food id string to a merged definition table or nil if not present.
-- Returns a fresh table (caller may mutate safely).
function FoodDefinitions.resolve(id)
	if not id then return nil end
	local base = FoodDefinitions.Foods[tostring(id)]
	if not base then return nil end
	local merged = mergeDefaults(FoodDefinitions.Defaults, base)
	return merged
end

-- Convenience: list available food ids (non-yielding)
function FoodDefinitions.listIds()
	local out = {}
	for k,_ in pairs(FoodDefinitions.Foods) do table.insert(out, k) end
	return out
end

return FoodDefinitions