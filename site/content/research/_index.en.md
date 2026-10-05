---
title: Research
weight: 30
bookCollapseSection: true
description: "Deltaplan research by topic: what we found out, on what data, and where it is applied in the game."
---

# Research

Where the game's numbers and models came from: literature reviews, analyses of wing passports, prototypes and computational experiments. The documents are included as they are, from the `docs/research/` and `tools/research/` folders of the repository. A condensed summary of the conclusions is in the [findings registry](/research/findings/); the story "what we tried and what we chose" is on the page ["Approaches and results"](/approaches/); plans are in the ["Plans"](/plans/) section.

The studies are closed (status `closed` in the document header), except the air physics review, which is alive. If a document is not connected to the site, the link leads to the repository on GitHub.

## Wind, thermals, air model

| Document | What it is about |
|---|---|
| [Air physics over terrain: review](/docs/research/air_physics_primer.md) | Equations and scales, boundary layer, flow around obstacles, stratification, saddles, thermals, turbulence; our solver and its limits. Conclusion: the solver on a 400 m grid underestimates the speed-up at the brow by 15–20 %; the main error of the inflow profile over mountains is deceleration (+2.3 m/s), which linear theory does not give. Status: active. |
| [Wind flow over a slope](/docs/research/slope_wind.md) | What was in the game (formulas), how it is in real life, what can be done; the basis of the air model plan. |
| [Models of thermals, ridge lift and lee flows](/docs/research/thermals.md) | Convective layer, thermal profile by radius (Gedeon), formulas implemented in `scripts/atmosphere/`. |
| [Calibration using the Professor scheme](/docs/research/air-model-tune.md) | Fitting the air model parameters to the Askervein and Perdigão measurements. |
| [Air model sensitivity: Morris screening](/docs/research/air-model-sensitivity.md) | The model is soft with respect to switches and α, stiff with respect to data, and degenerate (λ/h ≈ α ≈ transport order ≈ local_k); errors were found in the Prandtl number, the cooling and the layer height — fixed. |
| [Catalog of experimental data](/docs/research/experimental_data.md), [tabular calibration data](/docs/research/calibration_data.md) | Which datasets exist, where they are, what they give. |
| [Surface parameters by land cover class](/docs/research/surface_params.md) | Albedo, Bowen ratio, roughness by land cover class. |
| [Air field size and the launch variants cache](/docs/research/air_field_cache.md) | The field of one variant is 23.5 MB raw; there are 57,564 variants in the start menu; conclusion: a full cache is unrealistic, a lazy cache on disk is needed. |
| [Visual cues for the pilot](/docs/research/visual_cues.md) | What should be visible in the simulator: birds, dust, grass in the wind. |

### Prototypes and computational experiments

- **[2D prototype "heating → buoyancy → flow"](/research/heat_ca/)** — a cellular automaton of heat and mass on a ridge cross-section, five scenarios and six comparison experiments (linearity, Picard method, transition matrices, ADI, jet kernel): which way of computing the steady field is faster and without loss of physics. The result is [`out/summary.md`](/research/heat_ca/out/summary/).
- **[3D reference on the Ongudai terrain](/research/air3d/)** — transferring the chosen method (Picard) to real terrain: time, memory, convergence by cell, field sizes. The result is [`summary.md`](/research/air3d/summary/).
- **[Askervein measurements](/research/askervein/)** — field data of flow over a hill (Zenodo 4095052, CC BY 4.0) for calibrating the wind speed-up at the brow.
- The remaining research passports are catalogs with code, tables and reproduction commands (the links lead to GitHub): [reconnaissance before A2](/tools/research/a2pre/README.md), [Morris](/tools/research/morris/README.md), [calibration](/tools/research/tune/README.md) and [Askervein recalibration](/tools/research/recal/README.md), [B1: Askervein + Perdigão](/tools/research/cases/b1/README.md), [the Perdigão case](/tools/research/cases/perdigao/README.md), [thermals from the field](/tools/research/air_thermals/README.md), [perturbations from the field](/tools/research/air_turb/README.md), [clipmap level junction](/tools/research/air_clipmap/README.md), [recomputing the field in flight](/tools/research/air_runtime/README.md), [air at the launch](/tools/research/air_start/README.md), [baseline figures](/tools/research/air_model_baseline/README.md), [comparison of main and air-model branch fields](/tools/research/wind_compare/README.md).

