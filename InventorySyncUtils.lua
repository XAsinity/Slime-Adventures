-- InventorySyncUtils.lua
-- Shared helpers for InventoryService: safe removal, tool-safe removal, instance inspection, and EnsureEntryHasId.
-- Cleaned up and simplified to avoid syntax/parser issues.

local InventorySyncUtils = {}
InventorySyncUtils.__Version = "v1.0.1"

local Players        = game:GetService("Players")
local HttpService    = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerProfileService = nil
pcall(function()
	PlayerProfileService = require(ServerScriptService:FindFirstChild("PlayerProfileService"))
end)

-- Debug toggle
InventorySyncUtils.Debug = false
local function dprint(...)
	if InventorySyncUtils.Debug then
		print("[InvSyncUtils]", ...)
	end
end

-- Inspect a fixed set of attributes safely (shallow)
function InventorySyncUtils.inspectInstanceAttrs(inst)
	if not inst or type(inst.GetAttribute) ~= "function" then return {} end
	local keys = {
		"ToolUniqueId","ToolUid","ServerRestore","PreserveOnServer","PreserveOnClient",
		"OwnerUserId","SlimeId","SlimeItem","FoodId","PersistentCaptured","PersistentFoodTool",
		"RestoreStamp","RecentlyPlacedSaved","RecentlyPlacedSavedAt","RecentlyPlacedSavedBy",
		"StagedByManager","RestoreBatchId","_RestoreGuard_Attempts"
	}
	local out = {}
	for _,k in ipairs(keys) do
		local ok, v = pcall(function() return inst:GetAttribute(k) end)
		if ok then out[k] = v end
	end
	return out
end

-- Heuristic: does this instance look like it was server-restored or is persistent/protected?
function InventorySyncUtils.looksLikeRestoredOrPersistent(inst)
	if not inst or type(inst.GetAttribute) ~= "function" then return false end
	local function get(name)
		local ok, v = pcall(function() return inst:GetAttribute(name) end)
		if ok then return v end
		return nil
	end
	if get("ServerRestore") then return true end
	if get("PreserveOnServer") or get("PreserveOnClient") then return true end
	if get("SlimeItem") or get("SlimeId") then return true end
	if get("PersistentCaptured") or get("PersistentFoodTool") then return true end
	if get("RestoreStamp") or get("RecentlyPlacedSaved") or get("RecentlyPlacedSavedAt") then return true end
	return false
end

-- safeRemoveOrDefer(inst, reason, opts)
-- opts.grace: seconds to treat recent RestoreStamp/etc as protected (default 3)
-- opts.force: destroy even if protected
-- returns: boolean, code
function InventorySyncUtils.safeRemoveOrDefer(inst, reason, opts)
	opts = opts or {}
	local grace = (type(opts.grace) == "number") and opts.grace or 3.0
	local force = opts.force and true or false

	if not inst or (typeof and typeof(inst) ~= "Instance") then
		warn("[InvSyncUtils] safeRemoveOrDefer invalid instance. reason=", tostring(reason))
		return false, "invalid_instance"
	end

	-- read possible numeric stamp values
	local recentStamp = nil
	pcall(function()
		if type(inst.GetAttribute) == "function" then
			recentStamp = inst:GetAttribute("RestoreStamp") or inst:GetAttribute("RecentlyPlacedSaved") or inst:GetAttribute("RecentlyPlacedSavedAt")
		end
	end)

	-- If looks restored/persistent and not forced, respect grace/flags
	if not force and InventorySyncUtils.looksLikeRestoredOrPersistent(inst) then
		if type(recentStamp) == "number" then
			if (tick() - tonumber(recentStamp)) <= grace then
				local attrs = InventorySyncUtils.inspectInstanceAttrs(inst)
				local okEnc, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
				warn(("[InvSyncUtils] SKIP removal (protected recent) name=%s reason=%s attrs=%s")
					:format(tostring(inst.Name), tostring(reason), okEnc and attrsJson or "<enc-failed>"))
				return false, "skipped_protected_recent"
			end
		else
			local attrs = InventorySyncUtils.inspectInstanceAttrs(inst)
			local okEnc, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
			warn(("[InvSyncUtils] SKIP removal (protected flag) name=%s reason=%s attrs=%s")
				:format(tostring(inst.Name), tostring(reason), okEnc and attrsJson or "<enc-failed>"))
			return false, "skipped_protected_flag"
		end
	end

	-- Log attempt
	local attrs = InventorySyncUtils.inspectInstanceAttrs(inst)
	local okEnc, attrsJson = pcall(function() return HttpService:JSONEncode(attrs) end)
	warn(("[InvSyncUtils] Removing instance name=%s reason=%s attrs=%s")
		:format(tostring(inst.Name), tostring(reason), okEnc and attrsJson or "<enc-failed>"))

	-- Try non-destructive detach first
	local ok, err = pcall(function() inst.Parent = nil end)
	if not ok then
		-- fallback to Destroy()
		local ok2, err2 = pcall(function() inst:Destroy() end)
		if not ok2 then
			warn(("[InvSyncUtils] Destroy() failed for %s err=%s"):format(tostring(inst.Name), tostring(err2)))
			return false, "destroy_failed"
		end
		return true, "destroyed_fallback"
	else
		if opts.force then
			local ok3, err3 = pcall(function() inst:Destroy() end)
			if not ok3 then
				warn(("[InvSyncUtils] Forced Destroy() failed for %s err=%s"):format(tostring(inst.Name), tostring(err3)))
				return false, "destroy_failed"
			end
			return true, "destroyed"
		end
		return true, "detached"
	end
