--!nocheck
-- TEST-03 server-side runner for the capture & attachment prototype.
-- Not synced by Rojo. Paste into ServerStorage.TLE_TestRunner (ModuleScript) and, during Studio Play
-- on the Server datamodel, run: return require(game.ServerStorage.TLE_TestRunner).run("capture")
-- Groups: "capture", "attach", "persist". Client-side checks (real prompts, ghost) run separately.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ServerStorage = game:GetService("ServerStorage")

local D = ServerStorage:WaitForChild("TLE_Debug")
local SOCKET = "Socket_A"

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
		string.format("t=%.1fs token=%s repeatAfter=%s", os.clock() - t0, tostring(s.tokenId ~= nil), tostring(r2[2])))

	local s6 = rejoin()
	check(6, s6.captureState == "Available" and s6.tokenId == nil and s6.stored == nil and s6.modules == 0, "after rejoin " .. s6.captureState)

	toRoom()
	D:Invoke("trigger")
	moveTo(CFrame.new(0, 4, 80))
	task.wait(0.3) -- ~0.6 s outside: still capturing (grace 1 s)
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
	toSocket()
	local sel = D:Invoke("select")
	local s9 = state()
	check(9, sel.status == "preview" and s9.modules == 0 and s9.stored == nil and s9.tokenId == tok,
		"server unchanged during preview")

	workspace.TLE_Greybox.Elevator.Socket_A:SetAttribute("SocketType", "Door4")
	local sel12 = D:Invoke("select")
	local r12 = D:Invoke("confirm", SOCKET, tok)
	workspace.TLE_Greybox.Elevator.Socket_A:SetAttribute("SocketType", "Door8")
	local s12 = state()
	check(12, sel12.status == "preview_incompatible" and r12.reason == "incompatible" and s12.tokenId == tok and s12.modules == 0,
		sel12.status .. " / " .. tostring(r12.reason))

	local s13 = rejoin()
	check(13, s13.captureState == "Available" and s13.modules == 0 and s13.stored == nil, "after rejoin in preview")

	-- 11: concurrent confirms
	tok = capture()
	D:Invoke("fault", "latency", 0.5)
	local res = {}
	for i = 1, 2 do
		task.spawn(function()
			res[i] = D:Invoke("confirm", SOCKET, tok).status
		end)
	end
	local t0 = os.clock()
	while not (res[1] and res[2]) and os.clock() - t0 < 10 do
		task.wait(0.1)
	end
	D:Invoke("fault", "latency", 0)
	local s11 = state()
	check(11, modules() == 1 and hasRecord(s11) and ((res[1] == "attached" and res[2] == "pending") or (res[2] == "attached" and res[1] == "pending")),
		tostring(res[1]) .. "+" .. tostring(res[2]) .. " modules=" .. modules())

	local s16 = rejoin()
	local r16 = D:Invoke("trigger")
	check(16, s16.captureState == "Attached" and s16.modules == 1 and r16[2] == "busy:Attached", "restored, trigger=" .. tostring(r16[2]))

	local s18 = fresh()
	check(18, s18.captureState == "Available" and s18.modules == 0 and s18.stored == nil and not s18.doorOpen, "clean")

	-- 19: write committed, response lost
	tok = capture()
	D:Invoke("fault", "updateFailAfter", 1)
	local r19 = D:Invoke("confirm", SOCKET, tok)
	local again = D:Invoke("confirm", SOCKET, tok)
	check(19, r19.status == "attached" and again.status == "attached" and modules() == 1 and hasRecord(state()), "status=" .. r19.status)

	-- 15: three failed writes
	fresh()
	tok = capture()
	D:Invoke("fault", "updateFailBefore", 3)
	t0 = os.clock()
	local r15 = D:Invoke("confirm", SOCKET, tok)
	local dur = os.clock() - t0
	local s15 = state()
	local retry = D:Invoke("confirm", SOCKET, tok)
	check(15, r15.status == "failed" and s15.captureState == "Captured" and s15.tokenId == tok and s15.modules == 0 and s15.stored == nil and retry.status == "attached",
		string.format("failed in %.1fs, retry=%s", dur, retry.status))

	-- 20: unverified (write failed / write committed), both with failed verify
	for _, variant in { "updateFailBefore", "updateFailAfter" } do
		fresh()
		tok = capture()
		D:Invoke("fault", variant, 1)
		D:Invoke("fault", "getFail", 1)
		local r = D:Invoke("confirm", SOCKET, tok)
		local s = state()
		local blocked = D:Invoke("confirm", SOCKET, tok)
		local j = rejoin()
		local expectAttached = variant == "updateFailAfter"
		check("20/" .. variant, r.status == "unverified" and s.session.locked and s.modules == 0 and blocked.reason == "locked"
			and j.session.locked == false and (if expectAttached then j.modules == 1 and j.captureState == "Attached" else j.modules == 0 and j.captureState == "Available"),
			"next join " .. j.captureState .. " modules=" .. j.modules)
	end
end

groups.persist = function(check)
	for _, case in { "writeSucceeds", "writeFails" } do
		fresh()
		local tok = capture()
		D:Invoke("fault", "latency", 2)
		if case == "writeFails" then
			D:Invoke("fault", "updateFailBefore", 3)
		end
		task.spawn(function()
			D:Invoke("confirm", SOCKET, tok)
		end)
		task.wait(0.3)
		D:Invoke("leave")
		local afterLeave = modules()
		local j = D:Invoke("join")
		clearFaults()
		local ok = afterLeave == 0 and (if case == "writeSucceeds" then j.modules == 1 and j.captureState == "Attached" else j.modules == 0 and j.captureState == "Available")
		check("14/" .. case, ok, "next join " .. j.captureState .. " modules=" .. j.modules)
	end

	-- 17: load failure -> read-only, capture and attachment blocked on the server
	fresh()
	local tok = capture()
	D:Invoke("confirm", SOCKET, tok)
	local before = HttpService:JSONEncode(state().stored)
	D:Invoke("fault", "getFail", 3)
	local j = rejoin()
	toRoom()
	local trig = D:Invoke("trigger")
	local promptOn = startPrompt().Enabled
	local conf = D:Invoke("confirm", SOCKET, "any")
	local s = state()
	local j2 = rejoin()
	check(17, j.session.readOnly and j.modules == 0 and not j.selectEnabled and trig[2] == "blocked" and not promptOn
		and s.captureState == "Available" and conf.reason == "read_only" and HttpService:JSONEncode(s.stored) == before
		and j2.session.readOnly == false and j2.modules == 1,
		string.format("trigger=%s prompt=%s confirm=%s storedSame=%s recovered=%d", tostring(trig[2]), tostring(promptOn), tostring(conf.reason),
			tostring(HttpService:JSONEncode(s.stored) == before), j2.modules))
	fresh()
end

local Runner = {}

function Runner.run(group: string)
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
