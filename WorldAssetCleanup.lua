-- WorldAssetCleanup.lua
-- Fully updated module: respects RecentlyPlacedSaved attribute, listens for PreExitInventorySaved bindable
-- and avoids destroying newly-saved items. Robust, defensive, and Studio-friendly logging.

local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")

local WorldAssetCleanup = {}

local CONFIG = {
	DestroyOnLeave        = true,
	Debug                 = true,
	FinalDelayAfterLeave  = 0.08,
	GraceSecondsPostLeave = 2.5,
	IncludeNeutralOnLeave = false,
	NeutralFolderName     = "Slimes",
	NeutralPerPlayerSubfolders = true,
	DestroyKinds = {
		Egg   = true,
		Slime = true,
	},
	DestroyIfHasAttributes = { "EggId", "SlimeId", "Placed" },
	-- Attributes that preserve an instance from cleanup. "RecentlyPlacedSaved" is checked for recency.
	PreserveAttributes = {
		"PreserveOnServer",
		"PreserveOnClient",
		"ServerRestore",
		"ServerIssued",
		"PersistentFoodTool",
		"PersistentCaptured",
		"RecentlyPlacedSaved",
	},
	-- A small safety margin to consider RecentlyPlacedSaved fresh
	RecentlyPlacedSavedMargin = 1.0, -- seconds, added to GraceSecondsPostLeave for tolerance
}

local function dprint(...)
	if CONFIG.Debug then
		-- indicate the module name and whether running in Studio for easier logs
		local studioTag = RunService:IsStudio() and "Studio" or "Server"
		print(string.format("[WorldAssetCleanup][%s]", studioTag), ...)
	end
end

local function normalizeOptions(options)
	local opts = {}
	if type(options) == "table" then
		for k, v in pairs(options) do
			opts[k] = v
		end
	end
	if opts.neutral == nil then
		opts.neutral = CONFIG.IncludeNeutralOnLeave
	end
	if opts.neutralFolderName == nil then
		opts.neutralFolderName = CONFIG.NeutralFolderName
	end
	if opts.neutralPerPlayerSubfolders == nil then
		opts.neutralPerPlayerSubfolders = CONFIG.NeutralPerPlayerSubfolders
	end
	return opts
end

local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

-- Helper: robust Instance check (uses typeof when available)
local function isInstance(v)
	local ok, t = pcall(function() return typeof(v) end)
	if ok and t == "Instance" then
		return true
	end
	-- Fallback: in an unlikely environment without typeof, use heuristics
	return type(v) == "userdata"
end

-- Determine if an instance is explicitly preserved.
-- Special-case: RecentlyPlacedSaved must be a numeric tick() value and within graceful age.
local function isExplicitlyPreserved(inst)
	if not inst then return false, nil end
	for _, attr in ipairs(CONFIG.PreserveAttributes) do
		local v = safeGetAttr(inst, attr)
		if v ~= nil then
			if attr == "RecentlyPlacedSaved" then
				-- Expect tick() (number)
				local n = tonumber(v)
				if n then
					local age = tick() - n
					local threshold = (CONFIG.GraceSecondsPostLeave or 0) + (CONFIG.RecentlyPlacedSavedMargin or 0)
					if age < threshold then
						return true, attr
					else
						-- stale stamp: do not treat as preserved
					end
				else
					-- Non-numeric RecentlyPlacedSaved - be conservative and treat as preserved
					return true, attr
				end
			else
				-- For boolean attributes prefer explicit true; but if attribute exists and isn't false, treat as preserved
				if type(v) == "boolean" then
					if v == true then
						return true, attr
					else
						-- explicit false -> do not preserve on this attribute
					end
				else
					-- non-boolean presence -> preserve
					return true, attr
				end
			end
		end
	end
	return false, nil
end

local function shouldDestroy(model)
	if not model or not model.Name then return false end
	if CONFIG.DestroyKinds[model.Name] then return true end
	for _, attr in ipairs(CONFIG.DestroyIfHasAttributes) do
		if safeGetAttr(model, attr) ~= nil then
			return true
		end
	end
	return false
