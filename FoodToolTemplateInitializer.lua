-- Recursive initializer with optional name->FoodId mapping.

local RS = game:GetService("ReplicatedStorage")
local folder = RS:FindFirstChild("FoodTemplates")
if not folder then
	warn("[FoodToolTemplateInitializer] FoodTemplates folder missing")
	return
end

-- Map legacy tool names to canonical FoodId (add more as needed)
local NAME_MAP = {
	BasicFoodTool = "BasicFood",
}

local function processTool(tool)
	-- Set FoodItem
	if not tool:GetAttribute("FoodItem") then
		tool:SetAttribute("FoodItem", true)
	end
	-- Assign / correct FoodId
	local mapped = NAME_MAP[tool.Name]
	if mapped then
		tool:SetAttribute("FoodId", mapped)
	elseif not tool:GetAttribute("FoodId") then
		-- If parent folder corresponds to a definition you can add that logic here; simple fallback:
		tool:SetAttribute("FoodId", tool.Name)
	end
	-- Baseline charges
	if tool:GetAttribute("Charges") == nil then
		tool:SetAttribute("Charges", 1)
	end
end

local function recurse(container)
	for _,inst in ipairs(container:GetChildren()) do
		if inst:IsA("Tool") then
			processTool(inst)
		elseif inst:IsA("Folder") then
			recurse(inst)
		end
	end
end

recurse(folder)
print("[FoodToolTemplateInitializer] Initialization complete")