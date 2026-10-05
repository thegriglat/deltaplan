---
title: "Deltaplan 1.0.0"
date: 2026-10-01
description: "Wind and thermals are computed from the terrain for every flight, 48 wings from DHV datasheets."
cover: screenshots/01_в_термике.jpg
---

# Deltaplan 1.0.0 — terrain-based air and 48 wings

01.10.2026. {{< button href="https://thegriglat.itch.io/deltaplan" >}}Download on itch.io{{< /button >}}

## What's included

**Air model**

- Wind over terrain is computed for every flight: the loading screen has a new stage, "Computing wind"
  (a few seconds) — a wind field exact for the start hour, the wind and the weather of the flight. In flight the field is recomputed
  every 15 game minutes and when the wind changes; the new one smoothly replaces the old. Without a graphics card that supports
  compute — as before.
- Thermals are taken from the field: over sun-heated slopes and in convergence — more often, in shade — none; in the morning they are small
  and capped by the inversion, by day they reach the cloud base; the wind from the field carries them.
- Turbulence comes from the field itself: stronger with wind and at the brow, almost gone in stable morning air.
- Behind the ridge — by physics and measurements: the rotor is where the field shows a detached wake, downdraughts are
  part of the turbulence, not the previous sinks down to −18 m/s.
- Wind with height depends on time of day and cloud cover: at sunny noon it grows only slightly with height, in the evening,
  in overcast weather and in strong wind — noticeably more.
- Grass and ripples on the water bend more strongly at the brow than in the valley.

For details, see the page ["Air model"](/mechanics/air-model/).

**Wings**

- 39 new wings (48 in total): trainers, kingposted and topless — Wills Wing, Moyes, Aeros, Icaro, Airborne,
  Seedwings and others. Span, area, nose angle, battens, kingpost, wing mass and pilot weight range — from DHV and
  manufacturer datasheets; the polar — from a wing of the same class, rescaled to the wing loading.
- Falcon, Litespeed, Combat and Laminar were brought in line with their datasheets.
- A pilot holds a wing on the ground level; a strong side gust can lift a wingtip and tip the wing over.
  A wing on a slope no longer passes through the ground.
- All wings with data and sources are in the section ["Wing models"](/wings/). Thanks to DHV for the open
  datasheet and test data.

**World**

- Launching from a map in a forest is no longer hopeless: trees are removed around the launch point.
- Grass grows under the trees; nearby trees no longer "pop", with 8 different trees of each species.
- Cirrus clouds as in real life — long ribbons of thin filaments.
- The world has become livelier: small details occasionally appear — in the sky, on the ground and at the launch.

**Menu and picture**

- The main menu opens at once, the world is loaded on "Fly".
- Start time — a choice of 9:00, 12:00, 15:00, 20:00.
- The picture's colour is softer and more natural, the menu background is in 4K.
- Debug layers for flight analysis: F1/F2 — performance, F3/F5 — wind arrows, F6 — thermals.
- The build is about 17 MB smaller thanks to terrain compression.

## Screenshots

{{< gallery >}}

Devlog text for itch.io (in English) — [devlog](https://github.com/thegriglat/deltaplan/blob/main/site/content/releases/1.0.0/devlog.txt).
