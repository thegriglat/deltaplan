---
title: "Wind field: phases and Picard"
weight: 10
description: "Level 1 of the air model: which flow regimes exist over terrain (flow over, separation, waves, blocking, convection, drainage, calm), how each is computed and what the game gets out — mean wind field, phase map, w*, z_i, separation zones."
---

# Wind field: phases and Picard

This is level 1 of the [air model](/mechanics/air-model/): the mean wind field for a game hour. The game gets out of it:

- **the mean wind field** — three velocity components and the temperature deviation on three nested grids (a 400 m area, 100 and 50 m windows around the pilot); from it come slope lift, speed-up at the brow, flow around hills sideways, the saddle, sink behind a ridge;
- **a phase map** — for every cell, which flow regime is the main one there; in the game it can be turned on as a debug layer next to the wind arrows;
- **w<sub>\*</sub> and z<sub>i</sub>** — the convective velocity scale (from the heat flux off the ground) and the mixing-layer height; the thermals of [level 2](/mechanics/air-model/thermals/) and the convective turbulence of [level 3](/mechanics/air-model/turbulence/) stand on them;
- **separation zones** — where the flow detaches behind a ridge; level 3 turns their size and position into rotor and jolts.

There is no neural network here: an early variant with a trained network was replaced by physics, because each flow regime has its own understandable mechanism, while the network was a black box.

## Why phases

One steady computation (the Picard method) is one equation and one closure for the whole field. It works well where the flow has a single steady solution — flow over a hill, separation behind a ridge. And badly where there is none or the game does not need it. The measurements show this: on a corpus of 7320 computations Picard did not converge in about a tenth of cases, and the main cause is neither heating nor one dimensionless parameter but weak wind: with surface wind below 2.5 m/s from a fifth to three quarters of cases did not converge, from 3 m/s only a few percent. At small Fr the non-converged runs wander by tens of percent of the wind speed — physically this looks like the absence of a steady solution, not a computing error.

![Share of non-converged Picard runs against the Froude number](/tools/research/air_phase/out/fig_nonconv_fr_hg.png "Share of non-converged runs (1000 iterations) against Fr = U/(N·h), 7320 cases. Left: without and with heating run together; dotted — a sigmoid with Fr₅₀ = 0.11 and width 1.3 decades. Middle and right: the same data in three groups by w*/U and by slope.")

*Non-convergence depends on Fr smoothly: at Fr ≈ 0.1 about half of the cases do not converge, at Fr > 1 a few percent. Heating and steepness change the curve little — what matters here is weak wind against stability.*

So the field is assembled by phases: a classifier determines the regime in each cell, and the cell gets the mechanism that suits it. The regime is governed by four dimensionless quantities: the Froude number Fr = U/(N·h) (wind against stability and obstacle height), the convection parameter −z<sub>i</sub>/L (heat against mechanical mixing), the slope steepness and the ratio of terrain height to mixing-layer height h/z<sub>i</sub>.

![Schematic phase diagram from the literature](/tools/research/air_phase/out/fig_phase_schematic.png "Phase schematic from the literature in the axes: (a) wind speed and heat flux, (b) Fr and −z_i/L, (c) Fr and lee-slope steepness, (d) inversion")

*This is a schematic from the literature, not a computed result: where boundaries are not measured they are marked as hypotheses. What was measured on ideal terrain is below; the schematic shows how the phases separate along the axes.*

## Phases in plain words

| Phase | What happens | How it is computed |
|---|---|---|
| **A** flow over, windward slopes | strong wind, the flow goes over the ridge: lift on the windward slope, speed-up at the brow | Picard |
| **B** separation behind a ridge | on a steep ridge the flow detaches: behind the brow a bubble with reverse flow at the ground and a shear layer | Picard |
| **C** waves | wind and stability in the "critical" band: lee waves, under an inversion rotors beneath them | Picard |
| **D** blocking and bypass | wind is weak against stability: the lower layer does not cross the ridge but flows around it, stagnation in front of the obstacle, flow through saddles | mechanism: dividing streamline and layer-by-layer flow |
| **E/F** convection and thermals | heated ground, air rises in cells; only the part tied to terrain is deterministic — sources over heated slopes | mechanism: similarity in w<sub>\*</sub> and z<sub>i</sub> |
| **G** evening drainage | the ground cools, cold air runs down slopes and pools in valleys | mechanism: Prandtl drainage and cold accumulation |
| **H** calm | wind direction is undefined, the solution is set by small disturbances | mechanism: statistics (mean and spread) |

What is honest in these regimes and what is not:

