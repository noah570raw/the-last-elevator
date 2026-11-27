--!strict
-- Client side of the capture & attachment prototype: status HUD, messages, socket preview (client-only ghost).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("ProtoConfig") :: ModuleScript)
local SocketMath = require(Shared:WaitForChild("SocketMath") :: ModuleScript)

local player = Players.LocalPlayer
local remotes = ReplicatedStorage:WaitForChild(Config.REMOTES)
local notifyRemote = remotes:WaitForChild("Notify") :: RemoteEvent
local previewRemote = remotes:WaitForChild("Preview") :: RemoteEvent
local confirmRemote = remotes:WaitForChild("ConfirmAttach") :: RemoteFunction

local greybox = workspace:WaitForChild(Config.GREYBOX)
local room = greybox:WaitForChild("TestRoom")
local elevator = greybox:WaitForChild("Elevator")
local socket = elevator:WaitForChild(Config.SOCKET_ID) :: BasePart
local door = elevator:WaitForChild("SocketDoor") :: BasePart
local template = ReplicatedStorage:WaitForChild(Config.TEMPLATES):WaitForChild(Config.MODULE_TEMPLATE) :: Model

-- HUD
local gui = Instance.new("ScreenGui")
gui.Name = "TLE_ProtoHUD"
gui.ResetOnSpawn = false
local status = Instance.new("TextLabel")
status.Name = "Status"
status.AnchorPoint = Vector2.new(0.5, 0)
status.Position = UDim2.new(0.5, 0, 0, 12)
status.Size = UDim2.fromOffset(360, 32)
status.BackgroundTransparency = 0.35
status.BackgroundColor3 = Color3.fromRGB(20, 22, 26)
status.TextColor3 = Color3.new(1, 1, 1)
status.Font = Enum.Font.GothamMedium
status.TextSize = 18
status.Parent = gui
local message = status:Clone()
message.Name = "Message"
message.Position = UDim2.new(0.5, 0, 0, 50)
message.Size = UDim2.fromOffset(520, 30)
message.TextSize = 16
message.Visible = false
message.Parent = gui
gui.Parent = player:WaitForChild("PlayerGui")

local STATE_TEXT = {
	Available = "Комната: доступна",
	Capturing = "Захват: %d%%",
	Captured = "Комната захвачена",
	Attached = "Комната пристыкована",
}

local function renderStatus()
	local s = room:GetAttribute("CaptureState") or "Available"
	local p = room:GetAttribute("CaptureProgress") or 0
	local fmt = STATE_TEXT[s] or s
	status.Text = if s == "Capturing" then string.format(fmt, math.floor(p * 100)) else fmt
end
room:GetAttributeChangedSignal("CaptureState"):Connect(renderStatus)
room:GetAttributeChangedSignal("CaptureProgress"):Connect(renderStatus)
renderStatus()

local messageSeq = 0
local function showMessage(text: string)
	messageSeq += 1
	local seq = messageSeq
	message.Text = text
	message.Visible = true
	task.delay(4, function()
		if messageSeq == seq then
			message.Visible = false
		end
	end)
end
notifyRemote.OnClientEvent:Connect(showMessage)

-- Preview (DEC-02 A4–A7)
type Preview = { ghost: Model, confirm: ProximityPrompt, cancel: ProximityPrompt, alive: boolean }
local current: Preview? = nil

-- The server publishes availability in the door attribute "Selectable"; the local prompt is hidden
-- only while a preview is open and restored from that attribute afterwards.
local function applySelectPrompt()
	local select = door:FindFirstChild("SelectSocketPrompt") :: ProximityPrompt?
	if not select then
		return
	end
	local want = door:GetAttribute("Selectable") == true and current == nil
	if select.Enabled ~= want then
		select.Enabled = want
	end
