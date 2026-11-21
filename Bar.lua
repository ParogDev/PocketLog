-- The pocket bar: a timeline from the Pick Pocket cast that shows when the second press (the opener of the
-- user's own `/castsequence`) is safe. Display only: no buttons, no bindings, no casts, no macro edits.
--
-- Two parts. ns.BarLogic is the timing state machine, plain functions over a state table and a clock, so busted
-- can drive it. ns.Bar is the adapter: it reads what the recorder already worked out (the attempt of a cast,
-- the kind of a loot window, what was left in it) after Core has passed each event to the recorder, and draws.
--
-- Phases: idle -> waiting (cast succeeded, no window yet) -> looting (the pocket window is open)
--   -> ready (closed with everything taken, or no window by the timeout: "Open now"; drains over `drain` s,
--      the macro's reset=target/3) -> opened (the next press came while ready; keeps draining) -> idle
--   early (the next press came before ready) | left (closed with loot in it) | stale (window open too long)
--   -> idle after HOLD s. A target change clears the bar.
local _ADDON, ns = ...

local B = {}
ns.BarLogic = B

B.SPAN = 1.4 -- the bar's full width: 1400 ms from the cast
B.DEAD = 0.25 -- the loot window opens 191-254 ms after the cast in the log: pressing before this never works
B.GATE_GUESS = 0.6 -- where the gate sits until the window opens
B.GATE_PAD = 0.04 -- after the last slot's auto loot
B.BASE_TIMEOUT = 0.6 -- no window this long after the cast (plus world latency): no loot
B.DEFAULT_RATE = 0.15 -- autoLootRate default, seconds per slot
B.DEFAULT_DRAIN = 3 -- seconds the ready bar drains: the macro's reset=target/3
B.STALE = 8 -- a pocket window open this long (auto loot off, a missed close): give up
B.HOLD = 1.5 -- seconds a final red or grey state stays shown

function B.newCounters()
	return { started = 0, lootClosed = 0, ready = 0, left = 0, timeout = 0, early = 0, opened = 0, stale = 0 }
end

function B.new(counters)
	return { phase = "idle", counters = counters or B.newCounters(), drain = B.DEFAULT_DRAIN }
end

local function ms(sec)
	return math.floor(sec * 1000 + 0.5)
end

-- lat = { home, world } in ms (either may be nil when unknown); moving: true when the player moved at the cast.
function B.start(s, t, lat, moving, key)
	local world = lat and type(lat.world) == "number" and lat.world or 0
	s.phase = "waiting"
	s.key = key
	s.castAt = t
	s.timeout = B.BASE_TIMEOUT + world / 1000
	s.lat = lat or {}
	s.moving = moving == true
	s.gate, s.gateSolid = B.GATE_GUESS, false
	s.openAt, s.readyAt, s.doneAt, s.pressAt, s.noLoot, s.leftN = nil, nil, nil, nil, nil, nil
	s.slots, s.taken, s.rate = 0, {}, B.DEFAULT_RATE
	s.counters.started = s.counters.started + 1
end

-- The pocket window opened with nSlots slots; rate is autoLootRate in seconds. The gate snaps to the predicted
-- finish: the window's opening time plus one auto-loot step per slot plus a pad.
function B.onWindow(s, t, nSlots, rate)
	if s.phase ~= "waiting" then
		return false
	end
	s.phase = "looting"
	s.openAt = t
	s.slots = nSlots or 0
	s.rate = rate or B.DEFAULT_RATE
	s.gate = (t - s.castAt) + s.slots * s.rate + B.GATE_PAD
	s.gateSolid = true
	return true
end

function B.onSlotCleared(s, slot)
	if s.phase == "looting" and type(slot) == "number" then
		s.taken[slot] = true
	end
end

local function finish(s, t, phase)
	s.phase = phase
	s.doneAt = t
end

local function becomeReady(s, t, noLoot)
	s.noLoot = noLoot
	s.readyAt = t
	finish(s, t, "ready")
end

-- The pocket window closed; nLeft slots were still in it.
function B.onClosed(s, t, nLeft)
	if s.phase ~= "looting" then
		return false
	end
	s.leftN = nLeft or 0
	s.counters.lootClosed = s.counters.lootClosed + 1
	if s.leftN == 0 then
		s.counters.ready = s.counters.ready + 1
		becomeReady(s, t, false)
	else
		s.counters.left = s.counters.left + 1
		finish(s, t, "left")
	end
	return true
end

-- The next spell after the Pick Pocket was sent. Before ready it throws the loot away; on a ready bar it is the
-- good press, and the bar keeps draining.
function B.onPress(s, t)
	if s.phase == "waiting" or s.phase == "looting" then
		s.pressAt = t
		s.counters.early = s.counters.early + 1
		finish(s, t, "early")
	elseif s.phase == "ready" then
		s.pressAt = t
		s.counters.opened = s.counters.opened + 1
		s.phase = "opened"
	end
end

function B.clear(s)
	s.phase = "idle"
end

function B.tick(s, t)
	if s.phase == "waiting" and t - s.castAt > s.timeout then
		s.counters.timeout = s.counters.timeout + 1
		becomeReady(s, t, true)
	elseif s.phase == "looting" and t - s.openAt > B.STALE then
		s.counters.stale = s.counters.stale + 1
		finish(s, t, "stale")
	elseif (s.phase == "ready" or s.phase == "opened") and t - s.readyAt >= s.drain then
		s.phase = "idle"
	elseif (s.phase == "early" or s.phase == "left" or s.phase == "stale") and t - s.doneAt > B.HOLD then
		s.phase = "idle"
	end
	return s.phase
end

B.COLORS = {
	violet = "5B4B8A",
	amber = "8A6A2B",
	red = "C4302B",
	yellow = "FFF468",
	grey = "55506A",
}

local function frac(sec)
	return math.max(0, math.min(1, sec / B.SPAN))
end

-- What to draw at t, or nil when idle:
--   fill (0..1 of the width), color (B.COLORS key), yellow (whole bar yellow, dark text), label, sub (line
--   under the bar or ""), latency ("95 ms"), gate (0..1), gateSolid, pips ({ pos, taken }), tick (0..1 or nil).
function B.view(s, t)
	if s.phase == "idle" then
		return nil
	end
	local world = s.lat.world
	local v = {
		latency = (type(world) == "number" and tostring(math.floor(world + 0.5)) or "?") .. " ms",
		gate = frac(s.gate),
		gateSolid = s.gateSolid,
		pips = {},
		sub = "",
		color = s.moving and "amber" or "violet",
	}
	if s.openAt then
		local openSec = s.openAt - s.castAt
		for k = 1, s.slots do
			v.pips[k] = { pos = frac(openSec + k * s.rate), taken = s.taken[k] == true }
		end
	end
	if s.pressAt then
		v.tick = frac(s.pressAt - s.castAt)
	end
	local p = s.phase
	if p == "waiting" or p == "looting" then
		v.fill = frac(t - s.castAt)
		if s.moving then
			v.label = "Moving"
			v.sub = "Cast while moving: the loot window rarely opens"
		else
			v.label = "Wait"
		end
	elseif p == "ready" or p == "opened" then
		v.yellow = true
		v.color = "yellow"
		v.fill = math.max(0, 1 - (t - s.readyAt) / s.drain)
		if p == "ready" then
			v.label = s.noLoot and "No loot, open now" or "Open now"
		else
			v.label = "Opened"
			if not s.noLoot then
				v.sub = string.format("Loot in. Opened %d ms after the bar turned.", ms(s.pressAt - s.readyAt))
			end
		end
	elseif p == "early" then
		v.fill = frac(s.pressAt - s.castAt)
		v.color = "red"
		v.label = "Too early"
		if s.gateSolid then
			v.sub = string.format("Opened %d ms early. Loot lost.", math.max(0, ms(s.gate - (s.pressAt - s.castAt))))
		else
			v.sub = "Opened before the loot window opened."
		end
	elseif p == "left" then
		v.fill = frac(s.doneAt - s.castAt)
		v.color = "red"
		v.label = "Loot left"
		v.sub = string.format("The window closed with %d left.", s.leftN or 0)
	else
		v.fill = frac(s.doneAt - s.castAt)
		v.color = "grey"
		v.label = "Window open too long"
	end
	return v
end

-- ---------------------------------------------------------------------------------------------------------
-- Adapter and frame
-- ---------------------------------------------------------------------------------------------------------
local Bar = {}
ns.Bar = Bar

local WIDTH, HEIGHT = 440, 24
local DEFAULT_POINT = { "CENTER", "CENTER", 0, -160 }

Bar.counters = B.newCounters()
Bar.state = B.new(Bar.counters)

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

local function now()
	return GetTimePreciseSec()
end

local function inInstance()
	local ok, inside = pcall(IsInInstance)
	return ok and inside == true
end

local function latency()
	local ok, _, _, home, world = pcall(GetNetStats)
	if not ok then
		return {}
	end
	return {
		home = (not isSecret(home)) and home or nil,
		world = (not isSecret(world)) and world or nil,
	}
end

local function lootRate()
	local raw = ns.Recorder.cvar("autoLootRate")
	local n = type(raw) == "string" and tonumber(raw)
	if n and n >= 0 then
		return n / 1000
	end
	return B.DEFAULT_RATE
end

local function rgb(hex)
	return tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
end
Bar.rgb = rgb

function Bar.enabled()
	return Bar.cfg ~= nil and Bar.cfg.enabled ~= false
end

-- ---- frame -----------------------------------------------------------------------------------------------
local function savePosition(f)
	local point, _, relPoint, x, y = f:GetPoint(1)
	if type(point) == "string" then
		Bar.cfg.point = { point, relPoint, math.floor((x or 0) + 0.5), math.floor((y or 0) + 0.5) }
	end
end

local function place(f)
	local p = Bar.cfg.point or DEFAULT_POINT
	f:ClearAllPoints()
	f:SetPoint(p[1], UIParent, p[2], p[3], p[4])
end

local function solid(parent, layer, hex, sub)
	local tex = parent:CreateTexture(nil, layer, nil, sub)
	tex:SetColorTexture(rgb(hex))
	return tex
end

local function text(parent, size, hex)
	local fs = parent:CreateFontString(nil, "OVERLAY")
	fs:SetFontObject(GameFontHighlight)
	fs:SetFontHeight(size)
	fs:SetTextColor(rgb(hex))
	return fs
end

function Bar.createView()
	local f = CreateFrame("Frame", nil, UIParent)
	f:SetSize(WIDTH, HEIGHT)
	f:SetFrameStrata("MEDIUM")
	f:SetClampedToScreen(true)
	f:SetMovable(true)
	f:RegisterForDrag("LeftButton")
	f:SetScript("OnDragStart", function(self)
		if not Bar.cfg.locked then
			self:StartMoving()
		end
	end)
	f:SetScript("OnDragStop", function(self)
		self:StopMovingOrSizing()
		savePosition(self)
	end)

	local border = solid(f, "BACKGROUND", "8C8A93", 0)
	border:SetPoint("TOPLEFT", -1, 1)
	border:SetPoint("BOTTOMRIGHT", 1, -1)
	local track = solid(f, "BACKGROUND", "1E1A25", 1)
	track:SetAllPoints()

	local dead = solid(f, "BORDER", "2A2433", 0)
	dead:SetPoint("TOPLEFT")
	dead:SetPoint("BOTTOMLEFT")
	dead:SetWidth(WIDTH * B.DEAD / B.SPAN)
	local deadEdge = solid(f, "BORDER", "55506A", 1)
	deadEdge:SetWidth(1)
	deadEdge:SetPoint("TOPRIGHT", dead, "TOPRIGHT")
	deadEdge:SetPoint("BOTTOMRIGHT", dead, "BOTTOMRIGHT")

	local fill = f:CreateTexture(nil, "ARTWORK", nil, 0)
	fill:SetColorTexture(1, 1, 1)
	fill:SetPoint("TOPLEFT")
	fill:SetPoint("BOTTOMLEFT")
	f.fill = fill

	local gate = solid(f, "OVERLAY", "FFFFFF", 0)
	gate:SetSize(2, HEIGHT)
	f.gate = gate

	local tick = solid(f, "OVERLAY", "FFFFFF", 2)
	tick:SetSize(3, HEIGHT + 4)
	f.tick = tick

	f.pips = {}

	f.spell = text(f, 13, "CFC9DA")
	f.spell:SetPoint("BOTTOMLEFT", f, "TOPLEFT", 0, 3)
	f.spell:SetText("Pick Pocket")
	f.lat = text(f, 13, "CFC9DA")
	f.lat:SetPoint("BOTTOMRIGHT", f, "TOPRIGHT", 0, 3)
	f.label = text(f, 13, "FFFFFF")
	f.label:SetPoint("CENTER")
	f.sub = text(f, 14, "CFC9DA")
	f.sub:SetPoint("TOP", f, "BOTTOM", 0, -4)

	f:SetScript("OnUpdate", function()
		Bar.tick()
	end)
	f:Hide()
	Bar.view = f
	place(f)
	return f
end

-- An 8 px outlined square per loot slot, made on first use.
local function pip(f, k)
	local p = f.pips[k]
	if not p then
		p = {}
		p.outline = solid(f, "OVERLAY", "CFC9DA", 3)
		p.outline:SetSize(8, 8)
		p.inner = solid(f, "OVERLAY", "1E1A25", 4)
		p.inner:SetSize(6, 6)
		p.inner:SetPoint("CENTER", p.outline, "CENTER")
		f.pips[k] = p
	end
	return p
end

local function at(tex, f, pos)
	tex:ClearAllPoints()
	tex:SetPoint("CENTER", f, "LEFT", WIDTH * pos, 0)
end

local function hidePips(f, from)
	for k = from, #f.pips do
		f.pips[k].outline:Hide()
		f.pips[k].inner:Hide()
	end
end

-- Draws the state at t; hides the bar when idle (unless it is unlocked for moving).
function Bar.draw(t)
	local f = Bar.view
	if not f then
		return
	end
	local v = Bar.enabled() and B.view(Bar.state, t) or nil
	if not v then
		if Bar.enabled() and not Bar.cfg.locked then
			f.fill:Hide()
			f.gate:Hide()
			f.tick:Hide()
			hidePips(f, 1)
			f.label:SetTextColor(rgb("FFFFFF"))
			f.label:SetText("PocketLog bar: drag me")
			f.lat:SetText("")
			f.sub:SetText("/pocketlog bar lock")
			f:Show()
		else
			f:Hide()
		end
		return
	end
	if v.fill > 0 then
		f.fill:SetColorTexture(rgb(B.COLORS[v.color]))
		f.fill:SetWidth(WIDTH * v.fill)
		f.fill:Show()
	else
		f.fill:Hide()
	end
	at(f.gate, f, v.gate)
	f.gate:SetAlpha(v.gateSolid and 1 or 0.45)
	f.gate:SetShown(not v.yellow)
	if v.tick then
		at(f.tick, f, v.tick)
		f.tick:Show()
	else
		f.tick:Hide()
	end
	for k, p in ipairs(v.pips) do
		local w = pip(f, k)
		at(w.outline, f, p.pos)
		w.inner:SetColorTexture(rgb(p.taken and "FFF468" or "1E1A25"))
		w.outline:SetShown(not v.yellow)
		w.inner:SetShown(not v.yellow)
	end
	hidePips(f, #v.pips + 1)
	f.label:SetTextColor(rgb(v.yellow and "3A3400" or "FFFFFF"))
	f.label:SetText(v.label)
	f.lat:SetText(v.latency)
	f.sub:SetText(v.sub)
	f:Show()
end

function Bar.tick()
	local t = now()
	local before = Bar.state.phase
	B.tick(Bar.state, t)
	if before ~= "idle" or Bar.state.phase ~= "idle" then
		Bar.draw(t)
	end
end

function Bar.applyConfig()
	Bar.state.drain = Bar.cfg.drain
	local f = Bar.view
	if not f then
		return
	end
	f:EnableMouse(not Bar.cfg.locked)
	place(f)
	Bar.draw(now())
end

function Bar.init(db)
	db.bar = type(db.bar) == "table" and db.bar or {}
	local cfg = db.bar
	if cfg.enabled == nil then
		cfg.enabled = true
	end
	if cfg.locked == nil then
		cfg.locked = true
	end
	if type(cfg.drain) ~= "number" or cfg.drain <= 0 then
		cfg.drain = B.DEFAULT_DRAIN
	end
	Bar.cfg = cfg
	if not Bar.view then
		Bar.createView()
	end
	Bar.applyConfig()
end

-- ---- events (called by Core after the recorder has seen the same event) ------------------------------------
-- Starts the bar for attempt `a`, seen at t. The origin is the cast's success, or the send when the loot window
-- beat the SUCCEEDED (never later than t). An opener the recorder already filed on the attempt (sent before the
-- bar started) is applied at its own time.
local function startFor(a, t, fromSend)
	local origin = t
	if fromSend and type(a.sentAt) == "number" and a.sentAt <= t then
		origin = a.sentAt
	end
	B.start(Bar.state, origin, latency(), a.move and a.move.moving == true, a)
	local o = a.opener
	local since = type(a.sentAt) == "number" and a.sentAt or origin
	if o and o.isOpener and type(o.sentAt) == "number" and o.sentAt >= since and o.sentAt <= t then
		B.onPress(Bar.state, o.sentAt)
	end
end

local on = {}

function on.UNIT_SPELLCAST_SUCCEEDED(unit, castGUID, spellID)
	if unit ~= "player" or isSecret(castGUID) or isSecret(spellID) then
		return
	end
	if ns.Recorder.spellKey(spellID) ~= "pickpocket" or inInstance() then
		return
	end
	local a = ns.Recorder.byCast[castGUID]
	-- skip when the pocket window already started this attempt's bar (it beat the SUCCEEDED)
	if type(a) == "table" and a.sentAt and not a.cast and Bar.state.key ~= a then
		startFor(a, now())
	end
end

-- The second press is an opener (Cheap Shot, Ambush, Garrote, Sap): Sprint, a trinket or a racial between the
-- two presses does not close the loot window and is not judged.
function on.UNIT_SPELLCAST_SENT(unit, _target, castGUID, spellID)
	if unit ~= "player" or isSecret(castGUID) or isSecret(spellID) then
		return
	end
	local key = ns.Recorder.spellKey(spellID)
	if key and ns.Recorder.SPELLS[key].opener then
		B.onPress(Bar.state, now())
	end
end

function on.LOOT_READY()
	local s = ns.Recorder.session
	if not (s and s.kind == "pocket" and s.attempt) then
		return
	end
	local t = now()
	-- the window beat the cast's SUCCEEDED: start from the send
	if Bar.state.key ~= s.attempt and not inInstance() then
		startFor(s.attempt, t, true)
	end
	if Bar.state.key == s.attempt then
		B.onWindow(Bar.state, t, #(s.rec.slots or {}), lootRate())
	end
end

function on.LOOT_SLOT_CLEARED(slot)
	local s = ns.Recorder.session
	if s and s.attempt == Bar.state.key and s.kind == "pocket" then
		B.onSlotCleared(Bar.state, slot)
	end
end

function on.LOOT_CLOSED()
	local c = ns.Recorder.closed
	if c and c.kind == "pocket" and c.attempt == Bar.state.key and c.rec.left then
		B.onClosed(Bar.state, now(), #c.rec.left)
	end
end

function on.PLAYER_TARGET_CHANGED()
	B.clear(Bar.state)
end

-- Events the bar needs that the recorder does not listen to; Core registers them too.
Bar.EXTRA_EVENTS = { "PLAYER_TARGET_CHANGED" }

function Bar.onEvent(event, ...)
	local fn = on[event]
	if fn and Bar.enabled() then
		fn(...)
		Bar.draw(now())
	end
end

function Bar.selftest()
	local c = {}
	for k, v in pairs(Bar.counters) do
		c[k] = v
	end
	c.enabled = Bar.enabled()
	if Bar.cfg then
		c.locked = Bar.cfg.locked
		c.drain = Bar.cfg.drain
	end
	c.phase = Bar.state.phase
	return c
end

local USAGE = "/pocketlog bar on | off | lock | unlock | reset | drain <seconds>"

-- /pocketlog bar <on|off|lock|unlock|reset|drain N>: returns the lines to print.
function Bar.slash(arg)
	arg = arg or ""
	local cfg = Bar.cfg
	if not cfg then
		return { "PocketLog bar: not loaded yet." }
	end
	local drain = arg:match("^drain%s+([%d%.]+)$")
	if drain then
		local n = tonumber(drain)
		if not n or n <= 0 or n > 30 then
			return { "PocketLog bar: drain takes seconds between 0 and 30." }
		end
		cfg.drain = n
	elseif arg == "on" then
		cfg.enabled = true
	elseif arg == "off" then
		cfg.enabled = false
		B.clear(Bar.state)
	elseif arg == "lock" then
		cfg.locked = true
	elseif arg == "unlock" then
		cfg.locked = false
		cfg.enabled = true
	elseif arg == "reset" then
		cfg.point = nil
	elseif arg ~= "" then
		return { "PocketLog bar: " .. USAGE }
	end
	Bar.applyConfig()
	return {
		string.format(
			"PocketLog bar: %s, %s, drains in %s s. %s",
			cfg.enabled and "on" or "off",
			cfg.locked and "locked" or "unlocked (drag it)",
			tostring(cfg.drain),
			USAGE
		),
	}
end

return Bar
