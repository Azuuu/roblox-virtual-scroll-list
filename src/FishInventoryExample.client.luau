-- FishInventoryExample.client.luau
--
-- Example showing how to wire VirtualScrollList for a 10,000-item fish
-- inventory: 3-column card grid, live search, filters, and sorting.
--
-- Put this in StarterPlayerScripts. Put VirtualScrollList.luau in
-- ReplicatedStorage (or wherever your require path points).
--
-- Expected UI hierarchy:
--   ScreenGui
--     Frame ("InventoryWindow")
--       TextBox ("SearchBox")    -- optional, for live search
--       ScrollingFrame ("FishList")
--         -- leave empty; cards are cloned in by the module
--         -- optionally add a UIPadding here for a visual margin

local Players        = game:GetService("Players")
local TweenService   = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VirtualScrollList = require(ReplicatedStorage.VirtualScrollList)

local player      = Players.LocalPlayer
local playerGui   = player:WaitForChild("PlayerGui")
local screenGui   = playerGui:WaitForChild("InventoryGui")
local scrollingFrame = screenGui.InventoryWindow.FishList :: ScrollingFrame

------------------------------------------------------------------------
-- 1. Fish data
------------------------------------------------------------------------

local FISH_NAMES = { "Clownfish", "Tuna", "Salmon", "Anglerfish", "Pufferfish", "Marlin", "Koi", "Catfish" }
local RARITIES   = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5 }

