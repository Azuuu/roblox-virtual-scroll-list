-- VirtualScrollList
-- Neuroticxs(Ace) v0.0.1 / 22/06/2026
-- github: https://github.com/Azuuu/roblox-virtual-scroll-list

-- A lightweight, framework-free virtual scrolling grid for Roblox.
-- Supports large datasets (10,000+ items) without creating one Instance
-- per item. Pools a small set of cloned Instances (just enough to cover
-- the visible viewport + a buffer) and recycles them as the user scrolls.
--
-- Usage:
--   local list = VirtualScrollList.new(scrollingFrame, {
--     ItemHeight  = 84,
--     Columns     = 3,
--     SpacingX    = 8,
--     SpacingY    = 8,
--     ItemTemplate = someFrame,     -- cloned into the pool
--     SetupItem  = function(frame, poolSlot) ... end,   -- once per clone
--     UpdateItem = function(frame, item, index) ... end, -- every bind
--     ItemRemoved = function(frame, item, index) ... end, -- optional cleanup
--   })
--   list:SetData(fishArray)
--   list:Destroy()
--
-- Config fields:
--   ItemHeight   number         Fixed height (px) of every item.
--   Buffer       number?        Extra rows above/below viewport. Default 3.
--   Columns      number?        Grid columns. Default 1. Ignored if AutoScale.
--   ItemWidth    number?        Fixed item width. Auto-calculated if omitted.
--   AspectRatio  number?        width/height ratio; overrides ItemWidth/auto-fill.
--                               Ignored if AutoScale is on.
--   AutoScale    boolean?       Column count becomes responsive; items stay at
--                               ItemWidth. Requires ItemWidth. Ignores Columns.
--   SpacingX     number?        Gap (px) between columns. Default 0.
--   SpacingY     number?        Gap (px) between rows. Default 0.
--   ItemTemplate GuiObject      Cloned to build the pool.
--   SetupItem    function       Called once per cloned pool Instance.
--   UpdateItem   function       Called each time a pool Instance is bound to data.
--   ItemRemoved  function?      Called when a bound pool Instance loses its data.
--
-- UIPadding: if a UIPadding Instance is parented to the ScrollingFrame (now or
-- later), it is auto-detected. Left/right padding shrinks usable width for
-- column math; top/bottom padding shrinks the usable viewport height and
-- offsets item positions so they land inside the padded area.
--
-- Sorting: register named sort comparators with SetSort(name, fn). Multiple
-- sorts are applied in registration order — earlier-registered sorts take
-- priority and later ones only break ties. Sorting runs after filtering.
-- Sort functions have the signature: (a: any, b: any) -> boolean
-- Return true if `a` should appear before `b`.
--
-- Filtering: register named predicates with SetFilter(name, fn). All filters
-- are AND-combined — an item must pass every registered filter to be shown.
-- Search is a special built-in filter registered under a reserved key.

local VirtualScrollList = {}
VirtualScrollList.__index = VirtualScrollList

local DEFAULT_BUFFER = 3
local DEFAULT_SEARCH_KEY = "__search"

-- Callback types
type SetupItemCallback   = (itemFrame: GuiObject, poolSlot: number) -> ()
type UpdateItemCallback  = (itemFrame: GuiObject, item: any, index: number) -> ()
type ItemRemovedCallback = (itemFrame: GuiObject, item: any, index: number) -> ()
export type FilterFn     = (item: any, index: number) -> boolean
export type SortFn       = (a: any, b: any) -> boolean
export type SearchMatchFn = (item: any, query: string) -> boolean

export type Config = {
	ItemHeight:   number,
	Buffer:       number?,
	Columns:      number?,
	ItemWidth:    number?,
	AspectRatio:  number?,
	AutoScale:    boolean?,
	SpacingX:     number?,
	SpacingY:     number?,
	ItemTemplate: GuiObject,
	SetupItem:    SetupItemCallback,
	UpdateItem:   UpdateItemCallback,
	ItemRemoved:  ItemRemovedCallback?,
}

-- Default search matcher: case-insensitive substring match on item.Name.
local function defaultSearchMatch(item: any, query: string): boolean
	local name = item and item.Name
	if type(name) ~= "string" then return false end
	return string.find(string.lower(name), query, 1, true) ~= nil
end

