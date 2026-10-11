---
title: "Deltaplan 1.5.7"
date: 2026-10-11
description: "Motion rig fix: heave in SRS now moves the platform, and motion data is sent on the ground too."
---

# Deltaplan 1.5.7 — motion rig fix

11.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
**Motion rig (DOF Reality)**
- Heave now moves the platform: accelerations go to SRS in m/s² instead of g — before, they were about 1% of the scale.
- Motion is sent on the ground too: slope, take-off run, touchdown and roll-out. The stream no longer switches on and off at take-off and landing, so there is no jump from that. Gain and filters are set in Sim Racing Studio.
- Where the simulation lies: touchdown itself is stiff in the physics — the landing impact is short and strong, and the platform will feel it.
- Not yet tested: heave and ground motion have not been tried on a real platform.

[itch.io devlog text](/site/content/releases/1.5.7/devlog.txt)
