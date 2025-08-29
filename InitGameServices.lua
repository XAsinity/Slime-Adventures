-- InitGameServices.lua
-- Comprehensive defensive module/service loader.
-- Key fix: call module.Init with the module table as the 'self' argument so Init()
-- implementations that expect colon-calls (self) work correctly.

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ModulesFolderServer = ServerScriptService:FindFirstChild("Modules")
local ModulesFolderReplicated = ReplicatedStorage:FindFirstChild("Modules")

local function dprint(...)
	if RunService:IsStudio() then
		print("[InitGameServices]", ...)
	else
		print("[InitGameServices]", ...)
	end
end

-- Ensure a bindable exists for legacy/persistence compatibility
local function createBindableIfMissing(parent)
	if not parent then return end
	local existing = parent:FindFirstChild("PersistInventoryRestored")
	if existing and existing:IsA("BindableEvent") then
		return existing
	end
	local ev = Instance.new("BindableEvent")
	ev.Name = "PersistInventoryRestored"
	ev.Parent = parent
	return ev
end

-- Safe require that returns module table or nil + error (includes traceback)
local function safeRequireWithTrace(moduleInstance)
	if not moduleInstance then
		return nil, "moduleInstance is nil"
	end
	local ok, result = xpcall(function()
		return require(moduleInstance)
	end, function(err)
		return debug.traceback(tostring(err), 2)
	end)
	if not ok then
		return nil, result -- result is traceback string
	end
	return result, nil
end

-- Safe Init() caller: call Init with moduleTable as self (pcall(module.Init, module))
-- This avoids Init being executed with nil self and prevents nil-index crashes.
local function safeInit(moduleName, moduleTable)
	if not moduleTable then
		dprint(("Module %s returned nil; skipping Init()"):format(tostring(moduleName)))
		return
	end
	if type(moduleTable.Init) == "function" then
		-- Call Init with moduleTable as the first (self) parameter
		local ok, err = pcall(moduleTable.Init, moduleTable)
		if ok then
			dprint(("Loaded module: %s - Init() run."):format(moduleName))
		else
			dprint(("Loaded module: %s - Init() ERROR: %s"):format(moduleName, tostring(err)))
		end
	else
		dprint(("Loaded module: %s (no Init)"):format(moduleName))
	end
end

-- Recursively collect ModuleScript instances under `root` into `out` keyed by FullName
local function collectModuleScriptsRecursive(root, out)
	if not root or not root.GetChildren then return end
	for _, child in ipairs(root:GetChildren()) do
		if child:IsA("ModuleScript") then
			out[child:GetFullName()] = child
		elseif child:IsA("Folder") then
			collectModuleScriptsRecursive(child, out)
		else
			-- Recurse any container with children (covers unexpected nesting)
			if #child:GetChildren() > 0 then
				collectModuleScriptsRecursive(child, out)
			end
		end
	end
end

local function Init()
	-- create bindable for backward compatibility immediately
	createBindableIfMissing(script)

	dprint("Starting recursive module discovery and initialization...")

	-- Discover modules in expected module folders
	local discovered = {}
	if ModulesFolderServer then
		collectModuleScriptsRecursive(ModulesFolderServer, discovered)
	else
		dprint("Warning: ServerScriptService.Modules not found")
	end
	if ModulesFolderReplicated then
		collectModuleScriptsRecursive(ModulesFolderReplicated, discovered)
	end
	-- Also check script.Parent in case Modules folder is adjacent or project structured differently
	collectModuleScriptsRecursive(script.Parent or Instance.new("Folder"), discovered)

	-- Print a short discovery summary
	local discoveredCount = 0
	for _ in pairs(discovered) do discoveredCount = discoveredCount + 1 end
	dprint(("Discovered ModuleScripts: %d"):format(discoveredCount))

	-- Skip list: modules we intentionally don't run here
	local skipModules = {
		PreExitInventorySync = true,
	}

	-- Prioritized require order (require first, Init later)
	local prioritized = {
		"PlayerProfileService",
		"GrandInventorySerializer",
		"InventoryService",
		"PlotManager",
		"ShopService",
		"EggService",
	}

	-- Map name -> module table (nil if not loaded or intentionally skipped)
	local loadedModules = {}

	-- First pass: require prioritized modules first (if present)
	for _, pname in ipairs(prioritized) do
		for fullName, inst in pairs(discovered) do
			if inst and inst.Name == pname and loadedModules[pname] == nil then
				if skipModules[pname] then
					dprint(("%s found at %s but intentionally skipped."):format(pname, fullName))
					loadedModules[pname] = nil
				else
					local mod, err = safeRequireWithTrace(inst)
					if not mod then
						dprint(("[Require ERROR] Prioritized module %s at %s failed to require:\n%s"):format(pname, fullName, tostring(err)))
					else
						dprint(("Required prioritized module %s from %s"):format(pname, fullName))
					end
					loadedModules[pname] = mod
				end
			end
		end
	end

	-- Second step of first pass: require all discovered modules (skip ones already attempted and skip list)
	for fullName, inst in pairs(discovered) do
		local key = inst.Name
		if loadedModules[key] == nil and not skipModules[key] then
			local mod, err = safeRequireWithTrace(inst)
			if not mod then
				dprint(("[Require ERROR] %s at %s failed to require:\n%s"):format(key, fullName, tostring(err)))
			else
				dprint(("Required %s from %s"):format(key, fullName))
			end
			loadedModules[key] = mod
		elseif skipModules[key] then
			dprint(("%s intentionally omitted from startup. Found at: %s"):format(key, fullName))
			loadedModules[key] = nil
		end
	end

	-- Second pass: call Init() on every successfully required module (safeInit will pcall with self)
	for name, mod in pairs(loadedModules) do
		-- skip nil entries
		if name and mod then
			safeInit(name, mod)
		end
	end

	-- Defensive fallback: if PlotManager didn't load, attempt explicit require from discovered set
	if not loadedModules["PlotManager"] then
		for fullName, inst in pairs(discovered) do
			if inst and inst.Name == "PlotManager" then
				local pm, err = safeRequireWithTrace(inst)
				if not pm then
					dprint(("[Fallback Require ERROR] PlotManager at %s failed to require:\n%s"):format(fullName, tostring(err)))
				else
					loadedModules["PlotManager"] = pm
					safeInit("PlotManager", pm)
					dprint("PlotManager required via fallback scan and Init() run.")
				end
				break
			end
		end
	end

	-- Final summary
	local loadedCount = 0
	for k,v in pairs(loadedModules) do
		if v ~= nil then loadedCount = loadedCount + 1 end
	end
	dprint(("Initialization complete. Discovered=%d SuccessfullyRequired=%d"):format(discoveredCount, loadedCount))
end

-- Run initialization in protected call
pcall(function() Init() end)

return {
	Init = Init,
}