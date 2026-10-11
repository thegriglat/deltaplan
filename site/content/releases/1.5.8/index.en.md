---
title: "Deltaplan 1.5.8"
date: 2026-10-12
description: "Launch exactly at the chosen point with a calm wing on the ground, a pilot weight-shift indicator, soft touchdown on the legs, and a motion rig without jolts."
cover: screenshots/01_индикатор_смещения_от_первого_лица.jpg
captions:
  "01_индикатор_смещения_от_первого_лица.jpg": "Weight-shift indicator, first-person view"
  "02_индикатор_смещения_от_третьего_лица.jpg": "Weight-shift indicator, third-person view"
---

# Deltaplan 1.5.8 — launch, weight-shift indicator, soft touchdown

12.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
**Launch**
- Launching from the map puts you exactly at the chosen point, with no search for a nearby slope; the nose points down the local slope (north on flat ground).
- Standing at launch, the wing no longer rocks or leans all the way back (both control modes): the keel stays near level, nose slightly up (5.5°, the way a pilot holds it); with no input the wing turns into the wind by itself.
- Until the transition to the flying position starts, touching the ground with the wing is not a crash: you can hop, touch and try again; after the transition the usual rules apply.

**Weight-shift indicator**
- At the bottom centre of the screen, in all control modes and cameras: a circle with a crosshair, the dot shows where the pilot's body is relative to the hang point (forward/back — pull/push, sideways — roll); centred means hanging with no input. Can be turned off in the interface settings.

**Touchdown**
- The legs absorb vertical speed by bending up to 0.3 m: landing at 3.5 m/s down is about 4 g instead of 22–44 g, 1 m/s is under 2 g, at 5.5 m/s the legs bottom out and the impact is 10–15 g. Landing grades did not change.
- A crash no longer stops the pilot in a single physics step: speed is taken out at about 20 g.

**Motion rig (DOF Reality via SRS)**
- Packets are always sent while output is on: neutral or the held pose in the menu and on pause, so SRS doesn't go to standby; on any transition values ease in over "Ease-in" (2.5 s) instead of jumping.
- Accelerations on the ground are multiplied by "Ground accelerations" (0.3): the take-off run is softer, flight is unchanged, the touchdown bump stays.
- Not yet tested: ease-in and the ground multiplier have not been tried on a real platform.

## Screenshots
{{< gallery >}}

[itch.io devlog text](/site/content/releases/1.5.8/devlog.txt)