end

-- Find the plot folder assigned to userId.
-- This function attempts a few heuristics: Player{index} naming, attributes on Models.
local function findPlayerPlotByAttributes(userId)
	if not userId then return nil end
	-- If userId is a number, test Player{userId} naming quickly
	local okNamePlot
	pcall(function()
		local plotName = "Player" .. tostring(userId)
		local plot = Workspace:FindFirstChild(plotName)
		if plot and plot:IsA("Model") then
			okNamePlot = plot
		end
	end)
	if okNamePlot then return okNamePlot end

	-- Fallback: scan children for models with UserId/OwnerUserId/AssignedUserId attributes matching userId
	for _, obj in ipairs(Workspace:GetChildren()) do
		if obj and obj:IsA("Model") then
			local ok, val = pcall(function()
				return obj:GetAttribute("UserId") or obj:GetAttribute("OwnerUserId") or obj:GetAttribute("AssignedUserId") or obj:GetAttribute("PersistentId")
			end)
			if ok and val and tostring(val) == tostring(userId) then
				return obj
			end
		end
	end
	return nil
end

local function resolvePlotForUser(userId, hint)
	if hint and isInstance(hint) and hint.Parent then
		return hint
	end
	return findPlayerPlotByAttributes(userId)
end

local function cleanupOwnedInstancesIn(container, userId)
	if not container or not userId then return 0, 0 end
	local destroyed, skipped = 0, 0
	for _, desc in ipairs(container:GetDescendants()) do
		-- handle Models
		if desc:IsA("Model") then
			local okOwner, owner = pcall(function() return safeGetAttr(desc, "OwnerUserId") or safeGetAttr(desc, "UserId") or safeGetAttr(desc, "AssignedUserId") end)
			if okOwner and owner and tostring(owner) == tostring(userId) and shouldDestroy(desc) then
				local preserved, reason = isExplicitlyPreserved(desc)
				if preserved then
					dprint(("Skipping preserved model: %s (Owner=%s, Reason=%s)"):format(desc:GetFullName(), tostring(userId), tostring(reason)))
					skipped = skipped + 1
				else
					dprint(("Destroying model: %s (Owner=%s)"):format(desc:GetFullName(), tostring(userId)))
					local ok = pcall(function() desc:Destroy() end)
					if ok then destroyed = destroyed + 1 else skipped = skipped + 1 end
				end
			end

			-- handle loose parts (not under a Model) - only destroy if owner attr present and not covered by model
		elseif desc:IsA("BasePart") then
			local okOwner, owner = pcall(function() return safeGetAttr(desc, "OwnerUserId") or safeGetAttr(desc, "UserId") end)
			if okOwner and owner and tostring(owner) == tostring(userId) then
				local ancestorModel = desc:FindFirstAncestorWhichIsA("Model")
				local coveredByModel = false
				if ancestorModel then
					local okAncOwner, ancOwner = pcall(function() return safeGetAttr(ancestorModel, "OwnerUserId") or safeGetAttr(ancestorModel, "UserId") end)
					if okAncOwner and ancOwner and tostring(ancOwner) == tostring(owner) and shouldDestroy(ancestorModel) then
						coveredByModel = true
					end
				end
				if coveredByModel then
					-- model cleanup will remove ancestor
				else
					local preserved, reason = isExplicitlyPreserved(desc)
					if preserved then
						dprint(("Skipping preserved part: %s (Owner=%s, Reason=%s)"):format(desc:GetFullName(), tostring(userId), tostring(reason)))
						skipped = skipped + 1
					else
						dprint(("Destroying part: %s (Owner=%s)"):format(desc:GetFullName(), tostring(userId)))
						local ok = pcall(function() desc:Destroy() end)
						if ok then destroyed = destroyed + 1 else skipped = skipped + 1 end
					end
				end
			end
		end
	end
	return destroyed, skipped
end

