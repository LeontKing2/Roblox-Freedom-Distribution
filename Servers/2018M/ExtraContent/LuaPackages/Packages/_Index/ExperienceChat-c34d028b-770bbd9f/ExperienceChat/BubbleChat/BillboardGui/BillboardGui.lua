local ExperienceChat = script:FindFirstAncestor("ExperienceChat")
local Logger = require(ExperienceChat.Logger):new("ExpChat/" .. script.Name)
local Packages = ExperienceChat.Parent

local Roact = require(Packages.Roact)
local RoactRodux = require(Packages.RoactRodux)
local List = require(Packages.llama).List
local Otter = require(Packages.Otter)

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local memoize = require(ExperienceChat.memoize)

local BubbleChat = script:FindFirstAncestor("BubbleChat")
local VoiceIndicator = require(BubbleChat.VoiceIndicator)
local BlankBubble = require(BubbleChat.BlankBubble)
local BubbleChatList = require(BubbleChat.BubbleChatList)
local ChatBubbleDistant = require(BubbleChat.ChatBubbleDistant)

local BILLBOARD_OFFSET_EPSILON = 0.5
local RENDER_INSERT_SIZE = Vector2.new(28, 28)

local BubbleChatBillboard = Roact.PureComponent:extend("BubbleChatBillboard")

local SPRING_CONFIG = {
	dampingRatio = 1,
	frequency = 4,
}

--[[
BubbleChatBillboard.validateProps = t.strictInterface({
	userId = t.string,
	onFadeOut = t.optional(t.callback),
	voiceEnabled = t.optional(t.boolean),

	-- RoactRodux
	messages = t.optional(t.array(t.string)), -- messages == nil during the last bubble's fade out animation
	lastMessage = t.optional(Types.IMessage),
	voiceState = t.optional(t.string),
})
]]

function BubbleChatBillboard:init()
	self:setState({
		adornee = nil,
		isInsideRenderDistance = false,
		isInsideMaximizeDistance = false,
		savedChatSettings = self.props.chatSettings,
	})

	self.isMounted = false
	self.offset, self.updateOffset = Roact.createBinding(Vector3.new())
	self.offsetMotor = Otter.createSingleMotor(0)
	self.offsetMotor:onStep(function(offset)
		self.updateOffset(Vector3.new(0, offset, 0))
	end)
	self.offsetGoal = 0

	self.onLastBubbleFadeOut = function()
		if self.props.onFadeOut and not self.isFadingOut then
			self.isFadingOut = true
			self.props.onFadeOut(self.props.userId)
		end
	end

	self.renderInsert = function()
		return Roact.createElement(VoiceIndicator, {
			userId = self.props.userId,
			getIcon = self.props.getIconVoiceIndicator,
			onClicked = self.props.onClickedVoiceIndicator,
		})
	end
end

-- Wait for the first of the passed signals to fire
local function waitForFirst(...)
	local shunt = Instance.new("BindableEvent")
	local slots = { ... }

	local function fire(...)
		for i = 1, #slots do
			slots[i]:Disconnect()
		end

		return shunt:Fire(...)
	end

	for i = 1, #slots do
		slots[i] = slots[i]:Connect(fire)
	end

	return shunt.Event:Wait()
end

local function findFirstChildByNameAndClass(instance: Instance, name: string, class: string): Instance?
	for _, child in ipairs(instance:GetChildren()) do
		if child.Name == name and child:IsA(class) then
			return child
		end
	end

	return nil
end

