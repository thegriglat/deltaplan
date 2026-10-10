# Deltaplan motion output

## What it is

Deltaplan can send the pilot's motion over UDP to a motion platform or to your own receiver. The numbers are honest physics: specific force (acceleration minus gravity) in the pilot's axes, attitude angles and angular rates. The game applies no filtering, washout, scaling or limits. Do that in your motion software (Sim Racing Studio or your own code).

Output is sent only while you are flying. In menus and on pause nothing is sent, so a receiver should return the platform to neutral on a timeout.

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

The SRS documentation does not define signs, and we have not tested this on a real platform. If an axis moves the wrong way, either invert it in SRS or tick the matching checkbox in the game (**Settings -> Motion platform -> Invert sign of**). It multiplies the value sent by -1.

| Quantity | Positive direction | SRS field | Invert checkbox |
|---|---|---|---|
| Pitch | nose up | `pitch`, degrees | Pitch |
| Roll | right wing down | `roll`, degrees | Roll |
| Yaw | heading, clockwise from north (SRS: -180..180) | `yaw`, degrees | Yaw |
| Surge | forward force (nose forward) | `longitudinal_acceleration`, g | Surge |
| Sway | force to the right | `lateral_acceleration`, g | Sway |
| Heave | force pressing into the seat | `vertical_acceleration`, g = load factor - 1 g | Heave |
| Sideslip | to the right | `lateral_velocity`, m/s | (none) |
| Airspeed | | `speed`, km/h | (none) |

Heave is the load factor minus 1 g: about 0 in steady flight, positive in a pull-up or a banked turn (load factor about 1/cos(bank): +0.15 g at 30 degrees of bank), negative when unloaded. Surge in steady glide is small but not zero, because the glider flies nose up about 6.6 degrees and the axes are body-fixed (about +0.11 g). Rates (roll, pitch, yaw rate) are not part of the SRS packet; the checkboxes for them affect the Generic format only.

## Generic UDP format

For your own receivers (microcontroller, Python, etc.). In the game choose **Format -> Generic**. One datagram = one sample, 64 bytes, little-endian, no padding. Machine-readable layouts: `motion_generic.h` (C, packed struct with `static_assert`) and `motion_formats.py` (Python, both formats).

| Offset | Type | Field | Units, sign |
|---|---|---|---|
| 0 | char[4] | magic | `DPMR` |
| 4 | uint32 | version | 1 |
| 8 | uint32 | seq | packet number, +1 per packet |
| 12 | uint32 | flags | bit 0 valid, bit 1 on ground |
| 16 | float32 | t | s, flight time |
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
