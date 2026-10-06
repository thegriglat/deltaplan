---
title: "The air model at three scales"
weight: 100
description: "Why the air in the game is computed at three levels — mean wind field, thermals, turbulence — and why that split is acceptable: scales, what a pilot feels, what it was checked against, where the model is wrong."
---

# The air model at three scales

The air in the game is not a set of separate formulas but a physical field: wind flows around the terrain, and thermals and turbulence take their place and strength from it. It is computed at three levels. This page explains **why three levels and why that split is acceptable**; what exactly is computed at each level is on its own page:

| Level | What it is for a pilot | Scale | Page |
|---|---|---|---|
| 1. Mean wind field | where it blows, where a slope holds, where wind separates behind a ridge, where thermals "stand", ceiling, drift | 400 m cell over the area, 100 and 50 m around the pilot; a field per game hour | [Wind field: phases and Picard](/mechanics/wind-phases/) |
| 2. Thermals | core, edge, "missed and dropped", life of a bubble | 100–500 m, minutes | [Thermals](/mechanics/thermals/) |
| 3. Turbulence and rotor | jolts, downdrafts, shaking behind a ridge | under 50 m, seconds | [Turbulence and rotor](/mechanics/turbulence/) |

The model is on by default. There is no neural network in the game: the wind field is computed with physics (phases and Picard), not by a trained network. If the field could not be computed, the game stays on the old formulas — [slope wind](/mechanics/slope-wind/); in the settings they are called "Heuristic".

## Why three levels

The atmosphere spans scales from tens of kilometers (slopes, valleys, daily circulations) to fractions of a meter (eddies that toss the wing). Computing everything at once, honestly, in one go is impossible: to resolve 30 m eddies over tens of kilometers you need billions of cells on every time step — minutes per frame. And it is not needed: the scales differ in character, and each suits its own method.

- **Size and time.** The mean wind field over terrain changes over an hour and lives at kilometers — it can be computed as a steady solution of the equations on a coarse grid. A thermal is tens to hundreds of meters and minutes of life: a separate object that must be put in the right place and given strength. Turbulence is meters and seconds: its details are random, the statistics matter.
- **Each level takes "where and how much" from the one below.** The mean field says where there is more heat at the ground and the air converges (thermals are born there), where the flow separates behind a ridge (turbulence is stronger there), what wind carries the eddies. The shape and life of a thermal bubble and the gust spectrum are their own, but their amplitudes are derived from the field rather than fitted separately.
- **No double counting.** The vertical velocity of the field is split into mechanical (air flowing over terrain — goes to the pilot directly) and convective (from heating — reaches the pilot only through thermals). Otherwise heat would be counted twice.
- **One physical law across levels.** The strength of a thermal is the Deardorff scale w<sub>*</sub> from the heat flux off the ground and the mixing-layer height; turbulence uses the same formula, and its w<sub>*</sub> equals that of the thermal sources: ratio 1.001 ± 0.038 (Kayancha, 12:00).

### What a pilot feels and what not

Whether the split is acceptable is decided by what a person under the wing perceives.

**Feels:** lift on a slope and its height; wind speed-up at the brow; sink and reverse wind behind a ridge; the rotor; a thermal — core, edge, drift with the wind and the ceiling at the inversion; the difference between morning and noon; jolts that roll the wing: the wing halves get air from the field at different points, so a different flow across the span rolls and shakes the wing by itself.

**Does not feel or see (absent in the model or averaged):** individual eddies smaller than a few meters — they give noise, not eddies as objects; the exact position of every neighboring thermal — density and strength matter, not a photograph of a particular day; thermal "streets" along the wind; moisture in the field (clouds come from the weather model); the nocturnal jet. These are deliberate limits, listed below and on the level pages.

How the split is checked: where levels meet, mass flux (lift in thermals is compensated by sink around them) and the common scale w<sub>*</sub> are preserved; the turbulence spectrum is checked against the −5/3 law, thermal density against the literature. Where a check failed, it is written in the limits.

## How the field is computed around the pilot

![Section of the field through the launch: lift over heated slopes and sink behind the ridge](/tools/research/air3d/out/fig_section.png "Vertical section of the field through the launch (Ongudai, 13:00): calm, south wind 3 m/s, windows of 100 and 50 m and a 200 m area. Left: vertical velocity, right: how much warmer the air is than the background")

