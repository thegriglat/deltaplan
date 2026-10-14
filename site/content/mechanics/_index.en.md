---
title: Mechanics
weight: 10
bookCollapseSection: false
description: "How flight, air, weather, clouds, terrain, instruments, bots and multiplayer work in Deltaplan: the physics, the limits of the model, the options considered."
---

# Mechanics

Each page is one mechanic of the game: how it works in plain words, what physics and approximations stand behind it, what the model cannot do, which options were considered and why this one was chosen. At the end of the pages are links to the source documents and code on GitHub.

A simulation is a model, and every model has limits. That is why every page has a "Model limits" section: what is simplified and where the game's behavior may differ from the real sky.

The air has five linked pages: the [overview of the three scales](/mechanics/air-model/), then one page per level — [wind field](/mechanics/air-model/wind-phases/), [thermals](/mechanics/air-model/thermals/), [turbulence and rotor](/mechanics/air-model/turbulence/) — and, separately, the [Heuristic mode](/mechanics/air-model/heuristic/) (slope wind without a solver). The air is driven by the forecast (temperature, wind, sky cover) described on the [Weather](/mechanics/weather/) page; clouds and their shadows are on [Clouds and shadows](/mechanics/clouds/); the map, forest, snow, villages and roads are on [Terrain and places](/mechanics/terrain/).

{{< children >}}
