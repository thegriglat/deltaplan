---
title: "Wing and flight"
weight: 10
description: "How flight is computed: polar, pilot mass, roll and control frame, ground run, stall, landing; a lineup of nine real wings."
---

# Wing and flight

The flight model is not an arcade with a single "speed–lift" curve, but a point mass with orientation
that solves the same equations as a real hang glider: lift and drag from the wing polar, pilot mass,
roll from weight shift, stall, ground run and the flare near the ground. Below is how it is built and
which wings are in the game.

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

Two roll control modes (`controls.json → roll_control_mode`, the "Roll control" setting); in both, the
meaning of `ControlInput.roll` in flight is `ControlInput.weight_shift`.

- **"Weight shift"** (`weight_shift`, the default). Mouse sideways, ←/→ and stick move the bar as on a real wing: bar right — weight left — roll left (the "Roll by mouse and arrows" setting switches to "like the body": right — roll right); one press of X returns the bar to the centre. Roll input (mouse sideways, ←/→, stick) is the
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

The X key ("to centre") in both modes smoothly puts the control frame to neutral and levels the wing to
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
(leg force falls toward the running speed limit, the slope helps, as the wing accelerates it unloads the
pilot). A crosswind banks the wing in the hands, the pilot levels it with the roll input. Lift-off — when
the vertical component of lift ≥ weight. Take-off failures: nose too high/low, a tailwind stronger than
1.5 m/s, sideways drift with the wing banked > 20°, a run that is too weak or too long (> 10 s).

**Flare.** Below 4 m above the feet, a control frame "pushed out" beyond a threshold sets the keel to a
pitch of up to 50° to the horizon in 0.1 s; the nose does not drop in this stall. The sail at a
post-critical angle briefly brakes more strongly than the static case (normal force ×3, a short-term rise
of \(C_L\) ×1.5 — the dynamic stall vortex), the wing balloons and "hangs": it lowers the pilot onto his
feet no faster than 0.7 m/s until he has descended 1.6 m — after that the effect ends and the wing drops.
This is a phenomenological model (the dynamic stall vortex, ground effect, the pilot stepping under the
wing — without a physical simulation of the pilot pendulum). With a correct flare (~1.2·V_stall) the
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
- No ground effect; on the ground the pilot and the wing are a single point. The flare is a
  phenomenological model, without a physical pilot pendulum.
- The polars are synthesized from the manufacturers' data-sheet reference points (they do not publish full
  measured polars) and by a method verified on a pair of real sizes of one wing.
- Limit load factors and wing failure when they are exceeded — not modelled.
- The sail tension regulator (VG) is deliberately not implemented ("pulley systems that tighten the sail —
  we don't bother", an answer of a consulting pilot) — the polars of the topless wings are given without
  it, as an "average working" setting.

## The wing lineup

The game has 48 wings with real prototypes in four groups — in order of increasing glide ratio and of the
wind in which it is comfortable to launch. In the "Flight setup…" menu you first choose a group, then a
model in it. All the wings, their numbers and the "data sheet / analogue / estimate" mark for each — in
the section [Glider models](/wings/). Below are the first nine wings, with which the lineup began.

| Class | id: prototype | Area, m² | Pilot, kg | Stall | Glide ratio | Wind up to, m/s |
|---|---|---|---|---|---|---|
| Soviet 1980s | `slavutich_ut`: Slavutich-UT | 17.46 | 60–90 | 25 km/h | 6.2 @ 34 | 7 |
| Soviet 1980s | `apogee`: "Apogee" (V. Mysenko) | 14.4 | 50–100 | 25.8 km/h | 7.1 @ 36.8 | 10 |
| Soviet 1980s | `atlas`: Soviet "Atlas" (a copy of La Mouette Atlas) | 15.5 | 65–95 | 27 km/h | 8.4 @ 35 | 8 |
| Single-surface trainers | `target`: Aeros Target 16 | 16.2 | 60–100 | 27 km/h | 7.2 @ 34 | 8 |
| Single-surface trainers | `training`: Wills Wing Falcon 170 | 15.8 | 64–100 | 24 km/h | 9.0 @ 38 | 8 |
| Kingposted double-surface | `magic`: Airwave Magic IV 166 | 15.4 | 65–100 | 29 km/h | 10.6 @ 42 | 10 |
| Kingposted double-surface | `laminar`: Icaro Laminar Easy 14 | 14.5 | 65–95 | 30 km/h | 13.2 @ 46 | 10 |
| Topless | `sport`: Moyes Litespeed RS 4 | 14.1 | 74–104 | 27 km/h | 15.0 @ 45 | 12 |
| Topless | `combat`: Aeros Combat GT 13.2 | 13.2 | 70–110 | 30 km/h | 16.0 @ 50 | 12 |

The data — area, span, pilot mass range, reference glide ratio and stall speed — are compiled from
manufacturers' data sheets, club tables, Wikipedia and (for the "Apogee", about which almost nothing
exists in open sources) the answers of a consulting pilot; the full table of sources with reliability
marks — [docs/archive/plan/wings-lineup.md §1](/docs/archive/plan/wings-lineup.md), the polars and
parameters of each wing — [docs/research/pilot_mass.md](/docs/research/pilot_mass.md) and
`configs/wings/*.json`.

