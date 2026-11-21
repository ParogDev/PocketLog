-- Event recorder: turns the client's cast, error, loot and money events into attempt records in
-- PocketLogDB.attempts. It measures only; it never acts on the game.
--
-- Attempt shape (all times on the GetTimePreciseSec clock, seconds; `t` is wall clock):
--   { id, t, guid, mob = { name, level, classification }, zone, castGUID, spellID,
--     sentAt, lat = { home, world }, result = "sent"|"succeeded"|"failed"|"interrupted", resultAt,
--     errors = { { kind, msg, errType, dtMs } },
--     pocket = session | nil, corpse = { session, ... },
--     opener = { spellID, name, isOpener, sentAt, dtMs, lat, result } }
-- Session shape: { readyAt, dtMs (from the cast), autoloot, opened, targetDead, slots = { slot... },
--     cleared = { [slot] = true }, closedAt, left = { slot numbers }, money = copper gained (PLAYER_MONEY),
--     chat = { { kind, text, dtMs } } }
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

R.stats = { events = 0, secret = 0, attempts = 0, sessions = 0, orphanLoot = 0, skippedInstance = 0 }

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
R.money = nil -- GetMoney() at the last look

function R.attach(db)
	R.db = db
	db.attempts = db.attempts or {}
	db.nextId = db.nextId or (#db.attempts + 1)
	R.byCast, R.byGUID, R.last, R.session, R.closed = {}, {}, nil, nil, nil
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
	-- Any other spell right after a Pick Pocket: the opener (or whatever came next).
	local a = R.last
	if a and not a.opener and a.sentAt and now() - a.sentAt < OPENER_WINDOW then
		local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
		local t = now()
		a.opener = {
			spellID = spellID,
			name = safe(name),
			key = key,
			isOpener = key ~= nil and R.SPELLS[key].opener == true,
			sentAt = t,
			dtMs = ms(a.resultAt or a.sentAt, t),
			dtFromSentMs = ms(a.sentAt, t),
			lat = latency(),
			result = "sent",
			sameTarget = targetGUID() == a.guid,
		}
		if type(castGUID) == "string" then
			R.byCast[castGUID] = { opener = a.opener }
		end
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
	if a and a.opener and not a.id then
		a.opener.result = result
		a.opener.resultAt = now()
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
	-- The opener's errors belong to the opener; the Pick Pocket's to the attempt.
	local target = a
	if a.opener and a.opener.sentAt and t - a.opener.sentAt < ERROR_WINDOW then
		target = a.opener
		target.errors = target.errors or {}
	elseif t - a.sentAt >= ERROR_WINDOW then
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

function R.onLootReady(autoloot)
	if R.session and not R.session.rec.closedAt then
		return -- LOOT_READY again for the same window
	end
	local t = now()
	local n = GetNumLootItems() or 0
	local slots = {}
	for i = 1, n do
		slots[#slots + 1] = readSlot(i)
	end
	local a, guid = attemptFor(slots)
	if not a and R.last and #slots == 0 then
		a, guid = R.last, R.last.guid -- an empty window right after a cast
	end
	local rec = {
		readyAt = t,
		autoloot = safe(autoloot),
		slots = slots,
		cleared = {},
		chat = {},
		money = 0,
		targetDead = targetIsDead(guid),
	}
	local kind = "other"
	if a then
		rec.dtMs = ms(a.sentAt, t)
		local fresh = a.sentAt and t - a.sentAt < POCKET_WINDOW
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
		R.session.rec.cleared[slot] = true
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
	R.closed, R.session = s, nil
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
