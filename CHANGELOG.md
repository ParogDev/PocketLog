# Changelog

## 0.2.0

- Records movement (moving, speed, falling) at the Pick Pocket send, its success and the opener; `/pocketlog` shows window shown / not shown for still vs moving.
- The opener is the first real opener (Cheap Shot, Ambush, Garrote, Sap); an unrelated spell before it goes in `nextCast`.
- Attempts saved before a PC reboot no longer count as pending or as a fresh pocket window (the precise clock restarts).
- An empty loot window counts as the pocket only within 5 s of the cast on the same target.
- A loot window whose close event was missed is closed when the next one opens, instead of swallowing it.

## 0.1.0

- First version: logs Pick Pocket casts, errors, openers, pocket and corpse loot windows, latency and money to `PocketLogDB`, classifies each attempt, `/pocketlog` summary, selftest snapshot on login and logout.
