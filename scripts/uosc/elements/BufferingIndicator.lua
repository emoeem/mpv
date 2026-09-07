local Element = require('elements/Element')

---@class BufferingIndicator : Element
local BufferingIndicator = class(Element)
local show_delay = 0.7

function BufferingIndicator:new() return Class.new(self) --[[@as BufferingIndicator]] end
function BufferingIndicator:init()
	Element.init(self, 'buffering_indicator', {ignores_curtain = true, render_order = 2})
	self.enabled = false
	self.generation = 0
	self.cache_paused = false
	self:observe_mp_property('paused-for-cache', 'bool', function(_, value)
		self.cache_paused = value == true
		self:decide_enabled()
	end)
	self:register_mp_event('start-file', function() self:reset() end)
	self:register_mp_event('end-file', function() self:reset() end)
	self:register_mp_event('file-loaded', function()
		self.cache_paused = mp.get_property_native('paused-for-cache') == true
		self:decide_enabled()
	end)
	self:register_disposer(function() self:reset() end)
	self:decide_enabled()
end

function BufferingIndicator:is_buffering()
	-- Prefetch progress and core-idle alone also describe ordinary startup,
	-- seeks, user pauses and filter rebuilds. Show only an actual cache wait.
	return not state.is_idle and not state.pause and not state.eof_reached
		and (self.cache_paused or (state.core_idle and state.is_stream and state.cache_underrun))
end

function BufferingIndicator:reset()
	self.generation = self.generation + 1
	if self.pending_timer then self.pending_timer:kill(); self.pending_timer = nil end
	self.cache_paused = false
	if self.enabled then self.enabled = false; request_render() end
end

function BufferingIndicator:decide_enabled()
	if not self:is_buffering() then
		self.generation = self.generation + 1
		if self.pending_timer then self.pending_timer:kill(); self.pending_timer = nil end
		if self.enabled then self.enabled = false; request_render() end
	elseif not self.enabled and not self.pending_timer then
		local generation = self.generation
		self.pending_timer = mp.add_timeout(show_delay, function()
			if generation ~= self.generation then return end
			self.pending_timer = nil
			self.enabled = self:is_buffering() == true
			request_render()
		end)
	end
end

function BufferingIndicator:on_prop_pause() self:decide_enabled() end
function BufferingIndicator:on_prop_core_idle() self:decide_enabled() end
function BufferingIndicator:on_prop_eof_reached() self:decide_enabled() end
function BufferingIndicator:on_prop_uncached_ranges() self:decide_enabled() end
function BufferingIndicator:on_prop_cache_buffering() self:decide_enabled() end
function BufferingIndicator:on_prop_cache_underrun() self:decide_enabled() end
function BufferingIndicator:on_prop_is_idle() self:decide_enabled() end
function BufferingIndicator:on_prop_is_stream() self:decide_enabled() end

function BufferingIndicator:render()
	local ass = assdraw.ass_new()
	local size = round(36 * state.scale)
	local timeline = Elements.timeline
	local bottom = timeline and timeline.ay > 0 and timeline.ay or display.height
	local x = display.width / 2
	local y = math.max(size, math.min(display.height - size, bottom - size))
	local opacity = (Elements.menu and Elements.menu:is_alive()) and 0.3 or 0.85
	-- Persistent buffering stays visible near the controls without dimming
	-- the whole frame or covering a face at the center of the picture.
	ass:rect(x - size / 2, y - size / 2, x + size / 2, y + size / 2,
		{color = bg, radius = size / 2, opacity = opacity * 0.8})
	ass:spinner(x, y, round(size * 0.65), {color = fg, opacity = opacity})
	return ass
end

return BufferingIndicator
