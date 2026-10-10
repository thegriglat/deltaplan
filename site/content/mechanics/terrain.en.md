---
title: "Terrain and places"
weight: 50
description: "Built-in places and flight by coordinates, sources of elevation and land cover, water, villages and forest: how a place is built and what its limits are."
---

# Terrain and places

The terrain is not just a "mountain made of noise": underneath it are the real elevations of a specific place on Earth and a
real land cover map (forest, meadow, field, water, built-up area). You can take off from one of the built-in places or
pick a point on the map and fly wherever the data reaches. There is no OpenStreetMap data in a place at all: no files and
no network requests at build time (only the raster basemap of the place selection map remains).

## Built-in places

| Place | What it is | Launches |
|---|---|---|
| `ongudai` | Altai, the Ursul valley near Ongudai, a ridge with the Kayancha pass (flights since the 1980s) | south slope at the Ongudai relay tower, 1870 m, heading 151° |
| `askarovo` | Bashkiria, the Biyagoda ridge near Idyash-Kuskarovo (hang gliding site, Russian Championship 2025) | west at the upper camp 294°, east 94°, south summit 285° |
| `aushkul` | Bashkiria, Lake Aushkul: Mount Austau ("pupyr") and the ridge near Starobayramgulovo | Austau east 119°, Austau south 170°, ridge west 273° |
| `altai` | Manzherok, Malaya Sinyukha (additional place) | 3 launches |

Sources and assumptions for each place are in the `_sources_doc` of the place config, for example
[configs/locations/ongudai.json](/configs/locations/ongudai.json).

## Building a place and flight by coordinates

A built-in place and any point on the map get the same set of layers: the code is one, the place builder
(`scripts/terrain/build/`), and the stages run in order: terrain (Copernicus GLO-30 + Terrarium), rivers from the
terrain, ESA WorldCover 10 m land cover. The game package holds no place data: the four built-in places are **downloaded
on first selection** and cached in `user://locations/<key>`. A cache with a different format version (`FORMAT_VERSION`) is
deleted and rebuilt. Example: the first build of `aushkul` with an empty cache takes 55.8 s and 166 requests.
Place data is stored as lossless WebP; elevations are 24 bit with a 1/32 m step (error against float32 is 0).

The loading screen shows a request counter ("Terrain: N/M", "Cover: N/M", "Total: N/M"); there are no time estimates.
If the cover could not be fetched, the flight goes on without that layer (procedural cover, no 10 m water and no houses),
and the next run fetches only what is missing. Without terrain there is no place: a message and a return to the menu.
Details: [docs/guide/location-data.md](/docs/guide/location-data.md).

The place selection map is a raster basemap from tiles (`scripts/terrain/map_picker.gd`): OpenTopoMap by default or the
standard OpenStreetMap tiles, with a disk cache and attribution on the map. It is a menu basemap and provides no place data.

## Elevation sources

The detail layer (40 km, 25 m step) is **Copernicus DEM GLO-30** (1″ resolution, ≈30 m, cloud-hosted GeoTIFF, free,
no key): the best open quality, newer and cleaner than SRTM. Only the needed internal tiles are read (HTTP range
requests), with smoothing σ = 0.8 cell. The background layer (160 km, 100 m step) is **Terrarium** (AWS Terrain Tiles,
Mapzen/Tilezen, z10): on land the base is the same SRTM, more accurate in some regions (Europe: EU-DEM, USA: 3DEP 10 m,
above 60° N: ArcticDEM). The detail layer is pasted into the background one, the nodes are aligned, and there is no step at the seam.

**Both Copernicus and SRTM are a surface model (DSM), not a ground model (DTM):** in a forest the "elevation" is the
top of the crowns (+15…25 m), and at forest edges and clearings there are steps the height of a tree. So the detail
layer is slightly smoothed and the 3D trees are sunk into the surface. There are no open forest-free models for Altai:
FABDEM is licensed CC-BY-NC (unsuitable for a freely distributed game), and national lidar DTMs cover only individual countries.

## Land cover map

The surface class (forest, meadow, arable, shrub, rock, water, built-up, snow) comes from **ESA WorldCover 2021**
(10 m, CC-BY 4.0). The same map gives the ground color, where trees stand, and the strength of thermal
sources: three things from one file. The cover stage reads only the needed COG tiles (HTTP range requests, no GDAL) and
writes the node class as the mode of 3×3 subsamples.

