--!strict
-- Profile storage for the prototype (DEC-04). Backends: in-memory test store (default) or DataStore TLE_Proto_v1.
-- Fault injection wraps any backend so failure scenarios run identically on both.

local DataStoreService = game:GetService("DataStoreService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage:WaitForChild("Shared"):WaitForChild("ProtoConfig") :: ModuleScript)

export type Transform = (old: any) -> any

local Store = {}

Store.faults = {
	latency = 0, -- seconds before each call
	updateFailBefore = 0, -- next N updates error without writing
	updateFailAfter = 0, -- next N updates write, then error (response lost)
	getFail = 0, -- next N gets error
}

local function deepCopy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

local memory: { [string]: any } = {}

local memoryBackend = {
	update = function(key: string, transform: Transform): any
		local new = transform(deepCopy(memory[key]))
		if new ~= nil then
			memory[key] = deepCopy(new)
		end
		return deepCopy(memory[key])
	end,
	get = function(key: string): any
		return deepCopy(memory[key])
	end,
	remove = function(key: string)
		memory[key] = nil
	end,
}

local dataStore: DataStore? = nil
local function ds(): DataStore
	if not dataStore then
		dataStore = DataStoreService:GetDataStore(Config.STORE_NAME)
	end
	return dataStore :: DataStore
end

local dataStoreBackend = {
	update = function(key: string, transform: Transform): any
		return (ds():UpdateAsync(key, function(old)
			return transform(old)
		end))
	end,
	get = function(key: string): any
		local options = Instance.new("DataStoreGetOptions")
		options.UseCache = false
		return (ds():GetAsync(key, options))
	end,
}

function Store.backendName(): string
	return if workspace:GetAttribute(Config.BACKEND_ATTRIBUTE) == "datastore" then "datastore" else "memory"
end

local function backend()
	return if Store.backendName() == "datastore" then dataStoreBackend else memoryBackend
end

local NO_FAULTS = table.freeze({ latency = 0, updateFailBefore = 0, updateFailAfter = 0, getFail = 0 })

-- Fault injection applies only to the in-memory test store, never to DataStore.
local function activeFaults(): any
	return if Store.backendName() == "memory" then Store.faults else NO_FAULTS
end

function Store.update(key: string, transform: Transform): (boolean, any)
	local f = activeFaults()
	if f.latency > 0 then
		task.wait(f.latency)
	end
	if f.updateFailBefore > 0 then
		f.updateFailBefore -= 1
		return false, "fault: update failed before write"
	end
	local ok, result = pcall(backend().update, key, transform)
	if not ok then
		return false, result
	end
	if f.updateFailAfter > 0 then
		f.updateFailAfter -= 1
		return false, "fault: write committed, response lost"
	end
	return true, result
end

-- Uncached read (DataStoreGetOptions.UseCache = false on DataStore).
function Store.get(key: string): (boolean, any)
	local f = activeFaults()
	if f.latency > 0 then
		task.wait(f.latency)
	end
	if f.getFail > 0 then
		f.getFail -= 1
		return false, "fault: get failed"
	end
	return pcall(backend().get, key)
end

-- Debug only: raw read/remove without faults.
function Store.peek(key: string): any
	local ok, result = pcall(backend().get, key)
	return if ok then result else nil
end

-- Debug reset: in-memory test store only.
function Store.remove(key: string): boolean
	if Store.backendName() ~= "memory" then
		return false
	end
	memoryBackend.remove(key)
	return true
end

return Store
