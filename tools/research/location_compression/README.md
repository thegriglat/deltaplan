---
type: "research"
status: "closed"
module: "no-osm"
updated: "2026-10-10"
summary: "Сжатие данных мест (data/terrain, user://locations): почему выросли после перехода на GDScript и какие форматы Godot 4.7 дают выигрыш"
related: []
conclusion: "docs/research/location_compression.md"
data: "tools/research/location_compression/results/"
applied_in: "не применено"
---
# Сжатие данных мест

Итог — `docs/research/location_compression.md`. Данные: data/terrain/{altai,ongudai,aushkul,askarovo} (лицензии как у самих мест: Copernicus DEM GLO-30 / Terrain Tiles, см. ASSETS.md).

Воспроизведение (venv heat_ca, нужен zstandard; Godot 4.7.2):

    cd tools/research/location_compression
    ../heat_ca/.venv/bin/python -I exp.py          # прикидка в Python: квантование/предсказатели/уровни -> results/py_sizes.json
    ./run_godot.sh                                  # те же варианты в Godot (XDG_DATA_HOME временный), 4 места x 2 слоя x уровни zstd 3/19/22 -> results/godot_l*.jsonl
    ../heat_ca/.venv/bin/python -I aggregate.py     # сводка -> results/godot_summary.json
    XDG_DATA_HOME=$(mktemp -d) godot --headless --path godot_bench --script pngs.gd -- altai   # PNG-слои -> WebP, osm.json -> zstd

Проекты gb19/gb22 — копии godot_bench с `compression/formats/zstd/compression_level` 19/22 в project.godot (уровень zstd в Godot читается при старте, set_setting в рабочем процессе не действует).
