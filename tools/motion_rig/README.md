# Deltaplan motion output

## What it is

Deltaplan can send the pilot's motion over UDP to a motion platform or to your own receiver. The numbers are honest physics: specific force (acceleration minus gravity) in the pilot's axes, attitude angles and angular rates. The game applies no filtering, washout, scaling or limits. Do that in your motion software (Sim Racing Studio or your own code).

Packets are sent **all the time while motion output is enabled**: in flight, on the ground, in the menu, on pause, while being towed and while a scene loads. The platform never goes without data, so SRS does not drop to standby and then jump when you appear on the ground (a jerk like that can knock the actuators out). What is sent when:

- **Live**: you are flying or standing/running in the scene. Real motion.
- **Hold**: the scene exists but there is no live motion (pause, inspection, tow, waiting). The last pose is held, angular rates are 0, so the platform stays where it was instead of snapping to level. In the Generic format these packets have flag bit 2 (`synthetic`) set.
- **Neutral**: no flight scene (menus, loading, after leaving a flight): standing on level ground, still (SRS: all accelerations and angles 0, speed 0; yaw keeps the last heading). Also `synthetic`.
- If the game freezes for a moment (loading a scene, a long frame), a separate send thread repeats the last packet about once per period, so the interval between packets stays about 2/rate even then (Generic: own `seq`, `synthetic` set).

On **every transition** (appearing in the scene, menu, pause on/off, restart, teleport, tow start/end, changing settings, enabling output) the values glide from the last sent packet to the new ones over `ramp_s` seconds (smoothstep; angles take the shortest arc). Turning output off glides to neutral first, then goes silent. Quitting the game does not glide. Generic flag bit 3 (`ramp`) is set while a glide is in progress.

Two settings (both under **Settings -> Motion platform**):

- **Ease-in, s** (`ramp_s`, default 2.5, 0 = off): length of the glide above. Raise it if the platform still feels abrupt at transitions; lower it if you want live motion right away. It does not alter motion after the glide ends.
- **Ground accelerations, x** (`ground_accel_scale`, default 0.3, **SRS format only**): multiplies lateral, longitudinal and vertical acceleration while on the ground (take-off run, standing). Angles and speed are not multiplied, so a slope is still felt. SRS has one common gain per axis, so you cannot reduce the strong take-off-run jolts there without losing flight motion; this setting does it in the game. The multiplier changes smoothly (`ground_blend_s`, config only, default 0.4 s) at lift-off and touchdown, so the touchdown impact (the first ~0.1 s) is kept almost fully. 1 = no change. Generic ignores it: use the `on ground` flag in your receiver.

## DOF Reality (H2/H3/H4R/H6) via Sim Racing Studio

1. Sim Racing Studio (SRS, version 1.43.2 or newer) works on Windows only. If the game runs on Linux or macOS, run SRS on a Windows PC in the same network and use that PC's IP address in the game.
2. In SRS: connect the platform, pick your profile, then **Setup -> Telemetry -> Capture Telemetry** (enable it). SRS listens on UDP port 33001 by default (changeable in SRS `config.ini`; then use the same port in the game).
3. In the game: **Settings -> Motion platform**
   - **Motion output**: enable.
   - **Address (host:port)**: `<SRS PC IP>:33001` (or `127.0.0.1:33001` if SRS is on the same PC).
   - **Rate**: 60 Hz is a good start (1 up to the physics rate).
   - **Format**: `SRS (DOF Reality)`.
   - Press Save. It applies immediately; no need to restart the flight.
4. Start a flight. In SRS the telemetry page should show moving values. Tune scales and washout per axis in SRS.

The game sends the Sim Racing Studio API v102 packet (236 bytes, header `api`, game `Deltaplan`, vehicle `Hang glider`).

## Axes and signs

The axes and signs of pitch, roll and yaw were confirmed on a DOF Reality platform. Surge, sway and heave signs are not confirmed yet. If an axis moves the wrong way, either invert it in SRS or tick the matching checkbox in the game (**Settings -> Motion platform -> Invert sign of**). It multiplies the value sent by -1.

