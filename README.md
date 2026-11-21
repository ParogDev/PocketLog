# PocketLog

A measuring addon for WoW: Forever rogues. It logs every Pick Pocket and the later corpse loot of the same mob, so you can find out what really happens when the pocket window is closed with loot still in it, never shows up, or is cut off by the opener.

It changes nothing in the game. Its only UI is the pocket bar (below). Badges, refill timers and haul totals are what Kaydee's Pockets does; this addon records, and the bar tells you when to press.

## The pocket bar

If your opener is a second press after Pick Pocket (`/castsequence Pick Pocket, Cheap Shot`), pressing it before the loot is in throws the loot away: none of 89 pockets with the opener on the same press gave everything. The bar shows when the second press is safe.

The bar is a timeline of the first 1400 ms after the cast, with your world latency above it on the right.

- The dark block on the left is the first 250 ms, before the loot window can open. A press there never works.
- A violet fill grows from the cast, labelled `Wait`. If you were moving at the cast it is amber, labelled `Moving`, because the window rarely opens then (1 in 66 moving, 79 in 100 standing still).
- The white line is the gate, where the second press becomes safe. It is faint at 600 ms until the window opens, then snaps solid to the predicted finish: the opening time plus `autoLootRate` (150 ms) per slot plus 40 ms. One small square per loot slot turns yellow as auto loot takes it.
- When the window closes with everything taken, the whole bar turns yellow: `Open now`. With no window after 600 ms plus your world latency it says `No loot, open now`. The yellow drains right to left over 3 s, the `reset=target/3` of the macro: once it is empty the next press is Pick Pocket again.
- A press while yellow shows `Opened` and how many ms after the bar turned. A press before it turns red, `Too early`, with a tick at the press and how early it was. A window closed with loot still in it shows `Loot left`.
- A target change clears the bar.

The bar owns no button and casts nothing; the sequence is your own macro. It does nothing in instances.

`/pocketlog bar unlock` shows it so you can drag it, `/pocketlog bar lock` fixes it, `/pocketlog bar off` and `on` turn it off and on, `/pocketlog bar reset` puts it back in the middle, `/pocketlog bar drain 3` sets the drain time in seconds (match your macro's reset). These settings and the position are saved per account.

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
