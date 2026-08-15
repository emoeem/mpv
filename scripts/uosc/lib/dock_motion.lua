-- Shared motion state for the bottom timeline + controls dock.
-- The interaction rectangles stay fixed; only the rendered geometry reads
-- this value, avoiding a proximity feedback loop while the dock is moving.
local DockMotion = {
	value = nil,
	target = 0,
	last_time = nil,
	active_mode = nil,
	transition_from = nil,
	transition_to = nil,
	transition_start = nil,
	transition_duration = nil,
}

local function smoothstep(value)
	value = clamp(0, value, 1)
	return value * value * (3 - 2 * value)
end

local function smootherstep(value)
	value = clamp(0, value, 1)
	return value * value * value * (value * (value * 6 - 15) + 10)
end

local function normalize_mode(mode)
	mode = tostring(mode or 'classic'):lower()
	if mode == 'smooth' or mode == 'classic' or mode == 'off' then return mode end
	return 'classic'
end

local function clear_transition(self)
	self.transition_from = nil
	self.transition_to = nil
	self.transition_start = nil
	self.transition_duration = nil
end

function DockMotion:reset(value)
	self.value = clamp(0, value or 0, 1)
	self.target = self.value
	self.last_time = nil
	self.active_mode = nil
	clear_transition(self)
end

function DockMotion:get_mode()
	if options.dock_animation == false then return 'off' end
	return normalize_mode(options.dock_animation_mode or self.active_mode)
end

function DockMotion:set_mode(mode)
	self.active_mode = normalize_mode(mode)
	self.last_time = state.render_last_time or mp.get_time()
	clear_transition(self)
	return self.active_mode
end

function DockMotion:update_classic(target, now)
	local previous_target = self.target
	local was_settled = math.abs((previous_target or self.value) - self.value) <= 0.001
	if was_settled and math.abs(target - (previous_target or target)) > 0.001 then
		-- Do not count time spent dormant as animation time; a new interaction
		-- starts on this frame and advances from the next display tick.
		self.last_time = now
	end
	self.target = target
	local elapsed = clamp(0, now - (self.last_time or now), 0.25)
	self.last_time = now
	local duration = target > self.value
		and (options.dock_animation_in or 180)
		or (options.dock_animation_out or 220)

	if duration <= 0 then
		self.value = target
		return
	end

	local distance = target - self.value
	if math.abs(distance) <= 0.001 then
		self.value = target
		return
	end

	-- Classic mode intentionally preserves the original fast response: it
	-- reaches 99% of the target in the configured duration.
	local response = 1 - math.exp(math.log(0.01) * elapsed * 1000 / duration)
	self.value = clamp(0, self.value + distance * response, 1)
	if math.abs(target - self.value) <= 0.001 then
		self.value = target
	else
		request_render()
	end
end

function DockMotion:evaluate_smooth(now)
	local duration = self.transition_duration or 0
	local from = self.transition_from
	local to = self.transition_to
	if from == nil or to == nil or duration <= 0 then return 1, 1 end

	local elapsed = math.max(0, (now - (self.transition_start or now)) * 1000)
	local progress = clamp(0, elapsed / duration, 1)
	local eased = smootherstep(progress)
	self.value = clamp(0, from + (to - from) * eased, 1)
	if progress >= 1 then self.value = to end
	return progress, eased
end

function DockMotion:start_smooth_transition(target, now)
	self.transition_from = self.value
	self.transition_to = target
	self.transition_start = now
	self.transition_duration = target > self.value
		and (options.dock_animation_smooth_in or 240)
		or (options.dock_animation_smooth_out or 280)
	self.target = target
end

function DockMotion:update_smooth(target, now)
	-- First advance the existing curve to the exact current timestamp. Retargets
	-- can then preserve that rendered position instead of using the prior frame.
	local progress, eased = self:evaluate_smooth(now)
	local target_changed = self.transition_to == nil
		or math.abs(target - self.transition_to) > 0.001
	if target_changed then
		local old_direction = (self.transition_to or self.value) - (self.transition_from or self.value)
		local new_direction = target - self.value
		local same_direction = old_direction * new_direction > 0

		if same_direction and progress < 0.95 then
			-- Proximity targets move while the cursor approaches the dock. Update the
			-- endpoint without restarting the clock or jumping the current frame.
			-- Solving the interpolation equation for `from` preserves continuity.
			self.transition_from = (self.value - target * eased) / math.max(0.001, 1 - eased)
			self.transition_to = target
			self.target = target
		else
			-- Direction reversals deliberately start a new zero-velocity curve from
			-- the current pixel position, preventing overshoot and single-frame snaps.
			self:start_smooth_transition(target, now)
			progress, eased = 0, 0
		end
	end

	local duration = self.transition_duration or 0
	local distance = (self.transition_to or target) - (self.transition_from or self.value)
	if duration <= 0 or math.abs(distance) <= 0.001 then
		self.value = target
		self.target = target
		return
	end

	self.last_time = now
	if progress < 1 then request_render() end
