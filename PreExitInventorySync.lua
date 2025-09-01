-- PreExitInventorySync.lua (updated: safer profile merge, bounded waits, prefer verified save, defensive calls)
-- Responsibilities:
--  - Collect server-side inventory assets (world slimes, world eggs, staged tools) at PlayerRemoving.
--  - Merge snapshot into PlayerProfileService in-memory profile when available (without overwriting existing data unintentionally).
--  - Request persistence via PlayerProfileService.SaveNowAndWait (preferVerified) or fall back to SaveNow + WaitForSaveComplete.
--  - Ask GrandInventorySerializer.PreExitSync to perform serializer-specific finalization, passing the in-memory profile when available.
-- Notes:
--  - This module does not write directly to datastores; PlayerProfileService is the authoritative writer.
--  - All external calls are wrapped in pcall to avoid unhandled errors during PlayerRemoving.
-----------------------------------------------------------------------

local Players                = game:GetService("Players")
local Workspace              = game:GetService("Workspace")
local ServerStorage          = game:GetService("ServerStorage")
local ServerScriptService    = game:GetService("ServerScriptService")
local RunService             = game:GetService("RunService")

local PlayerProfileService = require(ServerScriptService.Modules:WaitForChild("PlayerProfileService"))

local PreExitInventorySync = {}

local function dprint(...)
	if RunService:IsStudio() then
		print("[PreExitInventorySync]", ...)
	else
		print("[PreExitInventorySync]", ...)
	end
end

