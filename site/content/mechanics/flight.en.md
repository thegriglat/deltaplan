---
title: "Wing and flight"
weight: 10
description: "How flight is computed in the Pendulum mode: a wing of 16 strips, a pilot on the hang chain, arms, ground, stall and spin, controls and the control frame, speed feel, telltales, model limits; the older modes; groups and classes of 48 wings."
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

The wing is steered by the mouse, the gamepad stick and the home-made control frame (a USB joystick, see below);
there is no pitch or roll from the keyboard, neither in flight nor on the ground. The mouse steers while it is captured (the M key);
W/S/A/D never move the wing: in flight they turn the head, on the ground they walk and turn on the spot. Shift in
flight is the extra pull-in. What the input means in "Pendulum":

- Roll right or left — the target displacement of the pilot across the bar up to ±0.45 m; the arms pull the
  pilot to the target (a spring with damping). The technique is as in real life: move the body — the wing
  banks and turns.
- "Pull in" — the pilot forward up to 0.45 m, "push out" — back up to 0.30 m (push out — nose up, braking;
  pull in — acceleration).
- **Extra pull-in**: Shift (mouse) or the gamepad's right bumper — the pilot pulls up to the hips, 0.7 m (from the
  T2C manual); on release the limit returns smoothly to 0.45 m at 0.5 m/s. A home-built control frame gives the full
  travel at once. Beyond the usual limit the suspension indicator is red. Speed at full pull-in with the extra
  pull-in: a median of 0.98 of the passport Vmax at VG 0 over 48 wings (the lowest tenth is below 0.90; before it was
  0.69–0.73), without it 0.785. For this the pitch stiffness below trim is halved (one number for every wing); trim
  did not change.
- A neutral bar in straight flight is the wing's trim; a released bar — the wing flies straight.

![Vmax at full pull-in over 48 wings](/tools/research/pendulum/out/vm2/fig/vmax_48.png "Vmax at full pull-in: grey — before the change (0.45 m), blue — with the softened pitch stiffness at the same travel, red — with the extra pull-in; black dash — the passport value at VG 0. The red bars use a 0.95 m extra pull-in (the VM-2 bench); the game uses 0.7 m, and over 48 wings the median is 0.98 of the passport")

Without the change (grey bars) almost every wing falls short of the passport speed, and with the softened stiffness
and the extra pull-in (red) they come up to the black dashes; for some wings the bar is still above or below the
dash — one number fitted to the whole fleet.

![Pitching moment Cm(alpha) of the wing: old and nonlinear](/tools/research/pendulum/out/vm2/fig/cm_alpha.png "Pitching moment about the hang point against the keel angle of attack: grey — the old one, red — the nonlinear one. Above about 10–12 degrees the curves coincide (trim did not change), below it the red one is flatter: pulled in, the wing accelerates more readily")

### Pilot displacement indicator

At the bottom centre of the screen is a circle with a crosshair, in every control mode and camera (since version 1.5.8).
The dot shows where the pilot's body is relative to the hang point: forward or back — pushing or pulling, sideways —
roll; at the centre the pilot hangs with no effort. It can be switched off in the interface settings. The indicator
shows how far the body is from neutral and whether the travel has reached its limit.

![Pilot displacement indicator, first-person view](/releases/1.5.8/screenshots/01_индикатор_смещения_от_первого_лица.jpg "The indicator at the bottom centre: a circle with a crosshair and a dot — the body position relative to the hang point")

![Pilot displacement indicator, third-person view](/releases/1.5.8/screenshots/02_индикатор_смещения_от_третьего_лица.jpg "The same indicator with the third-person camera")

### Home-made control frame (USB joystick)

The game accepts any USB joystick with two axes: stick sideways gives roll, forward and back gives pitch, like a
gamepad stick. There is no custom protocol and no driver: the board shows up to the computer as a game controller,
and the sensors are its axes. The settings are in "Settings → Controls → Control bar / joystick" (since version 1.5.2):
the device ("first connected" or a specific one), the roll and pitch axes, inversion of each axis, dead zone,
expo, calibration of the neutral and the end positions, a position indicator. If the chosen device is not plugged
in, the mouse and keyboard keep working. Expo is best left at zero for a control frame: it has a real position,
not a centring spring.

