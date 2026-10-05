---
title: Plan archive
weight: 99
description: "Plans and logs of closed Deltaplan work, by module; their findings are in the findings registry."
---

# Archive of plans and logs

Here are plans and logs of work that is closed: the executors have reported, the result is accepted and merged into the game. The documents are attached as they are (the `docs/archive/plan/` folder), without edits; they are not included in the ordinary search over the repository documentation. The results — numbers, decisions and model limits — are collected in the [findings registry](/research/findings/), and usually there is no need to read the whole archive: come here when you need to find out how a particular decision was made.

## Air model

Log and plans of the calibration waves and wind field solver fixes (September–October 2026).

- [Module log](/docs/archive/plan/air-model-progress.md) — decisions, the result of the Morris screening, the analysis at the gate, closing the module.
- [Baseline numbers before the air model](/docs/archive/plan/air-model-baseline.md) (AM-00) — call time, FPS, the "before/after" reference point.
- [Reconnaissance before A2](/docs/archive/plan/air-model-a2pre.md) — convergence and solver cost on the new parameters.
- [A1: structural solver fixes](/docs/archive/plan/air-model-a1.md) — Prandtl number, cooling, layer height.
- [A3: scheme and switches](/docs/archive/plan/air-model-a3.md) — a choice based on the literature.
- [A4: Perdigão, forest and applicability limits](/docs/archive/plan/air-model-a4.md).
- [B1: joint calibration of Askervein and Perdigão](/docs/archive/plan/air-model-b1.md) and [B2: α and λ in the game](/docs/archive/plan/air-model-b2.md).

## Wind neural network and the air model: additions

- [Neural network in the game (air-onnx)](/docs/archive/plan/air-onnx.md) — an ONNX network instead of the solver in the game (release 1.0.5).
- [Neural network pilot P-3](/docs/archive/plan/air-nn-p3.md) — input and output encoding; the result is in the section "0. Result of P3" — and the [air-nn log](/docs/archive/plan/air-nn-progress.md) until 02.10.
- [A2: convergence in calm air](/docs/archive/plan/air-model-a2.md).
- [Prototype of the heat and mass cellular automaton](/docs/archive/plan/heat-ca-prototype.md) — a card; the results are in the [research](/research/heat_ca/).
- [Mass-consistent wind field](/docs/archive/plan/wind-field.md) — superseded by the air model plan.

## Weather, wings, group "Game"

- [Weather from a forecast](/docs/archive/plan/weather-by-temperature.md) and [wing lineup](/docs/archive/plan/wings-lineup.md) (build 0.6.0).
- Group "Game scene and controls": [contents](/docs/archive/plan/game/README.md), [cockpit acceptance](/docs/archive/plan/game/01-priemka-kabiny.md), [end-to-end test](/docs/archive/plan/game/02-skvoznoj-test-svobodnyj.md), [gameplay](/docs/archive/plan/game/03-geimplej-svobodnogo.md), [collisions](/docs/archive/plan/game/05-stolknoveniya.md), [nose on the launch run](/docs/archive/plan/game/06-nos-na-razbege-po-vetru.md).

## Air at the launch site and takeoff physics

- [Air at the launch site](/docs/archive/plan/air-start.md) and its [log](/docs/archive/plan/air-start-progress.md) — a pilot's complaint "it blows me off"; two passes of the field.
- [Wing physics check](/docs/archive/plan/wing-physics-check.md) and its [log](/docs/archive/plan/wing-physics-check-progress.md) — DHV passports against polars.
- [Wing control on the ground](/docs/archive/plan/control-fix.md) and its [log](/docs/archive/plan/control-fix-progress.md); the launch run: [before/after the run-limit fix](/docs/archive/plan/cf1_start/README.md).
- [Launch fixes](/docs/archive/plan/start-fixes.md) and its [log](/docs/archive/plan/start-fixes-progress.md); [wing clearance above the terrain](/docs/archive/plan/sf4_wing_clearance/after_sf3.md).
- [Takeoff failures on a strong day](/docs/archive/plan/flight/01-vzlet-v-silnyj-veter.md).

## Wings and models

- [3D models and wing configs from passports](/docs/archive/plan/wings-models3d.md) and its [log](/docs/archive/plan/wings-models3d-progress.md); the [passports log](/docs/archive/plan/wings-passports-progress.md).
- [The "standing" pose at launch and the 90s variometer](/docs/archive/plan/models/01-poza-stoya-i-variometr.md).

## Interface, site, build

- [Controls in the interface](/docs/archive/plan/ui-controls.md) and its [log](/docs/archive/plan/ui-controls-progress.md).
- [Site update](/docs/archive/plan/site-update.md) and its [log](/docs/archive/plan/site-update-progress.md).
- Group "Interface": [menu and flight](/docs/archive/plan/ui/01-menyu-i-polyot.md), [pause, settings, summary](/docs/archive/plan/ui/02-pauza-nastrojki-itog.md).
- Group "Build": [Linux and verification](/docs/archive/plan/build/01-sborka-linux-proverka.md), [stability matrix](/docs/archive/plan/build/02-stabilnost-matrica.md), [FPS and load time measurements](/docs/archive/plan/build/03-zamery-fps-zagruzka.md).

## Old task groups

Cards from the first days of the project, by code area:

- Atmosphere: [route-flying bot](/docs/archive/plan/atmosphere/01-xc-bot.md), [references from real XC flights](/docs/archive/plan/atmosphere/02-etalony-zamer.md), [calibration of presets by passability](/docs/archive/plan/atmosphere/03-kalibrovka.md), [pilot's words and tests](/docs/archive/plan/atmosphere/04-slova-pilota-testy.md), [slope at launch sites](/docs/archive/plan/atmosphere/05-sklon-na-startah.md), [wave and rotors](/docs/archive/plan/atmosphere/06-volna-proverka.md), [thermal centering by the bot](/docs/archive/plan/atmosphere/07-centrovka-bota.md).
- Terrain: [test stand, frames, GPU measurement](/docs/archive/plan/terrain/01-stend-kadry-zamery.md), [forest and the 10 m edge](/docs/archive/plan/terrain/02-les-kromka-10m.md), [rivers and lakes from OSM](/docs/archive/plan/terrain/03-reki-ozyora-osm.md), [haze and contrast](/docs/archive/plan/terrain/04-dymka-kontrast.md), [gust waves over grass](/docs/archive/plan/terrain/05-veter-volny-poryvov.md), [terrain GPU budget (postponed)](/docs/archive/plan/terrain/06-byudzhet-gpu-relefa.md).
- Vegetation: [grass blade settings](/docs/archive/plan/vegetation/01-nastrojki-travinki.md), [trees by mask and distant tone](/docs/archive/plan/vegetation/02-derevya-po-maske-dalnij-ton.md).
- World objects: [wires, fences, batching](/docs/archive/plan/world_objects/01-provoda-zabory-batching.md).
- Top-level list of groups (superseded): [groups-top-level](/docs/archive/plan/groups-top-level.md).
- Tasks and training — [postponed](/docs/archive/plan/tasks/README.md): the logic is ready, not connected to the game.
