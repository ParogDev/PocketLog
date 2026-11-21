-- Addon entry: SavedVariables, the selftest contract (docs/verify-loop.md in the scaffolding), event wiring
-- and the /pocketlog summary. The recording itself is Recorder.lua; the analysis is Logic.lua.
local ADDON, ns = ...

PocketLog = ns

local R, Logic, Bar = ns.Recorder, ns.Logic, ns.Bar

-- Bar.lua came with 0.4.0. A client that has not restarted since keeps the old file list and never loads it:
-- recording goes on, and the selftest and /pocketlog bar name that broken link instead of erroring.
if not Bar then
	local missing = "Bar.lua not loaded: restart the client (a new file needs a restart, not a /reload)"
	Bar = {
		EXTRA_EVENTS = {},
		init = function() end,
		onEvent = function() end,
		selftest = function()
			return { error = missing }
		end,
		slash = function()
			return { "PocketLog bar: " .. missing }
		end,
	}
end

local DB_VERSION = 1

function ns.initDB(saved)
	local db = type(saved) == "table" and saved or {}
	db.dbVersion = db.dbVersion or DB_VERSION
	db.attempts = db.attempts or {}
	db.selftest = db.selftest or {}
	ns.db = db
	PocketLogDB = db
	R.attach(db)
	return db
end

local selftest = { counters = R.stats }
ns.selftest = selftest

-- The version the code says it is: a junction-linked checkout has the packager's unreplaced token in the .toc,
-- so the selftest would show the same "@project-version@" before and after a change.
ns.VERSION = "0.4.0"

local function version()
	local ok, v = pcall(C_AddOns.GetAddOnMetadata, ADDON, "Version")
	if not ok or type(v) ~= "string" or v:find("@", 1, true) then
		return ns.VERSION
	end
	return v
end
ns.version = version

function selftest.snapshot(phase)
	local okB, buildVersion, buildNumber, _, interface = pcall(GetBuildInfo)
	local clock = GetTimePreciseSec()
	local sum = Logic.summarize(ns.db.attempts, clock)
	ns.db.selftest = {
		phase = phase,
		version = version(),
		-- GetTimePreciseSec at the save: the report's `now` for pending (attempt times are on that clock)
		clock = clock,
		-- the waits Logic classifies with, so the report needs no copy of them
		waits = { attempt = Logic.ATTEMPT_WAIT, corpse = Logic.CORPSE_WAIT, window = Logic.WINDOW_WAIT },
		build = okB and (tostring(buildVersion) .. "." .. tostring(buildNumber)) or "GetBuildInfo failed",
		interface = okB and interface or nil,
		project = WOW_PROJECT_ID,
		loadedAt = selftest.loadedAt,
		savedAt = date("%Y-%m-%d %H:%M:%S"),
		spells = R.resolved,
		cvars = { spellQueueWindow = R.cvars.spellQueueWindow },
		counters = R.stats,
		attempts = #ns.db.attempts,
		summary = sum,
		bar = Bar.selftest(),
		lastError = selftest.lastError,
	}
	return ns.db.selftest
end

-- Runs fn, catching an error into selftest.lastError instead of breaking the event frame.
local function guard(where, fn, ...)
	local ok, err = pcall(fn, ...)
	if not ok then
		selftest.lastError = { where = where, error = tostring(err), at = date("%Y-%m-%d %H:%M:%S") }
	end
end

-- ---------------------------------------------------------------------------------------------------------
-- /pocketlog
-- ---------------------------------------------------------------------------------------------------------
local function money(c)
	c = math.floor(c or 0)
	return string.format("%dg %ds %dc", math.floor(c / 10000), math.floor(c / 100) % 100, c % 100)
end

