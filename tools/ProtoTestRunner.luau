--!nocheck
-- TEST-03 server-side runner for the capture & attachment prototype.
-- Synced by Rojo to ServerStorage.TLE_TestRunner. In Studio Play, Server datamodel:
--   return require(game.ServerStorage.TLE_TestRunner).run("capture")
-- Groups: "capture", "attach", "preview", "persist", "longwrite".
-- Refuses to run unless the in-memory test store is active (never touches DataStore profiles).

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local SOCKET = "Socket_A"
local D -- TLE_Debug, resolved in run()

local function player()
	return Players:GetPlayers()[1]
end
local function state()
	return D:Invoke("state")
end
local function room()
	return workspace.TLE_Greybox.TestRoom
end
local function startPrompt()
	return room().CaptureTerminal.CapturePrompt
end
local function waitAlive()
	local t0 = os.clock()
	while os.clock() - t0 < 10 do
		local c = player().Character
		local h = c and c:FindFirstChildOfClass("Humanoid")
		if h and h.Health > 0 and c:FindFirstChild("HumanoidRootPart") then
			return
		end
		task.wait(0.25)
	end
end
local function moveTo(cf)
	waitAlive()
	player().Character:PivotTo(cf)
	task.wait(0.3)
end
local function toRoom()
	moveTo(CFrame.new(-10, 4, 108))
end
local function toSocket()
	moveTo(CFrame.lookAt(Vector3.new(1, 4, 65), Vector3.new(6, 4, 65)))
end
local function clearFaults()
	for _, k in { "latency", "updateFailBefore", "updateFailAfter", "getFail" } do
		D:Invoke("fault", k, 0)
	end
end
local function rejoin()
	D:Invoke("leave")
	return D:Invoke("join")
end
local function fresh()
	clearFaults()
	D:Invoke("resetProfile")
	return rejoin()
end
local function capture()
	toRoom()
	D:Invoke("trigger")
	local t0 = os.clock()
	while state().captureState ~= "Captured" and os.clock() - t0 < 11 do
		task.wait(0.25)
	end
	return state().tokenId
end
local function select()
	toSocket()
	return D:Invoke("select")
end
local function confirm(tok)
	return D:Invoke("confirm", SOCKET, tok)
end
local function selectConfirm(tok)
	select()
	return confirm(tok)
end
local function modules()
	return #workspace.TLE_Attached:GetChildren()
end
local function hasRecord(s)
	return s.stored ~= nil and s.stored.sockets ~= nil and s.stored.sockets[SOCKET] ~= nil
end

local groups = {}

groups.capture = function(check)
	fresh()
	toRoom()
	local r0 = D:Invoke("trigger")
	task.wait(0.3)
	local r1 = D:Invoke("trigger")
	check(1, r0[1] == true and state().captureState == "Capturing", "start=" .. tostring(r0[2]))
	check(3, r1[1] == false and r1[2] == "busy:Capturing" and not startPrompt().Enabled, "repeat=" .. tostring(r1[2]))
	local t0 = os.clock()
	while state().captureState == "Capturing" and os.clock() - t0 < 11 do
		task.wait(0.25)
	end
	local s = state()
	local r2 = D:Invoke("trigger")
	check(2, s.captureState == "Captured" and s.tokenId ~= nil and state().tokenId == s.tokenId and s.selectEnabled,
		string.format("t=%.1fs repeatAfter=%s", os.clock() - t0, tostring(r2[2])))

	local s6 = rejoin()
	check(6, s6.captureState == "Available" and s6.tokenId == nil and s6.stored == nil and s6.modules == 0, "after rejoin " .. s6.captureState)

	toRoom()
	D:Invoke("trigger")
	moveTo(CFrame.new(0, 4, 80))
	task.wait(0.3)
	local mid = room():GetAttribute("CaptureState")
	task.wait(1.4)
	local s4 = state()
	check(4, mid == "Capturing" and s4.captureState == "Available" and room():GetAttribute("CaptureProgress") == 0,
		"at0.6=" .. tostring(mid) .. " at2=" .. s4.captureState)

	toRoom()
	D:Invoke("trigger")
	task.wait(1)
	player().Character:FindFirstChildOfClass("Humanoid").Health = 0
	task.wait(0.3)
	local s5 = state()
	check(5, s5.captureState == "Available" and s5.tokenId == nil, "after death " .. s5.captureState)
	waitAlive()
end

