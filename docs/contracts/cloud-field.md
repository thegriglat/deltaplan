---
type: "contract"
status: "active"
module: "cloud-field"
area: "air"
updated: "2026-10-17"
summary: "Стыки поля облачности: CloudField (К1), текстура рендера (К2), потолок частицы AirThermals (К3), снимок сети (К4), конфиг (К5)."
related: ["docs/plan/cloud-field.md", "docs/guide/atmosphere/clouds.md", "docs/guide/air-model/thermals.md"]
contracts: [{"id": "CLF-К1", "version": 1}, {"id": "CLF-К2", "version": 1}, {"id": "CLF-К3", "version": 1}, {"id": "CLF-К4", "version": 1}, {"id": "CLF-К5", "version": 1}]
---
# Контракты модуля cloud-field

План — `docs/plan/cloud-field.md`. Менять — только координатор (версия +1, что изменилось, уведомить потребителей). Исполнителю нужна правка — `<ID> contract: <что>` координатору.
Контрактные тесты — по файлу на стык: `tests/contracts/test_cloud_field_k1.gd` … `test_cloud_field_k5.gd` (headless, без сети и GPU). Каждый проверяет заголовок своего раздела с версией — регулярка `(?m)^## (CLF-К\d)\. .* \(v(\d+)\)\s*$`; владелец стыка дописывает в свой файл проверку интерфейса (`load(path)` + `get_script_method_list()` / `get_script_property_list()` / `get_script_constant_map()`, ключи конфига — как `tests/contracts/test_goals_k2.gd`).

Оси и сетка везде — как `WindField` (`scripts/atmosphere/air_model/wind_field.gd`): столбец `c = j·nx + i`, i — восток = мировой x, j — север (мировой z = −y); центр клетки x = x0 + (i + ½)·dx, z = −(y0 + (j + ½)·dx). Сетка поля облачности = сетка региона поля воздуха (`air_field.levels[-1]`: dx 400 м, 96 × 96, x0 = y0 = −19 200) или, без поля воздуха, такая же сетка по `AirPlace.DOMAIN_L` и `AirRuntime.DX`. Высоты — м над уровнем моря (MSL), время — игровые секунды `t` (как `Atmosphere`), скорости — м/с.

## CLF-К1. CloudField — поле облачности на CPU (v1)
Владелец CLF-1. Потребители: CLF-3 (`CloudLayer`, `ThermalField`, `Atmosphere`, `CloudPhysics`), CLF-4 (сеть), CLF-5/6 (рендер через К2).

Файл `scripts/atmosphere/cloud_field.gd` (`class_name CloudField extends RefCounted`; помощники — `scripts/atmosphere/cloud_field_*.gd`). Не в `scripts/atmosphere/air_model/`.

```
const FORMAT_VERSION := 1
var nx: int; var ny: int; var dx: float; var x0: float; var y0: float
var base_msl: float                       # основание (LCL), общее на сетку
var cover: PackedFloat32Array             # ny·nx, 0..1 — доля столбца под облаком
var depth: PackedFloat32Array             # ny·nx, м — мощность облака над base_msl (0 — нет облака)
var stage: PackedFloat32Array             # ny·nx, −1..1 — +1 растёт, 0 зрелое, −1 тает
var activity: PackedFloat32Array          # ny·nx, 0..1 — подъём под облаком сейчас (тёмное плотное основание)
var bg_cover: float; var bg_depth: float  # фон вне сетки
func setup_grid(nx: int, ny: int, dx: float, x0: float, y0: float) -> void
func set_inputs(inp: Dictionary) -> void  # см. ниже; можно звать в любой момент, применяются со следующего шага
func reset(t: float) -> void              # пустое поле + разгон до t (spinup_s, К5) от текущих входов
func step_to(t: float) -> void            # интегрирование фиксированным шагом step_s до t; t назад или скачок > spinup_s → reset(t)
func sample(p: Vector3) -> Vector4        # (cover, base_msl, base_msl + depth, stage) билинейно по x,z; вне сетки — фон с переходом edge_fade_m
func density_at(p: Vector3) -> float      # 0..1, грубая плотность без шума (физика: белая мгла, подсос); 0 ниже base и выше base + depth
func shade_at(xz: Vector2, sun_dir: Vector3) -> float  # 0..1 — доля прямого солнца, закрытая полем над точкой земли (луч к солнцу до base_msl)
func to_image() -> Image                  # К2
func snapshot() -> PackedByteArray        # К4
func apply_snapshot(b: PackedByteArray, blend: float) -> bool  # К4; false — чужая сетка/версия
func signature() -> String                # "dx,x0,y0,nx,ny" — как AirThermals.grid_sig
```

