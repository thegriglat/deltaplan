---
title: "Weather"
weight: 40
description: "Weather from temperature and the daily cycle: how a whole day is derived from the daytime maximum, wind and sky cover: thermal height, cloud base, heating inertia, the evening."
---

# Weather from temperature and the daily cycle

The pilot in the game does not pick a "weak / medium / strong day" from a list. They set what they see in
the forecast: the daytime maximum temperature, wind strength and direction, and cloud cover. Everything
else (thermal height, cloud base, strength and frequency of the lift, thunderstorm probability, the daily
cycle) is derived from these numbers by the model, physically.

## How it works

The "Flight setup…" screen sets three things: the **daytime temperature** (0…+40 °C, a slider with the hint
"usually this month: …"), the **wind** (from 0 m/s at the launch; the top of the slider is the largest wind limit among the wing classes, currently 25 m/s; plus a direction, "headwind" or one of 8
compass points) and the **cloud cover** ("Clear / Partly cloudy / Overcast"). `WeatherModel.derive` (pure
functions, `scripts/atmosphere/weather_model.gd`, parameters in `configs/weather_model.json`) turns these
three numbers into the same parameter dictionary that used to be hard-coded in the `weak/medium/strong`
presets. Humidity is not asked for separately: the pilot found it unnecessary, so the dew point is taken as
typical for the month (the `dew_point_c` table, one for Altai and Bashkiria, 50–56° N).

**Thermal height and cloud base.** In the mixed layer a rising bubble cools along the dry adiabat, while
the surrounding air above cools at the climatological lapse rate of the month:

$$ z_{dry} = h_v + \frac{(T + \delta) - T_u - \Gamma_{env}(z_u - h_v)}{9.8 - \Gamma_{env}} $$

$$ z_{lcl} = h_v + 0.122 \cdot (T - T_d) $$

where `h_v` is the valley height (the lowest 10 % of the terrain within a 10 km radius), `δ` = 1 K is the
bubble's superheat, `Γ_env` = 4 K/km is the climatological lapse rate above the layer, and `T_u` and `T_d`
are the tabulated temperature at 3000 m and the dew point for the month. The top of the lift is the smaller
of the two: `z_top = min(z_dry, z_lcl)`. The margin `m = z_dry − z_lcl` determines whether the day will be
cumulus or "blue" (no clouds if `m < −100 m`).

For the reference place from `configs/weather_model.json → reference_context` (Altai, Sinyukha, 15 July: `h_v` = 304 m, mean ground 509 m, `T_u` = +2.5 °C, `T_d` = +9 °C):

| Daytime temperature | z_dry | z_lcl | margin m | cloud base above mean ground | day |
|---|---|---|---|---|---|
| +12 °C | 255 m | 670 m | −415 m | 300 m (minimum) | almost dead, blue |
| +16 °C | 945 m | 1160 m | −213 m | ~440 m | weak dry thermals |
| +20 °C | 1630 m | 1650 m | ≈ 0 | ~1130 m | weak (a few small clouds) |
| +26 °C | 2670 m | 2380 m | 290 m | ~1870 m | good day |
| +31 °C | 3530 m | 2990 m | 540 m | ~2480 m | strong, overdevelopment |
| +34 °C | 4050 m | 3350 m | 690 m | ~2850 m | thunderstorm: Cb noticeably more frequent |

The values are computed from the formulas above with the config parameters (`z_dry`, `z_lcl` are above sea level).

The cloud base rises by roughly 120–140 m per degree of temperature–dew point spread, as pilots know from
the rule "+1 °C is another 120 m".

**Thermal strength, size and frequency** come from a piecewise-linear table of anchor points by the height
of the top of the lift (`top_agl`). Its rows exactly match the values of the former presets (the
calibration is preserved), with corrections for the season (solar elevation at noon) and for the wind
(strong wind tears thermals apart: the strength multiplier falls from 1.0 in weak wind to 0.5 at 45 km/h).

**Sky cover from the forecast** ("Clear / Partly cloudy / Overcast", `configs/weather_model.json → sky`) reduces the
heating once: the heating share is 1.0 / 0.8 / 0.3 (thermal strength × share^⅓ — ×0.93 and ×0.67), the share of
births × 1 / 0.85 / 0.5, softness 0 / 0.3 / 1; thunderstorm cells ×0.7 for "Partly cloudy" and none for "Overcast".
The sky veil dims the sun for the sources only beyond the chosen sky cover, not twice.

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

