-- Tiny by-reference signal helper.
-- BindableEvent deep-copies payloads; these callbacks keep table references intact.

local Signal = {}
Signal.__index = Signal

function Signal.new()
	return setmetatable({ _h = {} }, Signal)
end

function Signal:Connect(fn)
	self._h[fn] = true
	local handlers = self._h
	return {
		Disconnect = function()
			handlers[fn] = nil
		end,
	}
end

function Signal:Fire(...)
	for fn in self._h do
		task.spawn(fn, ...)
	end
end

return Signal
