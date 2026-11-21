-- Event recorder: turns the client's cast, error, loot and money events into attempt records in
-- PocketLogDB.attempts. It measures only; it never acts on the game.
--
-- Attempt shape (all times on the GetTimePreciseSec clock, seconds; `t` is wall clock):
--   { id, t, guid, mob = { name, level, classification }, zone, castGUID, spellID,
--     sentAt, lat = { home, world }, move = { moving, speed, falling }, moveAtResult,
--     result = "sent"|"succeeded"|"failed"|"interrupted", resultAt, resultMs,
--     sqw = SpellQueueWindow CVar (string, cached at login and on CVAR_UPDATE),
--     range = { spell = C_Spell.IsSpellInRange (true|false|nil), interact = CheckInteractDistance 3 | "blocked" },
--     loc = { mapID, x, y (0..1, 3 decimals; nil without a position), subzone },
--     errors = { { kind, msg, errType, dtMs } },
--     pocket = session | nil, corpse = { session, ... },
--     opener = { spellID, name, isOpener, sentAt, dtMs, lat, result, resultAt }, nextCast = same shape }
-- Session shape: { readyAt, dtMs (from the cast), autoloot, opened, targetDead, slots = { slot... },
--     autoLootDefault, autoLootRate (raw CVar strings), autoLootToggle (IsModifiedClick("AUTOLOOTTOGGLE")),
--     cleared = { [slot] = ms after readyAt }, changed = { { slot, dtMs } } (LOOT_SLOT_CHANGED),
--     closedAt, openMs, left = { slot numbers }, closedBy = "opener"|"all_taken"|"manual"|"empty" (a guess),
--     closeVsOpenerMs = closedAt - opener.sentAt, closeVsOpenerResultMs = closedAt - opener.resultAt,
--     money = copper gained (PLAYER_MONEY), chat = { { kind, text, dtMs } } }
-- Every value read from the client goes through safe(): a secret is stored as "secret".
-- Slot shape: { slot, type, name, qty, quality, link, itemID, isCoin, money, sources = { { guid, qty } } }
local _ADDON, ns = ...

local R = {}
ns.Recorder = R

local SECRET = "secret"
local MAX_ATTEMPTS = 3000
local POCKET_WINDOW = 5 -- seconds after the cast in which a loot window from that mob counts as the pocket
local OPENER_WINDOW = 10 -- seconds after the cast in which the next spell counts as the opener
local ERROR_WINDOW = 1.5 -- seconds after a cast in which a UI error belongs to it
local CHAT_WINDOW = 2 -- seconds after a loot window closed in which money and loot chat still belong to it
local STALE_SESSION = 60 -- a loot window open this long without LOOT_CLOSED missed its close event
local CLOSE_BY_OPENER = 0.3 -- an opener sent this close to LOOT_CLOSED (either side) is taken as what closed it

R.stats = {
	events = 0,
	secret = 0,
	attempts = 0,
	sessions = 0,
	orphanLoot = 0,
	skippedInstance = 0,
	repeatReady = 0,
	closeMissed = 0,
}

local function isSecret(v)
	return issecretvalue ~= nil and issecretvalue(v)
end

-- The value itself, or "secret". Never compares or concatenates a secret.
local function safe(v)
	if isSecret(v) then
		R.stats.secret = R.stats.secret + 1
		return SECRET
	end
	return v
end
R.safe = safe

local function now()
	return GetTimePreciseSec()
end

local function ms(a, b)
	if type(a) ~= "number" or type(b) ~= "number" then
		return nil
	end
	return math.floor((b - a) * 1000 + 0.5)
end

local function latency()
	local ok, _, _, home, world = pcall(GetNetStats)
	if not ok then
		return { error = "GetNetStats failed" }
	end
	return { home = safe(home), world = safe(world) }
end

