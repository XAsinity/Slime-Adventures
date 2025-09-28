-- StagedToolManager.lua
-- Staging/rehoming helper for Tools with safe removal instrumentation.
-- Includes a safeRemoveTool wrapper that logs attributes and stacktraces and avoids destroying preserved/restored tools.
-- Patch 2025-09-16: avoid unnecessary staging for already-restored/host-parented tools,
--                 ensure we don't move tools that already live in the finalParent or that are
--                 marked ServerRestore (they are being restored by other systems).
--                 This prevents transient detach/reparent races that left tools parentless.

local ServerStorage = game:GetService("ServerStorage")
local RunService    = game:GetService("RunService")
local HttpService   = game:GetService("HttpService")
local Players       = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local StagedToolManager = {}
StagedToolManager.__index = StagedToolManager

-- Optionally require InventoryService if present in ServerScriptService.Modules
local InventoryService = nil
pcall(function()
	local modules = ServerScriptService:FindFirstChild("Modules")
	if modules and modules:FindFirstChild("InventoryService") then
		InventoryService = require(modules:FindFirstChild("InventoryService"))
	end
end)

-- Safe helpers
local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function safeFullName(inst)
	if not inst then return "<nil>" end
	local ok, s = pcall(function() return inst:GetFullName() end)
	if ok and type(s) == "string" then return s end
	local ok2, n = pcall(function() return inst.Name end)
	if ok2 and type(n) == "string" then return tostring(n) end
	return "<unknown>"
end

local function safeName(inst)
	if not inst then return "<nil>" end
	local ok, n = pcall(function() return inst.Name end)
	if ok and type(n) == "string" then return tostring(n) end
	return "<unknown>"
end

local function inspectToolAttrs(tool)
	local keys = {
		"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","OwnerUserId",
		"SlimeId","SlimeItem","FoodId","PersistentCaptured","PersistentFoodTool",
		"RestoreStamp","RecentlyPlacedSaved","StagedByManager","StagedAt","RestoreBatchId","_RestoreGuard_Attempts"
	}
	local out = {}
	for _,k in ipairs(keys) do
		local ok, v = pcall(function() return tool:GetAttribute(k) end)
		if ok then out[k] = v end
	end
	return out
end

local function safeRemoveTool(tool, reason)
	-- defensive checks
	if not tool or (typeof and typeof(tool) ~= "Instance") then
		warn(("[safeRemoveTool] called with invalid tool: %s reason=%s"):format(tostring(tool), tostring(reason)))
		return false
	end

	-- build a safe fullName string
	local fullName = safeFullName(tool)

	-- Log attributes and stacktrace before removal
	local attrs = inspectToolAttrs(tool)
	local okJson, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
	local attrsStr = okJson and attrsJson or tostring(attrs)
	warn(("[safeRemoveTool] Removing tool: %s (Full=%s) Reason=%s Attrs=%s"):format(
		tostring(safeName(tool)), fullName, tostring(reason), attrsStr
		))
	warn(debug.traceback("[safeRemoveTool] stack (caller->remove):", 2))

	-- If InventoryService exposes a helper that recognizes preserved/persistent objects, prefer that check
	local preserve = false
	if InventoryService then
		pcall(function()
			if type(InventoryService._looksLikeRestoredOrPersistent) == "function" then
				local ok, res = pcall(function() return InventoryService._looksLikeRestoredOrPersistent(tool) end)
				if ok and res then preserve = true end
			end
		end)
	end
	-- fallback to local attribute checks
	if not preserve then
		local p1 = safeGetAttr(tool, "PreserveOnServer")
		local p2 = safeGetAttr(tool, "ServerRestore")
		if p1 or p2 then preserve = true end
	end

	-- Try non-destructive parent detach first
	local ok, err = pcall(function() tool.Parent = nil end)
	if not ok then
		warn(("[safeRemoveTool] Parent=nil failed for %s err=%s; attempting Destroy()"):format(tostring(safeName(tool)), tostring(err)))
		local ok2, err2 = pcall(function() tool:Destroy() end)
		if not ok2 then
			warn(("[safeRemoveTool] Destroy() failed for %s err=%s"):format(tostring(safeName(tool)), tostring(err2)))
			return false
		end
		return true
	else
		-- Detached successfully; if preserve is set we keep it detached and do not destroy.
		if preserve then
			warn(("[safeRemoveTool] Preserved tool left detached (PreserveOnServer/ServerRestore set): %s"):format(tostring(safeName(tool))))
			return true
		end

		-- Otherwise destroy
		local ok3, err3 = pcall(function() tool:Destroy() end)
		if not ok3 then
			warn(("[safeRemoveTool] Later Destroy() failed for %s err=%s"):format(tostring(safeName(tool)), tostring(err3)))
			return false
		end
		return true
	end
