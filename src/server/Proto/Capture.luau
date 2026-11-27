--!strict
-- Room capture state machine (DEC-01): Available -> Capturing -> Captured -> Attached.
-- Server-owned; clients read the room attributes CaptureState and CaptureProgress.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProtoConfig") :: ModuleScript)

export type Token = { tokenId: string, roomId: string, userId: number, inUse: boolean }
type Run = { player: Player, elapsed: number, outside: number, diedConn: RBXScriptConnection? }

local Capture = {}

local room: Model
local terminal: BasePart
local zone: BasePart
local light: PointLight?
local startPrompt: ProximityPrompt
local cancelPrompt: ProximityPrompt
local notify: (Player, string) -> ()
local isOwner: (Player) -> boolean

local state = "Available"
local blockedMessage: string? = nil -- set while the owner's profile is loading or unavailable (DEC-04 P5)
local token: Token? = nil
local capturing: Run? = nil
local listeners: { () -> () } = {}

local COLORS = {
	Available = Color3.fromRGB(80, 110, 140),
	Capturing = Color3.fromRGB(255, 170, 40),
	Captured = Color3.fromRGB(60, 220, 110),
	Attached = Color3.fromRGB(40, 150, 80),
}

local function setProgress(p: number)
	room:SetAttribute("CaptureProgress", p)
end

local function setState(s: string)
	state = s
	room:SetAttribute("CaptureState", s)
	terminal.Color = COLORS[s]
	if light then
		light.Color = COLORS[s]
		light.Brightness = 1
	end
	startPrompt.Enabled = s == "Available" and blockedMessage == nil
	cancelPrompt.Enabled = s == "Capturing"
	for _, cb in listeners do
		task.spawn(cb)
	end
end

local function inZone(pos: Vector3): boolean
	local rel = zone.CFrame:PointToObjectSpace(pos)
	local half = zone.Size / 2
	return math.abs(rel.X) <= half.X and math.abs(rel.Y) <= half.Y and math.abs(rel.Z) <= half.Z
end

local function aliveRoot(player: Player): (BasePart?, Humanoid?)
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hum and root and hum.Health > 0 then
		return root, hum
	end
	return nil, nil
end

local function stopRun(run: Run)
	if run.diedConn then
		run.diedConn:Disconnect()
	end
end

local function complete(run: Run)
	if capturing ~= run then
		return
	end
	capturing = nil
	stopRun(run)
	token = {
		tokenId = HttpService:GenerateGUID(false),
		roomId = Config.ROOM_ID,
		userId = run.player.UserId,
		inUse = false,
	}
	setProgress(1)
	setState("Captured")
	notify(run.player, "Комната захвачена. Выберите сокет в лифте.")
end

function Capture.cancel(player: Player, reason: string?): boolean
	local run = capturing
	if not run or run.player ~= player then
		return false
	end
	capturing = nil
	stopRun(run)
	setProgress(0)
	setState("Available")
	if reason then
		notify(player, reason)
	end
	return true
end

function Capture.start(player: Player): (boolean, string)
	if not isOwner(player) then
		return false, "not_owner"
	end
	if blockedMessage then
		notify(player, blockedMessage)
		return false, "blocked"
	end
	if state ~= "Available" then
		return false, "busy:" .. state
	end
	local root, hum = aliveRoot(player)
	if not root or not hum then
		return false, "no_character"
	end
	if not inZone(root.Position) then
		return false, "outside_zone"
	end

	local run: Run = { player = player, elapsed = 0, outside = 0 }
	capturing = run
	run.diedConn = hum.Died:Connect(function()
		Capture.cancel(player, "Захват прерван: персонаж погиб.")
	end)
	setProgress(0)
	setState("Capturing")

	task.spawn(function()
		local t = 0
		while capturing == run do
			local dt = task.wait(Config.CAPTURE_TICK)
			if capturing ~= run then
				break
			end
			t += dt
			local r = aliveRoot(player)
			if not r then
				Capture.cancel(player, "Захват прерван: персонаж погиб.")
				break
			end
			if inZone(r.Position) then
				run.outside = 0
				run.elapsed += dt
			else
				run.outside += dt
				if run.outside > Config.ZONE_GRACE then
					Capture.cancel(player, "Захват прерван: вы покинули зону.")
					break
				end
			end
			if light then
				light.Brightness = 1 + 0.8 * math.sin(t * 6)
			end
			setProgress(math.clamp(run.elapsed / Config.CAPTURE_SECONDS, 0, 1))
			if run.elapsed >= Config.CAPTURE_SECONDS then
				complete(run)
				break
			end
		end
	end)
	return true, "started"
end

function Capture.getState(): string
	return state
end

function Capture.getToken(player: Player): Token?
	if token and token.userId == player.UserId then
		return token
	end
	return nil
end

function Capture.markAttached()
	token = nil
	setProgress(1)
	setState("Attached")
end

-- Session teardown (leave): drop transient capture data (C6). Attached is restored from the profile on join.
function Capture.resetForPlayer(player: Player)
	Capture.cancel(player, nil)
	if token and token.userId == player.UserId then
		token = nil
	end
	setProgress(0)
	setState("Available")
end

-- nil unblocks; a message blocks capture start and is shown on each attempt.
function Capture.setBlocked(message: string?)
	blockedMessage = message
	setState(state)
end

function Capture.onChanged(cb: () -> ())
	table.insert(listeners, cb)
end

function Capture.init(opts: {
	room: Model,
	notify: (Player, string) -> (),
	isOwner: (Player) -> boolean,
})
	room = opts.room
	notify = opts.notify
	isOwner = opts.isOwner
	terminal = room:WaitForChild("CaptureTerminal") :: BasePart
	zone = room:WaitForChild("CaptureZone") :: BasePart
	light = terminal:FindFirstChildOfClass("PointLight")

	startPrompt = Instance.new("ProximityPrompt")
	startPrompt.Name = "CapturePrompt"
	startPrompt.ActionText = "Захватить"
	startPrompt.ObjectText = "Терминал комнаты"
	startPrompt.HoldDuration = Config.START_HOLD
	startPrompt.MaxActivationDistance = 10
	startPrompt.RequiresLineOfSight = false
	startPrompt.Parent = terminal
	startPrompt.Triggered:Connect(function(player)
		Capture.start(player)
	end)

	cancelPrompt = Instance.new("ProximityPrompt")
	cancelPrompt.Name = "CancelCapturePrompt"
	cancelPrompt.ActionText = "Отменить"
	cancelPrompt.ObjectText = "Захват"
	cancelPrompt.KeyboardKeyCode = Enum.KeyCode.X
	cancelPrompt.GamepadKeyCode = Enum.KeyCode.ButtonB
	cancelPrompt.HoldDuration = 0
	cancelPrompt.MaxActivationDistance = 10
	cancelPrompt.RequiresLineOfSight = false
	cancelPrompt.UIOffset = Vector2.new(0, 80)
	cancelPrompt.Parent = terminal
	cancelPrompt.Triggered:Connect(function(player)
		Capture.cancel(player, "Захват отменён.")
	end)

	setProgress(0)
	setState("Available")
end

return Capture
