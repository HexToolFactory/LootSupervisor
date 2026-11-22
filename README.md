# Loot Supervisor

A World of Warcraft: Forever addon that keeps a log of every boss kill - date, items, who got them - tracks which
boss drops which currency, reminds you to loot it, and whispers group members who forgot.

## Kill log
Every boss kill is saved with date, time, boss, instance, each item that dropped, who got it and everyone's roll.

`/lsup` (or the addon menu on the minimap) opens the log window. Kills are grouped per activity - one instance
visit - newest first. Pick a kill to see its items, winners, rolls and your currency. Names are class-colored.
The Items tab lists every drop in a table (date, instance, boss, item, winner, roll) and the Currency tab the
currency per boss; click any column header to sort, again to reverse. The search box takes a player or item name
and filters the open tab. The window is styled like DungeonJournal and uses its dungeon art and colors when
DungeonJournal is loaded.

The log in chat:

```
/lsup log            last 5 kills
/lsup log 20         last 20 kills
/lsup log ragnaros   kills of one boss
```

```
2026-11-20 21:14 Ragnaros - Molten Core
   [Bonereaver's Edge] > Anna Berg (87)
      Need: Anna Berg 87, Cid Moss 45 | Greed: Bob Stone 30 | Pass: 4
   [Choker of the Fire Lord] > Bob Stone
   2x Tarnished Undermine Real > you
```

Rolls are listed per kind (Need, Greed, Transmog, Disenchant, Pass), highest first. More than three passes show as a count.

Item links in the log are clickable. The last 500 kills are kept.

Where the data comes from:
- the game's roll history (item, winner, every roll),
- the boss loot window when you open it,
- the roll, "won" and "receives loot" lines in chat, read in your client's language (master loot included).

## Currency per boss
`/lsup currency` (or the Currency tab) lists every boss that dropped a currency for you: amount and in how many kills.

## Loot reminder
After a kill of a boss that drops currency, a box with a bouncing arrow appears: "Loot Gallywix" with the
currency. Bosses that drop a Tarnished Undermine Real come from a built-in list (Dire Maul, Blackrock Depths,
Blackrock Spire, Scholomance, Stratholme, Blackmaw Hold, world and raid bosses); any other boss counts once it
dropped currency for you. A boss whose Real you already looted today shows no box. It also appears when you target or mouse over a lootable corpse of such a boss. It disappears when you loot,
after 2 minutes, or on right-click. Drag it to move it. `/lsup test` shows it.

## Group check
15 seconds after the kill, group members with Loot Supervisor who have not looted get a whisper:

> [Loot Supervisor] Loot Gallywix: Tarnished Undermine Real is waiting for you.

- Members with Loot Supervisor report their loot to each other, so only those who really did not loot are told.
- WoW: Forever shows no other player's currency loot in chat, so for members without the addon nobody can know.
  They get no whisper by default; `/lsup whisper all` whispers them too, looted or not.
- When several members have the addon, only one of them whispers.
- Whispers wait while the game blocks chat (boss fights).

## Commands
| Command | |
|---|---|
| `/lsup` | log window |
| `/lsup currency` | currency per boss in chat |
| `/lsup log [n or boss]` | kill log in chat |
| `/lsup whisper addon\|all\|off` | whom to whisper (default `addon`) |
| `/lsup hint known\|all\|off` | reminder after known currency bosses, every boss, or never |
| `/lsup delay <seconds>` | wait before whispering (default 15) |
| `/lsup test` | show the reminder |

`/lootsupervisor` works too.

## Limits
- The arrow cannot sit over the corpse: dead units have no nameplate, so the reminder is a box on screen.
- Kills are taken from the game's boss fight events. Where a boss sends none, only skull-level bosses count.
- Without an open loot window, rare and better items from chat lines within 10 minutes of a kill count for that
  kill, so a rare trash drop in that time can slip in.
- Currency amounts per boss are what **you** got.

## License
MIT
