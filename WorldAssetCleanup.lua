-- WorldAssetCleanup.lua (revised version)

local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")

local WorldAssetCleanup = {}

local CONFIG = {
	DestroyOnLeave        = true,
	Debug                 = true,
	FinalDelayAfterLeave  = 0.08,
	GraceSecondsPostLeave = 2.5,
	DestroyKinds = {
		Egg   = true,
		Slime = true,
	},
	DestroyIfHasAttributes = { "EggId", "SlimeId", "Placed" },
	PreserveAttributes = {
		"PreserveOnServer",
		"PreserveOnClient",
		"ServerRestore",
		"ServerIssued",
		"PersistentFoodTool",
		"PersistentCaptured",
	},
}

local function dprint(...)
	if CONFIG.Debug then print("[WorldAssetCleanup]", ...) end
end

local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function isExplicitlyPreserved(inst)
	for _,attr in ipairs(CONFIG.PreserveAttributes) do
		local v = safeGetAttr(inst, attr)
		if v then return true, attr end
	end
	return false, nil
end

local function shouldDestroy(model)
	if not model or not model.Name then return false end
	if CONFIG.DestroyKinds[model.Name] then return true end
	for _,attr in ipairs(CONFIG.DestroyIfHasAttributes) do
		if safeGetAttr(model, attr) ~= nil then
			return true
		end
	end
	return false
end

-- Find the plot folder assigned to userId
local function findPlayerPlot(userId)
	local plotName = "Player" .. tostring(userId)
	local plot = Workspace:FindFirstChild(plotName)
	if plot and plot:IsA("Model") then return plot end
	-- Try alternative: scan for plot models with correct attribute
	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj:IsA("Model") and (safeGetAttr(obj, "UserId") or safeGetAttr(obj, "OwnerUserId")) == userId then
			return obj
		end
	end
	return nil
end

-- Only destroy models for the leaving player's userId on their plot after a grace window.
local function destroyOwnedModelsOnPlot(userId)
	local destroyed, skipped = 0, 0
	local plot = findPlayerPlot(userId)
	if not plot then
		dprint(("No plot found for userId=%s; skipping cleanup"):format(tostring(userId)))
		return destroyed, skipped
	end
	for _,desc in ipairs(plot:GetDescendants()) do
		if desc:IsA("Model") then
			local owner = safeGetAttr(desc, "OwnerUserId")
			if owner and tostring(owner) == tostring(userId) and shouldDestroy(desc) then
				local preserved, attr = isExplicitlyPreserved(desc)
				if preserved then
					dprint(("Skipping preserved model: %s (Owner=%s, Reason=%s)")
						:format(desc:GetFullName(), tostring(userId), tostring(attr)))
					skipped = skipped + 1
				else
					dprint(("Destroying model: %s (Owner=%s)")
						:format(desc:GetFullName(), tostring(userId)))
					local ok = pcall(function() desc:Destroy() end)
					if ok then destroyed = destroyed + 1
					else dprint(("Failed to destroy model: %s"):format(desc:GetFullName())) end
				end
			end
		end
	end
	dprint(("Destroyed %d models, skipped %d for userId=%s on plot")
		:format(destroyed, skipped, tostring(userId)))
	return destroyed, skipped
end

local cleanupQueue = {}

local function scheduleCleanupForUser(userId)
	if cleanupQueue[userId] then return end
	cleanupQueue[userId] = true

	task.spawn(function()
		task.wait(CONFIG.FinalDelayAfterLeave)
		task.wait(CONFIG.GraceSecondsPostLeave)

		dprint(("Running cleanup for userId=%s"):format(tostring(userId)))
		destroyOwnedModelsOnPlot(userId)

		cleanupQueue[userId] = nil
	end)
end

function WorldAssetCleanup.ScheduleCleanup(userId)
	scheduleCleanupForUser(userId)
end

function WorldAssetCleanup.ForceCleanupUser(userId)
	dprint(("ForceCleanupUser invoked for userId=%s"):format(tostring(userId)))
	task.spawn(function()
		destroyOwnedModelsOnPlot(userId)
	end)
end

function WorldAssetCleanup.Init()
	if not CONFIG.DestroyOnLeave then
		dprint("DestroyOnLeave disabled."); return
	end

	Players.PlayerRemoving:Connect(function(player)
		if not player or not player.UserId then return end
		local uid = player.UserId
		dprint(("PlayerRemoving: queued cleanup for userId=%s"):format(tostring(uid)))
		scheduleCleanupForUser(uid)
	end)

	-- On shutdown: best-effort cleanup for online players
	game:BindToClose(function()
		dprint("BindToClose: running final cleanup for online players (best-effort)")
		for _,plr in ipairs(Players:GetPlayers()) do
			local uid = plr and plr.UserId
			if uid then
				task.wait(math.min(0.1, CONFIG.GraceSecondsPostLeave))
				destroyOwnedModelsOnPlot(uid)
			end
		end
	end)

	dprint("Initialized (DestroyOnLeave="..tostring(CONFIG.DestroyOnLeave)..", FinalDelay="..tostring(CONFIG.FinalDelayAfterLeave)..", Grace="..tostring(CONFIG.GraceSecondsPostLeave)..")")
end

WorldAssetCleanup._internal = {
	config = CONFIG,
	_schedule = scheduleCleanupForUser,
	_destroy = destroyOwnedModelsOnPlot,
	_findPlot = findPlayerPlot,
}

return WorldAssetCleanup