-- Creates a new VirtualScrollList bound to the given ScrollingFrame.
-- Throws if required config fields are missing or invalid.
function VirtualScrollList.new(scrollingFrame: ScrollingFrame, config: Config)
	assert(scrollingFrame and scrollingFrame:IsA("ScrollingFrame"),
		"VirtualScrollList requires a ScrollingFrame")
	assert(type(config.ItemHeight) == "number" and config.ItemHeight > 0,
		"Config.ItemHeight must be a positive number")
	assert(typeof(config.ItemTemplate) == "Instance" and config.ItemTemplate:IsA("GuiObject"),
		"Config.ItemTemplate must be a GuiObject Instance to clone")
	assert(type(config.SetupItem) == "function",  "Config.SetupItem must be a function")
	assert(type(config.UpdateItem) == "function", "Config.UpdateItem must be a function")
	if config.Columns ~= nil then
		assert(type(config.Columns) == "number" and config.Columns >= 1 and config.Columns % 1 == 0,
			"Config.Columns must be a positive integer")
	end
	if config.ItemWidth ~= nil then
		assert(type(config.ItemWidth) == "number" and config.ItemWidth > 0,
			"Config.ItemWidth must be a positive number")
	end
	if config.AspectRatio ~= nil then
		assert(type(config.AspectRatio) == "number" and config.AspectRatio > 0,
			"Config.AspectRatio must be a positive number")
	end
	if config.AutoScale then
		assert(type(config.ItemWidth) == "number" and config.ItemWidth > 0,
			"Config.ItemWidth is required when Config.AutoScale is true")
	end
	if config.ItemRemoved ~= nil then
		assert(type(config.ItemRemoved) == "function", "Config.ItemRemoved must be a function")
	end

	local self = setmetatable({}, VirtualScrollList)

	self._scrollingFrame = scrollingFrame
	self._itemHeight     = config.ItemHeight
	self._buffer         = config.Buffer or DEFAULT_BUFFER
	self._itemTemplate   = config.ItemTemplate
	self._setupItem      = config.SetupItem
	self._updateItem     = config.UpdateItem
	self._itemRemoved    = config.ItemRemoved :: ItemRemovedCallback?

	-- Layout config. See _resolveLayout for the priority chain.
	self._columns           = config.Columns or 1
	self._explicitItemWidth = config.ItemWidth :: number?
	self._aspectRatio       = config.AspectRatio :: number?
	self._autoScale         = config.AutoScale == true
	self._spacingX          = config.SpacingX or 0
	self._spacingY          = config.SpacingY or 0
	self._resolvedItemWidth = 0 :: number

	-- _sourceData: the raw array passed to SetData (never modified by filters/sort).
	-- _data: the filtered + sorted view that the virtual scroller actually uses.
	-- Only _data is indexed by the pool's bound indices.
	self._sourceData = {} :: { any }
	self._data       = {} :: { any }
	self._dataCount  = 0

	-- Filter state. All predicates are AND-combined. Search is a special
	-- built-in filter stored under DEFAULT_SEARCH_KEY in this same table.
	self._filters     = {} :: { [string]: FilterFn }
	self._filterOrder = {} :: { string }
	self._searchQuery   = nil :: string?
	self._searchMatchFn = defaultSearchMatch :: SearchMatchFn

	-- Sort state. Comparators are applied in _sortOrder order.
	-- Earlier entries have higher priority; later ones only break ties.
	self._sorts     = {} :: { [string]: SortFn }
	self._sortOrder = {} :: { string }

	-- Pool: reusable cloned Instances. _poolBoundIndex tracks which data
	-- index each clone currently shows; _poolBoundItem tracks the actual
	-- item value (needed by ItemRemoved even after _data is replaced).
	self._pool           = {} :: { GuiObject }
	self._poolBoundIndex = {} :: { [GuiObject]: number? }
	self._poolBoundItem  = {} :: { [GuiObject]: any }

	self._firstVisibleIndex = nil :: number?
	self._lastVisibleIndex  = nil :: number?
	self._destroyed         = false

	-- UIPadding: auto-detected and kept live via property change connections.
	self._uiPadding          = nil :: UIPadding?
	self._paddingConnections = {} :: { RBXScriptConnection }
	self._paddingLeft   = 0
	self._paddingRight  = 0
	self._paddingTop    = 0
	self._paddingBottom = 0

	-- Disable AutomaticCanvasSize so we can drive CanvasSize manually.
	scrollingFrame.AutomaticCanvasSize = Enum.AutomaticSize.None

	self:_attachUIPadding(scrollingFrame:FindFirstChildOfClass("UIPadding"))
	self:_resolveLayout()

	self._connections = {}

	table.insert(self._connections,
		scrollingFrame:GetPropertyChangedSignal("CanvasPosition"):Connect(function()
			self:_refresh()
		end))

	table.insert(self._connections,
		scrollingFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(function()
			self:_handleResize()
		end))

	-- Track UIPadding added or removed after construction.
	table.insert(self._connections,
		scrollingFrame.ChildAdded:Connect(function(child: Instance)
			if not self._uiPadding and child:IsA("UIPadding") then
				self:_attachUIPadding(child)
				self:_handlePaddingChanged()
			end
		end))

	table.insert(self._connections,
		scrollingFrame.ChildRemoved:Connect(function(child: Instance)
			if child == self._uiPadding then
				self:_attachUIPadding(nil)
				self:_handlePaddingChanged()
			end
		end))

	return self
