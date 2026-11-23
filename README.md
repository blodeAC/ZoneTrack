# ZoneTrack

A quest tracker helper for WoW Forever. It keeps the default quest tracker showing the quests that matter where you are, sorts them by distance and points the quest arrow at the nearest one. No quest database: everything comes from what the game itself shows on your map.

## Install

With [instawow](https://github.com/layday/instawow):

```
instawow install github:blodeAC/ZoneTrack
```

or copy this folder to `World of Warcraft/_forever_/Interface/AddOns/ZoneTrack`.

## What it does

- Tracks every quest that has a highlighted area on your current zone's map, and untracks the rest. A quest whose area shows on the edge of this zone's map (a neighbouring zone, a dungeon entrance) counts too: if it's on the map, it's tracked.
- Tracks finished quests waiting to be turned in, below this zone's quests. Hand-off steps (no item or spell reward, nothing to do but talk to someone) are skipped.
- Sorts the tracker nearest-first and points the quest arrow at the nearest quest. Standing inside a quest's highlighted area counts as distance 0, so that quest wins. Outside, distance is the game's own distance to the middle of the quest's nearest area.
- While you move, it checks again at the earliest moment the nearest quest could change (half the distance gap to the runner-up, at your current speed), and not at all while you stand still, stand inside an area, fly, or fight.
- Quests you track yourself stay tracked in every zone. Untracking one of this zone's quests by hand leaves it untracked until you change zones. Picking a quest's arrow yourself pauses the automatic arrow until you change zones or click the button.
- The tracker is re-sorted when the arrow moves to a different quest, you accept or turn in a quest, or you change zones, not after every kill (that's a setting). Nothing changes in combat or on a flight path; it catches up afterwards.

## Using it

- The spyglass button (starts at the top-left corner of the tracker): left-click sorts the tracker and points the arrow at the nearest quest now, right-click opens the settings, drag to move it.
- `/zonetrack` or Options > AddOns > ZoneTrack opens the settings.

## Settings

- Enabled
- Keep quests I track by hand
- Track this zone's finished quests
- Track finished quests from every zone
- Skip hand-off quests
- Sort the tracker nearest-first
- Re-sort after every quest update
- Point the quest arrow at the nearest quest
- Blizzard auto-tracks quests when you accept them (the game's own setting)
- Show the ZoneTrack button
- When the tracker is full, track first: quest log order or nearest quest area
- Debug messages in chat

## First run

The first time it runs, ZoneTrack untracks every quest that has no area on your current zone's map, including ones you tracked by hand before installing it. Track those again and they stay tracked everywhere.
