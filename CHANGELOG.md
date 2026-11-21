# Changelog

## 0.4.0

- The pocket bar (`Bar.lua`): a 1400 ms timeline from the Pick Pocket cast with the 250 ms dead zone, a fill that grows from the cast, a gate line that snaps to the predicted end of auto loot when the window opens, one pip per loot slot, and world latency. At the close with everything taken (or no window by 600 ms plus world latency) it turns yellow, `Open now`, and drains over 3 s. The next press shows `Opened` or `Too early` with the ms. Amber with a warning when you moved at the cast. A target change clears it. Display only; nothing in instances.
- `/pocketlog bar on | off | lock | unlock | reset | drain <seconds>`; the settings and position are saved in `PocketLogDB.bar`.
- The selftest has `bar` counters: started, released by loot closed (`lootClosed`, split into `ready` and `left`), by the timeout (`timeout`), presses `opened` and `early`, and windows open too long (`stale`).
- New file in the `.toc`: the first load needs a client restart.

## 0.3.3

- A loot window that never got `LOOT_CLOSED` (open at a reload, a logout, a disconnect or a crash) is settled at the next load and at logout: `closedBy = "unknown"`, `left` from the slots not taken while it was open, no `closedAt`. Such a window used to stay `pending` in the summary and the report forever. `Recorder.stats.closeUnknown` counts them; `/pocketlog` prints `unknown` in the closed-by line.
- An unclosed window counts as `pending` only for 60 s after it opened (`Logic.WINDOW_WAIT`, the same limit Recorder already used for a missed close), and never in a save without a clock.
- The selftest records `waits` (`attempt`, `corpse`, `window`, in seconds), so the scaffolding's report classifies with the addon's own waits. `tests/fixtures/classify_cases.lua` gains `PocketLogWaits` and the unclosed-window cases.

## 0.3.2

- A UI error goes to the latest cast sent within 1.5 s: the opener, the spell cast between the Pick Pocket and the opener (`nextCast.errors`), or the Pick Pocket itself. Before, an error after that in-between spell was filed on the Pick Pocket.

## 0.3.1

- An opener that arrives after its window closed is judged against every window of its own attempt closed in the last 10 s, not only the latest closed window, so another mob's window closing in between no longer leaves `closedBy` at `manual`.
- An opener cast at a different target (`sameTarget` false) no longer counts as what closed the window.
- A loot window open over 60 s that fires `LOOT_READY` again with the same mobs' loot is the same window (`repeatReady`), not a missed close.
- Corpse outcome `pending`: no corpse window yet and the Pick Pocket less than 120 s old. Pending corpses stay out of the carry-over counts.
- `/pocketlog` prints the `unknown` movement bucket.
- The selftest records `clock` (GetTimePreciseSec at the save), so the report can tell pending attempts, and `version` falls back to the code's version when the `.toc` holds the packager token.
- `tests/fixtures/classify_cases.lua`: classifier cases shared with the scaffolding's report script test.

## 0.3.0

- Each loot window records a guess at what closed it (`closedBy`: `opener`, `all_taken` or `manual`) and how far the close was from the opener's send and result. `/pocketlog` prints the counts for pocket windows.
- Loot windows record the auto-loot CVars (`autoLootDefault`, `autoLootRate`), whether the auto-loot toggle modifier was held, when each slot was taken (ms after the window was ready, in `cleared`) and every `LOOT_SLOT_CHANGED`.
- Each attempt records the SpellQueueWindow CVar (`sqw`, read at login and on `CVAR_UPDATE`; also in the selftest), the range at the cast (`C_Spell.IsSpellInRange` and `CheckInteractDistance`, `blocked` when the client refuses it) and the location (map, x/y, subzone).
- `/pocketlog` prints window shown / not shown by spell range.

## 0.2.0

- Records movement (moving, speed, falling) at the Pick Pocket send, its success and the opener; `/pocketlog` shows window shown / not shown for still vs moving.
- The opener is the first real opener (Cheap Shot, Ambush, Garrote, Sap); an unrelated spell before it goes in `nextCast`.
- Attempts saved before a PC reboot no longer count as pending or as a fresh pocket window (the precise clock restarts).
- An empty loot window counts as the pocket only within 5 s of the cast on the same target.
- A loot window whose close event was missed is closed when the next one opens, instead of swallowing it.

## 0.1.0

- First version: logs Pick Pocket casts, errors, openers, pocket and corpse loot windows, latency and money to `PocketLogDB`, classifies each attempt, `/pocketlog` summary, selftest snapshot on login and logout.