| Quantity | Positive direction | SRS field | Invert checkbox |
|---|---|---|---|
| Pitch | nose up | `pitch`, degrees | Pitch |
| Roll | right wing down | `roll`, degrees | Roll |
| Yaw | heading, clockwise from north (SRS: -180..180) | `yaw`, degrees | Yaw |
| Surge | forward force (nose forward) | `longitudinal_acceleration`, m/s^2 | Surge |
| Sway | force to the right | `lateral_acceleration`, m/s^2 | Sway |
| Heave | force pressing into the seat | `vertical_acceleration`, m/s^2 = specific force minus 1 g | Heave |
| Sideslip | to the right | `lateral_velocity`, m/s | (none) |
| Airspeed | | `speed`, km/h | (none) |

Accelerations in the SRS packet are in m/s^2 (earlier builds sent g, about 1 % of the SRS scale, so heave barely moved the platform). Heave is the specific force minus 1 g: about 0 in steady flight and standing on level ground, positive in a pull-up or a banked turn (about +1.5 m/s^2 at 30 degrees of bank), negative when unloaded. On the ground the same quantities are sent: standing still on a slope gives a tilted pose with surge/sway/heave from the tilted gravity, running and landing give real accelerations (a hard touchdown peaks at tens of m/s^2). Surge in steady glide is small but not zero, because the glider flies nose up about 6.6 degrees and the axes are body-fixed (about +1.1 m/s^2). Gain, scaling and filters (washout) are set in SRS, not in the game. Rates (roll, pitch, yaw rate) are not part of the SRS packet; the checkboxes for them affect the Generic format only.

## Generic UDP format

For your own receivers (microcontroller, Python, etc.). In the game choose **Format -> Generic**. One datagram = one sample, 64 bytes, little-endian, no padding. Machine-readable layouts: `motion_generic.h` (C, packed struct with `static_assert`) and `motion_formats.py` (Python, both formats).

| Offset | Type | Field | Units, sign |
|---|---|---|---|
| 0 | char[4] | magic | `DPMR` |
| 4 | uint32 | version | 2 |
| 8 | uint32 | seq | packet number, +1 per packet |
| 12 | uint32 | flags | bit 0 valid, bit 1 on ground, bit 2 synthetic (hold, neutral or repeat during a freeze), bit 3 ramp (glide in progress) |
| 16 | float32 | t | s, flight time (held at the last live value in hold/neutral) |
| 20 | float32 | surge | m/s^2, specific force forward (nose forward > 0) |
| 24 | float32 | sway | m/s^2, to the right > 0 |
| 28 | float32 | heave | m/s^2, up (into the seat) > 0; level flight about +9.8 |
| 32 | float32 | roll | deg, right wing down > 0, (-180, 180] |
| 36 | float32 | pitch | deg, nose up > 0, [-90, 90] |
| 40 | float32 | yaw | deg, 0 = north, clockwise, [0, 360) |
| 44 | float32 | roll_rate | deg/s, right wing down > 0 |
| 48 | float32 | pitch_rate | deg/s, nose up > 0 |
| 52 | float32 | yaw_rate | deg/s, nose right > 0 |
| 56 | float32 | airspeed | m/s |
| 60 | float32 | air_lateral | m/s, sideslip to the right > 0 |

The invert checkboxes apply to the corresponding field (yaw is negated and wrapped back to [0, 360)).

## Testing without hardware

You need Python 3 only (standard library).

```
python3 recv.py --selftest                     # check packet parsing, no game needed
python3 recv.py --port 33001                   # print incoming packets (format detected automatically)
python3 recv.py --port 33001 --format generic  # force a format
python3 recv.py --port 33001 --jsonl out.jsonl --count 600 --timeout 30   # also log to a file, stop after 600 packets or 30 s
```

Set the address in the game to `127.0.0.1:33001` (or the receiving PC) and fly. `--bind 0.0.0.0` accepts packets from other PCs. Add `--quiet` to suppress printing.

## SimTools / FlyPT Mover

Not supported yet: SimTools needs a per-game plugin (dll), and FlyPT Mover has no generic UDP input. If you need them, use the Generic format as a basis for a plugin.

See also: [build your own control bar](../control_bar/README.md) (a joystick as the control bar input).
