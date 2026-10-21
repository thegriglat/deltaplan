---
title: "Motion platforms"
weight: 100
description: "Pilot motion output to a motion platform over UDP (DOF Reality via Sim Racing Studio, Generic format): what the game sends, how to enable it and what is not verified on hardware."
---

# Motion platforms

The game can send the pilot's motion to a motion platform over UDP: to DOF Reality through Sim Racing Studio (SRS) and, in its own Generic format, to home-built receivers. It sends "honest" physical pilot quantities with no filters or scaling; converting them into actuator travel (scaling, washout, limits) is done in the platform's software.

## What the game sends

There is a single source: the pilot point in the flight model. Accelerations are the velocity difference over the interval between packets divided by its duration (an average, unfiltered). The pilot axes are the aviation ones: forward, right, up.

| Quantity | Units | Meaning |
|---|---|---|
| surge, sway, heave | m/s² | specific force, what an accelerometer feels; at rest and in steady gliding heave = +g up |
| yaw | deg | 0 is north, clockwise |
| pitch | deg | nose up > 0 |
| roll | deg | right wing down > 0 |
| roll, pitch, yaw rates | deg/s | in the body frame, Generic format only |
| airspeed, sideslip | m/s | in SRS the speed goes out in km/h |

Expected values from a run in the point model: steady gliding (pitch about 6.6°) gives surge +1.125 m/s² and heave 9.742 m/s²; a steady right turn at 30° bank gives heave 11.249 m/s² (the formula g/cos φ predicted 11.32) and a yaw rate of 26.5 deg/s. Surge in gliding is not zero because the axes are attached to the body and the nose is above the horizon.

## Formats

- **SRS (DOF Reality)** — the default, Sim Racing Studio API v102, a 236-byte packet, port 33001. Accelerations go in m/s²; heave is sent as "heave minus g", so standing on level ground and in steady flight it is about zero. When they went in g, the values were about 1 % of the SRS scale and heave did not move the platform even at maximum gain (fixed in build 1.5.7). SRS does not carry rotation rates.
- **Generic** — the game's own DPMR format, 64 bytes, for home-built receivers (microcontrollers, Python). It carries all the quantities from the table above, a packet number and the flags "data valid" and "on the ground".

SimTools and FlyPT Mover are not supported: SimTools has no general UDP input (it needs a separate plugin for each game), and FlyPT Mover has no universal UDP source.

## How to enable

"Settings → Motion platform" (section "Motion platform"):

- "Motion output" — turn on (off by default; when off nothing is opened or sent);
- "Address (host:port)" — 127.0.0.1:33001 by default; a wrong address turns sending off without errors;
- "Rate" — 60 packets per second by default, not above the physics rate;
- "Format" — "SRS (DOF Reality)" or "Generic";
- "Ease-in, s" — 2.5 by default;
- "Ground accelerations, × (SRS only)" — 0.3 by default;
- "Invert sign of" — nine checkboxes (surge, sway, heave, roll, pitch, yaw and three rates). The SRS signs are not documented, so the player fixes them without a new build. In the SRS format six of the nine apply; the rates are Generic only.

Settings apply immediately, without restarting the flight, and are stored on this computer (not in the Steam cloud). Gain, filters and washout are tuned in SRS.

## A stream without jerks

After build 1.5.7 the DOF Reality owner reported that on spawning on the ground a jerk knocked the actuators. The hypothesis: with no data SRS drops to standby, and the transition from standby to live data gives a jerk that SRS's damping does not absorb. The data itself had no spike at spawn (standing: surge 0.39 m/s², a jump per packet under 0.06 g). So the stream was made continuous:

- while output is on, packets flow always, including in the menu and on pause: there it is neutral (standing on level ground) or the last pose with zero rotation rates;
- if no packet has appeared for over one and a half periods (scene loading, a long frame), a separate thread repeats the last one;
- on any transition (mode change, new flight, settings change, turning on) the values ease from the last packet to the current one over "Ease-in", 2.5 s; turning off is also smooth, to neutral, then silence;
- on the ground, accelerations in the SRS format are multiplied by 0.3 with a rate-of-change limit (0.4 s): the run-up is softer, the touchdown impact (the first ~0.1 s) stays, flight is unchanged.

## What is verified and what is not

Verified by the DOF Reality owner (11 Oct 2026, through SRS): the pitch, roll and yaw axes and signs are right.

Verified without a platform: packet packing (offsets, m/s² units), the stream on the ground and across phase changes with no breaks, parsing of the game's packets by a receiver script, a game-to-receiver loop with ground and flight, and a check of the format description in C and Python.

**Not verified on a real platform:**
- the ease-in and the ground multiplier (added after the feedback);
- slope, run-up, landing, and the absence of a jerk on takeoff and landing;
- the signs of surge, sway and heave;
- how SRS distributes heave for the H4R;
- the needed rate and latency.

How SRS behaves on neutral packets (whether it drops to standby) is unknown: the author has neither a platform nor SRS.

## Where the model lies

- In the control modes without the pendulum (including "Weight shift") the pilot is a single material point: no swing on the suspension, and the angles and rotation rates are the wing's. In the "Pendulum" mode the position and velocity of the pilot's centre of mass and the body orientation on the suspension are taken; this is checked by a test, not tried on hardware.
- There are no filters or washout; values are averages over the interval between packets, not instantaneous.
- Angular acceleration of the head, vibration and turbulence above the physics step rate are not transmitted.
- Sideslip in the point model is about zero.
- Ground contact in the physics is hard: the landing impact is short and sharp, and the platform will feel it.

## Details

- Design, quantities and signs: [docs/guide/motion-rig.md](/docs/guide/motion-rig.md).
- Choice of protocols: [docs/research/motion-rig-protocols.md](/docs/research/motion-rig-protocols.md).
- A receiver for checking without a platform, the player instructions (English) and the format description: [tools/motion_rig/](/tools/motion_rig/README.md).
- History: [CHANGELOG.md](/CHANGELOG.md) — builds 1.5.2, 1.5.7, 1.5.8.