end

-- Config
local DEFAULT_STAGE_TIME     = 0.20   -- how long to keep in ServerStorage before first move
local DEFAULT_FINAL_DELAY    = 2.00   -- extra delay for post-restore audit / client init
local ABANDONED_CLEANUP_SECS = 60     -- remove staged items left too long

-- How long to keep PreserveOnServer/ServerRestore set after final reparent (grace for other systems)
local PRESERVE_GRACE_SECONDS = 6

local staged = setmetatable({}, { __mode = "k" }) -- weak-keyed by tool
-- staged[tool] = { target = parent, stagedAt = tick(), ids = {...}, timers = {...}, batchId = str }

local function now() return tick() end

-- Defensive helper: detect captured-item tools so we can skip destructive/staging ops
local function isCapturedTool(tool)
	if not tool or type(tool.GetAttribute) ~= "function" then return false end
	local ok, v = pcall(function() return tool:GetAttribute("SlimeItem") end)
	if ok and v then return true end
	ok, v = pcall(function() return tool:GetAttribute("SlimeId") end)
	if ok and v then return true end
	-- fallback: ToolUniqueId present often indicates persistence id; don't classify by itself as captured
	return false
end

local function mark(tool, meta)
	staged[tool] = meta
	if tool and tool.SetAttribute then
		pcall(function()
			tool:SetAttribute("StagedByManager", true)
			tool:SetAttribute("StagedAt", meta.stagedAt)
			tool:SetAttribute("RestoreBatchId", meta.batchId)
		end)
	end
end

local function unmark(tool)
	if tool and tool.SetAttribute then
		pcall(function()
			tool:SetAttribute("StagedByManager", nil)
			tool:SetAttribute("StagedAt", nil)
			-- keep RestoreBatchId for history; comment out next line if you want to remove it
			-- tool:SetAttribute("RestoreBatchId", nil)
		end)
	end
	staged[tool] = nil
end

-- Helper: mark preserve attributes so other systems know this is a server-controlled restore/stage.
local function setPreserveAttrs(tool)
	if not tool or type(tool.SetAttribute) ~= "function" then return end
	pcall(function()
		tool:SetAttribute("ServerRestore", true)
		tool:SetAttribute("PreserveOnServer", true)
		tool:SetAttribute("RestoreStamp", tick())
		tool:SetAttribute("RecentlyPlacedSaved", os.time())
	end)
end

-- Helper: clear the preserve flags after a grace window (best-effort)
local function clearPreserveAttrs(tool)
	if not tool or type(tool.SetAttribute) ~= "function" then return end
	pcall(function()
		tool:SetAttribute("PreserveOnServer", nil)
		tool:SetAttribute("ServerRestore", nil)
		tool:SetAttribute("RestoreStamp", nil)
		tool:SetAttribute("RecentlyPlacedSaved", nil)
	end)
end

