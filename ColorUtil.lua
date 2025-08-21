-- ColorUtil.lua
local ColorUtil = {}

function ColorUtil.ColorToHex(c: Color3)
	return string.format("%02X%02X%02X",
		math.floor(c.R*255+0.5),
		math.floor(c.G*255+0.5),
		math.floor(c.B*255+0.5))
end

function ColorUtil.HexToColor(hex: string)
	if type(hex)~="string" or #hex<6 then return nil end
	hex = hex:gsub("^#","")
	local r = tonumber(hex:sub(1,2),16)
	local g = tonumber(hex:sub(3,4),16)
	local b = tonumber(hex:sub(5,6),16)
	if not r or not g or not b then return nil end
	return Color3.fromRGB(r,g,b)
end

return ColorUtil