end
door:GetAttributeChangedSignal("Selectable"):Connect(applySelectPrompt)
door.ChildAdded:Connect(function(child)
	if child.Name == "SelectSocketPrompt" then
		(child :: ProximityPrompt):GetPropertyChangedSignal("Enabled"):Connect(applySelectPrompt)
		applySelectPrompt()
	end
end)
do
	local select = door:FindFirstChild("SelectSocketPrompt") :: ProximityPrompt?
	if select then
		select:GetPropertyChangedSignal("Enabled"):Connect(applySelectPrompt)
	end
end

local function endPreview(reason: string?)
	local pv = current
	if not pv then
		return
	end
	current = nil
	pv.alive = false
	pv.ghost:Destroy()
	pv.confirm:Destroy()
	pv.cancel:Destroy()
	applySelectPrompt()
	if reason then
		showMessage(reason)
	end
end

local function makeGhost(compatible: boolean): Model
	local ghost = template:Clone()
	ghost.Name = "TLE_Ghost"
	local color = if compatible then Color3.fromRGB(60, 255, 120) else Color3.fromRGB(255, 60, 60)
	for _, d in ghost:GetDescendants() do
		if d:IsA("BasePart") then
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
			d.Material = Enum.Material.ForceField
			d.Color = color
			if d.Transparency < 1 then
				d.Transparency = 0.4
			end
		elseif d:IsA("Light") then
			d.Enabled = false
		end
	end
	ghost:SetAttribute("Compatible", compatible)
	ghost:PivotTo(SocketMath.modulePivot(socket.CFrame, ghost))
	ghost.Parent = workspace.CurrentCamera
	return ghost
end

local function startPreview(socketId: string, tokenId: string, compatible: boolean)
	endPreview(nil)

	local confirm = Instance.new("ProximityPrompt")
	confirm.Name = "TLE_ConfirmAttach"
	confirm.ActionText = if compatible then "Пристыковать" else "Несовместимый сокет"
	confirm.ObjectText = "Модуль " .. Config.ROOM_ID
	confirm.HoldDuration = Config.CONFIRM_HOLD
	confirm.MaxActivationDistance = 8
	confirm.RequiresLineOfSight = false
	confirm.Enabled = compatible
	confirm.Parent = door

	local cancel = Instance.new("ProximityPrompt")
	cancel.Name = "TLE_CancelPreview"
	cancel.ActionText = "Отменить"
	cancel.KeyboardKeyCode = Enum.KeyCode.X
	cancel.GamepadKeyCode = Enum.KeyCode.ButtonB
	cancel.HoldDuration = 0
	cancel.MaxActivationDistance = 8
	cancel.RequiresLineOfSight = false
	cancel.UIOffset = Vector2.new(0, 80)
	cancel.Parent = door

	local pv: Preview = { ghost = makeGhost(compatible), confirm = confirm, cancel = cancel, alive = true }
	current = pv
	applySelectPrompt()

	cancel.Triggered:Connect(function()
		endPreview("Предпросмотр отменён.")
	end)
	confirm.Triggered:Connect(function()
		if not pv.alive or not confirm.Enabled then
			return
		end
		confirm.Enabled = false -- block double confirm until the server answers
		confirm.ActionText = "Стыковка…"
		local ok, result = pcall(function()
			return confirmRemote:InvokeServer(socketId, tokenId)
		end)
		if current == pv then
			endPreview(nil)
		end
		if not ok then
			showMessage("Нет ответа сервера.")
		elseif type(result) == "table" and result.status == "rejected" then
			showMessage("Стыковка отклонена: " .. tostring(result.reason))
		end
	end)

	-- Auto-cancel: distance or timeout
	task.spawn(function()
		local started = os.clock()
		while pv.alive do
			task.wait(0.25)
			if not pv.alive then
				break
			end
			local char = player.Character
			local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not root or (root.Position - socket.Position).Magnitude > Config.PREVIEW_MAX_DISTANCE then
				endPreview("Предпросмотр отменён: вы отошли от сокета.")
			elseif os.clock() - started > Config.PREVIEW_TIMEOUT then
				endPreview("Предпросмотр отменён: время вышло.")
			end
		end
	end)
end

previewRemote.OnClientEvent:Connect(startPreview)
