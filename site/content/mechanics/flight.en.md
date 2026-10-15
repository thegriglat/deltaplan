---
title: "Wing and flight"
weight: 10
description: "How flight is computed in the Pendulum mode: a wing of 16 strips, a pilot on the hang chain, arms, ground, stall and spin, telltales, model limits; the older modes; groups and classes of 48 wings."
---

# Wing and flight

The main control mode is "Pendulum": the wing and the pilot are computed as two bodies. The wing is a rigid
body whose lift is assembled from strips; the pilot hangs under it on the suspension and steers by moving
relative to the control bar. Roll, pitch, sideslip and yaw come from forces and moments, not from a commanded
turn rate. The two older, simpler modes ("Weight shift" and "Simple") are still in the settings; they are
described in a short section at the end. Below: how it is built, where the model lies, and which wings are in
the game.

## How flight is computed

The model was first written and verified as a Python prototype (`tools/research/pendulum/`); the game is a
port, with no discrepancy above 15 % on the 110 numbers compared. The code is `scripts/flight/pendulum/`
(plain `RefCounted` classes, no graphics, covered by tests); the `Glider` node is a thin wrapper. The physics
step is 120 Hz; inside a step the hang chain is solved in 4 substeps (XPBD), more when the frame rate drops.

**The wing** is a rigid body with six degrees of freedom. Lift and drag are not computed as one sum but over
**16 strips** (8 per half-wing); each strip has its own local velocity

$$
\vec V_i = \vec V_{\text{wing}} + \vec\omega\times\vec r_i - \vec V_{\text{wind}}(\vec x_i),
$$

its own angle of attack and its own stall; the wind is sampled at the strip from the air model. So the
difference in load between the half-wings, sideslip and the wing's rotation work on their own. Dynamic
pressure and strip force:

$$
q = \tfrac12\rho V^2,\qquad dL = q\,C_L(\alpha_i)\,dS,\qquad dD = q\,C_D\,dS
$$

**The pilot** is a point (his mass) on a **three-link hang chain** 1.2 m long in total; the strap only pulls.
The pilot hangs under the wing and swings sideways with a period of about 1.2–1.3 s. **The arms** are a force
between the pilot and the middle of the base bar (limit 300 N); the pilot is not rigidly tied to the wing, and
his displacement relative to the bar is the control.

**Yaw is free:** the heading is not tied to the airspeed, and sideslip arises from the strips and an
"equivalent keel". Without it (checked on the prototype) the wing has no lateral stability and falls apart
in turbulence.

**Polar and trim.** Each wing has a table "speed (km/h) → sink rate (m/s)" at a reference pilot mass
(`configs/wings/<id>.json → polar.points_kmh_ms`). The sum of the 16 strips in straight flight reproduces this
polar (one drag multiplier per wing, `cd_scale`) and the data-sheet trim (one sail moment constant `dcm0` =
0.05–0.14). The pitch stability margin 0.11–0.20 comes from the geometry. The phugoid damps by itself: period
5.2–5.7 s (Cook, Hiway Demon: 5.4 s), no artificial damping is needed. Moving the hang point 1 cm forward
changes trim by +0.4 (trainer), +0.7 (kingposted), +0.9 (topless) km/h; the Moyes manual gives ≈ 3.2 km/h per
hole.

**Mass and altitude.** At the same angle of attack all speeds and the sink rate grow as \(\sqrt{M/\rho}\),
while the glide ratio (\(C_L/C_D\)) does not depend on mass — a standard result of gliding-flight theory (the
polar is rescaled the same way when water ballast is added). The **total** mass is scaled (pilot + wing).
Air density is \(\rho(h) = 1.225\cdot e^{-h/10400}\) kg/m³ (ISA approximation): at 2000 m the speeds are
already ~10 % higher than at ground level. A detailed derivation, checked against data-sheet values of two
sizes of one wing (Litespeed RS 3.5 and RS 4), is in [docs/research/pilot_mass.md](/docs/research/pilot_mass.md).

## Input and the "Vehicle" tab