- **Board.** An Arduino Leonardo or Pro Micro (ATmega32U4) with the ArduinoJoystickLibrary will do: one short sketch,
  a few dollars; a variant with no programming is the FreeJoy firmware on an STM32 "Blue Pill" (calibration and
  smoothing in the board itself) or a ready-made board such as the Leo Bodnar BU0836.
- **Sensors.** Potentiometers are the simplest start (the contact wears out); a contactless magnetic AS5600 (12 bit)
  can be programmed to an angle from 18° to 360°, so that a short stick travel uses the whole range. The 10-bit ADC
  of the ATmega32U4 (1024 steps) is enough for a travel of about 60°: ≈ 0.06° per step.
- **Godot 4.5+** passes the raw axes of an unknown HID by index (SDL3); the axis order depends on the board — check
  it with the indicator.

Limits. No ready-made hang glider control frames or simulators that support them were found: there is no standard,
and the sources give no geometry or travel of a real frame — it is set by the author's own frame. The axis order and
the behaviour on all three systems were checked against the documentation, not on hardware; sensor latency and
jitter were not measured. Research: [docs/research/control-bar-input.md](/docs/research/control-bar-input.md).

### The "Vehicle" tab

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
- **Crosswind while standing.** The arm moment on the ground is at most (moment limit)·(share of weight on the legs):
  the more the wing unloads the legs, the weaker the arm. The side gust that a pilot on `sport` can still hold while
  standing, with a 4 m/s headwind, is 1.90 m/s; with a 6 m/s headwind it is only 0.6–1.0 m/s: the legs are unloaded
  and the arm weakens. This is physics, not a defect. A sidestep and body posture are not modelled.
- **Launch clearing.** Around the start the clearing radius is at least two run lengths; only trees are removed
  (forest becomes grass), bushes stay. The smallest wing clearance above the terrain on every start at zero bank is
  0.58 m; it is negative only on an oblique slope when turning across it and after lift-off with the roll held
  (bank 39–50°).

![The run and lift-off: lift, strap tension, share of weight on the legs](/tools/research/pendulum/out/fig/ground_run.png "A run on a 15° slope in calm air, three classes: lift (blue) grows with speed, the share of weight on the legs (green) falls to zero, and the strap (orange) takes the weight — the legs lose the ground at 5–6.4 s. This is a prototype plot; it disagrees with the game numbers in the text above (lift-off 2.8–3.4 s), the reason was not investigated; the shape of the process is the same")
- **Flare.** Near the ground "push out" raises the nose, but the arm travel is limited by the reach of a
  standing pilot (grip 0.5 m below the hang point, arm 0.71 m).
- **Landing on the feet.** The knees absorb the vertical speed: a squat of up to 0.3 m
  (since 1.5.8) — a landing at 3.5 m/s down gives about 4 g instead of 22–44 g, 1 m/s — under 2 g, at 5.5 m/s the leg
  travel runs out and the impact is 10–15 g; the landing rating (soft/hard/crash) did not change. A crash does not
  stop the pilot in one step: the speed is shed at about 20 g. Thresholds on vertical speed and bank are the
  same as in the other modes: soft — vertical < 5 m/s, bank ≤ 15°; hard — vertical 5…7 m/s; crash —
  vertical > 7 m/s or bank > 35°. The thresholds were set from consulting pilots' answers ("from 5 m/s the
  landing is already hard"). The legs decide on the horizontal speed: up to 2 m/s the pilot stands, up to
  5 m/s he runs it out (a step every 0.33 s), faster — he cannot run it out, a hard landing. Touching with the
  control frame before the feet is a hard landing; with the nose, a half-wing or the tail — a crash. After the
  landing the pilot is on his feet again.

![Control frame of the "Apogee": the upright joint and the hang point](/releases/0.7.0/screenshots/106_трапеция_апогей_стойка_до.jpg "The upright joint of the control frame on the Soviet Apogee")

### Exiting a pull-in without a tumble

Returning the bar to the centre at high speed after a full pull-in is dangerous: the wing may go into a tumble. Since
version 1.5.21 the arms release the pilot along the keel at that moment, and the wing returns to trim; the numbers
over 48 wings are in "Model limits".