end

------------------------------------------------------------------------
-- Data
------------------------------------------------------------------------

-- Replaces the full source dataset. Runs filters + sort over the new
-- data and re-renders the visible viewport, resetting scroll to the top.
function VirtualScrollList:SetData(data: { any })
	assert(not self._destroyed, "Cannot call SetData on a destroyed VirtualScrollList")
	self._sourceData = data
	self:_applyFiltersAndSort(true)
end

-- Returns the full unfiltered source dataset last passed to SetData.
function VirtualScrollList:GetSourceData(): { any }
	return self._sourceData
end

-- Returns the current filtered + sorted view (what is actually being scrolled).
function VirtualScrollList:GetData(): { any }
	return self._data
end

-- Number of items currently passing all filters.
function VirtualScrollList:GetVisibleCount(): number
	return self._dataCount
end

-- Updates a single item in the source data by its source index, then
-- re-applies filters and sort. Use ChangeItemByPredicate if you don't
-- track source indices directly.
function VirtualScrollList:ChangeItem(sourceIndex: number, item: any)
	assert(not self._destroyed, "Cannot call ChangeItem on a destroyed VirtualScrollList")
	if sourceIndex < 1 or sourceIndex > #self._sourceData then return end
	self._sourceData[sourceIndex] = item
	self:_applyFiltersAndSort()
end

-- Updates the first item in source data for which findFn returns true,
-- then re-applies filters and sort. Returns true if a match was found.
function VirtualScrollList:ChangeItemByPredicate(findFn: (item: any) -> boolean, newItem: any): boolean
	assert(not self._destroyed, "Cannot call ChangeItemByPredicate on a destroyed VirtualScrollList")
	for i, existing in ipairs(self._sourceData) do
		if findFn(existing) then
			self._sourceData[i] = newItem
			self:_applyFiltersAndSort()
			return true
		end
	end
	return false
end

------------------------------------------------------------------------
-- Layout
------------------------------------------------------------------------

-- Changes the column count and re-renders. Optionally pass new
-- ItemWidth/AspectRatio/SpacingX/SpacingY in the options table at the
-- same time. If AutoScale is on, the `columns` argument is overridden
-- by the derived count; options still apply normally.
function VirtualScrollList:SetColumns(
	columns: number,
	options: { ItemWidth: number?, AspectRatio: number?, SpacingX: number?, SpacingY: number? }?
)
	assert(not self._destroyed, "Cannot call SetColumns on a destroyed VirtualScrollList")
	assert(type(columns) == "number" and columns >= 1 and columns % 1 == 0,
		"columns must be a positive integer")

	self._columns = columns
	if options then
		self._explicitItemWidth = options.ItemWidth
		self._aspectRatio       = options.AspectRatio
		if options.SpacingX ~= nil then self._spacingX = options.SpacingX end
		if options.SpacingY ~= nil then self._spacingY = options.SpacingY end
	end
	self:_applyLayoutChange()
end

-- Toggles AutoScale. When true, column count is derived from ItemWidth
-- and the frame width — Columns config is ignored. Requires ItemWidth
-- to already be set. When false, reverts to Columns/ItemWidth/AspectRatio.
function VirtualScrollList:SetAutoScale(enabled: boolean)
	assert(not self._destroyed, "Cannot call SetAutoScale on a destroyed VirtualScrollList")
	if enabled then
		assert(type(self._explicitItemWidth) == "number" and self._explicitItemWidth > 0,
			"SetAutoScale(true) requires ItemWidth to be set first")
	end
	self._autoScale = enabled
	self:_applyLayoutChange()
end

-- Mutates item width and/or height and re-renders. Pass nil for either
-- to leave that dimension unchanged.
-- Setting width also clears AspectRatio so the explicit size takes effect.
-- If AutoScale is on, the new width is used as the anchor for column fitting.
function VirtualScrollList:SetItemSize(width: number?, height: number?)
	assert(not self._destroyed, "Cannot call SetItemSize on a destroyed VirtualScrollList")
	assert(width ~= nil or height ~= nil, "SetItemSize requires at least one of width or height")
	if width ~= nil then
		assert(type(width) == "number" and width > 0, "width must be a positive number")
		self._explicitItemWidth = width
		self._aspectRatio = nil
	end
	if height ~= nil then
		assert(type(height) == "number" and height > 0, "height must be a positive number")
		self._itemHeight = height
	end
	self:_applyLayoutChange()
