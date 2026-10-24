---
title: "Deltaplan 1.6.1"
date: 2026-10-24
description: "Fixed a crash when changing place after a flight."
---

# Deltaplan 1.6.1 — crash fix when changing place

24.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
- **Fixed a crash when changing place after a flight.** The game crashed when loading another place after flying (for example Kok-Tobe → menu → Yutsa): cars, trees, landing sites, the dog, geese and bots of the previous place still used its unloaded terrain.
- **Fixed "Out of bounds get index" errors after changing place.** Background placement of rocks and forest no longer reads the surface mask while it is being changed; clearings at launch sites now appear all at once.

[itch.io devlog text](/site/content/releases/1.6.1/devlog.txt)
