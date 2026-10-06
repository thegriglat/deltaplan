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

So the field is assembled by phases: a classifier determines the regime in each cell, and the cell gets the mechanism that suits it. The regime is governed by four dimensionless quantities: the Froude number Fr = U/(N·h) (wind against stability and obstacle height), the convection parameter −z<sub>i</sub>/L (heat against mechanical mixing), the slope steepness and the ratio of terrain height to mixing-layer height h/z<sub>i</sub>.

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

## How the field is assembled

1. The **classifier** computes phase weights for each cell — from terrain, wind, stability (temperature profile and inversion), mixing-layer height and the cell's heating (sun by slope and azimuth). This is a parallel computation on the graphics card; the weights are smoothed to avoid a "checkerboard".
2. The **mechanisms** D, F, G, H are computed in cells where they are the main one; A, B, C get an inflow profile with a mechanism correction. From them the **initial approximation** is assembled.
3. **Picard on the GPU** starts not from zero but from this assembly (a "warm start"), and a per-cell **under-relaxation ω** is set by the phase map: in clean flow over terrain a full step, near regime boundaries more careful, so as not to rock the iteration. If there is no convergence by a set number of iterations, ω is reduced across the whole field. Columns handed to mechanisms (calm, convection, drainage, strong blocking) are not recomputed by Picard — their field stays as it is, and the residual is counted over the rest.
4. **Stitching by projection.** A mixture of velocities by weights breaks continuity at zone boundaries. One projection step (a multigrid pressure solver with a terrain mask) removes the divergence and keeps the rotational part of the mixture.
5. **Fallback on convergence.** If Picard still did not converge, in cells with a calm or blocking weight the mechanism field is taken, in the rest the late mean of the iterations; then projection. If the computation failed altogether — at load the formulas of the [Heuristic mode](/mechanics/air-model/heuristic/) are used, in flight the previous field stays.

Recomputation is every 15 game minutes and when the wind or weather changes: in the morning phases G and D turn into E/F, in the evening back, and the morning break of the inversion simply raises the mixing layer. The new field is blended in smoothly over 60 seconds.

## Limits of the model

- **The classifier thresholds come from the literature and our own measurements on ideal terrain.** Behavior near boundaries is an approximation; on real terrain boundaries transfer partially and are blurred wider.
- **Phases are determined locally, but real flow is nonlocal**: on a 400 m grid the lower and upper layers may be in different regimes, while the classifier looks at the column as a whole.
- **Calm and evening drainage are the weakest spots.** The nocturnal jet is not reproduced; thin drainage layers (units to tens of meters) are not resolved on the grid; cold pools follow accumulation, not computation.
- **Convection and thermals are statistics**, not a computation of each thermal; more on the [thermals](/mechanics/air-model/thermals/) page.
- **The mean field is steady.** Evolution within the hour does not live in it, so between recomputations the field is smoothly replaced by a new one.
- **Terrain resolution.** Speed-up at the brow is underestimated by 15–20 % (see the [common limits](/mechanics/air-model/)); on the 400 m area separation behind small ridges is not resolved, there the separation zone is set by the level 3 estimate.

## What was considered and why this way

- **One Picard for the whole field** — was there before; non-convergence in weak wind and needless computation in convection.
- **A neural network instead of computation** — it is no longer in the game: in calm and in convection the training reference is noisy, and in the wave band the target is two-valued; physics with an understandable mechanism per regime suits better.
- **Assembly by phases + Picard (chosen):** every cell is explainable ("here a bypass under the inversion", "here separation"), and ready blocks are used (the classifier is trivial, the pressure solver and Picard already existed).

## More

- [Phase diagram research](/docs/research/air_phase.md) — phases, order parameters, thresholds from the literature.
- [Measurements on ideal terrain](/docs/research/air_phase_results.md) — what is sharp, what is smooth, hysteresis, transfer to eroded terrain.
- [Experts and assembly by phases](/docs/research/air_phase_experts.md) (§15) — mechanisms and stitching.
- [air-phase plan](/docs/plan/air-phase.md).
- [The air model in the game](/docs/guide/air-model.md), [overview page](/mechanics/air-model/).