local function collect_world_slimes(userId)
	local out = {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) then
			local entry = { id = inst:GetAttribute("SlimeId"), px = 0, py = 0, pz = 0 }
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			if prim then
				local cf = prim:GetPivot()
				entry.px, entry.py, entry.pz = cf.X, cf.Y, cf.Z
			end
			out[#out+1] = entry
		end
	end
	return out
end

local function collect_world_eggs(userId)
	local out = {}
	for _,inst in ipairs(Workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Egg" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) then
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			local cf = prim and prim:GetPivot() or CFrame.new()
			local id = inst:GetAttribute("EggId") or ("Egg_"..tostring(math.random(1,1e9)))
			out[#out+1] = {
				id = id,
				px = cf.X, py = cf.Y, pz = cf.Z,
				ht = inst:GetAttribute("HatchTime"),
				ha = inst:GetAttribute("HatchAt"),
				tr = 0,
			}
		end
	end
	return out
end

local function collect_staged_tools(userId)
	local eggTools, foodTools, captured = {}, {}, {}
	for _,inst in ipairs(ServerStorage:GetDescendants()) do
		if inst:IsA("Tool") then
			local owner = inst:GetAttribute("OwnerUserId")
			if tostring(owner) == tostring(userId) then
				if inst:GetAttribute("FoodItem") or inst:GetAttribute("FoodId") then
					table.insert(foodTools, {
						nm = inst.Name,
						fid = inst:GetAttribute("FoodId"),
						uid = inst:GetAttribute("ToolUniqueId") or inst:GetAttribute("ToolUid"),
					})
				elseif inst:GetAttribute("SlimeItem") or inst:GetAttribute("Captured") then
					table.insert(captured, {
						nm = inst.Name,
						id = inst:GetAttribute("SlimeId"),
						uid = inst:GetAttribute("ToolUniqueId") or inst:GetAttribute("ToolUid"),
					})
				else
					table.insert(eggTools, {
						nm = inst.Name,
						id = inst:GetAttribute("EggId") or inst:GetAttribute("ToolUniqueId"),
						uid = inst:GetAttribute("ToolUniqueId") or inst:GetAttribute("ToolUid"),
					})
				end
			end
		end
	end
	return eggTools, foodTools, captured
end

-- conservative merge helper: only apply payload fields if profile field is empty (avoid overwriting).
local function merge_pre_exit_snapshot_into_profile(profile, payload)
	if not profile then return false end
	profile.inventory = profile.inventory or {}
	local inv = profile.inventory
	local applied = false

	local function mergeField(fieldName, value)
		if type(value) ~= "table" then return end
		if not inv[fieldName] or #inv[fieldName] == 0 then
			inv[fieldName] = value
			applied = true
		end
	end

	mergeField("worldSlimes", payload.worldSlimes or {})
	mergeField("worldEggs",   payload.worldEggs   or {})
	mergeField("eggTools",    payload.eggTools    or {})
	mergeField("foodTools",   payload.foodTools   or {})
	mergeField("capturedSlimes", payload.capturedSlimes or {})

	profile.meta = profile.meta or {}
	profile.meta.lastPreExitSnapshot = os.time()

	return applied
end

function PreExitInventorySync.Init()
	-- safe attach: idempotent
	if PreExitInventorySync._installed then return end
	PreExitInventorySync._installed = true

	Players.PlayerRemoving:Connect(function(player)
		if not player then return end

		local ok, err = pcall(function()
			local uid = player.UserId
			dprint("PlayerRemoving for", player.Name, "userId=", uid)

			-- collect server-side inventories
			local worldSlimes = collect_world_slimes(uid)
			local worldEggs   = collect_world_eggs(uid)
			local eggTools, foodTools, captured = collect_staged_tools(uid)

			local payload = {
				worldSlimes = worldSlimes or {},
				worldEggs   = worldEggs or {},
				eggTools    = eggTools or {},
				foodTools   = foodTools or {},
				capturedSlimes = captured or {},
			}

			-- attempt to get in-memory profile; prefer WaitForProfile briefly if not present
			local profile = nil
			local okProf, prof = pcall(function() return PlayerProfileService.GetProfile(uid) end)
			if okProf and type(prof) == "table" then
				profile = prof
			else
				-- bounded attempt to wait for profile if not yet loaded (short window)
				if type(PlayerProfileService.WaitForProfile) == "function" then
					local okWait, wprof = pcall(function() return PlayerProfileService.WaitForProfile(uid, 1) end)
					if okWait and type(wprof) == "table" then
						profile = wprof
					end
				end
			end

			-- Merge snapshot into PlayerProfileService profile (conservative merge)
			local merged = false
			if profile and type(profile) == "table" then
				merged = merge_pre_exit_snapshot_into_profile(profile, payload)
				if merged then
					dprint("Merged pre-exit snapshot into in-memory profile for", uid)
				else
					dprint("Pre-exit snapshot not merged because profile already had inventory for", uid)
				end
			else
				dprint("No in-memory profile object found for", uid, "- will still request save by numeric id")
			end

			-- Best-effort: ask InventoryService to update its runtime view if available (defensive).
			local invOk, InventoryService = pcall(function()
				return require(ServerScriptService.Modules:WaitForChild("InventoryService"))
			end)
			if invOk and InventoryService and type(InventoryService.UpdateProfileInventory) == "function" then
				local okInv, invErr = pcall(function()
					-- InventoryService.UpdateProfileInventory expects the player; it will use its own state to update profile.
					-- We call it to ensure any InventoryService-owned state is synced to PlayerProfileService.
					InventoryService.UpdateProfileInventory(player)
					dprint("InventoryService.UpdateProfileInventory invoked for", uid)
				end)
				if not okInv then
					dprint("InventoryService.UpdateProfileInventory failed:", invErr)
				end
			else
				dprint("InventoryService.UpdateProfileInventory not available; skipping direct update")
			end

			-- Ask PlayerProfileService to persist authoritative snapshot.
			-- Use SaveNowAndWait(preferVerified=true) when available; otherwise SaveNow + WaitForSaveComplete fallback.
			local numericId = tonumber(uid)
			local saved = false

			local okSaveNowAndWait, saveRes = pcall(function()
				if type(PlayerProfileService.SaveNowAndWait) == "function" then
					-- prefer a verified write for PlayerRemoving
					return PlayerProfileService.SaveNowAndWait(numericId, 4, true)
				elseif type(PlayerProfileService.ForceFullSaveNow) == "function" then
					-- older API
					return PlayerProfileService.ForceFullSaveNow(numericId, "PreExitInventorySync_VerifiedFallback")
				else
					-- no verified API: call SaveNow and wait for SaveComplete
					PlayerProfileService.SaveNow(numericId, "PreExitInventorySync_AsyncFallback")
					if type(PlayerProfileService.WaitForSaveComplete) == "function" then
						return PlayerProfileService.WaitForSaveComplete(numericId, 2)
					end
					return false
				end
			end)

			if okSaveNowAndWait then
				if type(saveRes) == "boolean" then
					saved = saveRes
				else
					-- some implementations may return non-boolean success; treat non-nil truthy as saved
					saved = saveRes ~= nil
				end
			else
				dprint("SaveNowAndWait/ForceFullSaveNow call failed for", uid, "err=", tostring(saveRes))
			end

			-- if verified save reported failure, try async fallback and wait briefly
			if not saved then
				dprint("Verified save not observed; falling back to async SaveNow and waiting (best-effort)")
				pcall(function() PlayerProfileService.SaveNow(numericId, "PreExitInventorySync_Fallback") end)
				local okWait, waitRes = pcall(function()
					if type(PlayerProfileService.WaitForSaveComplete) == "function" then
						return PlayerProfileService.WaitForSaveComplete(numericId, 2)
					end
					return false
				end)
				if okWait and waitRes then
					saved = true
				else
					-- last-ditch short pause to reduce race
					task.wait(0.35)
				end
			end

			dprint("PreExitInventorySync persistence complete (saved="..tostring(saved)..") for userId=", numericId)

			-- Notify GrandInventorySerializer.PreExitSync so it can perform serializer-specific finalization.
			local okGis, gisModule = pcall(function()
				return require(ServerScriptService.Modules:WaitForChild("GrandInventorySerializer"))
			end)
			if okGis and gisModule and type(gisModule.PreExitSync) == "function" then
				-- Prefer passing the profile table so serializer can prefer profile-backed final payloads.
				local arg = profile or numericId or player
				local okCall, callErr = pcall(function() gisModule.PreExitSync(arg) end)
				if okCall then
					dprint("Invoked GrandInventorySerializer.PreExitSync with", (type(arg) == "table" and "profile table") or ("userId="..tostring(arg)))
				else
					dprint("GrandInventorySerializer.PreExitSync invocation failed:", callErr, " - attempting fallback with player")
					pcall(function() gisModule.PreExitSync(player) end)
				end
			else
				dprint("GrandInventorySerializer.PreExitSync not available; skipping explicit call")
			end
		end)

		if not ok then
			warn("[PreExitInventorySync] PlayerRemoving handler error for", player and player.Name or "nil", err)
		end
	end)
end

return PreExitInventorySync