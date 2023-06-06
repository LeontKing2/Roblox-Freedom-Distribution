local GridRoot = script.Parent
local AppRoot = GridRoot.Parent
local UIBloxRoot = AppRoot.Parent
local Packages = UIBloxRoot.Parent
local RoactGamepad = require(Packages.RoactGamepad)
local UIBloxConfig = require(UIBloxRoot.UIBloxConfig)

local Roact = require(Packages.Roact)
local Cryo = require(Packages.Cryo)
local t = require(Packages.t)

local positiveVector2 = require(UIBloxRoot.Utility.isPositiveVector2)

local validateProps = t.strictInterface({
	-- A function that, given an item, returns a Roact element representing that
	-- item. The item should expect to fill its parent. Setting LayoutOrder is
	-- not necessary.
	renderItem = t.callback,
	-- The size of a grid item, in pixels.
	itemSize = positiveVector2,
	-- The spacing between grid cells, on each axis.
	itemPadding = t.Vector2,
	-- All the items that can be displayed in the grid. renderItem should be
	-- able to use all values in this table. This must be an array (we don't
	-- check if it is for performance reasons).
	items = t.table,
	-- The maximum height the grid view is allowed to grow to.
	maxHeight = t.numberMin(0),
	-- The height of the visible window in the grid view. If nil, the grid view
	-- will render all of its items.
	windowHeight = t.optional(t.numberMin(0)),
	-- The layout order of the grid.
	LayoutOrder = t.optional(t.integer),
	-- Called when the grid view measures a change in its width. Used in
	-- DefaultMetricsGridView to resize the grid cells.
	onWidthChanged = t.optional(t.callback),

	-- optional parameters for RoactGamepad
	NextSelectionLeft = t.optional(t.table),
	NextSelectionRight = t.optional(t.table),
	NextSelectionUp = t.optional(t.table),
	NextSelectionDown = t.optional(t.table),
	frameRef = t.optional(t.table),
	restorePreviousChildFocus = t.optional(t.boolean),
	onFocusGained = t.optional(t.callback),

	-- which selection will initally be selected (if using roact-gamepad)
	defaultChildIndex = t.optional(t.numberMin(1)),
})

local GridView = Roact.PureComponent:extend("GridView")

function GridView:itemsAreVisible()
	-- We should only try to render items when things are 'sane':
	--   * we are parented to the game.
	--   * the container is non-zero width.
	--   * our item size is non-zero.
	return self.state.isInDataModel and self.state.containerWidth ~= 0 and self.props.itemSize.X ~= 0
end

GridView.defaultProps = {
	maxHeight = math.huge,
	restorePreviousChildFocus = true,
}

function GridView:init()
	self.frameRef = Roact.createRef()
	self.isMounted = false

	self.state = {
		containerWidth = 0,
		containerYPosition = 0,
		isInDataModel = false,
	}

	self.focusableRefs = RoactGamepad.createRefCache()

	self.onAncestryChanged = function(instance)
		if instance:IsDescendantOf(game) then
			self:setState(function(state)
				if not state.isInDataModel or state.containerWidth ~= instance.AbsoluteSize.X then
					return {
						isInDataModel = true,
						containerWidth = instance.AbsoluteSize.X,
					}
				end
				return nil
			end)
		end
	end
end