-- Fires when the adornee character respawns. Updates the state adornee to the new character once it has respawned.
function BubbleChatBillboard:onCharacterAdded(player, character)
	-- This part is inspired from HumanoidReadyUtil.lua

	-- Make sure that character is parented, stop execution if the character has respawned again in the meantime
	if not character.Parent then
		waitForFirst(character.AncestryChanged, player.CharacterAdded)
	end
	if player.Character ~= character or not character.Parent then
		Logger:debug("Mismatched or unparented character in onCharacterAdded for {}", self.state.shortId)
		return
	end

	-- Make sure that the humanoid is parented, stop execution if the character has respawned again in the meantime
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	while character:IsDescendantOf(game) and not humanoid do
		waitForFirst(character.ChildAdded, character.AncestryChanged, player.CharacterAdded)
		humanoid = character:FindFirstChildOfClass("Humanoid")
	end

	if player.Character ~= character or not character:IsDescendantOf(game) then
		Logger:debug("Mismatched or unparented character in onCharacterAdded for {}", self.state.shortId)
		return
	end

	-- Make sure that the root part is parented, stop execution if the character has respawned again in the meantime
	local rootPart = character.PrimaryPart

	while character:IsDescendantOf(game) and not rootPart do
		waitForFirst(character.ChildAdded, character.AncestryChanged, player.CharacterAdded)
		rootPart = character.PrimaryPart
	end

	if rootPart and character:IsDescendantOf(game) and player.Character == character and self.isMounted then
		local head = findFirstChildByNameAndClass(character, "Head", "BasePart")
		self:setState({
			adornee = if humanoid.Health == 0 then head else character,
		})

		if self.humanoidDiedConn then
			self.humanoidDiedConn:Disconnect()
			self.humanoidDiedConn = nil
		end
		self.humanoidDiedConn = humanoid.Died:Connect(function()
			self:setState({
				adornee = findFirstChildByNameAndClass(character, "Head", "BasePart") or character,
			})
		end)
	end
end

-- Offsets the billboard so it will align properly with the top of the
-- character, regardless of what assets they're wearing.
function BubbleChatBillboard:getVerticalOffset(adornee)
	if adornee and adornee:IsA("Model") then
		-- Billboard is adornee'd to a child part -> need to calculate the distance between it and the top of the
		-- bounding box
		local orientation, size = adornee:GetBoundingBox()
		local adorneeInstance = self:getAdorneeInstance(adornee)
		if not adorneeInstance then
			return size.Y / 2
		elseif adorneeInstance:IsA("BasePart") then
			local relative = orientation:PointToObjectSpace(adorneeInstance.Position)
			return size.Y / 2 - relative.Y
		end
		return 0
	elseif adornee and adornee:IsA("BasePart") then
		return adornee.Size.Y / 2
	else
		return 0
	end
end

-- From a given adornee object, which can be either a model, a part, an attachment, or nil, returns which part
-- (or attachment) (or nil) the billboard should attach itself to
function BubbleChatBillboard:getAdorneeInstance(adornee): Instance?
	if not adornee then
		return nil
	elseif adornee:IsA("Model") then
		local adorneePart = adornee:FindFirstChild(self.state.savedChatSettings.AdorneeName, true)
			or adornee.PrimaryPart

		if not adorneePart or adorneePart:IsA("BasePart") or adorneePart:IsA("Attachment") then
			return adorneePart
		end
	elseif adornee:IsA("BasePart") or adornee:IsA("Attachment") then
		return adornee
	end

	return nil
end