-- Robust reparent attempt with retry/backoff. Returns true if reparented.
local function tryReparentWithRetry(tool, dest, attempts, baseDelay)
	attempts = attempts or 6
	baseDelay = baseDelay or 0.05
	for i = 1, attempts do
		local ok, err = pcall(function() tool.Parent = dest end)
		if ok then
			return true
		else
			local msg = ("[StagedToolManager] Reparent attempt %d failed for %s -> %s err=%s"):format(
				i,
				tostring(safeName(tool)),
				tostring(safeFullName(dest)),
				tostring(err)
			)
			warn(msg)
			warn(debug.traceback("[StagedToolManager] reparent failure stack:", 2))
			-- short backoff
			task.wait(baseDelay * (1 + (i - 1) * 0.5))
		end
	end
	return false
end

-- Resolve a Player from a container (Backpack, Character, or per-player folder)
local function resolvePlayerFromContainer(container)
	if not container then return nil end
	-- Backpack: parent is player
	if container:IsA("Backpack") then
		for _,pl in ipairs(Players:GetPlayers()) do
			if pl:FindFirstChildOfClass("Backpack") == container then return pl end
		end
	end
	-- Character: GetPlayerFromCharacter
	local ok, playerFromChar = pcall(function() return Players:GetPlayerFromCharacter(container) end)
	if ok and playerFromChar then return playerFromChar end
	-- If container is a Folder under Workspace named by player name, try find player
	local ok2, name = pcall(function() return container.Name end)
	if ok2 and type(name) == "string" then
		local pl = Players:FindFirstChild(name)
		if pl then return pl end
	end
	return nil
end

-- Internal cleanup loop (periodic)
task.spawn(function()
	while true do
		local t0 = now()
		for tool,meta in pairs(staged) do
			-- prune entries for destroyed tools or tools with no parent
			local alive = pcall(function() return tool and tool.Parent ~= nil end)
			if not alive then
				staged[tool] = nil
			else
				local age = t0 - (meta.stagedAt or 0)
				if age > ABANDONED_CLEANUP_SECS then
					-- use safeRemoveTool to log and protect preserved items when appropriate
					pcall(function()
						safeRemoveTool(tool, "ABANDONED_CLEANUP")
					end)
					staged[tool] = nil
				end
			end
		end
		task.wait(math.max(1, ABANDONED_CLEANUP_SECS/2))
	end
end)

