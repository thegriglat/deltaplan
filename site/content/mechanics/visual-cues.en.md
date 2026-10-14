---
title: "Grass, Water and Landmarks"
weight: 60
description: "Visual cues of wind and air for the pilot: grass bending with the wind, ripples on water, campfire smoke, windsocks, the telltale — what the picture shows and where the model is silent."
---

# Grass, Water and Landmarks

The game has no HUD and no hints — the pilot learns about wind and air only from the picture around, as in a real
flight. Every cue below is tied to the real atmosphere model: the grass sways from the actual wind at
that point, the smoke is carried by the actual local flow, the ripples on water come from the same wind the wing feels.
Nothing is drawn "for beauty" separately from the model — otherwise the picture would teach the wrong thing.

## Grass sways with the wind

The grass blades around the camera (`GrassField`) react to the mean wind near the ground and to gustiness: gust
patches run across the grass and the grain fields (the grass turns lighter — the undersides of the leaves show) and ripples run along the wind direction. Over
a thermal near the ground there is a broken, swirled wave converging to the flow axis, and stronger swaying: the grass
seems to "inhale" into the thermal. The offset of the gust pattern is accumulated on the CPU frame by frame, and is not derived
from the overall game time — so when the wind direction changes sharply the pattern does not jerk backwards.
Trees sway too (the amplitude of the treetop grows with the wind). Individual blades are in rings around the camera:
a near layer to 14 m, a middle one to 36 m, a far one to 115 m (sparser, wider tufts); the gust waves in the ground colour
and normals reach farther and fade out at 3 km (`wind_fade_m`, `configs/world.json`).

The grass is trampled at the pilot's feet at the launch and at the landing, and at the official landing fields the grass
is mown in a rectangle along their real axis. Details of placement, thinning at a distance and trampling are
in [docs/guide/vegetation.md](/docs/guide/vegetation.md).

## Ripples on water

Water reacts to the same wind as the grass:
- **calm** — a mirror-smooth surface;
- **toward full wind speed** — matte ripples: roughness and normal direction go across the wind;
- **in gust patches** — the ripples are darker ("cat's paws" — less reflected sky), and
  sparkle against the sun;
- **at the windward shore** — a smooth strip: the land on the windward side dampens the wind, and the water there
  stays calm (computed from several samples of the shore mask against the wind direction).

Along every shore, regardless of wind, there is a thin strip of wet ground. All of this is part of the common model of
terrain and water described on the page [Terrain and places](/mechanics/terrain/).

## Campfire smoke

At the launch camp there is a campfire (a ring of stones, logs, flame particles, flickering light). The smoke is 26 puffs
(puff life 10 s) in world coordinates, their velocity relaxes toward the sum "wind + buoyancy"; the wind is taken from the atmosphere model
at the campfire itself at two heights (a puff uses the one closer to its own height), including the vertical
flow of the slope or thermal. The buoyancy decays with time (by a factor e in 5 s) and is divided by (1 + 0.1·wind, m/s): in calm the smoke goes
as a thin stream almost vertically, at 3 m/s it is noticeably tilted, at 7 m/s it is pressed to the ground and trails along the
wind. It is updated several times a second — gusts sway the whole plume at once, not only the last
puff.

## Windsocks and ribbons

At every launch there is a cone on a mast and marker poles with red-and-white tape at the edges of the launch run; at the landings, a
cone on a taller mast. The air for them is taken right at the swivel/the fabric (with all gusts,
rotor and thermals), so in a rotor neighboring cones at the same launch may show different
directions, and in a thermal the cone is slightly lifted upward. The cone's fill and the sag of the tape grow with the
wind speed by formulas checked against photographs of real cones; the flapping of the tail is amplified by
gustiness. The design of this instrument, its formulas and tuning — on the page
[Instruments](/mechanics/instruments/).

## The telltale on the control frame cable

A separate small detail in the cockpit — two ribbons ("strings") on the front cables of the control frame: at
launch they show the direction and strength of the wind, in flight — the airflow right at the wing. In the
"Weight shift" control mode the model has no sideslip, and in a steady turn the string points straight back; it
shows sideslip in the "Pendulum" mode (details and limits — on the Instruments page). It is visible at the periphery of vision, as with real pilots, without any hints from above.
More about its attachment point and parameters — on the page [Instruments](/mechanics/instruments/) and in
[docs/guide/telltale.md](/docs/guide/telltale.md).

## Haze and visibility

The visibility range and the color of distant ridges are also a cue to the state of the air: under a clear sky distant
ridges turn blue with distance (the blue haze of clean air), under the mixing layer visibility is limited
and improves sharply above its upper boundary. In detail about haze, the inversion and its link to cloud height
— on the page [Terrain and places](/mechanics/terrain/) (the section on world and sky) and in
[docs/guide/atmosphere.md](/docs/guide/atmosphere.md).

## What is done