**Ground heating inertia** works over 9 surface classes (`configs/weather_model.json → heating.lag_h`):
a thermal source takes not the current sun but the sun delayed by its class (≈ 0.6·τ): meadow and field 0.3 h
(τ ≈ 0.5 h), shrub 0.4 h, forest 0.6 h, rocks and scree 0.9 h (τ ≈ 1.5 h), built-up area 1.2 h, water 0 (it
barely heats; it has its own flux from the water–air temperature difference). That is why "evening thermals
from rocks" and warm walls appear later than over open fields.

**After sunset** land heating is zero: there are no new thermals either in the analytic part or in the air
field, and live ones finish their cycle (before, rocks and built-up areas kept "heating" with a lag after
sunset; build 1.5.12). The exceptions are water (a warm lake in autumn gives an upward heat flux in the
evening) and the city, which cools over ≈ 1.5 h down to a weak night flux of 25 W/m². The air field is
computed for the chosen flight date, not for 15 July as it was before 1.5.12. The water temperature used for heating the air over lakes comes from the same weather model: the daily mean air temperature 30 days before the date, at the lake height (at or below 0 °C it is ice, treated as snow); see [Thermals](/mechanics/air-model/thermals/).

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
- **Snow does not depend on the weather.** The temperature slider starts at 0 °C, lying snow is not drawn
  from the forecast and does not change the heating; fresh snow and glaciers on high mountains depend on the
  date and latitude, not on the day's temperature (see [“Terrain and places”](/mechanics/terrain/)). The snow
  class does heat (as a surface class), but only mountains above the snow line and ice on lakes get it.
- **There is no precipitation:** the weather model does not produce rain or snowfall, only clouds and
  thunderstorm cells.
- **The wave is hidden and off by default** (`wave.enabled = false`): the physics of the lee wave (strong
  wind across the ridge plus stable air) exists in the code, but the pilot does not know the word "wave",
  and by default it is not switched on. More on the page [“Slope wind”](/mechanics/air-model/heuristic/).

## What was considered and why this way

Previously the pilot chose from five ready-made weather presets ("Weak / Medium / Strong day / Thunderstorm
/ Wave"). According to the feedback this looked strange: a real forecast has no such categories, it has
temperature and wind. The presets were removed from the interface completely (without keeping compatibility
with old settings), but the `weak/medium/strong` values themselves remained in the internal references
`configs/weather/*` and tests as calibration points: the rows 1000/1700/2300 m of the anchor table are exactly those.

Separately, the option of a "mass-consistent wind field on a grid" was considered and rejected: solve the
continuity equation over the terrain and obtain a physically consistent wind without hand-written formulas
for the slope. Such a field had no heat (so no thermals, no difference between a heated and a cold slope, no
inversion) and no inertia (recomputation on a weather change would have been instantaneous, with no smooth
daily cycle). A general air model was chosen, where heat and inertia are built in from the start.

## Relation to the air model

The game has a single physical air field for three scales: the **mean field** (where it blows, where the
slope holds the glider up, the thermal ceiling: a steady solution of the Boussinesq equations, recomputed
every 15 game minutes and on a change of wind or weather), **thermals** (a bubble model, but sources and
strength come from the field, not from the anchor table) and **perturbations** (turbulence and gusts, from
the field's turbulence statistics). The daily cycle, the heating inertia by surface class and temperature as
an input parameter stayed the same; the field takes them as input. More: [air model](/mechanics/air-model/),
[docs/guide/air-model.md](/docs/guide/air-model.md).

## Details

- [docs/guide/atmosphere/weather.md](/docs/guide/atmosphere/weather.md) → "Weather from the forecast": how it is wired into
  the game.
- [docs/research/calibration_data.md](/docs/research/calibration_data.md): tables for calibration
  (§1 "Thermals", §6 "Atmosphere profiles, clouds").
- [scripts/atmosphere/weather_model.gd](/scripts/atmosphere/weather_model.gd),
  [scripts/atmosphere/surface_heating.gd](/scripts/atmosphere/surface_heating.gd): the code.
- [configs/weather_model.json](/configs/weather_model.json): all the numbers of the weather model.
- [CHANGELOG.md](/CHANGELOG.md): what changed for the pilot, by date.
