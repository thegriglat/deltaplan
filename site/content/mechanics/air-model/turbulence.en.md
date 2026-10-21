---
title: "Turbulence and rotor"
weight: 40
description: "Level 3 of the air model: how gusts, turbulence, downdrafts, rotor and reverse wind behind a ridge come out of the mean field; how the lee zone was calibrated against measurements; where the model is wrong."
---

# Turbulence and rotor behind a ridge

This is level 3 of the [air model](/mechanics/air-model/): everything smaller and faster than the mean field — gusts, jolts, downdrafts, rotor. The details of these motions are random, so the model does not compute eddies but sets **their statistics**; amplitudes and scales are derived from the level 1 field and the level 2 thermals. At every point of flight the game gets: an addition to the wind (three components, different at the center and at the wing halves), the strength and scale of turbulence, and a lee-zone flag.

## What is computed

**Turbulence by place.** The strength of fluctuations comes from the field, not from a table by height:

- from **ground friction** (wind near the ground) and **wind shear** — mechanical turbulence; it grows with wind, is stronger at the brow than over flat ground (the air is accelerated there); forest is only partly accounted for — roughness by cover, but not canopy height (see ["Forest"](#forest));
- from **stability** — above the surface layer in stable air it almost dies out, and the eddy scale is limited;
- from **convection** — the same scale w<sub>\*</sub> as for thermals, with a profile over the mixing-layer height;
- the mechanical and convective parts add up as in surface-layer similarity, not as a plain sum.

Fluctuations are not equal in all directions: near the ground along the wind they are stronger than vertical, higher up closer to isotropy. They are laid along and across the mean wind at the point.

**The gust spectrum.** Gusts are a sum of several octaves of noise weighted by the von Kármán spectrum; in the inertial range the spectrum follows the −5/3 law (the old noise had a slope of about −2.9). Near the ground the eddies are carried by the local wind, not the common one, so that a standing pilot sees slow "cycles" of wind, not jolts within seconds.

![Gust spectrum in straight flight: field and the simplified formulas](/tools/research/air_turb/out/spectrum.png "Spectrum of gusts u and w at 150 and 400 m above the Aushkul launch, straight flight at 12 m/s")

**Lee zone and rotor.** The field itself shows the wake behind the ridge: sink and weakened wind. Where the solver resolves the separation bubble (in the 50 and 100 m windows), reverse flow at the ground is taken straight from the field; on the coarse 400 m area and behind low bumps — an estimate from measurements on the Perdigão ridge pair. On top of the field level 3 adds:

- a **mixing layer** between the flow above the ridge and the wake — the velocity jump across it is counted from the wind **at ridge-top level**, not from the largest wind above (otherwise sinks behind the ridge came out several times deeper than real);
- **turbulence of this layer** — by measurements of mixing layers it is a small fraction of the velocity jump;
- **downward jolts** — part of this turbulence with zero mean (the mass flux is already in the field) and reverse flow at the ground.

The zone flag is a velocity deficit against a logarithmic profile together with sinking air: sinking distinguishes a wake from simple braking at the windward foot. In the "Heuristic" mode turbulence and rotor parameters come from simplified formulas instead of the field — see [Heuristic mode](/mechanics/air-model/heuristic/).

**Heating kills the rotor.** Over heated ground convection destroys the separation bubble, so rotor and jolts are weakened by heating: slightly at weak heating (an average day), strongly at strong heating (clear noon).

## Separation behind a ridge: the Perdigão section

The flow behind a crest was checked on two parallel Perdigão ridges (Portugal, 2017 campaign): the model on this terrain was compared with masts on the slopes and in the valley. The sections below show wind speed along the wind; the black dashed line is the edge of reverse flow (−0.5 m/s), red is downwind.

![Perdigão, wind from the north-east: along-wind speed on a section across the ridges](/tools/research/cases/perdigao/out/fig_section_ne.png "Perdigão section for north-east wind (nominal research run): behind the first ridge there is a reverse-flow zone 0.31 ridge heights long against 0.50 measured")

Takeaway: with north-east wind the solution shows a reverse-flow bubble behind the first ridge, but about half as long as measured (length 0.31 against 0.50 ridge heights, depth 0.36 against 0.9 of the height).

![Perdigão, wind from the south-west: along-wind speed on a section across the ridges](/tools/research/cases/perdigao/out/fig_section_sw.png "Perdigão section for south-west wind (nominal research run): the reverse-flow zone hardly forms — 0.04 ridge heights")

Takeaway: with south-west wind the solution gives almost no bubble (0.04 against 0.50 measured) — which is why on the coarse domain the game adds an estimate from the Perdigão measurements (see above) rather than relying on the solution alone. This is a research calculation with a constant roughness of 0.645 m, not a picture from the game.

## Where the numbers come from: calibration on measurements

The lee zone in the game is fitted not "by feel" but to measurements on ideal terrain (the AP-10 series — [results](/docs/research/air_phase_results.md)): hill, ridge, step of different steepness, at different wind and heating. What they showed and what entered the model:

- **Separation depends on steepness, not on the Froude number.** Reverse flow behind the brow begins at a slope of about a quarter (a ridge slightly earlier, a step and a hill slightly later) and is present at any wind. One angle for all shapes is a simplification: without a field we do not distinguish the shape of the brow.
- **The shear layer above the zone is thicker than thought:** by measurements several hundred meters above the line (the old estimate was 60 m).
- **Sink in the zone is small**, several times less than before: measurements give a few percent of the wind speed, the literature up to tens.
- **Heating kills the bubble:** from weak heating on it shortens, and at strong heating it disappears.
- On eroded terrain the transfer of boundaries is partial: lift at the slope transfers well, rotor appears at weaker wind than on ideal shapes and changes not at one point but gradually — ridges of different heights separate one after another.

For comparison with the field, pilots' words: sinks and downward jolts behind a ridge feel right, and it was decided not to touch them.

## Limits of the model

- **Gusts are a prescribed shape, not an eddy computation.** For the jolts the amplitude and the mean (zero) are derived from physics, but not the tail of the distribution. In the quiet wake behind the ridge the eddies "fly past" faster than in life: the noise is carried by one common wind, not the local one.
- **Over the summit and on the windward slope turbulence is overestimated** by a factor of 2–3 against what was measured on Askervein (the flow is accelerated there and turbulence has no time to grow); behind the ridge it matches within uncertainty.
- **Forest is only partly accounted for** (details [below](#forest)): roughness by cover is there, but there is no zero-plane displacement above the canopy and no separate eddy scale over forest; which way this shifts turbulence above the treetops we have not checked.
- **Known discrepancy (a): in strong wind behind the ridge the model shakes the wing more than in life.** Noticeable 50–100 m above ground on the lee side. The shear layer gives turbulence 3–4 times higher than in measurements and literature calculations; individual vertical-velocity peaks are 3–4 σ too high. The model errs on the side of "throws harder". The author checked against the literature and decided not to fix it for now: with this amount of data it cannot be calibrated more precisely.
- **Known discrepancy (b): reverse wind near the ground behind low bumps and gentle slopes is overestimated.** Where the solver does not resolve the separation bubble it is replaced by an estimate from the Perdigão ridge with no slope check: for three-dimensional bumps the bubble length is overestimated about 1.8 times, and the reverse speed, taken as the maximum inside the bubble, is overestimated 1.5–2 times as a mean. The error is "too much return wind".
- **No small eddies:** eddies smaller than a few meters are simply noise.
- **Not reproduced:** the influence of brow shape and roughness on separation; there is no windward bubble at the foot of a steep cliff.

## Forest in the air model {#forest}

This page used to say "over forest the surface is meadow everywhere" — by the code that is wrong. What is actually there:

- **Roughness by cover.** For each cell the model takes the share of each surface class (forest, meadow, field, shrub, rock, water, built-up); forest roughness z<sub>0</sub> is 1.0 m against 0.03 m for meadow; cells are averaged logarithmically. Over Altai the mean roughness of the domain comes out near 0.22 m instead of the former 0.1 m. Wind near the ground in a forest cell is computed with its own roughness: at 30 m over forest it is about ×0.95, over meadow ×1.03–1.05.
- **Heating by cover.** Forest heats differently from meadow: different albedo (0.12 against 0.2), share of heat into the soil (0.04 against 0.15), ratio of latent to sensible flux, and the heating lags by 0.6 h against 0.3.
- **Turbulence.** Friction is taken from the wind at the point and the column friction, so forest roughness reaches it through the mean wind; the single z<sub>0</sub> in the turbulence formulas is the domain mean, not per cell.
- **What is missing.** The terrain in the model is bare ground without crowns: the surface is not raised by the forest height, and the zero of the logarithmic profile above the canopy is not displaced (the Perdigão studies used a displacement of 12.6 m — 0.7 of an 18 m canopy — but it was not carried into the game). There is no separate eddy scale over forest either. The 10 m number in the world settings is not part of the air model: it is used for lighting the forest edge in rendering.

Summary: the phrase "the surface is meadow everywhere" concerned turbulence and was inaccurate; it is fairer to say that forest affects wind and heating, but canopy height and mixing inside it are not modelled.

## More

- [The air model in the game](/docs/guide/air-model/turbulence.md) → "Scale 3: disturbances from the field".
- [Measurements on ideal terrain](/docs/research/air_phase_results.md) (separation behind the brow, envelope), [turbulence from the field research](/tools/research/air_turb/README.md).
- [Atmosphere](/docs/guide/atmosphere.md) — the lee zone in the simplified formulas.
- [Perdigão research results](/tools/research/cases/perdigao/README.md) — NE and SW sections.
- Pages: [air model](/mechanics/air-model/), [wind field: phases and Picard](/mechanics/air-model/wind-phases/), [thermals](/mechanics/air-model/thermals/).
