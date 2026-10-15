---
title: "Approaches and results"
weight: 25
description: "Which ways of computing wind over terrain, thermals, wings and world data were tried in Deltaplan, what came out in numbers, what is in the game now and why."
---

# Approaches and results

The game is built on physics, and physics can be computed in different ways. This page is a map of what we tried on the key topics: the numbers, the choice, the reason for it and what is in the game now (version 1.5.15). The longest topic is wind over terrain: it went from formulas through a GPU solver and a neural network to a field assembled by flow phases.

How to read it: for each approach — what was done, what came out, what was decided and why. All numbers are taken from the repository documents — the [findings registry](/research/findings/), [research](/research/), the [CHANGELOG](/releases/) and the [diary](https://github.com/thegriglat/deltaplan/tree/main/diary); where a number is an estimate rather than a measurement, it says so. The selection criterion is the same everywhere (the author's decision): first physics within the model's limits, then accuracy, then cost. "The pilot likes it" is a reference, not a requirement: tuning coefficients "so that it feels right" is a dead end, so tuning follows a scheme with measurements and uncertainties. Build numbers and dates follow the CHANGELOG; the pages of old builds describe what was true then.

## What is in the game now

- **Wind over terrain.** The "Wind over terrain" setting: "GPU solver" (default) — the field is assembled by flow phases and refined by the Picard method on the GPU; "Heuristic" — formulas without a field. Without a GPU there is no solver, the formulas apply.
- **Thermals and turbulence.** Sources, strength, ceiling and drift are taken from the wind field and from ground heating by land cover; the thermal's shape is a formula (Gedeon, Allen).
- **Wings.** 48 models in four groups, numbers from DHV and manufacturer datasheets, the origin of every number is marked.
- **Flight.** The default control mode is "Pendulum": a wing of 16 strips and a pilot on the hang chain, sideslip and stall come from forces; "Weight shift" and "Simple" remain selectable, bots and remote players over the network fly on them.
- **Takeoff.** Physics only: liftoff when lift is not less than weight; there are no fixed times.
- **Multiplayer.** WebSocket and protobuf, a built-in server for the local network, a Go server for the internet; Steam lobbies in the Steam builds.
- **World data.** Copernicus terrain at 25 m, ESA WorldCover land cover, OpenStreetMap objects from our own 20 km tiles.

Where the simulator simplifies or errs is said in the sections below and under "Model limits" on the [«Air model»](/mechanics/air-model/) and [«Flight»](/mechanics/flight/) pages.

## Wind over terrain

Summary of the approaches in order:

| # | Approach | When | Outcome and what is in the game now |
|---|---|---|---|
| 1 | Formulas: wind profile, slope lift, the "shadow line" behind a ridge | from the first build; version 0.8.0 | "not physical"; remain as the "Heuristic" mode and a fallback |
| 2 | Mass-consistent wind field (Poisson equation) | Sep 29 | not taken into work: no heat and no air inertia |
| 3 | Coupled "heating → buoyancy → flow" system: 2D prototype and six experiments | Sep 29 | the idea is physically right; the Picard method was chosen |
| 4 | Picard solver on the GPU, three scales | build 1.0.0, Oct 1 | in the game, but now as part of item 8 |
| 5 | Simplified mode "as in 0.8.0" | 1.0.3 and 1.0.4, Oct 3 | in the game as the "Heuristic" mode |
| 6 | Neural network instead of the solver: pilots P1, P2, P3; the network in builds 1.0.5–1.2.0 | Oct 2–5 | replacing the solver failed; removed in 1.3.0 |
| 7 | WindNinja as an independent reference | Oct 4 | not a solver replacement; confirms the speed-up on ridges |
| 8 | Field assembled by flow phases + Picard | build 1.3.0, Oct 7 | in the game, the "GPU solver" mode |

### 1. Formulas (version 0.8.0)

**What it is.** The pilot gets all air through one function, `Atmosphere.air_velocity_at`. Horizontal wind grows with height by a power law and with altitude above sea level, with a single direction for the whole world:

$$ u = u_{ref} \cdot \left(\frac{agl}{10\,\text{m}}\right)^{0.14} \cdot \left(1 + 0.6 \cdot \frac{msl - msl_{start}}{1000\,\text{m}}\right) $$

Slope lift is $w_{ridge} = \mathrm{clamp}(0.85 \cdot u \cdot (\hat w \cdot \nabla h) \cdot e^{-agl_s / 250}, \pm 6\ \text{m/s})$ with the slope point shifted upwind by $0.8\,agl$ (no more than 400 m). The lee zone is the "shadow line": below a line sloping at 12° from the ridge the air is in a rotor (sink $0.25\ldots0.7\,u$, turbulence $0.5\ldots0.9\,u$, downward gusts, reverse flow). Details — [the "Heuristic" mode](/mechanics/air-model/heuristic/).

**What came out.** The consultant pilot said the flow around terrain is "not physical". The analysis ([research](/docs/research/slope_wind.md)) found three discrepancies with real life: no wind speed-up at the brow, the lift band is a fixed 250 m, and the "pipe" in a saddle works the wrong way round. The pilot's reference points: speed-up up to about two mountain heights from the foot, laminar at 2.5 heights, the steeper the slope the stronger, saddle ×1.5 along the axis even with an oblique wind of 15° ([diary Sep 29](https://github.com/thegriglat/deltaplan/blob/main/diary/2026-09-29.en.md)).

When the solver was put next to it, defects in the formulas themselves turned up as well: at 9 m/s the heuristics' "downward gusts" gave −13…−18 m/s (in the formula they are proportional to the highest wind above the ridge), and the heuristics' reverse flow duplicated the solver's flow — the minimum along-wind speed at the start was −4.66 m/s instead of −0.52 m/s (a double rotor). Literature check: the maximum reverse flow behind ridges is 0.22 ± 0.08 of the wind at ridge level (Menke et al. 2019); the field gives ≈ 0.2, with the heuristics ≈ 0.4. So in the "GPU solver" mode the heuristics weight is 1 − smoothstep(2, 4, excess/dx), i.e. it fades out where the solver itself resolves separation; gusts are 0.42·ΔU (3σ<sub>w</sub>).

**What is in the game now.** The formulas were replaced by a physical field but remain: the "Heuristic" mode (the field is not computed on the GPU, the "Computing wind" stage is skipped), a fallback if the field was not computed, and the air outside the field's area.

### 2. Mass-consistent field

**What was tried (on paper).** Wind as a solution of the Poisson equation on the GPU: terrain deflects the flow, mass is conserved; linearity in wind (two base fields per stability level); nested grids around the pilot ("clipmaps") from 50 to 800 m. Estimate — about 31 days of agent work.

**What came out.** Not taken into work. The approach solved only the flow around terrain and gave neither heat nor air inertia: without heating of the ground there is no inflow to a heated slope, no column over the ridge and no thermal ceiling at the inversion. The same was shown later by the WindNinja check (item 7): a mass-consistent diagnostic model conserves mass but does not lose speed on flow around terrain.

**What was chosen.** The [three-scale air model](/mechanics/air-model/); the sections on the grid, clipmaps and GPU were reused. Compute platform: **CUDA rejected** (AMD cards are expected among the pilots), **Rust + rayon / GDExtension** considered and rejected (offline CPU computation is too slow for recomputing the field in the game), portable Vulkan compute (RenderingDevice in Godot) chosen.

### 3. Coupled system and the 2D prototype

**The author's idea.** A cellular automaton: a hot cell gives heat sideways and upwards and sucks in mass from cold ones; then — "layer→layer transition by multiplying by a transfer matrix", "a kernel as in image processing". Physical basis — the Boussinesq approximation: mass, momentum with buoyancy and non-local pressure, energy.

**Prototype on a 2D ridge section** (500 m ridge, slopes up to 33° and 16°, heating up to 250 W/m², [results](/research/heat_ca/)). Over the heated slope — lift 1.65 m/s (both slopes — 2.47 m/s over the ridge), inflow to the foot ≈ 0.5 m/s, sink over the valley −0.08…−0.2 m/s; an inversion at 1500–1800 m stops the column at 1550 m (without it, 1800). Conservation: mass residual ~10⁻¹¹ of the domain mass. Cell convergence: at 200 m there is no slope wind, 100 m is the coarsest grid with the right picture, at 50 m the lift has an error of about 15 %, finer than 25 m makes no sense.

**Six experiments: how to get a steady field quickly without thousands of time steps** ([summary](/research/heat_ca/out/summary/), [diary Sep 29](https://github.com/thegriglat/deltaplan/blob/main/diary/2026-09-29.en.md)):

| Experiment | What was checked | Result |
|---|---|---|
| 1, 3. Linearity, kernel superposition | Reduce the field to a convolution or a chain of filters | Linear only when lift is centimetres per second; at 250 W/m² the superposition error is 69 %, a thermal from a sum of kernels is three times weaker than the real one. **Rejected** |
| 6. "Jet kernel" | A chain of formulas: heating blur, warm pool, buoyant jet | 1–2 ms; location, strength and ceiling of a thermal ±5–30 %; the field is coarse. Suitable as an instant estimate |
| 4. Layer→layer transition matrices | Upward and downward pass by block sweep | The same fixed point, 1–2 %; 56–66 repeats almost independent of the cell (200…12.5 m); 0.33 s versus 24.6 s with steps at 12.5 m. A fallback for small windows |
| 5. ADI sweeps along lines | Rounds of implicit sweeps | The same point, 100–190 rounds, the iteration is expensive. Not chosen |
| 2. Picard method (Oseen momentum + projection by one V-cycle + heat) | Iterations to the fixed point | ≤ 0.5 % in wind, ≈ 1 % in temperature, 5–36 times faster than steps; 3D estimate for a 200 m domain — 2–5 s. **Chosen** |
| (Time steps) | Reference | 3D at 50 m — about 17 min; at 200 m 7–18 s against 2–5 s for Picard — too expensive for the game, remain the reference |

Incidentally it turned out that the reference solutions in the database are under-converged (absolute convergence criterion): 3–8 % off in wind and 10–23 % off in temperature from the exact fixed point — all the executors found this independently. The method was then carried over to the real terrain of Ongudai ([3D reference](/research/air3d/)).

### 4. Picard solver in the game (1.0.0)

**What was done.** Three scales: (1) the mean field — Picard on the GPU: a 400 m domain over the whole place (38.4 km), 100 and 50 m windows around the pilot, recomputed every 15 game minutes; (2) thermals — bubbles whose location, strength, ceiling and drift are taken from the field; (3) turbulence — a spectrum of gusts, strength from the field. Details — [«Air model»](/mechanics/air-model/).

**Comparison with measurements** (details — on the mechanics page):
- Askervein (116 m hill): on the fine 12.5 m grid the speed-up at the summit at 10 m is 0.59–0.61 against the measured 0.82–0.88; right behind the summit the model already slows the flow, while the measurements still show speed-up.
- Perdigão (two ridges): the reverse-flow zone is weaker than measured — length 0.40 against 0.50 of the distance between the ridges (north-east case), 0.20 against 0.50 (south-west case); maximum reverse speed 0.11 against 0.22 of the wind at 100 m.

**Calibration** — by the Professor scheme (grid of runs → polynomials → χ² with uncertainties). Joint calibration on two datasets: common mixing length 27 m (+4 −3), χ²/ndf = 208/76 — the model does not describe the data within the uncertainties; the cases pull the parameter in different directions (Askervein wants 145 m, Perdigão — 10 m). This is a structural discrepancy that a parameter cannot remove.

**What the Morris screening found** (16 factors × 6 cases, 1230 runs, 5.3 h of GPU): the model is soft in the switches and the profile exponent α, rigid in the data (94 % — one SVD direction) and degenerate (λ/h ≈ α ≈ transport order ≈ local_k, cosines 0.93–0.94). Three bugs were found and fixed: the Prandtl number, cooling and the layer height in the closure. The Prandtl number was set to 0.85 (the author's decision): saddle ×2.05, lift at the start in calm −15 %. The conclusion "the data pull λ/h upward" turned out to be an artefact of the manual α = 0.17: the mast profile gives α ≈ 0.22, the best χ² points ≈ 54 at α 0.20–0.24. Source — the [findings registry](/research/findings/), [sensitivity](/docs/research/air-model-sensitivity.md), [calibration](/docs/research/air-model-tune.md).

**What broke in the pilot's flight and how it was fixed (1.0.x):**
- *"Blown away" at the start at 6 m/s.* The wing physics check showed that the polar is not the cause (by its characteristics any soft wing flies against 6 m/s). The cause was that the menu wind set the inflow at the edge of the 38 km domain, not U10 over the start: the field gave 1.0–2.1 × the menu (at 6 m/s — 6.2–12.6 m/s at 10 m). Fix — two passes of the field: at all ten starts the ratio of U10 over the start to the menu is 0.90–1.06 (30 of 30 within ±10 %). Applied in 1.0.1 and 1.0.2 and still in place.
- *Turbulence at the start.* The jump was found by bisecting commits: at 6 m/s and 1.5 m above the ground σ<sub>w</sub> 0.04 m/s (before the 100/50 m windows), then 0.73, in 1.0.0 — 1.05; direction scatter ±86°. The cause lies entirely in the air model, not in control; after fixing the surface layer at Kayanche ±21°.
- *Loading.* In 1.0.x the "Computing wind" stage took 7–8 s, but 25–60 s at wind of 1–2 m/s, at 3 m/s from the south or west, and in calm at 9:00: the solver hit the limit of 3000 iterations ([research](/docs/research/air_field_cache.md)). This became one of the arguments for the phase assembly (item 8).

### 5. Simplified mode "as in 0.8.0"

**What happened.** A pilot reported that the game sometimes crashes and that rolling back to 0.8.0 saves the day: "in 0.8.0 the physics is not as plausible, but tolerable for the sake of flying" ([diary Oct 3](https://github.com/thegriglat/deltaplan/blob/main/diary/2026-10-03.en.md)).

**What was done.** In [1.0.3](/releases/1.0.3/) — a settings item "Wind over terrain": calculation from terrain or a simplified mode (the GPU solver is not started, the "Computing wind" stage is skipped). Slope, lee zones, thermals and turbulence in it are the same; what changed is the wind profile with height — in 1.x it depended on the hour and cloudiness. In [1.0.4](/releases/1.0.4/) the profile in the simplified mode is as in 0.8.0: power law, α = 0.14, no more than ×1.8 of the wind at 10 m. Automatic switch-off after a crash was not implemented (the author's decision): the settings item is enough.

**What is in the game now.** The item is called "Heuristic (wind profile without terrain)"; details — on the [«Heuristic» mode](/mechanics/air-model/heuristic/) page. In it terrain neither turns nor speeds up the wind.

### 6. Neural network instead of the solver: pilots P1, P2, P3

**Why.** The solver takes 7–8 s at loading, and 25–60 s at weak wind. A precomputed cache does not help: there are 57 564 launch variants in the menu per start (4 hours × 13 speeds × 9 directions × 41 temperatures × 3 skies), about 2160 after coarsening, which is 17–29 GB for ten built-in starts and 4.5–6.5 h of computation per start, and any change to the model invalidates the whole cache ([research](/docs/research/air_field_cache.md)). On 02.10.2026 a direction was chosen: the solver stays offline as a data source, the field in the game comes from a network on the CPU. Speed and stability matter more than accuracy: a 10–15 % wind error at a point is acceptable — a pilot will take it for a gust. The main question is **replaceability**: does the network reproduce the solver within the solver's own uncertainty (by Askervein the solver itself is off by ±10–20 %).

**Pilot P1 (Oct 2).** 1890 solver cases "as in the game" (4 built-in places, 5 synthetic shapes, 40 procedural terrains, ≈ 7.5 h of GPU), a U-Net conditioned on weather numbers (FiLM), 3.2 M parameters, a CPU pass of 19 ms. At 60 m above terrain the median wind error is 0.47 m/s on familiar terrain, 0.63 on held-out procedural terrain, 0.87 at Ongudai (outside training; the inflow profile gives 1.12). The target (90 % of points) was not met. Reasons: on validation the error plateaus while on training it keeps falling; at Ongudai in strong wind the network overestimates speed, because the typical slope there is 0.22, at Altai 0.12, for procedural terrains 0.016 — the network extrapolated. The error falls with the number of terrains (Ongudai 1.16 → 0.82 m/s at 5 → 40 terrains), so **300 real terrains** were taken next.

**Pilot P2 (Oct 3).** 360 places (300 in training and four held-out mountain systems — the Appalachians, the Caucasus, the Pyrenees, the Southern Alps of New Zealand), 4320 cases in ≈ 8 h on one GPU; about 20 % of solutions did not converge, almost all at weak wind. The wind criterion is relative: error within max(0.3 m/s; 10 % of the solver speed). Result on the held-out systems (60 m, converged):

| | P2 network | inflow profile |
|---|---|---|
| wind error, median / p90 | 0.62 / 1.84 m/s | 2.46 / 7.86 m/s |
| "ok" by wind | 35 % | 10 % |
| lift < 0.1 m/s (without / with heating) | 78 % / 72 % | 70 % / 62 % |
| speed bias at 60 m | +0.008 m/s | +2.32 m/s |

There is no bias; on the non-converged ones the network errs at the level of the solver's own scatter. The curve by number of places (25 → 300: 0.83 → 0.62 m/s, about −7 % per doubling) has no plateau. But even on the training places "ok" is only 49 %. The network is 13 MB, 21 ms.

**Pilot P3 (Oct 3–4): physical encoding.** Hypothesis: the network learns too much from scratch — give it a physical basis (linear flow theory, speed-up and turning instead of u and v, slopes by scale, subgrid terrain, separation mask) or capacity. Nine experiments on 100 places (584 held-out cases, 60 m); wind — median / p90, m/s:

| Experiment | What | Wind | "ok" |
|---|---|---|---|
| P3E0 | control (P2 encoding, 100 places, 3.2 M) | 0.683 / 1.97 | 32 % |
| P3E1 | channels ×2 (12.3 M, 48 ms) | 0.665 / 1.95 | 33 % |
| P3E2 | new input | 0.706 | |
| P3E3 | new output (a loss bug is likely: bias +0.37) | 0.864 | |
| P3E4 | new input and output | stopped (the author's decision) | |
| P3E6 | background stratification in FiLM | 0.689 / 1.99 | 31 % |
| P3E7 | U-FNO (spectral layers) | 0.732 / 2.09 | 29 % |
| P3E8 | training only on confidently converged cases | 0.692 / 1.95 | 31 % |

**P3 outcome:** neither encoding, nor architecture, nor stratification, nor cleaning the targets gave more than a few percent (width ×2 — −2.6 %; U-FNO worse by 7 %); on the training places the error of all variants is ≈ 0.36 m/s — the network does not fit even clean training cases. The best is the P2 network on 300 places: data matter more than tweaks. Replaceability was not achieved by any variant.

**What was in the game and what is now.** The P2 network (on the CPU) appeared in 1.0.5 (Oct 4) as an experimental settings item; the first flight on it at Askarovo: "on the whole even 'flyable', nothing really unusual" ([diary Oct 3](https://github.com/thegriglat/deltaplan/blob/main/diary/2026-10-03.en.md)). In 1.2.0 (Oct 5) a new network trained on 305 starts from the OpenStreetMap catalogue arrived: median error at 60 m on held-out places 0.69 m/s against 0.92 for the previous one, on game places 0.59 against 0.76; it worked up to 12 m/s and became the default. In 1.3.0 (Oct 7) the network was **removed** together with ONNX Runtime: it is neither in the game nor in the builds, and the research stays offline in `tools/research/`. The reasons are in item 8: every flow regime has its own clear mechanism while the network was a black box, in calm and convection the training reference is noisy, and in the wave band the target is ambiguous. The question "why the network does not fit even the training cases" stays open.

### 7. WindNinja

**What was done.** Our solver without heating was compared with WindNinja (3.13 and 4.0.0, license — public domain / BSD-2) on 21 cases in 6 places (Askarovo, Ongudai and four mountain systems), 60 m, U10 4–8 m/s ([report](/tools/research/windninja/README.md)).

| Metric | WindNinja | solver |
|---|---|---|
| speed-up on ridges, of inflow | 1.19 | 1.13 |
| direction: median angle between vectors | 10° (Pyrenees, Southern Alps NZ — 21–27°) | |
| domain mean to inflow | 1.00 | 0.61 |
| valleys / lee slopes, of inflow | 0.84 / 0.97 | 0.30 / 0.34 |
| time | 0.9 s (400 m), 15 s (100 m), 75 s (50 m), 10 CPU threads | median 2.4 s on GPU (for the non-converged — tens of seconds) |

**Conclusion.** The speed-up on ridges and the turning of the flow agree. WindNinja gives no slowing by a mountain massif at all — it has no momentum and pressure; so it neither confirms nor refutes the solver. It does not work as a solver replacement in the game: in valleys the speed is 3–5 m/s higher and the wind is "too even"; forest instead of grass shifts its field by 2 m/s. It works as an independent check of speed-up and turning. It is not in the game.

### 8. Field assembled by flow phases (1.3.0)

**Why.** One steady computation (Picard) is one equation and one closure for the whole field. It is good where the flow has a single stationary solution (flow over a hill, separation behind a ridge) and bad where it has none. On a set of 7320 runs Picard did not converge in about a tenth of the cases, and the main cause is weak wind: at surface wind below 2.5 m/s from a fifth to three quarters of the cases did not converge, from 3 m/s a few percent. The non-converged ones at small Froude numbers wander by tens of percent of the speed — it looks like the absence of a stationary solution rather than a computation error.

**What was done.** A classifier on the GPU determines the regime of each cell (flow over, separation, waves, blocking and bypass, convection, evening drainage, calm) from the Froude number, the convection parameter, the slope steepness and the ratio of terrain height to the mixing layer. Blocking, convection, drainage and calm are computed by their own mechanisms, the rest by Picard, which starts from this assembly; the seams are removed by a projection step. The regime boundaries were measured on idealised terrain (about 8000 runs: hill, ridge, escarpment) and checked on terrain with erosion: lift at a slope and mean speed transfer well, rotor, stagnation and reverse flow worse, and the transition between regimes is 5–10 times wider. Details — [«Wind field: phases and Picard»](/mechanics/air-model/wind-phases/), the research on the [phase diagram](/docs/research/air_phase.md) and on the [measurements](/docs/research/air_phase_results.md).

**What came out.** The "Computing wind" stage on an RTX 4070 SUPER (Ongudai, 12:00, 3 m/s) takes 3.3–3.9 s; on weak graphics cards the estimate is ×2…×11, one computation is limited to 60 s: at loading the formulas of the "Heuristic" mode apply after that, in flight the previous field stays. If Picard did not converge, in calm and blocking cells the mechanism's field is taken, elsewhere the mean of the late iterations.

**Known discrepancies (not fixed, the author's decision):** in strong wind behind a ridge the shear layer gives turbulence 3–4 times higher than in the literature; the separation bubble behind three-dimensional bumps is overestimated by about 1.8 times; the speed-up at the brow is underestimated by 15–20 %; saddle ×2.05 instead of ×1.5; calm and evening drainage are the weakest spots, the nocturnal low-level jet is not reproduced. Details — "Model limits" on the pages of the [air model](/mechanics/air-model/) and of [turbulence](/mechanics/air-model/turbulence/).

## Thermals and weather

| Approach | Result and choice |
|---|---|
| Rising ring (Scorer) versus column | Both regimes occur in real life. A column with a life cycle was chosen, whose bottom detaches at decay: the same feel of a "bubble that went up" without a separate vortex ring |
| Lift profile by radius | Gedeon ("Mexican hat"): core, sink ring, the total mass flux through the plane is zero. Chosen for smoothness: the lift difference between the wing's semi-spans grows smoothly towards the core edge, the wing banks "out of the thermal" rather than abruptly |
| Extreme thermals 7–9 m/s | Rare and only on a strong day, under a large cloud (a pilot's words: "+8 — time to bail out"); a test confirms there are none on a weak and a medium day |
| Dry thermals | A separate share, on a weak day not less than 40 %: the pilot finds them by the variometer |
| Thunderstorms | Before, at +26 °C there was a thunderstorm at the start in almost every flight. By a measurement of 100 days at Ongudai now: +26 — Cb closer than 15 km in the first hour in 0–1 % of flights, +30 — 20–40 %, +34 — 50–70 %; a thunderstorm at the start at the beginning of the flight — 0 / 0–4 / 3–6 %. Outflows from neighbouring cells do not add up (before, up to 30–60 m/s) |
| Weather by presets "weak / medium / strong day" | Replaced by the day's temperature, wind, direction and cloudiness, from which thermals, cloud base and thunderstorms are computed (0.6.0) |
| Thermals from the field (1.0.0) | Location, strength, ceiling and drift are taken from the field. Measurement of 1.0.0, Ongudai, 12:00, wind 3 m/s: on heated slopes 4.9 sources per km², on weakly heated ones 0.7, in shade 0; strength 2.7–3.2 m/s by day, 1.1–1.5 m/s at 9:00 (core radius 25–60 m); ceiling by the inversion, not by the cloud base |
| Heating by land cover (1.5.0) | Forest, meadow, arable land, scrub, rock, buildings and snow heat differently (albedo, moisture, heat flux into the soil); lakes do not heat by day. At noon the mean heating is 10–16 % lower than before, the scatter is larger: southern rocky slopes are stronger, northern and damp hollows weaker. The numbers of the row above predate this change |
| Flight date in the field (1.5.12) | The field used to be always computed for July 15; now for the chosen date: after sunset land no longer heats, cloudiness weakens heating once rather than twice |
| Double counting of heat | The field's vertical component is split into mechanical (goes to the pilot directly) and convective (only through bubbles); strength by Deardorff, $w_*$ of thermals and turbulence agree: ratio 1.001 ± 0.038 |
| A separate neural network for thermals | Not needed: thermals are computed by formulas from the literature on top of the field |

What the model does not reproduce: "strong thermals at 1–1.5 layer thicknesses" (the density of all cores N·z<sub>i</sub>/L = 1.4–1.5 against 1.2 ± 0.4 in the literature agrees, the spacing of strong ones does not); "streets" along the wind; the strength scatter between neighbouring thermals is wider than in the model. Sources — [«Thermals»](/mechanics/air-model/thermals/), [research](/docs/research/thermals.md), [CHANGELOG](/releases/).

## Wings: passports and models

The game has 48 wings in four groups (Soviet, trainer, kingpost, topless); each has its own polar, mass and 3D model. Wing pages — [«Wing models»](/wings/).

| Approach | Result and choice |
|---|---|
| A line of nine models in four classes (0.6.0) | The first line: each has its own polar, mass and 3D model. Classes — by quality and by the wind in which it is comfortable to launch. It grew to 48 models |
| "Skin on a skeleton" sail | Fabric sag between battens (1.5 %, then 0.5 %); consultant pilot: "tight as a drum", the difference from a smooth one is unnoticeable. **Prototype removed** |
| Collecting DHV and manufacturer passports | A summary set [by models and sizes](/tools/research/data/wing_passports/README.md): area for 186 entries, take-off weight for 151, Vne for 151, span for 145. Rules: a number changes only if there is a passport of the same model and size (or an explicitly marked analogue); we do not trust absolute L/D from claims; in case of discrepancy DHV has priority |
| Polars by similarity to the class base or by passport | DHV Vmin is above the polar stall by 5–30 % for all 22 new wings with data (for the bases −10 / −21 / −11 %) — a systematic offset; CL_max by passports 1.13 (Condor Crex 3) … 2.91 (Bautek Kite). In 1.0.2 for 38 wings the stall, trim, maximum speed and minimum sink are brought to the passport at the reference mass (within 7–10 %); the stall of many is at 26–38 km/h instead of 22–28 |
| 39 new models by similarity to the class base | ≈ 0.5–0.7 MB each; sail shape, twist, profile and kingpost height — from the base, because the passports do not contain these numbers; full correctness — by pilots' feedback. In 1.5.13 the textures are stored compressed, the game data went 212 → 86 MB |
| "Blown away" — are the polars to blame | No: by characteristics any soft wing flies against 6 m/s (for example, "Atlas": CL_max 1.46, stall at 12.6°); the cause was the overestimated wind in the field (see item 4 above) |
| Size of the "Apogee" | 16 m² replaced by 14.4 m² (a copy of the Airwave Magic 155, per a pilot): at the same mass the wing flies 5 % faster |

Sources — [passports → configs](/docs/research/wings_config_sources.md), the [«Wing models»](/wings/) section.

## Takeoff and ground control

| Approach | Result and choice |
|---|---|
| Fixed takeoff times and a "weak run" | Rejected (the author's decision, Oct 1): liftoff is physics only, lift not less than weight from airspeed (running plus wind); in calm you can run as long as needed; bot and autopilot timers replaced by physics |
| Running speed limit | After the fix the run in calm on the sport wing — 67 → 13 m (2.5 s), training — 29 → 11 m, "Atlas" — 64 → 18 m; with a headwind of 3–6 m/s the run is 1.2–1.8 s and did not change |
| Pilot's hand on the ground | Roll moment is limited to $M_{max}\cdot(N/W)$, where $N/W$ is the share of weight on the legs; crosswind while standing: threshold 1.90 m/s at a 4 m/s headwind, at a 6 m/s headwind — 0.6–1.0 m/s — physics, not a defect. Leg mobility, a sidestep and body posture are not modelled (a model boundary) |
| Wing clearance above terrain | At all starts at zero roll the smallest clearance over the rendered mesh is 0.58 m — we do not touch the terrain |
| Cleared area at the start | Radius ≥ 2 × run length, only trees are removed, bushes stay (the run direction in a crosswind is not known in advance) |
| Mouse and keyboard control | The mouse is always the wing (the "Look / Control frame" mode was removed); W/S/A/D on the ground — walking and turning of the pilot, in flight — the head; Shift is held for the run. The "Roll by mouse and arrows" setting (1.4.0): "body" or "control frame" (as with hands on the bar) |

Details — [«Flight and controls»](/mechanics/flight/).

## Multiplayer

| Approach | Result and choice |
|---|---|
| gRPC | Rejected: Godot has it neither in the engine nor as a live addon; a GDExtension with C++ gRPC is a heavy build for each platform |
| WebSocket + protobuf in JSON | Chosen: the built-in `WebSocketPeer` without addons, readable by eye when debugging; the contract — `server/proto/deltaplan/v1/net.proto` — is the single source of truth |
| Server on a VPS only | Supplemented with a built-in one: "Create" without an address starts a server on this computer, the others find the zone by a UDP announcement on the local network; the Go server is for play over the internet |
| Server via itch.io | itch has no network functionality; the variant without a VPS — a server on the pilot's computer over Tailscale or ZeroTier. Not built ([research](/docs/research/itch_multiplayer.md)) |
| Steam lobbies | In the Steam builds (1.2.0): "friends only" lobbies, invitation through the overlay. The itch build has no Steam |
| Transferring the world over the network | Not needed: the atmosphere is deterministic by place, date, time, weather and seed — each client computes it itself; only zone parameters, the clock and states go over the network. Because of different graphics cards the clients' fields differ slightly; the thermal positions are common to all |

Details — [«Multiplayer»](/mechanics/multiplayer/).

## World data

**What was tried.** A region pack in our own format instead of downloading over the network. Measurement on Slovenia: pack ≈ 80 MB (OSM vector 63 MB, 30 m terrain — 14 MB, 25 m land cover — 2.4 MB; 81 % of the vector is land use); for the Alps on the order of 150–300 MB per country; Russia as a single pack — about 14 GB (estimate), almost all terrain and land cover. **OsmAnd OBF rejected**: the terms of use forbid automatic downloading, caching and redistribution of their files; the format is non-standard with no live libraries; there is no terrain of the needed quality; everything useful is OSM data, which is simpler and legal to take from `.osm.pbf` ([OBF experiment](/tools/research/obf_region/README.md)).

**What came out.** The Overpass service, from which the game took OSM, became unavailable. In 1.5.1 the game learned to work without OSM: terrain, the satellite land-cover map, and villages, lakes and rivers derived from them. In 1.5.2 (Oct 11) OpenStreetMap objects returned through **our own 20 km tiles for the whole world** (houses, roads, rivers, railways, power lines, masts, chimneys, wind turbines, cable cars, airfields, peaks and passes), built from Geofabrik extracts and served as static files (Cloudflare R2). The size of the whole planet is estimated at 7.2–7.4 GB against a 10 GB budget. The tiles are downloaded when a place is built, together with terrain and land cover, and cached.

**What is in the game now.** Any point on the map gets the same layers as a built-in place: 25 m Copernicus terrain and a 100 m background, ESA WorldCover land cover, forest and water at 10 m, OSM objects from the tiles. The built-in places (Altai, Ongudai, Askarovo, Aushkul) are built by the same code on first selection rather than shipped in the game; a built place is kept in the local cache. Details — [OSM tiles](/docs/guide/osm-tiles.md) and [location data](/docs/guide/location-data.md).

## Where to look for more

- Numbers and sources for closed work — the [findings registry](/research/findings/).
- Research and prototypes by topic — [«Research»](/research/).
- How all this works in the game — [«Mechanics»](/mechanics/): [air model](/mechanics/air-model/), [the "Heuristic" mode](/mechanics/air-model/heuristic/), [thermals](/mechanics/air-model/thermals/), [flight and wing](/mechanics/flight/).
- Chronology of decisions and pilots' feedback — the [diary](https://github.com/thegriglat/deltaplan/tree/main/diary).
