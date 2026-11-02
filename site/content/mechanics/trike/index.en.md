---
title: "Trike and towing"
weight: 20
description: "The powered trike as the player's aircraft (wheels, engine, fuel, gauges) and towing a hang glider behind a tug trike or a winch: how it works, controls, numbers and model limits."
---

# Trike and towing

Besides the ordinary hang glider the game has two ways to take off without a hill: fly a trike yourself (a powered cart with a
propeller under the wing), or be towed on a rope behind another trike (or a winch). The author's parents are pilots, which gave the
idea its start; this page is about how it works in the game and where the model is simplified.

## How it works

- **The player's trike** is a cart (Rotax 582, 1.8 m propeller) hanging under an Air Creation iXess 15 wing. The physics is the same
  as for the hang glider (the "Pendulum" model, see [Wing and flight](/mechanics/flight/)): a wing and a loaded body on a hang
  point, except that the body is a cart treated as a point mass, plus propeller thrust, wheels and an engine.
- **Towing** is a rope between the player's hang glider and a tug. The tug is also a trike on the same model, flown by an
  autopilot. A second kind is a winch at the end of the runway.
- A trike and towing do not combine: you either fly the trike yourself, or a hang glider (on a rope or not). Single player only: in
  multiplayer there is no choice window and you always fly the hang glider.

## How to start

"Fly" (and "Fly from here" in the map view) opens the "Start" window:

| Choice | Result |
|---|---|
| "Tow (hang glider)" row: "None" | ordinary hang glider start |
| "Winch" | hang glider on a dolly, rope to a winch at the end of the runway |
| "Aerotow (trike)" | hang glider on a dolly, a tug stands one rope length ahead |
| "Trike" button | you are in the powered cart on its wheels, no rope |

- The tow row lists the kinds the chosen start site has; a place without sites and a point picked on the map offer all kinds. Quick
  start from favourites skips the window and flies as saved.
- Command line: `--vehicle=trike` (trike), `--tow=winch_static`, `--tow=aerotow`, `--tow=none`.
- A trike and towing work at any place: the line runs from the start point along the place's heading. The game does **not** check
  the terrain: slope, height difference, forest or water do not stop the start; on a steep slope the cart just rolls away.
- The trike is placed on its wheels at the start point, heading of the place, engine off, tank full. The wing cannot be chosen: it
  is always the iXess 15. "Again" (R) puts you back on the wheels at the start of the line.
- The built-in place with ready towing runways is Wilotree Park (Quest Air), Florida: two 610 × 35 m runways, headings 356.8° and
  176.8°, kinds "winch" and "aerotow".

## Trike controls

| Action | Key | Note |
|---|---|---|
| Throttle: more / less | W / S | on the ground and in the air; both together — zero |
| Start / stop the engine | Space | will not start with an empty tank |
| Nosewheel steering | A / D | on the ground only |
| Wheel brake | Shift | on the ground only; in the air Shift is "pull in", as on the hang glider |
| Control bar (pitch, roll) | mouse / stick | no keyboard for the bar |
| Look around | mouse, right button held | no keyboard look: W/S are the throttle |

Everything else (camera, instrument pages, R, Esc, pause) is as on the hang glider. There is no walking or running: the pilot sits.
Help is in the controls window, section "Trike (powered mode)".

## Engine and fuel

States: off → starting → running → stopping → off.

- **Space** from "off" (fuel left) runs the starter: revs rise linearly to idle in 3 s. Space while starting or running stops the
  engine: revs fall linearly in 4 s; Space does nothing while it is stopping.
- **Throttle lever** 0…1; holding W/S moves it at 0.5 per second (full travel 2 s). The lever moves with the engine off too; after
  start the revs go to whatever it sets.
- **Revs and thrust** come from tables that depend on airspeed. Propeller revs: idle 576, full throttle 1614 rpm static and 1790
  at 35 m/s. Gearbox 3.47 : 1; **the tachometer shows engine revs**, as on real Rotax 582 trikes.