The handling of each wing is its own (through the existing `FlightModel` parameters, no new ones were
needed): for example, the "Apogee" is the most stable wing in the set (`roll_stability_per_s` 1.25 versus
0.75–1.1 for the others, `roll_overbank_deg` 75), with the softest and slowest stall (`lift_loss_time_s`
0.6 s, the nose drops earlier — at `nose_drop_delay_s` 0.35 s). The Icaro Laminar, on the contrary, has
light and fast roll (`roll_rate_max_dps` 50). The Aeros Combat GT is the "stiffest" and sharpest-in-roll
wing of the set.

![Icaro Piuma from behind in flight](/docs/screenshots/site/06_icaro_piuma_сзади.jpg "Icaro Piuma, a kingposted trainer")

![Wills Wing T2C from behind in flight](/docs/screenshots/site/08_ww_t2c_сзади.jpg "Wills Wing T2C, a topless wing")

### Which options were considered

The initial request was a broad lineup of real wings by class, based on the models that the consulting
pilots flew. Further decisions:

- **The sail tension regulator (VG)** was considered separately (§5 of the plan): per the Wills Wing T2C
  and Aeros Combat manuals, the glide ratio with VG rises by about 10–15 % at 55–80 km/h, but the handling
  becomes noticeably heavier and slower in roll. Rejected by the user's decision — the card was cancelled,
  the polars of the topless wings are given without VG.
- **The Laminar prototype** was at first listed as topless; per the clarification of a consulting pilot, it
  is a kingposted wing of the Aeros/Airwave Magic class, and moved to the kingposted class.
- **Terminology**: "kingposted/topless" instead of the older "keeled/keelless" — the same distinction in
  substance (the presence of a kingpost with top wires), but the term is more precise.
- **Wills Wing Sport 2** was in the set as the prototype of the kingposted class, but was removed from the
  game by the user's decision of 28 September 2026: the config, the 3D model and the name key were
  deleted, the id `kingpost` in tests was replaced with `laminar` ({{< commit 8633fa7 >}},
  {{< commit e2704c4 >}}) with no compatibility layer for saved settings — "there are no users".
- New `FlightModel` parameters for the "Apogee" handling were also considered separately (card 4), but
  cancelled — the current parameters (stability, roll rate, stall parameters) were enough to convey "very
  light and stable, forgives gross mistakes".

## Further reading

- [docs/guide/flight.md](/docs/guide/flight.md) — the full description of the flight model, the
  `FlightModel`/`Glider` API, the visual contract and tests.
- [docs/research/pilot_mass.md](/docs/research/pilot_mass.md) — the derivation of the polar scaling with
  mass and the check against data-sheet data.
- [docs/archive/plan/wings-lineup.md](/docs/archive/plan/wings-lineup.md) — the research on each wing
  (sources, reliability marks), the choice of the set and of the handling parameters.
- [docs/research/wing_sources.md](/docs/research/wing_sources.md) — sources on the appearance and
  characteristics of the wings.
- [docs/research/control_frame_refs.md](/docs/research/control_frame_refs.md) — references for the control
  frame and the cockpit view for the 3D models.
- Code: [flight_model.gd](/scripts/flight/flight_model.gd), [wing_polar.gd](/scripts/flight/wing_polar.gd),
  [ground_run.gd](/scripts/flight/ground_run.gd), [landing_flare.gd](/scripts/flight/landing_flare.gd).
