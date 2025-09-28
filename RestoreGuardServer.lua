-- RestoreGuard_v2.lua
-- Watches restored/preserved Tools and attempts to ensure they end up in the player's Backpack.
-- If reparent retries fail repeatedly (Parent locked), fallback to cloning the tool and parenting the clone.

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")

local RestoreGuard = {}
RestoreGuard.__index = RestoreGuard

local MAX_REPARENT_ATTEMPTS = 6
local REPTY_BASE_DELAY = 0.06
local CLONE_FALLBACK_DELAY = 0.05

local function safeGetAttr(inst, name)
	if not inst or type(inst.GetAttribute) ~= "function" then return nil end
	local ok, v = pcall(function() return inst:GetAttribute(name) end)
	if ok then return v end
	return nil
end

local function safeSetAttr(inst, name, value)
	if not inst or type(inst.SetAttribute) ~= "function" then return end
	pcall(function() inst:SetAttribute(name, value) end)
end

local function safeFullName(inst)
	if not inst then return "<nil>" end
	local ok, s = pcall(function() return inst:GetFullName() end)
	if ok and type(s) == "string" then return s end
	local ok2, n = pcall(function() return inst.Name end)
	if ok2 and type(n) == "string" then return tostring(n) end
	return "<unknown>"
end

local function tryReparentWithRetry(tool, dest, attempts, baseDelay)
	attempts = attempts or MAX_REPARENT_ATTEMPTS
	baseDelay = baseDelay or REPTY_BASE_DELAY
	for i = 1, attempts do
		local ok, err = pcall(function() tool.Parent = dest end)
		if ok then
			return true, nil
		else
			-- return the last error to the caller (for diagnostics)
			warn(("[RestoreGuard_v2] reparent attempt %d failed for %s -> %s err=%s"):format(
				i, tostring(safeFullName(tool)), tostring(dest and dest:GetFullName() or "<nil>"), tostring(err)
				))
			task.wait(baseDelay * (1 + (i - 1) * 0.5))
		end
	end
	return false, "max_attempts_exceeded"
end

-- Safe destroy that respects PreserveOnServer/ServerRestore attribute
local function safeDestroyTool(tool, reason)
	if not tool then return false end
	local preserve = safeGetAttr(tool, "PreserveOnServer") or safeGetAttr(tool, "ServerRestore")
	if preserve then
		warn(("[RestoreGuard_v2] safeDestroyTool: preserve attrs set, not destroying %s reason=%s"):format(safeFullName(tool), tostring(reason)))
		-- if preserved, leave it for other flows to clean after their grace window
		return true
	end
	local ok, err = pcall(function() tool:Destroy() end)
	if not ok then
		warn(("[RestoreGuard_v2] safeDestroyTool failed for %s err=%s"):format(safeFullName(tool), tostring(err)))
		return false
	end
	return true
end

-- Clone fallback: clone the tool server-side, copy key attributes, and parent clone into finalParent
local function cloneFallback(tool, finalParent)
	if not tool or not finalParent then return false, "invalid_args" end
	local ok, clone = pcall(function() return tool:Clone() end)
	if not ok or not clone then
		warn(("[RestoreGuard_v2][CLONE] Failed to clone tool %s err=%s"):format(safeFullName(tool), tostring(clone)))
		return false, "clone_failed"
	end

	-- preserve attributes which matter for persistence / inventory
	for _,k in ipairs({"ToolUniqueId","ToolUid","SlimeId","FoodId","PreserveOnServer","ServerRestore","RecentlyPlacedSaved","PersistentCaptured","PersistentFoodTool","OwnerUserId","RestoreBatchId"}) do
		local v = safeGetAttr(tool, k)
		if v ~= nil then
			safeSetAttr(clone, k, v)
		end
	end

	-- ensure the clone is visible to server flows
	pcall(function() clone.Parent = finalParent end)
	-- Try reparenting with the usual retry, but the fresh clone generally avoids the locked state
	local reparented, err = tryReparentWithRetry(clone, finalParent, 4, CLONE_FALLBACK_DELAY)
	if reparented then
		warn(("[RestoreGuard_v2][CLONE] Clone succeeded for %s -> %s, destroying original"):format(safeFullName(tool), safeFullName(clone)))
		-- copy over ServerRestore/Preserve flags so other flows see it
		safeSetAttr(clone, "ServerRestore", true)
		safeSetAttr(clone, "PreserveOnServer", true)
		-- attempt to destroy original (best-effort)
		pcall(function() safeDestroyTool(tool, "replaced_by_clone") end)
		return true, "clone_ok"
	else
		-- failed to parent clone too; destroy clone to avoid duplicates
		warn(("[RestoreGuard_v2][CLONE] Clone parent failed for %s err=%s; cleaning up clone"):format(safeFullName(clone), tostring(err)))
		pcall(function() clone:Destroy() end)
		return false, "clone_parent_failed"
	end
end

-- Main observe function called by the system when a restored/preserved tool loses its parent.
-- tool: Instance (Tool)
-- finalParent: Instance (Backpack)
function RestoreGuard.ensureToolInParent(tool, finalParent)
	if not tool or not finalParent then return false end

	-- quick path: if already in target, nothing to do
	if tool.Parent == finalParent then
		return true
	end

	-- Try standard reparent attempts first
	local ok, err = tryReparentWithRetry(tool, finalParent)
	if ok then
		return true
	end

	-- If we got a parent-locked error pattern or repeated failures, try clone fallback
	-- Small delay before clone to reduce concurrent engine activity
	task.wait(CLONE_FALLBACK_DELAY)

	-- log diagnostics (attributes)
	local attrs = {}
	pcall(function()
		for _,k in ipairs({"ServerRestore","PreserveOnServer","ToolUniqueId","ToolUid","SlimeId","FoodId","_RestoreGuard_Attempts"}) do
			local v = safeGetAttr(tool, k)
			if v ~= nil then attrs[k] = v end
		end
	end)
	local okJson, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
	local attrsStr = okJson and attrsJson or tostring(attrs)

	warn(("[RestoreGuard_v2][CLONE] Falling back to clone for %s finalParent=%s attrs=%s"):format(safeFullName(tool), tostring(finalParent and finalParent:GetFullName() or "<nil>"), attrsStr))

	local clonedOk, reason = cloneFallback(tool, finalParent)
	if clonedOk then
		return true
	end

	-- Final fallback: keep retrying for a while longer but with longer backoff
	local extraOk, extraErr = tryReparentWithRetry(tool, finalParent, 8, REPTY_BASE_DELAY * 0.3)
	if extraOk then
		return true
	end

	-- Nothing else worked; log and give up — leave the tool for other cleanup flows (it may be preserved)
	warn(("[RestoreGuard_v2] All reparent strategies failed for %s; giving up for now"):format(safeFullName(tool)))
	return false
end

return RestoreGuard