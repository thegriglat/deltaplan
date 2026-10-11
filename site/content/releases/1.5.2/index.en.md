---
title: "Deltaplan 1.5.2"
date: 2026-10-11
description: "OpenStreetMap is back on our own tiles: cities, roads, power lines, wind turbines and cable cars; motion platform output and a home-made control bar."
cover: screenshots/01_алматы_сверху.jpg
captions:
  "01_алматы_сверху.jpg": "Almaty from above"
  "02_высотки_центра.jpg": "High-rises in the city centre"
  "03_частный_сектор_с_дымом.jpg": "Private houses with chimney smoke"
  "04_шлейф_пара_по_ветру.jpg": "Power plant steam plume drifting with the wind"
  "05_ветряки_по_ветру.jpg": "Wind turbines facing the wind"
  "06_канатка_шымбулак.jpg": "Shymbulak cable car"
  "07_опоры_лэп.jpg": "Power line pylons"
  "08_дороги.jpg": "Roads with markings"
  "09_горизонтальная_поза.jpg": "Cockpit view, prone position"
---

# Deltaplan 1.5.2 — OpenStreetMap on our own tiles

11.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
**OpenStreetMap is back**
- OpenStreetMap objects are back, served from our own tiles (no overloaded map servers): buildings, roads, rivers and canals, railways, power lines, masts, chimneys, wind turbines, cable cars, airfields, peak and pass labels. The tiles cover the whole world.
- Buildings styled as city / village / industrial; in big cities buildings without a height in OSM grow taller towards the centre, with glass high-rises in the dense core.
- Smoke from village chimneys and steam plumes from industrial stacks, carried by the model wind, so a plume works as a wind indicator from kilometres away.
- Models instead of cones: lattice pylons and poles with wires, masts, chimneys, TV towers modelled on Ostankino.
- Wind turbines turn into the model wind and spin with its strength; cable cars run along ropeways.
- Roads: asphalt with markings, ruts on dirt roads.

**Cockpit camera**
- Two views: "Seated position" (just behind the head) and "Prone position" (the pilot's eyes). The pilot's body is hidden, only the gloves on the bar are visible.

**Simulators**
- Motion output to motion platforms over UDP: DOF Reality via Sim Racing Studio, plus a generic format for home-built rigs.
- Control from a home-made control bar: any two-axis USB joystick, calibrated in settings.

**Menu**
- Game settings are split into tabs.
- Built-in places (Altai, Ongudai, Askarovo, Aushkul) moved to "Popular places → Russia"; Mount Yutsa near Pyatigorsk added (two launches). The network game screen picks a place the same way as flight settings.
- A "Peak labels" checkbox.

## Screenshots
{{< gallery >}}

[itch.io devlog text](/site/content/releases/1.5.2/devlog.txt)
