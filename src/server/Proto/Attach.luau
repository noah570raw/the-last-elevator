--!strict
-- Elevator socket attachment and profile restore (DEC-02, DEC-04).
-- Rule: one opId per attach operation, reused across retries; the module spawns only after the write is confirmed.

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Config = require(Shared:WaitForChild("ProtoConfig") :: ModuleScript)
local SocketMath = require(Shared:WaitForChild("SocketMath") :: ModuleScript)
local Store = require(script.Parent:WaitForChild("Store") :: ModuleScript)
local Capture = require(script.Parent:WaitForChild("Capture") :: ModuleScript)

type Op = { opId: string, instanceId: string, socketId: string, userId: number }
type Preview = { socketId: string, tokenId: string, startedAt: number }
type Session = {
	loaded: boolean,
	readOnly: boolean,
	locked: boolean,
	lockReason: string?,
	inflight: Op?,
	preview: Preview?, -- server record of the last select; confirm requires it (DEC-02 A4/A5)
}
export type Result = { status: string, reason: string?, instanceId: string? }

local Attach = {}

local sessions: { [Player]: Session } = {}
local pendingOps: { [number]: Op } = {}

local socket: BasePart
local door: BasePart
local frames: { BasePart } = {}
local template: Model
local attachedFolder: Folder
local selectPrompt: ProximityPrompt
local previewRemote: RemoteEvent
local notify: (Player, string) -> ()
local ownerPlayer: () -> Player?

local function profileKey(userId: number): string
	return "u_" .. userId
end

local function instanceIdFor(userId: number): string
	return Config.ROOM_ID .. ":" .. userId
end

local function setDoor(open: boolean)
	door.CanCollide = not open
	door.CanQuery = not open
	door.Transparency = if open then 1 else 0
end

local function socketOccupied(): boolean
	for _, m in attachedFolder:GetChildren() do
		if m:GetAttribute("SocketId") == Config.SOCKET_ID then
			return true
		end
	end
	return false
end

-- Exactly one module per instanceId.
local function spawnModule(userId: number, socketId: string): (Model, boolean)
	local id = instanceIdFor(userId)
	local existing = attachedFolder:FindFirstChild(id)
	if existing then
		return existing :: Model, false
	end
	local m = template:Clone()
	m.Name = id
	m:SetAttribute("OwnerUserId", userId)
	m:SetAttribute("SocketId", socketId)
	m:PivotTo(SocketMath.modulePivot(socket.CFrame, m))
	m.Parent = attachedFolder
	setDoor(true)
	return m, true
end

local function canSelect(player: Player): boolean
	local s = sessions[player]
	return s ~= nil
		and s.loaded
		and not s.readOnly
		and not s.locked
		and s.inflight == nil
		and Capture.getState() == "Captured"
		and Capture.getToken(player) ~= nil
		and not socketOccupied()
end

local function aliveRoot(player: Player): BasePart?
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if hum and root and hum.Health > 0 then
		return root
	end
	return nil
end

function Attach.refresh()
	local owner = ownerPlayer()
	local enabled = owner ~= nil and canSelect(owner)
	selectPrompt.Enabled = enabled
	door:SetAttribute("Selectable", enabled) -- clients derive local prompt state from this, never from Enabled
	for _, f in frames do
		f.Transparency = if enabled then 0.1 else 0.85
	end
end

-- Write the socket record with one opId; verify with an uncached read after any error.
-- Returns "committed" | "conflict" | "failed" (verified absent after all attempts) | "unverified".
local function commit(op: Op): string
	local key = profileKey(op.userId)
	local function transform(old: any): any
		local data = if type(old) == "table" then old else { schema = Config.SCHEMA, sockets = {} }
		data.sockets = data.sockets or {}
		local rec = data.sockets[op.socketId]
		if rec then
			if rec.opId == op.opId then
				return data -- already written by an earlier attempt
			end
			return nil -- socket taken by another operation: cancel write
		end
		data.schema = Config.SCHEMA
		data.sockets[op.socketId] = {
			roomId = Config.ROOM_ID,
			instanceId = op.instanceId,
			opId = op.opId,
			attachedAt = os.time(),
		}
		return data
	end
	local function written(data: any): string
		local rec = type(data) == "table" and data.sockets and data.sockets[op.socketId]
		if not rec then
			return "absent"
		end
		return if rec.opId == op.opId then "mine" else "other"
	end

	for attempt = 1, Config.SAVE_ATTEMPTS do
		local ok, result = Store.update(key, transform)
		if ok then
			local w = written(result)
			if w == "mine" then
				return "committed"
			elseif w == "other" then
				return "conflict"
			end
		else
			warn(string.format("[TLE Attach] write error op=%s attempt=%d: %s", op.opId, attempt, tostring(result)))
		end
		local gok, data = Store.get(key)
		if not gok then
			warn(string.format("[TLE Attach] verify failed op=%s: %s", op.opId, tostring(data)))
			return "unverified"
		end
		local w = written(data)
		if w == "mine" then
			return "committed"
		elseif w == "other" then
			return "conflict"
		end
		if attempt < Config.SAVE_ATTEMPTS then
			task.wait(Config.SAVE_BACKOFF[attempt])
		end
	end
	return "failed"