-- The player's movement right now: { moving, speed (yards/s), falling }. Speed can be secret when unit stats
-- are restricted; then it is stored as "secret".
local function movement()
	-- explicit ifs: `ok and false or nil` would drop a false (standing still)
	local m = {}
	local okM, moving = pcall(IsPlayerMoving)
	if okM then
		m.moving = safe(moving)
	end
	local okS, speed = pcall(GetUnitSpeed, "player")
	if okS then
		m.speed = safe(speed)
	end
	local okF, falling = pcall(IsFalling)
	if okF then
		m.falling = safe(falling)
	end
	return m
end
R.movement = movement

-- A CVar's raw string, "secret", or nil when C_CVar is missing or the call fails.
local function cvar(name)
	if not (C_CVar and C_CVar.GetCVar) then
		return nil
	end
	local ok, v = pcall(C_CVar.GetCVar, name)
	if not ok then
		return nil
	end
	return safe(v)
end
R.cvar = cvar

R.cvars = {} -- cached CVars stamped on each attempt
function R.refreshCVars()
	R.cvars.spellQueueWindow = cvar("SpellQueueWindow")
	return R.cvars
end

function R.onCVarUpdate(name)
	if type(name) == "string" and not isSecret(name) and name:lower() == "spellqueuewindow" then
		R.refreshCVars()
	end
end

-- Range to the target at the Pick Pocket send. CheckInteractDistance is protected against hostile units in
-- combat on Mainline: a failed call is stored as "blocked".
local function rangeAt(spellID)
	local r = {}
	if C_Spell and C_Spell.IsSpellInRange and type(spellID) == "number" then
		local ok, inRange = pcall(C_Spell.IsSpellInRange, spellID, "target")
		if ok then
			r.spell = safe(inRange)
		else
			r.spell = "error"
		end
	end
	if CheckInteractDistance == nil then
		r.interact = "missing"
		return r
	end
	local ok, near = pcall(CheckInteractDistance, "target", 3)
	if ok then
		r.interact = safe(near)
	else
		r.interact = "blocked"
	end
	return r
end
R.rangeAt = rangeAt

local function round3(v)
	if type(v) ~= "number" then
		return v
	end
	return math.floor(v * 1000 + 0.5) / 1000
end

-- Where the player stands: { mapID, x, y, subzone }. No position (an instance, a map without one) is fine.
local function location()
	local loc = {}
	if not (C_Map and C_Map.GetBestMapForUnit and C_Map.GetPlayerMapPosition) then
		loc.missing = "C_Map"
	end
	local okM, mapID = pcall(function()
		return C_Map.GetBestMapForUnit("player")
	end)
	if okM then
		loc.mapID = safe(mapID)
	end
	if type(loc.mapID) == "number" then
		local okP, pos = pcall(function()
			return C_Map.GetPlayerMapPosition(loc.mapID, "player")
		end)
		if okP and pos ~= nil and not isSecret(pos) then
			local okXY, x, y = pcall(pos.GetXY, pos)
			if okXY then
				loc.x, loc.y = round3(safe(x)), round3(safe(y))
			end
		end
	end
	local okZ, sub = pcall(GetSubZoneText)
	if okZ then
		loc.subzone = safe(sub)
	end
	return loc
end
R.location = location

-- ---------------------------------------------------------------------------------------------------------
-- Spells: resolved by name through C_Spell (enUS client), else by known ids checked against their name.
-- ---------------------------------------------------------------------------------------------------------
R.SPELLS = {
	pickpocket = { name = "Pick Pocket", ids = { 921 } },
	cheapShot = { name = "Cheap Shot", ids = { 1833 }, opener = true },
	ambush = { name = "Ambush", ids = { 8676, 8724, 8725, 11267, 11268, 11269 }, opener = true },
	garrote = { name = "Garrote", ids = { 703, 8631, 8632, 8633, 11289, 11290 }, opener = true },
	sap = { name = "Sap", ids = { 6770, 2070, 11297 }, opener = true },
}
R.resolved = {} -- key -> { spellID, name, how }
R.nameToKey = {} -- spell name (from C_Spell) -> key