For the detail layer a "10 m detail" mask is built (R is the forest fraction, G is the water fraction in a 10 m cell):
it makes forest edges and banks look smooth rather than a "staircase" of 25 m cells. Water in the mask is `max(WorldCover
"water" class fraction, river mask from the terrain)`. Rivers are computed from the terrain itself (drainage over the
background layer, width from the catchment area) and resampled bilinearly onto the 10 m grid; WorldCover sees lakes of
≥ 10 ha by itself. The trade-off: small and narrow water bodies are seen worse by WorldCover, and reservoir outlines
follow the 2021 state. The cover is a single snapshot: new buildings, a changed shoreline and clear-cuts are not visible.

If there is no cover (no network), a fallback procedural map by height, slope, aspect and noise (`SurfaceClassifier`)
is used, of the same form as the real one.

## Villages and the trail to the launch

There are no roads, power lines or fences in the game. There are village houses, windsocks, landing fields of the
built-in places, and a trail from the launch.

**Villages.** The only source is the WorldCover "built-up" class: the cover stage writes the built-up basemap
`detail_built10` (built-up fraction in a 10 m cell) and patches, 8-connected components of cells with fraction ≥ 0.5 and
area ≥ 3000 m². Inside a patch `VillagePlacer` lays out a grid of yards (≈ 520 m²) with a random offset; a yard is
occupied with probability equal to the built-up fraction; it holds a procedural house (6×8…8×10 m, gable roof), with
probability 0.7 a shed and 0.3 a bathhouse (banya). There are no houses on slopes steeper than 14°; a house is turned along the
contour by slope, and at a patch edge parallel to the edge. The generator is deterministic by place and patch, so everyone
in a network session sees the same houses. The built-up basemap is blurred: soft edges, no sharp patch outline. Outlines of
real buildings and village names are not reproduced. Clearings (buildings, planted fields) cut out trees with an explicit mask.

**Trail.** A footpath dirt trail down the slope from each launch is always procedural: there is no road or village
to attach it to.

Details: [docs/guide/world-objects.md](/docs/guide/world-objects.md).

## Water

The "water" class sets not only the color but also the behavior: over water there are no thermals (on a summer day water is colder
than the air and cools it; in the evening warm water heats it; see [Thermals](/mechanics/air-model/thermals/)). Visually the water reacts to the wind: in calm it is a mirror, toward a wind speed of
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
ending in a wall. Clearings (buildings, planted fields) cut out trees with an explicit mask
(`WorldClearings`): neither a model nor an impostor lands there.

The grass blades around the camera, their thinning and swaying in the wind are a separate mechanic; see
[docs/guide/vegetation.md](/docs/guide/vegetation.md) (parameters and graphics presets) and the "Wind on the ground" section below.

## How the terrain is built and loaded

**Mesh.** Each elevation layer is cut into chunks; all chunks of a layer share flat grids of several LODs
(step 1, 2, 4… cells), and the vertex shader adds the elevation by sampling the height texture, so
building the mesh is instant. The LOD is switched by the camera distance to the chunk; gaps between levels
are closed by a "skirt". There is no collision as such: flight and landing use the `height_at` function
(bilinear interpolation of the most detailed layer covering the point; ≈1.6 µs per call).

**Place loading** does not hang the main thread: elevation and cover blocks are downloaded via `HTTPRequest` (blocks are
cached in `user://terrain_cache`, and a neighboring place takes them from there), heavy computation runs in the
`WorkerThreadPool`, and the assembly of the mesh, trees and grass proceeds frame by frame while the loading screen shows the request counter. At high latitudes a web Mercator
pixel shrinks as cos(latitude), so the tile level is lowered automatically to keep the grid from
ballooning (for example, near Greenland at 72° N).

**Errors** return to the menu with a clear message: no connection to the terrain server, no data for the point
(tile 403/404), the point is sea (elevation below sea level with no cover map showing land nearby), the terrain server
does not respond (timeout on unchanged progress).

## Model limits

- **Resolution.** Elevations are 25 m for the detail layer (100 m for the background one), the cover map is 10 m for the
  detail mask / 25 m for the general class map. The terrain distinguishes nothing finer: rocks, paths and
  individual bushes on the map are not "real" but a procedural pattern following statistics.
