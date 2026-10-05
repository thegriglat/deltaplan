---
title: "Clouds and shadows"
weight: 45
description: "Cumulus clouds and their life cycle, the shadow shaped like the cloud, the penumbra, and how it all ties to the thermals beneath them."
---

# Clouds and shadows

Every cumulus cloud in the game stands above a real thermal of the atmosphere model and repeats its life:
it is born, grows, lives and falls apart. A cloud's shadow on the ground is not a decorative blob but an honest shadow
of exactly that shape, and where it lies, the thermals beneath it are weaker.

## Cumulus clouds and their life cycle

A cloud appears when the thermal's air has reached the condensation height (with a delay proportional to
the cloud height and the strength of the updraft), and dissolves some time after the thermal has died. The shape
is built from eight semi-ellipsoid "towers" with a wide central dome and is filled with 3D noise
(Perlin-Worley and Worley), which gives billowing rather than smooth edges. The cloud's aspect ratio (height to
width) is larger on overdeveloped days: fair-weather cumulus are wider than they are tall, and tall towers
appear only with overdevelopment.

**The stage can be read from the cloud itself**, without labels:
- **growing**: wisps gather into a dense cloud with sharp "cauliflower" edges, and growth is noticeable over
  1–3 minutes of observation;
- **mature**: tall, dense, with a flat dark base; while the thermal is alive, the base is darker and
  denser (the inflow is visible);
- **decaying**: ragged, translucent, with a raised ragged rim, it sinks and drifts off with the wind.

The base is at the same height for all clouds of the day (the condensation level). In wind, clouds
stretch along it and can line up into cloud streets along the wind; the noise inside a cloud itself "flows",
carried by the wind at the height of the rim, while the shape stays above its thermal. A weak day has
few thermals stronger than `cloud_min_strength_ms`, and the sky is almost cloudless (a "blue day"); on a strong
day some of the thermals overdevelop: tall towers, a spreading top (more on this level is in
the "dangerous weather" section of the atmosphere module, including thunderstorm cells and anvils).

For details on the thermal itself, its strength, the shape of the flow, the updraft speed and how the
airflow beneath the cloud is born and dies, see the page [Thermals](/mechanics/thermals/); only the
above-ground, visible part is described here.

## Cloud shadows

A cloud **blocks only the direct sunlight**; the diffuse light of the sky beneath it remains, so the shadow does not
turn into a black blot. The shadow is drawn in a separate pass (`CloudShadowMap`): a small map around the
camera is recomputed several times a second, and for each of its points the transmission of direct light is computed
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

This is not only a picture: the thermal model knows about the same mature clouds that are drawn in the sky, and a **new
thermal born in the shade of such a cloud is weaker** than in the sun (an attenuation coefficient in the
source model). The shadow for this calculation is the same cloud disk, shifted away from the sun in its direction, as
the visible shadow on the ground: a pilot reading the shadows below sees exactly the same division of the ground into
"heating" and "not heating" that the model uses.

## Model limits

- **The shadow is not a global map** but a window of fixed size around the camera: clouds beyond it
  cast no shadow on the visible scene (nor is that needed, as they cannot be seen anyway).
- **The cloud density is approximate**: a raymarch over several geometrically growing steps toward the sun, not
  a true multiple-scattering simulation. This is enough for the base to be darker than the edges and
  darker over a live thermal, but there will be no exact photometry.
- **Different render paths differ in cost and slightly in picture**: the main path (Forward+/Mobile) is
  one shared raymarch pass per frame with upscaling, the path for integrated graphics (Compatibility) is a box per
  cloud. In Compatibility there is a known visual problem: some clouds are split by a
  vertical boundary into two halves of different brightness with a "stepped" edge. It is deliberately not
  fixed; the project's target renderer is Forward+.
- **The shadow does not account for interreflection** from neighboring clouds or terrain, only direct shading by the
  cloud thickness above the point.
- The thermal model and its cloud are **not recomputed at every physics step**: the cloud and its shadow
  are recomputed noticeably less often than the frame, so with a sharp change of lighting (for example, after a quick
  turn) the shadow can lag the actual cloud shape for a fraction of a second.

## What was considered and why this way

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
  dangerous weather (thunderstorms, wave, cirrus veil, dust devils).
- Cloud and shadow code: [scripts/atmosphere/cloud_layer.gd](/scripts/atmosphere/cloud_layer.gd),
  [scripts/atmosphere/cloud_shadow_map.gd](/scripts/atmosphere/cloud_shadow_map.gd),
  [scripts/atmosphere/cloud_common.gdshaderinc](/scripts/atmosphere/cloud_common.gdshaderinc),
  [scripts/terrain/cloud_shadow.gdshaderinc](/scripts/terrain/cloud_shadow.gdshaderinc).
- Cloud noise generator: [tools/atmosphere/gen_cloud_noise.py](/tools/atmosphere/gen_cloud_noise.py).

![Cloud shadows over the valley, before the shadow shape rework](/releases/0.7.0/screenshots/113_тени_облаков_долина_до.jpg "Cloud shadows over the valley, before")

![Cloud shadows over the valley, after: the shadow repeats the cloud's shape](/releases/0.7.0/screenshots/114_тени_облаков_долина_после.jpg "Cloud shadows over the valley, after")

![Cloud shadows from the air, from above](/releases/0.7.0/screenshots/116_тени_облаков_сверху_после.jpg "Cloud shadows from above")

![Water ripples and cloud shadows in cloudy weather](/releases/0.7.1/screenshots/134_рябь_тени_облачно_до_после.jpg "Water ripples and cloud shadows")
