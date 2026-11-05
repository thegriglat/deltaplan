---
title: "Deltaplan 1.7.3"
date: 2026-11-05
description: "Air start, scenic places, pilot voice, wingmen, your own sail picture and cleaner cloud views."
---

# Deltaplan 1.7.3 — air start, scenic places and a pilot voice

05.11.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
- **Air start.** In the "Start" window there is now an "In the air" option next to towing, with a "Height above launch" slider (60–1000 m above the terrain, 300 by default). The hang glider is placed above the launch in trimmed equilibrium; "Again" repeats the start. Records, achievements and task records are not counted for such flights, the result screen says so; goals are measured from the start point.
- **Scenic places.** A "Scenic places…" button next to "Popular places" in "Flight settings": 236 natural landscapes in 29 countries (mountains, glaciers, fjords, canyons, volcanoes, lakes), no cities or buildings. Choosing one puts the wing straight into the air above the view, heading towards it. Points over the sea are allowed.
- **Pilot voice.** The pilot sometimes says short lines: takeoff, finding or losing a thermal, sink, turbulence, stall, getting low, entering cloud, turnpoints, goal, landing, spotted easter eggs. Lines are triggered only by what the player has too (vario, speed, g-load, height), not by the hidden wind field. Male and female voice, Russian and English; "Sound → Pilot voice" (male / female / off). The voice is synthetic (Qwen3-TTS, Apache-2.0).
- **Wingmen.** "Wingmen" setting (0–2, 1 by default): the first bots stay close to you, fly towards you and join your thermal. Same physics, no pulling: a wingman that falls low and behind may not catch up. Single player only.
- **Your own sail picture.** In "Flight…" → "Glider" you can pick a PNG or JPEG (up to 20 MB) for your sail; "Original" restores the stock one. Only you see it: it is not sent over the network.
- **Clouds.** The whitish veil when climbing in a clear gap at cloud-layer height is gone: the in-cloud whiteout now uses the clouds that are actually drawn, not the coarse cloud-cover field. At the edge of a cloud the sky no longer jumps in brightness and other clouds no longer change colour. Inside a cloud visibility is about 65 m.
- **Sail animation fixed** for all wings: the lower surface and the chord weighting were swapped; now the leading edge is still and the lower surface moves by its own settings.
- Place picker: the place name and coordinates are on their own line below the buttons.

## Honestly
- The air start begins from equilibrium, not from a manoeuvre: g-load dips 0.95 → 0.83 for about 30 ms right after placement.
- Scenic places were checked by terrain geometry only, not by eye.
- The whiteout boundary follows the coarse cloud shape (no fine erosion or wisps), so it may not match the visible edge exactly; checked on one place and one weather.
- The pilot's tone is only weakly coloured by the synthesizer; not every line was listened to.
- Your sail picture is seen mirrored from below past the edge of the lower surface (as on a real single-surface sail); on 8 wings with a keel pocket the lower surface is narrow.
- No macOS build: the Rust wind library does not build for macOS yet, Mac stays on 1.6.1.

[itch.io devlog text](/site/content/releases/1.7.3/devlog.txt)