The level 1 field lies on three nested grids: a 400 m area for the whole place (38.4 km), a 100 m window (6.4 km) and a 50 m window (3.2 km) around the pilot. The windows join their parent without a step: 50 m before the window edge the wind at 50 m above ground changes by 9–12 % (inside the window, by 9–18 %). When the pilot has moved a quarter of the window side from its center, the windows are recomputed in the background (1–3 s) while the game uses the old ones. The field is recomputed every 15 game minutes and when the wind or weather changes; the new one is blended in smoothly over 60 seconds.

![Seam of the field levels at Kayancha: the levels differ, but what the pilot sees changes smoothly](/tools/research/air_clipmap/out/seam_kayancha_h12_U3.png "Seam of the levels, Ongudai, 12:00, wind 3 m/s: 400 m area, 100 and 50 m windows and what the game sees. Gray is the window edge strip")

The computation runs on the graphics card in Vulkan compute shaders, so it works on AMD as well as NVIDIA. When a place loads there is a "Computing the wind" stage — on the order of a few seconds on a modern card. Without a graphics card the game does not run (clouds are on it too).

**Multiplayer.** Every client computes the field itself, and on different cards it comes out slightly different. The thermal places are shared: the host chooses the sources and sends them to the others, while each computes strength, ceiling and drift from its own field; the differences are at most 0.008 m/s in strength and 0.4 m in the thermal axis.

## What it is based on

The basis is the conservation of mass, momentum and heat in the Boussinesq approximation: air density is constant except in the buoyancy term. The model looks for a **steady** solution — the mean picture over an hour, rather than a step-by-step time simulation (on a fine grid that would cost minutes per frame). It is solved by the Picard method: approximations are refined until the field stops changing. But "one Picard for everything" has a known limit: in calm, in strong blocking and in convection there is no steady solution, or it is not what is needed. That is why at level 1 a sorting into wind phases stands before Picard — see the [separate page](/mechanics/wind-phases/).

The computing method was chosen from several. Time stepping is exact but expensive (7–18 s per 200 m area against 2–5 s for Picard on an RTX 4070 SUPER); linear kernels with superposition are physically wrong — a thermal from a sum of kernels came out three times weaker than the real one. The Picard method gives an error of at most 0.5 % in wind and about 1 % in temperature deviation. More in the [prototype summary](/tools/research/heat_ca/out/summary.md).

### What it was checked against

The data are collected in the [catalog](/docs/research/experimental_data.md): where they come from, what was measured and what limits it.

**Askervein** (South Uist island, Scotland, 1982–83) is the classic test of flow over a single hill 116 m high: masts along lines across the hill, wind 210°, 8.9 m/s, nearly neutral air. The data are [Zenodo 4095052](/tools/research/data/askervein/README.md), CC BY 4.0. We compared the speed-up of wind relative to a reference mast at the same height: 36 points at 10 m and a height profile at the summit.

![Askervein: speed-up along the line across the summit and the profile at the summit, model against measurements](/tools/research/air3d/out/ref/fig_askervein.png "Askervein: wind speed-up along line A at 10 m and the profile at the summit. Dots are measurements, lines are the model on 25 and 50 m grids, with 1st and 2nd order advection")

What did not match: on the fine grid (12.5 m) the model gives a speed-up of 0.59–0.61 at 10 m near the summit against the measured 0.82–0.88; just past the summit it already slows the flow (0.19 against 0.68 and −0.07 against 0.40), while the measurements still show speed-up there. Along the ridge it is 0.1–0.3 below the measured.

**Perdigão** (Portugal, 2017) is two parallel ridges with a valley-to-ridge drop of about 200 m and a distance between ridges of about 1.4 km, patches of forest; masts and lidars. It is needed for the wake and rotor, which Askervein hardly shows (only 3 points behind the hill). Two neutral cases were selected: wind from the north-east (27.04.2017) and from the south-west (11.05.2017), about 8.8 m/s at 100 m. From the paper by Menke et al. 2019 the statistics of the reverse-flow zone over 1619 ten-minute periods are taken: it is present 52 % of the time, 697 m long on average (about 2.8 ridge heights), with a maximum reverse speed of about 0.22 of the wind at 100 m.

![Perdigão: wind along the ridges, model, best fit](/tools/research/cases/b1/out/fig_best_sections.png "Perdigão: section across the ridges, along-wind velocity to the wind at 100 m. Black dashed line is the reverse-flow boundary −0.5 m/s. Top: the north-east case, bottom: the south-west case; left: 2nd order advection, right: the game's scheme")

What did not match: the model does produce a reverse-flow zone behind the ridge, but weaker than measured: length 0.40 of the distance between ridges against 0.50 (north-east case), maximum reverse speed 0.11 of the wind at 100 m against 0.22; in the south-west case the length is 0.20 against 0.50.

