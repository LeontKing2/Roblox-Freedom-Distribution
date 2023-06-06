local CorePackages = game:GetService("CorePackages")

local Roact = require(CorePackages.Roact)
local t = require(CorePackages.Packages.t)

local PermissionButton = Roact.PureComponent:extend("PermissionButton")

local BUTTON_SIZE = 32

PermissionButton.validateProps = t.strictInterface({
	callback = t.callback,
	image = t.string,
	LayoutOrder = t.number,
})

function PermissionButton:render()
	return Roact.createElement("ImageButton", {
		LayoutOrder = self.props.LayoutOrder,
		Image = "rbxasset://textures/ui/dialog_white.png",
		ImageTransparency = 0.85,
		BackgroundTransparency = 1,
		ScaleType = Enum.ScaleType.Slice,
		SliceCenter = Rect.new(10, 10, 10, 10),
		Size = UDim2.new(0, BUTTON_SIZE, 0, BUTTON_SIZE),
		[Roact.Event.Activated] = self.props.callback,
	}, {
		ImageLabel = Roact.createElement("ImageLabel", {
			LayoutOrder = 2,
			Image = self.props.image,
			BackgroundTransparency = 1,
			Size = UDim2.new(0, BUTTON_SIZE, 0, BUTTON_SIZE),
		})
	})
end

return PermissionButton