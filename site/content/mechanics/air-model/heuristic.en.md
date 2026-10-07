---
title: "Heuristic mode"
weight: 50
description: "The simple wind-over-terrain mode: a wind profile and formulas for slope lift, the lee zone, thermals and turbulence instead of a computed field. What is computed, how it is simpler than Calculation, when to choose it."
---

# Heuristic mode: wind by formulas

The "Wind over terrain" setting has two modes. "Calculation" is the [air model](/mechanics/air-model/) of three levels (phases and Picard on the graphics card); the other pages of this section are about it. "Heuristic" is the simple mode: the wind field is not computed on the graphics card, and the air at each point is given by one function using formulas. This page is only about it.

## What it is and how it is simpler

- **One wind for the whole world:** a single direction, speed growing with height above ground by a power law and separately with altitude above sea level. Terrain neither turns nor accelerates the wind — hence the menu label "wind profile without terrain".
- **Slope lift and the lee zone** are formulas from the terrain slope at the point (below on this page): lift ahead of the slope along the wind, a "shadow line" behind the ridge with sink, jolts and reverse flow.
- **Thermals** are cells with a deterministic cycle, strength from the table of anchors by cloud base height (the ["Weather"](/mechanics/weather/) page).
- **Turbulence** is noise from formulas: mechanical, convective, at the thermal edge and the rotor behind a ridge.
- The GPU solver is not launched, so the place loads without the wind computation stage.

Besides the menu choice, the same formulas work if the field computation failed at load and outside the field's area.

## When to choose it

When a predictable, cheap wind is needed: a weak graphics card, fast loading, comparison with the old behavior. What it loses against "Calculation" is the list of "what the formula cannot do" below: no flow over the brow and speed-up, saddle, flow around hills sideways, phases (blocking, waves, drainage, calm), stability; thermals do not come from a field.

## How it works

All the air the pilot gets in the game comes through a single function `Atmosphere.air_velocity_at(pos)`
(`scripts/atmosphere/atmosphere.gd`), and the flight model calls it at three points at once: the wing center
and both outer wing sections. So a different flow across the span rolls and shakes the wing by itself, without a separate
"roll from a gust". The atmosphere knows the terrain through the `GroundField` cache, a 30 m grid with height and slope
at every node.

**Horizontal wind** grows with height above the ground under the pilot by a power law and, separately,
with altitude above sea level:

$$ u = u_{ref} \cdot \left(\frac{agl}{10\,\text{m}}\right)^{0.14} \cdot \left(1 + 0.6 \cdot \frac{msl - msl_{start}}{1000\,\text{m}}\right) $$

The wind direction is one for the whole world; the terrain does not turn it.

**Slope lift.** Right at the ground the air follows the terrain: the steeper the slope facing the wind, the
stronger the vertical component. The point where the slope is taken is shifted forward upwind (the higher the
pilot, the farther from the slope the lift is "felt"), and the lift strength decays with height:

$$ w_{ridge} = \mathrm{clamp}\Big(0.85 \cdot u \cdot (\hat w \cdot \nabla h) \cdot e^{-agl_s / 250\,\text{m}},\ \pm 6\ \text{m/s}\Big) \cdot (1 - lee) $$

where the gradient point is taken with an offset of `0.8 · agl` (maximum 400 m) against the wind. The numbers are from
`configs/atmosphere.json → ridge`: `efficiency` 0.85, `decay_height_m` 250, `forward_shift_factor` 0.8,
`forward_shift_max_m` 400, `max_lift_ms` 6.

**The lee zone and rotor.** Behind the crest a "shadow line" is computed: the boundary below which, at the given
wind, the flow separation zone begins: `s(p) = maxᵢ(h(p − ŵ·dᵢ) − dᵢ·tg 12°)` (samples upwind at
60…1600 m). A pilot below this line is in the rotor. The zone's strength grows with depth below the line and with the height of the
obstacle itself and gives:

