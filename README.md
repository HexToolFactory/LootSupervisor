# Loot Supervisor

A World of Warcraft: Forever addon that keeps a log of every boss kill - date, items, who got them - tracks which
boss drops which currency, reminds you to loot it, and whispers group members who forgot.

## Kill log
Every boss kill is saved with date, time, boss, instance, each item that dropped, who got it and the roll.

```
/lsup log            last 5 kills
/lsup log 20         last 20 kills
/lsup log ragnaros   kills of one boss
```

```
2026-11-20 21:14 Ragnaros - Molten Core
   [Bonereaver's Edge] > Anna Berg (87)
   [Choker of the Fire Lord] > Bob Stone
   2x Tarnished Undermine Real > you
```

Item links in the log are clickable. The last 500 kills are kept.

Where the data comes from:
- the game's roll history (item, winner, roll),
- the boss loot window when you open it,
- the "won" / "receives loot" lines in chat, read in your client's language (master loot included).

## Currency per boss
`/lsup` lists every boss that dropped a currency for you: amount and in how many kills.

## Loot reminder
After a kill of a boss that dropped currency before, a box with a bouncing arrow appears: "Loot Gallywix" with the
currency. It also appears when you target or mouse over a lootable corpse of such a boss. It disappears when you loot,
after 2 minutes, or on right-click. Drag it to move it. `/lsup test` shows it.

## Group check
15 seconds after the kill, group members who have not looted get a whisper:

> [Loot Supervisor] Loot Gallywix: Tarnished Undermine Real is waiting for you.

- Members with Loot Supervisor report their loot to each other.
- Members without it count as looted when their currency line shows up in chat.
- When several members have the addon, only one of them whispers.
- Whispers wait while the game blocks chat (boss fights).

## Commands
| Command | |
|---|---|
| `/lsup` | currency per boss |
| `/lsup log [n or boss]` | kill log |
| `/lsup whisper all\|addon\|off` | whom to whisper (default `all`) |
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
