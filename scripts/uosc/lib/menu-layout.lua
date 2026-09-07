-- Shared viewport geometry for drawn panels and their pointer targets.
local layout = {}

function layout.clamp_panel(x, y, width, height, viewport_width, viewport_height, edge)
	local function fit(value, size, available)
		return math.max(edge, math.min(value, math.max(edge, available - edge - size)))
	end
	return fit(x, width, viewport_width), fit(y, height, viewport_height)
end

-- The first child chooses a side; all descendants keep it. Prefer a slightly
-- narrower readable panel on that side over reversing the user's pointer path.
function layout.submenu(parent, width, viewport_width, edge, gap, direction, ancestors, min_width)
	local function candidate(side, shrink)
		local near = side == -1 and parent.ax - gap or parent.bx + gap
		local far = side == -1 and edge or viewport_width - edge
		for _, rect in ipairs(ancestors or {}) do
			if side == -1 and rect.bx <= near then far = math.max(far, rect.bx + gap) end
			if side == 1 and rect.ax >= near then far = math.min(far, rect.ax - gap) end
		end
		local available = (far - near) * side
		local fitted = shrink and math.min(width, available) or width
		if fitted > available or fitted < math.min(width, min_width or width) then return nil end
		local x = side == -1 and near - fitted or near
		for _, rect in ipairs(ancestors or {}) do
			if x < rect.bx and x + fitted > rect.ax then return nil end
		end
		return x, side, fitted
	end
	local sides = direction and {direction} or {1, -1}
	for _, shrink in ipairs({false, true}) do
		for _, side in ipairs(sides) do
			local x, opening, fitted = candidate(side, shrink)
			if x then return x, opening, fitted end
		end
	end
	-- Even drill-in affordances must retain the branch's established direction.
	return nil, direction or (parent.ax > viewport_width - parent.bx and -1 or 1)
end

return layout