local function destroyOwnedModelsOnPlot(userId, plot, options)
	local opts = normalizeOptions(options)
	local destroyed, skipped = 0, 0
	local targetPlot = resolvePlotForUser(userId, plot)
	if targetPlot then
		local d, s = cleanupOwnedInstancesIn(targetPlot, userId)
		destroyed = destroyed + d
		skipped = skipped + s
	else
		dprint(("No plot found for userId=%s; skipping plot cleanup"):format(tostring(userId)))
	end

	if opts.neutral then
		local root = Workspace:FindFirstChild(opts.neutralFolderName)
		if root then
			if opts.neutralPerPlayerSubfolders then
				for _, sub in ipairs(root:GetChildren()) do
					if sub:IsA("Folder") then
						local d, s = cleanupOwnedInstancesIn(sub, userId)
						destroyed = destroyed + d
						skipped = skipped + s
					end
				end
			else
				local d, s = cleanupOwnedInstancesIn(root, userId)
				destroyed = destroyed + d
				skipped = skipped + s
			end
		end
	end

	dprint(("Destroyed %d instances, skipped %d for userId=%s"):format(destroyed, skipped, tostring(userId)))
	return destroyed, skipped
end

local cleanupQueue = {}

local function scheduleCleanupForUser(userId, plotHint, options)
	if not userId then return end
	if not plotHint then
		plotHint = findPlayerPlotByAttributes(userId)
	end
	local normalizedOptions = options ~= nil and normalizeOptions(options) or nil
	local existing = cleanupQueue[userId]
	if existing then
		if plotHint and isInstance(plotHint) and plotHint.Parent then
			existing.plot = plotHint
		end
		if normalizedOptions then
			existing.options = normalizedOptions
		end
		return
	end
	cleanupQueue[userId] = {
		plot = (plotHint and isInstance(plotHint) and plotHint.Parent) and plotHint or nil,
		options = normalizedOptions or normalizeOptions(nil),
	}

	task.spawn(function()
		-- initial small delay (allow leave handlers to start)
		task.wait(CONFIG.FinalDelayAfterLeave or 0.08)
		-- grace window after leave before cleanup
		task.wait(CONFIG.GraceSecondsPostLeave or 2.5)

		dprint(("Running cleanup for userId=%s"):format(tostring(userId)))
		local entry = cleanupQueue[userId]
		cleanupQueue[userId] = nil
		if not entry then return end
		destroyOwnedModelsOnPlot(userId, entry.plot, entry.options)
	end)
end

local function cancelScheduledCleanup(userId)
	if cleanupQueue[userId] then
		cleanupQueue[userId] = nil
		dprint(("Cancelled scheduled cleanup for userId=%s"):format(tostring(userId)))
	end
end

function WorldAssetCleanup.ScheduleCleanup(userId, plotHint, options)
	scheduleCleanupForUser(userId, plotHint, options)
end

function WorldAssetCleanup.ForceCleanupUser(userId, options, plotHint)
	dprint(("ForceCleanupUser invoked for userId=%s"):format(tostring(userId)))
	task.spawn(function()
		destroyOwnedModelsOnPlot(userId, plotHint, options)
	end)
end

function WorldAssetCleanup.CleanupPlot(plot, userId, options)
	return destroyOwnedModelsOnPlot(userId, plot, options)
end

function WorldAssetCleanup.Configure(options)
	if type(options) ~= "table" then return end
	if options.DestroyOnLeave ~= nil then
		CONFIG.DestroyOnLeave = options.DestroyOnLeave and true or false
	end
	if options.Debug ~= nil then
		CONFIG.Debug = options.Debug and true or false
	end
	if options.FinalDelayAfterLeave ~= nil then
		local v = tonumber(options.FinalDelayAfterLeave)
		if v then CONFIG.FinalDelayAfterLeave = math.max(0, v) end
	end
	if options.GraceSecondsPostLeave ~= nil then
		local v = tonumber(options.GraceSecondsPostLeave)
		if v then CONFIG.GraceSecondsPostLeave = math.max(0, v) end
	end
	if options.IncludeNeutralOnLeave ~= nil then
		CONFIG.IncludeNeutralOnLeave = options.IncludeNeutralOnLeave and true or false
	end
	if options.NeutralFolderName ~= nil then
		CONFIG.NeutralFolderName = tostring(options.NeutralFolderName)
	end
	if options.NeutralPerPlayerSubfolders ~= nil then
		CONFIG.NeutralPerPlayerSubfolders = options.NeutralPerPlayerSubfolders and true or false
	end
	if options.DestroyKinds and type(options.DestroyKinds) == "table" then
		for k, v in pairs(options.DestroyKinds) do
			CONFIG.DestroyKinds[k] = v and true or nil
		end
	end
	if options.DestroyIfHasAttributes and type(options.DestroyIfHasAttributes) == "table" then
		CONFIG.DestroyIfHasAttributes = options.DestroyIfHasAttributes
	end
	if options.PreserveAttributes and type(options.PreserveAttributes) == "table" then
		CONFIG.PreserveAttributes = options.PreserveAttributes
	end
