---
title: "Clouds and shadows"
weight: 45
description: "The cloud field: how cumulus is born from the air above a place, lives and dissolves; the shadow shaped like the cloud, the penumbra, and how it ties to thermals."
---

# Clouds and shadows

Cumulus in the game is not "one cloud per thermal" but a **cloud field** over the whole place: it grows where the lifted
air has reached the condensation level, stays while the lift works, dissolves with a delay and is carried off by the
wind. A cloud's shadow on the ground is not a decorative blob but an honest shadow of exactly that shape, and where it
lies, new thermals are weaker.

## How the cloud field is born

A cloud is visible only where the air has risen high enough to cool to saturation. That height is the **condensation
level**; it is one for the whole place and day, so all clouds of the day share one flat base. Its height depends on the
air temperature and the dew point; the game takes the dew point from the place's climate (there is no separate humidity
by height or by area, see "Model limits").

The model then works on a grid of 96 x 96 cells of 400 m (38 x 38 km around the place; the step is 20 game seconds,
computed in a separate thread). Each cell stores:

- what share of the area is covered by **active** cloud, above a working lift;
- what share is **passive**: the lift has gone, the cloud still stands and dissolves;
- the cloud depth, its height above the base;
- the accumulated "overdevelopment", a sign that a tall tower grows here.

**Where a cloud comes from.** There are three sources: convection of the air field (what the game computes as thermals:
the ceiling and the flow at the base from [Thermals](/mechanics/air-model/thermals/)), lift of air on a windward slope,
and, if there is no air field, the live thermals of the older analytic model. A cloud appears where the lift reaches the
condensation level: the higher the thermal ceiling above the base, the more of the flow reaches it. If the ceiling barely
reaches it, a sparse scatter remains; if it is below the base, the day is cloudless (a "blue day").

**A cloud's life in time** (the numbers come from the literature on cumulus, not fitted to the pictures):

| stage | time |
|---|---|
| the cloud fills after the lift reaches the base | 4 min |
| the lift under the cloud works | 15 min |
| the passive cloud dissolves | 20 min x (depth / 1 km), factor from 1/2 to 2 |

So thin cumulus dissolve 5-10 minutes after the lift is gone, deep ones last 20-40. Five minutes after the lift is gone,
more than half of the cover remains; after 90 minutes, less than a tenth. A cloud does not appear or vanish in one frame.
Because of the slow dissolving there is more cloud than lift: at 1 km depth the cover is about 2.3 times the area of the
active clouds. That is why a strong day is not necessarily "cloudier" than a weak one by cover, but its clouds are deeper
and live longer.

**Depth** is the height the air parcel reaches above the base (with a correction for the moist adiabat: inside the cloud
it loses buoyancy more slowly, up to three times), but not more than the day's limit from the weather model. In some
cells of a strong day, under a steady lift, the cloud accumulates overdevelopment for 30 minutes and grows to 2.5 km:
tall towers. Thunderstorm clouds are not part of this field (see below).

**Drift.** The wind at base height carries the clouds; in wind they stretch along it and can line up into streets along
the wind. The noise inside a cloud also "flows" with the wind, while the shape stands above its lift.

![The cloud field over Almaty on a strong day: cover at 11, 13 and 15 hours](cloud-field-almaty-hours.jpg "Cover by hour")

Three frames of one day, Almaty, +31 C, wind 18 km/h, at 11, 13 and 15 hours: white is cover, the blue contour shows
where it exceeds 0.3, red dots are thermal sources. The cover is concentrated over the mountains and foothills at the
bottom of the frame, and the wind (the arrow) carries the clouds to the right; over the plain there is less cloud, but
there is some (more on that below).

**What can be read from the cloud itself** (shape and stage, without labels):
- **growing**: wisps gather into a dense cloud with sharp "cauliflower" edges, and growth is noticeable over 1-3 minutes of observation;
- **mature**: tall, dense, with a flat dark base; while the lift is alive, the base is darker and denser (the inflow is visible);
- **decaying**: ragged, translucent, with a raised ragged rim, it sinks and drifts off with the wind.