![Recovery from acceleration on the Laminar wing: before and after the change](/tools/research/pendulum/out/vm6/fig/release_laminar.png "Laminar, the VM-6 bench: pitch, angle of attack and the pilot position along the keel after an exit from 1.8·Vtrim (left) and after a smooth exit (right). Red — the game before the change: pitch crosses −60° (dashed), the pilot jerks along the keel. Blue — a variant of the change close to what went into the game: on the left the pitch does not reach the dashed line, on the right the smooth exit still goes below −60° — the remainder, called a Lanchester zoom in the text")

## Stall, wing drop, spin

Stall is computed from the **local** angle of attack of every strip, not of the wing as a whole. A stalled
strip is a finite-aspect-ratio plate (Viterna & Corrigan, \(C_N\) at 90° ≈ 1.2); the centre of pressure moves
back along the chord gradually, over 20° (Fage & Johansen). The half-wing that carries more at a given
sideslip stalls first: in the model's slipping turn it is the **inner** one.

- In a turn of ≈ 30° at low speed with full push-out — a drop onto the inner half-wing, then a spin:
  rotation, yaw up to 94–136°/s, sink rate up to 11–12 m/s. Altitude lost from stall to recovery: trainer
  41 m, kingposted 79 m, topless 65 m.
- **Recovery:** pull in fully and shift the body **against** the rotation until rotation and stall end; then
  the bar to the centre (the arms release the pilot along the keel and the wing returns to trim, no flip).
  Pulling in without shifting against the rotation does not recover, and letting go (input 0) ends the spin
  on no wing. With the mouse: toward you to the stop and sideways against the rotation, then to the centre.
  The mouse does not return to the centre by itself: a released mouse keeps the bar where it was. In the test
  recovery takes 2.2–7.2 s (for `sport` the time depends on the computation step), and the altitude lost on
  recovery for `sport` is 65–78 m.
- **`sport` recovers too.** The 1.5.21 note "`sport` does not recover from a spin" was a test error, not the wing's:
  the test's pilot model held the pull-in at a speed above 1.5·Vtrim and did not return the bar. The input reaches
  the control frame in full (mouse → arms → wing), the 300 N arm limit saturates in a spin but is not the cause:
  at 1000 N the result is the same. Aerodynamics and input were not changed. An open question: should a spin end by
  itself with the controls let go — not investigated
  ([docs/research/pendulum/spin-recovery.md](/docs/research/pendulum/spin-recovery.md)).
- The trainer forgives: with a slow push-out or without pushing to the end one or two root strips stall, the
  wing parachutes (1.6–1.9 m/s), no spin. Kingposted and topless wings spin even then.
- A sharp full pull-in for 3 s with arms to neutral does not leave the wing in a permanent stall: speed returns
  to trim in 1.3–2.2 s, then a damped phugoid follows; no one of the 48 wings stays in a permanent stall.

## Speed feel

Several things convey speed in the cockpit at once; the numbers come from measurements on the flight model and from
the literature ([docs/research/speed-feel.md](/docs/research/speed-feel.md)).

- **Turbulence grows with speed.** For the same gust strength (σ 1 m/s) the load-factor jitter grows as V<sup>1.2–1.5</sup>:
  at about 2·Vtrim it is 2.0–3.1 times larger than at trim (trainer — 62.6 km/h, sport — 80 km/h). Speed is already
  in the physics, so the shake was not multiplied a second time; the rate of twitches in the cockpit grows with
  airspeed (gusts are fixed in space and are met more often), from 0.7 to 2 times the rate at trim. In calm air
  there is no shake at any speed.
- **The nose drops.** From trim to ≈ 2·Vtrim the keel pitch falls by 15–17°: +3.6° → −11.4° for the trainer, +6.6° →
  −8.9° for the sport wing. The cockpit camera does not repeat the wing's pitch, so on acceleration the wing in the
  frame "pecks" by this amount. The pilot's head slowly (over a couple of seconds) repeats 0.3 of the deviation of the
  wing's pitch from trim — on acceleration the horizon in the frame rises by about 4.5°. The coefficient 0.3 (range
  0.1–0.5) is an estimate from physiology (reflexes hold the head weakly below 1 Hz, vision on the horizon helps
  beyond that); there are no direct measurements for a pilot lying in a harness.