end

-- Returns the current column count. Under AutoScale this is the live
-- derived value, not what was last passed to SetColumns.
function VirtualScrollList:GetColumns(): number
	return self._columns
end

-- Returns whether AutoScale is currently enabled.
function VirtualScrollList:GetAutoScale(): boolean
	return self._autoScale
end

-- Returns the current item height (never auto-derived).
function VirtualScrollList:GetItemHeight(): number
	return self._itemHeight
end

-- Returns the resolved item width actually used for rendering — the
-- result of AspectRatio/AutoScale/ItemWidth/auto-fill, whichever is
-- currently in effect.
function VirtualScrollList:GetItemWidth(): number
	return self._resolvedItemWidth
end

-- Scrolls so the item at `index` (in the filtered+sorted view) is
-- visible at the top of the viewport. With Columns > 1, scrolls to
-- the row containing that index.
function VirtualScrollList:ScrollToIndex(index: number)
	assert(not self._destroyed, "Cannot call ScrollToIndex on a destroyed VirtualScrollList")
	index = math.clamp(index, 1, math.max(self._dataCount, 1))
	local row = math.floor((index - 1) / self._columns)
	local targetY = row * self:_rowPitch()
	self._scrollingFrame.CanvasPosition = Vector2.new(self._scrollingFrame.CanvasPosition.X, targetY)
end

------------------------------------------------------------------------
-- Filtering
------------------------------------------------------------------------

-- Registers (or replaces) a named filter predicate.
-- predicateFn(item, sourceIndex) -> boolean: return true to show the item.
-- All registered filters are AND-combined. Applies immediately.
function VirtualScrollList:SetFilter(name: string, predicateFn: FilterFn)
	assert(not self._destroyed, "Cannot call SetFilter on a destroyed VirtualScrollList")
	assert(type(name) == "string" and name ~= "", "Filter name must be a non-empty string")
	assert(type(predicateFn) == "function", "predicateFn must be a function")
	if self._filters[name] == nil then
		table.insert(self._filterOrder, name)
	end
	self._filters[name] = predicateFn
	self:_applyFiltersAndSort()
end

-- Removes a registered filter by name. No-op if it doesn't exist.
function VirtualScrollList:RemoveFilter(name: string)
	assert(not self._destroyed, "Cannot call RemoveFilter on a destroyed VirtualScrollList")
	if self._filters[name] == nil then return end
	self._filters[name] = nil
	for i, n in ipairs(self._filterOrder) do
		if n == name then table.remove(self._filterOrder, i)
break end
	end
	self:_applyFiltersAndSort()
end

-- Clears all registered filters and the search query.
function VirtualScrollList:ClearFilters()
	assert(not self._destroyed, "Cannot call ClearFilters on a destroyed VirtualScrollList")
	self._filters     = {}
	self._filterOrder = {}
	self._searchQuery = nil
	self:_applyFiltersAndSort()
end

-- Sets or clears the search query (pass "" or nil to clear).
-- Internally registered as a filter under a reserved key, so it composes
-- naturally with SetFilter. matchFn overrides the default item.Name
-- case-insensitive match if provided, and is remembered for future calls.
function VirtualScrollList:SetSearch(query: string?, matchFn: SearchMatchFn?)
	assert(not self._destroyed, "Cannot call SetSearch on a destroyed VirtualScrollList")
	if matchFn then self._searchMatchFn = matchFn end

	if query == nil or query == "" then
		self._searchQuery = nil
		if self._filters[DEFAULT_SEARCH_KEY] then
			self._filters[DEFAULT_SEARCH_KEY] = nil
			for i, n in ipairs(self._filterOrder) do
				if n == DEFAULT_SEARCH_KEY then table.remove(self._filterOrder, i)
break end
			end
		end
		self:_applyFiltersAndSort()
		return
	end

	self._searchQuery = string.lower(query)
	if self._filters[DEFAULT_SEARCH_KEY] == nil then
		table.insert(self._filterOrder, DEFAULT_SEARCH_KEY)
	end
	self._filters[DEFAULT_SEARCH_KEY] = function(item: any)
		return self._searchMatchFn(item, self._searchQuery :: string)
	end
	self:_applyFiltersAndSort()
end

-- Re-runs all filters and sorts without changing any registrations.
-- Use this when a filter or sort's external state changed (e.g. a
-- toggle variable flipped) without calling SetFilter/SetSort again.
function VirtualScrollList:RefreshFilters()
	assert(not self._destroyed, "Cannot call RefreshFilters on a destroyed VirtualScrollList")
	self:_applyFiltersAndSort()
