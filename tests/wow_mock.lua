-- Minimal WoW client globals so the addon loads under busted, plus a scriptable world: a clock, a target,
-- a loot window and money. Dumb tables, not a client; the real check is the in-game reload.
local M = {}

local function noop() end

local function newFrame()
	local f = { _events = {} }
	function f:RegisterEvent(e)
		self._events[e] = true
	end
	function f:UnregisterEvent(e)
		self._events[e] = nil
	end
	function f:SetScript(k, fn)
		self["_" .. k] = fn
	end
	M.frames[#M.frames + 1] = f
	return f
end

function M.install()
	M.frames = {}
	M.clock = 1000
	M.secret = {}
	M.chat = {}
	M.target = nil -- { guid, name, level, dead }
	M.loot = {} -- slots: { type, name, qty, link, quality, isCoin, sources = { guid, qty, ... } }
	M.money = 0
	M.inInstance = false
	M.latency = { 40, 60 }
	M.spells = {
		[921] = "Pick Pocket",
		[1833] = "Cheap Shot",
		[8676] = "Ambush",
		[703] = "Garrote",
		[6770] = "Sap",
		[1752] = "Sinister Strike",
	}
	_G.CreateFrame = newFrame
	_G.DEFAULT_CHAT_FRAME = {
		AddMessage = function(_, line)
			M.chat[#M.chat + 1] = line
		end,
	}
	_G.SlashCmdList = {}
	_G.WOW_PROJECT_ID = 18
	_G.GetBuildInfo = function()
		return "1.60.1", "70790", "Nov 4 2026", 16001
	end
	_G.C_AddOns = {
		GetAddOnMetadata = function()
			return "test"
		end,
	}
	_G.date = function(fmt)
		return os.date(fmt)
	end
	_G.time = os.time
	_G.issecretvalue = function(v)
		return v ~= nil and M.secret[v] == true
	end
	_G.GetTimePreciseSec = function()
		return M.clock
	end
	_G.GetNetStats = function()
		return 0, 0, M.latency[1], M.latency[2]
	end
	_G.IsInInstance = function()
		return M.inInstance, M.inInstance and "party" or "none"
	end
	_G.GetRealZoneText = function()
		return "Arathi Highlands"
	end
	_G.UnitGUID = function(unit)
		return unit == "target" and M.target and M.target.guid or nil
	end
	_G.UnitName = function(unit)
		return unit == "target" and M.target and M.target.name or nil
	end
	_G.UnitLevel = function(unit)
		return unit == "target" and M.target and M.target.level or nil
	end
	_G.UnitClassification = function()
		return "normal"
	end
	_G.UnitIsDead = function(unit)
		return unit == "target" and M.target and M.target.dead or false
	end
	local byName = {}
	for id, n in pairs(M.spells) do
		byName[n] = id
	end
	_G.C_Spell = {
		GetSpellInfo = function(q)
			local id = type(q) == "number" and q or byName[q]
			if id and M.spells[id] then
				return { spellID = id, name = M.spells[id] }
			end
			return nil
		end,
		GetSpellName = function(id)
			return M.spells[id]
		end,
	}
	_G.Enum = { LootSlotType = { None = 0, Item = 1, Money = 2, Currency = 3 } }
	_G.GetNumLootItems = function()
		return #M.loot
	end
	_G.GetLootSlotType = function(i)
		return M.loot[i] and M.loot[i].type or 0
	end
	_G.GetLootSlotInfo = function(i)
		local s = M.loot[i]
		if not s then
			return nil
		end
		return "tex", s.name, s.qty or 1, nil, s.quality or 1, false, false, nil, false, s.type == 2
	end
	_G.GetLootSlotLink = function(i)
		return M.loot[i] and M.loot[i].link or nil
	end
	_G.GetLootSourceInfo = function(i)
		local s = M.loot[i]
		if not s then
			return nil
		end
		return unpack(s.sources or {})
	end
	_G.GetMoney = function()
		return M.money
	end
	_G.SPELL_FAILED_TARGET_NO_POCKETS = "No pockets to pick"
	_G.ERR_ALREADY_PICKPOCKETED = "Your target has already had its pockets picked"
	_G.SPELL_FAILED_TARGET_AFFECTING_COMBAT = "Target is in combat"
	_G.SPELL_FAILED_OUT_OF_RANGE = "Out of range"
	_G.ERR_OUT_OF_RANGE = "Out of range."
	_G.SPELL_FAILED_ONLY_STEALTHED = "You must be in stealth mode."
	_G.SPELL_FAILED_NOT_BEHIND = "You must be behind your target."
	_G.SPELL_FAILED_UNIT_NOT_INFRONT = "Target needs to be in front of you."
	_G.PocketLog = nil
	_G.PocketLogDB = nil
	return M
end

-- Loads the addon in TOC order with (ADDON_NAME, namespace) as varargs, then fires ADDON_LOADED and
-- PLAYER_LOGIN the way the client does.
function M.loadAddon(dir, saved)
	local ns = {}
	for _, f in ipairs({ "Logic.lua", "Recorder.lua", "Core.lua" }) do
		local chunk, err = loadfile(dir .. "/" .. f)
		assert(chunk, err)
		chunk("PocketLog", ns)
	end
	_G.PocketLogDB = saved
	M.fire("ADDON_LOADED", "PocketLog")
	M.fire("PLAYER_LOGIN")
	M.ns = ns
	return ns
end

function M.fire(event, ...)
	for _, f in ipairs(M.frames) do
		if f._OnEvent and (f._events[event] or event == "ADDON_LOADED") then
			f._OnEvent(f, event, ...)
		end
	end
end

function M.advance(sec)
	M.clock = M.clock + sec
end

-- A money slot from one source.
function M.moneySlot(guid, copper)
	return { type = 2, name = copper .. " Copper", qty = 0, sources = { guid, copper } }
end

function M.itemSlot(guid, itemID, name)
	return {
		type = 1,
		name = name or ("item" .. itemID),
		link = "|cffffffff|Hitem:" .. itemID .. "::::::::39:::::|h[" .. (name or "x") .. "]|h|r",
		sources = { guid, 1 },
	}
end

M.noop = noop
return M
