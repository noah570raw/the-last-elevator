--!strict
-- Socket alignment and compatibility shared by server spawn and client preview.

local SocketMath = {}

local function connectorOf(model: Model): BasePart?
	return model:FindFirstChild("Connector") :: BasePart?
end

-- Pivot that places the module's Connector on the socket, facing it (180° turn).
function SocketMath.modulePivot(socketCFrame: CFrame, model: Model): CFrame
	local connector = connectorOf(model)
	assert(connector, "module has no Connector")
	local connectorToPivot = connector.CFrame:ToObjectSpace(model:GetPivot())
	return socketCFrame * CFrame.Angles(0, math.pi, 0) * connectorToPivot
end

function SocketMath.isCompatible(socket: Instance, model: Model): boolean
	local connector = connectorOf(model)
	local socketType = socket:GetAttribute("SocketType")
	return connector ~= nil and socketType ~= nil and socketType == connector:GetAttribute("SocketType")
end

return SocketMath