- **Thrust** (calculated, ±15 %): 1587 N static at full throttle, 1352 N at 60 km/h (table interpolation), 966 N at 35 m/s; at idle
  202 N static and 0 above 22 m/s. While starting or stopping thrust ∝ (revs)². The thrust axis is tilted 2° up.
- **Fuel burn** (l/h by engine revs): 2000 → 2.0; 3000 → 2.8; 4000 → 5.5; 5000 → 10.8; 6200 → 20.5; 6500 → 23.5; 6800 → 26.5;
  linear in between. Tank 53 l, density 0.75 kg/l. A full tank lasts 2–4 hours.
- **Tank empty** — the engine dies, thrust 0, then you glide; it will not start without fuel.

## Wheels: steering, brake, landing

The wheel mode is the same code as the tug's cart.

- **Steering** is bicycle kinematics: `dψ/dt = v·tan(turn·35°)/1.8 m` (1.8 m is the wheelbase), tyre lateral force no more than
  `0.4·g`. The cart does not turn standing still; there is no reverse.
- **Brake** — deceleration `0.3·N/m` on top of rolling (≈ 0.3 g).
- **Take-off run.** Rolling on grass: coefficient 0.07, centre of mass 0.8 m above the ground. In the control test (full throttle,
  bar pushed out by a simple controller): run 34–35 m in 9.2–9.3 s, lift-off at 15.3–15.5 m/s. The Wilotree Park runway is 610 m.
- **Landing.** Touching down on the wheels brings the wheel mode back: horizontal speed is kept, vertical speed is removed, lateral
  speed is lost. You can take off again from the wheels. There is **no crash** on the wheels however hard you land; a wing or keel
  touching the ground is a crash, as on the hang glider.
- **End of flight**: after the first lift-off and a landing, ground speed below 0.5 m/s continuously for ≥ 3 s (taxiing after
  landing is allowed). The flight does not end before the first lift-off.

## Gauges, view, sound

- Two gauges: a **tachometer** 0…8000 rpm of the engine (green arc 2000–6500, red line 6800 — per the Rotax manual; the end of the
  scale is an estimate) and a **fuel gauge** 0…53 l with E and F marks. In the cockpit they sit on the cart's panel; in the
  third-person view they are in the right column with the tablet; hidden in the cockpit view.
- The cockpit view is from the seated pilot's head. The pilot's body is not visible from the cockpit. The propeller spins with revs.
- The sound is procedural: engine firings (by revs), the propeller blade frequency, exhaust. Loudness in the cockpit is 3 dB below
  the tug's. On pause and in menus the engine sound is silent.

## Towing behind a trike

The player stands on a **dolly** under the hang glider (keel cradle at 18°, dolly mass 25 kg, rolling coefficient 0.06), the tug is
80 m ahead (the rope length). Nothing happens until you press W: the rope lies slack.

- **W** starts the tug (on a gamepad, the run button). **Shift** does not start the rope: it is the ordinary launch run.
- **B** (gamepad X/□) releases. Outside towing it does nothing. Release also happens by itself when the weak link breaks.
- You fly the wing with the mouse or stick; there is no keyboard for pitch and roll. After lift-off the dolly stays on the runway.
- "Again" and "To start" in the middle of a tow reset the rope: it lies slack again and waits for W.

**What the tug does** (an autopilot; the same inputs as a human — bar and throttle):

| Phase | What happens |
|---|---|
| waiting | stands on its wheels, idle, waits for W |
| taking up slack | taxis at low throttle (1 m/s) until the rope tightens |
| run | full throttle; wheels stay down until the hang glider is above 3 m or speed above 56 km/h; then lift-off |
| climb | full throttle, towing speed 63 km/h; above 152 m throttle is reduced so the climb does not exceed 3.05 m/s |
| circuit | from 150 m left-hand circuits, bank 8° |
| away | after release or a break: throttle 0.35, straight on, the model is removed after 15 s |

**Rope** (aerotow): polypropylene/polyester, stiffness `EA = 3·10⁴ N`, 0.014 kg/m, weak link 125 daN, length 80 m, initial slack
3 m. A 50/50 bridle: half the tension goes to the pilot, half to the keel. The rope is one-sided (it pulls, does not push) and
damps by stretch rate.