- In **A** the linear theory of flow over a hill is exact while the hill is gentle; the steeper it is, the more a computation is needed. In **B** the mean is defined but the fluctuations behind the ridge are not; they come from level 3.
- In **C** the solution may be ambiguous (two branches — wave or jump); Picard works here as both the working mechanism and the reference, and the iteration count tells of unreliability.
- **D** is the one regime where terrain shape decides everything: a rounded hill has no stagnation or reverse flow in front of the obstacle, a step and a ridge do.
- In **H** there is no steady solution at all; whether a real atmosphere has one, a steady model cannot say. So the game takes calm statistics there, and the lee zone comes not from the wandering field but from statistics and analytics; thermals come from the level 2 formulas.
- **F** is "cells with a share of updraft of about 0.4": the mean field can be computed, the position of each thermal only as statistics.

The boundaries between regimes were measured on ideal terrain (about 8000 computations: hill, ridge, step), then checked on eroded terrain. Blocking, bypass, reverse flow and rotor are **sharp**: the width of the transition in Fr is hundredths of a decade, almost a step. Ground braking, thermal drift and the thermal ceiling change smoothly. No hysteresis (a regime depending on where you came from) was found. On real eroded terrain the transfer of boundaries is partial: lift at the slope and mean speed transfer well, rotor, stagnation and reverse flow worse, and the transition is 5–10 times wider (terrain of many ridges of different heights changes regime one after another). Separation behind the brow depends not on Fr but on steepness: reverse flow begins at a slope of about a quarter and is present at any wind.

## Where Picard finds no solution: the U/N threshold and calm {#picard-limit}

Without heating Picard does not converge at N > N<sub>c</sub>(U): the threshold grows with wind speed as U<sup>0.7</sup>. For a ridge (slope 0.3, height 500 m, wind 3 / 4.5 / 6 m/s) N<sub>c</sub> = 0.0087 / 0.0113 / 0.0142 1/s, that is U/N ≈ 340–440 m. The more stable the air and the weaker the wind, the sooner the iterations stop converging. The ridge height hardly affects the threshold; one threshold on N gives 0–4 errors in 37 cases, on Fr — 0–5.

![Non-convergence threshold against wind speed](/tools/research/air_phase/analysis/AP-13/fig_nc_vs_u.png "N_c (1/s) against wind speed U_sat (m/s) for computation variants: ctrl — as in the game (ω = 1), omega — under-relaxation ω = 0.5 (blue, higher); dotted — the estimate from an earlier measurement")

*The threshold lies on the convergence limit of the iterations, not on a boundary of the flow regime: under-relaxation ω = 0.5 raises it 1.4 times (0.0121 / 0.0155 / > 0.0199 1/s), and 15 of 17 non-convergences are cured with no side effects. So U/N is not part of the phase classifier — it is a property of the solver. In the game ω = 1, convergence has a fallback — see "How the field is assembled" below.*

**Calm.** Fr ≲ 0.25 — at N = 0.01 1/s and h = 500 m this is surface wind up to about 0.5 m/s. Here Picard does not find a steady solution of the model: with ω = 0.5 19–30 % of cases converge, at Fr 0.1–0.2 — 0 of 81, the iterations wander by 0.4–0.6 of the inflow speed, the residual sits on a plateau. Neither under-relaxation nor a longer run helps: it is the same loss of iteration stability, only deeper beyond the threshold. Whether the real atmosphere has a steady solution a steady model cannot say, so the calm field is statistics (mean and spread of late iterations), while the lee zone and thermals come from analytics and the level-2 formulas: the late mean reproduces a true fixed point only up to ~0.1 of the inflow speed. The U/N threshold was checked only at three winds, 3–6 m/s — the U<sup>0.7</sup> law was not tested at lower speeds.

## Separation behind a ridge: the shadow line {#lee-shadow}

The separation zone behind a ridge is set in the game by the shadow line — an inclined line from the brow downwind, below which the flow is considered detached. Its angle in the game is 12° (tan 12° = 0.21), the same for all shapes. Measured on ideal shapes (28 cases with reverse flow, 100 m window, wind across): 9.9° on median — ridge 7.3°, escarpment 10.5°, hill 12.4°; the literature gives 16° for a two-dimensional ridge and 19.7° for Perdigão.

![Along-wind velocity sections behind a ridge with the shadow line](/tools/research/air_phase/analysis/AP-10/fig_sections.png "Along-wind velocity u·e/U behind a brow, Fr = 3. Top to bottom: ridge with slope 0.6 (shadow line 5.5°), ridge with slope 0.3 (8.0°), escarpment (10.6°). Black line — zero velocity, solid orange — the measured shadow line, dashed — the game's 12°.")

*At a ridge the solver gives a lower angle and a reverse-flow bubble longer than in the literature (4–11 obstacle heights against 2.8–3.5): this is a property of the closure with too little mixing in the shear layer. Reverse flow starts at a slope of ≈ 0.20–0.30 and does not depend on Fr over 0.3–5; heating of 100–250 W/m² removes the bubble at slope 0.3.*

## How the field is assembled