- **The telltale** tells speed apart: at low speed it flaps lazily, by 10–12 m/s it flutters across its full width,
  further on it stretches out and trembles finely (at 25 m/s the amplitude is ≈ 0.6 of the full one). The Strouhal
  number of the string is ≈ 0.4 (0.25–0.55) at a length of 0.13 m: the real frequency is 37 Hz at 12 m/s and 77 Hz at
  25 m/s — higher than a screen can show (a 15 Hz ceiling), so speeds above ≈ 5 m/s differ only by amplitude. The
  decay of amplitude as (12/U)<sup>2/3</sup> is an inference by analogy with flags and paper in wind; there is no direct
  measurement for the string.
- **The whistle of the wires** is synthesised on the fly: tone f = 0.2·V/d (the Strouhal number of a cylinder is 0.2,
  wires Ø 2.0–3.2 mm at Wills Wing and Bautek): about 0.7–1.1 kHz at 40 km/h, twice that at 80 km/h. It is audible in
  the cockpit from ≈ 30 km/h, quieter than the general wind noise. The wire thickness in the 3D models (Ø 9 mm) is
  visual, three times the real one, and does not affect the sound.

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
- **No VG.** Sail tightening (+~20 % speed on sport wings) is not modelled. The passport Vmax at VG 0 is reached
  only with the extra pull-in; without it, 0.785 of the passport. The pitch-stiffness reduction is one number for the
  whole fleet, fitted to the median of the passports, not a sail model; the 0.7 m reach comes from one manual. The
  elasticity of the edges and battens is not modelled either.
- **Tumble when coming out of the dive** — partly fixed in 1.5.21, the remainder is physics. The arms release the
  pilot along the keel when the input has returned to exactly 0 after a pull-in (threshold 0.25 of travel, 5 cm of
  swing and one pendulum period — estimates, not measurements); the wing goes to trim with no tumble. The numbers are
  from the CHANGELOG of 1.5.21, each with its scenario, over 48 wings, was → now: an instant release from
  1.8·Vtrim — tumble 29 → 0; a smooth exit from the usual full pull-in — 26 → 4; a smooth exit from Vmax with the
  extra pull-in — 40 → 26 (the plot above is the Laminar, a bench before the final tuning). The remainder is a Lanchester
  zoom, physics: when exiting from twice the trim speed and above the wing makes a loop. Aerodynamics was not changed.
  Analysis: [docs/research/pendulum/release-tumble.md](/docs/research/pendulum/release-tumble.md).
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

- **"Weight shift"** (`weight_shift`). Mouse sideways and the stick set the pilot's position across the
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
- [docs/research/speed-feel.md](/docs/research/speed-feel.md) — speed feel: shake, keel pitch, the string, the wires, the head.
- [docs/research/pendulum/spin-recovery.md](/docs/research/pendulum/spin-recovery.md) — spin recovery, `sport` included.
- [docs/research/pendulum/release-tumble.md](/docs/research/pendulum/release-tumble.md) — the tumble on exiting a pull-in.
- [docs/research/control-bar-input.md](/docs/research/control-bar-input.md) — the home-made control frame as a USB joystick.
- [docs/guide/flight/pendulum.md](/docs/guide/flight/pendulum.md) — how "Pendulum" is built in the game.
- [docs/research/wings_config_sources.md](/docs/research/wings_config_sources.md) — how the data sheets went into the wing configs.
- [docs/research/wing_sources.md](/docs/research/wing_sources.md) — sources on the appearance and
  characteristics of the wings.
- [docs/research/control_frame_refs.md](/docs/research/control_frame_refs.md) — references for the control
  frame and the cockpit view for the 3D models.
- Code: [flight_model.gd](/scripts/flight/flight_model.gd), [wing_polar.gd](/scripts/flight/wing_polar.gd),
  [ground_run.gd](/scripts/flight/ground_run.gd), [landing_flare.gd](/scripts/flight/landing_flare.gd),
  [pendulum_model.gd](/scripts/flight/pendulum/pendulum_model.gd).
