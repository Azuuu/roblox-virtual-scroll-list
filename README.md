# VirtualScrollList

A lightweight, framework-free virtual scrolling grid for Roblox. Supports large datasets (10,000+ items) without creating one `Instance` per item. It pools a small set of cloned `GuiObject`s — just enough to cover the visible viewport plus a buffer — and recycles them as the user scrolls.

---

## Features

- **Performance** — renders only the visible rows; works smoothly with 10,000+ items.
- **Grid support** — configurable column count, spacing, and aspect ratio.
- **AutoScale** — column count adjusts automatically to the frame width.
- **Filtering** — register multiple named predicates; all are AND-combined.
- **Search** — built-in debounce-friendly search with a customizable match function.
- **Sorting** — register multiple named comparators applied in priority order.
- **UIPadding** — auto-detected; padded items land in the right place automatically.
- **No dependencies** — pure Luau, no external packages.

---

## Installation

1. Place `VirtualScrollList.luau` in `ReplicatedStorage` (or any location reachable by `require`).
2. Require it from a `LocalScript`:

```lua
local VirtualScrollList = require(game:GetService("ReplicatedStorage").VirtualScrollList)
```

---

## Quick Start

```lua
local VirtualScrollList = require(ReplicatedStorage.VirtualScrollList)

local list = VirtualScrollList.new(scrollingFrame, {
    ItemHeight   = 84,
    Columns      = 3,
    SpacingX     = 8,
    SpacingY     = 8,
    ItemTemplate = myFrameTemplate,

    SetupItem = function(frame, poolSlot)
        -- Called once per cloned pool slot. Wire persistent events here.
        frame.MouseEnter:Connect(function() frame.BackgroundTransparency = 0.8 end)
        frame.MouseLeave:Connect(function() frame.BackgroundTransparency = 0.92 end)
    end,

    UpdateItem = function(frame, item, index)
        -- Called every time a slot is rebound to new data.
        frame.NameLabel.Text = item.Name
    end,

    ItemRemoved = function(frame, item, index)
        -- Optional. Called when a slot's binding is cleared (scrolled away,
        -- filtered out, or list destroyed). Good for stopping tweens/sounds.
    end,
})

list:SetData(myDataArray)
```

---

## Config Reference

| Field | Type | Required | Description |
|---|---|---|---|
| `ItemHeight` | `number` | ✅ | Fixed height (px) of every item. |
| `ItemTemplate` | `GuiObject` | ✅ | Cloned to build the internal pool. |
| `SetupItem` | `function` | ✅ | Called once per cloned pool Instance. |
| `UpdateItem` | `function` | ✅ | Called each time a pool slot is bound to data. |
| `ItemRemoved` | `function?` | — | Called when a bound slot loses its data. |
| `Buffer` | `number?` | — | Extra rows rendered above/below the viewport. Default `3`. |
| `Columns` | `number?` | — | Grid column count. Default `1`. Ignored when `AutoScale` is on. |
| `ItemWidth` | `number?` | — | Fixed item width. Auto-calculated if omitted. Required for `AutoScale`. |
| `AspectRatio` | `number?` | — | `width / height` ratio; overrides `ItemWidth`. Ignored when `AutoScale` is on. |
| `AutoScale` | `boolean?` | — | Column count becomes responsive; items stay at `ItemWidth`. Requires `ItemWidth`. |
| `SpacingX` | `number?` | — | Gap (px) between columns. Default `0`. |
| `SpacingY` | `number?` | — | Gap (px) between rows. Default `0`. |

---

## API Reference

### Data

#### `list:SetData(data: { any })`
Replaces the full source dataset, re-applies filters and sort, and resets scroll to the top.

#### `list:GetData(): { any }`
Returns the current filtered + sorted view (what is actually being scrolled).

#### `list:GetSourceData(): { any }`
Returns the raw unfiltered array last passed to `SetData`.

#### `list:GetVisibleCount(): number`
Number of items currently passing all filters.

#### `list:ChangeItem(sourceIndex: number, item: any)`
Updates a single item in the source array by its source index, then re-applies filters and sort.

#### `list:ChangeItemByPredicate(findFn, newItem): boolean`
Updates the first item for which `findFn(item)` returns `true`. Returns `true` if a match was found.

---

### Layout

#### `list:SetColumns(columns: number, options?)`
Changes the column count and re-renders. Optional `options` table accepts `ItemWidth`, `AspectRatio`, `SpacingX`, `SpacingY`.

#### `list:SetAutoScale(enabled: boolean)`
Toggles responsive column count. Requires `ItemWidth` to already be set.

#### `list:SetItemSize(width: number?, height: number?)`
Mutates item width and/or height and re-renders. Setting width clears `AspectRatio`.

#### `list:GetColumns(): number`
Returns the current (possibly auto-derived) column count.