1. The **classifier** computes phase weights for each cell — from terrain, wind, stability (temperature profile and inversion), mixing-layer height and the cell's heating (sun by slope and azimuth). This is a parallel computation on the graphics card; the weights are smoothed to avoid a "checkerboard".
2. The **mechanisms** D, F, G, H are computed in cells where they are the main one; A, B, C get an inflow profile with a mechanism correction. From them the mechanism field is assembled; it is needed for the columns that Picard does not recompute (next item) and for the fallback.
3. **Picard on the GPU.** At place load it starts from a coarse Picard (cell ×3 = 1200 m, a 32 × 32 grid, `air_model.picard_start = coarse`), whose solution is interpolated to 400 m; in flight and on the second load pass it starts from the previous field. Columns handed to mechanisms (calm, strong blocking, convection, drainage) are not recomputed by Picard — their field stays the mechanism field, and the residual is counted over the rest. The under-relaxation ω is 1 everywhere in the game: the per-phase ω map is computed but not used (with it the total iteration count is higher, 1560 against 1140, while the field is the same). ω drops to 0.5 only by the fallback rule: if there is no convergence in 300 iterations.
4. **Stitching by projection.** A mixture of velocities by weights breaks continuity at zone boundaries. One projection step (a multigrid pressure solver with a terrain mask) removes the divergence and keeps the rotational part of the mixture.
5. **Fallback on convergence.** If Picard still did not converge (iteration limit), in cells where the calm or blocking weight is above a threshold the mechanism field is taken, in the rest the late mean of the iterations; then projection. If the computation failed altogether — at load the formulas of the [Heuristic mode](/mechanics/air-model/heuristic/) are used, in flight the previous field stays.

Recomputation is every 15 game minutes and when the wind or weather changes: in the morning phases G and D turn into E/F, in the evening back, and the morning break of the inversion simply raises the mixing layer. The new field is blended in smoothly over 60 seconds.

## Limits of the model

- **The classifier thresholds come from the literature and our own measurements on ideal terrain.** Behavior near boundaries is an approximation; on real terrain boundaries transfer partially and are blurred wider.
- **Phases are determined locally, but real flow is nonlocal**: on a 400 m grid the lower and upper layers may be in different regimes, while the classifier looks at the column as a whole.
- **The U/N threshold and calm are solver limits, not physics.** N<sub>c</sub> and non-convergence at Fr ≲ 0.25 were measured on ideal terrain without heating; the model cannot separate physical unsteadiness from instability of the iterations. The shadow-line angle is the same for all shapes: at a ridge the measurement is below the game's 12° (7.3°), at a hill close to it (12.4°).
- **Calm and evening drainage are the weakest spots.** The nocturnal jet is not reproduced; thin drainage layers (units to tens of meters) are not resolved on the grid; cold pools follow accumulation, not computation.
- **Convection and thermals are statistics**, not a computation of each thermal; more on the [thermals](/mechanics/air-model/thermals/) page.
- **The mean field is steady.** Evolution within the hour does not live in it, so between recomputations the field is smoothly replaced by a new one.
- **Terrain resolution.** Speed-up at the brow is underestimated by 15–20 % (see the [common limits](/mechanics/air-model/)); on the 400 m area separation behind small ridges is not resolved, there the separation zone is set by the level 3 estimate.

## What was considered and why this way

- **One Picard for the whole field** — was there before; non-convergence in weak wind and needless computation in convection.
- **A neural network instead of computation** — it is no longer in the game: in calm and in convection the training reference is noisy, and in the wave band the target is two-valued; physics with an understandable mechanism per regime suits better.
- **Assembly by phases + Picard (chosen):** every cell is explainable ("here a bypass under the inversion", "here separation"), and ready blocks are used (the classifier is trivial, the pressure solver and Picard already existed).
- **What to start Picard from.** Compared (total iterations of the pair of solutions over 6 cases: Ongudai, Askarovo, Aushkul at 3 and 6 m/s): from the background 1140, from the phase assembly 1090, from a coarse Picard at 800 m 850, at 1200 m 793. The 1200 m coarse start was taken; in GPU time the gain is smaller (4.34 → 3.75 s) because a fine grid loads the card worse.
- **The phase ω map.** It is computed (ω ≈ 0.5 near regime boundaries), but the iteration total with it is higher (1560 against 1140), so the game uses ω = 1.

## More

- [Phase diagram research](/docs/research/air_phase.md) — phases, order parameters, thresholds from the literature.
- [Measurements on ideal terrain](/docs/research/air_phase_results.md) — what is sharp, what is smooth, hysteresis, transfer to eroded terrain.
- [Experts and assembly by phases](/docs/research/air_phase_experts.md) (§15) — mechanisms and stitching.
- [The air model in the game](/docs/guide/air-model.md), [overview page](/mechanics/air-model/).