-- Generates fake fish records. Replace with your real DataStore/server data.
local function generateFishData(count: number)
	local fish = table.create(count)
	for i = 1, count do
		fish[i] = {
			Id     = i,
			Name   = FISH_NAMES[((i - 1) % #FISH_NAMES) + 1] .. " #" .. i,
			Rarity = RARITIES[((i - 1) % #RARITIES) + 1],
			Weight = math.round((math.random() * 50 + 0.5) * 100) / 100,
			Sold   = (i % 7 == 0), -- every 7th fish is "sold"
		}
	end
	return fish
end

local fishData = generateFishData(10000)

------------------------------------------------------------------------
-- 2. Item template
------------------------------------------------------------------------

local RARITY_COLORS = {
	Common   = Color3.fromRGB(200, 200, 200),
	Uncommon = Color3.fromRGB(110, 200, 110),
	Rare     = Color3.fromRGB(90,  140, 240),
	Epic     = Color3.fromRGB(170,  90, 230),
	Legendary = Color3.fromRGB(240, 180,  60),
}

-- Builds the card template cloned by VirtualScrollList. Size is irrelevant
-- here — the module always overrides it with the resolved grid cell size.
local function buildFishCardTemplate(): Frame
	local card = Instance.new("Frame")
	card.Name                 = "FishCardTemplate"
	card.BackgroundColor3     = Color3.fromRGB(255, 255, 255)
	card.BackgroundTransparency = 0.92
	card.ClipsDescendants     = true
	card.Visible              = false

	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, 6)
	corner.Parent = card

	local nameLabel = Instance.new("TextLabel")
	nameLabel.Name            = "NameLabel"
	nameLabel.Size            = UDim2.new(1, -16, 0, 20)
	nameLabel.Position        = UDim2.new(0, 8, 0, 8)
	nameLabel.BackgroundTransparency = 1
	nameLabel.TextXAlignment  = Enum.TextXAlignment.Left
	nameLabel.Font            = Enum.Font.GothamMedium
	nameLabel.TextSize        = 15
	nameLabel.TextColor3      = Color3.fromRGB(240, 240, 240)
	nameLabel.TextTruncate    = Enum.TextTruncate.AtEnd
	nameLabel.Parent          = card

	local rarityLabel = Instance.new("TextLabel")
	rarityLabel.Name           = "RarityLabel"
	rarityLabel.Size           = UDim2.new(1, -16, 0, 16)
	rarityLabel.Position       = UDim2.new(0, 8, 0, 30)
	rarityLabel.BackgroundTransparency = 1
	rarityLabel.TextXAlignment = Enum.TextXAlignment.Left
	rarityLabel.Font           = Enum.Font.Gotham
	rarityLabel.TextSize       = 13
	rarityLabel.Parent         = card

	local weightLabel = Instance.new("TextLabel")
	weightLabel.Name           = "WeightLabel"
	weightLabel.Size           = UDim2.new(1, -16, 0, 16)
	weightLabel.Position       = UDim2.new(0, 8, 1, -24)
	weightLabel.BackgroundTransparency = 1
	weightLabel.TextXAlignment = Enum.TextXAlignment.Left
	weightLabel.Font           = Enum.Font.Gotham
	weightLabel.TextSize       = 13
	weightLabel.TextColor3     = Color3.fromRGB(200, 200, 200)
	weightLabel.Parent         = card

	return card
end

local fishCardTemplate = buildFishCardTemplate()

------------------------------------------------------------------------
-- 3. Pool callbacks
------------------------------------------------------------------------

-- SetupItem: called once per cloned pool slot. Good for persistent
-- events like hover that don't depend on which fish is shown.
local function setupItem(itemFrame: Frame, poolSlot: number)
	itemFrame.MouseEnter:Connect(function()
		itemFrame.BackgroundTransparency = 0.85
	end)
	itemFrame.MouseLeave:Connect(function()
		itemFrame.BackgroundTransparency = 0.94
	end)
end

-- Tracks active shimmer tweens by pool Instance so ItemRemoved can stop them.
local activeShimmers: { [Frame]: Tween } = {}

-- UpdateItem: called every time a pool Instance is rebound to a fish.
-- Legendary fish get a looping shimmer — per-fish state that must be
-- cleaned up by itemRemoved when the card scrolls away.
local function updateItem(itemFrame: Frame, item, index: number)
	local nameLabel   = itemFrame:FindFirstChild("NameLabel")   :: TextLabel
	local rarityLabel = itemFrame:FindFirstChild("RarityLabel") :: TextLabel
	local weightLabel = itemFrame:FindFirstChild("WeightLabel") :: TextLabel

	nameLabel.Text          = item.Name
	rarityLabel.Text        = item.Rarity
	rarityLabel.TextColor3  = RARITY_COLORS[item.Rarity] or Color3.fromRGB(255, 255, 255)
	weightLabel.Text        = string.format("%.2f kg", item.Weight)
	itemFrame.BackgroundTransparency = (index % 2 == 0) and 0.92 or 0.96

	if item.Rarity == "Legendary" then
		local shimmer = TweenService:Create(
			itemFrame,
			TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true),
			{ BackgroundTransparency = 0.8 }
		)
		shimmer:Play()
		activeShimmers[itemFrame] = shimmer
	end
end

-- ItemRemoved: called when a pool Instance's binding is cleared (scrolled
-- away, filtered out, list destroyed). Stops the shimmer tween so it
-- doesn't keep running on a slot now showing a different fish.
local function itemRemoved(itemFrame: Frame, item, index: number)
	local shimmer = activeShimmers[itemFrame]
	if shimmer then
		shimmer:Cancel()
		activeShimmers[itemFrame] = nil
	end
end

------------------------------------------------------------------------
-- 4. Create the list
------------------------------------------------------------------------

local list = VirtualScrollList.new(scrollingFrame, {
	ItemHeight   = 84,
	Buffer       = 4,
	Columns      = 3,
	SpacingX     = 8,
	SpacingY     = 8,
	-- AspectRatio = 1.6,  -- derive width from height instead of auto-fill
	-- AutoScale   = true, -- column count auto-fits; requires ItemWidth
	ItemTemplate = fishCardTemplate,
	SetupItem    = setupItem,
	UpdateItem   = updateItem,
	ItemRemoved  = itemRemoved,
})

list:SetData(fishData)

-- list:ScrollToIndex(5000)
-- list:ChangeItem(12, { Id = 12, Name = "Golden Tuna #12", Rarity = "Legendary", Weight = 88.4, Sold = false })
-- list:ChangeItemByPredicate(function(f) return f.Id == 12 end, newFish)

------------------------------------------------------------------------
-- 5. Grid density / size controls
------------------------------------------------------------------------

-- Switches to a fixed column count. Width auto-fills the row.
-- Wire to view-toggle buttons (list view / grid view / compact).
local function setView(columns: number)
	list:SetColumns(columns)
end
-- listViewButton.MouseButton1Click:Connect(function() setView(1) end)
-- gridViewButton.MouseButton1Click:Connect(function() setView(3) end)
-- compactViewButton.MouseButton1Click:Connect(function() setView(5) end)

-- AutoScale: column count adjusts automatically to the frame width so
-- cards always stay at cardWidth regardless of ScrollingFrame size.
local function setResponsiveCardView(cardWidth: number)
	list:SetColumns(1, { ItemWidth = cardWidth, SpacingX = 8, SpacingY = 8 })
	list:SetAutoScale(true)
end
-- local function disableResponsiveCardView()
--   list:SetAutoScale(false)
-- end

-- Directly resize cards (e.g. from a size-slider in settings).
-- Works with or without AutoScale: under AutoScale the column count
-- recalculates; otherwise the column count stays fixed and cards resize.
local function setCardSize(width: number, height: number)
	list:SetItemSize(width, height)
end
-- cardSizeSlider.Changed:Connect(function(v) setCardSize(v, v * 0.6) end)

------------------------------------------------------------------------
-- 6. Search (debounced to avoid re-filtering 10k items every keystroke)
------------------------------------------------------------------------

local searchBox = screenGui.InventoryWindow:FindFirstChild("SearchBox") :: TextBox?

if searchBox then
	local debounceToken = 0
	searchBox:GetPropertyChangedSignal("Text"):Connect(function()
		debounceToken += 1
		local token = debounceToken
		local query = searchBox.Text
		task.delay(0.15, function()
			if token == debounceToken then
				list:SetSearch(query)
			end
		end)
	end)
end

------------------------------------------------------------------------
-- 7. Filters
------------------------------------------------------------------------

local RARITIES_LIST = { "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- Rarity toggles: track which rarities are visible (all on by default).
local selectedRarities: { [string]: boolean } = {}
for _, rarity in ipairs(RARITIES_LIST) do
	selectedRarities[rarity] = true
end

-- Re-applies (or removes) the rarity filter based on selectedRarities.
-- Removing it entirely when all are selected skips a needless predicate
-- call per item on every filter pass.
local function applyRarityFilter()
	local allSelected = true
	for _, on in pairs(selectedRarities) do
		if not on then allSelected = false; break end
	end
	if allSelected then
		list:RemoveFilter("rarity")
	else
		list:SetFilter("rarity", function(item)
			return selectedRarities[item.Rarity] == true
		end)
	end
end
-- rarityButton.MouseButton1Click:Connect(function()
--   selectedRarities[rarity] = not selectedRarities[rarity]
--   applyRarityFilter()
-- end)

-- Visibility filter: hide items marked as sold.
local hideSold = false
local function applyHideSoldFilter()
	if hideSold then
		list:SetFilter("hideSold", function(item) return item.Sold ~= true end)
	else
		list:RemoveFilter("hideSold")
	end
end
-- hideSoldToggle.MouseButton1Click:Connect(function()
--   hideSold = not hideSold
--   applyHideSoldFilter()
-- end)

-- If an external system changes state that a filter depends on, call
-- RefreshFilters() to re-run all predicates without re-registering them.
-- list:RefreshFilters()

------------------------------------------------------------------------
-- 8. Sorting
------------------------------------------------------------------------

-- Sort by weight descending (heaviest first).
-- SetSort registers a named comparator: (a, b) -> boolean,
-- return true if `a` should appear before `b`.
local function sortByWeightDesc()
	list:SetSort("weight", function(a, b)
		return a.Weight > b.Weight
	end)
end

-- Sort by rarity descending (Legendary first), weight as tiebreaker.
-- Multiple sorts are applied in registration order — here "rarity" wins
-- ties if registered first, and "weight" breaks remaining ties.
local function sortByRarityThenWeight()
	list:SetSort("rarity", function(a, b)
		return (RARITY_RANK[a.Rarity] or 0) > (RARITY_RANK[b.Rarity] or 0)
	end)
	list:SetSort("weight", function(a, b)
		return a.Weight > b.Weight
	end)
end

-- Sort alphabetically by name.
local function sortByName()
	list:SetSort("name", function(a, b)
		return a.Name < b.Name
	end)
end

-- Clear all sorts and return to source order.
local function clearSorts()
	list:ClearSorts()
end

-- If a sort's external state changes without re-calling SetSort,
-- call RefreshSort() to re-run all comparators.
-- list:RefreshSort()

-- Wire sort functions to your sort buttons, e.g.:
-- sortWeightButton.MouseButton1Click:Connect(sortByWeightDesc)
-- sortRarityButton.MouseButton1Click:Connect(sortByRarityThenWeight)
-- sortNameButton.MouseButton1Click:Connect(sortByName)
-- clearSortButton.MouseButton1Click:Connect(clearSorts)

-- list:Destroy() -- call when the inventory UI is closed

return list
