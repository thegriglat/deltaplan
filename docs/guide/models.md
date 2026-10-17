---
type: "guide"
status: "active"
module: "models"
area: "flight"
updated: "2026-10-17"
summary: "Вход в гайд по 3D-моделям: крылья, пилот, приборы, лагерь, деревья; как их пересобрать (Blender 4.3) и где контракты имён и осей."
related: ["docs/guide/models/wings.md", "docs/guide/models/wing-contract.md", "docs/guide/models/pilot.md", "docs/guide/models/instruments-3d.md", "docs/guide/models/camp.md", "docs/guide/models/sail-shader.md", "docs/guide/models/trees.md", "docs/guide/models/references.md"]
---
# Модели (крылья, пилот, приборы, деревья)

Все модели генерируются скриптами Blender 4.3 (воспроизводимо, параметры в JSON рядом со скриптами),
исходники `.blend` и текстуры — в `assets/source/` (там `.gdignore`), готовые `.glb` — в `assets/models/`.
Сторонних ассетов нет, всё «сгенерировано» (`ASSETS.md` → «Модели и текстуры»); исключение — тело пилота:
базовый меш MakeHuman из MPFB 2 (CC0), собирается скриптом. Гайд описывает код `main` на версию 1.5.15 и разбит на части
(D4): этот файл — вход, подробности — в `docs/guide/models/`.

Оси в Godot: вперёд (нос) **−Z**, вверх **+Y**, вправо +X, 1 ед. = 1 м (glTF «+Y up»; в Blender вперёд +Y, вверх +Z).

| Что | Файлы | Часть |
|---|---|---|
| 48 крыльев | `assets/models/glider_<id>.glb` (11,8…14,0 тыс. треугольников) | [models/wings.md](models/wings.md); контракт нод — [models/wing-contract.md](models/wing-contract.md) |
| пилот | `assets/models/pilot.glb` (9703 треугольника, 20 костей, 8 анимаций) | [models/pilot.md](models/pilot.md) |
| приборы | `instrument.glb` (планшет), `vario_90s.glb`, `watch.glb`, `wrist_compass.glb` | [models/instruments-3d.md](models/instruments-3d.md) |
| лагерь у старта | `assets/models/world/{start_gear,glider_kit,camp_person,camp_pilot}.glb`, `assets/models/world/rocketbox/` | [models/camp.md](models/camp.md) |
| деревья | `assets/models/trees/tree_<вид>.glb` — 5 пород, 8 вариантов, 3 LOD | [models/trees.md](models/trees.md) |
| шейдер паруса | `assets/shaders/sail/` | [models/sail-shader.md](models/sail-shader.md) |
| скриншоты, приёмка по фото, источники | `docs/models/screenshots/` | [models/references.md](models/references.md) |

Оглавление по старым названиям разделов: «Параметры крыла», «Трапеция», «Центровка», «Подвеска» — [models/wings.md](models/wings.md);
«Контракт имён и осей» — [models/wing-contract.md](models/wing-contract.md); «Пилот», «Высота пилота в полёте» — [models/pilot.md](models/pilot.md);
«Приборы», «Наручные приборы», «Кабинная камера» — [models/instruments-3d.md](models/instruments-3d.md); «Модели лагеря у старта» —
[models/camp.md](models/camp.md); «Шейдер паруса» — [models/sail-shader.md](models/sail-shader.md); «Деревья» — [models/trees.md](models/trees.md);
«Скриншоты», «Приёмка: сравнение с фото», «Источники референсов» — [models/references.md](models/references.md).
Использование крыльев и пилота в игре — [flight.md](flight.md) ([flight/api.md](flight/api.md), «Визуал»).

## Как перегенерировать

```bash
blender --background --python tools/blender/build_gliders.py      # все крылья (или -- sport apogee …)
tools/blender/setup_mpfb.sh                                         # один раз: MPFB 2 для пилота
BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user blender --background --python tools/blender/build_pilot.py
blender --background --python tools/blender/build_instrument.py   # планшет
blender --background --python tools/blender/build_vario90s.py
blender --background --python tools/blender/build_watch.py         # наручные часы (watch.json)
blender --background --python tools/blender/build_wrist_compass.py   # наручный компас (wrist_compass.json)
blender --background --python tools/blender/build_start_gear.py    # вещи у старта
blender --background --python tools/blender/build_glider_kit.py    # полусобранный аппарат
blender --background --python tools/blender/build_camp_person.py   # человек, дальний уровень
BLENDER_USER_RESOURCES=~/.cache/deltaplan/blender_user blender --background --python tools/blender/build_camp_pilot.py   # человек MPFB — источник анимаций лагеря
tools/blender/build_camp_rocketbox.sh                              # люди лагеря вблизи (Rocketbox: скачать, LOD, текстуры, ретаргет)
xvfb-run -a blender --background --python tools/blender/build_trees.py   # Eevee печёт импосторы
tools/blender/render_all.sh                                        # скриншоты → docs/models/screenshots/
xvfb-run -a blender --background --python tools/blender/render_trees.py
godot --headless --path . --import
godot --headless --path . --script res://scenes/models_preview/check_models.gd   # контракт имён
```

`check_models.gd` печатает найденные и отсутствующие ноды, ориентацию и бюджеты; в 1.5.15 он сообщает одну ошибку — габарит
корпуса часов (см. [models/instruments-3d.md](models/instruments-3d.md)), на моделях это не сказывается.

**Общая текстура шины** — один файл `assets/textures/wheel/tire.png` (VRAM-сжатие, мипмапы); glb колёсных крыльев и
`world/glider_kit.glb` ссылаются на него по uri, встроенной копии нет (`tools/blender/glb_extern.py`, вызывается из
`bl_util.export` и `build_glider_kit.py`; без этого Godot извлекает отдельный png на каждую модель и держит в памяти
столько же текстур). Новую модель с шиной не копировать: материал с картинкой `wheel_tire` из `wheel_parts.tire_texture()`.

Файлы `tools/blender/`: `bl_util.py` (MeshBuilder, материалы, экспорт), `frame_parts.py` (детали трапеции: пластины, болты,
наконечники тросов, профильная труба, стропы, карабин), `wheel_parts.py`, `aframe_geom.py`, `aframe_cg.py`, `glider_params.json`
(форма крыльев, трапеция, глаза пилота), `sail_texture.py`, `sail_maps.py` (раскраска и карты паруса), `tree_params.json`,
`tree_textures.py`, `render_views.py` (приёмочные рендеры из готовых .glb), `render_trees.py`, `compress_png.py`.
Проверка в Godot: `scenes/models_preview/models_preview.tscn` (три крыла с пилотом и приборами; `-- --view=iso|below|side|cockpit
--pose=<анимация> --shot=/путь.png`), `sail_preview.tscn` — шейдер паруса.
