--!strict
-- Capture & attachment prototype entry point (MS-02). One player owns the elevator.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProtoConfig") :: ModuleScript)
local Proto = script.Parent:WaitForChild("Proto")
local Store = require(Proto:WaitForChild("Store") :: ModuleScript)
local Capture = require(Proto:WaitForChild("Capture") :: ModuleScript)
local Attach = require(Proto:WaitForChild("Attach") :: ModuleScript)

local greybox = workspace:WaitForChild(Config.GREYBOX)

local remotes = Instance.new("Folder")
remotes.Name = Config.REMOTES
local notifyRemote = Instance.new("RemoteEvent")
notifyRemote.Name = "Notify"
notifyRemote.Parent = remotes
local previewRemote = Instance.new("RemoteEvent")
previewRemote.Name = "Preview"
previewRemote.Parent = remotes
local confirmRemote = Instance.new("RemoteFunction")
confirmRemote.Name = "ConfirmAttach"
confirmRemote.Parent = remotes
remotes.Parent = ReplicatedStorage

local ownerUserId: number? = nil

local function notify(player: Player, text: string)
	if player.Parent == Players then
		notifyRemote:FireClient(player, text)
	end
end

local function ownerPlayer(): Player?
	return if ownerUserId then Players:GetPlayerByUserId(ownerUserId) else nil
end

Capture.init({
	room = greybox:WaitForChild("TestRoom") :: Model,
	notify = notify,
	isOwner = function(player)
		return player.UserId == ownerUserId
	end,
})

Attach.init({
	elevator = greybox:WaitForChild("Elevator") :: Model,
	previewRemote = previewRemote,
	notify = notify,
	ownerPlayer = ownerPlayer,
})

confirmRemote.OnServerInvoke = function(player, socketId, tokenId)
	if player.UserId ~= ownerUserId then
		return { status = "rejected", reason = "not_owner" }
	end
	return Attach.confirm(player, socketId, tokenId)
end

local function onJoin(player: Player)
	if ownerUserId == nil then
		ownerUserId = player.UserId
	end
	if player.UserId == ownerUserId then
		Attach.join(player)
	end
end

Players.PlayerAdded:Connect(onJoin)
for _, p in Players:GetPlayers() do
	task.spawn(onJoin, p)
end
Players.PlayerRemoving:Connect(function(player)
	if player.UserId == ownerUserId then
		Attach.leave(player)
	end
end)

game:BindToClose(function()
	local waited = 0
	while Attach.hasPending() and waited < 25 do
		waited += task.wait(0.25)
	end
end)

print(string.format("[TLE Proto] capture+attach ready · store=%s", Store.backendName()))

-- Studio-only debug hook for MCP-driven tests (TEST-03).
if RunService:IsStudio() then
	local debugFn = Instance.new("BindableFunction")
	debugFn.Name = "TLE_Debug"
	debugFn.OnInvoke = function(cmd: string, a: any, b: any): any
		local owner = ownerPlayer()
		if not owner then
			return { error = "no_owner" }
		end
		if cmd == "state" then
			return Attach.debugState(owner)
		elseif cmd == "fault" then
			(Store.faults :: any)[a] = b
			return Store.faults
		elseif cmd == "trigger" then
			return { Capture.start(owner) }
		elseif cmd == "cancel" then
			return Capture.cancel(owner, "Захват отменён.")
		elseif cmd == "select" then
			return Attach.select(owner)
		elseif cmd == "confirm" then
			return Attach.confirm(owner, a, b)
		elseif cmd == "leave" then
			Attach.leave(owner)
			return true
		elseif cmd == "join" then
			Attach.join(owner)
			return Attach.debugState(owner)
		elseif cmd == "resetProfile" then
			Store.remove(Attach.profileKey(owner.UserId))
			return true
		end
		return { error = "unknown_cmd" }
	end
	debugFn.Parent = ServerStorage
end
