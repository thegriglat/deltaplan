---
title: "Wing and flight"
weight: 10
description: "How flight is computed: polar, pilot mass, roll and control frame, Pendulum mode, ground run, stall, landing; groups and classes of 48 wings."
---

# Wing and flight

The flight model is not an arcade with a single "speed–lift" curve, but a point mass with orientation
that solves the same equations as a real hang glider: lift and drag from the wing polar, pilot mass,
roll from weight shift, stall, ground run and the flare near the ground. There is also a second level —
the experimental "Pendulum" mode (wing and pilot as two bodies), described separately below. Below is how
it is built and which wings are in the game.

## How flight is computed

The logic lives in `scripts/flight/` — plain `RefCounted` classes (tested without graphics, by tests);
the `Glider` node is a thin wrapper around them. The physics step is 120 Hz, semi-implicit Euler.

Glider state: position, ground velocity, heading, roll and roll rate, keel pitch, angle of attack, stall
flag. Forces: lift — perpendicular to the airspeed, tilted by the roll angle; drag — along the flow;
weight.

$$
q = \tfrac12\rho V^2 S,\qquad L = q\,C_L(\alpha),\qquad D = q\,C_D(C_L)
$$

**Polar.** Each wing has a table of "speed (km/h) → sink rate (m/s)" points at a reference pilot mass
(`configs/wings/<id>.json → polar.points_kmh_ms`). The points are converted to dimensionless \(C_L\to C_D\)
by

$$
C_L = \frac{2Mg\cos\gamma}{\rho S V^2},\qquad C_D = C_L\,\mathrm{tg}\,\gamma
$$

and between them the interpolation is linear; in calm air the model reproduces the source polar exactly.
Beyond the slowest edge of the polar (deeper than there are points) it is a parabola \(C_{D0}+kC_L^2\).

**The control frame sets the angle of attack**, not the speed directly: position 0 is trim, −1 is "fully
pulled in" (acceleration), +1 is "fully pushed out" (up to the stall); between them the speed is linear
in the deflection. The layout is the hang glider pilot's: push out (mouse forward, ↑, gamepad stick
forward) — nose up, braking; pull in (mouse back, ↓) — nose down, acceleration. The mouse always drives
the wing (the control frame) while it is captured (the M key); without capture the cursor is free and the
control frame holds its last position. W/S/A/D never move the wing: in flight they turn the head in the
cockpit (90°/s; release and the view stays; V or the middle button — forward again), on the ground —
walking and turning on the spot. To look around with the mouse, hold the right button (the control frame
keeps its position meanwhile). The "Invert pitch" setting (off by default) gives an "airplane-style"
layout for the arrows, mouse and stick. The wing reaches the commanded angle of attack not instantly but
with the time constant `pitch_time_constant_s` — inertia. The speed↔height oscillation (the phugoid),
which in a point model without damping would swing forever, is damped by an addition to the angle of
attack proportional to \(dV/dt\) (`flight.json → phugoid_damping`, coefficient 1.4 — damping ratio
ζ≈0.5): a real wing is speed-stable and settles within 1–2 oscillations.