### Neural network instead of the solver

- [The air-nn pilot: can a small network replace the solver](/tools/research/air_nn_pilot/README.md) — code and reports of the pilots P-1, P-2, P-3.
- [WindNinja as an independent reference](/tools/research/windninja/README.md) — comparison on 21 cases in 6 places: the speed-up on ridges matches, WindNinja does not give deceleration over the massif.
- Plans and results — [air-nn plan](/docs/plan/air_nn.md), [P-3](/docs/archive/plan/air-nn-p3.md), [air-onnx](/docs/archive/plan/air-onnx.md); analysis — ["Approaches and results"](/approaches/).

## Wings and flight

| Document | What it is about |
|---|---|
| [Pilot mass and the hang glider polar](/docs/research/pilot_mass.md) | How pilot mass changes speeds, sink rate and glide ratio. |
| [Open sources of characteristics and polars](/docs/research/glider_polars_sources.md) | There is no ready-made open database of polars of modern hang gliders. |
| [Wing passports → configs](/docs/research/wings_config_sources.md) | What was changed in `configs/wings/*.json`, sources and contradictions; when they disagree, DHV takes priority. |
| [List of hang glider models](/docs/research/glider_models.md) and [combined set of passports](/tools/research/data/wing_passports/README.md) | DHV and manufacturer passport data; the game's wings are in the ["Glider models"](/wings/) section. |
| [Specification for 3D wing models from passports](/docs/research/glider_3d_tz.md) | A section per wing, self-sufficient for the implementer. |
| [Sources on hang glider models](/docs/research/wing_sources.md), ["Atlas" (USSR)](/docs/research/atlas_wing.md), [Ordodi "Hang Gliding" (1984), ch. 3.2](/docs/research/ordodi_1984_konstruktsiya.md) | Where to look for appearance and characteristics; data on the "Atlas" trainer; construction. |
| [References for the control frame and the view from the pilot's seat](/docs/research/control_frame_refs.md) | For procedural control frame models. |
| [Wing physics check](/tools/research/wing_physics_check/README.md) | Data and tools for checking polars against passports. |

## World, sound, game

| Document | What it is about |
|---|---|
| [Terrain and map sources](/docs/research/terrain_sources.md) | What was verified by queries and where elevations and land cover come from. |
| [Reference cross-country XC flights](/docs/research/xc_reference.md), [cross-country competition rules](/docs/research/competition_rules.md) | Benchmarks for the bot and tasks; the GAP formula, task geometry. |
| [Sound: assets and procedural synthesis](/docs/research/sounds.md), [sound of 1990s variometers](/docs/research/vario_sounds.md) | 51 files, 8.2 MB; the variometer timbre is a square wave up to the 11th harmonic and a 3.2 kHz resonance. |
| [Multiplayer via itch.io](/docs/research/itch_multiplayer.md) | itch has no networking features; the serverless option is the pilot's PC over Tailscale/ZeroTier; postponed. |
| [Contents of an OsmAnd OBF of a region](/tools/research/obf_region/README.md), [measurement of an offline pack (Slovenia)](/tools/research/osm_pack/README.md) | Experiments for the [offline world data](/docs/plan/offline_world_data.md) plan. |

## How to reproduce the prototypes

The prototypes are separate Python scripts outside the game (own venv, GPU via CuPy); the commands are in the README of each folder:

```bash
cd tools/research/heat_ca
uv venv .venv && uv pip install --python .venv/bin/python -r requirements.txt
.venv/bin/python run.py all              # all 2D scenarios
.venv/bin/python study.py cells          # convergence by cell
```

```bash
cd tools/research/air3d
PY=../heat_ca/.venv/bin/python
$PY study.py conv && $PY study.py matrix && $PY study.py cells   # 3D on the Ongudai terrain
$PY report.py figs && $PY report.py tables
```

Details and flags are in [`heat_ca/README.md`](/research/heat_ca/) and [`air3d/README.md`](/research/air3d/).

## Service

- [Findings registry](/research/findings/) — topic, conclusion with numbers, source, where applied.
- The entry point to all the repository documentation is `docs/INDEX.md` ([on GitHub](/docs/INDEX.md)): the path, type, status and a short summary of each document.
- [All `docs/research/` studies](/research/docs/) as a list.
