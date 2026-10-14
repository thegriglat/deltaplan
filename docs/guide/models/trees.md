---
type: "guide"
status: "active"
module: "models"
area: "flight"
updated: "2026-10-15"
summary: "Модели деревьев (5 пород, 8 вариантов, 3 LOD) и их подключение в мире."
related: ["docs/guide/models.md"]
---
# Деревья

**Модели** `assets/models/trees/tree_<вид>.glb` — пять пород Алтая: `pine`, `cedar`, `larch`, `birch`, `spruce`
(`tools/blender/build_trees.py`, параметры — `tools/blender/tree_params.json`, высоты в модели 18–25 м). В каждом файле
8 вариантов дерева (`variants` = 8, вариант выбирается хешем места; сиды от базового), у варианта n три меша в одной
точке (основание ствола): `V{n}_LOD0` (вблизи), `V{n}_LOD1` (средняя дальность: тот же каркас, ствол 5 граней, пучки
ветвей слиты) и `V{n}_LOD2` (4 треугольника — две скрещённые плоскости с запечённой картинкой). Треугольники у варианта 0:

| Порода | LOD0 | LOD1 | LOD2 |
|---|---|---|---|
| `pine` | 1042 | 228 | 4 |
| `cedar` | 1780 | 336 | 4 |
| `larch` | 1870 | 336 | 4 |
| `birch` | 1950 | 296 | 4 |
| `spruce` | 1786 | 408 | 4 |

Материалы: `Bark_<вид>` (кора 256×512), `Leaf_<вид>` (карточки хвои/листвы 512×512, альфа-отсечение) и `Impostor_<вид>_v<n>`
(картинки `tree_<вид>_tree_<вид>_v<n>_impostor.png`, 256×512 RGBA, вид сбоку, ортокамера, низ = земля). Атлас импосторов
`trees_impostor_atlas.png` — 1024×1024, 4×2 ячейки 256×512 (`world.json → trees.impostors.atlas_cells`).

**Как деревья попадают в игру.** `configs/world.json → trees.models` задаёт путь к модели каждой породы; нет файла —
запасные процедурные кроны (`TerrainTrees`, [terrain.md](../terrain.md)). Расстановку считает `TreePlacer` в рабочем
потоке, модели рисует `TerrainTreeModels` (`scripts/terrain/terrain_tree_models.gd`): по `MultiMesh` на породу,
вариант и LOD, переходы LOD по `trees.lod_distances_m` = [60, 180] м (`lod_fade_m`, `lod_dither_m`). Дальше LOD2 —
кресты `TreeCrosses` (`trees.crosses_enabled`, до `cross_radius_m`), за ними билборды `ForestImpostors` из атласа
(средний план леса до `impostors.outer_m`), а затем полог леса в шейдере рельефа; качание ветром — `tree_model.gdshader`
(`sway_top_m`, `sway_hz`). Породы, высоты и высотные пояса — `trees.species`. Подробности расстановки и покрова —
[vegetation.md](../vegetation.md) и [terrain.md](../terrain.md).
