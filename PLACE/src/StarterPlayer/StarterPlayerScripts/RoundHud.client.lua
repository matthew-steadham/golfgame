-- RoundHud
-- Binds the round HUD visuals (which YOU build in StarterGui) to RoundState. Creates no visuals;
-- it finds named elements and drives their text/image. Missing elements warn once with the path.
-- Drives two independent ScreenGuis, each optional:
--
--   RoundHUD (ScreenGui)                     -- persistent top-right card
--     Card (Frame): Headshot(ImageLabel) PlayerName(TextLabel) Hole,Stroke,Score(TextLabels)
--
--   ScoreCard (ScreenGui)                    -- between-holes scorecard; shown on hole-out
--     Root > CanvasGroup >
--       Avatar (Frame)                        -- headshot ImageLabel auto-created inside if absent
--       Top    > HoleNumbers > 1..9 (TextLabels), PlayerName, ScoreDiff
--       Middle > HolePars    > 1..9 (TextLabels), ParOut
--       Bottom > PlayerHoleScores > 1..9 (TextLabels), CurrentScore

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

local Mods = ReplicatedStorage.Shared.Modules
local RoundState = require(Mods.RoundState)
local ShotDistance = require(Mods.ShotDistance)
local Hud = require(Mods.HudController)

ShotDistance.Changed:Connect(function(count: string, unit: string)
	Hud.setDistance(count, unit)
end)

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local HEADSHOT = `rbxthumb://type=AvatarHeadShot&id={player.UserId}&w=150&h=150`
local HOLD_MAIN_ATTR = "RoundHudHoldMainUpdates"
local HIDE_SCORECARD_ATTR = "RoundHudHideScorecardRequest"

local warned = {}
local function find(parent: Instance?, name: string): Instance?
	if not parent then
		return nil
	end
	local inst = parent:FindFirstChild(name)
	if not inst and not warned[name] then
		warned[name] = true
		warn(`[RoundHud] missing element "{name}" under {parent:GetFullName()}`)
	end
	return inst
end

local function setText(parent: Instance?, name: string, text: string)
	local lbl = find(parent, name)
	if lbl and lbl:IsA("TextLabel") then
		lbl.Text = text
	end
end

-- =============================================================================================
-- Top-right card (ScreenGui "RoundHUD" > Card)
-- =============================================================================================
local roundHud = playerGui:WaitForChild("RoundHUD", 5)
local card = roundHud and find(roundHud, "Card")

if card then
	local head = find(card, "Headshot")
	if head and head:IsA("ImageLabel") then
		head.Image = HEADSHOT
	end
	setText(card, "PlayerName", player.DisplayName)
end

local function updateCard()
	if not card then
		return
	end
	setText(card, "Hole", string.format("HOLE %d", RoundState.currentHole))
	-- Stroke the player is ABOUT to play (taken + 1). Drop the "+ 1" for strokes-already-taken.
	setText(card, "Stroke", string.format("STROKE %d", RoundState.currentStrokes + 1))
	setText(card, "Score", RoundState.GetToParText())
end

-- =============================================================================================
-- Between-holes scorecard (ScreenGui "ScoreCard")
-- =============================================================================================
local scoreCard = playerGui:WaitForChild("ScoreCard", 5)
local scorecardPanel, scorecardCanvas, avatarFrame, top, middle, bottom, holeNumbers, holePars, playerHoleScores
local SCORECARD_START_POS = UDim2.new(0.5, 0, 1.5, 0)
local SCORECARD_FINAL_POS = UDim2.new(0.5, 0, 0.927, 0)
local SCORECARD_TWEEN_TIME = 0.5
local scorecardPosTween: Tween? = nil
local scorecardFadeTween: Tween? = nil

