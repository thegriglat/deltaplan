---
title: "Deltaplan 1.5.19"
date: 2026-10-17
description: "Clouds from a shared cloud field, two training islands, flight goals and tracks, faster reloads."
cover: screenshots/01_облака_из_поля.jpg
captions:
  "01_облака_из_поля.jpg": "Cumulus from the cloud field"
  "02_вулканический_остров.jpg": "Volcanic island, crater ridge"
  "03_учебный_остров.jpg": "Training island from above"
  "04_судно_у_берега.jpg": "A ship off the coast"
  "05_люди_в_лагере.jpg": "People at the launch camp"
  "06_цели_полёта.jpg": "Flight goals tab"
  "07_след_прошлой_попытки.jpg": "Last attempt track"
---

# Deltaplan 1.5.19 — clouds from the field, islands and flight goals

17.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new

**Clouds**
- Cumulus are drawn from a shared regional cloud field (400 m grid) instead of one cloud per thermal: a cloud grows where lift reaches the condensation level, lives and decays over minutes and drifts with the wind. Strong days show cloud streets along the wind and more cloud over ridges; weak days give scattered clouds over crests. Lenticulars, caps and storms are unchanged.
- Thermals under cloud shade are weaker; the mixed-layer top partly follows terrain — up to 100–400 m higher over ridges.
- In network play the host shares a cloud field snapshot every 30 s.
- Honestly: over Almaty on a strong day the lowland keeps 0.23 cloud cover instead of clear sky.

**Training: two islands**
- Training island — a fictional 15 × 10 km place: a ridge above the sea, a plain for thermals, a training hill with a target field, a lee bowl with a rotor. Each launch has fixed weather and a pre-baked wind field — loads in under a second.
- Volcanic island on real terrain: sea cliffs, a crater ridge, thermals from the summit, spot landing on the plateau. Available from the Training window only.
- Honestly: there is no trade-wind inversion on the island, so cloud base is higher than in reality.

**Flight goals and tracks**
- A Goals tab in the Flight window: height gain, time aloft, distance, out-and-return, triangle, route, spot landing; levels estimated from the weather at launch time. Goal list in flight, "n of m done" summary and records. Single-player only.
- The flight track is saved as IGC; "last attempt track" shows it as a ribbon in the world: climb red, sink blue. You can load your own `.igc` and `.gpx` files.

**World**
- Ships off sea coasts: a tanker, a bulk carrier and a container ship, 2–6 per place, 3–15 km offshore. Distant sea is at water level, open ocean is water.
- People at the launch camp — four different people with real faces (Microsoft Rocketbox, MIT), visible up to 100 m.
- Thermals no longer start over the sea.

**Loading and physics**
- Reloading a place is faster: the wind field comes from a disk cache (Ongudai 12.5 s instead of 29, a map point 18 s instead of 40), and the loading screen freezes for at most 1–1.5 s. Cache size is in settings (200 MB by default).
- Launching in a lee shadow no longer inflates the wind over the whole map.
- Pendulum control: full bar travel is exactly as configured, top speed at full pull-in is lower, the dive after a sharp pull-in is shallower.
- Forest is no longer cleared under non-existent houses; "Sea here" checks the chosen point.
- Debug layer F7 — surface heat flux.

## Screenshots
{{< gallery >}}

[Itch.io devlog text](/site/content/releases/1.5.19/devlog.txt)
