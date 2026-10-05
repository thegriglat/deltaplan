---
title: Plans
weight: 28
bookCollapseSection: true
description: "Deltaplan development plans: what is in progress or postponed, what is closed, and where to find the results of closed work."
---

# Plans

Plans are working documents of the agents and the author: what was decided to be done, how it was split into tasks, how the result was accepted. They are attached to the site as they are (from the `docs/plan/` and `docs/archive/plan/` folders of the repository), so they are drier and more detailed than the [mechanics](/mechanics/) pages. What came out of the plans and which approaches were tried is on the page ["Approaches and results"](/approaches/); numbers and sources are in the [findings registry](/research/findings/).

The repository follows a rule: `docs/plan/` holds only live and postponed plans, and closed ones move to the [archive](/plans/archive/), with their findings in the registry. The status of each document is recorded in its header (`status`); it is given below as is. State as of 04.10.2026.

## Live and postponed

"Postponed" (`postponed`) means the document is not being worked on now but is not closed; it does not mean that nothing has been done. "Idea" (`idea`) means not started.

| Plan | Status in header | What is done and what remains |
|---|---|---|
| [Neural network instead of the wind field solver](/docs/plan/air_nn.md) | active | An ongoing experiment. **Stage 1 is complete:** pilots P-1, P-2, P-3 (the solver is not replaceable yet; the best network is P2 on 300 sites); the P2 network has been in the game since 1.0.5 as the "Neural network (experimental)" item. Stage 2 is under way; analysis is in ["Approaches and results"](/approaches/). |
| [Air model at three scales](/docs/plan/air_model.md) | active | In the game since 1.0.0 (01.10.2026) and constantly developing, see the page ["Air model"](/mechanics/air-model/). Ahead are AM-11 (performance, network, Windows) and AM-12 (pilot's flight, documentation). |
| [Multiplayer: roadmap](/docs/plan/multiplayer.md) | active | In the game since 0.8.0 and developing, see the page ["Multiplayer"](/mechanics/multiplayer/). Open: a 30-minute run, a check over the internet, a load test and a systemd unit for the server. |
| [Offline world data](/docs/plan/offline_world_data.md) | postponed | Decision of 30.09.2026: keep the plan, postpone the implementation; the size measurement is done. |
| [Offline pack size (measurement on Slovenia)](/docs/plan/osm_vector_pack.md) | postponed | A measurement for the offline data plan. |
| [Flying sites from OSM and download on demand](/docs/plan/on_demand_location.md) | idea | Not accepted; an alternative to region packs. |
| [Trail of the previous flight](/docs/plan/game/04-sled-proshlogo-poleta.md) | idea | Postponed by the author's decision. |

## Closed and superseded: moved to the archive

These plans used to lie in `docs/plan/`; after reconciling statuses with the state of the work they are in the [archive](/plans/archive/), and their findings are in the [findings registry](/research/findings/).

| Plan | Status | Result |
|---|---|---|
| [Neural network in the game (air-onnx)](/docs/archive/plan/air-onnx.md) | closed | End-to-end path `.onnx` → wind field → thermals; merged into the main branch, in release 1.0.5. |
| [Neural network pilot P-3](/docs/archive/plan/air-nn-p3.md) | closed | The result is in the section "0. Result of P3"; the numbers are in ["Approaches and results"](/approaches/). |
| [air-nn log](/docs/archive/plan/air-nn-progress.md) | closed | History of the work until 02.10 23:00; after that the log is kept in `tools/dp`. |
| [A2: convergence in calm air](/docs/archive/plan/air-model-a2.md) | closed | `k_relax` 0.5 → 0.1: all cases with heating converge; a continuation of the air model plan. |
| [Prototype of the heat and mass cellular automaton](/docs/archive/plan/heat-ca-prototype.md) | closed | The prototype is done: [results](/research/heat_ca/), the choice of method is on the page "Approaches and results". |
| [Weather from a forecast](/docs/archive/plan/weather-by-temperature.md) | closed | Instead of the "weak/medium/strong day" presets: temperature, wind and cloud cover (build 0.6.0). |
| [Wing lineup](/docs/archive/plan/wings-lineup.md) | closed | Classes, models and the "class → model" choice (build 0.6.0); the lineup later grew to [48 models](/wings/). |
| [Mass-consistent wind field](/docs/archive/plan/wind-field.md) | superseded | Superseded by the three-scale air model plan. |
| [Task groups (top-level plan)](/docs/archive/plan/groups-top-level.md) | superseded | An outdated top-level list of groups by code area. |
| Group "Game scene and controls" ([contents](/plans/archive/game/)) | closed | Cards: [cockpit acceptance](/docs/archive/plan/game/01-priemka-kabiny.md), [end-to-end test](/docs/archive/plan/game/02-skvoznoj-test-svobodnyj.md), [gameplay](/docs/archive/plan/game/03-geimplej-svobodnogo.md), [collisions](/docs/archive/plan/game/05-stolknoveniya.md), [nose on the launch run](/docs/archive/plan/game/06-nos-na-razbege-po-vetru.md). |

## Closed: archive

Plans and logs of closed work are in the [plan archive](/plans/archive/): the air model (waves A and B, calibration), air at the launch site, wing control, wing passports and 3D models, wing physics check, controls in the interface, site update and old task groups. Their findings are collected in the [findings registry](/research/findings/): topic, finding with numbers, source and where it is applied.

The research the plans rely on is in the section ["Research"](/research/).