Keys, mouse, gamepad and the home-made control frame work as before. The mouse steers the wing while it is
captured (the M key); W/S/A/D never move the wing: in flight they turn the head, on the ground they walk and
turn on the spot. What the input means in "Pendulum":

- Roll right or left — the target displacement of the pilot across the bar up to ±0.45 m; the arms pull the
  pilot to the target (a spring with damping). The technique is as in real life: move the body — the wing
  banks and turns.
- "Pull in" — the pilot forward up to 0.45 m, "push out" — back up to 0.30 m (push out — nose up, braking;
  pull in — acceleration). Full pull-in gives 45–58 km/h, not the 63–103 of "Weight shift": the arms' reach
  is limited and there is no sail tension regulator (VG).
- A neutral bar in straight flight is the wing's trim; a released bar — the wing flies straight.

The "Flight settings" screen is split into the "Place" and "Vehicle" tabs. "Vehicle" holds the wing class and
model, the pilot mass and four parameters that act only in the "Pendulum" mode; the values are stored per
wing and reset to the wing's defaults.

| Parameter | Range | Default | What it does |
|---|---|---|---|
| Hang point along the keel | −4…+4 cm | 0 (data sheet) | forward — faster trim (see above) |
| Hang length | 1.0…1.4 m | 1.2 | swing period 1.1→1.45 s; longer — slower reversal |
| Sail flexibility | 0.1…1.0 | per wing | sail twist from the arm force; more — the wing banks more readily |
| Dihedral | −2…+6° | per wing | more — the spiral is more stable, the reversal slower |

Defaults by class (chosen on the prototype with four reference wings and checked on all 48):

| Class | V, ° | Flexibility | Wing from a 30° turn with neutral arms | Reversal 45→45 (reference wing) |
|---|---|---|---|---|
| trainers | 6 | 0.5 | recovers by itself: bank ≈ 1° after 10 s | 5.1 s |
| Soviet | 5 | 0.45 | recovers by itself | 3.5 s |
| kingposted | −1.5 | 0.6 | holds and tightens slightly: 51° after 10 s | 4.1 s |
| topless | +0.5 | 0.6 | the same: 44° after 10 s | 4.5 s |

The classes are separated by the spiral, as the consulting pilot described: on trainers the wing returns by
itself, on sport wings the exit is by opposite body displacement. Reversal times differ little between classes.

## Ground: run, lift-off, landing

"Pendulum" has its own ground (`PendulumGround`); there are no speed thresholds — everything comes from forces.

- **Standing and the run.** The pilot stands, the wing is on his hands (uprights at the shoulders), the strap
  is slack. The legs are a spring-damper that only pushes; running is a leg force falling as speed grows. The
  arms hold the nose and the wing's roll with a moment proportional to the share of weight on the legs.
- **Lift-off.** The wing builds lift and takes the weight onto the strap; when the feet stop pressing on the
  ground, the mode switches to "flight" by itself. A second later the arms move to the bar. 15° slope, calm
  air: lift-off after 2.8–3.4 s, 15–21 m of run, lift-off speed 31–36 km/h; a 6 m/s headwind shortens the run
  to 2–4 m. If the wing is pushed sideways by the hand during the run, a half-wing touches the slope.
- **Flare.** Near the ground "push out" raises the nose, but the arm travel is limited by the reach of a
  standing pilot (grip 0.5 m below the hang point, arm 0.71 m).
- **Landing on the feet.** The knees absorb the vertical speed. Thresholds on vertical speed and bank are the
  same as in the other modes: soft — vertical < 5 m/s, bank ≤ 15°; hard — vertical 5…7 m/s; crash —
  vertical > 7 m/s or bank > 35°. The thresholds were set from consulting pilots' answers ("from 5 m/s the
  landing is already hard"). The legs decide on the horizontal speed: up to 2 m/s the pilot stands, up to
  5 m/s he runs it out (a step every 0.33 s), faster — he cannot run it out, a hard landing. Touching with the
  control frame before the feet is a hard landing; with the nose, a half-wing or the tail — a crash. After the
  landing the pilot is on his feet again.

![Control frame of the "Apogee": the upright joint and the hang point](/releases/0.7.0/screenshots/106_трапеция_апогей_стойка_до.jpg "The upright joint of the control frame on the Soviet Apogee")