end

-- Initialize: hook PlayerRemoving and try to connect to PreExitInventorySaved bindable (if present).
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

	-- Try to connect to a BindableEvent named "PreExitInventorySaved" under ServerScriptService.Modules
	-- If fired with (userId, savedFlag) and savedFlag==true, we cancel scheduled cleanup and run cleanup
	-- after a tiny delay so RecentlyPlacedSaved attributes applied by PreExitInventorySync are visible.
	local function tryConnectPreExitSaved()
		local ok, modulesFolder = pcall(function() return ServerScriptService:FindFirstChild("Modules") end)
		if not ok or not modulesFolder then
			return false
		end
		local be = modulesFolder:FindFirstChild("PreExitInventorySaved")
		if be and be:IsA("BindableEvent") and be.Event then
			-- Connect only once (safe to connect multiple times; duplicate connections are harmless but avoid spam)
			be.Event:Connect(function(userId, savedFlag)
				if not userId then return end
				dprint(("PreExitInventorySaved fired for userId=%s saved=%s"):format(tostring(userId), tostring(savedFlag)))
				-- Cancel any scheduled delayed cleanup and run now (post-finalization)
				cancelScheduledCleanup(userId)
				-- Small delay to allow PreExitInventorySync to set RecentlyPlacedSaved attributes
				task.spawn(function()
					task.wait(0.02)
					-- Run cleanup now (fire-and-forget)
					pcall(function()
						destroyOwnedModelsOnPlot(userId)
					end)
				end)
			end)
			dprint("Connected to PreExitInventorySaved bindable (ServerScriptService.Modules.PreExitInventorySaved)")
			return true
		end
		return false
	end

	-- Attempt immediate connection, and attempt again shortly after in case Modules folder or bindable is created later.
	local connected = false
	pcall(function() connected = tryConnectPreExitSaved() end)
	if not connected then
		-- schedule retries for short interval, then stop
		task.spawn(function()
			local tries = 3
			for i = 1, tries do
				task.wait(0.25 * i)
				local ok = pcall(function() return tryConnectPreExitSaved() end)
				if ok then break end
			end
		end)
	end

	-- BindToClose: best-effort cleanup for online players
	pcall(function()
		game:BindToClose(function()
			dprint("BindToClose: running final cleanup for online players (best-effort)")
			for _, plr in ipairs(Players:GetPlayers()) do
				local uid = plr and plr.UserId
				if uid then
					task.wait(math.min(0.1, CONFIG.GraceSecondsPostLeave or 2.5))
					pcall(function() destroyOwnedModelsOnPlot(uid) end)
				end
			end
		end)
	end)

	dprint("Initialized (DestroyOnLeave="..tostring(CONFIG.DestroyOnLeave)..", FinalDelay="..tostring(CONFIG.FinalDelayAfterLeave)..", Grace="..tostring(CONFIG.GraceSecondsPostLeave)..")")
end

WorldAssetCleanup._internal = {
	config = CONFIG,
	_schedule = scheduleCleanupForUser,
	_cancel = cancelScheduledCleanup,
	_destroy = destroyOwnedModelsOnPlot,
	_findPlot = findPlayerPlotByAttributes,
	_cleanupContainer = cleanupOwnedInstancesIn,
}

return WorldAssetCleanup