end

function DockMotion:update()
	local target = Elements:maybe('timeline', 'get_dock_target')
		or Elements:maybe('controls', 'get_target_visibility') or 0
	target = clamp(0, target, 1)

	local now = state.render_last_time or mp.get_time()
	if self.value == nil then
		self.value = target
		self.target = target
		self.last_time = now
		return
	end

	local mode = self:get_mode()
	if mode ~= self.active_mode then
		self.active_mode = mode
		self.last_time = now
		self.target = self.value
		clear_transition(self)
	end

	if mode == 'off' then
		self.value = target
		self.target = target
		clear_transition(self)
		return
	end

	if mode == 'classic' then
		self:update_classic(target, now)
	else
		self:update_smooth(target, now)
	end
end

function DockMotion:get_visibility()
	return self.value or 0
end

function DockMotion:get_geometry(value)
	value = value ~= nil and value or self:get_visibility()
	-- Smooth mode already applies one full-duration easing pass. Applying a
	-- second curve here was the main cause of the dock visually rushing ahead.
	return self:get_mode() == 'smooth' and clamp(0, value, 1) or smoothstep(value)
end

function DockMotion:get_timeline_geometry()
	if self:get_mode() == 'smooth' then
		-- Follow the master motion exactly. In particular, do not repeat the
		-- classic /0.72 remap that made the track finish before the full duration.
		return clamp(0, self:get_visibility(), 1)
	end
	-- The timeline leads the choreography and reaches its expanded track before
	-- the controls finish fading in. This is retained for classic mode only.
	return smoothstep(clamp(0, self:get_visibility() / 0.72, 1))
end

function DockMotion:get_timeline_bounds(expanded_ax, expanded_bx, display_width)
	-- The minimized progress line is a true edge-to-edge viewport element. Its
	-- horizontal bounds converge on the regular inset timeline as the dock opens.
	local geometry = self:get_timeline_geometry()
	return expanded_ax * geometry,
		display_width + (expanded_bx - display_width) * geometry
end

function DockMotion:is_minimized_progress_enabled()
	-- The edge-to-edge mini progress line belongs to the new smooth design.
	-- Classic mode must remain visually identical to the original dock when
	-- retracted: no persistent line, only the full dock on normal proximity.
	if self:get_mode() ~= 'smooth' then return false end
	local placement = options.progress == 'always'
		or (options.progress == 'fullscreen' and state.fullormaxed)
		or (options.progress == 'windowed' and not state.fullormaxed)
	if not placement then return false end
	if options.progress_playing_only ~= true then return true end
	return not state.pause and not state.is_idle and not state.eof_reached
end

function DockMotion:get_minimized_track_visibility(timeline_geometry)
	if options.progress_minimized_track ~= false then return 1 end
	-- Hide the unplayed/cache track in the resting mini state, then bring the
	-- complete track back as the regular timeline expands under the cursor.
	return timeline_geometry ~= nil and timeline_geometry or self:get_timeline_geometry()
end

function DockMotion:get_surface_profile()
	if self:get_mode() == 'classic' then
		-- Restore the original, deeper dock mask together with the original
		-- response curve. It stays anchored at the expanded panel top.
		return 15, 0.70, 0.34, false
	end
	-- Smooth mode keeps the restrained material surface and lets its height
	-- continuously follow the full-duration Morph geometry.
	return 8, 0.30, 0.14, true
end

function DockMotion:get_controls_opacity()
	if self:get_mode() == 'smooth' then
		-- The master value is already eased; a linear fade mapping avoids another
		-- front-loaded curve while retaining a subtle controls-after-track delay.
		return clamp(0, (self:get_visibility() - 0.08) / 0.92, 1)
	end
	-- Timeline motion leads by a small amount; controls then join as one group.
	local value = clamp(0, (self:get_visibility() - 0.10) / 0.72, 1)
	return smoothstep(value)
end

function DockMotion:get_controls_transform()
	local geometry = self:get_geometry()
	if self:get_mode() == 'smooth' then
		-- Re-rasterizing every button glyph at a different scale can look stepped
		-- in ASS. The smooth mode therefore uses only a restrained 6px lift.
		return {
			scale = 1,
			translate_y = (1 - geometry) * 6 * state.scale,
		}
	end
	return {
		scale = 0.94 + geometry * 0.06,
		translate_y = (1 - geometry) * 10 * state.scale,
	}
end

return DockMotion
