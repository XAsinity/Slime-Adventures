-- TableUtil.lua
local TableUtil = {}

function TableUtil.ShallowCopy(t)
	if type(t)~="table" then return t end
	local n = {}
	for k,v in pairs(t) do n[k]=v end
	return n
end

function TableUtil.DeepCopy(t)
	if type(t)~="table" then return t end
	local n = {}
	for k,v in pairs(t) do
		if type(v)=="table" then
			n[k]=TableUtil.DeepCopy(v)
		else
			n[k]=v
		end
	end
	return n
end

return TableUtil