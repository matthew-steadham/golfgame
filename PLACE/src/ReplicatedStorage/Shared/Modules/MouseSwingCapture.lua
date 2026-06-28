--!strict
-- MouseSwingCapture
-- The mouse backend for the 4-step EvoSwing. Captures a swing trajectory through
-- four explicit phases and hands it to the (device-agnostic) SwingAnalyzer.
--
--   1. ADDRESS    -- armed, ball-line locked, waiting for the player to start
--   2. BACKSWING  -- pull straight DOWN; depth = power, past-full = overswing
--   3. TRANSITION -- the top, where motion reverses; tempo timing begins here
--   4. DOWNSWING  -- push UP through the ball line; impact resolves path/face/contact
--
-- This is the ONLY file you'd swap to add console support: write GamepadSwingCapture
-- the same way, reading thumbstick deflection instead of mouse delta, feeding the
-- same analyzer and emitting the same phases.
--
-- Usage:
--   local cap = MouseSwingCapture.new()
--   cap.onCompleted = function(swing) ... end   -- fire the shot
--   cap.onUpdated   = function(state) ... end    -- drive the swing meter HUD
--   cap.onCancelled = function() ... end
--   cap:Arm()    -- at address, when a swing is allowed
--   cap:Disarm() -- when leaving the aim state

local UserInputService = game:GetService("UserInputService")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.SwingConfig)
local SwingAnalyzer = require(script.Parent.SwingAnalyzer)

type SwingSample = Config.SwingSample
type SwingInput = Config.SwingInput

-- Phase is one of: "address" | "backswing" | "transition" | "downswing"
export type FeedbackState = {
	phase: string,
	power: number,     -- 0..1 backswing depth so far
	overswing: number, -- 0..1 pulled past full
	path: number,      -- -1..1 current horizontal lean
	committed: boolean,
	committedPower: number, -- power locked in at the top (0..1)
	downProgress: number,   -- 0..1 through the ideal downswing window
}

-- Complete fallback values so a missing/partial SwingConfig can never crash the swing.
-- Anything the provided config defines overrides these; anything it omits uses these.
local DEFAULTS = {
	MousePixelsPerUnit = 320,
	InvertY = false,
	FullBackswingTravel = 1.0,
	FullBackswingTime = 0.80,
	OverswingTime = 0.15,
	MinBackswingTravel = 0.01,
	MaxOverswing = 0.20,
	ReversalSmoothing = 3,
	ImpactLineBand = 0.04,
	TransitionExitBand = 0.06,
	IdealTempoRatio = 3.0,
	TempoToleranceRatio = 2.0,
	MaxPathDeviation = 0.5,
	ContactTempoWeight = 0.45,
	ContactWobbleWeight = 0.30,
	ContactFaceWeight = 0.25,
	MaxWobble = 0.6,
}

local function mergeConfig(provided: any)
	local merged: { [string]: any } = {}
	for k, v in DEFAULTS do
		merged[k] = v
	end
	if type(provided) == "table" then
		for k, v in provided do
			merged[k] = v
		end
	end
	return merged
end

local MouseSwingCapture = {}
MouseSwingCapture.__index = MouseSwingCapture

export type Capture = typeof(setmetatable(
	{} :: {
		onCompleted: ((SwingInput) -> ())?,
		onCancelled: (() -> ())?,
		onUpdated: ((FeedbackState) -> ())?,
		sensitivity: number,
		swingTilt: number,
		targetFraction: number,
		_config: any,
		_armed: boolean,
		_active: boolean,
		_committed: boolean,
		_phase: string,
		_topY: number,
		_startT: number,
		_transitionT: number,
		_impactT: number,
		_topPos: Vector2,
		_impactPos: Vector2,
		_committedPower: number,
		_virtual: Vector2,
		_samples: { SwingSample },
		_armConns: { RBXScriptConnection },
		_swingConns: { RBXScriptConnection },
	},
	MouseSwingCapture
	))

function MouseSwingCapture.new(config: any?): Capture
	return setmetatable({
		onCompleted = nil,
		onCancelled = nil,
		onUpdated = nil,
		sensitivity = 1.0,
		swingTilt = 0,
		targetFraction = 1.0,
		_config = mergeConfig(config or Config),
		_armed = false,
		_active = false,
		_committed = false,
		_phase = "address",
		_topY = 0,
		_startT = 0,
		_transitionT = 0,
		_impactT = 0,
		_topPos = Vector2.zero,
		_impactPos = Vector2.zero,
		_committedPower = 0,
		_virtual = Vector2.zero,
		_samples = {},
		_armConns = {},
		_swingConns = {},
	}, MouseSwingCapture)
end

local function disconnectAll(conns: { RBXScriptConnection })
	for _, c in ipairs(conns) do
		c:Disconnect()
	end
	table.clear(conns)
end

function MouseSwingCapture.Arm(self: Capture)
	if self._armed then return end
	self._armed = true
	self._phase = "address"

	table.insert(self._armConns, UserInputService.InputBegan:Connect(function(input, gpe)
		if gpe then return end
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_beginSwing()
		end
	end))
	table.insert(self._armConns, UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			self:_releaseSwing()
		end
	end))
end

function MouseSwingCapture.Disarm(self: Capture)
	self._armed = false
	self:_endSwing()
	disconnectAll(self._armConns)
end

