-- minimal smoke script: proves the mock can build, parent and dump a tree
local gui = Instance.new("ScreenGui")
gui.Name = "SmokeGui"
gui.Parent = gethui()

local frame = Instance.new("Frame")
frame.Name = "Card"
frame.Size = UDim2.new(0, 200, 0, 100)
frame.Position = UDim2.new(0, 20, 0, 20)
frame.BackgroundColor3 = Color3.fromRGB(30, 30, 40)
frame.Parent = gui

local label = Instance.new("TextLabel")
label.Name = "Caption"
label.Size = UDim2.new(1, 0, 1, 0)
label.BackgroundTransparency = 1
label.Text = "hello renderer"
label.TextSize = 16
label.TextColor3 = Color3.fromRGB(232, 236, 247)
label.Font = Enum.Font.GothamBold
label.Parent = frame

print("smoke built: frame offset width =", frame.Size.X.Offset)
