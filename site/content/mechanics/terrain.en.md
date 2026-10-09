---
title: "Terrain and places"
weight: 50
description: "Built-in places and flight by coordinates, sources of elevation and maps, houses/roads/power lines from OpenStreetMap, water and forest: how the terrain is built and what its limits are."
---

# Terrain and places

The terrain is not just a "mountain made of noise": underneath it are the real elevations of a specific place on Earth, a real
land cover map (forest, meadow, field, water) and real houses, roads and power lines from OpenStreetMap. You can
take off from one of the built-in places or enter coordinates, and fly wherever the data reaches.

## Built-in places

| Place | What it is | Launches |
|---|---|---|
| `ongudai` | Altai, the Ursul valley near Ongudai, a ridge with the Kayancha pass (flights since the 1980s) | south slope at the Ongudai relay tower, 1870 m, heading 151° |
| `askarovo` | Bashkiria, the Biyagoda ridge near Idyash-Kuskarovo (hang gliding site, Russian Championship 2025) | west at the upper camp 294°, east 94°, south summit 285° |
| `aushkul` | Bashkiria, Lake Aushkul: Mount Austau ("pupyr") and the ridge near Starobayramgulovo | Austau east 119°, Austau south 170°, ridge west 273° |
| `altai` | Manzherok, Malaya Sinyukha (additional place) | 3 launches |

Sources and assumptions for each place are in the `_sources_doc` of the place config, for example
[configs/locations/ongudai.json](/configs/locations/ongudai.json).

## Flight by coordinates

Besides the built-in places, you can enter any coordinates (latitude, longitude) on the place selection map; the terrain
and the surface map are loaded over the network:

```gdscript
terrain.load_location_latlon(43.25, 42.45, 40.0)   # lat, lon, side length in km
await terrain.loaded
```

The point selection map is drawn as a hillshade straight from the same elevation tiles that are loaded for the flight,
with no external map services and no keys (`scripts/terrain/map_picker.gd`).

## Elevation sources

For the built-in places the elevations are **Copernicus DEM GLO-30** (1″ resolution, ≈30 m, cloud-hosted
GeoTIFF, free, no key): the best open quality, newer and cleaner than SRTM. The data is converted to a
flat format in advance (`scripts/terrain/build/dem_stage.gd`, the same code the game uses for any point) and enters the game as a ready layer.

For runtime places (by coordinates) it is **AWS Terrain Tiles** (Mapzen/Tilezen): on land the base is the same
SRTM (≈30 m), more accurate for some regions (Europe: EU-DEM, USA: 3DEP 10 m, above 60° N:
ArcticDEM). Open HTTPS with no key and no limits; the engine itself decodes the PNG tiles.

**Both Copernicus and SRTM are a surface model (DSM), not a ground model (DTM):** in a forest the "elevation" is the top of the canopy
(+15…25 m), and at forest edges and clearings you get steps as tall as a tree. So the detailed layer is slightly
smoothed (σ = 0.8 cell), and the 3D trees are sunk into the surface. There are no open forest-free models
for Altai: FABDEM is licensed under CC-BY-NC (not suitable for a freely distributed game),
and national lidar DTMs cover only individual countries.

Each built-in place stores two nested elevation layers: a detailed one (40 km, 25 m step) and a background one (160 km,
100 m step, Terrarium); the nodes are aligned, so there is no step at the seam. Loading Altai takes 0.2–0.3 s.

## Land cover map

The surface class (forest, meadow, cropland, shrub, rock, water, built-up, snow) comes from **ESA WorldCover 2021**
(10 m, CC-BY 4.0 license). The same map gives the ground color, the places where trees stand, and the strength of the
thermal sources: three things from one file. `surface_stage.gd` reads only the tiles it needs from the COG
(HTTP range requests, no GDAL) and writes the node class as the 3×3 mode of the subsamples.

In addition, for the detailed layer a "10 m detail" mask is built (two channels: R is the forest fraction, G is the water
fraction in a 10 m cell): with it the forest edge and river banks look smooth rather than a "staircase" of 25 m cells.
The water in this mask is supplemented with rivers, canals and streams from OpenStreetMap (width by type: river 25 m,
canal 6 m, stream 4 m) and lakes (OSM polygons). Streams narrower than a cell stay a bank in the shader rather than
solid water; rivers and canals are solid water. The data of the whole location, including this mask, is no more than
15 MB.