#### `list:GetItemWidth(): number`
Returns the resolved item width actually used for rendering.

#### `list:GetItemHeight(): number`
Returns the current item height.

#### `list:ScrollToIndex(index: number)`
Scrolls so the item at `index` (in the filtered+sorted view) is visible at the top of the viewport.

---

### Filtering

#### `list:SetFilter(name: string, predicateFn: (item, index) -> boolean)`
Registers (or replaces) a named filter. All filters are AND-combined and applied immediately.

#### `list:RemoveFilter(name: string)`
Removes a registered filter by name. No-op if it doesn't exist.

#### `list:ClearFilters()`
Removes all registered filters and the search query.

#### `list:RefreshFilters()`
Re-runs all filters and sorts without changing registrations. Use when a filter's external state changed.

---

### Search

#### `list:SetSearch(query: string?, matchFn?)`
Sets or clears the search query (pass `""` or `nil` to clear). Internally registered as a filter so it composes naturally with `SetFilter`. An optional `matchFn(item, query) -> boolean` overrides the default case-insensitive `item.Name` match.

```lua
-- Default behavior: case-insensitive substring match on item.Name
list:SetSearch("tuna")

-- Custom match function
list:SetSearch("tuna", function(item, query)
    return string.find(string.lower(item.Description), query, 1, true) ~= nil
end)

-- Clear search
list:SetSearch(nil)
```

---

### Sorting

#### `list:SetSort(name: string, compareFn: (a, b) -> boolean)`
Registers (or replaces) a named sort. `compareFn` follows `table.sort` convention: return `true` if `a` should appear before `b`. Multiple sorts are applied in registration order — earlier sorts win; later ones break ties.

#### `list:RemoveSort(name: string)`
Removes a registered sort by name.

#### `list:ClearSorts()`
Removes all registered sorts and re-renders in source order.

#### `list:RefreshSort()`
Re-runs all sorts (and filters) without changing registrations.

---

### Cleanup

#### `list:Destroy()`
Disconnects all connections, fires `ItemRemoved` for every bound slot, and destroys all cloned Instances. Safe to call multiple times.

---

## UIPadding

If a `UIPadding` Instance is parented to the `ScrollingFrame` — either before or after `VirtualScrollList.new` — it is automatically detected and tracked. Left/right padding shrinks the usable width for column math; top/bottom padding shifts item positions so they land inside the padded area.

```
ScrollingFrame
  └─ UIPadding   ← auto-detected, live-tracked
```

---

## Recipes

### Debounced search box

```lua
local debounceToken = 0
searchBox:GetPropertyChangedSignal("Text"):Connect(function()
    debounceToken += 1
    local token = debounceToken
    task.delay(0.15, function()
        if token == debounceToken then
            list:SetSearch(searchBox.Text)
        end
    end)
end)
```

### Multiple filters (AND-combined)

```lua
-- Show only Rare+ fish
list:SetFilter("rarity", function(item)
    return item.Rarity == "Rare" or item.Rarity == "Epic" or item.Rarity == "Legendary"
end)

-- Also hide sold fish
list:SetFilter("hideSold", function(item)
    return item.Sold ~= true
end)

-- Remove one filter later
list:RemoveFilter("hideSold")
```

### Multi-key sort (rarity, then weight as tiebreaker)

```lua
local RARITY_RANK = { Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5 }

list:SetSort("rarity", function(a, b)
    return (RARITY_RANK[a.Rarity] or 0) > (RARITY_RANK[b.Rarity] or 0)
end)
list:SetSort("weight", function(a, b)
    return a.Weight > b.Weight
end)
```

### Responsive grid (AutoScale)

```lua
-- Cards stay 160px wide; columns auto-fit the frame
list:SetColumns(1, { ItemWidth = 160, SpacingX = 8, SpacingY = 8 })
list:SetAutoScale(true)
```

### Stop tween on scroll-away (ItemRemoved)

```lua
local activeShimmers = {}

UpdateItem = function(frame, item, index)
    if item.Rarity == "Legendary" then
        local tween = TweenService:Create(frame, TweenInfo.new(0.8, Enum.EasingStyle.Sine,
            Enum.EasingDirection.InOut, -1, true), { BackgroundTransparency = 0.7 })
        tween:Play()
        activeShimmers[frame] = tween
    end
end,

ItemRemoved = function(frame, item, index)
    local tween = activeShimmers[frame]
    if tween then tween:Cancel(); activeShimmers[frame] = nil end
end,
```

---

## Example

See [`FishInventoryExample.client.luau`](FishInventoryExample.client.luau) for a complete working example: a 10,000-item fish inventory with a 3-column card grid, live search, rarity filters, multi-key sorting, and shimmer tweens cleaned up via `ItemRemoved`.

---

## License

MIT — free to use in any Roblox project, commercial or otherwise.