function R.resolveSpells()
	R.resolved, R.nameToKey = {}, {}
	for key, def in pairs(R.SPELLS) do
		local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(def.name)
		local entry
		if info and info.spellID then
			entry = { spellID = info.spellID, name = info.name, how = "name" }
		else
			for _, id in ipairs(def.ids) do
				local n = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(id)
				if n then
					entry = { spellID = id, name = n, how = "id" }
					break
				end
			end
		end
		if entry then
			R.resolved[key] = entry
			R.nameToKey[entry.name] = key
		else
			R.resolved[key] = { how = "unresolved: C_Spell knows neither '" .. def.name .. "' nor its ids" }
		end
	end
	return R.resolved
end

-- Which of our spells is this id? Matches the resolved id, else the spell's name (ranks share a name).
function R.spellKey(spellID)
	if isSecret(spellID) or type(spellID) ~= "number" then
		return nil
	end
	for key, e in pairs(R.resolved) do
		if e.spellID == spellID then
			return key
		end
	end
	local n = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
	if n and not isSecret(n) then
		return R.nameToKey[n]
	end
	return nil
end

-- ---------------------------------------------------------------------------------------------------------
-- Errors: locale-safe kinds from the GlobalStrings constants.
-- ---------------------------------------------------------------------------------------------------------
local ERROR_KINDS = {
	{ "SPELL_FAILED_TARGET_NO_POCKETS", "no_pockets" },
	{ "ERR_ALREADY_PICKPOCKETED", "already_picked" },
	{ "SPELL_FAILED_TARGET_AFFECTING_COMBAT", "target_in_combat" },
	{ "SPELL_FAILED_OUT_OF_RANGE", "out_of_range" },
	{ "ERR_OUT_OF_RANGE", "out_of_range" },
	{ "SPELL_FAILED_ONLY_STEALTHED", "not_stealthed" },
	{ "SPELL_FAILED_NOT_BEHIND", "not_behind" },
	{ "SPELL_FAILED_UNIT_NOT_INFRONT", "not_in_front" },
}
function R.errorKind(msg)
	if isSecret(msg) or type(msg) ~= "string" then
		return SECRET
	end
	for _, pair in ipairs(ERROR_KINDS) do
		local text = _G[pair[1]]
		if type(text) == "string" and text ~= "" and msg == text then
			return pair[2]
		end
	end
	return "other"
end

-- ---------------------------------------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------------------------------------
R.byCast = {} -- castGUID -> attempt (this session only)
R.byGUID = {} -- mob GUID -> latest attempt
R.last = nil -- latest attempt
R.session = nil -- the open loot window: { rec = session, attempt = a, kind = "pocket"|"corpse"|"other" }
R.closed = nil -- the last closed window, for late chat and money events
R.recentClosed = {} -- windows closed in the last OPENER_WINDOW seconds, newest last: { rec, attempt }
R.money = nil -- GetMoney() at the last look

-- What closed a loot window, a guess from the timings: "all_taken" when no slot is left (the client closes an
-- emptied window itself), else "opener" when the attempt's opener was sent at the window's mob within
-- CLOSE_BY_OPENER of the close or while the window was open, else "manual". The window's attempt is found by
-- the loot's source GUID, so its opener is the one cast after that mob's Pick Pocket. Run again when the
-- opener or its result arrives after the close, so a SENT that lands just after LOOT_CLOSED still counts.
local function judgeClose(rec, a)
	if not rec.closedAt then
		return
	end
	local o = a and a.opener
	rec.closeVsOpenerMs = o and ms(o.sentAt, rec.closedAt) or nil
	rec.closeVsOpenerResultMs = o and ms(o.resultAt, rec.closedAt) or nil
	local sent = o and o.sentAt
	-- an opener cast at another target (sameTarget false) did not interrupt this mob's window
	local byOpener = type(sent) == "number"
		and o.sameTarget ~= false
		and (
			math.abs(rec.closedAt - sent) <= CLOSE_BY_OPENER
			or (type(rec.readyAt) == "number" and sent >= rec.readyAt and sent <= rec.closedAt)
		)
	if #(rec.slots or {}) == 0 then
		rec.closedBy = "empty" -- nothing was there to take: says nothing about what closed it
	elseif #(rec.left or {}) == 0 then
		rec.closedBy = "all_taken"
	elseif byOpener then
		rec.closedBy = "opener"
	else
		rec.closedBy = "manual"
	end