end

------------------------------------------------------------------------
-- Sorting
------------------------------------------------------------------------

-- Registers (or replaces) a named sort comparator.
-- compareFn(a, b) -> boolean: return true if `a` should appear before `b`.
-- Multiple sorts are applied in registration order — earlier-registered
-- sorts take priority; later ones only break ties. Applies immediately.
function VirtualScrollList:SetSort(name: string, compareFn: SortFn)
	assert(not self._destroyed, "Cannot call SetSort on a destroyed VirtualScrollList")
	assert(type(name) == "string" and name ~= "", "Sort name must be a non-empty string")
	assert(type(compareFn) == "function", "compareFn must be a function")
	if self._sorts[name] == nil then
		table.insert(self._sortOrder, name)
	end
	self._sorts[name] = compareFn
	self:_applyFiltersAndSort()
end

-- Removes a registered sort by name. No-op if it doesn't exist.
function VirtualScrollList:RemoveSort(name: string)
	assert(not self._destroyed, "Cannot call RemoveSort on a destroyed VirtualScrollList")
	if self._sorts[name] == nil then return end
	self._sorts[name] = nil
	for i, n in ipairs(self._sortOrder) do
		if n == name then table.remove(self._sortOrder, i)
break end
	end
	self:_applyFiltersAndSort()
end

-- Removes all registered sorts. Applies immediately.
function VirtualScrollList:ClearSorts()
	assert(not self._destroyed, "Cannot call ClearSorts on a destroyed VirtualScrollList")
	self._sorts     = {}
	self._sortOrder = {}
	self:_applyFiltersAndSort()
end

-- Re-runs sorts (and filters) without changing registrations.
-- Use this when a sort comparator's external state changed without
-- calling SetSort again.
function VirtualScrollList:RefreshSort()
	assert(not self._destroyed, "Cannot call RefreshSort on a destroyed VirtualScrollList")
	self:_applyFiltersAndSort()
end

------------------------------------------------------------------------
-- Cleanup
------------------------------------------------------------------------

-- Disconnects all connections, fires ItemRemoved for every still-bound
-- pool Instance, and destroys all cloned Instances. Safe to call
-- multiple times — subsequent calls are no-ops.
function VirtualScrollList:Destroy()
	if self._destroyed then return end
	self._destroyed = true

	for _, c in ipairs(self._connections) do c:Disconnect() end
	self._connections = {}

	for _, c in ipairs(self._paddingConnections) do c:Disconnect() end
	self._paddingConnections = {}

	for _, itemFrame in ipairs(self._pool) do
		if self._poolBoundIndex[itemFrame] then
			self:_fireItemRemoved(itemFrame)
		end
		itemFrame:Destroy()
	end
	self._pool           = {}
	self._poolBoundIndex = {}
	self._poolBoundItem  = {}
	self._data           = {}
	self._sourceData     = {}
	self._filters        = {}
	self._filterOrder    = {}
	self._sorts          = {}
	self._sortOrder      = {}
end

------------------------------------------------------------------------
-- Internal: filter + sort pipeline
------------------------------------------------------------------------

