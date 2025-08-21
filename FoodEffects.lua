-- FoodEffects: applies secondary effects defined in FoodDefinitions ExtraEffects.
-- This module should contain only pure-ish logic and small side-effect helpers; server only logic should gate actual attribute writes.

local FoodEffects = {}

-- Example effect application stubs.
-- Extend with your actual systems (Growth, Mutation, Movement, Status, etc.)

-- Provide an interface: applyExtraEffects(slime, player, foodDef, context)
-- context could include { restoreFractionApplied = number }

function FoodEffects.applyExtraEffects(slime, player, foodDef, context)
	if not foodDef.ExtraEffects then return end
	for _,effect in ipairs(foodDef.ExtraEffects) do
		if effect.Type == "GrowthBoost" then
			FoodEffects.applyTimedScalar(slime, "GrowthRateBoost", effect.Amount, effect.Duration)
		elseif effect.Type == "MutationChanceBonus" then
			FoodEffects.applyTimedScalar(slime, "MutationChanceBonus", effect.Amount, effect.Duration)
		elseif effect.Type == "MovementBoost" then
			FoodEffects.applyTimedScalar(slime, "MovementScalarBonus", effect.Amount, effect.Duration)
		else
			warn("[FoodEffects] Unknown effect type:", effect.Type)
		end
	end
end

-- Generic timed scalar approach:
-- For each attribute, keep base stored separately if needed,
-- or accumulate bonuses in a composite attribute (e.g., GrowthRateBonusAccum).
-- Here we do a simplistic stacking with timeouts.

function FoodEffects.applyTimedScalar(slime, attrName, amount, duration)
	if not slime or not slime.Parent then return end
	local listAttr = attrName .. "_Buffs" -- store JSON list or just reapply stacking
	local buffs = slime:GetAttribute(listAttr)
	-- Basic representation: a serialized string we ignore, or skip for brevity
	-- For this example, we’ll just stack into an aggregate attribute
	local aggregateName = attrName .. "_Aggregate"
	local current = slime:GetAttribute(aggregateName) or 0
	slime:SetAttribute(aggregateName, current + amount)

	task.delay(duration, function()
		if slime.Parent then
			local cur = slime:GetAttribute(aggregateName) or 0
			slime:SetAttribute(aggregateName, math.max(0, cur - amount))
		end
	end)
end

return FoodEffects