groups.attach = function(check)
	fresh()
	local tok = capture()
	local sel = select()
	local s9 = state()
	check(9, sel.status == "preview" and s9.modules == 0 and s9.stored == nil and s9.tokenId == tok, "server unchanged during preview")

	workspace.TLE_Greybox.Elevator.Socket_A:SetAttribute("SocketType", "Door4")
	local sel12 = select()
	local r12 = confirm(tok)
	workspace.TLE_Greybox.Elevator.Socket_A:SetAttribute("SocketType", "Door8")
	local s12 = state()
	check(12, sel12.status == "preview_incompatible" and r12.reason == "incompatible" and s12.tokenId == tok and s12.modules == 0,
		sel12.status .. " / " .. tostring(r12.reason))

	local s13 = rejoin()
	check(13, s13.captureState == "Available" and s13.modules == 0 and s13.stored == nil, "after rejoin in preview")

	-- 11: concurrent confirms after one select
	tok = capture()
	select()
	D:Invoke("fault", "latency", 0.5)
	local res = {}
	for i = 1, 2 do
		task.spawn(function()
			res[i] = confirm(tok).status
		end)
	end
	local t0 = os.clock()
	while not (res[1] and res[2]) and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	D:Invoke("fault", "latency", 0)
	local third = confirm(tok)
	local s11 = state()
	check(11, modules() == 1 and hasRecord(s11) and third.status == "attached"
		and ((res[1] == "attached" and res[2] == "pending") or (res[2] == "attached" and res[1] == "pending")),
		tostring(res[1]) .. "+" .. tostring(res[2]) .. " third=" .. third.status .. " modules=" .. modules())

	local s16 = rejoin()
	local r16 = D:Invoke("trigger")
	check(16, s16.captureState == "Attached" and s16.modules == 1 and r16[2] == "busy:Attached", "restored, trigger=" .. tostring(r16[2]))

	local s18 = fresh()
	check(18, s18.captureState == "Available" and s18.modules == 0 and s18.stored == nil and not s18.doorOpen, "clean")

	tok = capture()
	select()
	D:Invoke("fault", "updateFailAfter", 1)
	local r19 = confirm(tok)
	local again = confirm(tok)
	check(19, r19.status == "attached" and again.status == "attached" and modules() == 1 and hasRecord(state()), "status=" .. r19.status)

	fresh()
	tok = capture()
	select()
	D:Invoke("fault", "updateFailBefore", 3)
	t0 = os.clock()
	local r15 = confirm(tok)
	local dur = os.clock() - t0
	local s15 = state()
	local retryNoSelect = confirm(tok)
	local retry = selectConfirm(tok)
	check(15, r15.status == "failed" and s15.captureState == "Captured" and s15.tokenId == tok and s15.modules == 0 and s15.stored == nil
		and retryNoSelect.reason == "no_preview" and retry.status == "attached",
		string.format("failed in %.1fs, retry w/o select=%s, retry=%s", dur, tostring(retryNoSelect.reason), retry.status))

	for _, variant in { "updateFailBefore", "updateFailAfter" } do
		fresh()
		tok = capture()
		select()
		D:Invoke("fault", variant, 1)
		D:Invoke("fault", "getFail", 1)
		local r = confirm(tok)
		local s = state()
		local blocked = confirm(tok)
		local j = rejoin()
		local expectAttached = variant == "updateFailAfter"
		check("20/" .. variant, r.status == "unverified" and s.session.locked and s.modules == 0 and blocked.reason == "locked"
			and j.session.locked == false
			and (if expectAttached then j.modules == 1 and j.captureState == "Attached" else j.modules == 0 and j.captureState == "Available"),
			"next join " .. j.captureState .. " modules=" .. j.modules)
	end
end

-- Server-side preview validation (review fix 2)
groups.preview = function(check)
	fresh()
	local tok = capture()
	toSocket()
	local r21 = confirm(tok)
	check(21, r21.reason == "no_preview" and modules() == 0, "confirm without select=" .. tostring(r21.reason))

	select()
	D:Invoke("agePreview", 25)
	local r22 = confirm(tok)
	check(22, r22.reason == "preview_expired" and modules() == 0, "aged preview=" .. tostring(r22.reason))

	select()
	moveTo(CFrame.new(0, 4, 82))
	local r23 = confirm(tok)
	check(23, r23.reason == "too_far" and modules() == 0 and state().tokenId == tok, "far confirm=" .. tostring(r23.reason))

	select()
	player().Character:FindFirstChildOfClass("Humanoid").Health = 0
	task.wait(0.2)
	local r24 = confirm(tok)
	check(24, r24.reason == "no_character" and modules() == 0, "dead confirm=" .. tostring(r24.reason))
	waitAlive()

	local r25 = selectConfirm(tok)
	local again = confirm(tok)
	check(25, r25.status == "attached" and again.status == "attached" and modules() == 1, "valid=" .. r25.status .. " repeat=" .. again.status)
	fresh()
