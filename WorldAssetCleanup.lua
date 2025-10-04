-- WorldAssetCleanup.lua (revised version)

local Workspace = game:GetService("Workspace")
local Players   = game:GetService("Players")

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
local function findPlayerPlotByAttributes(userId)
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

local function resolvePlotForUser(userId, hint)
	if hint and hint.Parent then
		return hint
	end
	return findPlayerPlotByAttributes(userId)
end

local function cleanupOwnedInstancesIn(container, userId)
	if not container then return 0, 0 end
	local destroyed, skipped = 0, 0
	for _, desc in ipairs(container:GetDescendants()) do
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
					if ok then destroyed = destroyed + 1 else skipped = skipped + 1 end
				end
			end
		elseif desc:IsA("BasePart") then
			local owner = safeGetAttr(desc, "OwnerUserId")
			if owner and tostring(owner) == tostring(userId) then
				local ancestorModel = desc:FindFirstAncestorWhichIsA("Model")
				if ancestorModel and safeGetAttr(ancestorModel, "OwnerUserId") == owner and shouldDestroy(ancestorModel) then
					-- model cleanup will handle this chain
				else
					local preserved, attr = isExplicitlyPreserved(desc)
					if preserved then
						dprint(("Skipping preserved part: %s (Owner=%s, Reason=%s)")
							:format(desc:GetFullName(), tostring(userId), tostring(attr)))
							skipped = skipped + 1
					else
						dprint(("Destroying part: %s (Owner=%s)")
							:format(desc:GetFullName(), tostring(userId)))
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
	dprint(("Destroyed %d instances, skipped %d for userId=%s")
		:format(destroyed, skipped, tostring(userId)))
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
		if plotHint and plotHint.Parent then
			existing.plot = plotHint
		end
		if normalizedOptions then
			existing.options = normalizedOptions
		end
		return
	end
	cleanupQueue[userId] = {
		plot = plotHint and plotHint.Parent and plotHint or nil,
		options = normalizedOptions or normalizeOptions(nil),
	}

	task.spawn(function()
		task.wait(CONFIG.FinalDelayAfterLeave)
		task.wait(CONFIG.GraceSecondsPostLeave)

		dprint(("Running cleanup for userId=%s"):format(tostring(userId)))
		local entry = cleanupQueue[userId]
		cleanupQueue[userId] = nil
		if not entry then return end
		destroyOwnedModelsOnPlot(userId, entry.plot, entry.options)
	end)
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
	_findPlot = findPlayerPlotByAttributes,
	_cleanupContainer = cleanupOwnedInstancesIn,
}

return WorldAssetCleanup