- sink `0.25…0.7 · u · lee` (the share grows with wind — "hazard" `g` from 2 to 5 m/s);
- turbulence σ `0.5…0.9 · u · lee`;
- rare downward jerks in noise patches carried by the wind;
- reverse flow right at the ground.

Measurement on a model 300 m ridge (`tests/atmosphere/test_lee_rotor.gd`):

| wind at takeoff | mean w in the rotor | σ | windward w / σ |
|---|---|---|---|
| 2 m/s | −0.74 m/s | 0.94 | +1.2 / 0.6 |
| 5 m/s | −3.8 m/s | 3.4 | +3.0 / 1.5 |
| 8 m/s | −6.0 m/s | 5.0 | +4.8 / 2.4 |

A trimmed flight over a 50 m crest, 50 m above it, in a 6 m/s wind: −126 m in 30 s (in calm air, −25 m).

**Wave** (`wave_field.gd`) is Scorer's linear theory along the wind direction: the displacement of streamlines is a
convolution of the terrain slope with `cos(k·d)·exp(−d/L)`, wavelength `λ = 2πU/N` (N is the Brunt–Väisälä frequency).
In the wave crests there is lift, under them near the ground there are rotors, and over the high points of the terrain there are lenticular clouds.
The word "wave" is never shown to the pilot (it is unfamiliar to them); the interface has only "Wind" and
"Wind from". By default the wave is off (`wave_strength = 0` in all current weather scenarios);
the lee zone and rotor work at all times, from the wind alone.

## Physics: laws and approximations

The key idea is the thin-perturbation model over terrain (Jackson–Hunt linear theory): the flow
is split into a mean profile plus a small perturbation from the shape of the hill, and the perturbation decays with height
on the scale of the hill's half-width. Our formula `w = U·∇h` with exponential decay is its crude,
"ornithological" approximation (the same formula is used in lift models for birds of prey), without
reconciling horizontal and vertical through the continuity equation.

Real values the model was checked against (`docs/research/slope_wind.md`, `docs/research/calibration_data.md`):

| Phenomenon | Typical values | Source |
|---|---|---|
| Wind speed-up over the summit (near the ground) | ΔS_max ≈ B·H/L: B ≈ 2.0 (long ridge), 1.6 (hill), 0.8 (escarpment) | Jackson & Hunt 1975; Taylor & Lee 1984 |
| Decay of the speed-up with height | ΔS(z) ≈ ΔS_max·exp(−A·z/L), A ≈ 2.5–4 | Taylor & Lee 1984, ASCE 7 |
| Askervein (H = 116 m) | summit speed-up at 10 m ≈ +80 % | Taylor & Teunissen 1987 |
| Saddle (field measurements) | +40…60 % to the approach at 10 m AGL | Neal 1982, Gebbies Pass |
| Flow separation behind the crest | starts at a lee slope ≳ 15–20° | Wood 1995 |
| Lift band | ≈ the height of the slope from its foot, on a good ridge up to 1–2 heights | FAA AC 00-6A; York Soaring, Condor |

## Model limits

- **The height of the lift band does not depend on the size of the slope.** For us the decay is always `exp(−agl/250 m)`.
  In real life the decay scale is the width of the slope itself, L: over a narrow steep ridge the lift in the model
  extends higher than it should, over a wide gentle one it dies out too early.
- **There is no wind speed-up over the crest.** In reality at the brow the wind is 30–90 % stronger than in front of the slope;
  for us the horizontal wind depends only on altitude above sea level, not on the shape of the terrain.
- **Small terrain "hits" at any height.** The slope is taken at a single point with a 60 m base, so a gully
  100 m wide gives the same dip at a height of 100 m as at the ground, only multiplied by the overall
  exponential. Physically, the perturbation from a feature of size λ should decay with height as `exp(−2πz/λ)`.
- **The flow is not three-dimensional.** An isolated hill, a spur ("nose") and a cirque ("bowl") with the same slope along the
  wind give the same lift for us; in reality the air partly flows around a hill from the sides (weaker lift),
  and in a bowl the flow converges (stronger lift).
