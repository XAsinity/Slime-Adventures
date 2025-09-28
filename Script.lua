-- AnchorFolliage.lua
-- One-time utility to anchor every BasePart descendant of the folder named "Folliage".
-- Place (or run) this Script INSIDE ServerScriptService or anywhere; it will look for workspace.Folliage.
-- If (as you said) the Script is INSIDE the Folliage folder, it will still work (it skips non-BasePart instances).
--
-- Safety features:
--   * Only touches parts under the target folder.
--   * Optional dry run & undo data.
--   * Skips parts already anchored unless FORCE_REANCHOR is true.
--
-- After it finishes you can automatically destroy this script (AUTO_DESTROY_SCRIPT = true).
--
-- If you need to UNDO immediately after running (same session), keep COLLECT_UNDO_DATA=true
-- and run the printed undo snippet in the command bar.

----------------------------------------------------------------
-- CONFIG
----------------------------------------------------------------
local TARGET_FOLDER_NAME      = "Folliage"   -- Folder under workspace
local DRY_RUN                 = false        -- true = just count, do not change
local COLLECT_UNDO_DATA       = true         -- store prior Anchored states for quick undo
local FORCE_REANCHOR          = false        -- if true, will set Anchored=true even if already anchored (no difference normally)
local PRINT_PROGRESS_EVERY    = 1000         -- 0 to disable progress prints
local AUTO_DESTROY_SCRIPT     = true         -- remove this Script after completion
local CLEAR_VELOCITIES        = true         -- zero out linear/angular velocities (recommended for physics stability)

----------------------------------------------------------------
-- IMPLEMENTATION
----------------------------------------------------------------
local Workspace = game:GetService("Workspace")

local targetFolder = Workspace:FindFirstChild(TARGET_FOLDER_NAME)
if not targetFolder then
	warn(("[AnchorFolliage] Folder '%s' not found under workspace. Aborting."):format(TARGET_FOLDER_NAME))
	return
end

local undoData = COLLECT_UNDO_DATA and {} or nil

local total = 0
local changed = 0
local already = 0

for _, inst in ipairs(targetFolder:GetDescendants()) do
	if inst:IsA("BasePart") then
		total += 1
		if COLLECT_UNDO_DATA then
			table.insert(undoData, {ref=inst, wasAnchored=inst.Anchored})
		end
		if inst.Anchored and not FORCE_REANCHOR then
			already += 1
		else
			if not DRY_RUN then
				if CLEAR_VELOCITIES then
					-- Safe velocity clear
					local ok1 = pcall(function() inst.AssemblyLinearVelocity = Vector3.zero end)
					if not ok1 then pcall(function() inst.Velocity = Vector3.zero end) end
					local ok2 = pcall(function() inst.AssemblyAngularVelocity = Vector3.zero end)
					if not ok2 then pcall(function() inst.RotVelocity = Vector3.zero end) end
				end
				inst.Anchored = true
			end
			changed += 1
		end
		if PRINT_PROGRESS_EVERY > 0 and total % PRINT_PROGRESS_EVERY == 0 then
			print(string.format("[AnchorFolliage] Processed %d parts (anchored %d, already %d)",
				total, changed, already))
		end
	end
end

print(string.rep("-", 55))
print("[AnchorFolliage] COMPLETE")
print("Folder: "..targetFolder:GetFullName())
print(string.format("Total BaseParts scanned : %d", total))
print(string.format("Newly anchored          : %d", changed))
print(string.format("Already anchored        : %d", already))
print(string.format("Undo data collected     : %s", tostring(COLLECT_UNDO_DATA)))
print(string.format("Dry run                 : %s", tostring(DRY_RUN)))
print(string.rep("-", 55))

if COLLECT_UNDO_DATA then
	_G.__FolliageAnchorUndo = undoData
	print("-- Undo snippet (run in command bar to revert):")
	print([[
do
  local list = _G.__FolliageAnchorUndo
  if not list then warn("No undo data present.") return end
  local restored=0
  for _,rec in ipairs(list) do
    local p = rec.ref
    if p and p.Parent and p:IsA("BasePart") then
      p.Anchored = rec.wasAnchored
      restored += 1
    end
  end
  print(string.format("[AnchorFolliage][Undo] Restored %d parts", restored))
end
]])
end

if AUTO_DESTROY_SCRIPT and not DRY_RUN then
	local this = script
	task.defer(function()
		if this and this.Parent then
			this:Destroy()
		end
	end)
end