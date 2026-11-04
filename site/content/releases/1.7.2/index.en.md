---
title: "Deltaplan 1.7.2"
date: 2026-11-04
description: "Bar control: pilot hand rate instead of instant input, clearer mouse sensitivity label."
---

# Deltaplan 1.7.2 — bar control

04.11.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
- **The pilot's hands move the bar at a human rate (0.15 s).** Previously mouse, keyboard and stick input reached the hands instantly, so small hand tremor on the mouse (2–4 Hz) shook the wing almost unfiltered and the glider felt "inflatable". That tremor now reaches the wing about 3.5 times weaker, while a 45→45° roll reversal still takes 4.4–4.8 s.
- **X returns the bar smoothly**, at the same hand rate.
- **Clearer "Bar sensitivity" label**: the number in cm is mouse travel to the stop (at 800 DPI), and a hint shows the direction: right is sharper, left is smoother. Values and range are unchanged.

## Honestly
- The swinging after X on sport wings is the slow pitch oscillation (phugoid) and the turn tightening by itself: these are properties of these wing classes in the model, not a bug of the X key.
- Bots and autopilots control without the hand rate.
- No macOS build: the Rust wind library does not build for macOS yet, Mac stays on 1.6.1.

[itch.io devlog text](/site/content/releases/1.7.2/devlog.txt)
