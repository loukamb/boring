-- plugins/layout-tiling.lua
-- Sway-style N-ary tiling layout plugin
-- Windows organized in N-ary tree with dynamic width/height fractions

-- layouts/tiling.lua - Sway-style N-ary Tiling Layout
-- Windows are organized in an N-ary tree with dynamic width/height fractions

local log = require("shared.log")
local wl = require("shared.wayland.server")
local ffi = wl._ffi
local bit = wl.bit

local tiling = {}

--------------------------------------------------------------------------------
-- Container Data Structures (Sway N-ary tree)
--------------------------------------------------------------------------------

-- Create a leaf container holding a single window
local function create_leaf(surface)
    return {
        type = "leaf",
        surface = surface,
        parent = nil,
        -- Fractions (0 = new, needs assignment during arrange)
        width_fraction = 0,
        height_fraction = 0,
        -- Cached geometry (computed during layout)
        x = 0,
        y = 0,
        width = 0,
        height = 0,
    }
end

-- Create a split container with N children
local function create_split(layout, children)
    local split = {
        type = "split",
        layout = layout, -- "horizontal" or "vertical"
        children = children or {},
        parent = nil,
        -- Fractions for this container within its parent
        width_fraction = 0,
        height_fraction = 0,
        -- Cached geometry
        x = 0,
        y = 0,
        width = 0,
        height = 0,
    }
    -- Set parent references
    for _, child in ipairs(split.children) do
        child.parent = split
    end
    return split
end

--------------------------------------------------------------------------------
-- Tree Traversal and Search
--------------------------------------------------------------------------------

-- Find the leaf container holding a specific surface
local function find_container(container, surface)
    if not container then return nil end

    if container.type == "leaf" then
        if container.surface == surface then
            return container
        end
        return nil
    end

    -- Search children
    for _, child in ipairs(container.children) do
        local found = find_container(child, surface)
        if found then return found end
    end

    return nil
end

-- Find container in a list of top-level children
local function find_in_children(children, surface)
    for _, child in ipairs(children) do
        local found = find_container(child, surface)
        if found then return found end
    end
    return nil
end

-- Count all leaf containers (windows) in the tree
local function count_leaves(container)
    if not container then return 0 end

    if container.type == "leaf" then
        return 1
    end

    local count = 0
    for _, child in ipairs(container.children) do
        count = count + count_leaves(child)
    end
    return count
end

-- Count leaves in a list of children
local function count_leaves_in_list(children)
    local count = 0
    for _, child in ipairs(children) do
        count = count + count_leaves(child)
    end
    return count
end

-- Get all leaf containers as a flat list
local function get_all_leaves(container, result)
    result = result or {}
    if not container then return result end

    if container.type == "leaf" then
        table.insert(result, container)
        return result
    end

    for _, child in ipairs(container.children) do
        get_all_leaves(child, result)
    end
    return result
end

-- Find index of item in array
local function find_index(arr, item)
    for i, v in ipairs(arr) do
        if v == item then return i end
    end
    return nil
end

