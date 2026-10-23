---
title: "Deltaplan 1.6.0"
date: 2026-10-24
description: "A trike to fly yourself, winch and trike aerotow, sunsets and clouds from atmospheric physics, local ERA5 climate, GPU switches."
cover: screenshots/01_кучевые_у_маттерхорна.jpg
captions:
  "01_кучевые_у_маттерхорна.jpg": "Cumulus by the Matterhorn"
  "02_облака_разного_размера.jpg": "Clouds of different sizes"
  "03_дельталёт.jpg": "The trike"
  "04_закат_у_эльбруса.jpg": "Sunset by Elbrus"
  "05_красное_солнце_у_горизонта.jpg": "Red sun at the horizon"
  "06_рельеф_снега.jpg": "Snow relief on a steep slope"
  "07_фудзи_за_спиной.jpg": "Fuji behind"
---

# Deltaplan 1.6.0 — trike, towing and a physical sky

24.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new

### New ways to get airborne
- **Start choice window.** "Fly" (and "Fly from here" on the map) asks: "Hang glider" (no tow, winch or aerotow) or "Trike". Works at any location; terrain is not checked — on a steep slope the line or the tug may hit the ground. Single player only.
- **A trike to fly yourself.** Start on wheels with the engine off and a full 53 l tank. W/S — throttle, Space — start/stop the engine, A/D — steer on the ground, Shift — brake. Pendulum physics, Rotax 582 thrust along the propeller axis (1587 N static), tachometer and fuel gauge on the panel (visible from the cockpit) and in the HUD, synthesized engine sound.
- **Winch tow.** W takes up the slack and tensions the line (41 daN on the ground, then 80 daN), you have to run to lift off; B (gamepad X/□) releases, the 125 daN weak link breaks by itself.
- **Aerotow behind a trike instead of the An-2.** The tug flies on the same physics with an autopilot: takeoff roll, climb at 60 km/h, left circuits from 150 m, breaks away after release. 80 m line; the An-2 stays as an easter egg.

### Sky and light
- **Clouds without steps and "popcorn".** Cumulus of different sizes with round tops instead of flat-roofed columns; soft cloud edges, bases that fade instead of a flat cut.
- **Sunset from atmospheric physics.** Sun color, terrain light, haze and clouds come from atmospheric transmittance (Rayleigh + haze), not hand-made tables: white sun by day, deep red at the horizon; cloud bases redden at sunset, high clouds stay lit after the sun has set on the ground; sunset exposure adapts smoothly.
- **Sun at the horizon** keeps its size, with a narrow halo and a glare like on a photo; the halo no longer spills over the mountains.
- **Haze by humidity:** in humid places the morning is noticeably murkier, and it thickens toward evening as humidity rises while the air cools.

### Local weather
- **ERA5 climate by location and month** instead of one Altai table: dew point, 700 hPa air, daily maximum and daily range, thunderstorm ceiling and cirrus. Cloud base and day strength now depend on where and when you fly.
- **Wind growth with height** — from the forecast wind at launch to the 700 hPa wind from the local climate.

### Mountains
- Steep rock faces without horizontal grey bands; snow on peaks with gullies down the slope and large-scale undulation.
- **Snow plumes off ridges:** in strong wind snow dust blows off snowy crests.

### Controls
- **Pendulum only.** The "Roll control" setting and the "Weight shift" and "Simple" modes are gone — you always fly a wing with the pilot hanging below.
- **Mouse bar:** travel is counted in mouse counts (≈ 7.9 cm to full travel at 800 DPI instead of 1.5 cm), new "Bar sensitivity" slider; the right button no longer sticks after menus and pause.
- **Spin:** all reference wings recover, `sport` included — full pull-in and opposite to the rotation, then center; the guide explains how to do it with the mouse.

### Graphics card and crashes
- **Switches in Settings → Graphics:** sun shadows, cloud shadows on the ground, glow, simple clouds without compute shaders, renderer choice (Vulkan / DirectX 12 / Metal).
- **Window after a crash:** if the last run broke off or the graphics card stopped responding, the game offers to switch the renderer, turn on "Safe graphics" or try again.
- Crash reports collect graphics driver diagnostics by themselves; GPU wind errors no longer crash the game — it falls back to simplified wind.

### Other
- Main menu backgrounds reshot with the new clouds.

Honestly: trike thrust and line forces are calculated (±15 %), not measured; the tug is still faster than a real one at full throttle (≈ 70 km/h instead of 55–65); fog is not modeled; the cause of crashes on some AMD cards is not found yet — the switches are there to find it.

## Screenshots
{{< gallery >}}

[Itch.io devlog text](/site/content/releases/1.6.0/devlog.txt)
