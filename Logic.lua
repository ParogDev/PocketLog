-- Pure analysis of recorded attempts: no client calls, so busted tests cover all of it.
-- An attempt is one Pick Pocket cast on one mob (see Recorder.lua for its shape). Two questions per attempt:
--   outcome:        what the Pick Pocket did (looted / left / empty / never_shown / no_pockets / failed)
--   corpseOutcome:  what the corpse gave later (not_looted / normal / normal_plus_pocket / second_loot / pending)
-- tools/pocketlog_report.py in the scaffolding mirrors both classifiers; tests/fixtures/classify_cases.lua pins
-- them to the same answers (busted here, pytest there).
local _ADDON, ns = ...

local Logic = {}
ns.Logic = Logic

-- Outcomes, in the order the summary prints them.
Logic.OUTCOMES = { "looted", "left", "empty", "never_shown", "no_pockets", "failed", "pending" }
Logic.CORPSE_OUTCOMES = { "normal", "normal_plus_pocket", "second_loot", "not_looted", "pending" }

-- The waits below go into the selftest (`waits`), so tools/pocketlog_report.py classifies with the values the
-- save was made with; tests/fixtures/classify_cases.lua (PocketLogWaits) pins its fallback to these.
-- Seconds after the cast result (or the send) in which the pocket window may still come.
Logic.ATTEMPT_WAIT = 3
-- Seconds after the Pick Pocket send in which an unlooted corpse is "pending" (the fight may still be on),
-- not "not_looted".
Logic.CORPSE_WAIT = 120
-- Seconds a loot window may stay open without LOOT_CLOSED. Past it the close was missed (a reload, disconnect
-- or crash while the window was open) and the window counts as closed. Recorder uses it for a missed close too.
Logic.WINDOW_WAIT = 60

-- GetTimePreciseSec restarts with the PC: a saved time later than `now` is from before a reboot, so old.
local function within(now, at, wait)
	return type(now) == "number" and type(at) == "number" and now >= at and now - at < wait
end

-- Error kinds Recorder.errorKind() gives a UI_ERROR_MESSAGE or a failed cast.
local NO_POCKET_KINDS = { no_pockets = true, already_picked = true }