- **DSM, not DTM.** The elevation in a forest is the top of the crowns, not the ground below; landing in a forest is
  a collision with the crowns, not a descent through them to the ground.
- **Objects.** No roads, power lines, fences, village names or outlines of real buildings; houses on built-up patches are procedural.
- **Launches and landings.** Named launches and landing fields are manual data only for built-in places; for an arbitrary
  point the launch is at the chosen point, heading down the slope.
- **Time zone** is by longitude (`round(lon/15)`); the game does not know time zone borders.
- **Thermals are tied to the same map** as the ground color: if WorldCover got a class wrong (a typical
  satellite classification error is to mistake a floodplain for forest), it shows equally in the thermals and in the picture;
  the model does not "peek" at the right answer separately from what the pilot sees.

## What was considered and why it is done this way

- **One path for built-in places and any point.** Built-in places used to have pre-built data (including OpenStreetMap)
  and points by coordinates poorer data. Now the build code is one and there is no OSM data: WorldCover patches give
  the built-up areas, the terrain gives the rivers, and a place is equally rich everywhere. The price: no roads or
  power lines, houses are procedural, small water bodies are seen worse.
- **Lakes and rivers without OSM.** WorldCover sees lakes of ≥ 10 ha by itself (coverage of OSM polygons 0.85–0.98 at
  Aushkul, Chebarkul, Atavda, Muldakkul), and rivers are computed from drainage. Details: `docs/research/lakes_worldcover.md`.
- **Map tiles for the place selection screen.** Standard `tile.openstreetmap.org` tiles are, by usage policy, for
  moderate traffic with attribution and no bulk prefetching; so the default basemap is OpenTopoMap with a disk cache.
  Paid services (MapTiler, Thunderforest) would require embedding an API key in open code.
- **DEM.** Copernicus is better in quality than the SRTM-based Terrarium tiles, but the whole globe cannot be bundled into the
  game as a ready layer; so the detail layer is taken from the Copernicus COG when a place is built, and the background from Terrarium
  (open PNG tiles with no key, decoded by the engine itself). OpenTopography requires a key and limits the number of requests.
- **No forest-free DTM was found** with a suitable license (FABDEM is CC-BY-NC), so instead of trying to remove the
  forest from the elevations, simple smoothing plus sinking the 3D tree models into the surface was chosen.
- **One map for three tasks.** The ground color, the placement of trees and the strength of thermals could have lived in
  three different structures; we decided to keep one surface map as the single source of truth, which is
  both simpler and keeps the picture from diverging from the thermal model.

## More

- [docs/guide/terrain.md](/docs/guide/terrain.md): the full structure of the terrain module (files, formulas, parameters).
- [docs/research/terrain_sources.md](/docs/research/terrain_sources.md): comparison of elevation sources and
  map basemaps.
- [docs/guide/location-data.md](/docs/guide/location-data.md): place building: stages, formats, cache, loading counter.
- [docs/guide/world-objects.md](/docs/guide/world-objects.md): villages, trail, landing fields, windsocks,
  the camp and campfire at the launch.
- [docs/guide/vegetation.md](/docs/guide/vegetation.md): grass blades and trees along the forest edge.
- Code: [scripts/terrain/](/scripts/terrain/), [scripts/world_objects/](/scripts/world_objects/).
- Place data building: [scripts/terrain/build/dem_stage.gd](/scripts/terrain/build/dem_stage.gd),
  [scripts/terrain/build/river_stage.gd](/scripts/terrain/build/river_stage.gd),
  [scripts/terrain/build/surface_stage.gd](/scripts/terrain/build/surface_stage.gd).

![Wind over water: calm, gusts of 3 and 6 m/s](/releases/0.7.0/screenshots/99_вода_ветер_0_3_6.jpg "Wind over water: calm, gusts of 3 and 6 m/s")

![Campfire at the launch camp, the smoke is carried by the real wind](/releases/0.7.0/screenshots/103_костёр_со_старта_штиль.jpg "Campfire at the launch camp")

![Place Altai: the real terrain of the Ursul valley](/docs/screenshots/e2e/ongudai_flight.jpg "Ongudai, the Ursul valley")