function GridView:render()
	assert(validateProps(self.props))
	local items = self.props.items
	local itemCount = #items

	local itemSize = self.props.itemSize
	local itemPadding = self.props.itemPadding
	local maxHeight = self.props.maxHeight
	local containerWidth = self.state.containerWidth
	local containerYOffset = self.state.containerYPosition
	local defaultChildIndex = self.props.defaultChildIndex
	local startIndex = 1
	local endIndex = itemCount
	local gridChildren = {}
	local x, y = 0, 0
	local maxPossibleVisibleItems = itemCount

	local itemsPerRow
	local maximumRenderableRows
	if UIBloxConfig.improvementsToGridView then
		local safeXDenominator = math.max(1, itemSize.X + itemPadding.X)
		local safeYDenominator = math.max(1, itemSize.Y + itemPadding.Y)
		itemsPerRow = math.floor((containerWidth + itemPadding.X) / safeXDenominator)
		maximumRenderableRows = math.floor((maxHeight + itemPadding.Y) / safeYDenominator)
	else
		itemsPerRow = math.floor((containerWidth + itemPadding.X) / (itemSize.X + itemPadding.X))
		maximumRenderableRows = math.floor((maxHeight + itemPadding.Y) / (itemSize.Y + itemPadding.Y))
	end

	local totalRows = math.ceil(itemCount / itemsPerRow)
	local displayedRows = math.min(maximumRenderableRows, totalRows)
	local containerHeight = displayedRows * itemSize.Y + math.max(displayedRows - 1, 0) * itemPadding.Y

	if self.props.windowHeight ~= nil then
		--ensure that when you scroll you don't see items "pop" into existence at the bottom
		local padRows = 2
		local visibleRows = math.floor((self.props.windowHeight + itemPadding.Y) / (itemSize.Y + itemPadding.Y))
			+ padRows
		local startingRow = math.floor((containerYOffset + itemPadding.Y) / (itemSize.Y + itemPadding.Y))
		local finalPadRows = 1
		local endingRow = math.min(displayedRows, startingRow + visibleRows) + finalPadRows

		startIndex = math.max(1, startingRow * itemsPerRow + 1)
		endIndex = math.min(itemCount, endingRow * itemsPerRow)

		y = startingRow * itemSize.Y + startingRow * itemPadding.Y

		local maxPossibleRowsDisplayed = math.min(maximumRenderableRows, visibleRows) + finalPadRows
		maxPossibleVisibleItems = math.abs(maxPossibleRowsDisplayed * itemsPerRow)
	end

	-- using maxPossibleVisibleItems means the amount of render keys will not change between renders (assuming
	-- positioning/size props don't change) this is important to ensure gamepad selection stability
	local maxRenderKey = maxPossibleVisibleItems

	-- FIXME(dbanks)
	-- 2021/11/30
	-- Remove with UIBloxConfig.improvementsToGridView
	local function calculateRenderKey(index)
		return index % maxRenderKey
	end

	local function getItemIndexRef(inputRow, inputCol)
		local isRowAndColInRange = inputRow > 0 and inputCol > 0 and inputCol <= itemsPerRow
		local index = 1 + (((inputRow - 1) * itemsPerRow) + (inputCol - 1))
		local isIndexInRange = index >= startIndex and index <= endIndex

		local renderKey = UIBloxConfig.improvementsToGridView and
			index or
			calculateRenderKey(index)
		return isIndexInRange and isRowAndColInRange and self.focusableRefs[renderKey] or nil
	end

	local function renderItem(itemIndex)
		local currentRow = 1 + (math.floor((itemIndex - 1) / itemsPerRow))
		local currentCol = 1 + ((itemIndex - 1) % itemsPerRow)

		local isVisible = true
		if UIBloxConfig.improvementsToGridView then
			-- If we don't even know how big the grid is, we shouldn't be
			-- rendering items: they will appear "squished".
			-- Also shouldn't be rendering grid items if the item size is 0.
			isVisible = self:itemsAreVisible()
		end

		return Roact.createElement(RoactGamepad.Focusable.Frame, {
			BackgroundTransparency = 1,
			Position = UDim2.new(0, x, 0, y),
			Size = UDim2.new(0, itemSize.X, 0, itemSize.Y),
			NextSelectionLeft = getItemIndexRef(currentRow, currentCol - 1),
			NextSelectionRight = getItemIndexRef(currentRow, currentCol + 1),
			NextSelectionUp = getItemIndexRef(currentRow - 1, currentCol),
			NextSelectionDown = getItemIndexRef(currentRow + 1, currentCol),
			[Roact.Ref] = UIBloxConfig.improvementsToGridView and self.focusableRefs[itemIndex] or getItemIndexRef(currentRow, currentCol),
			-- Optional Gamepad prop callback which is called when a grid member is focused on
			onFocusGained = self.props.onFocusGained,
		}, {
			Content = isVisible and self.props.renderItem(items[itemIndex], itemIndex),
		})
	end

	-- If the item height is already greater than the maximum size we shouldn't
	-- render _anything_
	if containerHeight < maxHeight then
		local defaultChildRendered = false
		local defaultChildExists = defaultChildIndex and defaultChildIndex <= itemCount

		for itemIndex = startIndex, endIndex do
			if itemIndex == defaultChildIndex then
				defaultChildRendered = true
			end
			local renderKey = UIBloxConfig.improvementsToGridView and itemIndex or calculateRenderKey(itemIndex)
			gridChildren[renderKey] = renderItem(itemIndex)

			x = math.floor(x + itemSize.X + itemPadding.X)

			-- If the x position overflows the maximum size, wrap further content
			-- onto another row. We check for just itemSize because the final
			-- grid item doesn't have padding tacked onto the end of it.
			if x + itemSize.X > containerWidth and itemIndex < endIndex then
				x = 0
				y = y + itemPadding.Y + itemSize.Y
			end
		end

		if UIBloxConfig.improvementsToGridView then
			if defaultChildExists and not defaultChildRendered then
				-- We could get into this situation in the following setup:
				--   * GridView with props:
				--     * defaultChildIndex = 1
				--     * restorePreviousChildFocus = false
				--   * You select the GridView. You navigate down several rows. You then navigate away
				--     from the GridView. You then navigate back to the GridView.
				-- The expected behavior of this would be that you select the first element.
				-- So we need to make sure the defaultChild is rendered.
				x = ((defaultChildIndex - 1) % itemsPerRow) * (itemSize.X + itemPadding.X)
				y = math.floor((defaultChildIndex - 1) / itemsPerRow) * (itemPadding.Y + itemSize.Y)
				gridChildren[defaultChildIndex] = renderItem(defaultChildIndex)
			end
		end
	end

	return Roact.createElement(RoactGamepad.Focusable.Frame, {
		BackgroundTransparency = 1,
		LayoutOrder = self.props.LayoutOrder,
		Size = UDim2.new(1, 0, 0, containerHeight),
		[Roact.Change.AbsolutePosition] = self.props.windowHeight ~= nil and function(rbx)
			if self.isMounted then
				self:setState({
					containerYPosition = -math.min(0, rbx.AbsolutePosition.Y),
				})
			end
		end or nil,
		[Roact.Change.AbsoluteSize] = function(rbx)
			if self.isMounted then
				if not UIBloxConfig.improvementsToGridView or self.state.isInDataModel then
					self:setState({
						containerWidth = rbx.AbsoluteSize.X,
					})
				end

				if self.props.onWidthChanged ~= nil then
					self.props.onWidthChanged(rbx.AbsoluteSize.X)
				end
			end
		end,
		[Roact.Event.AncestryChanged] = UIBloxConfig.improvementsToGridView  and self.onAncestryChanged or nil,

		NextSelectionLeft = self.props.NextSelectionLeft,
		NextSelectionRight = self.props.NextSelectionRight,
		NextSelectionUp = self.props.NextSelectionUp,
		NextSelectionDown = self.props.NextSelectionDown,

		[Roact.Ref] = self.props.frameRef or self.frameRef,
		-- Optional Gamepad prop for which grid member to focus on by default
		defaultChild = defaultChildIndex and self.focusableRefs[defaultChildIndex] or nil,
		-- Optional Gamepad prop for whether the previous focused on grid member should be refocused
		-- when returning focus to the grid
		restorePreviousChildFocus = self.props.restorePreviousChildFocus,
	}, gridChildren)
end

function GridView:didMount()
	self.isMounted = true

	local ref = self.props.frameRef or self.frameRef

	if ref.current and ref.current.AbsoluteSize.X ~= 0 then
		if not UIBloxConfig.improvementsToGridView or ref.current:IsDescendantOf(game) then
			self:setState({
				isInDataModel = true,
				containerWidth = ref.current.AbsoluteSize.X,
			})
		end

		if self.props.onWidthChanged ~= nil then
			delay(0, function()
				if ref.current then
					self.props.onWidthChanged(ref.current.AbsoluteSize.X)
				end
			end)
		end
	end
end

function GridView:willUnmount()
	self.isMounted = false
end

return Roact.forwardRef(function(props, ref)
	return Roact.createElement(GridView, Cryo.Dictionary.join(props, { frameRef = ref }))
end)