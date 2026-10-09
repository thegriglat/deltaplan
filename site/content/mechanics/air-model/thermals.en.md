---
title: "Thermals"
weight: 30
description: "Level 2 of the air model — thermals: where sources, strength, ceiling and drift come from (the wind field), how a bubble is built, plus dust devils and thunderstorms."
---

# Thermals, dust devils, thunderstorms

A thermal is a column of warm air rising from ground heated by the sun. A hang glider pilot circles
inside it to gain altitude; around the thermal the air, on the contrary, sinks weakly. Below is how this works
in the game, where the formulas come from and what the model cannot do. This is level 2 of the [air model](/mechanics/air-model/): the place, strength, ceiling and drift of a thermal come from the [level 1 wind field](/mechanics/air-model/wind-phases/), and the shape and life of the bubble from the formulas below; turbulence is [level 3](/mechanics/air-model/turbulence/).

## What is computed at level 2

Every field hour the game builds a **list of thermal sources**. The data for it come from the level 1 wind field — computed for the whole place, the same for all players in a network game:

- **Where.** A source appears where there is more heat flux at the ground and the air converges near the ground: over heated slopes dense, over weakly heated ones sparse, in shade, where there is no heat flux, none at all. This ties sources to the sunny side of a slope rather than to grid nodes.
- **Strength.** The Deardorff scale w<sub>\*</sub> from the heat flux at the point and the mixing-layer height; the core gains a fraction of w<sub>\*</sub>. In the morning the layer is thin — cores are small and frequent, weaker; toward noon wider and stronger.
- **Ceiling.** By the inversion, not by the cloud base: a parcel rises until it equals the temperature of the air above.
- **Drift.** The axis is tilted by the wind from the same field: the cloud ends up kilometers downwind of the source.
- **How many.** The number, radius and strength of cores follow Allen's updraft model from layer thickness and w<sub>\*</sub>; the field only decides **where** there are more. The field's updraft beyond what the cores carry is a broad weak lift "in between".

In the "Heuristic" mode the thermal parameters come from simplified formulas instead of the field — see [Heuristic mode](/mechanics/air-model/heuristic/).

**Multiplayer.** The host chooses the sources and sends them to the others; each computes strength, ceiling and drift from its own field, and the differences are vanishingly small (hundredths of a meter per second, tens of centimeters in the axis).

The strength, ceiling and drift of a thermal are not made up separately but agree with levels 1 and 3: the w<sub>\*</sub> of turbulence at a source point equals the w<sub>\*</sub> of the source itself (ratio 1.001 ± 0.038 at Kayancha, 12:00).

An example result — Ongudai, 12:00 (wind 3 m/s, clear, a typical July): on heated slopes 4.9 sources per km², on weakly heated ones 0.7, in shade 0. On real terrain the thermal column is 575 m in the morning, 1440 m at 12:00, 1640 m at 15:00.

![Where thermals are born: heat flux, air convergence and sources over Kayancha, 12:00](/tools/research/air_thermals/out/fig_sources_kayancha_w100_h12.png "Kayancha, 12:00: heat flux, mean convergence of air in the layer and 109 thermal sources (a dot is proportional to strength)")

**What it cannot do.** The core strength is a single fraction of w<sub>\*</sub> without spread between neighbors; in life the spread is wider. "Strong thermals every 1–1.5 layer thicknesses" the model does not reproduce: the density of all cores matches the literature, the spacing of strong ones does not. There are no "streets" along the wind. The source list is updated once per field hour. Small morning thermals with a column shorter than 300 m are not born. The position of particular thermals is statistics, not a computation.

## Where the heating comes from: cover, moisture, water

The source strength and the solver input are computed from one heat flux H (W/m²), and it depends on what lies on the ground: forest, meadow, cropland, shrub, rock, built-up area, water, snow.

- **Albedo.** Light surfaces reflect more sun (meadow 0.20, rock 0.25, snow 0.55), dark ones less (forest 0.12, water 0.07). The rest heats the ground.
- **Part of the heat goes into the ground.** 4 % for forest, 15 % for meadow, 25 % for rock and built-up areas. What is left is split between heating the air and evaporation.
- **Wet heats less.** The wetter the soil, the more energy goes into evaporation and the less is left for the air. Wetness comes from the terrain: damp hollows heat the air less, dry ridges and rock more. There is no rain or irrigation in the game, so this is drainage geometry, not weather.
- **Lag.** The sun for a class is taken with a delay: meadow and field 0.3 h, forest 0.6 h, rock 0.9 h, built-up 1.2 h. Rock and villages start heating later and keep giving heat longer than open fields.

At noon on level ground, clear sky, midsummer (50° N): meadow ≈ 210 W/m², forest ≈ 290, rock ≈ 300, built-up ≈ 320, snow ≈ 20. The previous heating was the same everywhere — 275 for meadow. Averaged over the areas, noon heating is 10–16 % lower, but the spread is wider: southern rocky slopes are stronger, northern slopes and damp hollows weaker. The number of thermal sources stays about the same (within ±8 %); the ceiling is 1–10 % lower.