## Stall, wing drop, spin

Stall is computed from the **local** angle of attack of every strip, not of the wing as a whole. A stalled
strip is a finite-aspect-ratio plate (Viterna & Corrigan, \(C_N\) at 90° ≈ 1.2); the centre of pressure moves
back along the chord gradually, over 20° (Fage & Johansen). The half-wing that carries more at a given
sideslip stalls first: in the model's slipping turn it is the **inner** one.

- In a turn of ≈ 30° at low speed with full push-out — a drop onto the inner half-wing, then a spin:
  rotation, yaw up to 94–136°/s, sink rate up to 11–12 m/s. Altitude lost from stall to recovery: trainer
  42 m, kingposted 77 m, topless 84 m.
- **Recovery:** pull in fully and shift the body **against** the rotation until rotation and stall end; then
  the bar to neutral by speed (straight to neutral — a zoom and a flip, this is the phugoid after the dive).
  Only pulling in without shifting against the rotation does not recover.
- The trainer forgives: with a slow push-out or without pushing to the end one or two root strips stall, the
  wing parachutes (1.6–1.9 m/s), no spin. Kingposted and topless wings spin even then.
- A sharp full pull-in for 3 s with arms to neutral does not leave the wing in a permanent stall: speed returns
  to trim in 1.3–2.2 s, then a damped phugoid follows; no one of the 48 wings stays in a permanent stall.

## Telltales

The telltales on the control frame cables show the **model's sideslip**: "Pendulum" has it, and the string
deflects by the same angle (±3°). For a side jet with β ≈ 8–9° the string shows 9°, in calm air — straight
back. A known error: in a steady turn the string goes inward (see "Model limits"). Bots have no strings.

## Eye camera

The head is the pilot's centre of mass + 0.75 m forward along the body + 0.15 m toward the hang point, with no
smoothing on top of the physics: the camera swings with the body on the suspension. The body hangs almost
vertically, it is the wing that swings (according to the consulting pilot). In turbulence with σ 1 m/s the head
in wing axes moves by 5–10 cm (RMS).

## Model limits

- **The pilot is a point.** No body rotation, pulling up, postures or body aerodynamics. "Body perpendicular to
  the bar" is taken as an assumption; in the game the pilot hangs vertically under the hang point.
- **No VG.** Sail tightening (+~20 % speed on sport wings) is not modelled; full pull-in gives 45–58 km/h
  instead of 63–103. The elasticity of the edges and battens is not modelled either.
- **Flexibility is sail twist and an effective dihedral**, fitted to a ≈ 4 s reversal and one flight
  experience (Ochi) with an imprecise force. Not measured on real wings.
- **The Dutch roll is faster than in the literature:** 1.7–2.1 rad/s against 0.92 for the Hiway Demon
  (ζ 0.40–0.53 against 0.29). The wing's Cnβ of 0.03–0.06 is 1.4–2.2 times above the literature; with 0.03
  the sport wing flips in turbulence, so it was not taken. Strip roll damping is −0.52…−0.59 against −0.93 in
  Cook.
- **Sideslip in a reversal is 22–28°** (the literature target ≤ 15–20° is not reached): the sail twist gives
  adverse yaw.
- **The telltale in a ≈ 30° turn** shows up to 12° inward, while the pilot says "the string straight back".
  None of the levers tried fixed this; the test only checks that the string shows the model's sideslip.
- **Landing in calm air is harder than on a real wing.** The model is quasi-steady: after stall there is no
  "air brake" of a flat plate. Best flare in calm air: `training` — hard (vertical 6.4 m/s, horizontal 3.8),
  `laminar` — hard (6.8 and 4.3), `sport` — crash (7.0 m/s against a threshold of 7); into a 3 m/s headwind
  the landing is soft (3–4 steps). Unsteady lift for a fast release exists in the code but is switched off: it
  hardly softens the calm-air landing, and in turbulence the `sport` phugoid starts to swing.
- **Trainers' self-recovery from a turn "within a few seconds"** — the model gives 5–10 s; two numbers (V,
  flexibility) cannot make it faster.
