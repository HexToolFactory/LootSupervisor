# Changelog

## 0.4.1
- Every boss of level 55 or higher counts as a Tarnished Undermine Real dropper, already on its first kill:
  the loot reminder shows and the group gets whispered without anyone having looted one before.
  The level comes from the boss frames, your dead target or DungeonJournal's boss list.
- Whispers now go only to group members who run Loot Supervisor (`/lsup whisper addon`, the new default).
  WoW: Forever shows no other player's currency loot in chat, so members without the addon were whispered even
  after they had looted. The old default `all` is switched once; `/lsup whisper all` brings it back.

## 0.4.0
- Log window: `/lsup` or the addon menu on the minimap. Kills are grouped per activity (one instance visit),
  newest first; click an activity to fold it. Pick a kill to see every item, who won it, all rolls and your currency.
- Styled like DungeonJournal; with DungeonJournal loaded, activities show the dungeon art and colors.
- Player names in class colors.
- Items tab: every drop in one table (date, instance, boss, item, winner, roll). Click a column to sort by it,
  again to reverse. Click a row to open that kill.
- Currency tab: boss, currency, amount, drops, kills and drop rate, sortable the same way.
- Search box: type a player or item name. It filters the open tab; a kill then shows only the matching items.
- Shift-click an item to link it in chat. The window updates while open.
- The currency list in chat moved to `/lsup currency`.
- Fix: no loot reminder after dungeon bosses (seen in Dire Maul). Their kill event names no creature, so the
  boss and its corpse stayed apart. The boss is now found from the boss frames of the fight or, with DungeonJournal
  loaded, from its boss list. Currency saved under the corpse moves to the boss at the next login.

## 0.3.1
- Fix: trash rolls ("Miscellaneous") were copied into a new log entry each time the game resent its roll history.
  Each roll is now logged once. Copies already saved by 0.3.0 are removed on the next login.
- Fix: a boss kill could be logged with its rolls but without your own loot and currency (seen at Pusillin in
  Dire Maul). Your loot window now joins the kill when one of its items shows up in that boss's rolls, in either order.
- "You receive loot: [x]" lines without a final period are read too.

## 0.3.0
- First public version for WoW: Forever.
- Kill log: date, boss, instance, every item that dropped, who got it and the winning roll. `/lsup log`,
  `/lsup log 20`, `/lsup log <boss>`. Keeps the last 500 kills.
- Every roll per item: Need, Greed, Transmog, Disenchant, Pass, with the number, highest first.
- Items and winners come from the game's roll history, the boss loot window and the loot lines in chat
  (any client language).
- Currency per boss: which boss dropped which currency, how much, in how many kills. `/lsup`
- Loot reminder: after a kill of a boss that dropped currency before, a box with an arrow says "Loot <boss>".
  Also when you target or mouse over a lootable corpse of such a boss. Drag to move, right-click to close.
- Group check: 15 s after the kill, group members who did not loot get a whisper. Members with the addon report
  their loot; others count as looted when their currency line shows up in chat. Only one addon user whispers.
- `/lsup whisper all|addon|off`, `/lsup hint known|all|off`, `/lsup delay <s>`, `/lsup test`.