end

-- Safe tool removal helper (Tool-specific)
-- opts.force, opts.grace (shorter default)
function InventorySyncUtils.safeRemoveTool(tool, reason, opts)
	opts = opts or {}
	local force = opts.force and true or false
	local grace = (type(opts.grace) == "number") and opts.grace or 0.25

	if not tool or type(tool.IsA) ~= "function" or not tool:IsA("Tool") then
		return false, "invalid_tool"
	end

	-- check preservation attributes
	local preserved = false
	pcall(function()
		if type(tool.GetAttribute) == "function" then
			if tool:GetAttribute("ServerRestore") or tool:GetAttribute("PreserveOnServer") or tool:GetAttribute("PersistentFoodTool") then
				preserved = true
			end
		end
	end)

	-- detach immediately if possible
	pcall(function()
		if tool.Parent then tool.Parent = nil end
	end)

	-- If not preserved or forced -> destroy after short grace
	if force or not preserved then
		task.delay(grace, function()
			pcall(function() if tool and tool.Parent then tool.Parent = nil end end)
			pcall(function() if tool and tool.Destroy then tool:Destroy() end end)
		end)
		return true, "scheduled_destroy"
	end

	-- preserved: mark RecentlyPlacedSaved and defer destroy longer
	pcall(function()
		if type(tool.SetAttribute) == "function" then
			tool:SetAttribute("RecentlyPlacedSaved", os.time())
			tool:SetAttribute("RecentlyPlacedSavedAt", os.time())
		end
	end)
	task.delay(math.max(0.5, grace * 4), function()
		pcall(function() if tool and tool.Parent then tool.Parent = nil end end)
		pcall(function() if tool and tool.Destroy then tool:Destroy() end end)
	end)
	return true, "deferred_preserved"
end

-- Robust tool search helper (scans Backpack, Character, ServerStorage, workspace)
function InventorySyncUtils.findToolForPlayerById(player, id)
	if not player or not id then return nil end

	local function matches(tool, idVal)
		if not tool then return false end
		-- attributes
		if type(tool.GetAttribute) == "function" then
			local ok, tu = pcall(function() return tool:GetAttribute("ToolUniqueId") end)
			if ok and tu and tostring(tu) == tostring(idVal) then return true end
			local ok2, tu2 = pcall(function() return tool:GetAttribute("ToolUid") end)
			if ok2 and tu2 and tostring(tu2) == tostring(idVal) then return true end
			local ok3, sid = pcall(function() return tool:GetAttribute("SlimeId") end)
			if ok3 and sid and tostring(sid) == tostring(idVal) then return true end
		end
		-- child value objects
		local c = tool:FindFirstChild("ToolUniqueId") or tool:FindFirstChild("ToolUid")
		if c and c.Value and tostring(c.Value) == tostring(idVal) then return true end
		local c2 = tool:FindFirstChild("SlimeId") or tool:FindFirstChild("slimeId")
		if c2 and c2.Value and tostring(c2.Value) == tostring(idVal) then return true end
		-- name fallback
		if tostring(tool.Name) == tostring(idVal) then return true end
		return false
	end

	local containers = {}
	pcall(function() table.insert(containers, player:FindFirstChildOfClass("Backpack")) end)
	pcall(function() if player.Character then table.insert(containers, player.Character) end end)
	local ss = game:GetService("ServerStorage")
	if ss then pcall(function() table.insert(containers, ss) end) end

	for _, parent in ipairs(containers) do
		if parent and type(parent.GetDescendants) == "function" then
			for _, inst in ipairs(parent:GetDescendants()) do
				if inst and type(inst.IsA) == "function" and inst:IsA("Tool") then
					local ok, res = pcall(function() return matches(inst, id) end)
					if ok and res then return inst end
				end
			end
		end
	end

	-- final fallback scanning workspace for tools owned by this player (rare)
	pcall(function()
		for _, inst in ipairs(workspace:GetDescendants()) do
			if inst and type(inst.IsA) == "function" and inst:IsA("Tool") then
				local ok, res = pcall(function() return matches(inst, id) end)
				if ok and res then
					-- check OwnerUserId attribute if present
					local ownerOk, owner = pcall(function() return inst.GetAttribute and inst:GetAttribute("OwnerUserId") end)
					if ownerOk and tostring(owner) == tostring(player.UserId) then
						return inst
					end
				end
			end
		end
	end)

	return nil