For runtime places (by coordinates) this mask does not exist: water is determined by the WorldCover class, as before;
if there is neither network nor data, a fallback procedural map by elevation, slope, aspect and noise
(`SurfaceClassifier`) is used, of the same form as the real one.

## OSM objects: houses, roads, wires, fences

For the built-in places, real OpenStreetMap objects stand on top of the terrain
(`data/terrain/<id>/osm.json`, © OpenStreetMap contributors, ODbL license): roads (a ribbon along the terrain, step
12 m on main roads / 20 m on the rest, visibility 25 km / 4 km), buildings (wall boxes + roof, following the outline
from OSM), power lines (lattice towers 110 kV / poles 10 kV, the wire is a parabola with a sag of
3 % of the span, real thickness 2 cm but never thinner than a pixel; up close it is a line, beyond 500 m it is not drawn, as
in real life), fences at landing fields. Wires have collision.

Rivers and lakes are **not drawn from OSM separately**: the water is already in the terrain coloring (the 10 m mask above);
the OSM water data is in the file and, if desired, the terrain module can use it to replace the river masks built
from drainage. OSM data is exported via the Overpass API (`scripts/terrain/build/osm_stage.gd`) and stored in the repository,
not requested by the game in real time.

For runtime places (by coordinates) there is no OSM data: only windsocks at the launches are placed, without houses,
roads and wires.

## Water

The "water" class sets not only the color but also the behavior: over water the thermal sources are weak (0.05 out of 1 in
strength, versus ≈0.87 for a flat field). Visually the water reacts to the wind: in calm it is a mirror, toward a wind speed of
≈ full roughness ("matte ripple"); the roughness and the direction of the ripple normals run across the
wind; in gust patches the ripple is darker ("cat's paws": less reflected sky), and against the sun it sparkles.
On the side the wind blows from, the water is damped by land and stays a smooth strip (4 samples of the water mask
upwind). Along the shore there is a thin strip of wet ground. For more on wind over water and land, see the
page [Clouds and shadows](/mechanics/clouds/) and the grass section below.

## Forest and vegetation

Three levels of forest seen from altitude:

1. **Terrain canopy** (on the "forest" class itself in the shader): Voronoi crown cells ≈6 m, lighting by the sun,
   shadow from the neighboring crown, dark gaps; at a distance where a single crown is smaller than a pixel, a smooth
   transition to the average canopy tone with patches of stands.
2. **Middle ground** (0.35–3.5 km): tree billboards from an impostor atlas on a 12 m grid.
3. **Near ground** (up to ≈0.7 of the model visibility radius): 3D models, 5 species (birch, larch, cedar,
   spruce, pine) × 3 LODs; the species depends on the altitude belt and slope aspect (spruce on north, pine on
   south dry slopes), and a location can override the species weights.

Trees stand only where the "10 m detail" mask shows forest (fraction ≥ 0.5) and do not stand in water (water
fraction of the mask < 0.35). At the forest edge the trees are denser and less sunk: the edge looks more voluminous rather than
ending in a wall. Clearings (roads, the power line corridor, buildings, planted fields) cut out trees with an explicit mask
(`WorldClearings`): neither a model nor an impostor lands there.

The grass blades around the camera, their thinning and swaying in the wind are a separate mechanic; see
[docs/guide/vegetation.md](/docs/guide/vegetation.md) (parameters and graphics presets) and the "Wind on the ground" section below.

## How the terrain is built and loaded

**Mesh.** Each elevation layer is cut into chunks; all chunks of a layer share flat grids of several LODs
(step 1, 2, 4… cells), and the vertex shader adds the elevation by sampling the height texture, so
building the mesh is instant. The LOD is switched by the camera distance to the chunk; gaps between levels
are closed by a "skirt". There is no collision as such: flight and landing use the `height_at` function
(bilinear interpolation of the most detailed layer covering the point; ≈1.6 µs per call).

**Runtime loading** (flight by coordinates) does not hang the main thread: elevation tiles and cover maps
are downloaded via `HTTPRequest` in background threads, and the assembly of the mesh, trees and grass proceeds frame by frame in a worker
thread while the loading screen shows the stages and the progress fraction. At high latitudes a web Mercator
pixel shrinks as cos(latitude), so the tile level is lowered automatically to keep the grid from
ballooning (for example, near Greenland at 72° N).

**Errors** return to the menu with a clear message: no connection to the terrain server, no data for the point
(tile 403/404), the point is sea (elevation below sea level with no cover map showing land nearby), the terrain server
does not respond (timeout on unchanged progress).