--------------------------------------------------------------------------------
-- Resize Helper Functions (from Sway's resize.c)
--------------------------------------------------------------------------------

-- WLR_EDGE constants for resize direction
local WLR_EDGE_NONE = 0
local WLR_EDGE_TOP = 1
local WLR_EDGE_BOTTOM = 2
local WLR_EDGE_LEFT = 4
local WLR_EDGE_RIGHT = 8

-- Check if edge is horizontal (left/right)
local function is_horizontal_edge(edge)
    return bit.band(edge, bit.bor(WLR_EDGE_LEFT, WLR_EDGE_RIGHT)) ~= 0
end

-- Resize a tiled container by a pixel amount
-- SIMPLIFIED: Directly modify widths as integers, then derive fractions
-- This avoids float/int precision issues from complex fraction math
-- @param con: The container to resize
-- @param axis: The edge/axis (WLR_EDGE_LEFT, WLR_EDGE_RIGHT, etc.)
-- @param amount: Pixel amount (integer) to resize by
-- @param siblings: List of all siblings at this level
local function container_resize_tiled(con, axis, amount, siblings, monitor_state)
    if not con or not siblings or #siblings < 2 then
        return
    end

    -- Amount is already an integer from update_resize
    if amount == 0 then return end

    local is_horiz = bit.band(axis, bit.bor(WLR_EDGE_LEFT, WLR_EDGE_RIGHT)) ~= 0
    local index = find_index(siblings, con)
    if not index then return end

    -- Find the sibling involved in this resize
    local sibling, sib_index
    if axis == WLR_EDGE_TOP or axis == WLR_EDGE_LEFT then
        if index > 1 then
            sibling = siblings[index - 1]
            sib_index = index - 1
        end
    else
        if index < #siblings then
            sibling = siblings[index + 1]
            sib_index = index + 1
        end
    end

    if not sibling then return end

    if is_horiz then
        -- Calculate child_total from current widths (more reliable than stored value)
        local child_total = 0
        for _, child in ipairs(siblings) do
            child_total = child_total + child.width
        end
        if child_total <= 0 then return end

        -- Check minimum sizes (use integers)
        local con_new_width = con.width + amount
        local sib_new_width = sibling.width - amount
        if con_new_width < 50 or sib_new_width < 50 then
            return
        end

        -- FIRST: Snap ALL siblings' fractions to current widths
        -- This ensures consistent state before applying delta
        for _, child in ipairs(siblings) do
            child.width_fraction = child.width / child_total
        end

        -- THEN: Apply the resize to just con and sibling
        con.width_fraction = con_new_width / child_total
        sibling.width_fraction = sib_new_width / child_total
    else
        -- Calculate child_total from current heights
        local child_total = 0
        for _, child in ipairs(siblings) do
            child_total = child_total + child.height
        end
        if child_total <= 0 then return end

        -- Check minimum sizes
        local con_new_height = con.height + amount
        local sib_new_height = sibling.height - amount
        if con_new_height < 50 or sib_new_height < 50 then
            return
        end

        -- Snap ALL siblings' fractions first
        for _, child in ipairs(siblings) do
            child.height_fraction = child.height / child_total
        end

        -- Then apply the resize
        con.height_fraction = con_new_height / child_total
        sibling.height_fraction = sib_new_height / child_total
    end
end

-- Find the container that can be resized in the given direction
-- (Sway's container_find_resize_parent from resize.c)
local function find_resize_parent(container, edge, tiling_state)
    local is_horiz = is_horizontal_edge(edge)
    local parallel_layout = is_horiz and "horizontal" or "vertical"

    -- Determine if we're allowed to be first/last child based on edge direction
    -- LEFT/TOP edge means we need a sibling to the left/top (so we can't be first)
    -- RIGHT/BOTTOM edge means we need a sibling to the right/bottom (so we can't be last)
    local allow_first = bit.band(edge, bit.bor(WLR_EDGE_TOP, WLR_EDGE_LEFT)) == 0
    local allow_last = bit.band(edge, bit.bor(WLR_EDGE_RIGHT, WLR_EDGE_BOTTOM)) == 0

    local current = container
    while current do
        local parent = current.parent
        local children_list = parent and parent.children or tiling_state.children
        local layout = parent and parent.layout or tiling_state.layout

        -- Check if this container's parent has the right layout and position
        if layout == parallel_layout and #children_list > 1 then
            local idx = find_index(children_list, current)
            if idx then
                local is_first = (idx == 1)
                local is_last = (idx == #children_list)

                -- Can resize if:
                -- - We're not first, OR first is allowed (resizing right/bottom edge)
                -- - We're not last, OR last is allowed (resizing left/top edge)
                if (allow_first or not is_first) and (allow_last or not is_last) then
                    return current, children_list, idx
                end
            end
        end

        current = parent
    end

    return nil, nil, nil
end

--------------------------------------------------------------------------------
-- Sway's Arrange Algorithm (from arrange.c)
--------------------------------------------------------------------------------

-- Forward declaration
local arrange_container

-- Apply horizontal layout to children (Sway's apply_horiz_layout)
local function apply_horiz_layout(children, parent_box, inner_gap)
    if #children == 0 then return end

    -- Count new children and current width fraction sum
    local new_children = 0
    local current_width_fraction = 0
    for _, child in ipairs(children) do
        current_width_fraction = current_width_fraction + child.width_fraction
        if child.width_fraction <= 0 then
            new_children = new_children + 1
        end
    end

    -- Assign fractions to new children
    for _, child in ipairs(children) do
        if child.width_fraction <= 0 then
            if current_width_fraction <= 0 then
                child.width_fraction = 1.0
            elseif #children > new_children then
                child.width_fraction = current_width_fraction / (#children - new_children)
            else
                child.width_fraction = current_width_fraction
            end
        end
    end

    -- Calculate total fraction (but DON'T mutate fractions like we were doing!)
    -- Sway uses fractions proportionally: width = fraction / total * available
    local total_width_fraction = 0
    for _, child in ipairs(children) do
        total_width_fraction = total_width_fraction + child.width_fraction
    end
    if total_width_fraction <= 0 then
        total_width_fraction = 1.0
    end

    -- Calculate total gap
    local total_gap = inner_gap * math.max(0, #children - 1)
    local child_total_width = parent_box.width - total_gap

    -- Position children using proportional fractions (like Sway)
    local child_x = parent_box.x
    for i, child in ipairs(children) do
        -- Store child_total_width for resize calculations (like Sway does)
        child.child_total_width = child_total_width

        child.x = math.floor(child_x)
        child.y = parent_box.y
        -- Use proportional calculation: fraction / total * available
        child.width = math.floor(child.width_fraction / total_width_fraction * child_total_width)
        child.height = parent_box.height

        -- Last child gets remaining width (avoids rounding errors)
        if i == #children then
            child.width = parent_box.x + parent_box.width - child.x
        end

        child_x = child_x + child.width + inner_gap

        -- Recurse into child containers
        arrange_container(child, inner_gap)
    end
end

-- Apply vertical layout to children (Sway's apply_vert_layout)
local function apply_vert_layout(children, parent_box, inner_gap)
    if #children == 0 then return end

    -- Count new children and current height fraction sum
    local new_children = 0
    local current_height_fraction = 0
    for _, child in ipairs(children) do
        current_height_fraction = current_height_fraction + child.height_fraction
        if child.height_fraction <= 0 then
            new_children = new_children + 1
        end
    end

    -- Assign fractions to new children
    for _, child in ipairs(children) do
        if child.height_fraction <= 0 then
            if current_height_fraction <= 0 then
                child.height_fraction = 1.0
            elseif #children > new_children then
                child.height_fraction = current_height_fraction / (#children - new_children)
            else
                child.height_fraction = current_height_fraction
            end
        end
    end

    -- Calculate total fraction (but DON'T mutate fractions!)
    -- Sway uses fractions proportionally: height = fraction / total * available
    local total_height_fraction = 0
    for _, child in ipairs(children) do
        total_height_fraction = total_height_fraction + child.height_fraction
    end
    if total_height_fraction <= 0 then
        total_height_fraction = 1.0
    end

    -- Calculate total gap
    local total_gap = inner_gap * math.max(0, #children - 1)
    local child_total_height = parent_box.height - total_gap

    -- Position children using proportional fractions (like Sway)
    local child_y = parent_box.y
    for i, child in ipairs(children) do
        -- Store child_total_height for resize calculations (like Sway does)
        child.child_total_height = child_total_height

        child.x = parent_box.x
        child.y = math.floor(child_y)
        child.width = parent_box.width
        -- Use proportional calculation: fraction / total * available
        child.height = math.floor(child.height_fraction / total_height_fraction * child_total_height)

        -- Last child gets remaining height (avoids rounding errors)
        if i == #children then
            child.height = parent_box.y + parent_box.height - child.y
        end

        child_y = child_y + child.height + inner_gap

        -- Recurse into child containers
        arrange_container(child, inner_gap)
    end
end

-- Arrange a single container (recursive)
arrange_container = function(container, inner_gap)
    if not container then return end

    if container.type == "leaf" then
        -- Position the actual window
        local surface = container.surface
        if surface and surface.scene_tree then
            local node_x = container.x
            local node_y = container.y

            -- Account for XDG geometry offset
            if surface.role_obj then
                local geo = surface.role_obj.base.geometry
                node_x = container.x - geo.x
                node_y = container.y - geo.y
            end

            wl.roots.scene_node_set_position(surface.scene_tree.node, node_x, node_y)

            -- Request client to resize
            if surface.set_size then
                surface:set_size(container.width, container.height)
            end

            -- Clip surface to prevent overflow before client redraws
            -- This ensures the window doesn't visually overflow its bounds
            -- while waiting for the client to acknowledge the resize
            local clip_box = ffi.new("struct wlr_box", {
                0, 0, container.width, container.height
            })
            pcall(function()
                wl.roots.scene_subsurface_tree_set_clip(surface.scene_tree.node, clip_box)
            end)
        end
        return
    end

    -- Split container - arrange children
    local box = {
        x = container.x,
        y = container.y,
        width = container.width,
        height = container.height,
    }

    if container.layout == "horizontal" then
        apply_horiz_layout(container.children, box, inner_gap)
    else
        apply_vert_layout(container.children, box, inner_gap)
    end
end

-- Get logical output dimensions (accounting for scale/transform)
local function get_output_dimensions(output)
    local output_service = require("compositor.services.output")
    local box = ffi.new("struct wlr_box")
    wl.roots.output_layout_get_box(output_service:get_output_layout(), output.wlr_output, box)

    -- Get raw dimensions and scale for fallback
    local raw_w = output.wlr_output.width
    local raw_h = output.wlr_output.height
    local scale = output.wlr_output.scale
    if scale <= 0 then scale = 1 end

    -- If box dimensions are invalid, calculate from raw dimensions / scale
    if box.width <= 0 or box.height <= 0 then
        log.warn("Invalid output box, falling back to raw/scale: %dx%d / %f",
            raw_w, raw_h, scale)
        return math.floor(raw_w / scale), math.floor(raw_h / scale)
    end

    return box.width, box.height
end

-- Arrange the entire workspace
local function arrange_workspace(monitor_state)
    local ts = monitor_state.tiling
    if not ts then return end

    local output = monitor_state.output
    if not output or not output.wlr_output then return end

    local output_width, output_height = get_output_dimensions(output)

    -- Get gap configuration
    local gaps = monitor_state.config.gaps or { inner = 4, outer = 4, smart = true }
    local inner_gap = gaps.inner or 4
    local outer_gap = gaps.outer or 4

    -- Smart gaps: no gaps if single window
    local window_count = count_leaves_in_list(ts.children)
    if gaps.smart and window_count == 1 then
        outer_gap = 0
        inner_gap = 0
    end

    -- Calculate usable area (workspace box with outer gaps applied)
    local workspace_box = {
        x = outer_gap,
        y = outer_gap,
        width = output_width - (outer_gap * 2),
        height = output_height - (outer_gap * 2),
    }

    -- Apply layout to top-level children
    if ts.layout == "horizontal" then
        apply_horiz_layout(ts.children, workspace_box, inner_gap)
    else
        apply_vert_layout(ts.children, workspace_box, inner_gap)
    end
end

--------------------------------------------------------------------------------
-- Window Insertion (Sway sibling-based insertion)
--------------------------------------------------------------------------------

-- Add a new surface as a sibling of the focused container
local function add_window(tiling_state, surface, focused_surface)
    local new_container = create_leaf(surface)
    -- width_fraction and height_fraction are 0, will be assigned during arrange

    if #tiling_state.children == 0 then
        -- First window: add directly to workspace
        table.insert(tiling_state.children, new_container)
        return new_container
    end

    -- Find the focused container
    local focused_container = nil
    if focused_surface then
        focused_container = find_in_children(tiling_state.children, focused_surface)
    end

    if not focused_container then
        -- No focus or not found, add to end of workspace
        table.insert(tiling_state.children, new_container)
        return new_container
    end

    -- Add as sibling to the focused container
    local parent = focused_container.parent
    if parent then
        -- Focused is inside a split container - add to that split
        local idx = find_index(parent.children, focused_container)
        if idx then
            table.insert(parent.children, idx + 1, new_container)
            new_container.parent = parent
        else
            table.insert(parent.children, new_container)
            new_container.parent = parent
        end
    else
        -- Focused is a top-level container - add to workspace children
        local idx = find_index(tiling_state.children, focused_container)
        if idx then
            table.insert(tiling_state.children, idx + 1, new_container)
        else
            table.insert(tiling_state.children, new_container)
        end
    end

    return new_container
end

--------------------------------------------------------------------------------
-- Window Removal
--------------------------------------------------------------------------------

-- Remove a surface from the tree, cleaning up empty containers
local function remove_window(tiling_state, surface)
    -- Find the container
    local container = find_in_children(tiling_state.children, surface)
    if not container then return end

    local parent = container.parent

    if not parent then
        -- Top-level container - remove from workspace children
        for i, child in ipairs(tiling_state.children) do
            if child == container then
                table.remove(tiling_state.children, i)
                break
            end
        end
        return
    end

    -- Remove from parent's children
    for i, child in ipairs(parent.children) do
        if child == container then
            table.remove(parent.children, i)
            break
        end
    end

    -- If parent now has only one child, collapse it
    if #parent.children == 1 then
        local remaining = parent.children[1]
        remaining.width_fraction = parent.width_fraction
        remaining.height_fraction = parent.height_fraction

        local grandparent = parent.parent
        if grandparent then
            -- Replace parent with remaining child in grandparent
            for i, child in ipairs(grandparent.children) do
                if child == parent then
                    grandparent.children[i] = remaining
                    remaining.parent = grandparent
                    break
                end
            end
        else
            -- Parent was top-level, replace in workspace children
            for i, child in ipairs(tiling_state.children) do
                if child == parent then
                    tiling_state.children[i] = remaining
                    remaining.parent = nil
                    break
                end
            end
        end
    elseif #parent.children == 0 then
        -- Parent is now empty, remove it recursively
        -- (This handles nested empty containers)
        local dummy_surface = { _dummy = true }
        parent.surface = dummy_surface
        parent.type = "leaf"
        remove_window(tiling_state, dummy_surface)
    end
end

--------------------------------------------------------------------------------
-- Tiling Layout Interface
--------------------------------------------------------------------------------

function tiling:init(monitor_state)
    monitor_state.tiling = {
        -- Workspace-level layout (like Sway's workspace.layout)
        layout = "horizontal", -- "horizontal" or "vertical"
        -- Top-level tiled containers (like Sway's workspace.tiling)
        children = {},

        -- Interactive state
        grabbed_surface = nil,
        grab_start_x = 0,
        grab_start_y = 0,
        mode = "none", -- "none", "move", "resize"

        -- Resize state (exactly matching Sway's seatop_resize_tiling_event)
        edge = 0,              -- Full edge flags
        edge_x = 0,            -- Horizontal component (LEFT|RIGHT)
        edge_y = 0,            -- Vertical component (TOP|BOTTOM)
        ref_lx = 0,            -- Cursor X at START (never updated!)
        ref_ly = 0,            -- Cursor Y at START (never updated!)
        -- Horizontal resize state
        h_con = nil,           -- Container being resized horizontally
        h_sib = nil,           -- Sibling for horizontal resize
        h_con_orig_width = 0,  -- Original width at start
        h_siblings = nil,      -- All siblings for snapping
        -- Vertical resize state
        v_con = nil,           -- Container being resized vertically
        v_sib = nil,           -- Sibling for vertical resize
        v_con_orig_height = 0, -- Original height at start
        v_siblings = nil,      -- All siblings for snapping
    }
end

function tiling:shutdown(monitor_state)
    monitor_state.tiling = nil
end

--------------------------------------------------------------------------------
-- Window Lifecycle
--------------------------------------------------------------------------------

function tiling:on_window_add(monitor_state, surface)
    local ts = monitor_state.tiling

    -- Get currently focused surface
    local surface_service = require("compositor.services.surface")
    local focused = surface_service:get_focused_window()

    -- Add as sibling
    add_window(ts, surface, focused)

    -- Arrange the workspace
    arrange_workspace(monitor_state)
end

function tiling:on_window_remove(monitor_state, surface)
    local ts = monitor_state.tiling

    -- Clear grab if this surface was grabbed
    if ts.grabbed_surface == surface then
        ts.grabbed_surface = nil
        ts.mode = "none"
    end

    -- Remove from tree
    remove_window(ts, surface)

    -- Arrange the workspace
    arrange_workspace(monitor_state)
end

function tiling:on_window_resize(monitor_state, surface, width, height)
    -- In tiling, we control window sizes, so just re-arrange
    arrange_workspace(monitor_state)
end

function tiling:position_window(monitor_state, surface)
    -- Re-apply position for a single window (called after commits)
    local ts = monitor_state.tiling
    if not ts then return end

    local container = find_in_children(ts.children, surface)
    if not container then return end

    -- Re-apply position using container's cached geometry
    if surface.scene_tree then
        local node_x = container.x
        local node_y = container.y

        if surface.role_obj then
            local geo = surface.role_obj.base.geometry
            node_x = container.x - geo.x
            node_y = container.y - geo.y
        end

        wl.roots.scene_node_set_position(surface.scene_tree.node, node_x, node_y)
    end
end

--------------------------------------------------------------------------------
-- Hit Testing
--------------------------------------------------------------------------------

function tiling:get_window_at(monitor_state, x, y)
    local surface_service = require("compositor.services.surface")
    local surface, _, _, _ = surface_service:surface_at(x, y)
    return surface
end

--------------------------------------------------------------------------------
-- Interactive Move (Swap Windows)
--------------------------------------------------------------------------------

-- Find the leaf container at a given position
local function find_leaf_at(children, x, y)
    for _, child in ipairs(children) do
        if x >= child.x and x < child.x + child.width and
            y >= child.y and y < child.y + child.height then
            if child.type == "leaf" then
                return child
            else
                return find_leaf_at(child.children, x, y)
            end
        end
    end
    return nil
end

function tiling:begin_move(monitor_state, surface, cursor_x, cursor_y)
    if not surface then return false end

    local ts = monitor_state.tiling
    ts.grabbed_surface = surface
    ts.mode = "move"
    ts.grab_start_x = cursor_x
    ts.grab_start_y = cursor_y

    return true
end

function tiling:update_move(monitor_state, cursor_x, cursor_y)
    -- In tiling mode, we don't move during drag - just wait for end_move
end

function tiling:end_move(monitor_state)
    local ts = monitor_state.tiling
    if ts.mode ~= "move" then return end

    local grabbed_surface = ts.grabbed_surface
    local input_service = require("compositor.services.input")
    local cursor = input_service:get_cursor()

    -- Find containers
    local grabbed_container = find_in_children(ts.children, grabbed_surface)
    local target_container = find_leaf_at(ts.children, cursor.x, cursor.y)

    if grabbed_container and target_container and grabbed_container ~= target_container then
        -- Swap surfaces between containers
        grabbed_container.surface, target_container.surface = target_container.surface, grabbed_container.surface
        arrange_workspace(monitor_state)
    end

    ts.grabbed_surface = nil
    ts.mode = "none"
end

--------------------------------------------------------------------------------
-- Interactive Resize (Sway-style from resize.c and seatop_resize_tiling.c)
--------------------------------------------------------------------------------

-- Get the resize sibling for a container in a given direction
-- (Sway's container_get_resize_sibling from seatop_resize_tiling.c)
local function get_resize_sibling(con, edge, siblings)
    if not con or not siblings then return nil end

    local index = find_index(siblings, con)
    if not index then return nil end

    -- LEFT/TOP edge: sibling is to the left/top (index - 1)
    -- RIGHT/BOTTOM edge: sibling is to the right/bottom (index + 1)
    local offset = bit.band(edge, bit.bor(WLR_EDGE_TOP, WLR_EDGE_LEFT)) ~= 0 and -1 or 1

    if #siblings == 1 then
        return nil
    end

    local sibling_idx = index + offset
    if sibling_idx < 1 or sibling_idx > #siblings then
        return nil
    end

    return siblings[sibling_idx]
end

function tiling:begin_resize(monitor_state, surface, cursor_x, cursor_y, edges)
    if not surface then return false end

    local ts = monitor_state.tiling
    local container = find_in_children(ts.children, surface)
    if not container then return false end

    -- If no specific edge, calculate based on cursor position relative to container center
    if edges == 0 or edges == WLR_EDGE_NONE then
        local cx = container.x + container.width / 2
        local cy = container.y + container.height / 2

        if cursor_x > cx then
            edges = bit.bor(edges, WLR_EDGE_RIGHT)
        else
            edges = bit.bor(edges, WLR_EDGE_LEFT)
        end
        if cursor_y > cy then
            edges = bit.bor(edges, WLR_EDGE_BOTTOM)
        else
            edges = bit.bor(edges, WLR_EDGE_TOP)
        end
    end

    -- Store edge and reference position (NEVER updated during resize!)
    ts.edge = edges
    ts.ref_lx = cursor_x
    ts.ref_ly = cursor_y
    ts.mode = "resize"
    ts.grabbed_surface = surface

    -- Clear previous state
    ts.h_con = nil
    ts.h_sib = nil
    ts.h_con_orig_width = 0
    ts.h_siblings = nil
    ts.v_con = nil
    ts.v_sib = nil
    ts.v_con_orig_height = 0
    ts.v_siblings = nil

    local found_resize = false

    -- Handle horizontal resize (LEFT/RIGHT edges)
    -- (From Sway's seatop_begin_resize_tiling lines 134-144)
    if bit.band(edges, bit.bor(WLR_EDGE_LEFT, WLR_EDGE_RIGHT)) ~= 0 then
        ts.edge_x = bit.band(edges, bit.bor(WLR_EDGE_LEFT, WLR_EDGE_RIGHT))
        local h_con, h_siblings, h_idx = find_resize_parent(container, ts.edge_x, ts)

        if h_con then
            local h_sib = get_resize_sibling(h_con, ts.edge_x, h_siblings)
            if h_sib then
                ts.h_con = h_con
                ts.h_sib = h_sib
                ts.h_con_orig_width = h_con.width
                ts.h_siblings = h_siblings
                found_resize = true
            end
        end
    end

    -- Handle vertical resize (TOP/BOTTOM edges)
    -- (From Sway's seatop_begin_resize_tiling lines 145-155)
    if bit.band(edges, bit.bor(WLR_EDGE_TOP, WLR_EDGE_BOTTOM)) ~= 0 then
        ts.edge_y = bit.band(edges, bit.bor(WLR_EDGE_TOP, WLR_EDGE_BOTTOM))
        local v_con, v_siblings, _ = find_resize_parent(container, ts.edge_y, ts)

        if v_con then
            local v_sib = get_resize_sibling(v_con, ts.edge_y, v_siblings)
            if v_sib then
                ts.v_con = v_con
                ts.v_sib = v_sib
                ts.v_con_orig_height = v_con.height
                ts.v_siblings = v_siblings
                found_resize = true
            end
        end
    end

    if not found_resize then
        ts.mode = "none"
        ts.grabbed_surface = nil
        return false
    end

    return true
end

function tiling:update_resize(monitor_state, cursor_x, cursor_y)
    local ts = monitor_state.tiling
    if ts.mode ~= "resize" then
        return
    end

    -- Calculate delta from LAST APPLIED position
    -- Don't update ref until we actually apply a resize (to accumulate small movements)
    local delta_x = cursor_x - ts.ref_lx
    local delta_y = cursor_y - ts.ref_ly

    local did_resize = false

    -- Handle horizontal resize
    if ts.h_con and ts.h_siblings then
        local amount_x = 0
        if bit.band(ts.edge, WLR_EDGE_LEFT) ~= 0 then
            -- LEFT edge: moving right shrinks con, grows sibling
            amount_x = -delta_x
        elseif bit.band(ts.edge, WLR_EDGE_RIGHT) ~= 0 then
            -- RIGHT edge: moving right grows con, shrinks sibling
            amount_x = delta_x
        end

        -- Round to integer - only apply if >= 1 pixel
        local rounded_x = math.floor(amount_x + 0.5)
        if rounded_x ~= 0 then
            container_resize_tiled(ts.h_con, ts.edge_x, rounded_x, ts.h_siblings, monitor_state)
            -- Only update ref by the amount we actually used (in pixels)
            if bit.band(ts.edge, WLR_EDGE_LEFT) ~= 0 then
                ts.ref_lx = ts.ref_lx - rounded_x
            else
                ts.ref_lx = ts.ref_lx + rounded_x
            end
            did_resize = true
        end
    end

    -- Handle vertical resize
    if ts.v_con and ts.v_siblings then
        local amount_y = 0
        if bit.band(ts.edge, WLR_EDGE_TOP) ~= 0 then
            -- TOP edge: moving up grows con
            amount_y = -delta_y
        elseif bit.band(ts.edge, WLR_EDGE_BOTTOM) ~= 0 then
            -- BOTTOM edge: moving down grows con
            amount_y = delta_y
        end

        -- Round to integer - only apply if >= 1 pixel
        local rounded_y = math.floor(amount_y + 0.5)
        if rounded_y ~= 0 then
            container_resize_tiled(ts.v_con, ts.edge_y, rounded_y, ts.v_siblings, monitor_state)
            -- Only update ref by the amount we actually used
            if bit.band(ts.edge, WLR_EDGE_TOP) ~= 0 then
                ts.ref_ly = ts.ref_ly - rounded_y
            else
                ts.ref_ly = ts.ref_ly + rounded_y
            end
            did_resize = true
        end
    end

    -- Re-arrange workspace only if we resized
    if did_resize then
        arrange_workspace(monitor_state)
    end
end

function tiling:end_resize(monitor_state)
    local ts = monitor_state.tiling
    ts.grabbed_surface = nil
    ts.mode = "none"
    -- Clear horizontal resize state
    ts.h_con = nil
    ts.h_sib = nil
    ts.h_con_orig_width = 0
    ts.h_siblings = nil
    -- Clear vertical resize state
    ts.v_con = nil
    ts.v_sib = nil
    ts.v_con_orig_height = 0
    ts.v_siblings = nil
    -- Clear edge state
    ts.edge = 0
    ts.edge_x = 0
    ts.edge_y = 0
end

--------------------------------------------------------------------------------
-- Viewport Operations (No-op for tiling)
--------------------------------------------------------------------------------

function tiling:pan(monitor_state, dx, dy)
    -- Tiling layout doesn't support panning
end

function tiling:zoom(monitor_state, delta, center_x, center_y)
    -- Tiling layout doesn't support zooming
end

--------------------------------------------------------------------------------
-- Fullscreen
--------------------------------------------------------------------------------

function tiling:enter_fullscreen(monitor_state, surface)
    if not surface or not surface.scene_tree then
        return false
    end

    local ts = monitor_state.tiling
    local container = find_in_children(ts.children, surface)

    -- Store pre-fullscreen state
    surface._pre_fullscreen = {
        container = container,
    }

    -- Get output dimensions
    local output = monitor_state.output
    local width, height = get_output_dimensions(output)

    -- Position at origin (accounting for geometry offset)
    local node_x, node_y = 0, 0
    if surface.role_obj then
        local geo = surface.role_obj.base.geometry
        node_x = -geo.x
        node_y = -geo.y
    end
    wl.roots.scene_node_set_position(surface.scene_tree.node, node_x, node_y)
    surface:set_size(width, height)

    -- Raise to top
    wl.roots.scene_node_raise_to_top(surface.scene_tree.node)

    monitor_state.fullscreen_surface = surface
    return true
end

function tiling:exit_fullscreen(monitor_state)
    local surface = monitor_state.fullscreen_surface
    if not surface then
        return false
    end

    surface._pre_fullscreen = nil
    monitor_state.fullscreen_surface = nil

    -- Re-arrange to restore tiled position
    arrange_workspace(monitor_state)

    return true
end

--------------------------------------------------------------------------------
-- Plugin Wrapper
--------------------------------------------------------------------------------

local plugin = {
    name = "layout-tiling",
}

function plugin:mount(config)
    local layout_service = require("compositor.services.layout")
    layout_service:register("tiling", tiling)
    return { layout = tiling }
end

function plugin:unmount()
    local layout_service = require("compositor.services.layout")
    layout_service:unregister("tiling")
end

return plugin