end

-- Ensure Entry_<id> folder exists under player.Inventory.<field>, and set Data payload string
function InventorySyncUtils.EnsureEntryHasId(playerOrId, fieldName, idValue, payloadTable)
	-- resolve player
	local ply = nil
	if typeof and typeof(playerOrId) == "Instance" and playerOrId:IsA("Player") then
		ply = playerOrId
	elseif type(playerOrId) == "table" and playerOrId.UserId then
		ply = playerOrId
	elseif type(playerOrId) == "number" then
		ply = Players:GetPlayerByUserId(playerOrId)
	elseif type(playerOrId) == "string" then
		ply = Players:FindFirstChild(playerOrId)
	end
	if not ply then return false, "no player" end

	-- canonicalize some short names (if user passed 'et', etc.)
	local canonical = (function(n)
		local m = { et = "eggTools", ft = "foodTools", we = "worldEggs", ws = "worldSlimes", cs = "capturedSlimes" }
		return m[n] or n
	end)(fieldName) or fieldName

	-- ensure Inventory folder and field folder
	local inv = ply:FindFirstChild("Inventory")
	if not inv then
		inv = Instance.new("Folder")
		inv.Name = "Inventory"
		inv.Parent = ply
	end
	local fld = inv:FindFirstChild(canonical)
	if not fld then
		fld = Instance.new("Folder")
		fld.Name = canonical
		fld.Parent = inv
		local countVal = Instance.new("IntValue")
		countVal.Name = "Count"
		countVal.Value = 0
		countVal.Parent = fld
	end

	local canonicalId = tostring(idValue)
	payloadTable = payloadTable or {}
	payloadTable.id = tostring(payloadTable.id or canonicalId)
	if canonical == "worldEggs" or canonical == "eggTools" then
		payloadTable.eggId = payloadTable.eggId or payloadTable.id
	else
		payloadTable.eggId = nil
	end

	local function encode(t)
		local ok, enc = pcall(function() return HttpService:JSONEncode(t) end)
		if ok then return enc end
		return "{}"
	end

	-- try find existing by decoded Data
	for _, entry in ipairs(fld:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild("Data")
			if data and type(data.Value) == "string" and data.Value ~= "" then
				local ok, dec = pcall(function() return HttpService:JSONDecode(data.Value) end)
				if ok and type(dec) == "table" and (tostring(dec.id) == canonicalId or tostring(dec.eggId) == canonicalId) then
					local desiredName = "Entry_" .. canonicalId
					pcall(function() entry.Name = desiredName end)
					return true
				end
			end
		end
	end

	-- find a placeholder to reuse
	for _, entry in ipairs(fld:GetChildren()) do
		if entry:IsA("Folder") then
			local data = entry:FindFirstChild("Data")
			local shouldSet = false
			if not data then
				shouldSet = true
			else
				if not data.Value or data.Value == "" then
					shouldSet = true
				else
					local ok, dec = pcall(function() return HttpService:JSONDecode(data.Value) end)
					if not ok or type(dec) ~= "table" or (not dec.id and not dec.eggId) then
						shouldSet = true
					end
				end
			end
			if shouldSet then
				if not data then
					data = Instance.new("StringValue")
					data.Name = "Data"
					data.Parent = entry
				end
				pcall(function() data.Value = encode(payloadTable) end)
				pcall(function() entry.Name = "Entry_" .. canonicalId end)
				-- update count
				local cnt = 0
				for _,c in ipairs(fld:GetChildren()) do if c:IsA("Folder") and tostring(c.Name):match("^Entry_") then cnt = cnt + 1 end end
				local cv = fld:FindFirstChild("Count")
				if cv then pcall(function() cv.Value = cnt end) end
				-- try saving if PlayerProfileService exists
				pcall(function()
					if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
						PlayerProfileService.SaveNow(ply, "EnsureEntryHasId")
					end
				end)
				return true
			end
		end
	end

	-- create new folder
	local okc, newEntry = pcall(function()
		local f = Instance.new("Folder")
		f.Name = "Entry_" .. canonicalId
		local data = Instance.new("StringValue")
		data.Name = "Data"
		data.Value = encode(payloadTable)
		data.Parent = f
		f.Parent = fld
		return f
	end)
	if okc and newEntry then
		local cnt = 0
		for _,c in ipairs(fld:GetChildren()) do if c:IsA("Folder") and tostring(c.Name):match("^Entry_") then cnt = cnt + 1 end end
		local cv = fld:FindFirstChild("Count")
		if cv then pcall(function() cv.Value = cnt end) end
		pcall(function()
			if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
				PlayerProfileService.SaveNow(ply, "EnsureEntryHasId")
			end
		end)
		return true
	end
	return false, "create_failed"
end

function InventorySyncUtils.SetDebug(enabled)
	InventorySyncUtils.Debug = enabled and true or false
end

return InventorySyncUtils