The shape is built from eight semi-ellipsoid "towers" with a wide central dome and is filled with 3D noise
(Perlin-Worley and Worley), so the edges billow rather than being smooth. The height-to-width ratio is larger on
overdeveloped days: fair-weather cumulus are wider than tall. A new cloud fades in over ~40 s, a decaying one
disappears in about a minute.

![Cumulus over Almaty in the game, a view from above the city](cloud-field-almaty-view.jpg "Field clouds in the game, Almaty")

### Different days, different places

The same calculation, days of 15 July, 13:00 (cover is the average over the 38 x 38 km grid):

| place, weather | base, m | mixed-layer top z_i, m | cover | clouds (cover >= 0.3) |
|---|---|---|---|---|
| Ongudai, weak | 2117 | 2462 | 0.19 | 58 small, up to 18 x 11 km |
| Ongudai, strong | 3459 | 4359 | 0.23 | 50, up to 27 x 8 km along the wind |
| Almaty, weak | 2079 | 2374 | 0.33 | 10, up to 41 x 19 km along the ridge |
| Almaty, strong | 3421 | 4271 | 0.33 | 21, up to 50 x 37 km |
| training island, weak | 1259 | 1004 | 0.001 | none (blue day) |

On a weak day over Ongudai it is a scatter over the crests: cover above the top fifth of the terrain is three times
higher than over the lowlands. On a strong day it is streaks along the wind, with crests and valleys about equal. Over
the island a weak day is blue: the thermal ceiling is below the base.

![A cross-section across the ridge at Almaty and the course of cloudiness from 9 to 17 hours](cloud-field-almaty-section.jpg "Cross-section across the ridge and the course of cloudiness")

On the left, a cross-section across the ridge at 13 hours: terrain, the cloud base (blue dashed line) and the ceiling
of the air parcels (green); the clouds lie between them. On the right, the course of the day: almost clear until 10:30,
then the cover grows with the heating and stays around 0.32-0.34 from 12 to 17 hours, with depth reaching 1.6 km.

## Terrain: the air layer follows the mountains

The thermal ceiling (the top of the mixed layer, z_i) is not the same over mountains and valleys. In the model it
**partly follows the terrain**: z_i(x) = the day's z_i + 1/3 x (smoothed terrain - valley level), smoothing 5 km. The
share 1/3 is an order of magnitude from a review of observations over the Alps, the Rockies and the Black Forest
(De Wekker & Kossmann, 2015): the layer over ridges is higher than over valleys, in a muted form. It does not repeat
narrow crests and gorges.

What this gives: the thermal ceiling over mountains is higher, by ~100 m at the median in Ongudai, and in Almaty on a
strong day by 150 m at the median and up to +414 m for the top 10% (ridge of 3-4 km). The cloud base is the same, so the
clouds over ridges get more margin above the base and last longer: the area of clouds >= 0.3 grew by a third to a half
(Ongudai 0.10 -> 0.18, Almaty 0.40 -> 0.47). Over flat terrain (Askarovo, small relief range) the correction is hardly
noticeable, as it should be.

![Almaty: a cross-section before and after accounting for terrain, ceilings of thermal sources](cloud-field-zi-before-after.jpg "Layer ceiling before and after")

On the left and in the middle, a cross-section across the ridge without and with the correction: the purple line is the
column z_i (it was flat and now rises toward the mountains), the green one is the parcel ceiling. On the right, the
ceilings of thermal sources before and after: the median 4950 -> 5097 m, the upper edge 5093 -> 5507 m.

## Subsidence over the plain

