---
title: "Thermals"
weight: 30
description: "Thermals, turbulence, dust devils and thunderstorms: how air rises from sun-heated ground and what physics is behind it."
---

# Thermals, turbulence, dust devils, thunderstorms

A thermal is a column of warm air rising from ground heated by the sun. A hang glider pilot circles
inside it to gain altitude; around the thermal the air, on the contrary, sinks weakly. Below is how this works
in the game, where the formulas come from and what the model cannot do.

## How it works

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

**Wind and turbulence**. The wind profile is a power law with exponent 0.14; in the mixing layer itself it is
almost constant. Mechanical turbulence is modeled as Taylor's "frozen turbulence": the fluctuation field
is carried by the wind as a whole rather than recomputed anew; the eddy scale of 30–80 m is comparable to the
wing span, so the wing halves get different lift and the wing is shaken in roll. The standard deviation of the fluctuations
is composed of a mechanical component, a convective one (by the Lenschow profile), turbulence at the thermal edge
and the rotor behind the ridge, as independent random variables:

$$ \sigma_w^2 / w_*^2 = 1.8 \cdot (z/z_i)^{2/3} \cdot (1 - 0.8\,z/z_i)^2, \qquad \sigma_{w,max} \approx 0.6\,w_* \text{ at } z \approx 0.3\,z_i $$

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
- **Thermals are generated on a regular grid of cells**, unlike in the real boundary layer, where the number
  and positions of thermals are a random but statistically structured process; here it is a deterministic
  generator by cell, cycle and seed.
- **The upper fall-off of lift at the top** is made adjustable (`top_taper_m`), rather than strictly 10 % of the layer
  height, as follows from Allen's formula — otherwise under a growing cloud the lift would die out unrealistically early.
- **No direct computation of the heat flux from soil physics** for the thermal strength in the static mode: the strength and
  the share of sources are taken from the table of anchors by cloud base height (see the page ["Weather"](/mechanics/weather/)),
  rather than from a measured flux anew each time.
- **The same turbulence profile** (Lenschow) is used both for convective turbulence and as the
  amplitude normalization — a simplification of the general picture of wind shear in the real boundary layer.
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

## Further

The thermal sources, their strength and ceiling are now taken not from the table of anchors by cloud base height, but from the common
air field: the maxima of lift and of flow convergence near the ground for that hour, and the Deardorff scale from the
simulated heat flux and mixing layer height at the specific point. The shape of the bubble itself
(Gedeon/Allen) and its life stayed the same; more on the page of the [air model](/mechanics/air-model/)
and in [docs/guide/air-model.md](/docs/guide/air-model.md) → "Scale 2: thermals from the field". The table of anchors described above
works as a fallback if the field is unavailable.

## Details

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
