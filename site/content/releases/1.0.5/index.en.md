---
title: "Deltaplan 1.0.5"
date: 2026-10-04
description: "Wind over terrain by a neural network (experimental) and a \"Map inspection\" mode with wind arrows around the camera."
cover: screenshots/01_осмотр_карты_стрелки_ветра.jpg
captions:
  "01_осмотр_карты_стрелки_ветра.jpg": "Map inspection, wind arrows"
---

# Deltaplan 1.0.5 — neural-network wind and map inspection

04.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's included

**Wind**

- Wind over terrain can be computed by a neural network (experimental): Settings → "Wind over terrain" → "Neural network (experimental)". The network is trained on solver runs over 300 real terrains; it computes on the CPU, no graphics card is needed for the wind, and the "Computing wind" stage takes a few seconds. The field is smoother than the solver's: unbiased on average, but on steep terrain it is off by 1–2 m/s in places.
- New main menu item "Map inspection": place, time and wind as for a flight, but without a pilot and wing — straight into a free camera with wind arrows (F5); exit — Esc → Main menu.
- Wind arrows (F5) are now always built around the camera, with a radius of 1800 m instead of 1200.

**Menu**

- In the lower right corner of the main menu — the game version and a short build number.

## Screenshots

{{< gallery >}}

[Devlog text for itch.io (in English)](/site/content/releases/1.0.5/devlog.txt)
