-- PreExitInventorySync.lua (safe revert, with enhanced merge/debug instrumentation)
-- Updated to fire a BindableEvent "PreExitInventorySaved" under ServerScriptService.Modules
-- when the pre-exit verified save/finalize completes (saved == true). WorldAssetCleanup listens
-- for that event and will run its cleanup after finalization so we avoid race conditions.

local Players                = game:GetService("Players")
local ServerScriptService    = game:GetService("ServerScriptService")
local ReplicatedStorage      = game:GetService("ReplicatedStorage")
local RunService             = game:GetService("RunService")
local workspace              = game:GetService("Workspace")

local ModulesRoot = ServerScriptService:WaitForChild("Modules")

local PlayerProfileService = nil
pcall(function()
	PlayerProfileService = require(ModulesRoot:WaitForChild("PlayerProfileService"))
end)

local GrandInventorySerializer = nil
local function getGrandInventorySanitizer()
	if GrandInventorySerializer and GrandInventorySerializer._internal then
		local fn = GrandInventorySerializer._internal.sanitizeInventoryOnProfile
		if type(fn) == "function" then
			return fn
		end
	end
	return nil
end

do
	local ok, mod = pcall(function()
		return require(ModulesRoot:WaitForChild("GrandInventorySerializer"))
	end)
	if ok and type(mod) == "table" then
		GrandInventorySerializer = mod
	end
end

local SlimeCore = nil
do
	local inst = ModulesRoot:FindFirstChild("SlimeCore")
	if inst and inst:IsA("ModuleScript") then
		local ok, sc = pcall(require, inst)
		if ok and type(sc) == "table" then SlimeCore = sc end
	end
end

local InventoryService = nil
pcall(function() InventoryService = require(ModulesRoot:WaitForChild("InventoryService")) end)

local InventorySyncUtils = nil
pcall(function() InventorySyncUtils = require(ModulesRoot:WaitForChild("InventorySyncUtils")) end)

local PreExitInventorySync = {}

local function dprint(...)
	if RunService:IsStudio() then
		print("[PreExitInventorySync]", ...)
	else
		print("[PreExitInventorySync]", ...)
	end
end

local function awaitProfileQueue(userId, stage, timeoutSeconds)
	if not PlayerProfileService or type(PlayerProfileService.AwaitSaveQueue) ~= "function" then
		return false
	end
	local label = stage or ""
	local ok, drained = pcall(function()
		return PlayerProfileService.AwaitSaveQueue(userId, timeoutSeconds or 2.5)
	end)
	if ok and drained then
		dprint(string.format("Awaited PlayerProfileService queue%s for userId=%s", label ~= "" and (" ["..label.."]") or "", tostring(userId)))
	else
		dprint(string.format("PlayerProfileService queue wait %s for userId=%s (ok=%s, drained=%s)", label ~= "" and ("["..label.."]") or "", tostring(userId), tostring(ok), tostring(drained)))
	end
	return ok and drained or false
end

local function deepCopy(src)
	if type(src) ~= "table" then return src end
	local dst = {}
	for k,v in pairs(src) do
		if type(v) == "table" then
			dst[k] = deepCopy(v)
		else
			dst[k] = v
		end
	end
	return dst
end