-- Stage a tool into ServerStorage and schedule moving it into 'finalParent'.
-- Important behavioral fixes:
--  - If the tool is already parented to finalParent, we do NOT move it to ServerStorage.
--    We simply set preserve attrs and run the final audit logic. This avoids a detach cycle
--    that previously left restored tools parentless.
--  - If the tool already has ServerRestore==true (it is being restored by another system),
--    we avoid moving it to ServerStorage and instead treat it as a "no-op stage" with
--    preserve attrs and final audit scheduling.
-- tool : Instance (Tool)
-- finalParent : Instance (e.g. player Backpack)
-- opts : table { stageTime=number, finalDelay=number, batchId=string }
function StagedToolManager.StageThenMove(tool, finalParent, opts)
	-- Don't touch captured tools: staging/reparenting them can trigger other systems to wipe attributes.
	if isCapturedTool(tool) then
		warn(("[StagedToolManager] Skipping StageThenMove for captured tool: %s"):format(safeFullName(tool)))
		return true
	end

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

	-- If the tool is already in the desired finalParent, avoid moving it at all.
	-- This prevents a detach/reparent dance which was observed to leave items parentless.
	if tool.Parent == finalParent then
		-- tag for visibility
		pcall(function() tool:SetAttribute("RestoreBatchId", meta.batchId) end)
		-- Ensure other systems see it as server-restored / preserved during the audit window.
		setPreserveAttrs(tool)

		-- run the same final-audit logic (inventory entry ensure + preserve clear scheduling)
		mark(tool, meta)
		-- schedule inventory integration and preserve-clear after finalDelay
		task.delay(math.max(stageTime, finalDelay), function()
			-- no reparent needed; just run the post-restore integrations
			unmark(tool)
			pcall(function()
				local uid = nil
				if type(tool.GetAttribute) == "function" then
					local ok, v = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
					if ok then uid = v end
				end
				if InventoryService and uid and finalParent then
					local player = resolvePlayerFromContainer(finalParent)
					if player and type(InventoryService.EnsureEntryHasId) == "function" then
						pcall(function()
							InventoryService.EnsureEntryHasId(player, "foodTools", uid, { ToolUniqueId = uid, FoodId = safeGetAttr(tool, "FoodId") })
						end)
						pcall(function() InventoryService.UpdateProfileInventory(player) end)
					end
				end
			end)
			-- clear preserve flags after grace window (best-effort)
			task.delay(PRESERVE_GRACE_SECONDS, function()
				local stillWithOwner = pcall(function() return tool and tool.Parent == finalParent end)
				if stillWithOwner then
					clearPreserveAttrs(tool)
				end
			end)
		end)

		return true
	end

	-- If tool already marked ServerRestore, it's probably being restored by another flow.
	-- Avoid removing it into ServerStorage; keep it where it is and run the "post-final" flow instead.
	if safeGetAttr(tool, "ServerRestore") then
		pcall(function() tool:SetAttribute("RestoreBatchId", meta.batchId) end)
		setPreserveAttrs(tool)
		mark(tool, meta)
		task.delay(math.max(stageTime, finalDelay), function()
			unmark(tool)
			pcall(function()
				local uid = nil
				if type(tool.GetAttribute) == "function" then
					local ok, v = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
					if ok then uid = v end
				end
				if InventoryService and uid and finalParent then
					local player = resolvePlayerFromContainer(finalParent)
					if player and type(InventoryService.EnsureEntryHasId) == "function" then
						pcall(function()
							InventoryService.EnsureEntryHasId(player, "foodTools", uid, { ToolUniqueId = uid, FoodId = safeGetAttr(tool, "FoodId") })
						end)
						pcall(function() InventoryService.UpdateProfileInventory(player) end)
					end
				end
			end)
			task.delay(PRESERVE_GRACE_SECONDS, function()
				local stillWithOwner = pcall(function() return tool and tool.Parent == finalParent end)
				if stillWithOwner then
					clearPreserveAttrs(tool)
				end
			end)
		end)
		return true
	end

	-- Normal staging flow: protect and move to ServerStorage, then later move to finalParent.
	-- tag for external inspection
	pcall(function() tool:SetAttribute("RestoreBatchId", meta.batchId) end)
	pcall(function() tool:SetAttribute("StagedByManager", true) end)
	pcall(function() tool:SetAttribute("StagedAt", meta.stagedAt) end)

	-- Protect the tool immediately so other cleanup flows skip it while in transit
	setPreserveAttrs(tool)

	-- move to ServerStorage immediately (best-effort) using retry/backoff
	local moved = tryReparentWithRetry(tool, ServerStorage, 6, 0.03)
	if not moved then
		warn(("[StagedToolManager] Failed to parent to ServerStorage after retries; aborting stage for: %s"):format(safeFullName(tool)))
		-- leave preserve flags for diagnostics, but don't keep it marked staged
		staged[tool] = nil
		return false
	end

	mark(tool, meta)

	-- Schedule initial move after stageTime
	task.delay(stageTime, function()
		-- abort if finalParent no longer exists in DataModel
		if not finalParent or not finalParent.Parent then return end
		-- don't reparent if tool has become captured in the meantime
		if isCapturedTool(tool) then
			unmark(tool)
			warn(("[StagedToolManager] Aborting scheduled reparent: tool became captured: %s"):format(safeFullName(tool)))
			return
		end
		-- attempt to move back; use retry/backoff as other systems may lock Parent briefly
		if tool and tool.Parent ~= finalParent then
			local ok = tryReparentWithRetry(tool, finalParent, 6, 0.05)
			if not ok then
				warn(("[StagedToolManager] initial scheduled reparent failed for tool: %s"):format(safeFullName(tool)))
			end
		end
	end)

	-- Schedule a final re-parent+audit after finalDelay
	task.delay(math.max(stageTime, finalDelay), function()
		if not finalParent or not finalParent.Parent then
			-- finalParent removed (player left?) keep tool in ServerStorage for cleanup loop
			return
		end
		-- don't reparent if tool has become captured in the meantime
		if isCapturedTool(tool) then
			unmark(tool)
			warn(("[StagedToolManager] Aborting final reparent: tool became captured: %s"):format(safeFullName(tool)))
			return
		end
		if tool and tool.Parent ~= finalParent then
			local ok = tryReparentWithRetry(tool, finalParent, 8, 0.05)
			if not ok then
				warn(("[StagedToolManager] final reparent failed for tool: %s"):format(safeFullName(tool)))
			end
		end
		-- clear staging marks (we leave batch id if you want it)
		unmark(tool)

		-- If InventoryService available, attempt to ensure Entry_<id> for persistent tools (foodTools / eggTools)
		pcall(function()
			local uid = nil
			if type(tool.GetAttribute) == "function" then
				local ok, v = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
				if ok then uid = v end
			end
			if InventoryService and uid and finalParent then
				local player = resolvePlayerFromContainer(finalParent)
				if player and type(InventoryService.EnsureEntryHasId) == "function" then
					pcall(function()
						InventoryService.EnsureEntryHasId(player, "foodTools", uid, { ToolUniqueId = uid, FoodId = safeGetAttr(tool, "FoodId") })
					end)
					pcall(function() InventoryService.UpdateProfileInventory(player) end)
				end
			end
		end)

		-- schedule clearing of preserve flags after a short grace so other systems can finish any checks
		task.delay(PRESERVE_GRACE_SECONDS, function()
			-- only clear if tool still appears to be owned by finalParent (heuristic)
			local stillWithOwner = pcall(function() return tool and tool.Parent == finalParent end)
			if stillWithOwner then
				clearPreserveAttrs(tool)
			end
		end)
	end)

	return true
