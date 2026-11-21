local mock = require("tests.wow_mock")

describe("Logic", function()
	local L
	before_each(function()
		mock.install()
		L = mock.loadAddon(".").Logic
	end)

	local function money(slot, c)
		return { slot = slot, type = 2, money = c }
	end
	local function item(slot, id)
		return { slot = slot, type = 1, itemID = id }
	end

	describe("classifyAttempt", function()
		it("calls a fully looted window looted", function()
			local a = {
				result = "succeeded",
				pocket = {
					slots = { money(1, 120), item(2, 5432) },
					cleared = { [1] = true, [2] = true },
					closedAt = 1,
				},
			}
			assert.equal("looted", L.classifyAttempt(a, 100))
		end)

		it("calls a window closed with slots still there left", function()
			local a = {
				result = "succeeded",
				pocket = { slots = { money(1, 120), item(2, 5432) }, cleared = { [1] = true }, closedAt = 1 },
			}
			assert.equal("left", L.classifyAttempt(a, 100))
			assert.same({ item(2, 5432) }, L.slotsLeft(a.pocket))
		end)

		it("calls a success without any window never_shown once the wait is over", function()
			local a = { result = "succeeded", resultAt = 10, sentAt = 9.9 }
			assert.equal("pending", L.classifyAttempt(a, 11))
			assert.equal("never_shown", L.classifyAttempt(a, 14))
		end)

		it("calls the no-pockets and already-picked errors no_pockets, whatever the cast result", function()
			assert.equal("no_pockets", L.classifyAttempt({ result = "failed", errors = { { kind = "no_pockets" } } }))
			assert.equal(
				"no_pockets",
				L.classifyAttempt({ result = "succeeded", errors = { { kind = "already_picked" } } })
			)
		end)

		it("calls other failures failed and an empty window empty", function()
			assert.equal("failed", L.classifyAttempt({ result = "failed", errors = { { kind = "target_in_combat" } } }))
			assert.equal("failed", L.classifyAttempt({ result = "interrupted" }))
			assert.equal("empty", L.classifyAttempt({ result = "succeeded", pocket = { slots = {}, closedAt = 1 } }))
		end)

		it("keeps a window opened under the window wait ago pending", function()
			local a = { result = "succeeded", pocket = { readyAt = 99, slots = { money(1, 5) } } }
			assert.equal("pending", L.classifyAttempt(a, 100))
		end)
	end)

	describe("classifyCorpse", function()
		local leftPocket = { slots = { money(1, 87), item(2, 5432) }, cleared = {}, closedAt = 1 }

		it("is not_looted without corpse windows", function()
			assert.equal("not_looted", L.classifyCorpse({ corpse = {} }))
		end)

		it("is normal when the corpse holds none of the left-behind pocket loot", function()
			local a = { pocket = leftPocket, corpse = { { slots = { money(1, 300), item(2, 2589) } } } }
			assert.equal("normal", L.classifyCorpse(a))
		end)

		it("is normal_plus_pocket when the corpse holds a left pocket item", function()
			local a = { pocket = leftPocket, corpse = { { slots = { money(1, 300), item(2, 2589), item(3, 5432) } } } }
			assert.equal("normal_plus_pocket", L.classifyCorpse(a))
		end)

		it("is normal_plus_pocket when a corpse money slot equals the pocket's money", function()
			local a = { pocket = leftPocket, corpse = { { slots = { money(1, 87) } } } }
			assert.equal("normal_plus_pocket", L.classifyCorpse(a))
		end)

		it("is second_loot when two corpse windows had loot", function()
			local a = { corpse = { { slots = { money(1, 300) } }, { slots = { money(1, 87) } } } }
			assert.equal("second_loot", L.classifyCorpse(a))
		end)

		it("does not count an empty second window as a second loot", function()
			local a = { corpse = { { slots = { money(1, 300) } }, { slots = {} } } }
			assert.equal("normal", L.classifyCorpse(a))
		end)
	end)

	it("matches carried items once each", function()
		local m = L.matchCarryOver({ item(1, 7), item(2, 7), item(3, 9) }, { slots = { item(1, 7), item(2, 9) } })
		assert.equal(2, m.items)
		assert.equal(3, m.pocketItems)
		assert.equal("none", m.money)
	end)

	it("buckets numbers and marks missing ones", function()
		assert.equal("0-250", L.bucket(10, L.GAP_EDGES))
		assert.equal("500-1000", L.bucket(700, L.GAP_EDGES))
		assert.equal("2000+", L.bucket(5000, L.GAP_EDGES))
		assert.equal("n/a", L.bucket("secret", L.GAP_EDGES))
	end)

	it("summarizes outcomes, carry-over and pocket money", function()
		local attempts = {
			{
				result = "succeeded",
				sentAt = 1,
				pocket = { readyAt = 1.3, slots = { money(1, 50) }, cleared = { [1] = true }, closedAt = 2 },
				corpse = {},
			},
			{
				result = "succeeded",
				sentAt = 1,
				pocket = { readyAt = 1.3, slots = { item(1, 5432) }, cleared = {}, closedAt = 2 },
				corpse = { { slots = { item(1, 5432) } } },
				opener = { sentAt = 1.2 },
			},
			{
				result = "succeeded",
				resultAt = 1,
				sentAt = 1,
				corpse = { { slots = { money(1, 9) } }, { slots = { money(1, 4) } } },
			},
		}
		local s = L.summarize(attempts, 1000) -- past the corpse wait: no corpse is pending
		assert.equal(3, s.total)
		assert.equal(1, s.outcome.looted)
		assert.equal(1, s.outcome.left)
		assert.equal(1, s.outcome.never_shown)
		assert.equal(1, s.corpse.normal_plus_pocket)
		assert.equal(1, s.corpse.second_loot)
		assert.equal(1, s.corpse.not_looted)
		assert.equal(50, s.pocketMoney)
		assert.same({ left = 1, carried = 1, neverShown = 1, neverShownSecond = 1 }, s.carry)
		assert.equal(1, s.openerBeforeWindow)
	end)

	it("treats slot timings in cleared (0 included) as cleared, like the old true", function()
		local p = { slots = { money(1, 5), item(2, 7), item(3, 9) }, cleared = { [1] = 0, [2] = 420 }, closedAt = 1 }
		assert.same({ item(3, 9) }, L.slotsLeft(p))
	end)

	it("counts closedBy over pocket windows and shown / not shown by spell range", function()
		local attempts = {
			{
				result = "succeeded",
				range = { spell = true, interact = "blocked" },
				pocket = { slots = { money(1, 5) }, cleared = { [1] = 80 }, closedAt = 2, closedBy = "all_taken" },
				corpse = {},
			},
			{
				result = "succeeded",
				range = { spell = false },
				pocket = {
					slots = { money(1, 5), item(2, 7) },
					cleared = { [1] = 80 },
					closedAt = 2,
					closedBy = "opener",
				},
				corpse = { { slots = { money(1, 3) }, closedBy = "manual" } },
			},
			{ result = "succeeded", resultAt = 1, range = { spell = false }, corpse = {} },
			{ result = "succeeded", resultAt = 1, corpse = {} }, -- an old attempt without range
		}
		local s = L.summarize(attempts, 100)
		-- corpse windows don't count
		assert.same({ opener = 1, all_taken = 1, manual = 0, empty = 0, unknown = 0 }, s.closedBy)
		assert.same({ shown = 1, notShown = 0 }, s.range.inRange)
		assert.same({ shown = 1, notShown = 1 }, s.range.outOfRange)
		assert.same({ shown = 0, notShown = 1 }, s.range.unknown)
	end)

	describe("pending corpse", function()
		it("is pending within the corpse wait, not_looted after it, before a reboot or without a clock", function()
			local a = { result = "succeeded", sentAt = 100, corpse = {} }
			assert.equal("pending", L.classifyCorpse(a, 150))
			assert.equal("not_looted", L.classifyCorpse(a, 100 + L.CORPSE_WAIT))
			assert.equal("not_looted", L.classifyCorpse(a, 5)) -- clock restarted
			assert.equal("not_looted", L.classifyCorpse(a, nil))
			assert.equal("pending", L.classifyCorpse(a, 105, 10))
		end)

		it("keeps attempts with a pending corpse out of the carry-over counts", function()
			local leftPocket = { closedAt = 101, slots = { item(1, 5432) }, cleared = {} }
			local attempts = {
				{ result = "succeeded", sentAt = 100, pocket = leftPocket, corpse = {} },
				{ result = "succeeded", sentAt = 100, resultAt = 100.1, corpse = {} },
			}
			local s = L.summarize(attempts, 150)
			assert.equal(2, s.corpse.pending)
			assert.equal(0, s.corpse.not_looted)
			assert.same({ left = 0, carried = 0, neverShown = 0, neverShownSecond = 0 }, s.carry)
			s = L.summarize(attempts, 1000)
			assert.same({ left = 1, carried = 0, neverShown = 1, neverShownSecond = 0 }, s.carry)
		end)
	end)

	-- The same cases tools/pocketlog_report.py is tested against in the scaffolding (companion/tests).
	it("classifies every shared parity case as the fixture says", function()
		local chunk = assert(loadfile("tests/fixtures/classify_cases.lua"))
		local env = {}
		setfenv(chunk, env)
		chunk()
		local cases = env.PocketLogClassifyCases
		assert.is_true(#cases >= 25)
		for _, c in ipairs(cases) do
			assert.equal(c.outcome, L.classifyAttempt(c.attempt, c.now), c.name)
			assert.equal(c.corpse, L.classifyCorpse(c.attempt, c.now), c.name)
		end
		-- the report falls back to these for saves without selftest.waits; pytest checks its side
		assert.same({ attempt = L.ATTEMPT_WAIT, corpse = L.CORPSE_WAIT, window = L.WINDOW_WAIT }, env.PocketLogWaits)
	end)

	describe("unclosed window", function()
		local function open(readyAt, extra)
			local p = { readyAt = readyAt, slots = { item(1, 5432) }, cleared = {} }
			for k, v in pairs(extra or {}) do
				p[k] = v
			end
			return { result = "succeeded", sentAt = readyAt - 0.3, pocket = p, corpse = {} }
		end

		it("is pending within the window wait only", function()
			assert.equal("pending", L.classifyAttempt(open(990), 1000))
			assert.equal("left", L.classifyAttempt(open(900), 1000))
			assert.equal("left", L.classifyAttempt(open(990), 5)) -- clock restarted
			assert.equal("left", L.classifyAttempt(open(990), nil)) -- no clock in the save
			assert.equal("pending", L.classifyAttempt(open(900), 1000, nil, 200)) -- the wait from the caller
		end)

		it("is settled at once when Recorder marked it closedBy unknown", function()
			assert.equal("left", L.classifyAttempt(open(999, { closedBy = "unknown" }), 1000))
			local s = L.summarize({ open(999, { closedBy = "unknown" }) }, 1000)
			assert.equal(1, s.closedBy.unknown)
			assert.equal(1, s.outcome.left)
			assert.equal(0, s.outcome.pending)
		end)
	end)
end)
