# Changelog

## 0.3.1
- Fix: trash rolls ("Miscellaneous") were copied into a new log entry each time the game resent its roll history.
  Each roll is now logged once. Copies already saved by 0.3.0 are removed on the next login.
- Fix: bosses without a boss-kill event (seen in Dire Maul) were logged from the roll history only, without your
  own loot and currency. Your loot window now joins the kill when one of its items shows up in that boss's rolls.
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