end

local function reject(reason: string): Result
	return { status = "rejected", reason = reason }
end

function Attach.confirm(player: Player, socketId: any, tokenId: any): Result
	if typeof(socketId) ~= "string" or typeof(tokenId) ~= "string" then
		return reject("bad_args")
	end
	local s = sessions[player]
	if not s or not s.loaded then
		return reject("not_loaded")
	end
	local id = instanceIdFor(player.UserId)
	if s.inflight then
		return { status = "pending", instanceId = s.inflight.instanceId }
	end
	if attachedFolder:FindFirstChild(id) then
		return { status = "attached", instanceId = id }
	end
	if s.readOnly then
		notify(player, Config.MSG_PROFILE_UNAVAILABLE)
		return reject("read_only")
	end
	if s.locked then
		return reject("locked")
	end
	if socketId ~= Config.SOCKET_ID then
		return reject("unknown_socket")
	end
	local tok = Capture.getToken(player)
	if not tok or tok.tokenId ~= tokenId then
		return reject("bad_token")
	end
	-- Preview validity is checked on the server, not only on the client.
	local pv = s.preview
	if not pv or pv.socketId ~= socketId or pv.tokenId ~= tokenId then
		return reject("no_preview")
	end
	if os.clock() - pv.startedAt > Config.PREVIEW_TIMEOUT + Config.PREVIEW_SERVER_SLACK_TIME then
		s.preview = nil
		return reject("preview_expired")
	end
	local root = aliveRoot(player)
	if not root then
		return reject("no_character")
	end
	if (root.Position - socket.Position).Magnitude > Config.PREVIEW_MAX_DISTANCE + Config.PREVIEW_SERVER_SLACK_DISTANCE then
		return reject("too_far")
	end
	if socketOccupied() then
		return reject("occupied")
	end
	if not SocketMath.isCompatible(socket, template) then
		return reject("incompatible")
	end

	local op: Op = { opId = HttpService:GenerateGUID(false), instanceId = id, socketId = socketId, userId = player.UserId }
	s.preview = nil -- one confirm per preview; repeats are answered by the inflight/attached checks above
	s.inflight = op
	pendingOps[op.userId] = op
	tok.inUse = true
	Attach.refresh()

	local outcome = commit(op)

	s.inflight = nil
	if pendingOps[op.userId] == op then
		pendingOps[op.userId] = nil
	end
	tok.inUse = false
	local stillHere = sessions[player] == s

	local result: Result
	if outcome == "committed" then
		if stillHere then
			spawnModule(op.userId, op.socketId)
			Capture.markAttached()
			notify(player, "Комната пристыкована.")
		end
		result = { status = "attached", instanceId = id }
	elseif outcome == "unverified" then
		s.locked = true
		s.lockReason = "unverified:" .. op.opId
		if stillHere then
			notify(player, "Не удалось подтвердить запись. Стыковка заблокирована до следующего входа.")
		end
		result = { status = "unverified", instanceId = id }
	elseif outcome == "conflict" then
		result = reject("occupied")
	else
		if stillHere then
			notify(player, "Стыковка не удалась. Попробуйте ещё раз.")
		end
		result = { status = "failed" }
	end
	Attach.refresh()
	return result
end

function Attach.select(player: Player): Result
	if not canSelect(player) then
		return reject("not_selectable")
	end
	local tok = Capture.getToken(player) :: Capture.Token
	local compatible = SocketMath.isCompatible(socket, template)
	local s = sessions[player] :: Session
	s.preview = { socketId = Config.SOCKET_ID, tokenId = tok.tokenId, startedAt = os.clock() }
	previewRemote:FireClient(player, Config.SOCKET_ID, tok.tokenId, compatible)
	return { status = if compatible then "preview" else "preview_incompatible" }
end

