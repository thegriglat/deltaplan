---
type: "guide"
status: "active"
module: "models"
area: "flight"
updated: "2026-10-15"
summary: "Шейдер паруса: просвечивание, анимация вершин, подключение к GliderVisual, стенд и сравнение с фото."
related: ["docs/guide/models.md"]
---
# Шейдер паруса

Файлы: `assets/shaders/sail/sail.gdshader`, `sail_material.gd` (`SailMaterial`), `configs/sail.json`
(значения по умолчанию, с `_doc`), карты в `assets/shaders/sail/`: `glider_<id>_normal.png` (латы, швы, кромка
майлара, подгиб задней кромки, X-сетка ламината) и `glider_<id>_trans.png` (сколько света проходит: кромка, латы,
швы, двойная обшивка темнее). Карты пишет `tools/blender/sail_maps.py` вместе с крыльями; одинаковые карты разных
крыльев хранятся одним файлом, соответствие — `sail_maps.json` (`tools/blender/sail_dedupe.py`).

- **Просвечивание**: `BACKLIGHT` = раскраска × карта просвечивания × `translucency` — снизу против
  солнца парус светится, латы и швы видны тёмными линиями; рассеяние вперёд через ткань (`forward_gain`,
  `forward_exp`) даёт просвет против солнца. Двусторонний (`cull_disabled`). Парус **не принимает тени**
  (`shadows_disabled`): иначе тень верхней обшивки гасит свечение нижней; цена — в тени рельефа парус не темнеет.
  Тень он отбрасывает (на землю и пилота): `sail.json → cast_shadows` = true.
- **Анимация вершин** (смещение по +Y модели, м) по маске
  (вторая UV меша `Sail`, в Godot `UV2`: `UV2.x` — вес пролёта между латами, 0 на лате; `UV2.y` — доля
  хорды, у нижней обшивки +2; цвет вершин не используется — по glTF он умножается на цвет материала):
  колыхание между латами ниже `firm_speed_ms` (14 м/с; полное ниже `soft_speed_ms` = 8), трепет при
  сваливании (`stall_amount`, `stall_amp_m` = 0,015), волны от турбулентности (`turbulence`, `turb_amp_m`) и трепет
  задней кромки выше `flutter_start_ms` с частотой `flutter_hz_per_ms · V` (`flutter_amp_m`, VR-19). Амплитуды
  турбулентности и трепета в `sail.json` сейчас 0 — парус натянут и на скорости не трепыхается (слова пилота), включаются
  числом в конфиге. Передняя кромка и латы неподвижны.

**Подключение (`GliderVisual`):**
```gdscript
# после загрузки модели крыла (model = "glider_sport" и т. п.; делает GliderVisual.build)
_sail_mat = SailMaterial.apply(wing_node.find_child("Sail", true, false) as MeshInstance3D, model)
# каждый кадр (или шаг физики)
SailMaterial.set_flight(_sail_mat, t.airspeed_ms, stall_amount_0_1, turbulence_0_1)
```
`stall_amount` — `FlightModel.stall_amount()` (0..1); `turbulence` — `FlightModel.load.jitter` / `turbulence_full_g` (0..1). Нет меша `Sail` или шейдера — `apply` вернёт `null`, остаётся
исходный материал .glb; нет карты — предупреждение в лог.

**Стенд**: `scenes/models_preview/sail_preview.tscn` — слайдеры скорости/сваливания/турбулентности;
со снимками: `-- --wing=<id> --view=below|keel|te|cockpit|side|shadow --airspeed=25 --stall=0 --turb=0 --pose=prone
--shot=/путь.png [--frames=8 --dt=0.04]` (серия кадров с фиксированным временем шейдера).

**Сравнение с фото снизу против солнца** — [Sport 2 снизу у киля](https://www.willswing.com/hang-gliders/sport-2/),
[T3 спереди в полёте](https://www.willswing.com/hang-gliders/t3/),
[Falcon 4 снизу](https://commons.wikimedia.org/wiki/File:Wills_Wing_Falcon_4_hang_glider.jpg):
✔ парус светится, латы и швы тёмными линиями, передняя кромка (майлар+труба) темнее, у ламината
видна X-сетка, двойная обшивка темнее одинарной задней части. ✘ цвета насыщеннее (у прототипов много
серого прозрачного майлара), нет светового пятна солнца и мягкой тени лат на ткани; в
gl_compatibility нет теней сквозь ткань.