By day the air rises over the ridge, and over the plain it is supposed to sink weakly: this is the return branch of the
mountain-plain circulation. The model accounts for **only its mesoscale part**: the vertical flow of the air field,
smoothed to ~10 km. Over the plain near Almaty it is about -1 cm/s, over the ridge +1 cm/s; the sinking air lowers the
layer ceiling over the column: by 130 m on average, by 380 m for the top 10%. Small cells of organized convection
(neighboring cells differ by +-0.1 m/s) are not included: they are part of the layer itself.

![Almaty: the vertical flow of the air field, its mesoscale part and the ceilings of sources](cloud-field-subsidence.jpg "Circulation subsidence")

The result is modest: over the plain the cover decreases by only a tenth (0.25 -> 0.23). The expectation "clearly clear
over the city, cover <= 0.1" is **not met**, and will not come out of this physics: for the city to be clear, drier air
over the plain (a higher base) is needed, and the dew point in the model is one per place.

## Special clouds

Field cumulus are not all the clouds of the game. The rest are separate records, built by the same shader from the same
physical model (details in [docs/guide/atmosphere/clouds.md](/docs/guide/atmosphere/clouds.md)):
- cumulonimbus (`storm_field.gd`): strong mature thermals overdevelop into a tower up to the tropopause with an anvil,
  and below the base a rain shaft of soft translucent streaks; beneath it a downdraft, outflow along the ground
  and a gust front. Thunderstorms are rare in the model: from hundredths of a percent per thermal at a small
  temperature margin to 0.5% at a large one;
- lenticular lenses, a cap on the highest point of the terrain and rotor fragments in the crests of a lee wave (`wave_field.gd`);
- an upper-level cirrus veil (`cirrus_layer.gd`): ribbons of fibres along the wind; it suppresses thermals (lower
  insolation) and makes cumulus shadows paler.

For details on the thermal itself, its strength, the shape of the flow, the updraft speed and how the airflow beneath
the cloud is born and dies, see the page [Thermals](/mechanics/air-model/thermals/); only the above-ground, visible
part is described here.

## Cloud shadows

A cloud **blocks only the direct sunlight**; the diffuse light of the sky beneath it remains, so the shadow does not
turn into a black blot. The shadow is drawn in a separate pass (`CloudShadowMap`): a map around the
camera (32 km side) is redrawn every 3 frames, and for each of its points the transmission of direct light is computed
by the Beer absorption formula through the very same cloud density that is drawn overhead. The shadow
therefore **repeats the cloud's shape exactly**, including the billows and the thinned edges of a decaying one, drifts
along with it and fades with it.

The shadow falls on terrain, grass, forest (models, impostors and procedural crowns alike), bushes and rocks. All
of them use the same lighting formula, attenuated by the cloud's transparency at that point. The part of
the sky covered by the cloud is also slightly darker (diffuse light), but less so than direct light. Toward the edge of the map the shadows
fade smoothly into haze; under a cirrus veil of the upper layer (if there is one) the shadows of all cumulus clouds are
paler, as in reality when the sun is already partly scattered by high cloud.

## Penumbra

The shadow does not end in a sharp line: at the edge of the shadow map and at the cloud's rim there is a smooth transition (soft
falloff), not a visible/invisible "step". The game's own sun shadow (terrain, trees,
wing) is also soft, with the angular size of the solar disk, so objects at the edge of a cloud shadow
get a true penumbra rather than two crisp states, "light" and "dark".

## Thermals are weaker in the shade

This is not only a picture: the thermal model knows about the same clouds that are drawn in the sky, and a **new
thermal born in the shade of a cloud is weaker** than in the sun: its strength and heating are reduced by 0.6 x shade.
The shade for this calculation comes from the cloud field: the cover times (1 - exp(-depth / 60 m)), along the ray from
the ground to the sun up to the base, so a 100 m cloud already blocks the sun. A pilot reading the shadows below sees
the same division of the ground into "heating" and "not heating" that the model uses.

## Model limits