if scoreCard then
	scoreCard.Enabled = false -- hidden until the first hole-out
	local root = find(scoreCard, "Root")
	local canvas = root and find(root, "CanvasGroup")
	scorecardPanel = if canvas and canvas:IsA("GuiObject") then canvas elseif root and root:IsA("GuiObject") then root else nil
	scorecardCanvas = if canvas and canvas:IsA("CanvasGroup") then canvas else nil
	if scorecardPanel then
		scorecardPanel.Position = SCORECARD_START_POS
	end
	if scorecardCanvas then
		scorecardCanvas.GroupTransparency = 1
	end
	if canvas then
		avatarFrame = find(canvas, "Avatar")
		top = find(canvas, "Top")
		middle = find(canvas, "Middle")
		bottom = find(canvas, "Bottom")
		holeNumbers = top and find(top, "HoleNumbers")
		holePars = middle and find(middle, "HolePars")
		playerHoleScores = bottom and find(bottom, "PlayerHoleScores")
	end
end

local function ensureHeadshot()
	if not avatarFrame then
		return
	end
	local img = avatarFrame:FindFirstChildWhichIsA("ImageLabel")
	if not img then
		-- Avatar is a plain Frame in your design, so drop an ImageLabel in to hold the headshot.
		-- Pre-add your own ImageLabel (any name) if you want to style it; this just sets .Image.
		img = Instance.new("ImageLabel")
		img.Name = "Headshot"
		img.BackgroundTransparency = 1
		img.Size = UDim2.fromScale(1, 1)
		img.Parent = avatarFrame
	end
	img.Image = HEADSHOT
end

-- Traditional scorecard notation on a PlayerHoleScores cell, driven by score-vs-par:
--   par        -> no frames        under par -> circle(s)     over par -> square(s)
--   1 off par  -> Inner only       2+ off par -> Inner + Outer
-- Frames use .Visible (Frames have no .Enabled). Outer may be a sibling of Inner or nested in it.
local CIRCLE = UDim.new(1, 0)
local SQUARE = UDim.new(0, 0)

local function decorateScore(cell: Instance, rel: number?)
	local inner = cell:FindFirstChild("Inner")
	if not inner or not inner:IsA("GuiObject") then
		return -- this cell has no notation frames; nothing to decorate
	end
	local outer = cell:FindFirstChild("Outer") or inner:FindFirstChild("Outer")
	local innerCorner = inner:FindFirstChildWhichIsA("UICorner")
	local outerCorner = outer and outer:FindFirstChildWhichIsA("UICorner")

	local showInner, showOuter, radius = false, false, CIRCLE
	if rel and rel ~= 0 then
		showInner = true
		radius = if rel < 0 then CIRCLE else SQUARE -- circle under par, square over
		showOuter = math.abs(rel) >= 2 -- eagle+ or double-bogey+ gets the doubled ring/box
	end

	inner.Visible = showInner
	if innerCorner and showInner then
		innerCorner.CornerRadius = radius
	end
	if outer then
		outer.Visible = showOuter
		if outerCorner and showOuter then
			outerCorner.CornerRadius = radius
		end
	end
end

local function populateScorecard()
	if not scoreCard then
		return
	end
	setText(top, "PlayerName", player.DisplayName)
	ensureHeadshot()

	local strokesByHole, parByHole = {}, {}
	for _, r in RoundState.card do
		strokesByHole[r.hole] = r.strokes
		parByHole[r.hole] = r.par
	end

	-- The 9 columns are a ROLLING nine: front (1-9) or back (10-18) based on the current hole.
	-- Column i shows hole (nineStart + i - 1); labels/pars/scores/totals all follow the nine.
	local nineStart = math.floor((RoundState.currentHole - 1) / 9) * 9 + 1

	local parSum, strokeSum = 0, 0
	for i = 1, 9 do
		local holeNum = nineStart + (i - 1)
		setText(holeNumbers, tostring(i), tostring(holeNum))
		local par = RoundState.pars[holeNum] or parByHole[holeNum] -- course par, else played par
		setText(holePars, tostring(i), if par then tostring(par) else "")
		if par then
			parSum += par
		end
		local sc = strokesByHole[holeNum]
		if sc then
			strokeSum += sc
		end
		-- score cell text + traditional circle/square notation
		local cell = playerHoleScores and playerHoleScores:FindFirstChild(tostring(i))
		if cell then
			if cell:IsA("TextLabel") then
				cell.Text = if sc then tostring(sc) else ""
			end
			decorateScore(cell, if sc and par then sc - par else nil)
		end
	end

	setText(top, "ScoreDiff", RoundState.GetToParText()) -- E / +N / -N over the WHOLE round
	setText(middle, "ParOut", tostring(parSum)) -- par total for the current nine
	setText(bottom, "CurrentScore", tostring(strokeSum)) -- strokes for the current nine
