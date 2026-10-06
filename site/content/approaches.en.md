---
title: "Approaches and results"
weight: 25
description: "Which ways of computing wind over terrain, thermals, wings and takeoff were tried in Deltaplan, what came out in numbers, what was chosen and why."
---

# Approaches and results

The game is built on physics, and physics can be computed in different ways. This page is a map of what we tried on the key topics, with the numbers, the choice and the reason for it. The first and longest topic is wind over terrain: in a week it went from formulas through a GPU solver to a neural network.

How to read it: for each approach — what was done, what came out, what was decided and why, with a link to the source. All numbers are taken from the repository documents — the [findings registry](/research/findings/), the plans in the [«Plans»](/plans/) section, [research](/research/), the [CHANGELOG](/releases/) and the [diary](/diary/); where a number is an estimate rather than a measurement, it says so. The selection criterion is the same everywhere (the author's decision): first physics within the model's limits, then accuracy, then cost. "The pilot likes it" is a reference, not a requirement: tuning coefficients "so that it feels right" is a dead end, so tuning follows a scheme with measurements and uncertainties.

## Wind over terrain

Summary of the approaches in order:

| # | Approach | When | Outcome |
|---|---|---|---|
| 1 | Formulas: wind profile, slope lift, the "shadow line" behind a ridge | from the first build; version 0.8.0 | works, but "not physical"; remained as a fallback and as the Simplified mode |
| 2 | Mass-consistent wind field (Poisson equation) | plan of Sep 29 | not taken into work, replaced: no heat and no air inertia |
| 3 | Coupled "heating → buoyancy → flow" system: 2D prototype and six experiments | Sep 29 | the idea is physically right; the Picard method was chosen |
| 4 | Picard solver on the GPU, three scales | build 1.0.0, Oct 1 | in the game, "Calculated from terrain" mode; known discrepancies |
| 5 | Simplified mode "as in 0.8.0" | 1.0.3 and 1.0.4, Oct 3 | the pilot's choice for failures and for an easy start |
| 6 | Neural network instead of the solver: pilots P1, P2, P3 | Oct 2–4 | the P2 network is in the game, "experimental"; replacing the solver failed |
| 7 | WindNinja as an independent reference | Oct 4 | not a solver replacement; confirms the speed-up on ridges |

### 1. Formulas (version 0.8.0)

**What it is.** The pilot gets all air through one function, `Atmosphere.air_velocity_at`. Horizontal wind grows with height by a power law and with altitude above sea level, with a single direction for the whole world:

$$ u = u_{ref} \cdot \left(\frac{agl}{10\,\text{m}}\right)^{0.14} \cdot \left(1 + 0.6 \cdot \frac{msl - msl_{start}}{1000\,\text{m}}\right) $$

Slope lift is $w_{ridge} = \mathrm{clamp}(0.85 \cdot u \cdot (\hat w \cdot \nabla h) \cdot e^{-agl_s / 250}, \pm 6\ \text{m/s})$ with the slope point shifted upwind by $0.8\,agl$ (no more than 400 m). The lee zone is the "shadow line": below a line sloping at 12° from the ridge the air is in a rotor (sink $0.25\ldots0.7\,u$, turbulence $0.5\ldots0.9\,u$, downward gusts, reverse flow). Details — [«Slope wind»](/mechanics/air-model/slope-wind/).

**What came out.** The consultant pilot said the flow around terrain is "not physical". The analysis ([research](/docs/research/slope_wind.md)) found three discrepancies with real life: no wind speed-up at the brow, the lift band is a fixed 250 m, and the "pipe" in a saddle works the wrong way round. The pilot's reference points: speed-up up to about two mountain heights from the foot, laminar at 2.5 heights, the steeper the slope the stronger, saddle ×1.5 along the axis even with an oblique wind of 15° ([diary Sep 29](/diary/2026-09-29/)).

When the solver was put next to it, defects in the formulas themselves turned up as well: at 9 m/s the heuristics' "downward gusts" gave −13…−18 m/s (in the formula they are proportional to the highest wind above the ridge), and the heuristics' reverse flow duplicated the solver's flow — the minimum along-wind speed at the start was −4.66 m/s instead of −0.52 m/s (a double rotor). Literature check: the maximum reverse flow behind ridges is 0.22 ± 0.08 of the wind at ridge level (Menke et al. 2019); the field gives ≈ 0.2, with the heuristics ≈ 0.4. Decision (AM-08v): the heuristics weight is 1 − smoothstep(2, 4, excess/dx), i.e. it fades out where the solver itself resolves separation; gusts are 0.42·ΔU (3σ<sub>w</sub>). Source — the [air model log](/docs/archive/plan/air-model-progress.md), section "Gate review" («Разбор на шлюзе»).

**What was chosen.** The formulas were replaced by a physical field but stay as a fallback (if the field was not computed, and outside the field's area) and as the basis of the Simplified mode (see item 5).

### 2. Mass-consistent field

**What was tried (on paper).** Wind as a solution of the Poisson equation on the GPU: terrain deflects the flow, mass is conserved; linearity in wind (two base fields per stability level); nested grids around the pilot ("clipmaps") from 50 to 800 m. Plan — [wind_field](/docs/archive/plan/wind-field.md), estimate ≈ 31 days of agent work.

**What came out.** The plan was not taken into work. It solved only the flow around terrain and gave neither heat nor air inertia: without heating of the ground there is no inflow to a heated slope, no column over the ridge and no thermal ceiling at the inversion. The same was shown later by the WindNinja check (item 7): a mass-consistent diagnostic model conserves mass but does not lose speed on flow around terrain.

**What was chosen.** Replaced by the [three-scale air model](/docs/plan/air_model.md) plan; the sections on the grid, clipmaps and GPU were reused. Compute platform: **CUDA rejected** (AMD cards are expected among the pilots), **Rust + rayon / GDExtension** considered and rejected (offline CPU computation is too slow for recomputing the field in the game), portable Vulkan compute (RenderingDevice in Godot) chosen.

### 3. Coupled system and the 2D prototype

**The author's idea.** A cellular automaton: a hot cell gives heat sideways and upwards and sucks in mass from cold ones; then — "layer→layer transition by multiplying by a transfer matrix", "a kernel as in image processing". Physical basis — the Boussinesq approximation: mass, momentum with buoyancy and non-local pressure, energy.

**Prototype on a 2D ridge section** (500 m ridge, slopes up to 33° and 16°, heating up to 250 W/m², [results](/research/heat_ca/)). Over the heated slope — lift 1.65 m/s (both slopes — 2.47 m/s over the ridge), inflow to the foot ≈ 0.5 m/s, sink over the valley −0.08…−0.2 m/s; an inversion at 1500–1800 m stops the column at 1550 m (without it, 1800). Conservation: mass residual ~10⁻¹¹ of the domain mass. Cell convergence: at 200 m there is no slope wind, 100 m is the coarsest grid with the right picture, at 50 m the lift has an error of about 15 %, finer than 25 m makes no sense.

**Six experiments: how to get a steady field quickly without thousands of time steps** ([summary](/research/heat_ca/out/summary/), [diary Sep 29](/diary/2026-09-29/)):

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

**What broke in the pilot's flight and how it was fixed:**
- *"Blown away" at the start at 6 m/s.* The wing physics check showed that the polar is not the cause (by its characteristics any soft wing flies against 6 m/s). The cause was that the menu wind set the inflow at the edge of the 38 km domain, not U10 over the start: the field gave 1.0–2.1 × the menu (at 6 m/s — 6.2–12.6 m/s at 10 m). Fix — two passes of the field: at all ten starts the ratio of U10 over the start to the menu is 0.90–1.06 (30 of 30 within ±10 %), loading 8.0–14.8 s (Altai at 3 m/s — 26.7–38.5 s). Applied in 1.0.1 and 1.0.2. Source — [air-start](/docs/archive/plan/air-start-progress.md), [physics check](/docs/archive/plan/wing-physics-check-progress.md).
- *Turbulence at the start.* The jump was found by bisecting commits: at 6 m/s and 1.5 m above the ground σ<sub>w</sub> 0.04 m/s (before the 100/50 m windows), then 0.73, in 1.0.0 — 1.05; direction scatter ±86°. The cause lies entirely in the air model, not in control; after fixing the surface layer at Kayanche ±21°.
- *Loading.* The "Computing wind from terrain…" stage takes 7–8 s almost everywhere, but 25–60 s at wind of 1–2 m/s, at 3 m/s from the south or west, and in calm at 9:00: the solver hits the limit of 3000 iterations, at 60 s there is a timeout and the game is left without a field ([research](/docs/research/air_field_cache.md)).

**Known discrepancies (not fixed, the author's decision):** the shear layer above the wake gives turbulence 3–4 times stronger than in the literature (0.4–0.6 against 0.13–0.15 of the speed jump); the separation bubble behind three-dimensional bumps is overestimated by about 1.8 times. Module closure: GPU tests `test_air_` 60/60, contract tests 28, atmosphere 128.

### 5. Simplified mode "as in 0.8.0"

**What happened.** A pilot reported that the game sometimes crashes and that rolling back to 0.8.0 saves the day: "in 0.8.0 the physics is not as plausible, but tolerable for the sake of flying"; then — "Don't torment 1.0. It got worse. Right now 0.8 is the best of all, practically perfect" ([diary Oct 3](/diary/2026-10-03/)).

**What was done.** In [1.0.3](/releases/1.0.3/) — a settings item "Wind over terrain": "Calculated from terrain" or "Simplified (lighter and safer)" (the GPU solver is not started, the "Computing wind from terrain…" stage is skipped). Analysis of differences from 0.8.0: slope, lee zones, thermals and turbulence in the simplified mode are the same; what changed is the wind profile with height — in 1.x it depended on the hour and cloudiness. In [1.0.4](/releases/1.0.4/) the profile in the simplified mode is as in 0.8.0: power law, α = 0.14, no more than ×1.8 of the wind at 10 m.

**Why this way.** Automatic switch-off after a crash was not implemented (the author's decision): the settings item is enough. Rolling back the version is not needed — you can switch to the simplified mode.

### 6. Neural network instead of the solver: pilots P1, P2, P3

**Why.** The solver takes 7–8 s at loading, and 25–60 s at weak wind. A precomputed cache does not help: there are 57 564 launch variants in the menu per start (4 hours × 13 speeds × 9 directions × 41 temperatures × 3 skies), about 2160 after coarsening, which is 17–29 GB for ten built-in starts and 4.5–6.5 h of computation per start, and any change to the model invalidates the whole cache ([research](/docs/research/air_field_cache.md)). On 02.10.2026 a direction was chosen: no solver in the game, the field is given by a network (ONNX, CPU), the solver stays offline as a data source — the "physics" of the field, with the network as its compression. Speed and stability matter more than accuracy: a 10–15 % wind error at a point is acceptable — a pilot will take it for a gust. The main question is **replaceability**: does the network reproduce the solver within the solver's own uncertainty (by Askervein the solver itself is off by ±10–20 %). Plan — [air_nn](/docs/plan/air_nn.md).

**Pilot P1 (Oct 2).** Dataset: 1890 solver cases "as in the game" — 4 built-in places, 5 synthetic shapes, 40 procedural terrains (≈ 7.5 h of GPU; 238 cases hit the iteration limit). Network: U-Net conditioned on weather numbers (FiLM), 3.2 M parameters, a CPU pass of 19 ms (4 threads). Result at 60 m above terrain:

| set | wind, median (inflow profile) | wind within 0.3 m/s | lift within 0.1 m/s |
|---|---|---|---|
| familiar terrain, new conditions | 0.47 (1.21) m/s | 29 % | 92 % |
| held-out procedural | 0.63 (1.75) m/s | 21 % | 83 % |
| Ongudai (outside training) | 0.87 (1.12) m/s | 12 % | 61 % |

The target (90 % of points) was not met — "fix the approach and repeat". Reasons: on validation the error plateaus by about the 30th epoch while on training it keeps falling (1188 cases on 44 terrains); at Ongudai in strong wind the network overestimates speed over almost the whole domain (in one case +1.7 m/s, +14 %), because the typical 400 m slope is 0.22 at Ongudai, 0.12 at Altai, 0.016 for procedural terrains — the network extrapolated. The wind error falls with the number of terrains (Ongudai 1.16 → 0.82 m/s at 5 → 40 terrains). Rejected along the way: bringing all inputs to [0, 1] (per-case normalization erases scale); validating on smooth procedural terrains (in the game the input is always real terrain) — **300 real terrains** were chosen.

**Pilot P2 (Oct 3).** 360 places (a pool of 300 and four held-out mountain systems — the Appalachians, the Caucasus, the Pyrenees, the Southern Alps of New Zealand — 15 each), 4320 cases in ≈ 8 h on one GPU; about 20 % of solutions did not converge, almost all at weak wind (the target for them is the mean of the late states). The wind criterion was made relative: error within max(0.3 m/s; 10 % of the solver speed). Result on the held-out systems (60 m, converged):

| | P2 network | inflow profile |
|---|---|---|
| wind error, median / p90 | 0.62 / 1.84 m/s | 2.46 / 7.86 m/s |
| "ok" by wind | 35 % | 10 % |
| lift < 0.1 m/s (without / with heating) | 78 % / 72 % | 70 % / 62 % |
| speed bias at 60 m | +0.008 m/s | +2.32 m/s |

There is no bias (the overestimate at Ongudai is gone); on the non-converged ones the network errs at the level of the solver's own scatter (median ratio 0.91). The curve by number of places: 25 → 300 — 0.83 → 0.62 m/s, about −7 % per doubling, no plateau. But even on the training places "ok" is only 49 %. The network is 13 MB, 21 ms. The verdict by the rule from the numbers — "fix the approach".

**Pilot P3 (Oct 3–4): physical encoding.** Hypothesis: the network learns too much from scratch; give it a physical basis (linear flow theory, speed-up and turning instead of u and v, slopes by scale, subgrid terrain, separation mask) or capacity. Experiments on 100 places, held-out mountain systems, 60 m, converged (584 cases); wind — median / p90, m/s:

| Experiment | What | Wind | "ok" |
|---|---|---|---|
| P3E0 | control (P2 encoding, 100 places, 3.2 M) | 0.683 / 1.97 | 32 % |
| P3E1 | channels ×2 (12.3 M, 48 ms) | 0.665 / 1.95 | 33 % |
| P3E2 | new input | 0.706 | |
| P3E3 | new output (a loss bug is likely: bias +0.37) | 0.864 | |
| P3E4 | new input and output | stopped at epoch ~90 (the author's decision) | |
| P3E5 | best variant on 300 places | not run ("the situation is clear") | |
| P3E6 | background stratification in FiLM | 0.689 / 1.99 | 31 % |
| P3E7 | U-FNO (spectral layers) | 0.732 / 2.09 | 29 % |
| P3E8 | training only on confidently converged cases | 0.692 / 1.95 | 31 % |

**P3 outcome:** neither encoding, nor architecture, nor stratification, nor cleaning the targets gave more than a few percent (width ×2 — −2.6 %; U-FNO worse by 7 %); the median ratio of network error to solver uncertainty ≈ 1.2 at a threshold of 0.5; on the training places the error of all variants is ≈ 0.36 m/s (ρ ≈ 0.5) — the network does not fit even clean training cases. The stratification background in the dataset is almost a single one (one month), mass variability — only in the morning. **The best is the P2 network on 300 places (0.62 / 1.84 m/s): data matter more than tweaks.** Replaceability was not achieved by any variant. Source — the [P3 plan](/docs/archive/plan/air-nn-p3.md), section "0. P3 outcome" («0. Итог P3»).

**What was chosen.** The game has the P2 network, the item "Neural network (experimental)": it computes on the CPU, no GPU needed; if there is no network or extension — the simplified model and a line in the log. The "Computing wind from terrain…" stage on the network takes about 4 s, of which the network itself is 56 ms, the rest is assembling the field in GDScript. The first flight on the network at Askarovo: "on the whole even 'flyable', nothing really unusual" ([diary Oct 3](/diary/2026-10-03/), [air-onnx plan](/docs/archive/plan/air-onnx.md)). The solver remains the default mode; the deep question "why the network does not fit even the training cases" is the author's background research.

**Ideas "in mind" (not tested, except where noted):** a triple feature plane with a vertical cut along the wind; stream function or potential (mass conservation by construction); dimensionless numbers (Froude, Richardson) in FiLM; a second basis — shallow-water hydraulics for saddles and weak wind; a cascade of 50 and 25 m windows around the pilot; a batch of cases in the solver; a saddle feature (curvature of varying sign); iterative "freezing" of the field by the network in 2–4 steps; a diffusion model of the live variability of weak wind; FNO instead of U-Net — tested as P3E7, worse.

### 7. WindNinja

**What was done.** Our solver without heating was compared with WindNinja (3.13 and 4.0.0, license — public domain / BSD-2) on 21 cases in 6 places (Askarovo, Ongudai and four mountain systems), 60 m, U10 4–8 m/s ([report](/tools/research/windninja/README.md)).

| Metric | WindNinja | solver |
|---|---|---|
| speed-up on ridges, of inflow | 1.19 | 1.13 |
| direction: median angle between vectors | 10° (Pyrenees, Southern Alps NZ — 21–27°) | |
| domain mean to inflow | 1.00 | 0.61 |
| valleys / lee slopes, of inflow | 0.84 / 0.97 | 0.30 / 0.34 |
| time | 0.9 s (400 m), 15 s (100 m), 75 s (50 m), 10 CPU threads | median 2.4 s on GPU (for the non-converged — tens of seconds) |

**Conclusion.** The speed-up on ridges and the turning of the flow agree. WindNinja gives no slowing by a mountain massif at all — it has no momentum and pressure; so it neither confirms nor refutes the solver. It does not work as a solver replacement in the game: in valleys the speed is 3–5 m/s higher and the wind is "too even"; forest instead of grass shifts its field by 2 m/s. It works as an independent check of speed-up and turning and as a cheap underlay where the solver did not converge.

## Thermals and weather

| Approach | Result and choice |
|---|---|
| Rising ring (Scorer) versus column | Both regimes occur in real life. A column with a life cycle was chosen, whose bottom detaches at decay: the same feel of a "bubble that went up" without a separate vortex ring |
| Lift profile by radius | Gedeon ("Mexican hat"): core, sink ring, the total mass flux through the plane is zero. Chosen for smoothness: the lift difference between the wing's semi-spans grows smoothly towards the core edge, the wing banks "out of the thermal" rather than abruptly |
| Extreme thermals 7–9 m/s | Rare and only on a strong day, under a large cloud (a pilot's words: "+8 — time to bail out"); a test confirms there are none on a weak and a medium day |
| Dry thermals | A separate share, on a weak day not less than 40 %: the pilot finds them by the variometer |
| Thunderstorms | Before, at +26 °C there was a thunderstorm at the start in almost every flight. By a measurement of 100 days at Ongudai now: +26 — Cb closer than 15 km in the first hour in 0–1 % of flights, +30 — 20–40 %, +34 — 50–70 %; a thunderstorm at the start at the beginning of the flight — 0 / 0–4 / 3–6 %. Outflows from neighbouring cells do not add up (before, up to 30–60 m/s) |
| Weather by presets "weak / medium / strong day" | Replaced by the day's temperature, wind, direction and cloudiness, from which thermals, cloud base and thunderstorms are computed (0.6.0) |
| Thermals from the field (1.0.0) | Location, strength, ceiling and drift are taken from the field. Ongudai, 12:00, wind 3 m/s: on heated slopes 4.9 sources per km², on weakly heated ones 0.7, in shade 0; strength 2.7–3.2 m/s by day, 1.1–1.5 m/s at 9:00 (core radius 25–60 m); ceiling by the inversion, not by the cloud base |
| Double counting of heat | The field's vertical component is split into mechanical (goes to the pilot directly) and convective (only through bubbles); strength by Deardorff, $w_*$ of thermals and turbulence agree: ratio 1.001 ± 0.038 |
| A separate neural network for thermals | Not needed: thermals are computed by formulas from the literature on top of the field, the needed quantities are given by the field network |

What the model does not reproduce: "strong thermals at 1–1.5 layer thicknesses" (the density of all cores N·z<sub>i</sub>/L = 1.4–1.5 against 1.2 ± 0.4 in the literature agrees, the spacing of strong ones does not); "streets" along the wind; the strength scatter between neighbouring thermals is wider than in the model. Sources — [«Thermals»](/mechanics/air-model/thermals/), [research](/docs/research/thermals.md), [CHANGELOG](/releases/).

## Wings: passports and models

| Approach | Result and choice |
|---|---|
| A line of nine models in four classes (0.6.0) | Each has its own polar, mass and 3D model. Classes — by quality and by the wind in which it is comfortable to launch |
| "Skin on a skeleton" sail | Fabric sag between battens (1.5 %, then 0.5 %); consultant pilot: "tight as a drum", the difference from a smooth one is unnoticeable. **Prototype removed** |
| Collecting DHV and manufacturer passports | A summary set [by models and sizes](/tools/research/data/wing_passports/README.md): area for 186 entries, take-off weight for 151, Vne for 151, span for 145. Rules: a number changes only if there is a passport of the same model and size (or an explicitly marked analogue); we do not trust absolute L/D from claims; in case of discrepancy DHV has priority |
| Polars by similarity to the class base or by passport | DHV Vmin is above the polar stall by 5–30 % for all 22 new wings with data (for the bases −10 / −21 / −11 %) — a systematic offset; CL_max by passports 1.13 (Condor Crex 3) … 2.91 (Bautek Kite). In 1.0.2 for 38 wings the stall, trim, maximum speed and minimum sink are brought to the passport at the reference mass (within 7–10 %); the stall of many is at 26–38 km/h instead of 22–28 |
| 39 new models by similarity to the class base | ≈ 0.5–0.7 MB each, build +25–35 MB; sail shape, twist, profile and kingpost height — from the base, because the passports do not contain these numbers; full correctness — by players' feedback |
| "Blown away" — are the polars to blame | No: by characteristics any soft wing flies against 6 m/s (for example, "Atlas": CL_max 1.46, stall at 12.6°); the cause was the overestimated wind in the field (see item 4 above) |
| Size of the "Apogee" | 16 m² replaced by 14.4 m² (a copy of the Airwave Magic 155, per a pilot): at the same mass the wing flies 5 % faster |

Sources — [passports → configs](/docs/research/wings_config_sources.md), [wing physics check](/docs/archive/plan/wing-physics-check-progress.md), [3D models](/docs/archive/plan/wings-models3d-progress.md), the [«Aircraft models»](/wings/) section.

## Takeoff and ground control

| Approach | Result and choice |
|---|---|
| Fixed takeoff times and a "weak run" | Rejected (the author's decision, Oct 1): liftoff is physics only, lift not less than weight from airspeed (running plus wind); in calm you can run as long as needed; bot and autopilot timers replaced by physics |
| Running speed limit | After the fix the run in calm on the sport wing — 67 → 13 m (2.5 s), training — 29 → 11 m, "Atlas" — 64 → 18 m; with a headwind of 3–6 m/s the run is 1.2–1.8 s and did not change |
| Pilot's hand on the ground | Roll moment is limited to $M_{max}\cdot(N/W)$, where $N/W$ is the share of weight on the legs; crosswind while standing: threshold 1.90 m/s at a 4 m/s headwind, at a 6 m/s headwind — 0.6–1.0 m/s — physics, not a defect. Leg mobility, a sidestep and body posture are not modelled (a model boundary) |
| Wing clearance above terrain | At all starts at zero roll the smallest clearance over the rendered mesh is 0.58 m — we do not touch the terrain |
| Cleared area at the start | Radius ≥ 2 × run length, only trees are removed, bushes stay (the run direction in a crosswind is not known in advance) |
| Mouse and keyboard control | The mouse is always the wing (the "Look / Control frame" mode was removed); W/S/A/D on the ground — the pilot, in flight — the head |

Sources — [control-fix](/docs/archive/plan/control-fix-progress.md), [start-fixes](/docs/archive/plan/start-fixes-progress.md), [ui-controls](/docs/archive/plan/ui-controls-progress.md).

## Multiplayer

| Approach | Result and choice |
|---|---|
| gRPC | Rejected: Godot has it neither in the engine nor as a live addon; a GDExtension with C++ gRPC is a heavy build for each platform |
| WebSocket + protobuf in JSON | Chosen: the built-in `WebSocketPeer` without addons, readable by eye when debugging; the contract — `server/proto/deltaplan/v1/net.proto` — is the single source of truth |
| Server on a VPS only | Supplemented with a built-in one: "Create" without an address starts a server on this computer, the others find the zone by a UDP announcement on the local network; the Go server is for play over the internet |
| Server via itch.io | itch has no network functionality; the variant without a VPS — a server on the pilot's computer over Tailscale or ZeroTier; the author's decision of Oct 1: postponed |
| Transferring the world over the network | Not needed: the atmosphere is deterministic by place, date, time, weather and seed — each client computes it itself; only zone parameters, the clock and states go over the network |

Sources — [multiplayer plan](/docs/plan/multiplayer.md), [research on itch](/docs/research/itch_multiplayer.md), [«Multiplayer»](/mechanics/multiplayer/).

## Offline world data

The idea is a region pack in our own format instead of downloading over the network. The author's decision of Sep 30: keep the plan, postpone the implementation. Measurement on Slovenia: pack ≈ 80 MB (OSM vector 63 MB, 30 m terrain — 14 MB, 25 m land cover — 2.4 MB; 81 % of the vector is land use); for the Alps on the order of 150–300 MB per country; Russia as a single pack — about 14 GB (estimate), almost all terrain and land cover, to be distributed by federal subject. **OsmAnd OBF rejected**: the terms of use forbid automatic downloading, caching and redistribution of their files; the format is non-standard with no live libraries; there is no terrain of the needed quality; everything useful is OSM data, which is simpler and legal to take from `.osm.pbf`. An alternative idea — a list of flying sites from OSM and downloading the full data for the chosen place. Sources — [plan](/docs/plan/offline_world_data.md), [measurement](/docs/plan/osm_vector_pack.md), [OBF experiment](/tools/research/obf_region/README.md).

## Where to look for more

- Numbers and sources for closed work — the [findings registry](/research/findings/).
- Plans and their statuses — [«Plans»](/plans/); closed ones — the [archive](/plans/archive/).
- Research and prototypes by topic — [«Research»](/research/).
- How all this works in the game — [«Mechanics»](/mechanics/): [air model](/mechanics/air-model/), [slope wind](/mechanics/air-model/slope-wind/), [thermals](/mechanics/air-model/thermals/), [flight and wing](/mechanics/flight/).
- Chronology of decisions and pilots' feedback — the [diary](/diary/).
