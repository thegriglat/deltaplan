---
title: "The air model at three scales"
weight: 100
description: "One physical air field instead of a set of formulas: wind flows around the terrain, and thermals and turbulence take their place and strength from the field. What it can do, what it was checked against, where it is wrong."
---

# The air model at three scales

Earlier, wind and thermals in the game were a set of separate formulas: a global wind of one direction, a separate bonus at a slope, thermals from a heating map. Now the air is computed as one physical field on a grid, and thermals and turbulence take their place and strength from it. The model runs in the game and is on by default; if the field could not be computed, the game stays on the old formulas.

Below: what the model can do, what it is based on, which measurements it was checked against, and where it is known to be wrong.

## What the model can do

![Section of the field through the launch: lift over heated slopes and sink behind the ridge](/tools/research/air3d/out/fig_section.png "Vertical section of the field through the launch (Ongudai, 13:00): calm, south wind 3 m/s, windows of 100 and 50 m and a 200 m domain. Left: vertical velocity; right: how much warmer the air is than the background")

**Wind flows around the terrain.** Lift on the windward slope, acceleration at the brow, sink behind the ridge, flow around hills sideways, stronger wind in a saddle all come out of the field itself, not from separate formulas. With an oblique wind the lift is weaker: at 45° it is 0.72 of the lift across the slope (pilots' words: 0.55–0.8).

**Rotor and jolts behind the ridge.** Behind the ridge the field shows a wake: sink and weaker wind. On top of it the model adds a mixing layer between the flow over the ridge and the wake (turbulence in it is 0.14 of the velocity jump), downward jolts and reverse wind near the ground. Where the solver itself gives reverse flow (50 and 100 m windows, the bubble covered by at least 8 cells), the reverse flow is taken from the field; on the coarse 400 m domain it comes from an estimate based on Perdigão measurements (0.22 of the wind at ridge-top level).

According to model calculations this strongly changed the sink behind the ridge at 9 m/s near the ground: the minimum vertical velocity at 10 / 20 / 50 m above the launch was −13.0 / −18.2 / −16.4 m/s (jolts of the old heuristic, which counted from the largest wind above the ridge), and became −0.9 / −1.2 / −1.8 m/s against −0.8 / −1.0 / −1.4 m/s in the field itself. Turbulence behind the ridge at three checked launches is now weaker than before according to the calculations: σ<sub>w</sub> 0.86 / 0.77 / 0.44 m/s against 1.14 / 1.08 / 1.27 (by 25–65 %). The reference is physics; the earlier feel is an observation, and a pilot's flight will check it.

**Thermals are taken from the field.** The thermal bubbles remain, but where they are born, how strong they are, how high they rise and where they drift is decided by the field: sources are where there is more heat at the ground and the air converges. For Ongudai at 12:00 (wind 3 m/s, clear, a typical July) there are 4.9 sources per km² on heated slopes, 0.7 on weakly heated ones, and 0 in shade (where there is no heat flux). In the morning, at 9:00, the mixing layer is thin, the cores are small (radius 25–60 m) and frequent, with strength 1.1–1.5 m/s; at 12:00 it is 2.7–3.2 m/s. The ceiling is set by the inversion, not by the cloud edge: with an inversion of 20 K/km above 2000 m a parcel rises to 2061 m. On real terrain the thermal column is 575 m in the morning, 1440 m at 12:00 and 1640 m at 15:00.

![Where thermals are born: heat flux, air convergence and sources over Kayancha, 12:00](/tools/research/air_thermals/out/fig_sources_kayancha_w100_h12.png "Kayancha, 12:00: heat flux, mean air convergence in the layer and 109 thermal sources (the dot is proportional to strength)")

**Turbulence.** Its strength is computed from the field: from the wind near the ground, wind shear, stability and convection. It grows with the wind; at the brow at 20 m it is 1.5 times stronger than on flat ground (the air accelerates there); in stable air above the surface layer it almost dies out. The gust spectrum is now close to the −5/3 law: slope from −1.58 to −2.00 against about −2.9 for the old noise.

![Gust spectrum in straight flight: the field and the old analytics](/tools/research/air_turb/out/spectrum.png "Spectrum of gusts u and w at 150 and 400 m above the Aushkul launch, straight flight at 12 m/s")

**The field is computed around the pilot and updated.** Three levels: a 400 m domain for the whole site (38.4 km), a 100 m window (6.4 km) and a 50 m window (3.2 km) around the pilot. The windows join their parent without a step: 50 m before the window edge the wind at 50 m above ground changes by 9–12 % (inside the window, by 9–18 %). When the pilot has moved a quarter of the window side away from its center, the windows are recomputed in the background (1–3 s) while the game uses the old ones. The field is recomputed every 15 game minutes and when the wind changes (by more than 0.05 m/s or 1°) or the weather changes; the new field is blended in smoothly over 60 seconds.

![The seam between field levels at Kayancha: the levels differ, but what the pilot sees changes smoothly](/tools/research/air_clipmap/out/seam_kayancha_h12_U3.png "Seam between levels, Ongudai, 12:00, wind 3 m/s: the 400 m domain, the 100 and 50 m windows and what the game sees. Gray is the window edge strip")

**Loading.** When a site loads there is a "Computing wind from terrain…" stage: 3.3–3.9 s on an RTX 4070 SUPER (on weak AMD cards the estimate is up to 15 s).

**Network play.** Each client computes the field itself, and on different video cards it comes out slightly different. Thermal locations are shared by everyone: the host chooses the sources and sends them to the others, while each computes strength, ceiling and drift from its own field; the differences are at most 0.008 m/s in strength and 0.4 m in the thermal axis.

## What it is based on

### Physics

The basis is the conservation of mass, momentum and heat in the Boussinesq approximation: air density is taken as constant except for the buoyancy term. The model looks for a **steady** solution, the mean picture over an hour in mixed air, rather than a step-by-step time simulation (on a fine grid that would cost minutes per frame). It is solved by Picard iteration: approximations are refined until the field stops changing. The computation runs on the video card in Vulkan compute shaders, so it works on AMD too, not only on NVIDIA.

There are three scales:

| Scale | What it means for the pilot | Size / time | How it is computed |
|---|---|---|---|
| 1. Mean field | where it blows, where the slope holds, where thermals "stand", ceiling, drift | cell 400 m over the domain, 100 and 50 m around the pilot; field for a game hour | Boussinesq equations, Picard iteration, GPU |
| 2. Thermals | core, edge, "missed and dropped", life of a bubble | 100–500 m, minutes | bubbles (Gedeon, Allen); place, strength, ceiling and drift from field 1 |
| 3. Perturbations | turbulence, gusts, downward blows, rotor | under 50 m, seconds | turbulence statistics; strength from fields 1 and 2 |

Scales 2 and 3 take "where and how much" from the field by physical formulas; the shape and life remain their own (the thermal bubble, the gust spectrum). The field's vertical component is split into mechanical (air flowing over terrain, which goes to the pilot directly) and convective (from heating, which goes only through thermal bubbles), so that heat is not counted twice. Thermal strength comes from the Deardorff scale, using the heat flux from the ground and the mixing-layer height; turbulence uses the same formula, and its w<sub>*</sub> matches the w<sub>*</sub> of the sources: the ratio is 1.001 ± 0.038 (Kayancha, 12:00).

The computation method was chosen from several. Time stepping is accurate but expensive (7–18 s per 200 m domain against 2–5 s for Picard iteration on an RTX 4070 SUPER); linear kernels with superposition are physically wrong: a thermal made as a sum of kernels came out three times weaker than a real one. Picard iteration gives an error of at most 0.5 % in wind and about 1 % in temperature deviation. More in the [prototype summary](/tools/research/heat_ca/out/summary.md).

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

Result of the last joint calibration: the common mixing length near terrain is 27 m (+4 −3) from Askervein and Perdigão together, χ²/ndf = 208/76 (Askervein 165 for 47 observables, Perdigão 43 for 35). This is much more than the uncertainties allow: the model does not describe the data within their limits. The cases pull the parameter in different directions: Askervein alone wants 145 m, Perdigão alone 10 m (the lower edge of the grid). This is a structural discrepancy of the model that a parameter cannot remove. In the game the mixing length equals max(40 m, 0.0158·h), where h is the layer thickness; the lower bound of 40 m is needed for the computation to converge. The exponent of the wind profile with height depends on stability (0.24 in a neutral layer; 0.11 at clear noon in calm and at 3 m/s); the Prandtl number 0.85 is taken from neutral-layer measurements.

Pilots' words against the model after calibration (synthetic case, wind 5 m/s):

| Pilot's words | Target | Model | Matched |
|---|---|---|---|
| lift band about 2 mountain heights, calm above | speed-up at 2 H above the foot at most 10 % | 19 % (potential flow: 24 %) | no |
| saddle is a "pipe" ×1.5 | 1.5 ± 0.2 | ×1.9 at 20 m, ×1.74 at 50 m | no |
| in a saddle the wind turns toward the axis | at most 5° | 4.2° | yes |
| oblique wind 45° | lift 0.55–0.8 of direct | 0.72 | yes |

## Limits of the model

- **No moisture or clouds in the field.** Cloud base is taken from the weather model, as before. Moisture is for later.
- **Steady mean, not a time simulation.** The field is the mean circulation over an hour; bubbles and eddies belong to scales 2 and 3.
- **Speed-up at the brow is underestimated by 15–20 % at 20–100 m above the slope.** Over the Kayancha launch in a head wind (neutral, 6 m/s) the speed with a 50 m cell and 1st order is 0.80 / 0.83 / 0.84 / 0.92 of the solution with a 25 m cell and 2nd order at 20 / 30 / 50 / 100 m. The cause is the numerical diffusion of 1st-order advection and the limited terrain resolution. The way to fix it, if pilots say "weak at the brow": 2nd order in the windows (time ×2–3) or a 25 m window.
- **Saddle ×2.05 instead of ×1.5.** At a Froude number of about 2 the flow goes over the whole range, and the saddle works as a lowered ridge. The day's stability comes from the weather; there is no separate "saddle knob".
- **The lift band over a steep ridge is higher than "two heights".** At 2 H the speed-up is still about 19 %; potential flow over the same terrain gives 24 %.
- **Over the summit and on the windward slope turbulence is overestimated.** On Askervein the measured turbulence there is almost as on flat ground (in the accelerated flow it has no time to grow); the model gives 1.5–4 times more (after the last calibration, 2–3). Behind the ridge it matches within uncertainty.
- **The surface is meadow everywhere.** Roughness 0.1 m for the whole field; there are no surface classes (forest, rock, water) in heating, and over forest mechanical turbulence is underestimated.
- **Gusts and jolts are a prescribed shape, not an eddy calculation.** The noise is carried by one wind, not the local one: in the quiet wake behind the ridge the eddies "fly past" faster than in life (about 10 against 3–5 m/s). For the jolts, the amplitude and the mean (zero) are derived from physics, but not the tail of the distribution.
- **Thermals.** Core strength is a single fraction of w<sub>*</sub> (1.24), without spread between neighbors; in life the spread is wider. "Strong thermals every 1–1.5 layer thicknesses" the model does not reproduce by construction: the density of all cores matches the literature, the spacing of strong ones does not. There are no "streets" along the wind. The source list is updated once per field hour. Small morning thermals with a column shorter than 300 m are not born.
- **Evening, night, calm.** The nocturnal jet maximum is not reproduced; stable cases have not been checked against inflow data (the calibration is neutral). In calm the computation converges more slowly and in places does not converge.

## Known discrepancies

The model is ready, but two things in the field behind the ridge have known errors. The author checked them against the literature and decided not to fix them now: with this amount of data they cannot be calibrated more precisely. They are recorded for a separate task.

**(a) In strong wind behind the ridge the model shakes the wing more than in life.** Noticeable on the lee side, 50–100 m above ground. The shear layer above the wake gives turbulence of 0.4–0.6 of the velocity jump, while in measurements and in literature calculations it is 0.13–0.15 (mixing layer: 0.14; above the lee ridge in Perdigão: about 0.16 of the wind). The difference is 3–4 times. Individual vertical-velocity peaks reach 0.54–0.74 of the wind at ridge-top level, which at 9 m/s is −6…−9 m/s; that is 3–4 σ of overestimated turbulence, and the distribution of vertical velocity in the wake is skewed upward in measurements. Sources: Liu et al. 2016, 2020; Bell & Mehta 1990; Menke et al. 2019. The model errs on the side of "throws harder".

**(b) Reverse wind near the ground behind low bumps and gentle slopes is overestimated.** Where the solver does not resolve the separation bubble (low bumps with a height of about 70 m or less, and on the 400 m domain behind any ridges outside the windows), it is replaced by an estimate from the Perdigão ridge: length 2.8 heights and reverse speed 0.22 of the wind at the ridge, with no check of the slope. In life separation begins at a slope of about 0.27 (two-dimensional slope) or 0.36 (three-dimensional bump); at a slope of 0.63 the bubble length is about 1.6 heights for a bump and 3.5 for a ridge. For three-dimensional bumps the length is overestimated about 1.8 times. The reverse speed of 0.22 is the maximum inside the bubble, not the mean; in a wind tunnel it is −0.1…−0.2 of the wind, so as a mean it is overestimated 1.5–2 times. Noticeable near the ground in strong wind; the error is "too much return wind".

## More

- [The air model in the game](/docs/guide/air-model.md): the main document, what works, laws, numbers, limits.
- [Air model plan](/docs/plan/air_model.md) and [work log](/docs/archive/plan/air-model-progress.md): decisions, stages, closing the module.
- [Calibration](/docs/research/air-model-tune.md), [sensitivity](/docs/research/air-model-sensitivity.md), [GPU solver and windows](/docs/guide/air-model-gpu.md).
- Calibration on two data sets: [Askervein and Perdigão](/docs/archive/plan/air-model-b1.md).
- [Catalog of experimental data](/docs/research/experimental_data.md); data of [Askervein](/tools/research/data/askervein/README.md) and [Perdigão](/tools/research/data/perdigao/README.md).
- Research: [3D reference on Ongudai terrain](/tools/research/air3d/README.md), [thermals from the field](/tools/research/air_thermals/README.md), [turbulence from the field](/tools/research/air_turb/README.md), [2D prototype](/tools/research/heat_ca/README.md).
- [Slope wind](/mechanics/slope-wind/), [thermals](/mechanics/thermals/), [weather](/mechanics/weather/); [research and plans](/research/).