- **The hang point was not changed:** the literal "CM + 2–3 cm" in our estimated mass model gives
  pitch-unstable topless wings (stability margin ≤ 0 on 10 of 15); hence the ±4 cm slider.
- **Stall is static,** strips have no mutual induction (\(C_{L\alpha}\) = 4.5 for all). The inner half-wing
  stalls first mainly because of sideslip inward, not because of the difference in tip speeds as in Zheglov.
- **In turbulence the heading drifts:** the pilot holds the horizon but not the heading; a weakly unstable
  spiral and sideslip turn this into a slow turn of 1–4°/s. The response is chaotic: for a single gust the
  game and the prototype differ, on average they agree. `sport` at the stall boundary is sensitive to the step
  (bank up to 65° at a step of 1/30 s).
- **The ground** was checked on a flat slope; the flare and landing on uneven terrain were not computed in the
  prototype.
- **Bots and remote players over the network** stay on the older model (`FlightModel`); the mode and the body
  position relative to the suspension go over the network.
- Load factor is computed, but breaking the wing when it is exceeded is not modelled.
- The polars are synthesised from manufacturers' data-sheet landmarks (they do not publish full measured
  polars) and by a method checked on a pair of real sizes of one wing.

Numbers, tables and sources are in [docs/research/pendulum.md](/docs/research/pendulum.md); checked against
the literature: Cook & Spottiswoode 2005, Takamatsu & Ochi 2022, Kroo 1981, the Moyes, Wills Wing and Airborne
manuals, Zheglov 1983. The consulting pilot's answers (11 Oct) are used in the class defaults, but it is one
respondent, qualitative; where an answer disagrees with the model, the model was not tuned to it.

## Older modes

"Settings → Controls → Roll control" also offers the two older modes. They are computed by the `FlightModel`
class — a point with orientation whose roll and pitch are set kinematically; the heading follows the airspeed
exactly. They have no sideslip and yaw as a separate degree of freedom, the string in a steady turn points
straight back, there is no pendulum pilot, and the flare near the ground is a phenomenological model. Bots and
the autopilot fly on `FlightModel`.

- **"Weight shift"** (`weight_shift`). Mouse sideways, ←/→ and the stick set the pilot's position across the
  control frame (−1…+1); the wing settles to the roll rate with the time constant `roll_time_constant_s`:

  $$
  \dot\varphi = u\cdot k(V)\cdot\text{roll\_rate\_max\_dps} - \big(\text{roll\_stability\_per\_s} +
  \text{roll\_stability\_steep\_per\_s}\cdot(\varphi/45°)^2\big)\cdot\varphi
  $$

  The turn is coordinated: radius \(V^2/(g\,\mathrm{tg}\varphi)\), in a turn the speed grows as \(\sqrt n\) and
  the sink rate as \(n^{1.5}\). The control frame sets the angle of attack (0 — trim, −1 — acceleration, +1 —
  up to the stall); the phugoid is damped by an angle-of-attack term ∝ \(dV/dt\).
- **"Simple"** (`rate`). The input directly sets the roll rate; with no input the bank holds. A 45°→45°
  reversal ≈ 2.3–2.7 s.

Their stall is a dynamic stall of the sail as a plate across the flow
(\(C_L = C_N\sin\alpha\cos\alpha\), \(C_D = C_N\sin^2\alpha\), \(C_N=2\)); the nose drops by itself after
`nose_drop_delay_s`; in a large bank — a wing drop. The flare uses thresholds and a "hanging" wing.
Parameters are in `configs/flight.json` and `configs/controls.json`, the full description in
[docs/guide/flight.md](/docs/guide/flight.md).

## The wing lineup

The game has 48 wings with real prototypes in four groups — in order of increasing glide ratio and of the
wind in which it is comfortable to launch (`configs/wing_groups.json`): Soviet 1980s (3), trainers (11),
kingposted (19), topless (15). In the "Flight settings" menu you first choose a group, then a model in it;
models within a group are ordered by glide ratio (`reference.best_glide`), then by the wind limit. All the
wings, their numbers and the "data sheet / analogue / estimate" mark for each — in the section
[Glider models](/wings/).