**Mass and altitude.** Since the control frame sets \(C_L\), all speeds and the sink rate grow as
\(\sqrt{M/\rho}\), while the glide ratio (\(C_L/C_D\)) does not depend on mass — a standard result of
gliding flight theory (the same way a glider's polar is recalculated when filling water ballast). The
**total** mass is scaled (pilot + wing), not the pilot mass alone. Air density
\(\rho(h) = 1.225\cdot e^{-h/10400}\) kg/m³ (ISA approximation): at 2000 m the speeds are already ~10 %
higher than at the ground. A detailed derivation with a check against the manufacturer data for two sizes
of one wing (Litespeed RS 3.5 and RS 4) — [docs/research/pilot_mass.md](/docs/research/pilot_mass.md).

The time constants in roll and pitch grow as \(\sqrt{M/M_{\text{ref}}}\) (moment of inertia ∝ M,
aerodynamic damping ∝ V ∝ √M) — a heavy pilot enters and leaves a roll more slowly.

## Roll and the control frame

Three roll control modes (`controls.json → roll_control_mode`, the "Roll control" setting). The first two
(`FlightModel`) are described here; the meaning of `ControlInput.roll` in flight is set by
`ControlInput.weight_shift`. The third, "Pendulum", is below.

- **"Weight shift"** (`weight_shift`, the default). Mouse sideways, ←/→ and stick move the pilot's body: right — roll right (the "Roll by mouse and arrows" setting switches to "like the bar": bar right — weight left — roll left); one press of X returns the bar to the centre. Roll input (mouse sideways, ←/→, stick) is the
  pilot's position across the control frame (−1…+1, 0 — centre). The technique is as in real life: swing
  to the right — the wing banks and turns; stand in the centre — the wing levels itself and flies
  straight in the new direction. The roll rate to which the wing settles with the time constant
  `roll_time_constant_s`:

  $$
  \dot\varphi = u\cdot k(V)\cdot\text{roll\_rate\_max\_dps} - \big(\text{roll\_stability\_per\_s} +
  \text{roll\_stability\_steep\_per\_s}\cdot(\varphi/45°)^2\big)\cdot\varphi
  $$

  (plus the contribution from the difference of the flows at the wing tips — see below). \(k(V)\) is the
  weight-shift effectiveness: below trim \((V/V_{\text{trim}})^{\text{roll\_speed\_exponent}}\) (the wing
  is sluggish), above trim — \((V_{\text{trim}}/V)^{\text{roll\_heavy\_exponent}}\) (heavier at speed).
  Holding the shift settles a bank proportional to the shift, without winding up into a spiral: at full
  shift in a turn ≈ 41° for the trainer wing, 45° for the kingposted one (Laminar), 44° for the sport one.
  From the centre after 2 s of full shift the wing returns to |φ| < 3° in ≈ 2.0 / 2.6 / 3.3 s
  respectively — the trainer is strongly stable, the sport wing is almost neutral at small bank. Beyond
  `roll_overbank_deg` (70 / 65 / 60°) the stability fades to nothing within 10° — a spiral begins, and the
  exit is only by shifting the opposite way. A 45°→45° reversal at full shift takes ≈ 2.2 s.
- **"As before"** (`rate`). Weight shift directly sets the roll rate (`roll_rate_max_dps`, multiplier
  \((V/V_{\text{trim}})^{0.5}\)), the wing settles to it with the time constant `roll_time_constant_s`;
  with no input the bank holds. A 45°→45° reversal ≈ 2.3–2.7 s. The autopilot and the test bots are always
  in this mode.

- **"Pendulum (experimental)"** (`pendulum`). A separate model instead of `FlightModel`: the wing is a rigid
  body with six degrees of freedom, lift is computed over 16 strips (8 per half-wing), each with its own
  local speed, local angle of attack and local stall; the pilot is a point on a three-link hang chain
  1.2 m long (the strap only pulls) and swings sideways with a period of about 1.2–1.3 s. The arms are a
  force between the pilot and the middle of the base bar (limit 300 N); the pilot's displacement relative
  to the bar is the control (up to ±0.45 m sideways, forward up to 0.45 m, back up to 0.30 m). Roll, pitch,
  slip and yaw come from forces and moments, not from a commanded rate. Full pull gives 45–58 km/h, not
  the 63–103 of "Weight shift": the arms' reach is limited and there is no sail tension regulator (VG).
  Stall is by the local angle of attack of a strip; in a slipping turn the inner half-wing stalls first;
  in a turn of ≈ 30° at low speed with full push the wing drops into a spin (recovery: pull in and shift
  the body against the rotation; the trainer forgives — it parachutes without a spin). It has its own
  ground (`PendulumGround`): no speed thresholds, the run and lift-off come from forces (15° slope, calm
  air — lift-off in 5.2–6.5 s over 21–31 m). The mode is chosen at the start of a flight and is for the
  human pilot only; bots and remote players over the network stay on `FlightModel`. Limits and
  disagreements with the literature (landing in calm air is harder than on a real wing; the Dutch roll is
  faster than published; the pilot is a point) are in [docs/guide/flight.md](/docs/guide/flight.md),
  section "Маятник".

The X key ("to centre") in the "Weight shift" and "As before" modes smoothly puts the control frame to neutral and levels the wing to
the horizon. The turn is coordinated, without slip: the heading follows the airspeed exactly, the radius
is \(V^2/(g\,\mathrm{tg}\varphi)\), in a turn the speed grows as \(\sqrt n\), the sink rate as \(n^{1.5}\)
(n — load factor).

## Stall

Above the critical angle of attack the flow over the time `lift_loss_time_s` goes over to a separated one
(dynamic stall): the sail works as a plate across the flow,

$$
C_L = C_N\sin\alpha\cos\alpha,\qquad C_D = C_N\sin^2\alpha
$$

(\(C_N=2\), like a parachute canopy). After `nose_drop_delay_s` the nose drops by itself by
`nose_drop_deg`, the wing accelerates and leaves the stall; if you keep holding the control frame out, the
stalls repeat. In a bank greater than `wing_drop_bank_deg` — a wing-drop stall: the lowered half-wing
keeps dropping, the roll control is weakened.

## Ground run, take-off, landing

**Ground.** Phases: standing → walking (turn on the spot, walking speed falls on a steep slope) → running
(leg force falls linearly toward the leg limit `speed_max_ms` = 6.5 m/s, which rises by 30 % as the wing
unloads the pilot; the slope and the wing's pull accelerate beyond it). With no input the nose on the ground
sits at the wing's run angle (`launch.alpha_neutral_deg`, 5–17° depending on the wing); the pilot moves it
from there. The wing rests on the shoulders and rolls about the keel axis: a crosswind and a difference of
flows bank it (the slip roll moment ∝ \(0.12\,C_L\), so a lower nose is calmer in a crosswind), the hand
holds the bank within ±15° with limited force. Lift-off only when the vertical component of lift ≥ weight
and the wing is not stalled; without running and wind the wing does not lift off, in calm air the pilot
runs as long as needed. There is a single take-off failure — the half-wing lowered by the bank touches the
ground (the wing is overturned). Nose too high, nose too low and a tailwind give no separate failures:
there is simply not enough lift and no lift-off. After lift-off the pilot is still on his feet while his
soles are below 1 m above the ground: the arms set the angle of attack, and a touch resumes the run rather
than counting as a landing.

**Flare.** Below 4 m above the feet, a control frame "pushed out" beyond a threshold sets the keel to a
pitch of up to 50° to the horizon in 0.1 s; the nose does not drop in this stall. The sail at a
post-critical angle briefly brakes more strongly than the static case (normal force ×3, a short-term rise
of \(C_L\) ×1.5 — the dynamic stall vortex), the wing balloons and "hangs": it lowers the pilot onto his
feet no faster than 0.7 m/s until he has descended 1.6 m — after that the effect ends and the wing drops.
This is a phenomenological model (the dynamic stall vortex, ground effect, the pilot stepping under the
wing — without a physical simulation of the pilot pendulum; in the "Pendulum" mode the landing is computed
from forces). With a correct flare (~1.2·V_stall) the
touchdown is ≈ 1.2 m/s vertical; 1 m higher than the point — still soft (~1.3 m/s); 3 m higher — a "plop"
of ~6.4 m/s, already a hard landing. Into the wind the flare is later (~0.9·V_stall).

**Landing.** The touchdown speed is split into the component normal to the slope ("vertical") and along it
("horizontal"). The thresholds were chosen from the answers of consulting pilots ("from 5 m/s the landing
is already hard, with a correct landing the speed ≈ 0"): soft — vertical < 5 m/s, horizontal ≤ 3 m/s,
bank ≤ 15°; hard — vertical 5…7 m/s or horizontal 3…12 m/s (at trim without a flare — about 10 m/s);
crash — vertical > 7 m/s (twice the impact energy of the hard-landing threshold), horizontal > 12 m/s or
bank > 35°.

![Control frame of the "Apogee": the uprights joint and the hang point](/releases/0.7.0/screenshots/106_трапеция_апогей_стойка_до.jpg "The uprights joint of the control frame on the Soviet \"Apogee\"")

## Model limits

- No slip and yaw as a separate degree of freedom, no moment from rotation in heading — the wing always
  flies "nose into the flow".
- Pitch is kinematic (first order): no control frame and centre-of-gravity moment, only the approach to the
  commanded angle of attack with a time constant.
- No ground effect; on the ground the pilot and the wing are a single point (except the wing's roll on
  the shoulders). In the "Weight shift" and "As before" modes the flare is a phenomenological model,
  without a physical pilot pendulum; the "Pendulum" mode computes it, with other limits: the pilot there is
  a point without body rotation or postures, and the spin and landing in calm air are not calibrated
  against real wings.
- The load factor (n = lift / weight) is computed and smoothed, but wing failure when it is exceeded is
  not modelled.
- The polars are synthesized from the manufacturers' data-sheet reference points (they do not publish full
  measured polars) and by a method verified on a pair of real sizes of one wing.
- The sail tension regulator (VG) is not modelled — the polars of the topless wings are given without it,
  as an "average working" setting; in "Pendulum" this gives a speed ceiling of 45–58 km/h.

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

The handling of each wing is its own, through the same parameters (`weight_shift.*`, `stall.*`): for
example, the "Apogee" is a very stable wing (`roll_stability_per_s` 1.25, `roll_overbank_deg` 75), with
the softest and slowest stall (`lift_loss_time_s` 0.6 s, the nose drops at `nose_drop_delay_s` 0.35 s).
The Icaro Laminar Easy 14, on the contrary, rolls fast (`roll_rate_max_dps` 50), and the topless wings
(`combat`, `sport`) have low stability at small bank (`roll_stability_per_s` 0.45) and a steep spiral
beyond 60°.

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
- No separate new `FlightModel` parameters were introduced for the "Apogee" handling — the current parameters (stability, roll rate, stall parameters) were enough to convey "very
  light and stable, forgives gross mistakes".
- **Wing and pilot as two bodies** instead of one point with kinematic roll: kept as a third, experimental
  mode rather than a replacement — "Weight shift" is simpler, more robust for bots and the network, and
  calibrated against pilots' answers.

## Further reading

- [docs/guide/flight.md](/docs/guide/flight.md) — the full description of the flight model, the
  `FlightModel`/`Glider` API, the visual contract and tests.
- [docs/research/pilot_mass.md](/docs/research/pilot_mass.md) — the derivation of the polar scaling with
  mass and the check against data-sheet data.
- [docs/research/pendulum.md](/docs/research/pendulum.md) — the "Pendulum" mode: prototype, verification, limits.
- [docs/research/wings_config_sources.md](/docs/research/wings_config_sources.md) — how the data sheets went into the wing configs.
- [docs/research/wing_sources.md](/docs/research/wing_sources.md) — sources on the appearance and
  characteristics of the wings.
- [docs/research/control_frame_refs.md](/docs/research/control_frame_refs.md) — references for the control
  frame and the cockpit view for the 3D models.
- Code: [flight_model.gd](/scripts/flight/flight_model.gd), [wing_polar.gd](/scripts/flight/wing_polar.gd),
  [ground_run.gd](/scripts/flight/ground_run.gd), [landing_flare.gd](/scripts/flight/landing_flare.gd),
  [pendulum_model.gd](/scripts/flight/pendulum/pendulum_model.gd).