function MouseSwingCapture._beginSwing(self: Capture)
	if self._active then return end
	self._active = true
	self._committed = false
	self._phase = "backswing"
	self._topY = 0
	self._virtual = Vector2.zero
	self._samples = {}
	self._startT = os.clock()
	self._transitionT = 0
	self._impactT = 0
	self._topPos = Vector2.zero
	self._impactPos = Vector2.zero
	self._committedPower = 0
	UserInputService.MouseBehavior = Enum.MouseBehavior.LockCurrentPosition

	local cfg = self._config
	local pxPerUnit: number = cfg.MousePixelsPerUnit / math.max(self.sensitivity, 0.1)
	local ySign = cfg.InvertY and -1 or 1

	-- Accumulate raw mouse motion into virtual swing space.
	-- Screen +Y is downward, so pulling DOWN reads as +Y = backswing.
	table.insert(self._swingConns, UserInputService.InputChanged:Connect(function(input)
		if not self._active then return end
		if input.UserInputType == Enum.UserInputType.MouseMovement then
			local d = input.Delta
			local vx = d.X / pxPerUnit
			local vy = (d.Y / pxPerUnit) * ySign
			-- draw/fade tilts the whole swing frame: swinging ALONG the tilt reads as straight,
			-- swinging straight reads as off-path. This is what makes the path "look angled".
			local tilt = self.swingTilt
			if tilt ~= 0 then
				local c, sn = math.cos(-tilt), math.sin(-tilt)
				vx, vy = vx * c - vy * sn, vx * sn + vy * c
			end
			self._virtual += Vector2.new(vx, vy)
		end
	end))

	-- Fixed-cadence sampling gives clean tempo timing regardless of mouse poll rate.
	table.insert(self._swingConns, RunService.RenderStepped:Connect(function()
		if self._active then
			self:_tick()
		end
	end))
end

function MouseSwingCapture._tick(self: Capture)
	local cfg = self._config
	-- The fill reaches the DIALED target in FullBackswingTime, whatever the target is:
	-- lower targets fill slower, so any % is reached at the same moment. effFull is
	-- therefore the time to reach 100% (= FullBackswingTime / target).
	local effFull = cfg.FullBackswingTime / math.max(self.targetFraction, 0.1)
	local pos = self._virtual
	local now = os.clock()
	table.insert(self._samples, { pos = pos, t = now } :: SwingSample)

	if pos.Y > self._topY then
		self._topY = pos.Y
	end

	if self._phase == "backswing" then
		if pos.Y >= cfg.MinBackswingTravel then
			self._committed = true -- past here, the shot is live
		end
		if self._committed and self:_yReversed() then
			self._phase = "transition"
			self._transitionT = now
			self._topPos = pos
			-- power is set by HOW LONG the backswing took, not how far it pulled
			self._committedPower = math.clamp((now - self._startT) / effFull, 0, 1)
		end
	elseif self._phase == "transition" then
		-- the downswing has clearly begun once Y has dropped off the top
		if pos.Y <= self._topY - cfg.TransitionExitBand then
			self._phase = "downswing"
		end
	elseif self._phase == "downswing" then
		if pos.Y <= cfg.ImpactLineBand then
			self:_impact()
			return
		end
	end

	if self.onUpdated then
		-- during the backswing the ring grows with elapsed time; after the top it freezes
		-- at the committed power so you can read it while timing the downswing.
		local power
		if self._phase == "backswing" then
			power = math.clamp((now - self._startT) / effFull, 0, 1)
		else
			power = self._committedPower
		end
		local downProgress = 0
		if self._transitionT > 0 then
			local backTime = self._transitionT - self._startT
			local idealDown = math.max(backTime / cfg.IdealTempoRatio, 1e-3)
			downProgress = math.clamp((now - self._transitionT) / idealDown, 0, 1)
		end
		self.onUpdated({
			phase = self._phase,
			power = power,
			overswing = math.clamp(((now - self._startT) - effFull) / cfg.OverswingTime, 0, 1),
			path = math.clamp(pos.X / cfg.MaxPathDeviation, -1, 1),
			committed = self._committed,
			committedPower = self._committedPower,
			downProgress = downProgress,
		})
	end
end

-- Has Y peaked and started coming back down over the smoothing window?
function MouseSwingCapture._yReversed(self: Capture): boolean
	local s = self._samples
	local w: number = self._config.ReversalSmoothing
	local n = #s
	if n < w + 1 then return false end
	return s[n].pos.Y < s[n - w].pos.Y
end

function MouseSwingCapture._impact(self: Capture)
	local now = os.clock()
	self._impactT = now
	self._impactPos = self._virtual
	local trajectory = {
		samples = self._samples,
		startT = self._startT,
		transitionT = if self._transitionT > 0 then self._transitionT else now,
		impactT = now,
		topPos = if self._transitionT > 0 then self._topPos else self._virtual,
		impactPos = self._virtual,
	}
	-- analyze against the effective full-time so the FINAL power matches the live meter:
	-- stopping at the dialed target (in FullBackswingTime) yields exactly that power.
	local analyzeCfg = {}
	for k, v in self._config do analyzeCfg[k] = v end
	analyzeCfg.FullBackswingTime = self._config.FullBackswingTime / math.max(self.targetFraction, 0.1)
	local result = SwingAnalyzer.analyze(trajectory, analyzeCfg)
	self:_endSwing()
	if result.valid then
		if self.onCompleted then self.onCompleted(result) end
	else
		if self.onCancelled then self.onCancelled() end
	end
end

function MouseSwingCapture._releaseSwing(self: Capture)
	if not self._active then return end
	if not self._committed then
		-- released during a shallow backswing: clean cancel, no penalty
		self:_endSwing()
		if self.onCancelled then self.onCancelled() end
		return
	end
	-- committed but let go early: analyze what we have (analyzer penalizes it)
	self:_impact()
end

function MouseSwingCapture._endSwing(self: Capture)
	self._active = false
	self._phase = "address"
	self._topY = 0
	UserInputService.MouseBehavior = Enum.MouseBehavior.Default
	disconnectAll(self._swingConns)
end

return MouseSwingCapture