Each wing has a class by crossbar type and the comfortable-wind limit of the class
(`configs/wing_classes.json`, from a consulting pilot's words): trainers 7–10 m/s, rigid crossbar 10–12,
floating crossbar 12–15, topless 20–25 m/s. This is a menu hint; the limit does not enter the physics.

The data — area, span, pilot mass range, reference glide ratio and stall speed — are compiled from
manufacturers' data sheets, DHV cards, club tables and (for the "Apogee", about which almost nothing
exists in open sources) the answers of a consulting pilot; the polars and parameters of each wing —
`configs/wings/*.json` and [docs/research/pilot_mass.md](/docs/research/pilot_mass.md).

The handling of each wing is its own: strip geometry, centre of mass, inertia, sail moment and drag
multiplier are in the `pendulum` block of `configs/wings/<id>.json`; the "Vehicle" defaults come from the
wing class (see above). The wing also carries the parameters of the older modes (`weight_shift.*`,
`stall.*`), but "Pendulum" does not use them.

![Icaro Piuma from behind in flight](/docs/screenshots/site/06_icaro_piuma_сзади.jpg "Icaro Piuma, a kingposted trainer")

![Wills Wing T2C from behind in flight](/docs/screenshots/site/08_ww_t2c_сзади.jpg "Wills Wing T2C, a topless wing")

### Which options were considered

The initial request was a broad lineup of real wings by class, based on the models that the consulting
pilots flew. Further decisions:

- **The sail tension regulator (VG)**: per the Wills Wing T2C and Aeros Combat manuals, the glide ratio
  with VG rises by about 10–15 % at 55–80 km/h, but the handling becomes noticeably heavier and slower in
  roll. Rejected ("pulley systems that tighten the sail — we don't bother", an answer of a consulting
  pilot): the polars of the topless wings are given without VG.
- **The Laminar prototype** was at first listed as topless; per the clarification of a consulting pilot, it
  is a kingposted wing of the Aeros/Airwave Magic class, and moved to the kingposted class.
- **Terminology**: "kingposted/topless" instead of the older "keeled/keelless" — the same distinction in
  substance (the presence of a kingpost with top wires), but the term is more precise.
- **Wills Wing Sport 2** was in the set as the prototype of the kingposted class, but was removed from the
  game by the user's decision of 28 September 2026: the config, the 3D model and the name key were
  deleted, the id `kingpost` in tests was replaced with `laminar` ({{< commit 8633fa7 >}},
  {{< commit e2704c4 >}}) with no compatibility layer for saved settings — "there are no users".
- **Wing and pilot as two bodies** instead of one point with kinematic roll: this became the main mode. The
  older modes remain selectable: they are simpler, bots and the network fly on them, and "Weight shift" was
  calibrated against pilots' answers.

## Further reading

- [docs/guide/flight.md](/docs/guide/flight.md) — the full description of the flight model, the
  `FlightModel`/`Glider` API, the visual contract and tests.
- [docs/research/pilot_mass.md](/docs/research/pilot_mass.md) — the derivation of the polar scaling with
  mass and the check against data-sheet data.
- [docs/research/pendulum.md](/docs/research/pendulum.md) — the "Pendulum" mode: prototype, verification, limits.
- [docs/guide/flight/pendulum.md](/docs/guide/flight/pendulum.md) — how "Pendulum" is built in the game.
- [docs/research/wings_config_sources.md](/docs/research/wings_config_sources.md) — how the data sheets went into the wing configs.
- [docs/research/wing_sources.md](/docs/research/wing_sources.md) — sources on the appearance and
  characteristics of the wings.
- [docs/research/control_frame_refs.md](/docs/research/control_frame_refs.md) — references for the control
  frame and the cockpit view for the 3D models.
- Code: [flight_model.gd](/scripts/flight/flight_model.gd), [wing_polar.gd](/scripts/flight/wing_polar.gd),
  [ground_run.gd](/scripts/flight/ground_run.gd), [landing_flare.gd](/scripts/flight/landing_flare.gd),
  [pendulum_model.gd](/scripts/flight/pendulum/pendulum_model.gd).
