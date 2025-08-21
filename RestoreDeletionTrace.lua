-- Trace early deletion of restored tools (first 2 seconds).
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local WINDOW = 2
local TAGS = { "ProtectedRestore", "PersistentCaptured", "PersistentFoodTool" }

local function isWatched(t)
	for _,a in ipairs(TAGS) do
		if t:GetAttribute(a) then return true end
	end
	return false
end

local function clean(tb)
	local out={}
	for line in tb:gmatch("[^\n]+") do
		if not line:find("RestoreDeletionTrace") then
			out[#out+1]=line
		end
	end
	return table.concat(out,"\n")
end

local function hook(tool)
	if tool:GetAttribute("__DelTrace") then return end
	tool:SetAttribute("__DelTrace", true)
	local t0 = os.clock()
	local function report(why)
		local age = os.clock()-t0
		if age > WINDOW then return end
		warn(("[DeletionTrace] %s %s (%.2fs)\n%s")
			:format(tool.Name, why, age, clean(debug.traceback("",2))))
	end
	tool.AncestryChanged:Connect(function(_, parent)
		if not parent then report("Parent=nil") end
	end)
	tool.Destroying:Connect(function()
		report("Destroying")
	end)
end

local function scan(plr)
	local bp = plr:FindFirstChildOfClass("Backpack")
	if not bp then return end
	for _,t in ipairs(bp:GetChildren()) do
		if t:IsA("Tool") and isWatched(t) then
			hook(t)
		end
	end
end

Players.PlayerAdded:Connect(function(plr)
	local start = os.clock()
	local hb
	hb = RunService.Heartbeat:Connect(function()
		if os.clock()-start > WINDOW then
			if hb then hb:Disconnect() end
			return
		end
		scan(plr)
	end)
end)