**Other.** Thermal density N·z<sub>i</sub>/L = 1.4–1.5 against 1.2 ± 0.4 from the literature (Lenschow & Stephens 1980); number, radius and strength of cores follow Allen 2006; the gust spectrum follows the −5/3 law. Pilots' words did not enter the fit: they were compared with the model after calibration (table below).

### Calibration

There is no fitting "by eye so that it feels good": that is the author's decision. Calibration follows the Professor scheme from high-energy physics: a grid of model runs over the parameters, a polynomial approximation of each observable, and the χ² minimum against measurements with uncertainties. Only unknown parameters with physical meaning are fitted; those known from the literature are fixed with a reference; there are noticeably fewer parameters than observables.

Result of the last joint calibration: the common mixing length near terrain is 27 m (+4 −3) from Askervein and Perdigão together, χ²/ndf = 208/76 (Askervein 165 for 47 observables, Perdigão 43 for 35). This is much more than the uncertainties allow: the model does not describe the data within their limits. The cases pull the parameter in different directions: Askervein alone wants 145 m, Perdigão alone 10 m (the lower edge of the grid). This is a structural discrepancy of the model that a parameter cannot remove. The exponent of the wind profile with height depends on stability; the Prandtl number is taken from neutral-layer measurements.

Pilots' words against the model after calibration (synthetic case, wind 5 m/s):

| Pilot's words | Target | Model | Matched |
|---|---|---|---|
| lift band about 2 mountain heights, calm above | speed-up at 2 H above the foot at most 10 % | 19 % (potential flow: 24 %) | no |
| saddle is a "pipe" ×1.5 | 1.5 ± 0.2 | ×1.9 at 20 m, ×1.74 at 50 m | no |
| in a saddle the wind turns toward the axis | at most 5° | 4.2° | yes |
| oblique wind 45° | lift 0.55–0.8 of direct | 0.72 | yes |


## Limits of the model

Common to the whole model; specific ones are on the level pages.

- **No moisture or clouds in the field.** Cloud base is taken from the weather model. Moisture is for later.
- **Steady mean, not a time simulation.** The field is the mean circulation over an hour; bubbles and eddies belong to levels 2 and 3.
- **Speed-up at the brow is underestimated by 15–20 % at 20–100 m above the slope.** The cause is the numerical diffusion of 1st-order advection and the limited terrain resolution. The way to fix it, if pilots say "weak at the brow": 2nd order in the windows (time ×2–3) or a 25 m window.
- **Saddle ×2.05 instead of ×1.5.** At a Froude number of about 2 the flow goes over the whole range, and the saddle works as a lowered ridge. The day's stability comes from the weather; there is no separate "saddle knob".
- **The lift band over a steep ridge is higher than "two heights".**
- **The surface is meadow everywhere.** There are no surface classes (forest, rock, water) in heating, and over forest mechanical turbulence is underestimated.
- **Evening, night, calm.** The nocturnal jet maximum is not reproduced; stable cases have not been checked against inflow data (the calibration is neutral). In calm the model has no steady solution — the field there comes from statistics (see [phases](/mechanics/wind-phases/)).

## More

- [The air model in the game](/docs/guide/air-model.md): the main document, what works, laws, numbers, limits.
- [Air model plan](/docs/plan/air_model.md) and [work log](/docs/archive/plan/air-model-progress.md): decisions, stages, closing the module.
- [Calibration](/docs/research/air-model-tune.md), [sensitivity](/docs/research/air-model-sensitivity.md), [GPU solver and windows](/docs/guide/air-model-gpu.md).
- Calibration on two data sets: [Askervein and Perdigão](/docs/archive/plan/air-model-b1.md).
- [Catalog of experimental data](/docs/research/experimental_data.md); data of [Askervein](/tools/research/data/askervein/README.md) and [Perdigão](/tools/research/data/perdigao/README.md).
- Research: [3D reference on Ongudai terrain](/tools/research/air3d/README.md), [thermals from the field](/tools/research/air_thermals/README.md), [turbulence from the field](/tools/research/air_turb/README.md), [2D prototype](/tools/research/heat_ca/README.md).
- [Wind phases: research](/docs/research/air_phase.md), [measurements on ideal terrain](/docs/research/air_phase_results.md), [plan](/docs/plan/air-phase.md).
- [Wind field: phases and Picard](/mechanics/wind-phases/), [thermals](/mechanics/thermals/), [turbulence and rotor](/mechanics/turbulence/).
- [Slope wind](/mechanics/slope-wind/), [thermals](/mechanics/thermals/), [weather](/mechanics/weather/); [research and plans](/research/).