-- Core pipeline: filter _sourceData through all registered predicates
-- (AND-combined), then sort the result with all registered comparators
-- (earlier-registered comparators take priority). Updates _data/_dataCount,
-- CanvasSize, scroll clamp, and force-refreshes the pool.
-- forceScrollReset resets CanvasPosition to the top instead of clamping.
function VirtualScrollList:_applyFiltersAndSort(forceScrollReset: boolean?)
	if self._destroyed then return end

	local sourceData  = self._sourceData
	local filterOrder = self._filterOrder
	local sortOrder   = self._sortOrder

	-- Filter pass.
	local filtered: { any }
	if #filterOrder == 0 then
		-- Fast path: no filters, just copy the source array.
		filtered = table.create(#sourceData)
		table.move(sourceData, 1, #sourceData, 1, filtered)
	else
		filtered = {}
		for index, item in ipairs(sourceData) do
			local passes = true
			for _, name in ipairs(filterOrder) do
				if not self._filters[name](item, index) then
					passes = false
					break
				end
			end
			if passes then
				table.insert(filtered, item)
			end
		end
	end

	-- Sort pass. Build a single merged comparator that chains all registered
	-- sorts in order: the first one that returns a definitive result wins;
	-- if both directions return false (a tie), the next sort is tried.
	if #sortOrder > 0 then
		local sorts     = self._sorts
		local sortNames = sortOrder
		table.sort(filtered, function(a, b)
			for _, name in ipairs(sortNames) do
				local fn = sorts[name]
				if fn(a, b) then return true end
				if fn(b, a) then return false end
				-- tie: fall through to next comparator
			end
			return false -- all comparators tied; preserve current order
		end)
	end

	self._data      = filtered
	self._dataCount = #filtered

	self._scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, self:_canvasHeight())

	if forceScrollReset then
		self._scrollingFrame.CanvasPosition = Vector2.new(self._scrollingFrame.CanvasPosition.X, 0)
	else
		local maxY = math.max(0, self:_canvasHeight() - self:_usableHeight())
		if self._scrollingFrame.CanvasPosition.Y > maxY then
			self._scrollingFrame.CanvasPosition = Vector2.new(self._scrollingFrame.CanvasPosition.X, maxY)
		end
	end

	self:_refresh(true)
end

------------------------------------------------------------------------
-- Internal: virtual scroll rendering
------------------------------------------------------------------------

-- Determines which data-index range is currently visible, assigns pooled
-- Instances to cover it (cloning more if the pool is undersized), and
-- fires ItemRemoved for any Instances whose previous binding is changing.
-- force = true rebinds even if the visible index range hasn't changed.
function VirtualScrollList:_refresh(force: boolean?)
	if self._destroyed then return end

	if self._dataCount == 0 then
		self:_hideAllItems()
		self._firstVisibleIndex = nil
		self._lastVisibleIndex  = nil
		return
	end

	local scrollingFrame = self._scrollingFrame
	local viewportHeight = self:_usableHeight()
	local scrollY        = scrollingFrame.CanvasPosition.Y
	local columns        = self._columns
	local rowPitch       = self:_rowPitch()

	-- Convert scroll position to visible row range (in row-space), then
	-- expand to the corresponding data-index range.
	local firstRow      = math.floor(scrollY / rowPitch) - self._buffer
	local visibleRows   = math.ceil(viewportHeight / rowPitch) + self._buffer * 2
	local lastRow       = firstRow + visibleRows - 1
	local totalRows     = self:_totalRows()
	firstRow = math.clamp(firstRow, 0, math.max(totalRows - 1, 0))
	lastRow  = math.clamp(lastRow,  0, math.max(totalRows - 1, 0))

	local firstIndex = math.clamp(firstRow * columns + 1, 1, self._dataCount)
	local lastIndex  = math.clamp((lastRow + 1) * columns, 1, self._dataCount)

	if not force and firstIndex == self._firstVisibleIndex and lastIndex == self._lastVisibleIndex then
		return
	end

	self._firstVisibleIndex = firstIndex
	self._lastVisibleIndex  = lastIndex

	self:_ensurePoolSize(lastIndex - firstIndex + 1)

	-- First pass: identify pool Instances that already show a still-needed
	-- index (keep them) vs those whose binding is about to change (fire
	-- ItemRemoved and move them to the free list).
	local stillNeeded  = {} :: { [number]: boolean }
	for index = firstIndex, lastIndex do stillNeeded[index] = true end

	local boundIndices = {} :: { [number]: GuiObject }
	local freeItems    = {} :: { GuiObject }
	for _, itemFrame in ipairs(self._pool) do
		local boundIndex = self._poolBoundIndex[itemFrame]
		if boundIndex and stillNeeded[boundIndex] then
			boundIndices[boundIndex] = itemFrame
		else
			if boundIndex then self:_fireItemRemoved(itemFrame) end
			table.insert(freeItems, itemFrame)
		end
	end

	-- Second pass: assign free Instances to indices not already covered.
	local freeCursor = 1
	for index = firstIndex, lastIndex do
		if not boundIndices[index] then
			local itemFrame = freeItems[freeCursor]
			freeCursor += 1
			assert(itemFrame, "VirtualScrollList: pool undersized (this should never happen)")
			local item = self._data[index]
			self._poolBoundIndex[itemFrame] = index
			self._poolBoundItem[itemFrame]  = item
			itemFrame.Position = self:_positionForIndex(index)
			itemFrame.Visible  = true
			self._updateItem(itemFrame, item, index)
		end
	end

	-- Hide any leftover free Instances that were not reassigned.
	-- ItemRemoved already fired for these in the first pass above.
	for i = freeCursor, #freeItems do
		local itemFrame = freeItems[i]
		itemFrame.Visible = false
		self._poolBoundIndex[itemFrame] = nil
		self._poolBoundItem[itemFrame]  = nil
	end
end

------------------------------------------------------------------------
-- Internal: layout math
------------------------------------------------------------------------

-- Total rows needed at the current Columns/dataCount.
function VirtualScrollList:_totalRows(): number
	if self._dataCount == 0 then return 0 end
	return math.ceil(self._dataCount / self._columns)
end

-- Vertical distance between the start of consecutive rows (ItemHeight + SpacingY).
-- This is what scroll math steps by — distinct from _itemHeight (just the item's size).
function VirtualScrollList:_rowPitch(): number
	return self._itemHeight + self._spacingY
end

-- Total canvas height: content height + top/bottom padding so content
-- renders inside the padded area and the last row isn't flush against
-- the bottom edge. Zero when there's no data.
function VirtualScrollList:_canvasHeight(): number
	local totalRows = self:_totalRows()
	if totalRows == 0 then return 0 end
	local contentHeight = totalRows * self:_rowPitch() - self._spacingY
	return contentHeight + self._paddingTop + self._paddingBottom
end

-- UDim2 Position for a 1-based data index, offset by UIPadding's
-- left/top so items land inside the padded area.
function VirtualScrollList:_positionForIndex(index: number): UDim2
	local zeroBased = index - 1
	local col = zeroBased % self._columns
	local row = (zeroBased - col) / self._columns
	local x = self._paddingLeft + col * (self._resolvedItemWidth + self._spacingX)
	local y = self._paddingTop  + row * self:_rowPitch()
	return UDim2.new(0, x, 0, y)
end

-- Resolves _resolvedItemWidth and (under AutoScale) _columns.
-- Priority: AutoScale (width fixed, columns derived from usable width)
--         > AspectRatio (width = ItemHeight * AspectRatio)
--         > explicit ItemWidth
--         > auto-fill (usable width / Columns).
-- Returns true if either value actually changed.
function VirtualScrollList:_resolveLayout(): boolean
	local newWidth: number
	local newColumns: number = self._columns

	if self._autoScale then
		newWidth = self._explicitItemWidth :: number
		local usableWidth = self:_usableWidth()
		local stride = newWidth + self._spacingX
		newColumns = math.max(1, math.floor((usableWidth + self._spacingX) / stride))
	elseif self._aspectRatio then
		newWidth = self._itemHeight * self._aspectRatio
	elseif self._explicitItemWidth then
		newWidth = self._explicitItemWidth
	else
		local usableWidth  = self:_usableWidth()
		local totalSpacing = self._spacingX * (self._columns - 1)
		newWidth = math.max((usableWidth - totalSpacing) / self._columns, 0)
	end

	local changed = newWidth ~= self._resolvedItemWidth or newColumns ~= self._columns
	self._resolvedItemWidth = newWidth
	self._columns           = newColumns
	return changed
end

-- Shared aftermath for public setters that change layout (SetColumns,
-- SetAutoScale, SetItemSize). Always recomputes CanvasSize, scroll clamp,
-- pool layout, and force-refreshes — never skips these steps the way
-- _handleResize does, because ItemHeight changes (e.g. via SetItemSize)
-- affect canvas height without necessarily changing columns.
function VirtualScrollList:_applyLayoutChange()
	self:_resolveLayout()
	self._scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, self:_canvasHeight())
	local maxY = math.max(0, self:_canvasHeight() - self:_usableHeight())
	if self._scrollingFrame.CanvasPosition.Y > maxY then
		self._scrollingFrame.CanvasPosition = Vector2.new(self._scrollingFrame.CanvasPosition.X, maxY)
	end
	self:_relayoutPool()
	self:_refresh(true)
end

-- Handles a passive ScrollingFrame AbsoluteSize change. Re-resolves layout
-- and re-resolves padding (Scale components depend on frame size). If columns
-- changed (AutoScale), updates CanvasSize and scroll clamp. Always refreshes
-- since viewport height may have changed independently of width/columns.
function VirtualScrollList:_handleResize()
	self:_resolvePaddingPixels() -- Scale components may have changed
	local previousColumns = self._columns
	local layoutChanged   = self:_resolveLayout()

	if layoutChanged then
		if self._columns ~= previousColumns then
			self._scrollingFrame.CanvasSize = UDim2.new(0, 0, 0, self:_canvasHeight())
			local maxY = math.max(0, self:_canvasHeight() - self:_usableHeight())
			if self._scrollingFrame.CanvasPosition.Y > maxY then
				self._scrollingFrame.CanvasPosition = Vector2.new(self._scrollingFrame.CanvasPosition.X, maxY)
			end
		end
		self:_relayoutPool()
	end

	self:_refresh()
end

-- Re-applies Size/Position to every pooled Instance based on the current
-- resolved width/height/columns/spacing. Called after any layout change
-- that shifts existing cell positions.
function VirtualScrollList:_relayoutPool()
	for _, itemFrame in ipairs(self._pool) do
		itemFrame.Size = UDim2.new(0, self._resolvedItemWidth, 0, self._itemHeight)
		local boundIndex = self._poolBoundIndex[itemFrame]
		if boundIndex then
			itemFrame.Position = self:_positionForIndex(boundIndex)
		end
	end
end

-- Clones ItemTemplate until the pool has at least `size` Instances.
-- Calls SetupItem exactly once per new clone.
function VirtualScrollList:_ensurePoolSize(size: number)
	while #self._pool < size do
		local itemFrame = self._itemTemplate:Clone()
		itemFrame.Size    = UDim2.new(0, self._resolvedItemWidth, 0, self._itemHeight)
		itemFrame.Visible = false
		itemFrame.Parent  = self._scrollingFrame
		local poolSlot = #self._pool + 1
		self._setupItem(itemFrame, poolSlot)
		table.insert(self._pool, itemFrame)
		self._poolBoundIndex[itemFrame] = nil
		self._poolBoundItem[itemFrame]  = nil
	end
end

-- Fires ItemRemoved for a pooled Instance using the item/index it was
-- last bound to. Reads _poolBoundItem rather than _data[index] since
-- _data may have already been replaced by a filter/sort pass.
function VirtualScrollList:_fireItemRemoved(itemFrame: GuiObject)
	if not self._itemRemoved then return end
	local boundIndex = self._poolBoundIndex[itemFrame]
	if not boundIndex then return end
	self._itemRemoved(itemFrame, self._poolBoundItem[itemFrame], boundIndex)
end

-- Hides all pooled Instances and fires ItemRemoved for any that were bound.
-- Used when the filtered dataset drops to zero items.
function VirtualScrollList:_hideAllItems()
	for _, itemFrame in ipairs(self._pool) do
		if self._poolBoundIndex[itemFrame] then
			self:_fireItemRemoved(itemFrame)
		end
		itemFrame.Visible = false
		self._poolBoundIndex[itemFrame] = nil
		self._poolBoundItem[itemFrame]  = nil
	end
end

------------------------------------------------------------------------
-- Internal: UIPadding
------------------------------------------------------------------------

-- Usable width for column math: frame width minus left+right padding.
function VirtualScrollList:_usableWidth(): number
	return math.max(self._scrollingFrame.AbsoluteSize.X - self._paddingLeft - self._paddingRight, 0)
end

-- Usable height for viewport math: window height minus top+bottom padding.
function VirtualScrollList:_usableHeight(): number
	return math.max(self._scrollingFrame.AbsoluteWindowSize.Y - self._paddingTop - self._paddingBottom, 0)
end

-- Starts or stops tracking a UIPadding Instance. Disconnects any existing
-- padding-change connections first. Resets padding to zero when nil.
-- Does NOT trigger a re-layout — callers should call _handlePaddingChanged.
function VirtualScrollList:_attachUIPadding(uiPadding: UIPadding?)
	for _, c in ipairs(self._paddingConnections) do c:Disconnect() end
	self._paddingConnections = {}
	self._uiPadding = uiPadding

	if not uiPadding then
		self._paddingLeft   = 0
		self._paddingRight  = 0
		self._paddingTop    = 0
		self._paddingBottom = 0
		return
	end

	self:_resolvePaddingPixels()

	for _, prop in ipairs({ "PaddingLeft", "PaddingRight", "PaddingTop", "PaddingBottom" }) do
		table.insert(self._paddingConnections,
			uiPadding:GetPropertyChangedSignal(prop):Connect(function()
				self:_handlePaddingChanged()
			end))
	end
end

-- Converts the tracked UIPadding's UDim values to pixels.
-- Scale components are resolved against the frame's current AbsoluteSize.
function VirtualScrollList:_resolvePaddingPixels()
	local p = self._uiPadding
	if not p then return end
	local fs = self._scrollingFrame.AbsoluteSize
	self._paddingLeft   = p.PaddingLeft.Offset   + p.PaddingLeft.Scale   * fs.X
	self._paddingRight  = p.PaddingRight.Offset  + p.PaddingRight.Scale  * fs.X
	self._paddingTop    = p.PaddingTop.Offset    + p.PaddingTop.Scale    * fs.Y
	self._paddingBottom = p.PaddingBottom.Offset + p.PaddingBottom.Scale * fs.Y
end

-- Handles a UIPadding property change or attach/detach. Routes through
-- _applyLayoutChange (not _handleResize) because padding shifts canvas
-- height and item positions independently of column count changes.
function VirtualScrollList:_handlePaddingChanged()
	self:_resolvePaddingPixels()
	self:_applyLayoutChange()
end

return VirtualScrollList
