---
title: "Deltaplan 1.7.1"
date: 2026-11-02
description: "Trike fixes: no lagging cart, a front strut stop, more bar travel and grass bent by the propeller."
---

# Deltaplan 1.7.1 — trike fixes

02.11.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
- **The trike cart in the air is drawn exactly as the physics computes it.** The view used to turn it no faster than 20°/s, so in turns the cart lagged by tens of degrees: it looked twisted relative to the wing, passed through the wing, and the control bar ended up in front of the front strut. The lag is gone — in the cockpit, in third-person view and on the tow tug.
- **Cart pitch in the view fixed**: a sign error had it rotated 8.75° nose down.
- **The front strut stops the bar.** Pushing out no longer goes past the strut; at idle, full push-out hits the stop at about 55 km/h.
- **More pull-in travel** — 0.178 m instead of 0.111, up to the pilot's chest; pull-in pitch is more responsive (7.5°/s instead of 5.9 at idle).
- **Grass bends in the propeller wash** — up to 25 m behind the trike while the propeller pulls and it flies low.
- **Softer mouse bar by default** (about 12.7 cm of mouse travel to the stop at 800 DPI instead of 7.9); the "Bar sensitivity" slider now goes down to ×0.1 for high-DPI mice.
- Site documentation updated to match the current game.

## Honestly
- Trike pull-in pitch control is still stiff; the strut stop stiffness is an estimate.
- No macOS build in this version: the Rust wind library does not build for macOS yet, Mac stays on 1.6.1.

[itch.io devlog text](/site/content/releases/1.7.1/devlog.txt)