end

-- Convenience: immediate move (bypass staging)
function StagedToolManager.MoveImmediate(tool, finalParent)
	-- don't move captured tools (don't interfere)
	if isCapturedTool(tool) then
		warn(("[StagedToolManager] MoveImmediate skipped for captured tool: %s"):format(safeFullName(tool)))
		return true
	end
	if not tool or not finalParent then return false end

	-- set preserve flags so transient races don't trigger cleanup while we move
	setPreserveAttrs(tool)

	local ok = tryReparentWithRetry(tool, finalParent, 6, 0.03)
	if ok then
		unmark(tool)
		-- If InventoryService available, ensure Entry_<id> as above
		pcall(function()
			local uid = nil
			if type(tool.GetAttribute) == "function" then
				local okG, v = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
				if okG then uid = v end
			end
			if InventoryService and uid and finalParent then
				local player = resolvePlayerFromContainer(finalParent)
				if player and type(InventoryService.EnsureEntryHasId) == "function" then
					pcall(function()
						InventoryService.EnsureEntryHasId(player, "foodTools", uid, { ToolUniqueId = uid, FoodId = safeGetAttr(tool, "FoodId") })
					end)
					pcall(function() InventoryService.UpdateProfileInventory(player) end)
				end
			end
		end)
		-- schedule clearing of preserve flags after short grace
		task.delay(PRESERVE_GRACE_SECONDS, function()
			local stillWithOwner = pcall(function() return tool and tool.Parent == finalParent end)
			if stillWithOwner then
				clearPreserveAttrs(tool)
			end
		end)
	end
	return ok
end

-- Clean a specific staged tool early (destroys it)
function StagedToolManager.DestroyStaged(tool)
	if not tool then return false end
	-- refuse to destroy captured tools
	if isCapturedTool(tool) then
		warn(("[StagedToolManager] DestroyStaged refused for captured tool: %s"):format(safeFullName(tool)))
		return false
	end
	unmark(tool)
	-- use safeRemoveTool to log and protect preserved items
	local ok = false
	pcall(function() ok = safeRemoveTool(tool, "DESTROY_STAGED") end)
	return ok
end

return StagedToolManager