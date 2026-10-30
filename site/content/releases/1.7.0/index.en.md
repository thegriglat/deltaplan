---
title: "Deltaplan 1.7.0"
date: 2026-10-30
description: "Wind and weather are computed by a Rust library on the CPU instead of shaders on the graphics card."
---

# Deltaplan 1.7.0 — wind without the graphics card

30.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
- **Wind is computed by a Rust library on the CPU.** The wind field over the terrain (the Picard solver), thermals, waves and rotors, thunderstorms, cloud outflow, turbulence and gusts moved into the `dp-air` crate; the game only asks for the wind at the current moment. Wind no longer depends on your graphics card and its driver; the old shader and GDScript wind code is gone.
- **Daily weather lives in the same library.** Dew point, 700 hPa air, wind profile, air and water temperature, sun, sky and haze use the same formulas and ERA5 climate; it matches the old code on every reference set.
- **Wind is always a field.** The "wind without field" mode and the "Wind over terrain" setting are gone; baked island fields (about 45 MB) are no longer needed.
- **The loading screen shows the wind computation.** "Computing wind from terrain…" stage with its own "Iteration: N" line, and "Run r of n" when there are several runs. Wind is no longer zero at a random location.
- **Wind debug layers** F3, F4 and F7 show the field again.
- **Grass in Look around mode** follows the camera while paused.

## Honestly
- Loading a location takes longer on slow CPUs; in weak summer wind (a high gentle launch above a valley) the solver can reach its 3000 iteration limit — the game flies with the field from the last iteration.
- No macOS build in this version: the Rust library does not build for macOS yet, Mac stays on 1.6.1.

[itch.io devlog text](/site/content/releases/1.7.0/devlog.txt)
