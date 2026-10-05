---
title: "Deltaplan 1.2.0"
date: 2026-10-05
description: "A new wind neural network trained on hang gliding sites, a clear wind model menu and a Popular sites window with 684 launches from OpenStreetMap."
cover: screenshots/01_меню_модели_ветра.jpg
captions:
  "01_меню_модели_ветра.jpg": "Wind model menu"
  "02_популярные_места_страны.jpg": "Popular sites: countries"
  "03_популярные_места_старты_страны.jpg": "Popular sites: launches in a country"
---

# Deltaplan 1.2.0 — a new wind network and popular sites

05.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's included
**Wind over terrain**
- A new wind neural network trained on places where people fly hang gliders: 305 launches from the OpenStreetMap catalogue, 24 conditions per site (April–September, morning, midday and evening, wind 2–12 m/s). Wind error at 60 m above terrain on sites the network never saw in training: median 0.69 m/s versus 0.92 for the previous network; on the game's sites, 0.59 versus 0.76.
- The network works for winds up to 12 m/s (the previous one up to 8).
- Wind model menu: "Neural network (wind field over terrain)", "GPU solver (terrain flow)", "Heuristic (wind profile without terrain)". The neural network is the default.

**Launch point picker**
- A "Popular sites" window on the "Flight setup…" screen (next to "Pick on map"): hang gliding launches from OpenStreetMap grouped by country with site counts; each site shows its name, elevation and the wind directions it works in; search by name within a country or across all countries. Picking a site sets the launch point, just like a point on the map. The catalogue has 684 launches from 24 countries (data © OpenStreetMap contributors, ODbL).

**Website**
- The project website is bilingual: English at the root and Russian under `/ru/`, with a language switch.

**Steam**
- A separate Steam build is prepared (achievements, cloud saves, network play with friends). The game is not on Steam yet; the itch.io build works as before.

## Screenshots
{{< gallery >}}

[Devlog text for itch.io (in English)](/site/content/releases/1.2.0/devlog.txt)
