![CafeRaidPlanner](docs/logo.png)

A WoW Classic addon for running planned raid pulls. You build the plan in
the [web planner](https://cafewow.github.io/CafeRaidPlanner-Web/), paste the
share string into the addon, and the rest of the raid sees pull-by-pull what
they're supposed to do.

It hooks the combat log to track kills, auto-advances through the pull list
as packs die, and shows each player only what's relevant to them.

Tested on Classic Era / Anniversary; should load anywhere that accepts a BCC
TOC (`Interface 20504`).

## Install

Easiest way is [CurseForge](https://legacy.curseforge.com/wow/addons/caferaidplanner) — search
for "CafeRaidPlanner". Or grab a release zip from this repo and drop the
`CafeRaidPlanner` folder into your AddOns directory.

## What you get

For the raid leader, the full window:

![Raid view](docs/raid_view.png)

- Pull notes and reminders straight from the plan
- Live kill progress per mob, with auto-advance when the pull is done
- All assignments laid out as a table — cooldowns, kicks/CC, equip swaps
- Preview of the next few pulls

For everyone else, the same plan filtered down to their character:

![Personal view](docs/personal_view.png)

Only assignments addressed to you show up. Spells and CC are filtered by
what your class actually knows, so a warrior doesn't see Polymorph and a
rogue doesn't see Innervate. Toggle with the **My view** / **Raid view**
button in the top-right corner. The window remembers its size and position
separately per mode.

Assignments can also target a **role** (tank / healer / damage) instead of a
named player. Role and class filters stack: a Divine Shield assigned to "tanks"
only reaches paladin tanks. Your role is auto-detected from your talents; if it
guesses wrong, override it with `/crp role tank|healer|damage` (or the dropdown
in the options window), and `/crp role auto` to go back to detection.

## Combat HUD

A small icon bar pops up when you enter combat showing just your actionable
assignments for the current pull — items, spells, on-use trinkets — each
one with a cooldown swipe and item-count overlay.

- Equip swaps only show between pulls, everything else during combat.
- Items you don't have in your bags don't appear.
- Icons whose cooldown still has more than ~5s left (configurable) drop off
  the bar rather than dimming, so leftovers from earlier pulls don't linger.

Drag it where you want it, scale it, lay it out horizontally or vertically.
Plays nicely with OmniCC since it uses the standard cooldown template.

## Using it

1. Build a plan on the [web planner](https://cafewow.github.io/CafeRaidPlanner-Web/),
   hit Share, copy the `crp1.…` string.
2. In-game, type `/crp import` and paste it in.
3. Open the window with `/crp` (or it'll pop open when you zone into a raid).
4. As raid leader, hit **Push** in the addon to broadcast the plan + current
   pull index to everyone else in the raid. They'll get a prompt to import.

Imported plans are kept in a library rather than overwriting each other, so you
can preload several (e.g. one per raid for the night) and switch between them
with the **Plans** button in the window. Only one plan is loaded at a time —
switching starts the new one fresh and discards the previous plan's pull cursor
and kill progress. Re-importing or being re-pushed the same plan updates it in
place instead of stacking duplicates.

The current pull advances on its own as packs die. If you go off-script
(skipped a pull, came back to redo one) you can jump to any pull from the
counter dropdown — the tracker fills in or clears intermediate kill state
accordingly, so the numbers stay consistent with where you actually are.

Kill progress survives a `/reload` mid-raid. A new lockout (after a reset
and zone back in) wipes everything on the next kill.

## Where the plans come from

Plans are built in the [web planner](https://cafewow.github.io/CafeRaidPlanner-Web/) —
drop pack markers on the raid map, group them into pulls, assign cooldowns
and CCs, then export a share string. The addon imports that string.

![Planner](docs/planner.png)

## Slash commands

| Command                   | What it does                                             |
| ------------------------- | -------------------------------------------------------- |
| `/crp`                    | toggle the window                                        |
| `/crp import`             | open the paste-string dialog                             |
| `/crp plans`              | list the stored plans in your library                    |
| `/crp next` / `/crp prev` | navigate pulls manually                                  |
| `/crp my` / `/crp raid`   | switch view mode                                         |
| `/crp push`               | broadcast plan + current pull to the raid                |
| `/crp auto on\|off`       | combat-log auto-advance (default on)                     |
| `/crp autoshow on\|off`   | open window on raid zone-in / incoming plan (default on) |
| `/crp autoimport on\|off` | skip the import prompt for pushed plans (default off)    |
| `/crp reveal click\|hover`| reveal the window chrome on click vs. hover (default hover)|
| `/crp role tank\|healer\|damage\|auto` | set your role for role-targeted assignments (default auto-detect) |
| `/crp clearkills`         | reset tracked kills without dropping the plan            |
| `/crp reset`              | remove the active plan from the library (switches to another if any) |
| `/crp debug on\|off`      | log each UNIT_DIED GUID, for lockout troubleshooting     |

## Related

- Web planner: [cafewow/CafeRaidPlanner-Web](https://github.com/cafewow/CafeRaidPlanner-Web)
- Architecture notes and dev docs: `PROJECT.md` in the repo root
