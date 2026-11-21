# PocketLog

A measuring addon for WoW: Forever rogues. It logs every Pick Pocket and the later corpse loot of the same mob, so you can find out what really happens when the pocket window is closed with loot still in it, never shows up, or is cut off by the opener.

It changes nothing in the game and draws no UI. Badges, refill timers and haul totals are what Kaydee's Pockets does; this addon only records.

## What it records

Per Pick Pocket cast (open world only):

- the cast: sent, succeeded, failed or interrupted, with times in ms, and home/world latency from `GetNetStats`
- UI errors that belong to it (no pockets, already picked, target in combat, out of range, not stealthed)
- the next spell you cast (the opener: Cheap Shot, Ambush, Garrote, Sap, or whatever came next) and the gap
- the pocket loot window: each slot's type, name, item, money and source GUIDs, autoloot, and which slots were still there when it closed
- the corpse loot of the same mob later, every window of it, with the same fields
- money that reached your bags and the loot/money chat lines while a window was open

Values the client hands over as secrets are stored as `"secret"`.

Each attempt is classified:

- Pick Pocket: `looted`, `left` (window closed with loot left), `empty`, `never_shown`, `no_pockets`, `failed`
- Corpse: `normal`, `normal_plus_pocket` (the corpse held what the pocket left behind), `second_loot` (the corpse could be looted twice), `not_looted`

## Use

Farm as usual. `/pocketlog` prints a summary; `/pocketlog reset` clears the log. The data is in `WTF/Account/<account>/SavedVariables/PocketLog.lua` after a `/reload` or logout. The scaffolding repo's `tools/pocketlog_report.py` turns it into tables.

## Development

Lua 5.1 with the Forever (Mainline 12.1) API. `luacheck .`, `busted`, `stylua --check .`. MIT licence.
