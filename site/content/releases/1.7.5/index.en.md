---
title: "Deltaplan 1.7.5"
date: 2026-11-10
description: "More accurate wind near slopes, thermals as rising bubbles with inflow at the ground, menu wind like a weather forecast."
---

# Deltaplan 1.7.5 — wind near slopes and thermals get more physical

10.11.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
- **Menu wind works like a weather forecast** (10 m over open terrain), not wind at the launch. Wind at the launch is now computed: stronger than the forecast on windward slopes, weaker in the lee. The launch hint shows the wind at the launch. Wind field loading is 1.9–2.4 times faster where a second pass used to run.
- **No more terrain steps in the wind field.** Wind cells are cut by the real terrain of the place (cut cells) on all levels. Valleys next to slopes are no longer blocked by steps, ridge wind is slightly stronger. Field loading on Ongudai takes about 15 % longer; the old field cache is not used.
- **Thermals are rising bubbles.** Within 2 km of the pilot the lift field follows a physical model (Hill's vortex with a plume): air converges to the core near the ground, spreads out under the cloud, and a sink ring surrounds it. Peak lift in the core is about 1.35 times stronger than before.
- **Lee turbulence.** The mixing layer behind a ridge now works on the wind-field path, with coefficients from measurements. Against the Perdigão and Askervein masts and in a flight across a ridge it is nearly the same as the old model.

## Known issues
- Turbulence right behind a ridge is not yet like the real thing: the valley behind a ridge is too calm in the wind field, and separation over small ridges is not resolved.
- No macOS build: the Rust wind library does not build for macOS yet, Mac stays on 1.6.1.

[itch.io devlog text](/site/content/releases/1.7.5/devlog.txt)
