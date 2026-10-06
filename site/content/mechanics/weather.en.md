---
title: "Weather"
weight: 40
description: "Weather from temperature and the daily cycle: how a whole day is derived from the daytime maximum and the wind."
---

# Weather from temperature and the daily cycle

The pilot in the game does not pick a "weak / medium / strong day" from a list. They set what they see in
the forecast: the daytime maximum temperature, wind strength and direction, and cloud cover. Everything
else (thermal height, cloud base, strength and frequency of the lift, thunderstorm probability, the daily
cycle) is derived from these numbers by the model, physically.

## How it works

The "Flight setup…" screen sets three things: the **daytime temperature** (0…+40 °C, a slider with the hint
"usually this month: …"), the **wind** (0…12 m/s at the launch plus a direction, "headwind" or one of 8
compass points) and the **cloud cover** ("Clear / Partly cloudy / Overcast"). `WeatherModel.derive` (pure
functions, `scripts/atmosphere/weather_model.gd`, parameters in `configs/weather_model.json`) turns these
three numbers into the same parameter dictionary that used to be hard-coded in the `weak/medium/strong`
presets. Humidity is not asked for separately: the pilot found it unnecessary, so the dew point is taken as
typical for the month and place.

**Thermal height and cloud base.** In the mixed layer a rising bubble cools along the dry adiabat, while
the surrounding air above cools at the climatological lapse rate of the month:

$$ z_{dry} = h_v + \frac{(T + \delta) - T_u - \Gamma_{env}(z_u - h_v)}{9.8 - \Gamma_{env}} $$

$$ z_{lcl} = h_v + 0.122 \cdot (T - T_d) $$

where `h_v` is the valley height (the lowest 10 % of the terrain within a 10 km radius), `δ` = 1 K is the
bubble's superheat, `Γ_env` = 4 K/km is the climatological lapse rate above the layer, and `T_u` and `T_d`
are the tabulated temperature at 3000 m and the dew point for the month. The top of the lift is the smaller
of the two: `z_top = min(z_dry, z_lcl)`. The margin `m = z_dry − z_lcl` determines whether the day will be
cumulus or "blue" (no clouds if `m < −100 m`).

For the reference place (Altai, July: `h_v` ≈ 400 m, `T_u` = +2 °C, `T_d` = +8 °C):

| Daytime temperature | z_dry | z_lcl | margin m | cloud base above mean ground | day |
|---|---|---|---|---|---|
| +12 °C | 500 m | 900 m | −400 m | 300 m (minimum) | almost dead, blue |
| +16 °C | 1200 m | 1400 m | −200 m | ~300–500 m | weak dry thermals |
| +20 °C | 1870 m | 1860 m | ≈ 0 | ~960 m | ≈ weak (a few small clouds) |
| +26 °C | 2900 m | 2600 m | 300 m | ~1700 m | ≈ good day |
| +31 °C | 3760 m | 3210 m | 550 m | ~2300 m | ≈ strong, overdevelopment |
| +34 °C | 4300 m | 3570 m | 700 m | ~2650 m | thunderstorm: Cb noticeably more frequent |

The cloud base rises by roughly 120–140 m per degree of temperature–dew point spread, as pilots know from
the rule "+1 °C is another 120 m".

**Thermal strength, size and frequency** come from a piecewise-linear table of anchor points by the height
of the top of the lift (`top_agl`). Its rows exactly match the values of the former presets (the
calibration is preserved), with corrections for the season (solar elevation at noon) and for the wind
(strong wind tears thermals apart: the strength multiplier falls from 1.0 in weak wind to 0.5 at 45 km/h).

**Cloudiness from the margin `m`**: the share of dry (cloudless) thermals, the cloud thickness, the
probability of overdevelopment and the share of thermals that grow into a thunderstorm cell (Cb) all depend
on the single number `m`. More about thunderstorms is on the page [“Thermals”](/mechanics/air-model/thermals/).

## The daily cycle

The pilot enters the daytime maximum rather than the temperature at the moment of launch: the forecast
prints the maximum in large type, and when game time is sped up (×10, ×60) the number must not "drift". The
temperature at time `t` is computed by the Parton–Logan formula: a sinusoid from sunrise to the maximum
(noon + 2.5 h), then a decline toward sunset:

$$ T(t) = T_{max} - A \cdot (1 - f(t)) $$

where `A` is the daily amplitude for the month (July ≈ 11 K, April ≈ 12 K, January ≈ 6 K), and `f(t)` is a
sine from sunrise (0) to the peak (1), after which it declines toward sunset to `f ≈ 0.65`.

**Ground heating inertia** works over 9 surface classes (field, rock, forest, built-up area, water, snow…),
each with its own time constant: `dS/dt = (a·I(t) − S) / τ`. Meadow warms up in ≈ 0.5 h, rocks and scree in
1.5 h, water in 10 h (it barely changes over a day), and forest gives up heat with a lag of ≈ 0.6·τ. That
is why "evening thermals from rocks" and warm walls appear later than over open fields.

**The morning surface inversion** keeps thermals low until heating breaks through it: the cloud base rises
all morning rather than standing at the maximum value right away. Thermal strength grows with the heat flux
as `(flux/peak)^(1/3)` (Deardorff scaling), and the share of births as `(flux/peak)^1`, so in the evening
there are noticeably fewer thermals, and they are wider and softer (the softness is set by the same
flux-to-peak ratio: an enlarged radius, a weakened core, weaker turbulence at the edge). Toward sunset
mechanical turbulence decreases (the air near the ground calms down), while the slope itself works as it
does by day: "warm, very good soft air, good dynamics at the slope, few thermals" (a pilot's words, which
became the basis of this part of the model).