end

groups.persist = function(check)
	for _, case in { "writeSucceeds", "writeFails" } do
		fresh()
		local tok = capture()
		select()
		D:Invoke("fault", "latency", 2)
		if case == "writeFails" then
			D:Invoke("fault", "updateFailBefore", 3)
		end
		task.spawn(confirm, tok)
		task.wait(0.3)
		D:Invoke("leave")
		local afterLeave = modules()
		local j = D:Invoke("join")
		clearFaults()
		local ok = afterLeave == 0
			and (if case == "writeSucceeds" then j.modules == 1 and j.captureState == "Attached" else j.modules == 0 and j.captureState == "Available")
		check("14/" .. case, ok, "next join " .. j.captureState .. " modules=" .. j.modules)
	end

	fresh()
	local tok = capture()
	selectConfirm(tok)
	local before = HttpService:JSONEncode(state().stored)
	D:Invoke("fault", "getFail", 3)
	local j = rejoin()
	toRoom()
	local trig = D:Invoke("trigger")
	local promptOn = startPrompt().Enabled
	local conf = confirm("any")
	local s = state()
	local j2 = rejoin()
	check(17, j.session.readOnly and j.modules == 0 and not j.selectEnabled and trig[2] == "blocked" and not promptOn
		and s.captureState == "Available" and conf.reason == "read_only" and HttpService:JSONEncode(s.stored) == before
		and j2.session.readOnly == false and j2.modules == 1,
		string.format("trigger=%s prompt=%s confirm=%s recovered=%d", tostring(trig[2]), tostring(promptOn), tostring(conf.reason), j2.modules))
	fresh()
end

-- Rejoin while an earlier write runs longer than the 30 s notice (review fix 3)
groups.longwrite = function(check)
	for _, case in { "writeSucceeds", "writeFails" } do
		fresh()
		local tok = capture()
		select()
		-- Latency is read when a call starts: only the first write attempt takes 34 s.
		D:Invoke("fault", "latency", 34)
		if case == "writeFails" then
			D:Invoke("fault", "updateFailBefore", 3) -- all three attempts fail without writing
		end
		task.spawn(confirm, tok)
		task.wait(0.3)
		D:Invoke("fault", "latency", 0)
		D:Invoke("leave")
		task.spawn(function()
			D:Invoke("join")
		end)
		task.wait(31) -- past the old 30 s cap
		local mid = state()
		toRoom()
		local trig = D:Invoke("trigger")
		local blockedOk = mid.pendingWrite and mid.session and mid.session.loaded == false and not mid.selectEnabled
			and trig[2] == "blocked" and mid.modules == 0
		local t0 = os.clock()
		local s
		repeat
			task.wait(0.5)
			s = state()
		until (s.session and s.session.loaded) or os.clock() - t0 > 30
		clearFaults()
		local expect = if case == "writeSucceeds"
			then s.captureState == "Attached" and s.modules == 1 and hasRecord(s)
			else s.captureState == "Available" and s.modules == 0 and not hasRecord(s)
		check("26/" .. case, blockedOk and expect,
			string.format("at31s pending=%s loaded=%s trigger=%s | after: %s modules=%d", tostring(mid.pendingWrite),
				tostring(mid.session and mid.session.loaded), tostring(trig[2]), s.captureState, s.modules))
	end
	fresh()
end

local Runner = {}

function Runner.run(group: string): string
	D = ServerStorage:FindFirstChild("TLE_Debug")
	if not D then
		return "ABORT: TLE_Debug missing (not in Studio Play?)"
	end
	local backend = D:Invoke("state").backend
	if backend ~= "memory" then
		return "ABORT: store=" .. tostring(backend) .. "; runner works on the in-memory test store only. Nothing was changed."
	end
	if not groups[group] then
		return "ABORT: unknown group " .. tostring(group)
	end
	local results = {}
	local function check(id, ok, detail)
		table.insert(results, string.format("%s %s — %s", tostring(id), if ok then "PASS" else "FAIL", detail))
	end
	local ok, err = pcall(groups[group], check)
	clearFaults()
	if not ok then
		table.insert(results, "ERROR " .. tostring(err))
	end
	return table.concat(results, "\n")
end

return Runner
