---
title: "Deltaplan 1.5.9"
date: 2026-10-12
description: "Graphics: sharper terrain and rocks, a city with trees, metal control frame, own gloves and pilot gear, less video memory; precise launch spot on the terrain."
---

# Deltaplan 1.5.9 — graphics and a precise launch spot

12.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
**Graphics**
- Terrain in the middle distance (1.5–10 km) is sharper, with erosion gullies on steep slopes; rocks on cliffs are angular, of different sizes, lying in ridges along the slope and in screes below the crags.
- Mountains in the distance are sharper: ridges and gullies on steep slopes are crisper (visual only; near the ground the terrain matches the physics); rock reads up to 6–12 km — large-scale rock texture, cracks, scree streaks; high-mountain rock is darker and colder than on the low hills; grass, rock and snow meet along a narrow ragged edge.
- Roads have soft edges and dusty shoulders and fade into the distance; OSM rivers are no longer drawn as thin blue lines.
- City: buildings in a calm palette instead of white boxes, distant windows in a mid tone, parapets and details on flat roofs; birches along streets, in yards and gardens (visible within 0.4–1.1 km depending on graphics quality).
- Tree branches sway in the wind; gusts over 7.5 m/s raise puffs of dust over dry ground and ploughed fields.
- The control frame and wing tubes are metal, with twisted cables and bolts; the instruments look worn, with scratches on the glass.
- The pilot has matte leather gloves gripping the base bar (curved ones too); the harness pod is soft, with no parachute bump on the back; helmet, clear visor, fabric, straps and boots have their own materials.
- New graphics setting "Haze toward the sun": how much haze and clouds brighten against the sun.
- Less video memory: sail, terrain, tree, OSM and menu textures are compressed and mipmapped (about 435 → 85 MB for terrain and vegetation); less shimmering in the distance.

**Precise launch on the terrain**
- The main menu map-view item is now "Pick launch on terrain": click the ground in 3D to place the launch spot (nose down the slope), drag or use ±5° buttons to set the run-up direction, "Downhill" resets it; "Fly from here" starts the flight right away without reloading the place.
- You can't place the launch on water, in built-up areas, on slopes steeper than 40° or at the edge of the loaded place — the marker turns red with the reason next to it.
- Auto-turn into the wind doesn't change a heading set by the pilot; "wind into launch" blows along the chosen heading.
- The spot is stored with the flight settings (last flight, favourites); the "Place" tab of the flight settings shows "Launch set on terrain" with a "Reset" button; picking another place clears it.
- In network play everyone gets the zone host's spot and heading.
- Rocks and bushes no longer lie on the 40 m run-up at any launch — built-in, from the map or refined.
- The hint on the topo map is fixed: the launch is exactly at the chosen point.

[itch.io devlog text](/site/content/releases/1.5.9/devlog.txt)
