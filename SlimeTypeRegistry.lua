-- SlimeTypeRegistry.lua
-- Central registry for mapping slime/egg types to their templates and default metadata.
-- Supports future expansion beyond the "Basic" slime by exposing registration helpers.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DEFAULT_TYPE = "Basic"

local registry = {}
local SlimeTypeRegistry = {}

local function shallowCopy(src)
	local dst = {}
	for k, v in pairs(src or {}) do
		dst[k] = v
	end
	return dst
end

local function resolvePath(path)
	if not path then return nil end
	if typeof(path) == "Instance" then return path end
	if type(path) == "string" then
		return ReplicatedStorage:FindFirstChild(path)
	end
	if type(path) ~= "table" then return nil end

	local node = ReplicatedStorage
	for _, segment in ipairs(path) do
		if typeof(node) ~= "Instance" then return nil end
		node = node:FindFirstChild(segment)
		if not node then return nil end
	end
	return node
end

local function normalizeDefinition(def)
	local normalized = shallowCopy(def or {})
	normalized.typeId = normalized.typeId or normalized.Type or normalized.type or DEFAULT_TYPE
	normalized.tier = normalized.tier or normalized.Tier or "Basic"
	normalized.displayName = normalized.displayName or normalized.DisplayName or normalized.typeId
	normalized.slug = normalized.slug or normalized.Slug or string.lower(tostring(normalized.typeId))
	return normalized
end

function SlimeTypeRegistry.Register(typeId, definition)
	if not typeId or type(typeId) ~= "string" then
		error("SlimeTypeRegistry.Register requires a string typeId", 2)
	end
	registry[typeId] = normalizeDefinition(shallowCopy(definition))
end

function SlimeTypeRegistry.Get(typeId)
	local target = registry[typeId]
	if target then return target end
	return registry[DEFAULT_TYPE]
end

function SlimeTypeRegistry.ResolveSlimeTemplate(typeId)
	local def = SlimeTypeRegistry.Get(typeId)
	if not def then return nil end
	return resolvePath(def.slimeTemplatePath or def.SlimeTemplate or def.SlimeModel)
end

function SlimeTypeRegistry.ResolveEggTemplate(typeId)
	local def = SlimeTypeRegistry.Get(typeId)
	if not def then return nil end
	return resolvePath(def.eggTemplatePath or def.EggTemplate or def.EggModel)
end

function SlimeTypeRegistry.GetDefaultType()
	return DEFAULT_TYPE
end

function SlimeTypeRegistry.Iterate()
	local list = {}
	for key, value in pairs(registry) do
		list[#list+1] = key
	end
	table.sort(list)
	local index = 0
	return function()
		index += 1
		local key = list[index]
		if not key then return nil end
		return key, registry[key]
	end
end

-- Seed the registry with the basic slime definition so current gameplay keeps working.
SlimeTypeRegistry.Register(DEFAULT_TYPE, {
	typeId = DEFAULT_TYPE,
	displayName = "Basic Slime",
	tier = "Basic",
	slimeTemplatePath = { "Assets", "Slime" },
	eggTemplatePath = { "Assets", "Egg" },
})

return SlimeTypeRegistry