## Model limits

- **Resolution.** Elevations are 25 m for built-in places (30 m for runtime places), the cover map is 10 m for the
  detailed mask / 25 m for the general class map. The terrain distinguishes nothing finer than this: rocks,
  paths and individual bushes on the map are not "real" but a procedural pattern following statistics.
- **DSM, not DTM.** The elevation in a forest is the top of the canopy, not the ground beneath it; landing in a forest is a collision
  with the crowns, not a descent through them to the ground.
- **Not everything is taken from OSM.** Roads, buildings, power lines and fences at landing fields are drawn; rivers and lakes are taken not
  from the OSM geometry but from the general water map (10 m mask / WorldCover class). Other OSM objects (bridges,
  small forms, yards) are not displayed.
- **Runtime places are poorer than built-in ones**: no OSM (no houses, roads, wires, fences), no 10 m water
  mask (water only by the WorldCover class), no specially placed landing fields: only the
  chosen point and a heading down the slope.
- **The data budget** is no more than 15 MB per built-in place (elevations + cover map + masks), so
  some details (for example, stream width by OSM tag) are deliberately not taken into account.
- **Thermals are tied to the same map** as the ground color: if WorldCover gets a class wrong (a typical
  error of satellite classification is to mistake a floodplain for forest), it shows up equally in the thermals and in the picture;
  the model does not "peek" at the right answer separately from what the pilot sees.

## What was considered and why it is done this way

- **Map tiles for the place selection screen.** The standard `tile.openstreetmap.org` tiles under their usage
  policy are only for moderate traffic with attribution and no bulk prefetching; for a distributed game
  with no guaranteed limit this does not fit. Paid services (MapTiler, Thunderforest) would require embedding an API key
  in open code. Our own OSM tile server is an option for the future but requires infrastructure. The choice was a terrain hillshade
  from the same elevation tiles that are needed for flight anyway: no external services or keys, and mountains and valleys read better
  to a pilot than roads.
- **DEM for runtime.** Copernicus DEM is better in quality, but it cannot be bundled into the game for runtime points across the world
  (the whole globe is not 15 MB). OpenTopography offers a convenient API but requires a key and is limited
  in area and daily request count, which does not suit a game on a random user's machine. AWS Terrain Tiles
  are open PNG tiles with no key and no limits, decoded by the engine itself; the quality is slightly lower
  than Copernicus (SRTM steps in places), but good enough for flight.
- **No forest-free DTM was found** with a suitable license (FABDEM is CC-BY-NC), so instead of trying to remove the
  forest from the elevations, simple smoothing plus sinking the 3D tree models into the surface was chosen.
- **One map for three tasks.** The ground color, the placement of trees and the strength of thermals could have lived in
  three different structures; we decided to keep one surface map as the single source of truth, which is
  both simpler and keeps the picture from diverging from the thermal model.

## More

- [docs/guide/terrain.md](/docs/guide/terrain.md): the full structure of the terrain module (files, formulas, parameters).
- [docs/research/terrain_sources.md](/docs/research/terrain_sources.md): comparison of elevation sources and
  map basemaps.
- [docs/guide/world-objects.md](/docs/guide/world-objects.md): OSM objects, landing fields, windsocks,
  the camp and campfire at the launch.
- [docs/guide/vegetation.md](/docs/guide/vegetation.md): grass blades and trees along the forest edge.
- Code: [scripts/terrain/](/scripts/terrain/), [scripts/world_objects/](/scripts/world_objects/).
- Place data preparation: [scripts/terrain/build/dem_stage.gd](/scripts/terrain/build/dem_stage.gd),
  [scripts/terrain/build/surface_stage.gd](/scripts/terrain/build/surface_stage.gd),
  [scripts/terrain/build/osm_stage.gd](/scripts/terrain/build/osm_stage.gd).

![Wind over water: calm, gusts of 3 and 6 m/s](/releases/0.7.0/screenshots/99_вода_ветер_0_3_6.jpg "Wind over water: calm, gusts of 3 and 6 m/s")

![Campfire at the launch camp, the smoke is carried by the real wind](/releases/0.7.0/screenshots/103_костёр_со_старта_штиль.jpg "Campfire at the launch camp")

![Place Altai: the real terrain of the Ursul valley](/docs/screenshots/e2e/ongudai_flight.jpg "Ongudai, the Ursul valley")