function ns.summaryLines()
	local s = Logic.summarize(ns.db.attempts, GetTimePreciseSec())
	local out = {}
	local function add(fmt, ...)
		out[#out + 1] = string.format(fmt, ...)
	end
	add("PocketLog: %d attempts recorded", s.total)
	local parts = {}
	for _, k in ipairs(Logic.OUTCOMES) do
		if s.outcome[k] > 0 then
			parts[#parts + 1] = k .. " " .. s.outcome[k]
		end
	end
	add("  pick pocket: %s", #parts > 0 and table.concat(parts, ", ") or "none yet")
	parts = {}
	for _, k in ipairs(Logic.CORPSE_OUTCOMES) do
		if s.corpse[k] > 0 then
			parts[#parts + 1] = k .. " " .. s.corpse[k]
		end
	end
	add("  corpse: %s", #parts > 0 and table.concat(parts, ", ") or "none yet")
	add("  looted from pockets: %s and %d items", money(s.pocketMoney), s.pocketItems)
	add(
		"  left in pockets: %d, found on the corpse %d; never shown: %d, second corpse loot %d",
		s.carry.left,
		s.carry.carried,
		s.carry.neverShown,
		s.carry.neverShownSecond
	)
	add("  opener cast before the pocket window: %d", s.openerBeforeWindow)
	add(
		"  window shown / not shown: still %d/%d, moving %d/%d, unknown %d/%d",
		s.move.still.shown,
		s.move.still.notShown,
		s.move.moving.shown,
		s.move.moving.notShown,
		s.move.unknown.shown,
		s.move.unknown.notShown
	)
	add(
		"  pocket window closed by: opener %d, all taken %d, manual %d, empty %d, unknown %d",
		s.closedBy.opener,
		s.closedBy.all_taken,
		s.closedBy.manual,
		s.closedBy.empty,
		s.closedBy.unknown
	)
	add(
		"  shown / not shown by range: in %d/%d, out %d/%d, unknown %d/%d",
		s.range.inRange.shown,
		s.range.inRange.notShown,
		s.range.outOfRange.shown,
		s.range.outOfRange.notShown,
		s.range.unknown.shown,
		s.range.unknown.notShown
	)
	return out
end

local function print(line)
	DEFAULT_CHAT_FRAME:AddMessage(line)
end

SLASH_POCKETLOG1 = "/pocketlog"
SlashCmdList.POCKETLOG = function(msg)
	msg = type(msg) == "string" and msg:lower() or ""
	local barArg = msg == "bar" and "" or msg:match("^bar%s+(.-)%s*$")
	if barArg then
		for _, line in ipairs(Bar.slash(barArg)) do
			print(line)
		end
		return
	end
	if msg == "reset" then
		ns.db.attempts = {}
		ns.db.nextId = 1
		R.attach(ns.db)
		print("PocketLog: log cleared.")
		return
	end
	for _, line in ipairs(ns.summaryLines()) do
		print(line)
	end
	if msg ~= "" then
		print("  /pocketlog reset clears the log; /pocketlog bar sets the pocket bar.")
	end
end

-- ---------------------------------------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------------------------------------
local handlers = {
	UNIT_SPELLCAST_SENT = R.onSpellSent,
	UNIT_SPELLCAST_SUCCEEDED = R.onSpellSucceeded,
	UNIT_SPELLCAST_FAILED = R.onSpellFailed,
	UNIT_SPELLCAST_FAILED_QUIET = R.onSpellFailed,
	UNIT_SPELLCAST_INTERRUPTED = R.onSpellInterrupted,
	UI_ERROR_MESSAGE = R.onUIError,
	LOOT_READY = R.onLootReady,
	LOOT_OPENED = R.onLootOpened,
	LOOT_SLOT_CLEARED = R.onLootSlotCleared,
	LOOT_SLOT_CHANGED = R.onLootSlotChanged,
	LOOT_CLOSED = R.onLootClosed,
	PLAYER_MONEY = R.onMoney,
	CVAR_UPDATE = R.onCVarUpdate,
	CHAT_MSG_MONEY = function(text)
		R.onChat("money", text)
	end,
	CHAT_MSG_LOOT = function(text)
		R.onChat("loot", text)
	end,
}
ns.handlers = handlers

local frame = CreateFrame("Frame")
ns.frame = frame
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, ...)
	R.stats.events = R.stats.events + 1
	if event == "ADDON_LOADED" then
		if ... == ADDON then
			ns.initDB(PocketLogDB)
			guard("bar.init", Bar.init, ns.db)
			for e in pairs(handlers) do
				frame:RegisterEvent(e)
			end
			for _, e in ipairs(Bar.EXTRA_EVENTS) do
				frame:RegisterEvent(e)
			end
		end
	elseif event == "PLAYER_LOGIN" then
		selftest.loadedAt = date("%Y-%m-%d %H:%M:%S")
		guard("resolveSpells", R.resolveSpells)
		guard("cvars", R.refreshCVars)
		guard("snapshot", selftest.snapshot, "login")
	elseif event == "PLAYER_LOGOUT" then
		guard("settleOpen", R.onLogout)
		guard("snapshot", selftest.snapshot, "logout")
	elseif ns.db then
		local fn = handlers[event]
		if fn then
			guard(event, fn, ...)
		end
		-- the bar reads what the recorder just recorded; its own guard, so a bar error never touches recording
		guard("bar:" .. event, Bar.onEvent, event, ...)
	end
end)