The weather in the game is recomputed every 60 game seconds and is "led" smoothly (over ~5 minutes)
without recreating the field: live thermals live out their life with the old parameters, while newly
born ones already get the new ones.

![Flow over terrain with a stable layer (inversion): a prototype of the air model](/tools/research/heat_ca/out/s4_inversion/flow.png "s4_inversion/flow.png")

## Physics: laws and approximations

The model rests on standard approximations of aviation meteorology: the dry adiabat of 9.8 K/km and the LCL
rule (condensation level) ≈ 122–125 m per degree of temperature–dew point spread. The theoretical value is
confirmed by measurements from paraglider tracks (France, 2017–2024): the "ceiling/spread" slope is
101–133 m/°C depending on the terrain, and theory gives 125 m/°C. The climatological profile above the
mixed layer and the Parton–Logan daily cycle are generally accepted simplifications: the real atmosphere
is, of course, neither perfectly mixed nor perfectly sinusoidal in time, but for a game this is enough for
"hotter near the ground with the same air aloft" to physically mean "thermals higher and angrier", that is,
spring +15 °C with cold air aloft gives as good a day as July +26 °C.

## Model limits

- **The dew point is constant through the day** (taken from the table for the month). In real life it also
  drifts, though much more slowly than temperature; humidity as a separate parameter is not set by the
  pilot.
- **Thermal sources do not shift in time other than through strength and share.** The cell positions
  (`thermal_spacing_m`) are fixed for the whole day by the peak flux, otherwise thermals would "jump" at
  every recomputation; this is a deliberate simplification for the sake of a stable picture of the sky.
- **The solar elevation used to choose thermal sources is taken instantaneously** from the current
  direction to the sun, while the heat flux into the ground itself (and hence the strength) has inertia by
  surface class; that is, "where the thermal will be" reacts to the sun faster than "how strong it will
  be".
- **The anchor table by `top_agl` is piecewise linear** and not rederived from the heat flux at each
  point: the table rows are calibrated values of the former presets, not a direct calculation from the
  heating of a specific piece of slope.
- **Snow on the terrain is not drawn.** Winter cold air with thermals from a heated forest against a snow
  field is mentioned as an idea for the future, but is not yet implemented in the model.
- **The wave is hidden and off by default** (`wave.enabled = false`): the physics of the lee wave (strong
  wind across the ridge plus stable air) exists in the code, but the pilot does not know the word "wave",
  and by default it is not switched on. More on the page [“Slope wind”](/mechanics/air-model/slope-wind/).

## What was considered and why this way

Previously the pilot chose from five ready-made weather presets ("Weak / Medium / Strong day / Thunderstorm
/ Wave"). According to the feedback this looked strange: a real forecast has no such categories, it has
temperature and wind. The presets were removed from the interface completely (without keeping compatibility
with old settings, since the game has no users yet who would need migrating), but the `weak/medium/strong`
values themselves remained in the internal references and tests as calibration points, to make sure that
+20/+26/+31 °C give roughly the same days that the old presets used to give.

Separately, the option of a "mass-consistent wind field on a grid"
([docs/archive/plan/wind-field.md](/docs/archive/plan/wind-field.md)) was considered and rejected in favor of
a broader plan: solve the continuity equation over the terrain and obtain a physically consistent wind
without hand-written formulas for the slope. That plan had no heat (so no thermals, no difference between a
heated and a cold slope, no inversion) and no inertia (recomputation on a weather change would have been
instantaneous, with no smooth daily cycle). The plan was replaced by a more general one,
[docs/plan/air_model.md](/docs/plan/air_model.md), "The air model at three scales", where heat and inertia
are built in from the start.

## What's next

The game has a single physical air field for three scales: the **mean field** (where it blows, where the
slope holds the glider up, the thermal ceiling: a steady solution of the Boussinesq equations, recomputed
every 15 game minutes and on a change of wind or weather), **thermals** (a bubble model, but sources and
strength come from the field, not from the anchor table) and **perturbations** (turbulence and gusts, from
the field's turbulence statistics). The daily cycle, the heating inertia by surface class and temperature as
an input parameter stayed the same; the field takes them as input. More: [air model](/mechanics/air-model/),
[docs/guide/air-model.md](/docs/guide/air-model.md).

## Details

- [docs/archive/plan/weather-by-temperature.md](/docs/archive/plan/weather-by-temperature.md): the full plan:
  interface, formulas, configs, the pilot's answers.
- [docs/guide/atmosphere.md](/docs/guide/atmosphere.md) → "Weather from the forecast": how it is wired into
  the game.
- [docs/research/calibration_data.md](/docs/research/calibration_data.md): tables for calibration
  (§1 "Thermals", §6 "Atmosphere profiles, clouds").
- [scripts/atmosphere/weather_model.gd](/scripts/atmosphere/weather_model.gd),
  [scripts/atmosphere/surface_heating.gd](/scripts/atmosphere/surface_heating.gd): the code.
- [configs/weather_model.json](/configs/weather_model.json): all the numbers of the weather model.
- [CHANGELOG.md](/CHANGELOG.md): what changed for the pilot, by date.