function Attach.join(player: Player)
	local s: Session = { loaded = false, readOnly = false, locked = false }
	sessions[player] = s
	Capture.setBlocked(Config.MSG_PROFILE_LOADING)

	-- An attach from a previous session may still be writing. Its outcome is unknown until it settles:
	-- keep the session unloaded (capture and attach blocked) for as long as it takes, then reconcile from the profile.
	local waited, noticed = 0, false
	while pendingOps[player.UserId] do
		waited += task.wait(0.25)
		if sessions[player] ~= s then
			return
		end
		if not noticed and waited >= Config.PENDING_NOTICE_AFTER then
			noticed = true
			notify(player, Config.MSG_SAVE_PENDING)
		end
	end

	local ok, data = false, nil
	for attempt = 1, Config.LOAD_ATTEMPTS do
		ok, data = Store.get(profileKey(player.UserId))
		if ok then
			break
		end
		warn(string.format("[TLE Attach] load error attempt=%d: %s", attempt, tostring(data)))
		if attempt < Config.LOAD_ATTEMPTS then
			task.wait(1)
		end
	end
	if sessions[player] ~= s then
		return
	end
	s.loaded = true
	if not ok then
		-- P5: read-only session blocks both capture and attachment on the server.
		s.readOnly = true
		Capture.setBlocked(Config.MSG_PROFILE_UNAVAILABLE)
		notify(player, Config.MSG_PROFILE_UNAVAILABLE)
		Attach.refresh()
		return
	end
	local rec = type(data) == "table" and data.sockets and data.sockets[Config.SOCKET_ID]
	if rec and rec.instanceId then
		spawnModule(player.UserId, Config.SOCKET_ID)
		Capture.markAttached()
		notify(player, "Пристыкованная комната восстановлена.")
	end
	Capture.setBlocked(nil)
	Attach.refresh()
end

function Attach.leave(player: Player)
	sessions[player] = nil
	Capture.resetForPlayer(player)
	Capture.setBlocked(nil)
	for _, m in attachedFolder:GetChildren() do
		if m:GetAttribute("OwnerUserId") == player.UserId then
			m:Destroy()
		end
	end
	if not socketOccupied() then
		setDoor(false)
	end
	Attach.refresh()
end

function Attach.hasPending(): boolean
	return next(pendingOps) ~= nil
end

function Attach.debugState(player: Player): { [string]: any }
	local s = sessions[player]
	local tok = Capture.getToken(player)
	local modules = 0
	for _ in attachedFolder:GetChildren() do
		modules += 1
	end
	return {
		backend = Store.backendName(),
		captureState = Capture.getState(),
		tokenId = tok and tok.tokenId,
		session = s and {
			loaded = s.loaded,
			readOnly = s.readOnly,
			locked = s.locked,
			lockReason = s.lockReason,
			inflight = s.inflight and s.inflight.opId,
			previewAge = s.preview and (os.clock() - s.preview.startedAt),
		},
		pendingWrite = pendingOps[player.UserId] ~= nil,
		modules = modules,
		doorOpen = not door.CanCollide,
		selectEnabled = selectPrompt.Enabled,
		stored = Store.peek(profileKey(player.UserId)),
	}
end

function Attach.profileKey(userId: number): string
	return profileKey(userId)
end

-- Debug (memory store only): age the current preview by `seconds`.
function Attach.debugAgePreview(player: Player, seconds: number): boolean
	local s = sessions[player]
	if not s or not s.preview then
		return false
	end
	s.preview.startedAt -= seconds
	return true
end

function Attach.init(opts: {
	elevator: Model,
	previewRemote: RemoteEvent,
	notify: (Player, string) -> (),
	ownerPlayer: () -> Player?,
})
	socket = opts.elevator:WaitForChild(Config.SOCKET_ID) :: BasePart
	door = opts.elevator:WaitForChild("SocketDoor") :: BasePart
	for _, name in { "SocketFrameL", "SocketFrameR", "SocketFrameTop" } do
		local f = opts.elevator:FindFirstChild(name)
		if f and f:IsA("BasePart") then
			table.insert(frames, f)
		end
	end
	template = ReplicatedStorage:WaitForChild(Config.TEMPLATES):WaitForChild(Config.MODULE_TEMPLATE) :: Model
	previewRemote = opts.previewRemote
	notify = opts.notify
	ownerPlayer = opts.ownerPlayer

	attachedFolder = workspace:FindFirstChild(Config.ATTACHED_FOLDER) :: Folder
	if not attachedFolder then
		attachedFolder = Instance.new("Folder")
		attachedFolder.Name = Config.ATTACHED_FOLDER
		attachedFolder.Parent = workspace
	end

	selectPrompt = Instance.new("ProximityPrompt")
	selectPrompt.Name = "SelectSocketPrompt"
	selectPrompt.ActionText = "Выбрать"
	selectPrompt.ObjectText = "Сокет лифта"
	selectPrompt.HoldDuration = 0
	selectPrompt.MaxActivationDistance = 8
	selectPrompt.RequiresLineOfSight = false
	selectPrompt.Enabled = false
	selectPrompt.Parent = door
	selectPrompt.Triggered:Connect(function(player)
		Attach.select(player)
	end)

	Capture.onChanged(Attach.refresh)
	setDoor(false)
	Attach.refresh()
end

return Attach
