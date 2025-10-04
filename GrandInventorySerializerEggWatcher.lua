local cachedWatcher

local function initEggWatcher(deps)
	assert(type(deps) == "table", "GrandInventorySerializerEggWatcher expects dependency table")
	if cachedWatcher then
		return cachedWatcher
	end

	local Workspace = assert(deps.Workspace, "Workspace dependency required")
	local ServerScriptService = deps.ServerScriptService or game:GetService("ServerScriptService")
	local getPPS = assert(deps.getPPS, "getPPS dependency required")

	local EggWatcher = {
		recentRemoved = {},
		debounceSeconds = 2,
	}

	function EggWatcher:debounce(eggId)
		if not eggId then return false end
		local now = os.clock()
		local last = self.recentRemoved[eggId]
		if last and (now - last) < self.debounceSeconds then
			return false
		end
		self.recentRemoved[eggId] = now
		task.delay(self.debounceSeconds * 2, function()
			local stamp = self.recentRemoved[eggId]
			if stamp and (os.clock() - stamp) >= self.debounceSeconds * 2 then
				self.recentRemoved[eggId] = nil
			end
		end)
		return true
	end

	local function findInventoryModule()
		local sources = {
			ServerScriptService,
			ServerScriptService:FindFirstChild("Modules") or ServerScriptService,
			game:GetService("ReplicatedStorage"),
			game:GetService("ReplicatedStorage"):FindFirstChild("Modules"),
		}
		for _, src in ipairs(sources) do
			if src then
				local inst = src:FindFirstChild("InventoryService") or src:FindFirstChild("InvSvc") or src:FindFirstChild("Inventory")
				if inst and inst:IsA("ModuleScript") then
					local ok, mod = pcall(function()
						return require(inst)
					end)
					if ok and type(mod) == "table" then
						return mod
					end
				end
			end
		end
		return nil
	end

	function EggWatcher:tryRemoveEgg(ownerUserId, eggId)
		if not eggId then return end
		if not self:debounce(tostring(eggId)) then return end

		local PPS = getPPS()
		if PPS and type(PPS.RemoveInventoryItem) == "function" then
			local ok = pcall(function()
				PPS.RemoveInventoryItem(ownerUserId, "worldEggs", "id", eggId)
			end)
			if ok then
				pcall(function()
					if ownerUserId then
						PPS.SaveNow(ownerUserId, "GrandInvSer_EggRemoved")
					end
				end)
				return
			end
		end

		local invMod = findInventoryModule()
		if not invMod then return end

		pcall(function()
			if type(invMod.UpdateProfileInventory) == "function" then
				local prof = nil
				if type(invMod.GetProfileForUser) == "function" then
					local ok, p = pcall(function()
						return invMod.GetProfileForUser(ownerUserId)
					end)
					if ok and type(p) == "table" then
						prof = p
					end
				end
				if prof and prof.inventory and prof.inventory.worldEggs then
					for i = #prof.inventory.worldEggs, 1, -1 do
						local it = prof.inventory.worldEggs[i]
						if it and (it.id == eggId or it.EggId == eggId) then
							table.remove(prof.inventory.worldEggs, i)
						end
					end
					pcall(function()
						invMod.UpdateProfileInventory(prof, "worldEggs", prof.inventory.worldEggs)
					end)
				else
					pcall(function()
						invMod.UpdateProfileInventory(ownerUserId, "worldEggs", {})
					end)
				end
			elseif type(invMod.SetProfileField) == "function" then
				pcall(function()
					invMod.SetProfileField(ownerUserId, "worldEggs", {})
				end)
			end

			if type(invMod.SaveNow) == "function" then
				pcall(function()
					invMod.SaveNow(ownerUserId, "GrandInvSer_EggRemoved")
				end)
			end
		end)
	end

	function EggWatcher:onEggRemoved(inst)
		if not inst or not inst:IsA("Model") then return end
		if tostring(inst.Name) ~= "Egg" then return end
		local eggId = inst:GetAttribute("EggId") or inst:GetAttribute("id")
		local owner = inst:GetAttribute("OwnerUserId") or inst:GetAttribute("ownerUserId") or inst:GetAttribute("Owner")
		local ownerNum = tonumber(owner)
		if eggId then
			pcall(function()
				self:tryRemoveEgg(ownerNum, eggId)
			end)
		end
	end

	function EggWatcher:onEggCandidate(inst)
		return inst and inst:IsA("Model") and tostring(inst.Name) == "Egg"
	end

	local function monitorEggAncestry(inst)
		if not EggWatcher:onEggCandidate(inst) then return end
		local conn
		conn = inst.AncestryChanged:Connect(function(_, parent)
			local parentOk = parent and parent:IsDescendantOf(Workspace)
			if not parentOk then
				pcall(function()
					EggWatcher:onEggRemoved(inst)
				end)
				if conn then conn:Disconnect() end
			end
		end)
	end

	Workspace.DescendantRemoving:Connect(function(desc)
		if EggWatcher:onEggCandidate(desc) then
			pcall(function()
				EggWatcher:onEggRemoved(desc)
			end)
		end
	end)

	for _, inst in ipairs(Workspace:GetDescendants()) do
		if EggWatcher:onEggCandidate(inst) then
			pcall(function()
				monitorEggAncestry(inst)
			end)
		end
	end

	Workspace.DescendantAdded:Connect(function(desc)
		if EggWatcher:onEggCandidate(desc) then
			pcall(function()
				monitorEggAncestry(desc)
			end)
		end
	end)

	cachedWatcher = EggWatcher
	return EggWatcher
end

return initEggWatcher