- **Humidity is one dew point per place** (from climate), with no dry and moist air by height and no difference between
  mountain and plain. Hence the base is flat and common for the whole day, there is no evening rise of the base, and over
  the plain the clouds are not as sparse as in real life (see "Subsidence over the plain").
- **There is no comparison with observations**: no satellite images and no pilot records for these places. The reference
  was the expectation for Almaty (a streak along the main ridge, a base at 3-3.5 km, summits in cloud): the base and
  the clouds on the ridge matched; the streak matched only on a weak day (on a strong one a continuous sheet of 50 x 37
  km comes out); clear over the city did not match.
- **The passive cloud dissolves exponentially** with one time for all weather, without the humidity of the surroundings;
  overdevelopment is only growth of depth, not thunderstorm physics (such a cloud has no rain, downdraft or anvil; that
  is Cb).
- **There are no cloud streets from convective rolls**: the field does not produce them; streaks along the wind come
  only from drift.
- **The air field changes in steps** every 15 game minutes (new inputs are blended in over a minute); there is no real
  daily course between fields.
- **Drift smears the cloud edge** by about one cell (400 m) per hour, a consequence of the numerical transport.
- **Field cumulus exist only in the main render mode** (Forward+/Mobile). In the integrated-graphics mode
  (Compatibility) only lenses, the cap and thunderstorm clouds are drawn; by the author's decision the target renderer
  is Forward+.
- **The shadow is not a global map** but a window of fixed size around the camera (32 km): clouds beyond it
  cast no shadow on the visible scene (nor is that needed, as they cannot be seen anyway).
- **Thunderstorm cells, wave and cirrus are simplified images**: the anvil has no mammatus, a Cb looks like a "mushroom" from afar (in real ones the body is more massive and wider), the lenticular lenses are smooth and the "stack of plates" is faint.
- **The cloud density is approximate**: a raymarch over several geometrically growing steps toward the sun, not
  a true multiple-scattering simulation. This is enough for the base to be darker than the edges and
  darker over a live thermal, but there will be no exact photometry.
- **Different render paths differ in cost and slightly in picture**: the main path (Forward+/Mobile) is
  one shared raymarch pass per frame in a reduced-resolution buffer (0.33/0.5/0.75 by quality preset) with depth-aware upscaling, the path for integrated graphics (Compatibility) is a box per
  cloud. In Compatibility there is a known visual problem: some clouds are split by a
  vertical boundary into two halves of different brightness with a "stepped" edge. It is deliberately not
  fixed.
- **The cost of the field layer is an estimate, not a measurement against the previous version**: on a strong day at
  Ongudai (cover about 0.19) a 1080p frame costs 1.2-1.7 ms of GPU more than without the layer (4.5-6.1 versus 3.3-4.3 ms).
- **The shadow does not account for interreflection** from neighboring clouds or terrain, only direct shading by the
  cloud thickness above the point.
- The thermal model and its cloud are **not recomputed at every physics step**: the cloud and its shadow
  are recomputed noticeably less often than the frame, so with a sharp change of lighting (for example, after a quick
  turn) the shadow can lag the actual cloud shape for a fraction of a second.

## What was considered and why this way

- **A cloud field vs one cloud per thermal.** Before, each cloud was tied to one thermal and lived together with it. The
  field instead computes the share of sky under cloud in every cell: a lift fills the cloud in minutes, and the cloud
  keeps dissolving after the lift has gone. The cost is a somewhat heavier calculation (a 96 x 96 grid step takes 6-7 ms
  on the development machine, once per 20 game seconds, in a separate thread) and the honest limits listed above. The
  old path remains as a fallback: without an air field, clouds are built from live thermals.
- **The layer top follows terrain by 1/3, not "fully" and not "not at all".** Without the correction the ceiling and the
  clouds over ridges do not differ from valley ones; the layer does not repeat the terrain fully (observations show a
  muted form, of the order of 1/3 of the height difference). The 1/3 and the 5 km smoothing are taken from a review of
  observations, not fitted to the maps.
