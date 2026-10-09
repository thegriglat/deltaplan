---
type: "reference"
status: "closed"
module: "osm-any"
updated: "2026-10-09"
summary: "Замороженная копия Python-сборки данных мест (fetch_dem, fetch_landcover, cog, rivers, fetch_osm) — только для воспроизводимости исследований perdigao, osm_pack, hg_sites."
related: []
conclusion: ""
data: "tools/research/_legacy_terrain/"
applied_in: ""
---
# _legacy_terrain — замороженная Python-сборка данных мест

Не путь игры: данные мест собирает игра (`tools/terrain/build_location.gd`, `docs/guide/location-data.md`).
Копия модулей `fetch_dem.py`, `fetch_landcover.py`, `cog.py`, `rivers.py`, `fetch_osm.py` на коммите `6cd393ce`
(удалены из `tools/terrain` и `tools/osm` в OA-7) нужна только для воспроизводимости исследований:
`tools/research/cases/perdigao/terrain.py`, `tools/research/osm_pack/slovenia_rasters.py`,
`tools/research/air_synth/hg_sites/fetch.py`. Не развивать.
