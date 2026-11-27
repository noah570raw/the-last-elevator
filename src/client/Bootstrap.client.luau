--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

if not RunService:IsStudio() then
	return
end

local shared = ReplicatedStorage:WaitForChild("Shared")
local projectInfo = require(shared:WaitForChild("ProjectInfo") :: ModuleScript)

print(string.format("%s Client · %s", projectInfo.logPrefix, projectInfo.version))
