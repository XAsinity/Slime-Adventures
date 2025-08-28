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

-- Helper: skip destroying server-restored / explicitly preserved assets
local function shouldSkipDestroy(inst)
	if not inst or not inst:IsA("Instance") then return false end
	if not inst.GetAttribute then return false end

	-- Honor explicit preservation flags set by GrandInventorySerializer
	if inst:GetAttribute("PreserveOnServer")
		or inst:GetAttribute("PreserveOnClient")
		or inst:GetAttribute("ServerRestore")
		or inst:GetAttribute("ServerIssued")
		or inst:GetAttribute("PersistentFoodTool")
		or inst:GetAttribute("PersistentCaptured") then
		return true
	end

	-- Honor recent restore stamp (avoid race during client/server init)
	local stamp = inst:GetAttribute("RestoreStamp")
	if type(stamp) == "number" then
		local graceSeconds = CONFIG.GraceSecondsPostLeave or 5
		-- use tick() which matches typical Roblox epoch timestamps
		if tick() - stamp <= graceSeconds then
			return true
		end
	end

	return false
end

-- Helper: detect preserved attributes anywhere inside the model (child parts/tools)
local function modelHasPreservedDescendant(model)
	for _,child in ipairs(model:GetDescendants()) do
		if shouldSkipDestroy(child) then
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
				-- skip if model or any descendant is marked to be preserved/restored recently
				if shouldSkipDestroy(desc) or modelHasPreservedDescendant(desc) then
					dprint(("[WorldAssetCleanup] Skipping destroy for preserved/restored model: %s (Owner=%s)"):format(desc:GetFullName(), tostring(userId)))
				else
					print("[WorldAssetCleanup][DestroyTrace] Destroying model:", desc.Name, "FullName:", desc:GetFullName())
					for _,attr in ipairs(CONFIG.DestroyIfHasAttributes) do
						print("  ", attr, "=", tostring(desc:GetAttribute(attr)))
					end
					print(debug.traceback())
					local ok = pcall(function() desc:Destroy() end)
					if ok then destroyed += 1 end
				end
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