end
R.judgeClose = judgeClose

-- The opener of `a` changed after windows of `a` closed: judge each of them again, not only the latest closed
-- window (another mob's window may have closed since).
local function rejudgeClosed(a)
	for _, c in ipairs(R.recentClosed) do
		if c.attempt == a then
			judgeClose(c.rec, a)
		end
	end
end

local function rememberClosed(s)
	local list, t = R.recentClosed, s.rec.closedAt
	list[#list + 1] = { rec = s.rec, attempt = s.attempt }
	while #list > 0 and not (type(list[1].rec.closedAt) == "number" and t - list[1].rec.closedAt < OPENER_WINDOW) do
		table.remove(list, 1)
	end
end

function R.attach(db)
	R.db = db
	db.attempts = db.attempts or {}
	db.nextId = db.nextId or (#db.attempts + 1)
	R.byCast, R.byGUID, R.last, R.session, R.closed, R.recentClosed = {}, {}, nil, nil, nil, {}
	-- Corpses can be looted after a reload: index the recent attempts by mob.
	local from = math.max(1, #db.attempts - 300)
	for i = from, #db.attempts do
		local a = db.attempts[i]
		if a.guid and a.guid ~= SECRET then
			R.byGUID[a.guid] = a
		end
	end
	local ok, m = pcall(GetMoney)
	R.money = ok and m or nil
end

local function push(a)
	local list = R.db.attempts
	list[#list + 1] = a
	while #list > MAX_ATTEMPTS do
		table.remove(list, 1)
	end
	R.stats.attempts = R.stats.attempts + 1
end

local function inInstance()
	local ok, inside = pcall(IsInInstance)
	return ok and inside == true
end

local function targetGUID()
	local g = UnitGUID("target")
	if g == nil or isSecret(g) then
		return g and SECRET or nil
	end
	return g
end

local function newAttempt(castGUID, spellID)
	local g = targetGUID()
	local a = {
		id = R.db.nextId,
		t = time(),
		guid = g,
		castGUID = safe(castGUID),
		spellID = safe(spellID),
		sentAt = now(),
		lat = latency(),
		move = movement(),
		sqw = R.cvars.spellQueueWindow,
		range = rangeAt((R.resolved.pickpocket and R.resolved.pickpocket.spellID) or spellID),
		loc = location(),
		result = "sent",
		errors = {},
		corpse = {},
	}
	R.db.nextId = R.db.nextId + 1
	if g and g ~= SECRET then
		a.mob = {
			name = safe(UnitName("target")),
			level = safe(UnitLevel("target")),
			classification = safe(UnitClassification("target")),
		}
	end
	local okZone, zone = pcall(GetRealZoneText)
	a.zone = okZone and safe(zone) or nil
	push(a)
	if type(castGUID) == "string" then
		R.byCast[castGUID] = a
	end
	if g and g ~= SECRET then
		R.byGUID[g] = a
	end
	R.last = a
	return a
end

-- ---------------------------------------------------------------------------------------------------------
-- Casts
-- ---------------------------------------------------------------------------------------------------------
function R.onSpellSent(unit, _target, castGUID, spellID)
	if unit ~= "player" then
		return
	end
	if isSecret(spellID) or isSecret(castGUID) then
		R.stats.secret = R.stats.secret + 1
		return
	end
	local key = R.spellKey(spellID)
	if key == "pickpocket" then
		if inInstance() then
			R.stats.skippedInstance = R.stats.skippedInstance + 1
			return
		end
		newAttempt(castGUID, spellID)
		return
	end
	-- Another spell right after a Pick Pocket: the opener (Cheap Shot, Ambush, Garrote, Sap) goes in `opener`;
	-- the first other spell before it (Sprint, a bandage) goes in `nextCast`, so it doesn't hide the opener.
	local a = R.last
	local t = now()
	if not a or a.opener or not a.sentAt or t < a.sentAt or t - a.sentAt >= OPENER_WINDOW then
		return
	end
	local isOpener = key ~= nil and R.SPELLS[key].opener == true
	if not isOpener and a.nextCast then
		return
	end
	local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
	local rec = {
		spellID = spellID,
		name = safe(name),
		key = key,
		isOpener = isOpener,
		sentAt = t,
		dtMs = ms(a.resultAt or a.sentAt, t),
		dtFromSentMs = ms(a.sentAt, t),
		lat = latency(),
		move = movement(),
		result = "sent",
		sameTarget = targetGUID() == a.guid,
	}
	if isOpener then
		a.opener = rec
		rejudgeClosed(a)
	else
		a.nextCast = rec
	end
	if type(castGUID) == "string" then
		R.byCast[castGUID] = { cast = rec, attempt = a }
	end
end

local function castResult(unit, castGUID, spellID, result)
	if unit ~= "player" then
		return
	end
	if isSecret(castGUID) then
		R.stats.secret = R.stats.secret + 1
		return
	end
	local a = R.byCast[castGUID]
	if a and a.cast then
		if a.cast.result == "sent" then
			a.cast.result = result
			a.cast.resultAt = now()
			if a.attempt and a.attempt.opener == a.cast then
				rejudgeClosed(a.attempt)
			end
		end
		return
	end
	if not a then
		-- A failure the client caught before sending (no SENT event): record it as an attempt of its own.
		if result ~= "succeeded" and R.spellKey(spellID) == "pickpocket" and not inInstance() then
			a = newAttempt(castGUID, spellID)
			a.clientSide = true
			-- Its UI error came first, while R.last was still the previous attempt.
			local e = R.lastError
			if e and a.sentAt - e.at < ERROR_WINDOW then
				a.errors[#a.errors + 1] = { kind = e.kind, msg = e.msg, errType = e.errType, dtMs = 0 }
				-- and take it back from the attempt it was first pinned on
				for i, x in ipairs(e.list or {}) do
					if x == e.entry then
						table.remove(e.list, i)
						break
					end
				end
				e.list, e.entry = nil, nil
			end
		else
			return
		end
	end
	-- FAILED often follows INTERRUPTED or SUCCEEDED for the same cast: keep the first final result.
	if a.result == "sent" then
		a.result = result
		a.resultAt = now()
		a.resultMs = ms(a.sentAt, a.resultAt)
		a.moveAtResult = movement()
	end
end

function R.onSpellSucceeded(unit, castGUID, spellID)
	castResult(unit, castGUID, spellID, "succeeded")
end
function R.onSpellFailed(unit, castGUID, spellID)
	castResult(unit, castGUID, spellID, "failed")
end
function R.onSpellInterrupted(unit, castGUID, spellID)
	castResult(unit, castGUID, spellID, "interrupted")
end

function R.onUIError(errType, msg)
	local t = now()
	R.lastError = { kind = R.errorKind(msg), msg = safe(msg), errType = safe(errType), at = t }
	local a = R.last
	if not a or not a.sentAt then
		return
	end
	-- An error belongs to the latest cast sent within ERROR_WINDOW: the opener's to the opener, the in-between
	-- spell's (Sprint, a bandage) to `nextCast`, the Pick Pocket's to the attempt.
	local target
	for _, c in ipairs({ a.opener or false, a.nextCast or false }) do
		if c and c.sentAt and t >= c.sentAt and t - c.sentAt < ERROR_WINDOW then
			if not target or c.sentAt > target.sentAt then
				target = c
			end
		end
	end
	if target then
		target.errors = target.errors or {}
	elseif t - a.sentAt < ERROR_WINDOW then
		target = a
	else
		return
	end
	local e = {
		kind = R.lastError.kind,
		msg = R.lastError.msg,
		errType = R.lastError.errType,
		dtMs = ms(target.sentAt, t),
	}
	target.errors[#target.errors + 1] = e
	R.lastError.list, R.lastError.entry = target.errors, e
end

-- ---------------------------------------------------------------------------------------------------------
-- Loot
-- ---------------------------------------------------------------------------------------------------------
local function itemIDFromLink(link)
	if type(link) ~= "string" then
		return nil
	end
	return tonumber(link:match("|Hitem:(%d+)"))
end

local function readSlot(i)
	local slot = { slot = i }
	local okT, slotType = pcall(GetLootSlotType, i)
	slot.type = okT and safe(slotType) or "error"
	local okI, _tex, name, qty, _cur, quality, _locked, _quest, _qid, _active, isCoin = pcall(GetLootSlotInfo, i)
	if okI then
		slot.name, slot.qty, slot.quality, slot.isCoin = safe(name), safe(qty), safe(quality), safe(isCoin)
	else
		slot.error = "GetLootSlotInfo failed"
	end
	local okL, link = pcall(GetLootSlotLink, i)
	if okL and link then
		slot.link = safe(link)
		slot.itemID = itemIDFromLink(slot.link)
	end
	slot.sources = {}
	local src = { pcall(GetLootSourceInfo, i) }
	if src[1] then
		local money = 0
		for k = 2, #src, 2 do
			local g, q = safe(src[k]), safe(src[k + 1])
			slot.sources[#slot.sources + 1] = { guid = g, qty = q }
			if type(q) == "number" then
				money = money + q
			end
		end
		local isMoney = slot.type == (Enum and Enum.LootSlotType and Enum.LootSlotType.Money or 2)
		if isMoney then
			slot.money = money
		end
	end
	return slot
end

-- The mob this window belongs to: the first non-secret source GUID with an attempt.
local function attemptFor(slots)
	for _, s in ipairs(slots) do
		for _, src in ipairs(s.sources or {}) do
			if src.guid ~= SECRET and R.byGUID[src.guid] then
				return R.byGUID[src.guid], src.guid
			end
		end
	end
	return nil
end

local function targetIsDead(guid)
	if guid and targetGUID() == guid then
		local d = UnitIsDead("target")
		if isSecret(d) then
			return SECRET
		end
		return d == true
	end
	return nil
end

-- Source GUIDs (non-secret) of a window's slots, as a set, and how many there were.
local function sourceSet(slots)
	local set, n = {}, 0
	for _, s in ipairs(slots or {}) do
		for _, src in ipairs(s.sources or {}) do
			if type(src.guid) == "string" and src.guid ~= SECRET and not set[src.guid] then
				set[src.guid] = true
				n = n + 1
			end
		end
	end
	return set, n
end

-- Is a LOOT_READY with these slots the open window firing again? Same mobs (every source GUID of the new slots
-- was a source of the open window), no more slots than it had. A window without readable GUIDs can't be told
-- apart from a new one: not the same.
local function sameWindow(rec, slots)
	if #slots == 0 or #slots > #(rec.slots or {}) then
		return false
	end
	local old = sourceSet(rec.slots)
	local new, n = sourceSet(slots)
	if n == 0 then
		return false
	end
	for g in pairs(new) do
		if not old[g] then
			return false
		end
	end
	return true
end
R.sameWindow = sameWindow

local function readSlots()
	local n = GetNumLootItems() or 0
	local slots = {}
	for i = 1, n do
		slots[#slots + 1] = readSlot(i)
	end
	return slots
end

function R.onLootReady(autoloot)
	local t = now()
	local slots
	if R.session and not R.session.rec.closedAt then
		-- LOOT_READY again for the same window. Past STALE_SESSION it is the same window only when it shows the
		-- same mobs' loot; otherwise its LOOT_CLOSED was missed and this is a new window.
		local rec = R.session.rec
		local fresh = t >= rec.readyAt and t - rec.readyAt < STALE_SESSION
		if not fresh then
			slots = readSlots()
		end
		if fresh or sameWindow(rec, slots) then
			R.stats.repeatReady = (R.stats.repeatReady or 0) + 1
			return
		end
		rec.closeMissed = true
		R.stats.closeMissed = (R.stats.closeMissed or 0) + 1
		R.onLootClosed()
	end
	slots = slots or readSlots()
	local a, guid = attemptFor(slots)
	local last = R.last
	if not a and last and #slots == 0 and type(last.sentAt) == "number" and t >= last.sentAt then
		-- an empty window right after a cast on the current target
		if t - last.sentAt < POCKET_WINDOW and (last.guid == nil or targetGUID() == last.guid) then
			a, guid = last, last.guid
		end
	end
	local rec = {
		readyAt = t,
		autoloot = safe(autoloot),
		slots = slots,
		cleared = {},
		changed = {},
		chat = {},
		money = 0,
		targetDead = targetIsDead(guid),
		autoLootDefault = cvar("autoLootDefault"),
		autoLootRate = cvar("autoLootRate"),
	}
	local okT, toggle = pcall(IsModifiedClick, "AUTOLOOTTOGGLE")
	if okT then
		rec.autoLootToggle = safe(toggle)
	end
	local kind = "other"
	if a then
		rec.dtMs = ms(a.sentAt, t)
		-- t < sentAt: the attempt was saved before a reboot (the precise clock restarted), so it is old
		local fresh = type(a.sentAt) == "number" and t >= a.sentAt and t - a.sentAt < POCKET_WINDOW
		if not a.pocket and #a.corpse == 0 and fresh and a.result ~= "failed" and rec.targetDead ~= true then
			a.pocket = rec
			kind = "pocket"
		else
			a.corpse[#a.corpse + 1] = rec
			rec.n = #a.corpse
			kind = "corpse"
		end
		R.stats.sessions = R.stats.sessions + 1
	else
		R.stats.orphanLoot = R.stats.orphanLoot + 1
	end
	R.session = { rec = rec, attempt = a, kind = kind }
end

function R.onLootOpened(autoloot)
	if R.session then
		R.session.rec.opened = true
		R.session.rec.openedMs = ms(R.session.rec.readyAt, now())
		R.session.rec.autoloot = safe(autoloot)
	end
end

function R.onLootSlotCleared(slot)
	if R.session and type(slot) == "number" then
		-- ms after the window was ready: a number, so still truthy for Logic.slotsLeft (0 is truthy in Lua)
		R.session.rec.cleared[slot] = ms(R.session.rec.readyAt, now()) or true
	end
end

function R.onLootSlotChanged(slot)
	if R.session and type(slot) == "number" then
		local rec = R.session.rec
		rec.changed = rec.changed or {}
		rec.changed[#rec.changed + 1] = { slot = slot, dtMs = ms(rec.readyAt, now()) }
	end
end

function R.onLootClosed()
	local s = R.session
	if not s then
		return
	end
	local rec = s.rec
	rec.closedAt = now()
	rec.openMs = ms(rec.readyAt, rec.closedAt)
	rec.left = {}
	for _, slot in ipairs(rec.slots) do
		if not rec.cleared[slot.slot] then
			rec.left[#rec.left + 1] = slot.slot
		end
	end
	judgeClose(rec, s.attempt)
	R.closed, R.session = s, nil
	rememberClosed(s)
end

-- The window money and loot chat belong to: the open one, else one closed in the last CHAT_WINDOW seconds.
local function currentRec()
	if R.session then
		return R.session.rec
	end
	if R.closed and R.closed.rec.closedAt and now() - R.closed.rec.closedAt < CHAT_WINDOW then
		return R.closed.rec
	end
	return nil
end

function R.onChat(kind, text)
	local rec = currentRec()
	if not rec then
		return
	end
	rec.chat[#rec.chat + 1] = { kind = kind, text = safe(text), dtMs = ms(rec.readyAt, now()) }
end

function R.onMoney()
	local ok, m = pcall(GetMoney)
	if not ok or type(m) ~= "number" or isSecret(m) then
		return
	end
	local before = R.money
	R.money = m
	local rec = currentRec()
	if rec and before and m > before then
		rec.money = (rec.money or 0) + (m - before)
	end
end

return R