- **The angle of the wind to the ridge** is accounted for only as a cosine; the turning of the wind along the ridge and the increase of turbulence at an
  oblique wind are not.
- **The saddle / pass ("pipe") is not amplified**: in the model it is, on the contrary, weaker, since the lower altitude above sea level and
  the gentler slope along the wind give less, not more, lift and wind. There is no flow compression in the depression.
- **There is no atmospheric stability.** The slope flow is the same on a stable and an unstable day; in real life
  with stable stratification the air does not go over high peaks but flows around them and goes into
  the depressions, so the "pipe" in passes should be stronger exactly then.
- **Mass is not conserved**: horizontal and vertical are computed independently of each other.
- **Separation** is only through the shadow line with a fixed 12° angle, with no dependence on surface
  roughness and the shape of the brow; there is no windward "bubble" at the foot of a steep cliff.

By a pilot's feedback, the sink and downward blows behind the crest feel right: this is the sum of several
terms (the sink ring around a thermal, the background between thermals, the rotor's sink and jerks,
turbulence, the wing's response to load factor), and it was decided not to touch it when reworking the slope.

## What was considered and why this way

A comparison of our formula with potential flow around a two-dimensional ridge (the Agnesi profile) showed: the strength of
lift at the ground is generally plausible (a discrepancy of 10–20 %), but the points listed above are not.
The rework options considered (from cheap to expensive):

- **Improved analytics** (smoothing the slope with height, decay scale = slope width,
  speed-up over the crest after Taylor–Lee, a saddle flag): days of work, runtime almost unchanged;
  closes almost all the discrepancies found, but remains a set of heuristics.
- **Linear 3D theory via an FFT of the terrain**: consistent lift, speed-up over the crest, flow around
  hills from the sides, wind turning; still no separation.
- **A mass-consistent diagnostic field** (WindNinja-like): plus blocking and a "pipe" in
  passes in stable air; still without real separation and rotors.
- **Offline CFD**: separation and real rotors, but only for built-in locations, hundreds of MB of data, and even
  CFD predicts the turbulence in the wake poorly (checked on the Askervein test site).

None of the options was chosen on its own: instead of a point rework of the slope it was decided to compute
**one physical air field** at once for wind, lift and thermals (the plan
[docs/plan/air_model.md](/docs/plan/air_model.md)), and this has been done — see the [air model](/mechanics/air-model/). A narrower plan was also considered: a wind field on a
grid, mass-consistent only ([docs/archive/plan/wind-field.md](/docs/archive/plan/wind-field.md)) — but it had
no heat (so no thermals and no difference between a heated and a cold slope), and no inertia
(an instant recomputation when the weather changes); the three-scale air plan replaced it.

## Next

The air model at three scales ([page](/mechanics/air-model/), [docs/guide/air-model.md](/docs/guide/air-model.md))
gives the acceleration at the brow, the saddle, flow around hills from the sides and the rotor not as separate formulas for the slope,
but as a consequence of one equation for the whole air field. It also lists what it cannot do yet:
for example, the speed-up at the brow is underestimated by 15–20 %, and the saddle gives ×2.05 instead of ×1.5.

## Details

- [docs/research/slope_wind.md](/docs/research/slope_wind.md) — the full study: numbers, formulas,
  comparison with other simulators, questions for the pilot.
- [docs/research/calibration_data.md](/docs/research/calibration_data.md) — a table of reference observables
  for calibration (speed-up over the crest, saddles, gorges).
- [docs/guide/atmosphere.md](/docs/guide/atmosphere.md) — the structure of the atmosphere module as a whole.
- [scripts/atmosphere/atmosphere.gd](/scripts/atmosphere/atmosphere.gd),
  [scripts/atmosphere/ground_field.gd](/scripts/atmosphere/ground_field.gd),
  [scripts/atmosphere/wave_field.gd](/scripts/atmosphere/wave_field.gd) — the code.
- [configs/atmosphere.json](/configs/atmosphere.json) — all numeric parameters (`ridge`, `lee`, `wave`).
