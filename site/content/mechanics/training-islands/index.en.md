---
title: "Training islands"
weight: 100
description: "The two places in the Training window — the fictional Training Island and the volcanic island with real terrain: which kind of air is where, the weather at each start, and how it differs from real mountains."
---

# Training islands

The Training window offers two places: **Training Island** and **Volcanic Island**. Each exists so that a single flight
shows one kind of air — ridge lift, a thermal, rotor, a landing — without hunting for the right day and place. For that,
every start has its weather set in advance, and the wind field is baked to a file and loads in about a second. Every start has its own card with a flight goal.

![The Training window, Training Island tab: four cards — ridge, thermals, landing, rotor](training-menu-island.jpg "The Training window, Training Island tab. Four starts, four cards, each with a flight goal.")

## Training Island {#training-island}

A fictional place, 15 × 10 km, generated from the game's own files: there is no real location behind it, and no network or terrain build is needed.
Four starts, each with its own kind of air:

| Start | What it teaches | Wind at the start | What the air gives |
|---|---|---|---|
| "Ridge" | soaring along a ridge | 6 m/s from 270°, overcast, 12:00 | lift over the crest: +1.83 m/s on average (+1.41 at 5 m/s, +2.52 at 8 m/s), upward in all 153 checked points |
| "Thermals" | finding and climbing in a thermal | 2 m/s from 180°, 25 °C, partly cloudy, 12:00 | thermal cores over the fields: median 1.98, p90 2.66, max 4.1 m/s; top 1741 m above sea |
| "Spot landing" | approach and landing in a circle | 1 m/s from 270°, morning (09:00), clear | near calm: 1.16 m/s at the target |
| "Rotor" | flying behind a ridge | 8.5 m/s inflow from 270°, overcast, 12:00 | behind the crest, near the ground the wind is reversed in 56 % of points, vertical speed down to −1.67 m/s |

The date is 15 July everywhere. The ridge is deliberately overcast and windy: weak thermals do not get in the way of learning the ridge.
Thermals are the opposite: light wind, a warm day, and no thermals over the sea at all.

![The Ridge start on Training Island: a gentle ridge slope above the sea, fields in the distance](island-ridge-west.jpg "The Ridge start: the 270° wind meets a ridge above the sea — the slope itself gives the lift, not thermals.")

![The lee bowl behind the ridge: a leeward slope and dark patches of forest on the crest](island-lee-bowl.jpg "The Rotor start: the bowl behind the ridge. Here the flow, having crossed the crest, goes down and curls — in the model it is reversed near the ground.")

## Volcanic Island {#volcano-island}

The island is real: about 24 × 18 km, land of about 165 km², highest point 507.6 m. Terrain and land cover come from open data,
unedited; the name and coordinates are not given in the game or on the site. The data ships inside the game, no network is needed. The place is reachable only from the
Training window — it is not in the Popular places list or the flight menu. Roads and buildings come from the place's own files.

The trade wind blows from 110° almost constantly, 6 m/s at the slopes, 15 January, 12:00, partly cloudy, 27 °C. Four starts:

| Start | Where | Height, heading, slope | Card goal |
|---|---|---|---|
| "Cliffs" | edge of the sea cliff of the eastern plateau | 141 m, 110°, 8.9° | 10 min airborne |
| "Crater" | edge of the south-west cliff above the crater | 226 m, 110°, 12.7° | 10 min airborne |
| "Thermals" | island summit, meadow | 504 m, 110°, 10.3° | climb 300 m (3 m/s, 15:00, 28 °C, clear) |
| "Plateau landing" | short approach to a target | 219 m, 90°, 13.1° | landing in a 25 m circle (2 m/s, 09:00, clear) |

What the air check showed (6 m/s, no turbulence): over the "Cliffs" edge +1.43 m/s on average (p90 2.30), at the "Crater" +1.56 (p90 2.31),
upward in every checked point. The rotor at the crater is weak: reversed wind in only 3.3 % of points behind the edge, minimum w −1.20 m/s.
Thermals over land: cores p90 4.1–4.3 m/s; there are no thermals over the sea.

![The Training window, Volcanic Island tab: cliffs, crater, thermals, plateau landing](training-menu-volcano.jpg "The Volcanic Island tab: four cards, each with its own goal.")

![Cockpit view at the Cliffs start: instruments on the frame, a meadow and a slope down to the sea](volcano-east-cliffs.jpg "The Cliffs start on Volcanic Island: the cliff edge above the sea, the trade wind meeting the slope.")

## Start weather and baked wind fields {#start-weather}

A start can have fixed weather: wind, hour, date, sky and temperature come from the start's set — the same from the menu, on replay,
over the network and from the command line. Time still runs as usual. The set's wind is given either at the start itself or as the inflow at the edge of the area
(for "Rotor" and "Crater"): then the wind at a start behind a ridge is honestly weaker than the set's, as in life.

The wind field is baked in advance. If the conditions match the file, the game reads it instead of computing: an island start loads in about 0.7 s instead of 14–58 s,
and the "Computing wind from terrain" stage is not shown. The four Training Island fields take 25.9 MB. A baked field
differs from a cold computation by at most 0.007 m/s (checked at Ongudai; stored as float16). No file, or conditions that do not match — it is computed as usual.

## How the islands differ from real places {#limits}

- **Training Island is fictional.** The terrain is generated and its relief is scaled to fit the task. The overall layout — ridge above the sea, fields, a hill, a bowl — is for teaching, not from life.
- **The set's weather is not tuned further.** Thermals on Training Island come only from choosing the start's weather, with no change to the model's global parameters. The 1741 m top
  is computed from the model's dry air (July dew point), without sea humidity: over a real sea island the base is lower and there is more cloud.
- **A 788 m thermal climb in 15 min** is an estimate for an "ideal" pilot: circling exactly on the axis, no run-up, no turbulence. A real pilot will climb less.
- **Volcanic Island has no trade-wind inversion.** The model lacks it, so the cumulus base comes out at 3.8–3.9 km instead of the usual 1.5–2.5 km: climbs in thermals up to 3 km are higher than on a real island.
- **The lift comes from sea cliffs**, not a gentle slope: on 5–10° slopes there is almost none. There are no level landing fields — only meadow terraces with a 4–8° slope.
- **One day was checked** (15 January, trade wind 110°, 3 m/s and 5–8 m/s); other wind directions were not. There is no sea breeze; thermals follow land-cover classes.
- **The spread of climbs** between flights (330–3120 m) is a matter of hitting the thermal core, not randomness in the model.

## More {#more}

- [docs/research/training_island_air.md](/docs/research/training_island_air.md) — Training Island start weather and the air check (ridge, thermals, rotor, landing).
- [docs/guide/volcano-island.md](/docs/guide/volcano-island.md) — Volcanic Island: data, starts, weather, air figures, limits.
- [docs/guide/location-data.md](/docs/guide/location-data.md) — baked wind fields and place data.
- [CHANGELOG.md](/CHANGELOG.md) — build 1.5.19.
