local function buildPreExitHelpers(deps)
	assert(type(deps) == "table", "GrandInventorySerializerPreExitHelpers expects dependency table")

	local sanitizeInventoryOnProfile = deps.sanitizeInventoryOnProfile
	local getPPS = deps.getPPS
	local we_enumeratePlotEggs = deps.we_enumeratePlotEggs
	local we_enumeratePlotEggs_by_userid = deps.we_enumeratePlotEggs_by_userid
	local safe_get_profile = deps.safe_get_profile
	local dprint = deps.dprint or function() end

	local Helpers = {}

	function Helpers.isPlayerInstance(value)
		return type(value) == "table" and type(value.FindFirstChildOfClass) == "function"
	end

	function Helpers.extractUserId(candidate)
		if candidate == nil then
			return nil
		end

		local candidateType = type(candidate)
		if candidateType == "number" then
			local num = tonumber(candidate)
			if num then
				return num
			end
		elseif candidateType == "string" then
			local num = tonumber(candidate)
			if num then
				return num
			end
		elseif candidateType == "table" then
			local id = candidate.userId or candidate.UserId or candidate.id or candidate.Id
			if not id and type(candidate.Identity) == "table" then
				id = candidate.Identity.userId or candidate.Identity.UserId or candidate.Identity.id or candidate.Identity.Id
			end
			local num = tonumber(id)
			if num then
				return num
			end
		end

		return nil
	end

	local function deepCopyTable(src)
		if type(src) ~= "table" then
			return src
		end
		local dst = {}
		for k, v in pairs(src) do
			dst[k] = (type(v) == "table") and deepCopyTable(v) or v
		end
		return dst
	end

	Helpers.deepCopyTable = deepCopyTable

	function Helpers.collectLiveWorldEggs(player, profileArg, a1, a2)
		if Helpers.isPlayerInstance(player) then
			local ok, list = pcall(function()
				return we_enumeratePlotEggs(player)
			end)
			if ok and type(list) == "table" then
				return list
			end
		end

		local uid = Helpers.extractUserId(profileArg) or Helpers.extractUserId(a1) or Helpers.extractUserId(a2)
		if uid then
			local ok, list = pcall(function()
				return we_enumeratePlotEggs_by_userid(uid)
			end)
			if ok and type(list) == "table" then
				return list
			end
		end

		return {}
	end

	function Helpers.resolveAuthoritativeProfile(player, profileArg, a1, a2)
		if Helpers.isPlayerInstance(player) then
			local prof = safe_get_profile(player)
			if prof then
				return prof
			end
		end

		local uid = Helpers.extractUserId(profileArg)
		if uid then
			local prof = safe_get_profile(uid)
			if prof then
				return prof
			end
		end

		if a1 ~= nil then
			local prof = safe_get_profile(a1)
			if prof then
				return prof
			end
		end
		if a2 ~= nil then
			local prof = safe_get_profile(a2)
			if prof then
				return prof
			end
		end

		return nil
	end

	function Helpers.applyWorldEggs(authoritativeProfile, live_we)
		authoritativeProfile.inventory = authoritativeProfile.inventory or {}
		local inv = authoritativeProfile.inventory

		if (live_we and #live_we > 0) or (not inv.worldEggs or #inv.worldEggs == 0) then
			inv.worldEggs = deepCopyTable(live_we)
		else
			dprint(("[PreExitSync] skipping overwrite of profile.inventory.worldEggs (authoritative already has %d entries)"):format(#(inv.worldEggs or {})))
		end

		authoritativeProfile.meta = authoritativeProfile.meta or {}
		authoritativeProfile.meta.lastPreExitSync = os.time()
	end

	function Helpers.requestSave(authoritativeProfile, player)
		pcall(function()
			sanitizeInventoryOnProfile(authoritativeProfile)
		end)

		local PPS = getPPS()
		if not (PPS and type(PPS.SaveNow) == "function") then
			return
		end

		if Helpers.isPlayerInstance(player) then
			pcall(function()
				PPS.SaveNow(player, "GrandInvSer_PreExitSync")
			end)
			return
		end

		local uid = Helpers.extractUserId(authoritativeProfile)
		if uid then
			pcall(function()
				PPS.SaveNow(uid, "GrandInvSer_PreExitSync")
			end)
		else
			dprint("PreExitSync: authoritative profile found but could not determine uid to SaveNow; skipping SaveNow")
		end
	end

	function Helpers.preExitSync(a1, a2)
		local player = nil
		if Helpers.isPlayerInstance(a1) then
			player = a1
		elseif Helpers.isPlayerInstance(a2) then
			player = a2
		end

		local profileArg = nil
		if type(a1) == "table" and a1.inventory ~= nil then
			profileArg = a1
		elseif type(a2) == "table" and a2.inventory ~= nil then
			profileArg = a2
		end

		local authoritativeProfile = Helpers.resolveAuthoritativeProfile(player, profileArg, a1, a2)
		local live_we = Helpers.collectLiveWorldEggs(player, profileArg, a1, a2)

		if not authoritativeProfile then
			return {
				worldEggs = Helpers.deepCopyTable(live_we),
			}
		end

		Helpers.applyWorldEggs(authoritativeProfile, live_we)
		Helpers.requestSave(authoritativeProfile, player)

		local inv = authoritativeProfile.inventory or {}
		return {
			worldEggs = Helpers.deepCopyTable(inv.worldEggs or {}),
		}
	end

	return Helpers
end

return buildPreExitHelpers
