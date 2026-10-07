---
title: "Deltaplan 1.3.0"
date: 2026-10-07
description: "Wind over terrain is computed by flow regime: slope flow, lee separation, waves, calm, evening drainage, convection; the neural network and ONNX Runtime are gone, Visual C++ is no longer needed."
cover: screenshots/01_стрелки_ветра.jpg
captions:
  "01_стрелки_ветра.jpg": "Wind arrows debug overlay (F5)"
---

# Deltaplan 1.3.0 — wind by flow regime

07.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's included
**Wind over terrain**
- Wind over terrain is computed by flow regime: flow over a slope, separation behind a ridge, lee waves, calm, evening drainage down slopes and valleys, free convection. For slope flow, separation and waves the field is refined by the GPU solver; in calm, strong stability, evening drainage and free convection the field comes from a ready regime model. Site loading is shorter.
- Wind menu "Wind over terrain": "Computed" (regimes + GPU solver) and "Heuristic" (wind profile without terrain). Without a GPU — heuristic.
- In light wind, when the solver does not converge, the field is averaged over the last iterations, and where a regime model leads, its value is used.
- The zone behind a ridge now matches measurements: the hazard is a rotor (reverse flow near the slope, chop, gusts from above) rather than a strong sink.
- The wind neural network is removed: ONNX Runtime and the Visual C++ Redistributable are no longer needed.

**Pilot**
- Launch run: legs run in the running plane with feet under the body; the body leans forward smoothly during the run and straightens in flight.

**Interface**
- English is the default language. Russian is a switch in the main menu or settings, and the choice is remembered.

**Debug**
- Wind arrows (F5) are drawn by the game's own code; the Debug Draw 3D extension is removed.
- Wind regime map layer (F4 in wind debug).

## Screenshots
{{< gallery >}}

[itch.io devlog text](/site/content/releases/1.3.0/devlog.txt)