local function collect_world_slimes_with_growth(userId)
	local out = {}
	for _,inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Slime" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) then
			local entry = {}
			entry.id = inst:GetAttribute("SlimeId") or inst:GetAttribute("id")
			entry.SlimeId = entry.id

			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			if prim then
				local ok, cf = pcall(function() return prim:GetPivot() end)
				if ok and cf then
					entry.Position = { x = cf.X, y = cf.Y, z = cf.Z }
				end
			end

			local gp = inst:GetAttribute("GrowthProgress")
			if gp ~= nil then entry.GrowthProgress = gp end
			local persisted = inst:GetAttribute("PersistedGrowthProgress")
			if persisted ~= nil then entry.PersistedGrowthProgress = persisted end
			local lg = inst:GetAttribute("LastGrowthUpdate")
			if lg ~= nil then entry.LastGrowthUpdate = lg end

			-- hunger-related attributes
			local cf_full = inst:GetAttribute("CurrentFullness")
			if cf_full ~= nil then entry.CurrentFullness = cf_full end
			local fed = inst:GetAttribute("FedFraction")
			if fed ~= nil then entry.FedFraction = fed end
			local lhu = inst:GetAttribute("LastHungerUpdate")
			if lhu ~= nil then entry.LastHungerUpdate = lhu end
			local hrate = inst:GetAttribute("HungerDecayRate")
			if hrate ~= nil then entry.HungerDecayRate = hrate end

			local ec = inst:GetAttribute("EyeColor")
			if ec then entry.EyeColor = ec end
			local ac = inst:GetAttribute("AccentColor")
			if ac then entry.AccentColor = ac end
			local bc = inst:GetAttribute("BodyColor")
			if bc then entry.BodyColor = bc end
			local ts = inst:GetAttribute("Timestamp")
			if ts then entry.Timestamp = ts end
			local size = inst:GetAttribute("Size")
			if size then entry.Size = size end

			out[#out+1] = entry
		end
	end
	return out
end

local function collect_world_eggs(userId)
	local out = {}
	for _,inst in ipairs(workspace:GetDescendants()) do
		if inst:IsA("Model") and inst.Name == "Egg" and tostring(inst:GetAttribute("OwnerUserId")) == tostring(userId) then
			local prim = inst.PrimaryPart or inst:FindFirstChildWhichIsA("BasePart")
			local cf = nil
			pcall(function() cf = prim and prim:GetPivot() end)
			cf = cf or CFrame.new()
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
	for _,inst in ipairs(game:GetService("ServerStorage"):GetDescendants()) do
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

local function overwrite_profile_world_slimes_with_payload(profile, payloadWorldSlimes)
	if not profile or type(profile) ~= "table" then return false end
	if not profile.inventory or type(profile.inventory) ~= "table" then return false end
	if not payloadWorldSlimes or type(payloadWorldSlimes) ~= "table" then return false end

	local ws = profile.inventory.worldSlimes or {}
	local indexById = {}
	for i,e in ipairs(ws) do
		local id = nil
		if type(e) == "table" then
			id = e.SlimeId or e.id or e.Id
		elseif type(e) == "string" then
			id = e
		end
		if id then indexById[tostring(id)] = i end
	end

	local updated = false
	for _,incoming in ipairs(payloadWorldSlimes) do
		local incomingId = incoming.id or incoming.SlimeId or incoming.Id
		if not incomingId then
			-- skip malformed
		else
			local key = tostring(incomingId)
			local pos = indexById[key]
			if pos then
				local existing = ws[pos]
				if type(existing) ~= "table" then existing = { id = existing } end
				if incoming.GrowthProgress ~= nil then existing.GrowthProgress = incoming.GrowthProgress end
				if incoming.PersistedGrowthProgress ~= nil then existing.PersistedGrowthProgress = incoming.PersistedGrowthProgress end
				if incoming.LastGrowthUpdate ~= nil then existing.LastGrowthUpdate = incoming.LastGrowthUpdate end
				if incoming.Timestamp ~= nil then existing.Timestamp = incoming.Timestamp end
				if incoming.Position ~= nil then existing.Position = incoming.Position end
				if incoming.EyeColor ~= nil then existing.EyeColor = incoming.EyeColor end
				if incoming.AccentColor ~= nil then existing.AccentColor = incoming.AccentColor end
				if incoming.BodyColor ~= nil then existing.BodyColor = incoming.BodyColor end
				if incoming.Size ~= nil then existing.Size = incoming.Size end
				ws[pos] = existing
				updated = true
			else
				table.insert(ws, incoming)
				updated = true
			end
		end
	end

	if updated then
		profile.inventory.worldSlimes = ws
	end

	return updated
end

local function debugPreExitMerge(userId, baseSnapshot, payload, mergedSnapshot)
	local function cnt(tbl, key) return tbl and tbl[key] and #tbl[key] or 0 end
	dprint(string.format("[PreExitDebug][Merge] userId=%s base(worldEggs=%d,captured=%d,eggTools=%d,foodTools=%d) payload(worldEggs=%d,captured=%d,eggTools=%d,foodTools=%d) merged(worldEggs=%d,captured=%d,eggTools=%d,foodTools=%d) time=%s",
		tostring(userId),
		cnt(baseSnapshot, "worldEggs"), cnt(baseSnapshot, "capturedSlimes"), cnt(baseSnapshot, "eggTools"), cnt(baseSnapshot, "foodTools"),
		cnt(payload, "worldEggs"), cnt(payload, "capturedSlimes"), cnt(payload, "eggTools"), cnt(payload, "foodTools"),
		cnt(mergedSnapshot, "worldEggs"), cnt(mergedSnapshot, "capturedSlimes"), cnt(mergedSnapshot, "eggTools"), cnt(mergedSnapshot, "foodTools"),
		os.date("%X")))
end

local function merge_pre_exit_snapshot_into_profile(profile, payload)
	if not profile then return false end
	profile.inventory = profile.inventory or {}
	local inv = profile.inventory
	local applied = false

	local function ensureList(t, k) if not t[k] or type(t[k]) ~= "table" then t[k] = {} end end

	local before = {
		worldEggs = deepCopy(inv.worldEggs),
		eggTools = deepCopy(inv.eggTools),
		foodTools = deepCopy(inv.foodTools),
		capturedSlimes = deepCopy(inv.capturedSlimes),
	}

	local function entryId(e)
		if type(e) ~= "table" then return tostring(e) end
		return tostring(e.id or e.SlimeId or e.uid or e.Id or e.nm or e.name or "")
	end

	local function mergeField(fieldName, value)
		if type(value) ~= "table" then return end
		ensureList(inv, fieldName)

		local existing = inv[fieldName] or {}
		if (#existing == 0 and #value > 0) then
			inv[fieldName] = deepCopy(value)
			applied = true
			return
		end
		if #existing == 0 and #value == 0 then
			return
		end
		if #existing > 0 and #value == 0 then
			return
		end

		local seen = {}
		for _,e in ipairs(existing) do
			local id = entryId(e)
			if id and id ~= "" then seen[id] = true end
		end
		for _,inc in ipairs(value) do
			local id = entryId(inc)
			if id == "" then
				table.insert(existing, deepCopy(inc))
				applied = true
			else
				if not seen[id] then
					table.insert(existing, deepCopy(inc))
					seen[id] = true
					applied = true
				end
			end
		end
		inv[fieldName] = existing
	end

	mergeField("worldEggs",   payload.worldEggs   or {})
	mergeField("eggTools",    payload.eggTools    or {})
	mergeField("foodTools",   payload.foodTools   or {})
	mergeField("capturedSlimes", payload.capturedSlimes or {})

	local after = {
		worldEggs = deepCopy(inv.worldEggs),
		eggTools = deepCopy(inv.eggTools),
		foodTools = deepCopy(inv.foodTools),
		capturedSlimes = deepCopy(inv.capturedSlimes),
	}
	debugPreExitMerge((profile and (profile.userId or profile.UserId)) or "<unknown>", before, payload or {}, after)

	profile.meta = profile.meta or {}
	profile.meta.lastPreExitSnapshot = os.time()

	return applied
end

local function mark_owned_models_recently_saved(userId)
	if not userId then return end
	local now = tick()
	for _,inst in ipairs(workspace:GetDescendants()) do
		if inst and inst:IsA("Model") then
			local owner = nil
			if type(inst.GetAttribute) == "function" then
				local ok, val = pcall(function() return inst:GetAttribute("OwnerUserId") end)
				if ok then owner = val end
			end

			if owner and tostring(owner) == tostring(userId) then
				local nm = inst.Name
				if nm == "Egg" or nm == "Slime" then
					pcall(function() inst:SetAttribute("RecentlyPlacedSaved", now) end)
				end
			end
		end
	end

	pcall(function()
		for _,inst in ipairs(game:GetService("ServerStorage"):GetDescendants()) do
			if inst and type(inst.GetAttribute) == "function" and inst:IsA("Tool") then
				local ok, owner = pcall(function() return inst:GetAttribute("OwnerUserId") end)
				if ok and owner and tostring(owner) == tostring(userId) then
					pcall(function() inst:SetAttribute("RecentlyPlacedSaved", now) end)
				end
			end
		end
	end)
	dprint("Marked RecentlyPlacedSaved timestamp for owned models/tools for userId=", tostring(userId))
end

local function mark_inventory_service_dirty(invServiceModule, player, uid)
	if not player and not uid then return end
	local called = false
	local function tryInvoke(name, arg)
		if invServiceModule and type(invServiceModule[name]) == "function" then
			pcall(function() invServiceModule[name](arg) end)
			called = true
			dprint(("InvMarkDirty: invoked %s with %s"):format(tostring(name), tostring(arg and (arg.Name or arg) or "<nil>")))
		end
	end

	tryInvoke("MarkDirty", player)
	tryInvoke("MarkDirty", uid)
	tryInvoke("MarkPlayerDirty", player)
	tryInvoke("MarkPlayerDirty", uid)
	tryInvoke("MarkDirtyForPlayer", player)
	tryInvoke("MarkDirtyForPlayer", uid)
	tryInvoke("MarkProfileDirty", player)
	tryInvoke("MarkProfileDirty", uid)
	tryInvoke("Touch", player)
	tryInvoke("Touch", uid)
	tryInvoke("SetDirty", player)
	tryInvoke("SetDirty", uid)
	tryInvoke("MarkStateDirty", player)
	tryInvoke("MarkStateDirty", uid)

	if not called and player and type(player.SetAttribute) == "function" then
		pcall(function()
			player:SetAttribute("__PreExitInventoryMergedAt", os.time())
			dprint("InvMarkDirty: fallback set player attribute __PreExitInventoryMergedAt")
		end)
	end
end

-- Ensure the bindable exists early so other modules (WorldAssetCleanup) can connect to it promptly.
local function ensurePreExitBindable()
	local ok, modulesFolder = pcall(function() return ServerScriptService:FindFirstChild("Modules") end)
	if not ok or not modulesFolder then return nil end
	local be = modulesFolder:FindFirstChild("PreExitInventorySaved")
	if be and be:IsA("BindableEvent") then return be end
	local okc, created = pcall(function()
		local b = Instance.new("BindableEvent")
		b.Name = "PreExitInventorySaved"
		b.Parent = modulesFolder
		return b
	end)
	if okc then return created end
	return nil
end
-- create proactively (best-effort)
pcall(ensurePreExitBindable)

-- Provide a helper to ensure the bindable exists and to fire it.
local function firePreExitSavedBindable(userId, savedFlag)
	local ok, modulesFolder = pcall(function() return ServerScriptService:FindFirstChild("Modules") end)
	if not ok or not modulesFolder then return end
	local be = modulesFolder:FindFirstChild("PreExitInventorySaved")
	if not be then
		local success, created = pcall(function()
			local b = Instance.new("BindableEvent")
			b.Name = "PreExitInventorySaved"
			b.Parent = modulesFolder
			return b
		end)
		if success and created then
			be = created
		end
	end
	if be and be:IsA("BindableEvent") then
		pcall(function() be:Fire(userId, savedFlag) end)
	end
end

function PreExitInventorySync.Init()
	if PreExitInventorySync._installed then return end
	PreExitInventorySync._installed = true

	Players.PlayerRemoving:Connect(function(player)
		if not player then return end

		local ok, err = pcall(function()
			local uid = player.UserId
			dprint("PlayerRemoving for", player.Name, "userId=", uid)

			pcall(function()
				if type(player.SetAttribute) == "function" then
					player:SetAttribute("__PreExitInventorySyncActive", os.clock())
				end
			end)

			awaitProfileQueue(uid, "pre-exit-begin", 1.0)

			local profile = nil
			local okProf, prof = pcall(function() return PlayerProfileService and PlayerProfileService.GetProfile and PlayerProfileService.GetProfile(uid) end)
			if okProf and type(prof) == "table" then
				profile = prof
			else
				if PlayerProfileService and type(PlayerProfileService.WaitForProfile) == "function" then
					local okWait, wprof = pcall(function() return PlayerProfileService.WaitForProfile(uid, 1) end)
					if okWait and type(wprof) == "table" then
						profile = wprof
					end
				end
			end
			local isProfile = (profile ~= nil) and (type(profile) == "table")

			local invServiceModule = InventoryService
			if not invServiceModule then
				local invOk, invMod = pcall(function() return require(ModulesRoot:WaitForChild("InventoryService")) end)
				if invOk and invMod then invServiceModule = invMod end
			end

			local invSync = InventorySyncUtils
			if not invSync then
				local okis, ismod = pcall(function() return require(ModulesRoot:WaitForChild("InventorySyncUtils")) end)
				if okis and ismod then invSync = ismod end
			end

			pcall(function()
				if SlimeCore and SlimeCore.GrowthService and type(SlimeCore.GrowthService.FlushPlayerSlimes) == "function" then
					pcall(function() SlimeCore.GrowthService:FlushPlayerSlimes(uid) end)
					dprint("Requested SlimeCore.GrowthService:FlushPlayerSlimes for", uid)
				end

				if SlimeCore and SlimeCore.GrowthPersistenceService then
					local gps = SlimeCore.GrowthPersistenceService
					if type(gps.FlushPlayerSlimesAndSave) == "function" then
						local okFlush, res = pcall(function() return gps.FlushPlayerSlimesAndSave(uid, 1) end)
						if okFlush then
							dprint("GrowthPersistenceService.FlushPlayerSlimesAndSave returned:", tostring(res))
						else
							dprint("GrowthPersistenceService.FlushPlayerSlimesAndSave call error:", tostring(res))
						end
					else
						local evt = ReplicatedStorage:FindFirstChild("GrowthStampDirty")
						if evt and evt:IsA("BindableEvent") then
							pcall(function() evt:Fire(uid, "PreExit") end)
							dprint("Fired GrowthStampDirty bindable for", uid, "as fallback")
						end
					end
				end

				task.wait(0.12)
			end)

			local worldSlimes = collect_world_slimes_with_growth(uid)
			local worldEggs   = collect_world_eggs(uid)
			local eggTools, foodTools, captured = collect_staged_tools(uid)

			local payload = {
				worldSlimes = worldSlimes or {},
				worldEggs   = worldEggs or {},
				eggTools    = eggTools or {},
				foodTools   = foodTools or {},
				capturedSlimes = captured or {},
			}

			if isProfile then
				local okMerge, mergeRes = pcall(function()
					return overwrite_profile_world_slimes_with_payload(profile, payload.worldSlimes)
				end)
				if okMerge and mergeRes then
					dprint("Updated profile.inventory.worldSlimes growth fields from live models for", uid)
				end

				local otherMerged = merge_pre_exit_snapshot_into_profile(profile, payload)
				if otherMerged then dprint("Merged additional snapshot fields for", uid) end

				local sanitizeFn = getGrandInventorySanitizer()
				if sanitizeFn then
					pcall(function()
						sanitizeFn(profile)
					end)
				end
			else
				dprint("No in-memory profile object found for", uid, "- will request save by uid")
			end

			if invServiceModule then
				pcall(function()
					mark_inventory_service_dirty(invServiceModule, player, uid)
				end)
			end

			if invServiceModule and type(invServiceModule.UpdateProfileInventory) == "function" then
				pcall(function()
					local okInv, resInv = pcall(function()
						return invServiceModule.UpdateProfileInventory(player, { overrideEmptyGuard = true })
					end)
					if okInv then
						dprint("InventoryService.UpdateProfileInventory invoked for", uid, "(post-growth-flush, overrideEmptyGuard=true)")
					else
						dprint("InventoryService.UpdateProfileInventory call error for", uid, "err=", tostring(resInv))
					end
				end)
			end

			awaitProfileQueue(uid, "post-update-profile", 1.0)

			local canonicalProfile = nil
			pcall(function() canonicalProfile = PlayerProfileService and PlayerProfileService.GetProfile and PlayerProfileService.GetProfile(uid) end)
			canonicalProfile = canonicalProfile or profile
			if canonicalProfile then
				local sanitizeFn = getGrandInventorySanitizer()
				if sanitizeFn then
					pcall(function()
						sanitizeFn(canonicalProfile)
					end)
				end
			end

			if canonicalProfile and type(canonicalProfile) == "table" then
				local curCoins = nil
				pcall(function() curCoins = (canonicalProfile.core and canonicalProfile.core.coins) end)
				if not curCoins or type(curCoins) ~= "number" or curCoins == 0 then
					local okGet, authoritativeCoins = pcall(function()
						return PlayerProfileService and PlayerProfileService.GetCoins and PlayerProfileService.GetCoins(uid)
					end)
					if okGet and type(authoritativeCoins) == "number" and authoritativeCoins > 0 then
						pcall(function()
							pcall(function() PlayerProfileService.SetCoins(player, authoritativeCoins) end)
							pcall(function() PlayerProfileService.SetCoins(uid, authoritativeCoins) end)
							if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
								PlayerProfileService.SaveNow(uid, "PreExit_RestoreCoins")
							end
						end)
						dprint("Restored coins into profile from authoritative store for", uid, "coins=", authoritativeCoins)
						pcall(function() canonicalProfile = PlayerProfileService.GetProfile(uid) end)
					end
				end
			end

			local function summarize(p)
				if not p or type(p) ~= "table" then return { coins = nil, captured = 0, world = 0 } end
				local coins = nil
				pcall(function() coins = tonumber((p.core and p.core.coins) or nil) end)
				local captured = 0
				pcall(function() captured = (p.inventory and p.inventory.capturedSlimes and #p.inventory.capturedSlimes) or 0 end)
				local world = 0
				pcall(function() world = (p.inventory and p.inventory.worldSlimes and #p.inventory.worldSlimes) or 0 end)
				return { coins = coins, captured = captured, world = world }
			end
			local beforeSaveSummary = summarize(canonicalProfile or profile)
			dprint(("Pre-save summary userId=%s coins=%s captured=%d world=%d"):format(tostring(uid), tostring(beforeSaveSummary.coins), beforeSaveSummary.captured, beforeSaveSummary.world))

			local finalizeUsed = false
			if invServiceModule and type(invServiceModule.FinalizePlayer) == "function" then
				local okFinal, finalRes = pcall(function()
					return invServiceModule.FinalizePlayer(player, "PreExitInventorySync_Finalize")
				end)
				if okFinal then
					finalizeUsed = true
					dprint(("InventoryService.FinalizePlayer invoked for uid=%s result=%s"):format(tostring(uid), tostring(finalRes)))
				else
					dprint(("InventoryService.FinalizePlayer failed for uid=%s err=%s"):format(tostring(uid), tostring(finalRes)))
				end
			end

			local numericId = tonumber(uid)
			local saved = false
			if not finalizeUsed then
				local okSaveNowAndWait, saveRes = pcall(function()
					if PlayerProfileService and type(PlayerProfileService.SaveNowAndWait) == "function" then
						dprint("Invoking PlayerProfileService.SaveNowAndWait (fail-fast) for", numericId)
						return PlayerProfileService.SaveNowAndWait(numericId, 1.25, {
							verified = true,
							reason = "PreExit",
							failFast = true,
							noFallback = false,
						})
					elseif PlayerProfileService and type(PlayerProfileService.ForceFullSaveNow) == "function" then
						dprint("Invoking PlayerProfileService.ForceFullSaveNow (fail-fast) for", numericId)
						return PlayerProfileService.ForceFullSaveNow(numericId, "PreExitInventorySync_Verified", { failFast = true, noFallback = false })
					else
						if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
							dprint("Invoking PlayerProfileService.SaveNow (async fallback) for", numericId)
							PlayerProfileService.SaveNow(numericId, "PreExitInventorySync_AsyncFallback")
						end
						if PlayerProfileService and type(PlayerProfileService.WaitForSaveComplete) == "function" then
							dprint("Waiting briefly for PlayerProfileService.WaitForSaveComplete for", numericId)
							return PlayerProfileService.WaitForSaveComplete(numericId, 0.5)
						end
						return false
					end
				end)

				if okSaveNowAndWait then
					if type(saveRes) == "boolean" then
						saved = saveRes
					elseif saveRes ~= nil then
						saved = true
					else
						saved = false
					end
					dprint("Save call returned for", numericId, "saved=", tostring(saved), "raw=", tostring(saveRes))
				else
					dprint("SaveNowAndWait/ForceFullSaveNow call (fail-fast) failed for", uid, "err=", tostring(saveRes))
				end

				if not saved then
					dprint("Verified save not observed (fail-fast); scheduling async SaveNow and continuing (short best-effort wait)")
					pcall(function()
						if PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
							PlayerProfileService.SaveNow(numericId, "PreExitInventorySync_Fallback")
						end
					end)
					pcall(function()
						if PlayerProfileService and type(PlayerProfileService.WaitForSaveComplete) == "function" then
							PlayerProfileService.WaitForSaveComplete(numericId, 0.5)
							saved = true
						end
					end)
					if not saved then task.wait(0.25) end
				end
			else
				dprint("Skipped module-level verified save because InventoryService.FinalizePlayer was used for uid=", tostring(uid))
				saved = true
			end

			if saved then
				pcall(function()
					mark_owned_models_recently_saved(uid)
				end)
			end

			if invSync and type(invSync.safeRemoveWorldEggForPlayer) == "function" and payload and payload.worldEggs then
				pcall(function()
					for _, we in ipairs(payload.worldEggs) do
						local id = we and (we.id or we.eggId or we.EggId)
						if id then
							invSync.safeRemoveWorldEggForPlayer(player or uid, id)
						end
					end
				end)
			end

			if not invSync and player and player:FindFirstChild("Inventory") and payload and payload.worldEggs then
				pcall(function()
					local folder = player.Inventory:FindFirstChild("worldEggs")
					if folder then
						for _, we in ipairs(payload.worldEggs) do
							local id = we and (we.id or we.eggId or we.EggId)
							if id then
								local f = folder:FindFirstChild("Entry_" .. tostring(id))
								if f then
									pcall(function() f:Destroy() end)
								end
							end
						end
					end
				end)
			end

			awaitProfileQueue(uid, "post-finalize", 1.5)

			pcall(function()
				if type(player.SetAttribute) == "function" then
					player:SetAttribute("__PreExitInventorySyncActive", nil)
					if saved then
						player:SetAttribute("__PreExitInventorySyncFinalizedAt", os.clock())
					end
				end
			end)

			-- FIRE bindable to signal Post-PreExit finalization/saved state
			-- WorldAssetCleanup listens for this and will run cleanup after finalization.
			pcall(function()
				firePreExitSavedBindable(uid, saved)
			end)

			dprint("PreExitInventorySync persistence complete (saved="..tostring(saved)..") for userId=", numericId)
		end)

		if not ok then
			warn("[PreExitInventorySync] PlayerRemoving handler error for", player and player.Name or "nil", err)
			pcall(function()
				if player and type(player.SetAttribute) == "function" then
					player:SetAttribute("__PreExitInventorySyncActive", nil)
				end
			end)
		end
	end)
end

return PreExitInventorySync