Входы `set_inputs` (ключ отсутствует / `null` — источник не учитывается):
- `air: AirThermals` — `phi`, `col_w`, `col_f`, `col_heat`, `c_top`, `col_wstar` (К3), источники `pos/w0/top`;
- `wind_field: WindField` — уровень региона (w у поверхности/склона, ветер на высоте основания);
- `thermals: Array` — живые термики `ThermalField` (аналитический путь, когда `air == null`);
- `weather: Dictionary` — выход `WeatherModel.derive` (с `_derived`: `z_lcl_msl_m`, `dew_point_c`, `temperature_c`…);
- `cloudbase_msl: float`, `ground_ref: float`;
- `wind_at: Callable(z_msl: float) -> Vector2` — ветер (мировые x, z), когда поля нет;
- `seed: int`.

Инварианты: одинаковые входы и `t` → побитно одинаковые массивы (фиксированный шаг, без часов и общего RNG); `cover`, `stage`, `activity` в своих пределах, `depth ≥ 0`, `depth = 0` где `cover = 0`; без входов — пустое поле (cover 0), без ошибок. Цена: шаг 96 × 96 ≤ 15 мс (headless, машина разработки), вызывается не на главном потоке (CLF-3, по образцу `AirJob`).

## CLF-К2. Текстура поля для рендера (v1)
Владелец CLF-1 (`CloudField.to_image`). Потребители: CLF-5 (`CloudCompositorEffect`, `CloudShadowMap`), CLF-6 (boxes).

- `Image` `FORMAT_RGBA8`, размер nx × ny; пиксель (i, r), r = ny − 1 − j (строка r растёт с мировым z).
- R = cover; G = depth / `depth_max_m` (К5); B = (stage + 1)/2; A = activity. Квантование округлением, те же байты, что в снимке К4.
- Параметры шейдера (имена фиксированы): `cf_rect = vec4(x_min, z_min, 1/(nx·dx), 1/(ny·dx))`, где x_min = x0, z_min = −(y0 + ny·dx), uv = ((x − x_min)·cf_rect.z, (z − z_min)·cf_rect.w); `cf_base = vec4(base_msl, depth_max_m, bg_cover, bg_depth)`; `cf_edge = edge_fade_m`. Выборка — билинейная, вне [0,1] — фон с переходом `cf_edge`.
- Обновление текстуры — не чаще раза в `step_s`; без облаков (вся cover = 0 и bg_cover = 0) рендер пропускает слой целиком.

## CLF-К3. AirThermals: потолок частицы по столбцам (v1)
Владелец CLF-1. Потребители: CloudField. Файл `scripts/atmosphere/air_model/air_thermals.gd`.

- `var c_top: PackedFloat32Array` — ny·nx, м MSL: потолок частицы столбца, как уже считается в `build` (θ частицы против θ̄ + θ′ поля); столбец без нагрева — высота земли столбца; столбец, пропущенный счётом (k1 ≥ nz или z_i = NAN), — NAN.
- `var col_wstar: PackedFloat32Array` — ny·nx, м/с, w* Дирдорфа столбца (уже считается как `c_ws`).
- Заполняются в `build`; размер = `phi.size()`; остальное поведение `build` не меняется (те же источники при тех же входах). Правка меняет `model_hash` запечённых полей острова → CLF-2.

## CLF-К4. Снимок поля для сети (v1)
Владелец CLF-1 (формат), CLF-4 (передача). Потребители: `NetFlight`, `ZoneState`.

- `snapshot()`: `PackedByteArray` = заголовок (`FORMAT_VERSION` u8, `signature()` — строка с длиной u16, `t` f64, `base_msl` f32, `bg_cover` f32, `bg_depth` f32) + RGBA8 по К2, сжато `COMPRESSION_ZSTD`.
- `apply_snapshot(b, blend)`: при совпадении версии и сетки — `поле = lerp(поле, снимок, blend)` (blend 1 — заменить), true; иначе false и поле не меняется.
- Ведущий шлёт раз в `net_interval_s`; остальные считают поле сами и применяют снимок с подтяжкой за `net_blend_s`; новый участник — снимок целиком.

## CLF-К5. Конфиг `configs/atmosphere.json → cloud_field` (v1)
Владелец CLF-1. Потребители: все задачи модуля. Каждый ключ — с `_doc` (что, единицы, откуда число).

Ослабление новых термиков в тени — прежний `thermal.cloud_shade_factor`. Обязательные ключи: `enabled` (bool), `step_s` (игровые с), `spinup_s` (с), `depth_max_m` (м), `edge_fade_m` (м), `net_interval_s` (с), `net_blend_s` (с). Прочие ключи модели — владелец добавляет без смены версии (внутренние параметры, не интерфейс). Раздел `clouds.*` (рендер) и `quality_presets.*` (PF-К2) этим контрактом не меняются.
