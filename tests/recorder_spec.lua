local mock = require("tests.wow_mock")

describe("Recorder", function()
	local ns, db
	local MOB = "Creature-0-1-0-1-2585-0000ABCD"

	before_each(function()
		mock.install()
		ns = mock.loadAddon(".")
		db = ns.db
		mock.target = { guid = MOB, name = "Stromgarde Soldier", level = 38, dead = false }
	end)

	local function pickpocket(castGUID)
		mock.fire("UNIT_SPELLCAST_SENT", "player", "Stromgarde Soldier", castGUID, 921)
		mock.advance(0.1)
	end

	local function openLoot(slots, cleared)
		mock.loot = slots
		mock.fire("LOOT_READY", false)
		mock.fire("LOOT_OPENED", false)
		for _, i in ipairs(cleared or {}) do
			mock.fire("LOOT_SLOT_CLEARED", i)
		end
		mock.advance(0.5)
		mock.fire("LOOT_CLOSED")
		mock.loot = {}
	end

	it("resolves Pick Pocket and the openers through C_Spell by name", function()
		assert.equal(921, ns.Recorder.resolved.pickpocket.spellID)
		assert.equal("name", ns.Recorder.resolved.pickpocket.how)
		assert.equal(1833, ns.Recorder.resolved.cheapShot.spellID)
	end)

	it("records a looted pickpocket with latency, slots and money", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.advance(0.2)
		openLoot({ mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432, "Hickory Shortbow") }, { 1, 2 })
		local a = db.attempts[1]
		assert.equal(MOB, a.guid)
		assert.equal("succeeded", a.result)
		assert.equal(100, a.resultMs)
		assert.same({ home = 40, world = 60 }, a.lat)
		assert.equal(87, a.pocket.slots[1].money)
		assert.equal(5432, a.pocket.slots[2].itemID)
		assert.equal(300, a.pocket.dtMs)
		assert.same({}, a.pocket.left)
		assert.equal("looted", ns.Logic.classifyAttempt(a, mock.clock))
	end)

	it("records the opener and its gap after the cast succeeded", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.advance(0.35)
		mock.fire("UNIT_SPELLCAST_SENT", "player", "Stromgarde Soldier", "Cast-2", 1833)
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", 1833)
		local a = db.attempts[1]
		assert.equal("Cheap Shot", a.opener.name)
		assert.is_true(a.opener.isOpener)
		assert.equal(350, a.opener.dtMs)
		assert.equal(450, a.opener.dtFromSentMs)
		assert.equal("succeeded", a.opener.result)
		assert.is_true(a.opener.sameTarget)
		assert.equal(1, #db.attempts) -- the opener is not an attempt
		assert.equal("never_shown", ns.Logic.classifyAttempt(a, mock.clock + 5))
	end)

	it("classifies a window closed with loot left, then finds that loot on the corpse", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		openLoot({ mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }, { 1 })
		local a = db.attempts[1]
		assert.same({ 2 }, a.pocket.left)
		assert.equal("left", ns.Logic.classifyAttempt(a, mock.clock))
		-- the fight, then the corpse
		mock.advance(20)
		mock.target.dead = true
		openLoot({ mock.moneySlot(MOB, 310), mock.itemSlot(MOB, 5432) }, { 1, 2 })
		assert.equal(1, #a.corpse)
		assert.is_true(a.corpse[1].targetDead)
		assert.equal("normal_plus_pocket", ns.Logic.classifyCorpse(a))
	end)

	it("counts a second corpse window of the same mob as second_loot", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.advance(20)
		mock.target.dead = true
		openLoot({ mock.moneySlot(MOB, 310) }, { 1 })
		mock.advance(1)
		openLoot({ mock.moneySlot(MOB, 87) }, { 1 })
		local a = db.attempts[1]
		assert.equal("never_shown", ns.Logic.classifyAttempt(a, mock.clock))
		assert.equal(2, #a.corpse)
		assert.equal("second_loot", ns.Logic.classifyCorpse(a))
	end)

	it("pins the no-pockets error on the attempt", function()
		pickpocket("Cast-1")
		mock.fire("UI_ERROR_MESSAGE", 51, "No pockets to pick")
		mock.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-1", 921)
		local a = db.attempts[1]
		assert.equal("no_pockets", a.errors[1].kind)
		assert.equal("failed", a.result)
		assert.equal("no_pockets", ns.Logic.classifyAttempt(a, mock.clock))
	end)

	it("pins an error after the in-between spell on nextCast, not on the attempt", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 1752)
		mock.advance(0.1)
		mock.fire("UI_ERROR_MESSAGE", 50, "Out of range")
		local a = db.attempts[1]
		assert.same({}, a.errors)
		assert.equal("out_of_range", a.nextCast.errors[1].kind)
		assert.equal(100, a.nextCast.errors[1].dtMs)
		-- the opener sent after it takes the errors that follow
		mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-3", 1833)
		mock.advance(0.1)
		mock.fire("UI_ERROR_MESSAGE", 50, "Out of range")
		assert.equal(1, #a.nextCast.errors)
		assert.equal("out_of_range", a.opener.errors[1].kind)
		assert.same({}, a.errors)
	end)

	it("records a client-side failure without SENT, with the error that came first", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.advance(0.5)
		mock.fire("UI_ERROR_MESSAGE", 50, "Out of range")
		mock.fire("UNIT_SPELLCAST_FAILED", "player", "Cast-9", 921)
		assert.equal(2, #db.attempts)
		assert.same({}, db.attempts[1].errors)
		local b = db.attempts[2]
		assert.is_true(b.clientSide)
		assert.equal("out_of_range", b.errors[1].kind)
		assert.equal("failed", ns.Logic.classifyAttempt(b, mock.clock))
	end)

	it("adds money that reached the bags to the open window", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.loot = { mock.moneySlot(MOB, 87) }
		mock.fire("LOOT_READY", true)
		mock.money = 87
		mock.fire("PLAYER_MONEY")
		mock.fire("CHAT_MSG_MONEY", "You loot 87 Copper")
		mock.fire("LOOT_SLOT_CLEARED", 1)
		mock.fire("LOOT_CLOSED")
		local p = db.attempts[1].pocket
		assert.equal(87, p.money)
		assert.equal("You loot 87 Copper", p.chat[1].text)
		assert.is_true(p.autoloot)
	end)

	it("stores 'secret' instead of a secret value and skips secret casts", function()
		mock.secret["Cast-S"] = true
		mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-S", 921)
		assert.equal(0, #db.attempts)
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		local secretText = "You loot 1 Copper"
		mock.secret[secretText] = true
		mock.loot = { mock.moneySlot(MOB, 1) }
		mock.fire("LOOT_READY", false)
		mock.fire("CHAT_MSG_MONEY", secretText)
		mock.fire("LOOT_CLOSED")
		assert.equal("secret", db.attempts[1].pocket.chat[1].text)
		assert.is_true(ns.Recorder.stats.secret >= 2)
		assert.is_nil(ns.selftest.lastError)
	end)

	it("ignores Pick Pocket inside an instance", function()
		mock.inInstance = true
		pickpocket("Cast-1")
		assert.equal(0, #db.attempts)
		assert.equal(1, ns.Recorder.stats.skippedInstance)
	end)

	it("re-indexes saved attempts so a corpse after a reload still finds its pickpocket", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		local saved = db
		mock.frames = {} -- the reload: the old event frame is gone
		ns = mock.loadAddon(".", saved)
		mock.advance(30)
		mock.target.dead = true
		openLoot({ mock.moneySlot(MOB, 310) }, { 1 })
		assert.equal(1, #ns.db.attempts[1].corpse)
	end)

	it("records movement at the Pick Pocket send, its success and the opener", function()
		mock.speed = 7
		pickpocket("Cast-1")
		mock.speed = 0
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 6770)
		local a = db.attempts[1]
		assert.same({ moving = true, speed = 7, falling = false }, a.move)
		assert.same({ moving = false, speed = 0, falling = false }, a.moveAtResult)
		assert.equal(0, a.opener.move.speed)
		assert.equal("moving", ns.Logic.movement(a))
		local s = ns.Logic.summarize(db.attempts, mock.clock + 5)
		assert.same({ shown = 0, notShown = 1 }, s.move.moving)
	end)

	it("stores a secret speed as 'secret'", function()
		mock.speed = 3
		mock.secret[3] = true
		pickpocket("Cast-1")
		assert.equal("secret", db.attempts[1].move.speed)
		assert.equal("moving", ns.Logic.movement(db.attempts[1])) -- IsPlayerMoving still answered
	end)

	it("keeps looking for the real opener past an unrelated spell", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 1752)
		mock.advance(0.4)
		mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-3", 1833)
		local a = db.attempts[1]
		assert.equal("Sinister Strike", a.nextCast.name)
		assert.equal("Cheap Shot", a.opener.name)
	end)

	it("does not take an empty window long after the cast as the pocket", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.advance(600)
		openLoot({}, {})
		local a = db.attempts[1]
		assert.is_nil(a.pocket)
		assert.equal(0, #a.corpse)
		assert.equal(1, ns.Recorder.stats.orphanLoot)
	end)

	it("treats attempts saved before a reboot (clock restarted) as old", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		mock.frames = {}
		mock.clock = 5 -- GetTimePreciseSec after a reboot
		ns = mock.loadAddon(".", db)
		local a = ns.db.attempts[1]
		assert.equal("never_shown", ns.Logic.classifyAttempt(a, mock.clock))
		openLoot({ mock.moneySlot(MOB, 87) }, { 1 })
		assert.is_nil(a.pocket)
		assert.equal(1, #a.corpse)
	end)

	it("closes a window whose LOOT_CLOSED was missed when the next one opens", function()
		mock.loot = { mock.moneySlot("Creature-0-1-0-1-99-0", 5) }
		mock.fire("LOOT_READY", false)
		mock.advance(120)
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		openLoot({ mock.moneySlot(MOB, 87) }, { 1 })
		assert.is_not_nil(db.attempts[1].pocket)
		assert.equal(1, ns.Recorder.stats.closeMissed)
	end)

	it("prints a summary and writes a selftest snapshot on logout", function()
		pickpocket("Cast-1")
		mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 921)
		openLoot({ mock.moneySlot(MOB, 12345) }, { 1 })
		SlashCmdList.POCKETLOG("")
		assert.matches("1 attempts", mock.chat[1])
		assert.matches("looted 1", mock.chat[2])
		assert.matches("1g 23s 45c", mock.chat[4])
		mock.fire("PLAYER_LOGOUT")
		assert.equal("test", db.selftest.version)
		assert.equal("logout", db.selftest.phase)
		assert.equal(1, db.selftest.summary.outcome.looted)
	end)

	describe("0.3.0 fields", function()
		local function castAndSucceed(castGUID)
			pickpocket(castGUID)
			mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", castGUID, 921)
			mock.advance(0.2)
		end

		it("stamps the spell queue window, range and location on the attempt", function()
			castAndSucceed("Cast-1")
			local a = db.attempts[1]
			assert.equal("400", a.sqw)
			assert.same({ spell = true, interact = true }, a.range)
			assert.same({ mapID = 1417, x = 0.457, y = 0.612, subzone = "Stromgarde Keep" }, a.loc)
			mock.fire("PLAYER_LOGOUT")
			assert.equal("400", db.selftest.cvars.spellQueueWindow)
		end)

		it("refreshes the spell queue window on CVAR_UPDATE only for that CVar", function()
			mock.cvars.SpellQueueWindow = "150"
			mock.fire("CVAR_UPDATE", "autoLootDefault", "1")
			pickpocket("Cast-1")
			assert.equal("400", db.attempts[1].sqw)
			mock.fire("CVAR_UPDATE", "SpellQueueWindow", "150")
			pickpocket("Cast-2")
			assert.equal("150", db.attempts[2].sqw)
		end)

		it("stores a nil position as no x/y and an out-of-range cast as false", function()
			mock.pos = nil
			mock.inSpellRange = false
			mock.interact = false
			pickpocket("Cast-1")
			local a = db.attempts[1]
			assert.is_nil(a.loc.x)
			assert.is_nil(a.loc.y)
			assert.equal(1417, a.loc.mapID)
			assert.same({ spell = false, interact = false }, a.range)
			assert.equal("outOfRange", ns.Logic.range(a))
		end)

		it("records 'blocked' when CheckInteractDistance is protected", function()
			mock.interactBlocked = true
			pickpocket("Cast-1")
			assert.equal("blocked", db.attempts[1].range.interact)
			assert.is_true(db.attempts[1].range.spell)
			assert.is_nil(ns.selftest.lastError)
		end)

		it("stores secret subzone, range and CVar values as 'secret'", function()
			mock.subzone = "Hidden Place"
			mock.secret["Hidden Place"] = true
			mock.cvars.autoLootRate = "secret-rate"
			mock.secret["secret-rate"] = true
			mock.inSpellRange = "secret-range"
			mock.secret["secret-range"] = true
			castAndSucceed("Cast-1")
			openLoot({ mock.moneySlot(MOB, 87) }, { 1 })
			local a = db.attempts[1]
			assert.equal("secret", a.loc.subzone)
			assert.equal("secret", a.range.spell)
			assert.equal("unknown", ns.Logic.range(a))
			assert.equal("secret", a.pocket.autoLootRate)
			assert.is_nil(ns.selftest.lastError)
		end)

		it("records auto-loot state, slot timings and slot changes in the window", function()
			mock.modifiers.AUTOLOOTTOGGLE = true
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", true)
			mock.advance(0.15)
			mock.fire("LOOT_SLOT_CLEARED", 1)
			mock.fire("LOOT_SLOT_CHANGED", 2)
			mock.advance(0.1)
			mock.fire("LOOT_SLOT_CLEARED", 2)
			mock.fire("LOOT_CLOSED")
			local p = db.attempts[1].pocket
			assert.equal("1", p.autoLootDefault)
			assert.equal("150", p.autoLootRate)
			assert.is_true(p.autoLootToggle)
			assert.same({ [1] = 150, [2] = 250 }, p.cleared)
			assert.same({ { slot = 2, dtMs = 150 } }, p.changed)
			assert.equal("all_taken", p.closedBy)
			assert.equal("looted", ns.Logic.classifyAttempt(db.attempts[1], mock.clock))
		end)

		it("guesses opener when the opener is sent while the window is open with loot left", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", false)
			mock.fire("LOOT_SLOT_CLEARED", 1)
			mock.advance(0.1)
			mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 1833)
			mock.advance(0.05)
			mock.fire("LOOT_CLOSED")
			local p = db.attempts[1].pocket
			assert.equal("opener", p.closedBy)
			assert.equal(50, p.closeVsOpenerMs)
			assert.is_nil(p.closeVsOpenerResultMs)
			-- the opener's result after the close fills in the second gap
			mock.advance(0.1)
			mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", 1833)
			assert.equal(-100, p.closeVsOpenerResultMs)
			assert.equal(1, ns.Logic.summarize(db.attempts, mock.clock).closedBy.opener)
		end)

		it("guesses opener when the opener SENT lands just after LOOT_CLOSED", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", false)
			mock.advance(0.3)
			mock.fire("LOOT_CLOSED")
			local p = db.attempts[1].pocket
			assert.equal("manual", p.closedBy)
			assert.is_nil(p.closeVsOpenerMs)
			mock.advance(0.2)
			mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 6770)
			assert.equal("opener", p.closedBy)
			assert.equal(-200, p.closeVsOpenerMs)
		end)

		it("guesses manual when loot is left and no opener came near the close", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", false)
			mock.fire("LOOT_SLOT_CLEARED", 1)
			mock.advance(1)
			mock.fire("LOOT_CLOSED")
			mock.advance(1)
			mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 1833)
			local p = db.attempts[1].pocket
			assert.equal("manual", p.closedBy)
			assert.equal(-1000, p.closeVsOpenerMs)
			local s = ns.Logic.summarize(db.attempts, mock.clock)
			assert.same({ opener = 0, all_taken = 0, manual = 1, empty = 0 }, s.closedBy)
			assert.same({ shown = 1, notShown = 0 }, s.range.inRange)
		end)

		it("calls a window with no slots empty, not all_taken", function()
			castAndSucceed("Cast-1")
			openLoot({}, {})
			assert.equal("empty", db.attempts[1].pocket.closedBy)
		end)

		it("records missing CheckInteractDistance and C_Map without losing the attempt", function()
			_G.CheckInteractDistance = nil
			_G.C_Map = nil
			castAndSucceed("Cast-1")
			local a = db.attempts[1]
			assert.equal("missing", a.range.interact)
			assert.equal("C_Map", a.loc.missing)
		end)

		it("judges a late opener against its own mob's window after another window closed", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", false)
			mock.fire("LOOT_SLOT_CLEARED", 1)
			mock.advance(0.3)
			mock.fire("LOOT_CLOSED")
			local p = db.attempts[1].pocket
			assert.equal("manual", p.closedBy)
			-- another mob's window (no attempt of its own) opens and closes before the opener's SENT
			mock.advance(0.05)
			mock.loot = { mock.moneySlot("Creature-0-1-0-1-99-0", 5) }
			mock.fire("LOOT_READY", false)
			mock.advance(0.05)
			mock.fire("LOOT_CLOSED")
			mock.advance(0.1)
			mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 1833)
			assert.equal("opener", p.closedBy)
			assert.equal(-200, p.closeVsOpenerMs)
			mock.fire("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-2", 1833)
			assert.equal(-200, p.closeVsOpenerResultMs)
		end)

		it("does not credit an opener cast at another target with closing the window", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", false)
			mock.fire("LOOT_SLOT_CLEARED", 1)
			mock.advance(0.1)
			mock.target = { guid = "Creature-0-1-0-1-77-0", name = "Other", level = 38, dead = false }
			mock.fire("UNIT_SPELLCAST_SENT", "player", "x", "Cast-2", 1833)
			mock.advance(0.05)
			mock.fire("LOOT_CLOSED")
			local a = db.attempts[1]
			assert.is_false(a.opener.sameTarget)
			assert.equal("manual", a.pocket.closedBy)
		end)

		it("takes a LOOT_READY re-fire of the same window past 60 s as the same window", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87), mock.itemSlot(MOB, 5432) }
			mock.fire("LOOT_READY", false)
			mock.fire("LOOT_SLOT_CLEARED", 1)
			mock.advance(61)
			mock.fire("LOOT_READY", false)
			local a = db.attempts[1]
			assert.equal(0, ns.Recorder.stats.closeMissed)
			assert.equal(1, ns.Recorder.stats.repeatReady)
			assert.is_nil(a.pocket.closedAt)
			assert.is_nil(a.pocket.closeMissed)
			mock.fire("LOOT_CLOSED")
			assert.equal(0, #a.corpse)
			assert.same({ 2 }, a.pocket.left)
		end)

		it("still calls a stale window with another mob's loot a missed close", function()
			castAndSucceed("Cast-1")
			mock.loot = { mock.moneySlot(MOB, 87) }
			mock.fire("LOOT_READY", false)
			mock.advance(61)
			mock.loot = { mock.moneySlot(MOB, 87), mock.moneySlot("Creature-0-1-0-1-77-0", 5) }
			assert.is_false(ns.Recorder.sameWindow(db.attempts[1].pocket, { { sources = {} } }))
			mock.fire("LOOT_READY", false)
			assert.equal(1, ns.Recorder.stats.closeMissed)
			assert.is_true(db.attempts[1].pocket.closeMissed)
		end)

		it("prints the unknown movement bucket in /pocketlog", function()
			_G.IsPlayerMoving, _G.GetUnitSpeed, _G.IsFalling = nil, nil, nil
			castAndSucceed("Cast-1")
			openLoot({ mock.moneySlot(MOB, 87) }, { 1 })
			SlashCmdList.POCKETLOG("")
			local line
			for _, l in ipairs(mock.chat) do
				if l:find("window shown / not shown:", 1, true) then
					line = l
				end
			end
			assert.equal("  window shown / not shown: still 0/0, moving 0/0, unknown 1/0", line)
		end)

		it("reports the code version when the .toc carries the packager's token, and the clock at the save", function()
			_G.C_AddOns.GetAddOnMetadata = function()
				return "@project-version@"
			end
			mock.fire("PLAYER_LOGOUT")
			assert.equal(ns.VERSION, db.selftest.version)
			assert.equal(mock.clock, db.selftest.clock)
		end)

		it("prints the closed-by and range lines in /pocketlog", function()
			castAndSucceed("Cast-1")
			openLoot({ mock.moneySlot(MOB, 87) }, { 1 })
			SlashCmdList.POCKETLOG("")
			assert.matches("closed by: opener 0, all taken 1, manual 0, empty 0", mock.chat[#mock.chat - 1], 1, true)
			assert.matches("by range: in 1/0, out 0/0, unknown 0/0", mock.chat[#mock.chat], 1, true)
		end)
	end)
end)