- **Decals vs an analytic shadow map.** Cloud shadows used to be drawn as decals: flat blots
  under each cloud with no true shape and no penumbra. Decals were dropped in favor of
  `CloudShadowMap`: the map computes the real light transmission through the same density as the visible
  cloud, so the shadow automatically follows the cloud's life stage (a ragged shadow for a decaying cloud,
  a dense one for a mature one) without separate hand animation.
- **A quality/cost trade-off.** A full volumetric shadow pass for every light source on
  every scene object would cost more than the performance budget on integrated graphics allows.
  A separate small pass was chosen (a SubViewport with a flat map), with resolution and number of
  ray steps configurable by quality presets. On a powerful graphics card it is a fraction of a GPU millisecond per redraw; on a
  weak one the map resolution can be lowered without losing the principle itself (the shadow shape is still real).
- **A reference plane under the camera**, rather than a true projection onto all the terrain: the shadow map is built on the ground
  under the camera and works correctly for terrain of any height in that area. It is cheaper than a true
  shadow trace over all the visible terrain, and for flight purposes (the shadow is needed where the pilot is, not beyond the
  horizon) it is enough.
- **The Compatibility renderer was not specially fixed**: the visual artifact with the cloud split is known, but
  the user's decision is to treat Forward+ as the target renderer and to support integrated graphics as far as
  possible without rewriting the cloud shader for it from scratch.

## More

- [docs/guide/atmosphere.md](/docs/guide/atmosphere.md): the full design of the atmosphere module: thermals, clouds, shadows,
  dangerous weather (thunderstorms, wave, cirrus veil, dust devils); the field clouds are in
  [docs/guide/atmosphere/clouds.md](/docs/guide/atmosphere/clouds.md).
- Research on the cloud field (formulas, parameters with sources, maps by place):
  [docs/research/cloud_field.md](/docs/research/cloud_field.md) and
  [docs/research/cloud_field/subsidence.md](/docs/research/cloud_field/subsidence.md).
- Field code: [scripts/atmosphere/cloud_field.gd](/scripts/atmosphere/cloud_field.gd),
  [scripts/atmosphere/cloud_field_sources.gd](/scripts/atmosphere/cloud_field_sources.gd), the layer top by terrain:
  [scripts/atmosphere/air_model/air_zi_terrain.gd](/scripts/atmosphere/air_model/air_zi_terrain.gd); parameters in
  `configs/atmosphere.json`, section `cloud_field`. In multiplayer every client computes the field, the host sends a
  snapshot every 30 s and the others catch up to it over 10 s.
- Cloud and shadow code: [scripts/atmosphere/cloud_layer.gd](/scripts/atmosphere/cloud_layer.gd),
  [scripts/atmosphere/cloud_shadow_map.gd](/scripts/atmosphere/cloud_shadow_map.gd),
  [scripts/atmosphere/cloud_common.gdshaderinc](/scripts/atmosphere/cloud_common.gdshaderinc),
  [scripts/terrain/cloud_shadow.gdshaderinc](/scripts/terrain/cloud_shadow.gdshaderinc).
- Cloud noise generator: [tools/atmosphere/gen_cloud_noise.py](/tools/atmosphere/gen_cloud_noise.py).

![Cloud shadows over the valley, before the shadow shape rework](/releases/0.7.0/screenshots/113_тени_облаков_долина_до.jpg "Cloud shadows over the valley, before")

![Cloud shadows over the valley, after: the shadow repeats the cloud's shape](/releases/0.7.0/screenshots/114_тени_облаков_долина_после.jpg "Cloud shadows over the valley, after")

![Cloud shadows from the air, from above](/releases/0.7.0/screenshots/116_тени_облаков_сверху_после.jpg "Cloud shadows from above")

![Water ripples and cloud shadows in cloudy weather](/releases/0.7.1/screenshots/134_рябь_тени_облачно_до_после.jpg "Water ripples and cloud shadows")