## Winch

The winch stands at the end of the runway one rope length away (up to 1000 m, but no more than the runway). The rope is Dyneema, weak
link 125 daN. The controller holds tension: 41 daN on the ground, 80 daN in the climb, ramp-up over 4 s, maximum reel speed 25 m/s;
rope angle at the top 60°, lock-out when the heading departs from the rope by more than 40°. Release is **B**; afterwards the rope
with its drogue parachute stays on the ground.

## Physics and assumptions

- **The cart is a point mass** on the hang point (for the tug: cart 150 kg + pilot 82.5 kg + fuel 30 kg = 262.5 kg without the
  wing). The centre of mass is 1.71 m below the hang point, cart CdA 0.82 m².
- **Thrust** acts along the propeller axis 1.40 m below the hang point and is split between the cart and the hang point by the lever
  rule: 1.40 / 1.71 ≈ 0.82 goes to the cart. This axis height is a fit to the game (the pilot's drawing gives 1.238 m): without it
  speed oscillated undamped at full throttle.
- **The player's trike mass** is ≈ 325 kg: cart 150 kg, pilot (from settings), fuel 53 l · 0.75 = 39.75 kg, the rest is the wing.
  Fuel burn does not change the mass in flight.
- The air is still for the rope: wind does not act on it, and the rope's own drag does not affect the force.
- The aircraft numbers are calculations and open sources (the Rotax manual, BHPA Technical Manual 2024); each number in the config
  has a `_doc` key beside it with the source or an "estimate" mark.

## Model limits

Where the simulator lies or does not know:

- **Thrust and fuel burn are calculated**, not measured: there are no measurements of a 1.8 m propeller on a 582, spread ±15 %. The
  start time (3 s), stop time (4 s), lever travel (2 s) and tachometer scale 8000 are estimates. Cart mass, centre of mass and CdA
  are estimates (±30 % for CdA).
- **Only the standard atmosphere and a fixed-pitch propeller**: altitude, temperature and mixture leaning in a descent do not affect
  power; there is no cold start; the starter time is not limited.
- **No propeller wash on the wing**, no reaction torque or gyroscopics; the drag and windmilling of a stopped propeller are not modelled.
- **Gear impact is not computed**: however hard you land on the wheels, they are "wheels". There is no belly landing. Surface does
  not affect wheel friction (wet grass and asphalt are not modelled); `lat_mu` 0.4, `brake_mu` 0.3 and the 35° nosewheel angle are estimates.
- **"Bar pushed out + full throttle"** (≈ 59 km/h) is close to a stall and barely damped; this is the physics of minimum climb speed
  at full throttle, and the game does not limit it.
- **The tug is a point mass**: there is no rope moment about the cart's centre of mass; thrust does not depend on bank; the place's
  altitude does not affect power; there is no thrust sag during the run. There is no wake behind the tug, although BHPA warns about it.
- **The tug autopilot is not a human**: it was tuned for stability on the tug alone and tied to the `sport` wing; other wings and
  strong wind were not checked.
- **Bridle**: the keel arm is attached at the hang point rather than 5–20 cm ahead of it as in BHPA; on the dolly all the tension
  goes to the pilot.
- **The winch does not move**, there is no operator (no "slower/faster" signals, no knife), no release failure. Not modelled: towing
  by a vehicle, a payout winch, a stepped winch, release dynamics in a bank.
- **Single player only**: there is no trike or towing in multiplayer, and you will not see other pilots on a rope.
- The trees and view at Wilotree Park are the game defaults, not Florida's; there are no landing sites there.

## More

- [The player's trike (guide)](/docs/guide/flight/trike-pilot.md) — keys, engine, wheels, limits.
- [Towing (guide)](/docs/guide/flight/tow.md) — rope, winch, aerotow, place.
- [Wing and flight](/mechanics/flight/) — the Pendulum model shared by the hang glider and the trike.
