---
title: "Deltaplan 1.4.1"
date: 2026-10-09
description: "Any point on the map now gets the same data as the built-in places; instruments face the pilot, telltales sit on the wires, haze is back in the chase view."
cover: screenshots/06_любая_точка_рельеф_реки_лес.jpg
captions:
  "01_приборы_к_пилоту.jpg": "Instruments facing the pilot"
  "02_взгляд_на_приборы_по_Q.jpg": "Q: look at the instruments"
  "03_ленточка_на_тросе.jpg": "Telltale on the front wire"
  "04_дымка_от_третьего_лица.jpg": "Haze in the chase view"
  "05_подсказка_по_клавишам.jpg": "Key hints at the top of the screen"
  "06_любая_точка_рельеф_реки_лес.jpg": "Any point: terrain, rivers and forest"
---

# Deltaplan 1.4.1 — any point, like a built-in place

09.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's included
**Place data**
- Any point (map, "Popular", "Recent") gets the same layers as the built-in places: 25 m Copernicus terrain with a 100 m background, rivers from terrain, ESA WorldCover land cover, 10 m forest and water, and roads, buildings, power lines, rivers, lakes, settlements, fields and fences from OpenStreetMap. Before, a point had only coarse terrain and land cover without OSM.
- A built place is saved to a local cache and loads without network next time. If land cover or OSM could not be downloaded, you fly without that layer and the missing part is fetched on the next launch.
- A point inside a built-in place opens that place with the launch at your point.
- The cache can be filled in advance without flying: `deltaplan --headless -- --prefetch=lat,lon`. All command-line options are in `README-options.txt` next to the game.
- The game's network requests are written to the game log.

**Cockpit view**
- The flight deck and vario sit at the centre of the base bar, in line with it, tilted 60° to the horizon towards the pilot — seen almost face-on from the cockpit.
- The base bar bend follows a real one: straight ends at the uprights, a smooth transition and a straight centre.
- Q looks at the instruments again (hold).
- Translucent key hints at the top of the screen: "F1 — frame rate · F3 — wind over terrain · F5 — wind around · F6 — thermals"; a mode disappears from the hint while it is on.
- The red telltales on the front wires hang at 30% of the control frame height and start right at the wire.
- Haze and distant ridges are back in the third-person views.
- After takeoff the first-person camera recenters by itself and no longer swings up to the wingtip.

**Menu**
- "Flight…" is now "Flight settings", "Settings" is now "Game settings".

## Screenshots
{{< gallery >}}

[itch.io devlog text](/site/content/releases/1.4.1/devlog.txt)