**Forest heats the air no less than meadow.** By the literature values forest is dark and hides almost no heat in the ground, so the air over it warms more than over meadow. The game used to make forest weaker; now thermal sources can also form over forest. The field–forest boundary is still a place where thermals break off: at a class boundary the source strength gets an extra boost (up to +30 % in a 50–150 m band).

**Water.** On a summer day water is colder than the air, and the air above it is cooled — "the lake sinks you": at Lake Aushkul over open water the flux is about −30 W/m² (3 m/s wind, water 6 K colder than air), and there are no thermals. In the evening warm water heats the air. Water temperature follows the climate a month earlier: the daily mean air temperature 30 days before the date (at the site's altitude). Below zero the water is ice and behaves like snow.

**Roughness.** The wind near the ground accounts for the cover: over forest and a village it is weaker, over meadow and water stronger. At launches this is a few percent: at 30 m over forest about −5 % from before, over meadow about +3…5 %.

**What the model cannot do.** Soil moisture comes from terrain only (no rain, irrigation or moisture forecast). Cold mountain rivers (snowmelt) are treated as warm as lakes. There is no daily cycle of water temperature (0.5–2 K for small lakes), and ice has no thickness or melting. There is no terrain shadowing in the heating.

## Shape and life of the bubble

Every thermal in the game is a bubble (`AtmoThermal`) with a source on the ground, a life cycle of growth → maturity →
decay and a lift profile over the radius. The world is divided into cells (`thermal_spacing_m`), and each cell has
its own cycle with a deterministic phase, strength and source point (chosen by the solar illumination
of the slope); the same day is fully reproducible regardless of where the pilot flew.

**Profile over the radius** is Gedeon's "Mexican hat": a core with lift in the center, around it a ring of weak
sink, then zero. The mass flux through a horizontal section is exactly zero: as much air as rose,
the same amount sank next to it:

$$ w(r) = w_c \cdot e^{-(r/R)^2} \cdot \left(1 - (r/R)^2\right) $$

**The radius grows with height** according to Allen's model (NASA, autonomous soaring gliders): the thermal widens from the
ground to the cloud base, the lift grows from the ground as `z^(1/3)` and dies out near the top:

$$ R(\xi) \propto \xi^{1/3}(1 - 0.25\,\xi), \qquad \xi = \frac{y - h_s}{z_{top} - h_s} $$

**The thermal axis is tilted by the wind**: the air rises at the core speed and is drifted at the same time:
`Δx(z) ≈ z · U(z_mid) / w_c`. With wind of 5 m/s, a core of 3 m/s and a layer of 1500 m the cloud ends up ~2.5 km
downwind of the source; the tilt angle is capped from above, otherwise the thermal would simply have to be torn apart
by the wind, as it happens in real life.

**Life cycle**: a cumulus cloud lives 15–30 min, a "good" thermal 10–20 min. In the decay stage
the bottom of the column detaches from the source earlier than the top: a pilot low under a decaying cloud no longer finds
lift, a familiar situation.

**Cloud suction.** Under a large growing cloud, in the last hundreds of meters below the base the climb noticeably
speeds up (inside the cloud condensation adds buoyancy: the air there cools more slowly than the dry
adiabat), and for a Cb up to a dangerous "pull-in". Under small, young and decaying clouds there is no suction:
the thermal weakens toward the top, as without a cloud.

**Wind and turbulence.** The wind profile in the mixing layer is almost constant; fluctuations (gusts, jolts, rotor) are computed by [level 3](/mechanics/air-model/turbulence/) — at the thermal edge turbulence is added as an independent component.

**Background sink** between thermals is −0.3…−1 m/s (−0.5 by default), from mass conservation: what
rose in the thermals must sink somewhere.

![Flow and temperature difference over a single sun-heated slope — a prototype of the air model](/tools/research/heat_ca/out/s1_sun_one_slope/flow.png "s1_sun_one_slope/flow.png")

## Physics: laws and approximations

The scale of the lift is the Deardorff convective velocity: the stronger the ground heating and the higher the mixing layer,
the stronger the thermals.

$$ w_* = \left(\frac{g}{T} \cdot H_0 \cdot z_i\right)^{1/3} $$

For a good summer day `w*` ≈ 1.5–3 m/s, on a weak day ≈ 1 m/s; the thermal core climbs ≈ 1…1.5·`w*`,
that is 0.5–5 m/s, consistent with hang glider pilots' logs ("a good thermal is 1–2 m/s cruise
climb, 2–3.5 on a strong day", [docs/research/xc_reference.md](/docs/research/xc_reference.md)). By
the annual statistics of the Desert Rock station (Allen 2006) the median `w*` over the year is 2.56 m/s at `z_i` ≈ 1400 m,
in July on average 2.69 m/s (`z_i` ≈ 1975 m), the maximum over the year is 6.3 m/s.

The thermal profile over height (Lenschow and Stevens 1980, from aircraft measurements over the sea; Allen 2006 —
the same formula, fitted to autonomous vehicles):

$$ \hat w / w_* = (z/z_i)^{1/3} (1 - 1.1\, z/z_i) $$

— the maximum is ≈ 0.45·`w*` at `z` ≈ 0.25·`z_i`, and it goes to zero at 0.91·`z_i`. By paraglider logs in France
(2017–2024, 1.47 million climbs) over mountains the climb is 30–40 % stronger than over flat terrain: at summer noon
over flat terrain ≈ 1.03 m/s, in high mountains ≈ 1.41 m/s, which is accounted for indirectly through the source strength
tied to terrain classes.

**Dust devils** are born at the base of a young strong thermal over a dry surface, live
10–60 s, are 20–200 m high depending on the thermal strength, and drift with the surface wind.

## Model limits

- **Not CFD.** A thermal is an analytical formula (Gedeon + Allen), not a flow computation: the shape of the core and
  the sink ring is fitted to the feel of an experienced pilot rather than derived from the equations from scratch.
- **In the "Heuristic" mode thermals are generated on a regular grid of cells**, unlike in the real boundary layer, where the number
  and positions of thermals are a random but statistically structured process; here it is a deterministic
  generator by cell, cycle and seed.
- **The upper fall-off of lift at the top** is made adjustable (`top_taper_m`), rather than strictly 10 % of the layer
  height, as follows from Allen's formula — otherwise under a growing cloud the lift would die out unrealistically early.
- **The heat flux is a model, not a measurement**: it is computed from the sun, slope, weather and land-cover class (see above), but without soil physics, groundwater depth and terrain shadows.
- Clouds in detail (shape, shadows, stages) are a separate mechanic: [/mechanics/clouds/](/mechanics/clouds/).

## What was considered and why this way

- **A bubble (column) model instead of a rising ring (Scorer).** In real life both regimes occur: a long-
  working "column" over a sunny slope and a short-lived "bubble" that detaches and rises.
  A column with a life cycle was chosen, whose bottom detaches in the decay stage; this gives the same
  feeling of a "bubble that went up" without computing a separate vortex ring.
- **Gedeon's profile was chosen for its smoothness**: the difference in lift between the wing halves (≈10 m) grows smoothly
  toward the edge of the core, so the wing banks "out of the thermal", as in real life, rather than abruptly at a sharp boundary.
- **Extreme thermals (7–9 m/s) are made rare and only on a strong day**: in a pilot's words
  "+8 — time to get out of here": a test verified that on a weak and a medium day such thermals do not occur at all,
  and on a strong day they are rare and always under a large cloud.
- **Dry thermals without a cloud** are kept as a separate share (on a weak day at least 40 %): the pilot
  looks for them "by the variometer", without the visual cue of a cumulus cloud.

**Thunderstorms are a rare phenomenon**, not a typical element of weather. The share of strong thermals that actually
become cumulonimbus (Cb) is separated from the overall "thunderstorminess of the day" (commit {{< commit 105bf45 >}}):
previously, with a daytime maximum of +26 °C, a thunderstorm near the start occurred in almost every flight, which does not match
real life. Measured over 100 random days at Ongudai (`tools/weather/storm_rarity.tscn`):

| Daytime temperature | Cb within 15 km in the first hour | Thunderstorm at the start at the beginning of the flight |
|---|---|---|
| +26 °C | 0–1 % of flights | 0 % |
| +30 °C | 20–40 % | 0–4 % |
| +34 °C | 50–70 % | 3–6 % |

Inside a storm cell (`storm_field.gd`) there are a downdraft under the downpour, spreading near the ground and a gust
front; the outflows of neighboring cells **are not added up**: previously, without this limit, the outflow speeds of several
cells summed to 30–60 m/s, which is physically wrong (a real squall of such
strength is a rare natural disaster, not an ordinary thunderstorm).

## Details

- [Wind field: phases and Picard](/mechanics/air-model/wind-phases/), [turbulence and rotor](/mechanics/air-model/turbulence/), [air model](/mechanics/air-model/); [docs/guide/air-model.md](/docs/guide/air-model.md) → "Scale 2: thermals from the field".
- [docs/research/thermals.md](/docs/research/thermals.md): formulas and sources: Gedeon, Allen,
  Lenschow and Stevens, Deardorff.
- [docs/research/calibration_data.md](/docs/research/calibration_data.md): the table of observables with
  uncertainties (§1 "Thermals").
- [docs/research/xc_reference.md](/docs/research/xc_reference.md): references for cross-country flights
  (climb, share of time spent circling, number of thermals per 10 km).
- [docs/guide/atmosphere.md](/docs/guide/atmosphere.md): the structure of the atmosphere module, the table "pilot's words
  in numbers".
- [scripts/atmosphere/thermal_field.gd](/scripts/atmosphere/thermal_field.gd),
  [scripts/atmosphere/atmo_thermal.gd](/scripts/atmosphere/atmo_thermal.gd),
  [scripts/atmosphere/storm_field.gd](/scripts/atmosphere/storm_field.gd),
  [scripts/atmosphere/dust_devils.gd](/scripts/atmosphere/dust_devils.gd): code.
- [configs/atmosphere.json](/configs/atmosphere.json), [configs/weather_model.json](/configs/weather_model.json): parameters.