The full list of visual cues of the air for the pilot with their importance is collected in the research
[docs/research/visual_cues.md](/docs/research/visual_cues.md) (the list VR-1…VR-30, "VR" = visual requirement).
From it the game has:
- cumulus clouds with life stages and cloud streets, cloud shadows by shape, haze and inversion, ground colour = map
  of thermal sources, sun and shadows of terrain, trees and wing, detailed grass and objects near the ground,
  windsocks and strings, navigation over real terrain and OSM, power lines with collision, wing and control frame
  in the cockpit view, a landing field with a windsock;
- ripples and a smooth strip on water from the wind, swaying of grass and trees by waves of gusts, campfire smoke
  carried by the wind, windsocks that honestly show the rotor (different wind at neighbouring cones), a volumetric
  forest with its edge as an obstacle, dust devils by strong young thermals over dry ground (`dust_devils.gd`);
- birds in strong mature thermals (up to 3 flocks of 2–5 birds, within 2.5 km, circling with bank
  `tg φ = v²/(g·r)`; `bird_flock.gd`); swallows and fluff over a young thermal near its source
  (`thermal_signs.gd`: a flock of 3–6 birds at 20–150 m, a column of fluff that fades at 140 m) — visible no
  farther than the eye can tell them apart;
- dangerous and special weather: thunderstorm cells with an anvil and rain (`storm_field.gd`), wave lenticular
  clouds and rotor fragments (`wave_field.gd`), an upper-level cirrus veil that suppresses thermals
  (`cirrus_layer.gd`).

## Model limits

- **The cues read the model, they do not approximate it**: if there is no thermal or wind at that point,
  neither grass, nor water, nor smoke will show false motion — but conversely, weak effects (for example,
  a very weak thermal below the cloud visibility threshold) get no visual cue at all —
  a "blue day" without a thermal and a "blue day" with a weak unusable thermal are indistinguishable by the picture.
- **The range of the cues is limited by a budget**: individual grass blades up to 115 m, ground swaying up to 3 km, farther
  the cues fade not because the phenomenon has stopped but by the rendering rules (`wind_fade_m` and
  the grass layer radii).
- **Not in the game**: a haze dome over dry thermals on a cloudless day; machinery in the fields (a tractor with dust) as a
  trigger for a thermal to break off; different vegetation on the landing field itself — landing fields are mown the same everywhere.
- **Not all cues from the research are equally accurate**: for example, smoke is particles with a wind averaged
  over two height probes, not an honest smoke simulation; the ripples on water are a procedural shader driven by
  wind speed and direction, not a wave computation.

## What was considered and why it is this way

- **Only cues tied to physics.** The research `visual_cues.md` originally collected dozens of
  ideas from the literature for pilots (Pagen, the FAA Glider Flying Handbook, SkyNomad articles and other sources
  on meteorology for glider pilots) and deliberately divides them into "required", "desirable" and "later" —
  the implementation went in that order (most of it is now done), not by the beauty of the effect.
  The general rule (VR-0) — draw nothing decorative that would contradict the model: a decorative
  cue without physics would be worse than its absence, because it would teach the pilot wrongly.
  The sources were selected and checked separately; some sources (Bradbury, Martens, Pagen "Performance Flying") are marked in the research as needing
  verification against the printed books — an open question, not a fact.
- **The priority is what you cannot fly honestly without a HUD**: windsocks, grass and objects near the ground
  for judging height, the wing's shadow at landing — were done first, because without them the judgment of height
  and speed in the flare turns into a lottery.

## More

- [docs/research/visual_cues.md](/docs/research/visual_cues.md) — the full list of cues, their importance,
  sources on meteorology for pilots.
- [docs/guide/vegetation.md](/docs/guide/vegetation.md) — grass and trees around the camera.
- [docs/guide/world-objects.md](/docs/guide/world-objects.md) — windsocks, campfire, camp.
- [docs/guide/telltale.md](/docs/guide/telltale.md) — the telltale on the control frame cable.
- [docs/guide/atmosphere.md](/docs/guide/atmosphere.md) — the model of wind, thermals, haze and dangerous weather that
  these cues show.
- Code: [scripts/terrain/grass_field.gd](/scripts/terrain/grass_field.gd),
  [scripts/terrain/terrain_wind.gd](/scripts/terrain/terrain_wind.gd),
  [scripts/world_objects/campfire.gd](/scripts/world_objects/campfire.gd),
  [scripts/world_objects/wind_indicator.gd](/scripts/world_objects/wind_indicator.gd).

![Wind over water: calm and gusts](/releases/0.7.0/screenshots/99_вода_ветер_0_3_6.jpg "Wind over water: calm, 3 and 6 m/s")

![Campfire smoke at wind 0, 3 and 7 m/s — carried by the model's real wind](/releases/0.7.0/screenshots/102_костёр_дым_ветер_0_3_7.jpg "Campfire smoke at different wind")

![Ripples on water and cloud shadows together](/releases/0.7.1/screenshots/133_рябь_тени_до_после.jpg "Ripples on water and cloud shadows")