end



-- =============================================================================================
-- Bindings
-- =============================================================================================
local scorecardShown = false
local scorecardHole: number? = nil

local lastHoleSeen = nil
local function updateHoleStatCard()
	Hud.setHoleStatCard({
		shot = RoundState.currentStrokes + 1, -- the shot they are currently on
		par = RoundState.currentPar,
		hole = RoundState.currentHole,
		toParText = RoundState.GetToParText(),
	})
	if RoundState.currentHole ~= lastHoleSeen then
		lastHoleSeen = RoundState.currentHole
		Hud.tweenHoleNumbersIn() -- slide the number row in when a new hole starts
	end
end

local function cancelScorecardTweens()
	if scorecardPosTween then
		scorecardPosTween:Cancel()
		scorecardPosTween = nil
	end
	if scorecardFadeTween then
		scorecardFadeTween:Cancel()
		scorecardFadeTween = nil
	end
end

local function tweenScorecard(show: boolean)
	if not scoreCard then
		return
	end
	cancelScorecardTweens()
	if show then
		scoreCard.Enabled = true
		if scorecardPanel then
			scorecardPanel.Position = SCORECARD_START_POS
		end
		if scorecardCanvas then
			scorecardCanvas.GroupTransparency = 1
		end
	end

	local remaining = 0
	local function finish()
		if not show then
			scoreCard.Enabled = false
		end
	end
	local function play(tween: Tween)
		remaining += 1
		tween.Completed:Once(function()
			remaining -= 1
			if remaining <= 0 then
				finish()
			end
		end)
		tween:Play()
	end

	local tweenInfo = TweenInfo.new(SCORECARD_TWEEN_TIME, Enum.EasingStyle.Sine, if show then Enum.EasingDirection.Out else Enum.EasingDirection.In)
	if scorecardPanel then
		scorecardPosTween = TweenService:Create(scorecardPanel, tweenInfo, {
			Position = if show then SCORECARD_FINAL_POS else SCORECARD_START_POS,
		})
		play(scorecardPosTween)
	end
	if scorecardCanvas then
		scorecardFadeTween = TweenService:Create(scorecardCanvas, tweenInfo, {
			GroupTransparency = if show then 0 else 1,
		})
		play(scorecardFadeTween)
	end
	if remaining == 0 then
		finish()
	end
end

local function hideScorecard()
	if not scorecardShown then
		return
	end
	tweenScorecard(false)
	scorecardShown = false
	scorecardHole = nil
end

updateCard()
updateHoleStatCard()

RoundState.Changed:Connect(function()
	if player:GetAttribute(HOLD_MAIN_ATTR) ~= true then
		updateCard()
		updateHoleStatCard()
	end
	-- Dismiss only once the next hole actually loads; the controller also requests
	-- an animated hide near the end of the between-hole intermission.
	if scorecardShown and scoreCard and RoundState.currentHole ~= scorecardHole then
		hideScorecard()
	end
end)

player:GetAttributeChangedSignal(HOLD_MAIN_ATTR):Connect(function()
	if player:GetAttribute(HOLD_MAIN_ATTR) ~= true then
		updateCard()
		updateHoleStatCard()
	end
end)

player:GetAttributeChangedSignal(HIDE_SCORECARD_ATTR):Connect(function()
	hideScorecard()
end)

RoundState.HoleCompleted:Connect(function()
	if not scoreCard then
		return
	end
	populateScorecard()
	tweenScorecard(true)
	scorecardShown = true
	scorecardHole = RoundState.currentHole
end)
