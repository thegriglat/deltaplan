---
title: "Flight goals and tracks"
weight: 10
description: "How to pick goals in the Flight window, how they are computed and scored, what the goal list, the instrument, the pillars and the result screen show, how tracks are recorded and drawn, and what is simplified."
---

# Flight goals and tracks

Goals are an optional layer on top of free flight: before launch you tick what you want to do, the game follows it in flight and shows the outcome at the end. There are no points and no hints. Single-player only; goals and tracks are not created in network play.

## Kinds of goals

![The Goals tab of the Flight window: a row per goal kind with a tick, a level and a number; below, the previous-attempt trace and track loading](goals-tab.jpg "The Goals tab: every goal has a tick, a level and a number; unavailable rows are greyed out. The frame predates the “Load task…” button, which sits next to the route choice.")

| Goal | What counts |
|---|---|
| Height gain | gain above the take-off point held for 10 s in a row (a single spike in turbulence does not count) |
| Time aloft | time since take-off |
| Distance | the largest straight-line distance from take-off |
| Out and return | a turn point at the given distance, then back into the cylinder at take-off |
| Triangle | an equilateral triangle from take-off with the given perimeter, then back |
| Route | a ready-made task for this place: a built-in one or your own, loaded from an `.xctsk` file |
| Time limit | fly the lead route from start to ESS (no ESS: to goal) within the given time |
| Landing | land inside a circle of the given radius without crashing |

The time limit only works together with a route, a triangle or an out-and-return. Return and triangle are built from the take-off point: the first leg goes into the wind (if the surface wind is at least 2 m/s), otherwise along the start heading; cylinders have a 400 m radius. The whole figure is rotated around take-off in 15° steps until it fits into the terrain zone; if it fits at no angle, the goal is unavailable. A landing circle exists only in some places: it needs a landing site in the location or the target of the "landing accuracy" training; for a place picked on the map there is none.

## Levels and numbers

Every goal has four levels: easy, medium, hard and "custom" (the number edited by hand). The numbers come from a formula over the weather at the start hour: thermal strength, cloud base, wind, hours before sunset. This is an order of magnitude, not a forecast: terrain and the air model do not take part, and the start height above mean terrain is a rough constant (400 m). Levels are not fitted to bad weather: on a good day all of them are reachable without a cloud, on a weak or overcast day the hard ones are unreachable by construction. Unavailable rows are greyed out without explanation.

## Your own task from XCTrack {#xctsk}

Next to the route choice on the Goals tab there is a "Load task…" button: it takes an `.xctsk` file — a task as made in XCTrack and published by competition organisers. The file is checked:

1. it reads as an `.xctsk` version 1 (JSON) and has points;
2. all points lie inside the detailed zone of the selected place — the same zone that foreign tracks are checked against.

A good file is copied into the game's task folder and is selected in the route list at once; a bad one is rejected with a message under the button: "not from this place" or "could not be read". The file itself carries no place, so the game lists the task for the places whose zone contains all of its points.

![The file chooser over the Goals tab](goals-task-file-dialog.jpg "The system file chooser over the Goals tab. The frame shows picking a track (filter “IGC and GPX”); loading a task opens the same way but accepts `.xctsk`.")

Times in `.xctsk` are UTC clock; in the game the flight starts 20 minutes before the first start gate opens (time to launch and climb). If the file has no start gates, one is created. Limits: the compressed version 2 format (`XCTSK:` QR codes) is not supported; there is no task editor in the game; there are no competition points — the result shows the speed-section time or the distance flown.

## In flight

- **Goal list** in a screen corner: ○ pending, ✓ done, ✗ failed, — unavailable; a goal in progress shows its current value.
- **Tablet**: the goal route appears on the "Map" and "Task" pages, and on the "Wind" page a small arrow in the corner of the rose points at the active point relative to the ground track.
- **Pillars** over the route points (the "Goal cylinders" setting, off by default): translucent, from the ground up 2 km; the active point is more visible, and they get denser with distance.

![View from the flight: the goal list in the left corner, translucent pillars over the route points, the tablet on the frame](goals-cylinders.jpg "The goal list in the corner (✓ done, ○ pending, a goal in progress shows its current value) and pillars over the points: red and blue are neighbouring route points.")
- **Result**: "done n of m", a line per goal and, if it failed, the reason ("landed first", "outside the circle", "over the time limit"…), plus new records: time aloft, distance, altitude; for a route its time and distance. Records are kept only if the glider took off.

![The flight result window: goals "2 of 5 done", reasons for failures and new records](goals-result.jpg "The result after landing in a forest: ✓ or ✗ per goal with a reason (“посадка” = landed first), new records below. A crash does not cancel the records: the glider did take off.")

## Tracks

While you are airborne the game records a track once a second. At the end of the flight, if take-off happened, it is saved as IGC — one record per place, a new one replaces the previous.

In the Flight window you can switch on the **trace of the previous attempt** (available once the place has a record) and **load your own tracks** (`.igc` or `.gpx`). A file is accepted if at least half of its points fall into this place's zone; otherwise the window says the track is from elsewhere.

A track is drawn as a ribbon over its whole length: its width on screen is constant (4 pixels) at any distance, and it is translucent. Colour follows the vertical speed over 5 s: climb is red, sink is blue, near zero the ribbon is almost invisible. A long track is thinned to 2000 points without losing its shape.

![A distant track: a red climb ribbon over a ridge](goals-track-far.jpg "A track seen from afar: the ribbon stays visible at distance, the red turns are climbs in a thermal.")

## Where the simulator simplifies

- The weather-based level estimate is a rough formula, not a forecast; a real day over a specific terrain can give more or less.
- "Distance" is a straight line from take-off, not a competition distance with turn points.
- In the IGC file the date is the system date of recording, the time of day is nominal (12:00 at the start of the record), pressure altitude equals GPS altitude and there is no `G` signature: fine for comparing a line and altitude, not for a flight archive.
- The previous-attempt trace is one per place, not a history.

The detailed technical description is in `docs/guide/goals.md` and the contracts in `docs/contracts/goals.md` in the repository; the `.xctsk` format and competition rules are in `docs/research/competition_rules.md`, tasks in `docs/guide/tasks.md`; task loading appeared in build 1.5.20 (`CHANGELOG.md`).