function BubbleChatBillboard:render()
	local adorneeInstance = self:getAdorneeInstance(self.state.adornee)
	local isLocalPlayer = self.props.userId == tostring(Players.LocalPlayer.UserId)
	local chatSettings = self.state.savedChatSettings

	if not adorneeInstance then
		Logger:debug("No adornee for {}", self.state.shortId)
		return
	end

	-- Don't render the billboard at all if out of range. We could use
	-- the MaxDistance property on the billboard, but that keeps
	-- instances around. This approach means nothing exists in the DM
	-- when there are no messages.
	if not self.state.isInsideRenderDistance then
		Logger:debug("Not in range for {}", self.state.shortId)
		return
	end

	local children = {}

	local showVoiceIndicator = self.props.voiceEnabled -- and not self.state.voiceTimedOut
	local renderInsert = if showVoiceIndicator then self.renderInsert else nil
	local renderInsertSize = RENDER_INSERT_SIZE

	-- If neither bubble chat nor voice is on, this whole component shouldn't be rendered.
	if
		showVoiceIndicator
		and (not self.props.bubbleChatEnabled or not self.state.filteredMessages or #self.state.filteredMessages == 0)
	then
		-- Render the VoiceBubble if neither of the other two should render.
		children.VoiceBubble = Roact.createElement(BlankBubble, {
			chatSettings = chatSettings,
			userId = self.props.userId,
			renderInsert = renderInsert,
			insertSize = renderInsertSize,
			isDistant = not self.state.isInsideMaximizeDistance,
		})
	end

	if self.state.isInsideMaximizeDistance then
		children.BubbleChatList = Roact.createElement(BubbleChatList, {
			userId = self.props.userId,
			isVisible = self.state.isInsideMaximizeDistance,
			onLastBubbleFadeOut = self.onLastBubbleFadeOut,
			chatSettings = chatSettings,
			renderFirstInsert = renderInsert,
			insertSize = renderInsertSize,
			messages = self.state.filteredMessages,
		})
	else
		children.DistantBubble = Roact.createElement(ChatBubbleDistant, {
			fadingOut = not self.state.filteredMessages or #self.state.filteredMessages == 0,
			onFadeOut = self.onLastBubbleFadeOut,
			chatSettings = chatSettings,
			renderInsert = renderInsert,
			insertSize = renderInsertSize,
		})
	end

	-- For other players, increase vertical offset by 1 to prevent overlaps with the name display
	-- For the local player, increase Z offset to prevent the character from overlapping his bubbles when jumping/emoting
	-- (see default value of settings.LocalPlayerStudsOffset in ChatSettings.lua)
	-- This behavior is the same as the old bubble chat
	local studsOffset = isLocalPlayer and chatSettings.LocalPlayerStudsOffset or Vector3.new(0, 1, 0.1)
	return Roact.createElement("BillboardGui", {
		Adornee = adorneeInstance,
		Active = showVoiceIndicator,
		Size = UDim2.fromOffset(500, 200),
		SizeOffset = Vector2.new(0, 0.5),
		StudsOffset = studsOffset + Vector3.new(0, chatSettings.VerticalStudsOffset, 0),
		StudsOffsetWorldSpace = self.offset,
		ResetOnSpawn = false,
	}, children)
end

function BubbleChatBillboard:didUpdate(_lastProps, _lastState)
	-- If self.state.isInsideRenderDistance, the responsibility to call self.onLastBubbleFadeOut will be on either
	-- DistantBubble or BubbleChatList (after their fade out animation)
	if
		(not self.state.filteredMessages or #self.state.filteredMessages == 0) and not self.state.isInsideRenderDistance
	then
		self.onLastBubbleFadeOut()
	end

	if self.state.filteredMessages and #self.state.filteredMessages > 0 then
		self.isFadingOut = false
	end
end

local function getRecentMessages(messages, bubbleDurationInMillis, maxBubbles)
	local now = DateTime.now().UnixTimestampMillis
	return List.filter(messages, function(message, index)
		return index > #messages - maxBubbles and now - message.timestamp.UnixTimestampMillis < bubbleDurationInMillis
	end)
end

function BubbleChatBillboard:didMount()
	self.isMounted = true
	local adornee = self.props.lastMessage and self.props.lastMessage.adornee
	self:setState({
		adornee = adornee,
	})

	local initialOffset = self:getVerticalOffset(adornee)
	self.offsetGoal = initialOffset
	self.offsetMotor:setGoal(Otter.instant(initialOffset))

	-- When the character respawns, we need to update the adornee
	local player
	if adornee then
		player = Players:GetPlayerFromCharacter(adornee)
	elseif tonumber(self.props.userId) then
		player = Players:GetPlayerByUserId(self.props.userId)
	end

	if player then
		if player.Character then
			task.spawn(function()
				self:onCharacterAdded(player, player.Character)
			end)
		end
		self.characterConn = player.CharacterAdded:Connect(function(character)
			self:onCharacterAdded(player, character)
		end)
	end

	-- Need to use a loop because property changed signals don't work on Position
	self.heartbeatConn = RunService.Heartbeat:Connect(function()
		local adorneeInstance = self:getAdorneeInstance(self.state.adornee) -- Can be a BasePart or Attachment or nil
		if workspace.CurrentCamera and adorneeInstance then
			local position = adorneeInstance:IsA("Attachment") and adorneeInstance.WorldPosition
				or adorneeInstance.Position
			local distance = (workspace.CurrentCamera.CFrame.Position - position).Magnitude
			local isInsideRenderDistance = distance < self.state.savedChatSettings.MaxDistance
			local isInsideMaximizeDistance = distance < self.state.savedChatSettings.MinimizeDistance

			if
				isInsideMaximizeDistance ~= self.state.isInsideMaximizeDistance
				or isInsideRenderDistance ~= self.state.isInsideRenderDistance
			then
				self:setState({
					isInsideRenderDistance = isInsideRenderDistance,
					isInsideMaximizeDistance = isInsideMaximizeDistance,
				})
			end
		end

		local offset = self:getVerticalOffset(self.state.adornee)
		if math.abs(offset - self.offsetGoal) > BILLBOARD_OFFSET_EPSILON then
			self.offsetGoal = offset
			self.offsetMotor:setGoal(Otter.spring(offset, SPRING_CONFIG))
		end

		local now = DateTime.now().UnixTimestampMillis
		local bubbleDurationInMillis = self.state.savedChatSettings.BubbleDuration * 1000
		for _, message in ipairs(self.state.filteredMessages) do
			if now - message.timestamp.UnixTimestampMillis >= bubbleDurationInMillis then
				self:setState(function(state)
					local newFilteredMessages = getRecentMessages(
						state.filteredMessages,
						bubbleDurationInMillis,
						self.props.chatSettings.MaxBubbles
					)
					return {
						filteredMessages = newFilteredMessages,
					}
				end)
				break
			end
		end
	end)
end

function BubbleChatBillboard:willUnmount()
	Logger:trace("Unmounting billboards for {}", self.state.shortId)
	self.isMounted = false
	if self.characterConn then
		self.characterConn:Disconnect()
		self.characterConn = nil
	end
	if self.heartbeatConn then
		self.heartbeatConn:Disconnect()
		self.heartbeatConn = nil
	end
	if self.humanoidDiedConn then
		self.humanoidDiedConn:Disconnect()
		self.humanoidDiedConn = nil
	end
	self.offsetMotor:destroy()
end

function BubbleChatBillboard.getDerivedStateFromProps(nextProps, lastState)
	-- Need to save the latest chat settings to the state because when the billboard does the fade out animation,
	-- there is no message (nextProps.lastMessage == nil), so no way to get the user ID, which is needed to get
	-- user specific settings.

	local shortId = "..." .. string.sub(tostring(nextProps.userId), -4)

	local bubbleDurationInMillis = lastState.savedChatSettings.BubbleDuration * 1000
	local filteredMessages =
		getRecentMessages(nextProps.messages, bubbleDurationInMillis, lastState.savedChatSettings.MaxBubbles)
	return {
		savedChatSettings = nextProps.lastMessage and nextProps.chatSettings,
		shortId = shortId,
		filteredMessages = filteredMessages,
	}
end

local selectMessages = memoize(function(messagesState, userId)
	return List.map(messagesState.inOrderBySenderId[userId] or {}, function(messageId)
		return messagesState.byMessageId[messageId]
	end)
end)

local function mapStateToProps(state, props)
	local messages = selectMessages(state.Messages, props.userId)
	local lastMessage = messages[#messages]

	return {
		messages = messages,
		lastMessage = lastMessage,
		chatSettings = state.BubbleChatSettings,
	}
end

return RoactRodux.connect(mapStateToProps)(BubbleChatBillboard)