local function slotsLeft(session)
	local left = {}
	if not session or not session.slots then
		return left
	end
	-- cleared[slot] is the ms after readyAt the slot was taken (0.3.0) or true (older logs): any truthy value
	local cleared = session.cleared or {}
	for _, s in ipairs(session.slots) do
		if not cleared[s.slot] then
			left[#left + 1] = s
		end
	end
	return left
end
Logic.slotsLeft = slotsLeft

-- Money (copper) in a list of slots: the source amounts of money slots, else 0.
local function moneyOf(slots)
	local total = 0
	for _, s in ipairs(slots or {}) do
		if s.money and type(s.money) == "number" then
			total = total + s.money
		end
	end
	return total
end
Logic.moneyOf = moneyOf

local function itemsOf(slots)
	local out = {}
	for _, s in ipairs(slots or {}) do
		if s.itemID and type(s.itemID) == "number" then
			out[#out + 1] = s.itemID
		end
	end
	return out
end
Logic.itemsOf = itemsOf

-- What a Pick Pocket attempt did. `now` (seconds, GetTimePreciseSec clock) decides "pending": a cast that
-- succeeded less than `wait` seconds ago may still get its window. A window without closedAt is "pending" only
-- while it is under `windowWait` seconds old; a window Recorder settled (closedBy "unknown"), an older one or
-- one with no clock to judge by counts as closed, with the slots it took then.
function Logic.classifyAttempt(a, now, wait, windowWait)
	wait = wait or Logic.ATTEMPT_WAIT
	for _, e in ipairs(a.errors or {}) do
		if NO_POCKET_KINDS[e.kind] then
			return "no_pockets"
		end
	end
	local p = a.pocket
	if p then
		if not p.slots or #p.slots == 0 then
			return "empty"
		end
		if not p.closedAt and p.closedBy ~= "unknown" and within(now, p.readyAt, windowWait or Logic.WINDOW_WAIT) then
			return "pending" -- window still open
		end
		if #slotsLeft(p) > 0 then
			return "left"
		end
		return "looted"
	end
	local function recent(at)
		return within(now, at, wait)
	end
	if a.result == "succeeded" then
		if recent(a.resultAt) then
			return "pending"
		end
		return "never_shown"
	end
	if a.result == "failed" or a.result == "interrupted" then
		return "failed"
	end
	if recent(a.sentAt) then
		return "pending"
	end
	-- Sent, then nothing: no success, no failure. The server dropped it or the event was secret.
	return "never_shown"
end

-- Does a corpse session hold what the pocket left behind? Items by id; money when a corpse money source
-- equals the pocket's money, or the corpse total equals pocket money plus some corpse money (merged).
-- Returns { items = n, itemIDs = {...}, money = "equal" | "none", pocketMoney = c, pocketItems = n }.
function Logic.matchCarryOver(pocketLeft, corpse)
	local res = { items = 0, itemIDs = {}, money = "none", pocketMoney = moneyOf(pocketLeft) }
	local want = itemsOf(pocketLeft)
	res.pocketItems = #want
	if not corpse or not corpse.slots then
		return res
	end
	local have = {}
	for _, id in ipairs(itemsOf(corpse.slots)) do
		have[id] = (have[id] or 0) + 1
	end
	for _, id in ipairs(want) do
		if have[id] and have[id] > 0 then
			have[id] = have[id] - 1
			res.items = res.items + 1
			res.itemIDs[#res.itemIDs + 1] = id
		end
	end
	if res.pocketMoney > 0 then
		for _, s in ipairs(corpse.slots) do
			if s.money == res.pocketMoney then
				res.money = "equal"
			end
		end
	end
	return res
end

local function sessionHasLoot(s)
	return s and s.slots and #s.slots > 0
end

-- What the corpse gave. Second loot: two corpse windows with loot. Plus pocket: the one corpse window holds
-- the pocket's left-behind items or its exact money. Pending: no corpse window yet, and the Pick Pocket was
-- sent less than `wait` (CORPSE_WAIT) seconds before `now`, so the mob may still be fought.
function Logic.classifyCorpse(a, now, wait)
	local sessions = a.corpse or {}
	local withLoot = 0
	for _, s in ipairs(sessions) do
		if sessionHasLoot(s) then
			withLoot = withLoot + 1
		end
	end
	if #sessions == 0 then
		if within(now, a.sentAt, wait or Logic.CORPSE_WAIT) then
			return "pending"
		end
		return "not_looted"
	end
	if withLoot >= 2 then
		return "second_loot"
	end
	local left = slotsLeft(a.pocket)
	if #left > 0 then
		for _, s in ipairs(sessions) do
			local m = Logic.matchCarryOver(left, s)
			if m.items > 0 or m.money == "equal" then
				return "normal_plus_pocket"
			end
		end
	end
	return "normal"
end

-- Bucket of a number for the summary tables (ms gaps, latency).
function Logic.bucket(v, edges)
	if type(v) ~= "number" then
		return "n/a"
	end
	local lo = 0
	for _, e in ipairs(edges) do
		if v < e then
			return lo .. "-" .. e
		end
		lo = e
	end
	return lo .. "+"
end

-- Did the window show? Only outcomes that answer it: no_pockets, failed and pending say nothing.
local SHOWN = { looted = true, left = true, empty = true, never_shown = false }

-- "moving" | "still" | "unknown" at the Pick Pocket cast: the SENT snapshot, else the SUCCEEDED one.
function Logic.movement(a)
	for _, key in ipairs({ "move", "moveAtResult" }) do
		local m = a[key]
		if type(m) == "table" then
			if m.moving == true or (type(m.speed) == "number" and m.speed > 0) then
				return "moving"
			end
			if m.moving == false then
				return "still"
			end
		end
	end
	return "unknown"
end

-- "inRange" | "outOfRange" | "unknown": C_Spell.IsSpellInRange at the Pick Pocket send.
function Logic.range(a)
	-- not `type(...) == "table" and a.range.spell`: that gives false (out of range) for an attempt without range
	if type(a.range) ~= "table" then
		return "unknown"
	end
	local r = a.range.spell
	if r == true then
		return "inRange"
	elseif r == false then
		return "outOfRange"
	end
	return "unknown"
end

-- "unknown": the window was still open at a load or logout (Recorder.settleOpen), so its close was never seen.
Logic.CLOSED_BY = { "opener", "all_taken", "manual", "empty", "unknown" }

Logic.GAP_EDGES = { 250, 500, 1000, 2000 }
Logic.LAT_EDGES = { 50, 100, 200, 400 }

-- Counts for /pocketlog and the selftest. `now` as in classifyAttempt.
function Logic.summarize(attempts, now)
	local s = {
		total = 0,
		outcome = {},
		corpse = {},
		pocketMoney = 0,
		pocketItems = 0,
		carry = { left = 0, carried = 0, neverShown = 0, neverShownSecond = 0 },
		openerBeforeWindow = 0,
		-- window shown or not, split by movement at the Pick Pocket cast
		move = {
			still = { shown = 0, notShown = 0 },
			moving = { shown = 0, notShown = 0 },
			unknown = { shown = 0, notShown = 0 },
		},
		-- what closed the pocket window (Recorder's guess), over pocket windows that recorded it
		closedBy = { opener = 0, all_taken = 0, manual = 0, empty = 0, unknown = 0 },
		-- window shown or not, split by C_Spell.IsSpellInRange at the Pick Pocket cast
		range = {
			inRange = { shown = 0, notShown = 0 },
			outOfRange = { shown = 0, notShown = 0 },
			unknown = { shown = 0, notShown = 0 },
		},
	}
	for _, k in ipairs(Logic.OUTCOMES) do
		s.outcome[k] = 0
	end
	for _, k in ipairs(Logic.CORPSE_OUTCOMES) do
		s.corpse[k] = 0
	end
	for _, a in ipairs(attempts or {}) do
		s.total = s.total + 1
		local o = Logic.classifyAttempt(a, now)
		local c = Logic.classifyCorpse(a, now)
		s.outcome[o] = (s.outcome[o] or 0) + 1
		s.corpse[c] = (s.corpse[c] or 0) + 1
		if a.pocket and a.pocket.slots then
			local got = {}
			local left = {}
			for _, x in ipairs(slotsLeft(a.pocket)) do
				left[x.slot] = true
			end
			for _, x in ipairs(a.pocket.slots) do
				if not left[x.slot] then
					got[#got + 1] = x
				end
			end
			s.pocketMoney = s.pocketMoney + moneyOf(got)
			s.pocketItems = s.pocketItems + #itemsOf(got)
		end
		-- carry-over counts only attempts whose corpse is settled: a pending corpse may still show the pocket loot
		local settled = c ~= "pending"
		if settled and o == "left" then
			s.carry.left = s.carry.left + 1
			if c == "normal_plus_pocket" or c == "second_loot" then
				s.carry.carried = s.carry.carried + 1
			end
		elseif settled and o == "never_shown" then
			s.carry.neverShown = s.carry.neverShown + 1
			if c == "second_loot" then
				s.carry.neverShownSecond = s.carry.neverShownSecond + 1
			end
		end
		local shown = SHOWN[o]
		if shown ~= nil then
			for _, m in ipairs({ s.move[Logic.movement(a)], s.range[Logic.range(a)] }) do
				if shown then
					m.shown = m.shown + 1
				else
					m.notShown = m.notShown + 1
				end
			end
		end
		local by = a.pocket and a.pocket.closedBy
		if type(by) == "string" then
			s.closedBy[by] = (s.closedBy[by] or 0) + 1
		end
		if a.opener and a.opener.sentAt and a.sentAt then
			local readyAt = a.pocket and a.pocket.readyAt
			if not readyAt or a.opener.sentAt < readyAt then
				s.openerBeforeWindow = s.openerBeforeWindow + 1
			end
		end
	end
	return s
end

return Logic
