# CafeRaidPlanner (addon)

WoW addon that consumes a plan exported from the
[CafeRaidPlanner web planner](https://github.com/cafewow/CafeRaidPlanner-Web),
tracks pull progress via the combat log, and shows the raid leader /
each player exactly what's expected on the current pull.

Supports TBC Classic (Interface 20504) and retail (120001/120005).

## Install

Clone or download this repo into your AddOns folder:

```
World of Warcraft/<client>/Interface/AddOns/CafeRaidPlanner/
```

Client folder depends on version: `_classic_era_`, `_bcc_`, `_anniversary_`,
`_retail_`, etc.

On Windows + WSL, `mklink /D` from an elevated cmd.exe can symlink a WSL
path into the AddOns folder.

## Usage

- `/crp` — toggle the planner window.
- `/crp import` — open the paste-string dialog for the `crp1.…` string
  you get from the web planner's Share dialog.
- `/crp next` / `/crp prev` — advance through pulls manually.
- `/crp my` / `/crp raid` — switch between the minimal per-player view and
  the full raid leader view.
- `/crp auto on|off` — toggle combat-log-driven auto-advance.
- `/crp clearkills` — wipe tracked kill progress without touching the plan.
- `/crp reset` — wipe the imported plan entirely.
- `/crp debug on|off` — log each UNIT_DIED GUID (for troubleshooting
  lockout detection).

## How it works

- **Import**: `crp1.<base64url(deflate(JSON))>`. `LibDeflate` unpacks the
  deflate, rxi's `json.lua` parses. Result is `{preset, packs, bosses,
  npcNames}` stored in AceDB.
- **Tracker** (`Tracker.lua`): hooks `COMBAT_LOG_EVENT_UNFILTERED`, filters
  `UNIT_DIED` / `PARTY_KILL`, extracts `npcId` from Creature GUIDs, and
  matches against the current pull's aggregated kill requirements (packs
  + boss). When the requirements are met and `autoAdvance` is on, the
  current pull advances.
- **Lockout** persistence: kill state is keyed by `serverID + zoneUID`
  from the GUID — the same fingerprint Nova Instance Tracker uses. Reloads
  mid-raid keep progress; a new lockout (after reset + reenter) wipes on
  the first kill.
- **My view**: filters assignments to those whose `player` matches the
  local character (realm-stripped, case-insensitive), plus unassigned
  items/reminders/equips and unassigned spells that `IsSpellKnown` returns
  true for.

## Layout

```
CafeRaidPlanner/
├── CafeRaidPlanner-BCC.toc
├── CafeRaidPlanner-Mainline.toc
├── init.lua           namespace + cross-version shims
├── Core.lua           AceAddon, AceDB, slash, event frame
├── Share.lua          decode crp1.… strings
├── Plan.lua           AceDB-backed plan/pull CRUD
├── Tracker.lua        combat-log kill tracker, auto-advance
├── Comms.lua          raid-sync scaffold (phase C — stub only)
├── UI.lua             main window, pull popup, import dialog
└── libs/              vendored Ace3, LibDeflate, LibDataBroker, rxi-json
```

## Status

v0.1.0-dev. Planning + tracker working; Comms scaffolded but not live.
