---
title: "Deltaplan 1.5.0"
date: 2026-10-10
description: "Ground heating by land cover: rock, meadow, forest and snow heat the air differently, and lakes sink in the daytime."
---

# Deltaplan 1.5.0 — ground heating by land cover

10.10.2026 · [Download on itch.io](https://thegriglat.itch.io/deltaplan)

## What's new
**Air and heating**
- Ground heating now depends on land cover: forest, meadow, cropland, shrubs, rock, built-up areas and snow heat the air differently (albedo, moisture, heat flux into the soil) instead of one value for everything. At noon the average heating is 10–16 % lower than before, but the spread is larger: sunny rocky slopes are stronger, north-facing slopes and wet hollows are weaker. Forest now heats more than meadow.
- Cloud cover affects heating once (not twice); the diffuse light share, slope and per-cover heating lag are taken into account.
- Lakes do not heat in the daytime: the water is colder than the air and gives sinking air, no thermals start over it. Lakes from OpenStreetMap count as water just like rivers. Water temperature follows the air temperature with a lag of about a month; in winter the water is frozen and behaves like snow.
- Surface roughness comes from land cover: near the ground the wind is weaker over forest and slightly stronger over meadow; wind speed at launch sites changes by a few percent at most.

More — [Where heating comes from](/mechanics/air-model/thermals/).

[itch.io devlog text](/site/content/releases/1.5.0/devlog.txt)
