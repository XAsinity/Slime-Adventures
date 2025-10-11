-- EggHatchService.lua (UPDATED)
-- Uses InventorySyncUtils / InventoryService to robustly remove hatched world-egg inventory entries
-- and avoid duplicated save/remove logic. Keeps a conservative approach: update in-memory profile if loaded,
-- then delegate authoritative removal to InventorySyncUtils which will try InventoryService / PlayerProfileService
-- and perform local folder cleanups.

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local ModulesRoot = ServerScriptService:WaitForChild("Modules")

local PlayerProfileService = nil
pcall(function() PlayerProfileService = require(ModulesRoot:WaitForChild("PlayerProfileService")) end)

local InventoryService = nil
pcall(function() InventoryService = require(ModulesRoot:WaitForChild("InventoryService")) end)

local InventorySyncUtils = nil
pcall(function() InventorySyncUtils = require(ModulesRoot:WaitForChild("InventorySyncUtils")) end)

local EggHatchService = {}

local CONFIG = {
	SaveImmediatelyOnHatch = true,
	Debug = true,
}

local function dprint(...)
	if CONFIG.Debug then print("[EggHatch]", ...) end
end

-- MarkEggHatched: high-level helper called when an egg hatches server-side.
-- Responsibilities:
--  - Remove the worldEgg entry from any in-memory profile if present (avoid dupes).
--  - Use InventorySyncUtils.safeRemoveWorldEggForPlayer to remove persisted entries via InventoryService / PlayerProfileService.
--  - As a fallback, call PlayerProfileService.RemoveInventoryItem if available.
--  - Do not aggressively call SaveNow twice; let the InventorySyncUtils helper request saves as appropriate.
function EggHatchService.MarkEggHatched(playerOrUser, eggId)
	if not eggId then return end

	-- Resolve player and userId
	local ply = nil
	local uid = nil
	if type(playerOrUser) == "number" then
		uid = playerOrUser
		ply = Players:GetPlayerByUserId(uid)
	elseif type(playerOrUser) == "table" and playerOrUser.UserId then
		ply = playerOrUser
		uid = ply.UserId
	end

	-- 1) Update in-memory profile if loaded locally (avoid duplicate worldEgg entries)
	pcall(function()
		if PlayerProfileService and type(PlayerProfileService.GetProfile) == "function" and uid then
			local ok, prof = pcall(function() return PlayerProfileService.GetProfile(uid) end)
			if ok and prof and type(prof) == "table" and prof.inventory and type(prof.inventory) == "table" and prof.inventory.worldEggs then
				for i = #prof.inventory.worldEggs, 1, -1 do
					local e = prof.inventory.worldEggs[i]
					if type(e) == "table" then
						local id = e.eggId or e.EggId or e.id or e.Id
						if id and tostring(id) == tostring(eggId) then
							table.remove(prof.inventory.worldEggs, i)
							dprint(("In-memory profile: removed worldEgg entry id=%s for user=%s"):format(tostring(eggId), tostring(uid)))
							-- mark dirty/save now (delegate to PlayerProfileService semantics)
							if type(PlayerProfileService.MarkDirty) == "function" then
								pcall(function() PlayerProfileService.MarkDirty(prof, "EggHatch_InMemoryRemoved") end)
							end
							break
						end
					end
				end
			end
		end
	end)

	-- 2) Use InventorySyncUtils helper to robustly remove persisted entries + local folders.
	if InventorySyncUtils and type(InventorySyncUtils.safeRemoveWorldEggForPlayer) == "function" then
		pcall(function()
			-- prefer player object if available to allow faster InventoryService paths
			local target = ply or uid
			InventorySyncUtils.safeRemoveWorldEggForPlayer(target, eggId)
			dprint(("InventorySyncUtils.safeRemoveWorldEggForPlayer invoked for eggId=%s player=%s"):format(tostring(eggId), tostring(ply and ply.Name or uid)))
		end)
	else
		-- Fallback: best-effort direct calls to InventoryService / PlayerProfileService
		if ply and InventoryService and type(InventoryService.RemoveInventoryItem) == "function" then
			pcall(function()
				InventoryService.RemoveInventoryItem(ply, "worldEggs", "eggId", eggId)
				InventoryService.RemoveInventoryItem(ply, "worldEggs", "EggId", eggId)
				InventoryService.UpdateProfileInventory(ply)
				dprint(("InventoryService.RemoveInventoryItem invoked (player) for eggId=%s player=%s"):format(tostring(eggId), tostring(ply and ply.Name)))
			end)
		end
		if uid and PlayerProfileService and type(PlayerProfileService.RemoveInventoryItem) == "function" then
			pcall(function()
				PlayerProfileService.RemoveInventoryItem(uid, "worldEggs", "eggId", eggId)
				PlayerProfileService.RemoveInventoryItem(uid, "worldEggs", "EggId", eggId)
				-- Try to persist immediately if API exposed
				if type(PlayerProfileService.SaveNow) == "function" then
					pcall(function() PlayerProfileService.SaveNow(uid, "EggHatch_RemoveOffline") end)
				end
				dprint(("PlayerProfileService.RemoveInventoryItem invoked (userId) for eggId=%s userId=%s"):format(tostring(eggId), tostring(uid)))
			end)
		end
		-- Defensive local folder cleanup for online player
		if ply and ply:FindFirstChild("Inventory") then
			pcall(function()
				local worldEggs = ply.Inventory:FindFirstChild("worldEggs")
				if worldEggs then
					local entryName = "Entry_" .. tostring(eggId)
					local ent = worldEggs:FindFirstChild(entryName)
					if ent then
						pcall(function() ent:Destroy() end)
						dprint(("Local Entry folder destroyed: %s for player %s"):format(entryName, ply.Name))
					end
				end
			end)
		end
	end

	-- 3) Finalize: Request a save if available and configured, but avoid double-saving if InventorySyncUtils already handled it.
	-- InventorySyncUtils will attempt SaveNow/SaveImmediately as appropriate; call PlayerProfileService.SaveNow minimally as fallback.
	if CONFIG.SaveImmediatelyOnHatch then
		pcall(function()
			if uid and PlayerProfileService and type(PlayerProfileService.ForceFullSaveNow) == "function" then
				-- prefer ForceFullSaveNow if available; it's typically heavier but more certain
				local ok, res = pcall(function() return PlayerProfileService.ForceFullSaveNow(uid, "EggHatch_Finalize") end)
				if ok then
					dprint(("PlayerProfileService.ForceFullSaveNow requested for user=%s result=%s"):format(tostring(uid), tostring(res)))
				else
					dprint(("PlayerProfileService.ForceFullSaveNow error for user=%s: %s"):format(tostring(uid), tostring(res)))
				end
			elseif uid and PlayerProfileService and type(PlayerProfileService.SaveNow) == "function" then
				pcall(function() PlayerProfileService.SaveNow(uid, "EggHatch_SaveNowFallback") end)
				dprint(("PlayerProfileService.SaveNow requested for user=%s"):format(tostring(uid)))
			end
		end)
	end

	if CONFIG.Debug then
		local who = ply and ply.Name or ("UserId:" .. tostring(uid))
		dprint("Marked egg hatched", eggId, "for", who)
	end
end

return EggHatchService