local ServerStorage = game:GetService("ServerStorage")
local RunService    = game:GetService("RunService")
local HttpService   = game:GetService("HttpService")

local StagedToolManager = {}
StagedToolManager.__index = StagedToolManager

-- Config
local DEFAULT_STAGE_TIME     = 0.20   -- how long to keep in ServerStorage before first move
local DEFAULT_FINAL_DELAY    = 2.00   -- extra delay for post-restore audit / client init
local ABANDONED_CLEANUP_SECS = 60     -- remove staged items left too long

local staged = setmetatable({}, { __mode = "k" }) -- weak-keyed by tool
-- staged[tool] = { target = parent, stagedAt = tick(), ids = {...}, timers = {...} }

local function now() return tick() end

local function mark(tool, meta)
	staged[tool] = meta
	if tool and tool.SetAttribute then
		pcall(function()
			tool:SetAttribute("StagedByManager", true)
			tool:SetAttribute("StagedAt", meta.stagedAt)
		end)
	end
end

local function unmark(tool)
	if tool and tool.SetAttribute then
		pcall(function()
			tool:SetAttribute("StagedByManager", nil)
			tool:SetAttribute("StagedAt", nil)
		end)
	end
	staged[tool] = nil
end

-- Internal cleanup loop (periodic)
task.spawn(function()
	while true do
		local t0 = now()
		for tool,meta in pairs(staged) do
			if not tool or not tool.Parent then
				staged[tool] = nil
			else
				local age = t0 - (meta.stagedAt or 0)
				if age > ABANDONED_CLEANUP_SECS then
					pcall(function() tool:Destroy() end)
					staged[tool] = nil
				end
			end
		end
		task.wait(ABANDONED_CLEANUP_SECS/2)
	end
end)

-- Stage a tool into ServerStorage and schedule moving it into 'finalParent'.
-- tool : Instance (Tool)
-- finalParent : Instance (e.g. player Backpack)
-- opts : table { stageTime=number, finalDelay=number, batchId=string }
function StagedToolManager.StageThenMove(tool, finalParent, opts)
	if not tool or not tool.Parent or not finalParent then return false end
	opts = opts or {}
	local stageTime  = (type(opts.stageTime)=="number") and opts.stageTime or DEFAULT_STAGE_TIME
	local finalDelay = (type(opts.finalDelay)=="number") and opts.finalDelay or DEFAULT_FINAL_DELAY
	local meta = {
		target = finalParent,
		stagedAt = now(),
		stageTime = stageTime,
		finalDelay = finalDelay,
		batchId = opts.batchId or ("batch-"..HttpService:GenerateGUID(false)),
	}
	-- tag for external inspection
	pcall(function() tool:SetAttribute("RestoreBatchId", meta.batchId) end)
	pcall(function() tool:SetAttribute("StagedByManager", true) end)
	pcall(function() tool:SetAttribute("StagedAt", meta.stagedAt) end)

	-- move to ServerStorage immediately (best-effort)
	local ok, err = pcall(function() tool.Parent = ServerStorage end)
	if not ok then
		warn("[StagedToolManager] Failed to parent to ServerStorage:", err)
		return false
	end
	mark(tool, meta)

	-- Schedule initial move after stageTime
	task.delay(stageTime, function()
		-- abort if finalParent no longer exists in DataModel
		if not finalParent or not finalParent.Parent then return end
		if tool and tool.Parent ~= finalParent then
			pcall(function() tool.Parent = finalParent end)
		end
	end)

	-- Schedule a final re-parent+audit after finalDelay
	task.delay(math.max(stageTime, finalDelay), function()
		if not finalParent or not finalParent.Parent then
			-- finalParent removed (player left?) keep tool in ServerStorage for cleanup loop
			return
		end
		if tool and tool.Parent ~= finalParent then
			pcall(function() tool.Parent = finalParent end)
		end
		-- clear staging marks (we leave batch id if you want it)
		unmark(tool)
	end)

	return true
end

-- Convenience: immediate move (bypass staging)
function StagedToolManager.MoveImmediate(tool, finalParent)
	if not tool or not finalParent then return false end
	local ok = pcall(function() tool.Parent = finalParent end)
	if ok then unmark(tool) end
	return ok
end

-- Clean a specific staged tool early (destroys it)
function StagedToolManager.DestroyStaged(tool)
	if not tool then return false end
	unmark(tool)
	return pcall(function() tool:Destroy() end)
end

return StagedToolManager