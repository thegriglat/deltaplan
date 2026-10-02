---
type: contract
status: active
module: air-onnx
updated: 2026-10-03
summary: "Контракты модуля air-onnx: формат .onnx сети области (O1), расширение ONNX Runtime (O2), вход/выход сети в GDScript (O3), вход из игры и страж (O4), AirRuntime engine=nn (O5), файл сети (O6)."
related:
  - docs/plan/air_onnx.md
  - docs/contracts/air-nn.md
  - docs/contracts/air-model.md
contracts:
  - {id: O1, version: 1}
  - {id: O2, version: 1}
  - {id: O3, version: 1}
  - {id: O4, version: 1}
  - {id: O5, version: 1}
  - {id: O6, version: 1}
---

# Контракты модуля air-onnx

План — `docs/plan/air_onnx.md`. Источник правды по входу и выходу сети — код пилота
`tools/research/air_nn_pilot/pilotnn/prep.py` (П2 v4, `docs/contracts/air-nn.md`) и экспорт
`pilotnn/evaluate.py:export_onnx`; поле в игре — контракты C3, C4, C9 (`docs/contracts/air-model.md`).
Менять интерфейс — только через координатора: версия +1, запись «что изменилось», правка потребителей в том же шаге.
Новые коммиты air-nn вливаются в `feature/air-onnx` (`git merge feature/air-nn`); после каждого — контрактный тест O1.

Общие соглашения:
- Сетка сети — область 400 м: 96 × 96 клеток, dx = 400 м, 38,4 × 38,4 км, центр — центр места (как `AirPlace.domain_case`).
- Массив карты — плоский, индекс `j·nx + i`, i — восток (x), j — север (y = −Z мира), как `AirCase` и numpy `[j, i]` пилота.
- Высоты выхода — 13 над рельефом клетки: `AGL = (25, 50, 75, 100, 150, 200, 300, 400, 600, 800, 1100, 1500, 2000)` м.

## O1. Файл сети `.onnx` (версия 1)
**Владелец:** пилот air-nn (`export_onnx`), в этой ветке — ON-1 (`tools/air_onnx/export_onnx.py`).
**Потребители:** O2 (загрузка), O5 (проверка формата), пользователь (подмена файла, O6).
- ONNX opset 17, тип float32, батч 1 (статические формы — torch-экспорт без dynamic_axes).
- Входы (ровно два):
  | имя | форма | содержание |
  |---|---|---|
  | `maps` | [1, C, 96, 96] | карты входа в **повёрнутой** системе (O3), порядок `prep.MAP_NAMES`; C = 9 — П2 v3/v4 (сеть П-2), C = 4 — П2 v2 (сеть первого пилота: первые 4 карты того же списка, формулы те же) |
  | `nums` | [1, 18] | числа FiLM, порядок `prep.FILM_NAMES` (U10, cos_r, sin_r, alpha, max_profile, z_i, z_lcl, sun_el, sun_x, sun_y, heat, t_max, stab, cap_flag, cap_agl, hour, brk, t_air) |
- Выход (ровно один): `out` [1, 91, 96, 96], канал = `c·13 + a` (c — канал, a — индекс AGL), повёрнутая система:
  c = 0..2 — без нагрева (u∥, u⊥, w), c = 3..6 — с нагревом (u∥, u⊥, w, θ′). Скорости — (поле − Ub(a)·(cos r, sin r, 0)) /
  max(U10, 1 м/с), θ′ — в К. Масштаб каналов (`out_scale`) — внутри сети: выход сразу в единицах П2.
- Метаданные (`metadata_props`, **необязательны**: сырой `main/model.onnx` пилота их не имеет; пишет `export_onnx.py` ON-1):
  `deltaplan.p2_version` ("2" | "4"), `deltaplan.map_names`, `deltaplan.film_names`, `deltaplan.agl` (через запятую),
  `deltaplan.source` (прогон/чекпойнт), `deltaplan.domain` (JSON, область применимости O4; нет — из конфига).
  Есть метаданные — игра сверяет их со своими списками (расхождение — отказ); нет — только имена и формы.
- Отказ (O5): иные имена/формы/тип → поле не строится, строка `air_model: analytic (нейросеть: формат … ≠ O1)`.
- Где берётся: `~/air_nn_data/pilot/runs/<прогон>/main/model.onnx` (экспорт в конце оценки пилота) или
  `export_onnx.py --ckpt <прогон>/main` (из `ckpt/best.pt` + `task.json`, с метаданными).
- **Тест:** `tools/air_onnx/test_contract_o1.py [--model файл.onnx]` (venv пилота, CPU) — константы `prep.py`
  (списки, AGL, нормировки карт), экспорт пилота на малой сети, готовые файлы по O1; итог `O1: OK`.
  Сеть первого пилота (`2026-10-02_pilot/main/model.onnx`, maps [1, 4, 96, 96]) — проходит (03.10).

## O2. Расширение ONNX Runtime `AirOnnx` (версия 1)
**Владелец:** ON-2 (`native/air_onnx/`, из пробника `native/air_nn_probe/`, П5 v2). **Потребители:** O5, тесты.
- ORT 1.30.0 C API, только CPU EP; godot-cpp 10.0.0-stable; сборка Linux x86_64 и Windows x86_64 из Linux
  (`native/air_onnx/build.sh all`, llvm-mingw), macOS — по возможности. Бинарники ORT и сборки — не в git.
- Класс `AirOnnx` (RefCounted), создаётся `ClassDB.instantiate("AirOnnx")` (нет класса — расширения нет, O5 → отказ):
  ```
  set_intra_op_threads(n: int) / get_intra_op_threads() -> int   # по умолчанию 4; действует на следующий load
  load(path: String) -> int        # FileAccess (res://, user://, абсолютный); 0 — ок, 1 файл, 2 ORT не создал сессию,
                                   # 3 нет входов/выходов, 4 не загрузилась библиотека ORT
  input_names() -> PackedStringArray, output_names() -> PackedStringArray
  input_shape(name) -> PackedInt64Array, output_shape(name) -> PackedInt64Array   # из модели; неизвестное имя — пусто
  metadata() -> Dictionary         # custom metadata_map модели (строка → строка)
  run(inputs: Dictionary) -> Dictionary   # {имя: PackedFloat32Array} → {имя выхода: PackedFloat32Array}; C-порядок;
                                   # размер входа ≠ произведению формы или ошибка ORT — {} и last_error()
  last_error() -> String
  ```
- `run` можно звать из рабочего потока (WorkerThreadPool); одна сессия — не из двух потоков одновременно.
- Без собранных бинарников игра запускается без ошибок-падений (тесты расширения — `skip`), O5 даёт отказ.
- Экспортированная сборка (Linux, Windows) содержит расширение и библиотеку ORT рядом (зависимость в `.gdextension`).
- Windows: `onnxruntime.dll` (MSVC) требует VC++ Redistributable 2015–2022 или 4 DLL рядом — решает ON-2, пишет в README.
- **Тест:** `test_air_onnx` (headless): модель-пустышка с двумя входами и эталон ORT Python — совпадение ≤ 1e-5;
  ошибки (нет файла, неверная форма) — коды/пустой ответ, без падения.

## O3. Вход и выход сети в GDScript `AirNnPrep` (версия 1)
**Владелец:** ON-3 (`scripts/atmosphere/air_model/air_nn_prep.gd`). **Потребители:** O5. **Эталон:** `prep.py`.
Перенос функций `prep.py` один в один (float64 внутри, float32 на выходе карт и чисел):
```
static func rotation_of(wdir_deg: float) -> Array          # [k: int, r: float рад], сектор [−45°, 45°)
static func case_meta(row: Dictionary, hc: PackedFloat64Array) -> Dictionary   # {k, r, U10, alpha, mp, S, hc_mean}
static func maps(hc, heat, meta: Dictionary, n_maps: int = 9, dx: float = 400.0) -> PackedFloat32Array
    # hc, heat — PackedFloat64Array ny·nx (м над морем, Вт/м²), исходная система; итог n_maps·ny·nx, [c][j′][i′],
    # первые n_maps из MAP_NAMES (4 — П2 v2, 9 — v4)
static func film(row: Dictionary, meta: Dictionary) -> PackedFloat32Array   # 18, порядок FILM_NAMES
static func to_physical(out: PackedFloat32Array, meta: Dictionary, nx: int = 96, ny: int = 96) -> Dictionary
    # {m: PackedFloat32Array 3·13·ny·nx (u, v, w), h: 4·13·ny·nx (u, v, w, θ′)}, исходная система (u — восток,
    # v — север), индекс ((c·13 + a)·ny + j)·nx + i; м/с и К
```
- `row` — словарь в форме строки набора пилота (O4): `U10, wdir, t_max, hour, profile{alpha, max_profile, stab,
  sun_el, sun_az}, day{z_i_msl, z_lcl_msl, heat, cap_agl, brk, t}`; пропуски — те же значения по умолчанию, что в `film()`.
- Константы карт (нормировки, σ ТПИ, шаг и дальность Sx) — как в `prep.py`; тест O1 ломается, если они поменялись там.
- **Тест N1/N2** `test_air_nn_prep` на фикстуре `tests/air_onnx/fixtures/` (её пишет `tools/air_onnx/make_prep_fixture.py`
  из `prep.py`; ≥ 4 случаев: k = 0, 1, 2, 3 и r у границы сектора, реальный рельеф): карты и числа GDScript = Python
  ≤ 1e-4 (абс.); `to_physical` на детерминированном `out` (формула, одинаковая в обоих языках) ≤ 1e-4·max(1, |x|);
  фикстуры в git ≤ 3 МБ.

## O4. Вход сети из игры и страж области применимости `AirNnInput` (версия 1)
**Владелец:** ON-4 (`scripts/atmosphere/air_model/air_nn_input.gd`). **Потребители:** O5.
```
static func row_from_case(case: AirCase, cond: Dictionary) -> Dictionary   # строка O3 + hc, heat (PackedFloat64Array ny·nx)
static func guard(row: Dictionary, domain: Dictionary) -> Dictionary       # {row: зажатая строка, clamped: ["U10 12.0→8.0", …]}
```
- `case` — случай области **с нагревом** из `AirPlace.domain_case` (тот же, что решателю; C2 v6). `U10` строки — U10 притока
  случая (с множителем притока k, C9 v3), `wdir` — направление атмосферы, `hc` — `case.hc`, `heat` — `case.heat`
  (как `d400_H` набора: поток тепла решения с гашением у края). `profile`/`day` — из тех же величин игры, из которых
  `AirCase`/погода считают решатель (аналоги `real.case` → `cond.alpha, max_profile, stab_class, sun_elev, sun[0]` и
  `weather.Day.summary()` в `tools/research/air3d/`). Нет величины в игре — значение по умолчанию `film()` и запись в
  отчёте ON-4 и здесь (раздел «Расхождения»).
- Страж: `domain` = `{U10: [0, 8], hour: [9, 20], t_max: [18, 34]}` (условия набора пилота, `airlite_gen.plan_rows`;
  конфиг `air_model.nn_domain`, метаданные `deltaplan.domain` важнее). Вне диапазона — величина зажимается к краю
  **только для входа сети** (числа FiLM); `to_physical` берёт настоящий U10 (выход нормирован на max(U10, 1)).
  Падения нет; список зажатого — в `last_info.nn_clamped` и строку журнала O5.
- **Тест N3** `test_air_nn_input`: для 2 случаев (Онгудай 12:00, 3 м/с со 150°, ясно; второй — другое место/час/небо)
  строка игры = строка Python (`real.case` + `Day.summary()`, как `airlite_gen.solve_case`; эталон — фикстура скрипта
  ON-4): числа ≤ 1e-3 отн., hc ≤ 0,5 м, heat ≤ 1 Вт/м²; страж — зажатие и список.

## O5. `AirRuntime` с `engine = "nn"` (версия 1)
**Владелец:** ON-5 (`air_runtime.gd`, `air_nn_field.gd`, `settings_panel.gd`, `configs/atmosphere.json`).
**Потребители:** игра (атмосфера, термики — C4 v4), пользователь. Расширяет C9 v3 (решатель не меняется).
- Конфиг `air_model`: `enabled` auto/on/off (как было), **`engine`**: `"solver"` (по умолчанию) | `"nn"`,
  `nn_model` — путь сети (O6), `nn_threads` (4), `nn_domain` (O4), у каждого `_doc`.
- Настройки: «Ветер над рельефом» — «расчёт» (`enabled = auto, engine = solver`), «нейросеть» (`auto, nn`),
  «упрощённый» (`off`). Без автоотключения.
- Загрузка (этап «Рассчитываем ветер», тот же ключ `wind`): `AirPlace.domain_case` (рабочий поток) → O4 (строка, страж)
  → O3 (`maps`, `film`) → O2 `run` (рабочий поток) → O3 `to_physical` → `WindField.from_arrays` → `set_air_field` →
  термики (`AirThermals.build`, как с решателем). Подстройка под старт (C9 v3, два прохода с k) — та же логика, проход
  = прогон сети. Уровень один — область 400 м (окон у сети нет).
- Сборка `WindField` (C3 v1): `u, v` = u, v набора **с нагревом** (`h`); `w_mech` = w набора без нагрева (`m`);
  `w_conv` = w(`h`) − w(`m`); `theta` = θ′(`h`). Сетка по высоте — та же, что у решателя для этого случая
  (`dz, z_bot, nz` из `AirCase`); центр клетки на высоте a над `hc` столбца: a < 0 — 0 (земля); 0 ≤ a < 25 м —
  значения 25 м (у земли лог-профиль даёт выборка C4); 25…2000 м — линейно по a между соседними AGL; a > 2000 м —
  отклонение от притока (скорости), w и θ′ линейно гаснут к 0 к 3000 м (выше — профиль притока Ub(a)·ê, w = θ′ = 0).
  `meta` — как у поля решателя (`dx, dz, x0, y0, z_bot, nx, ny, nz, z0, heat, z_i, gam, u10, wdir`), `source = "nn:<файл>"`.
  Ограничители C3 (40 / 10 м/с, NaN → 0) — те же.
- Полёт: пересчёт по сроку и смене условий — как C9 (тот же срок, подмена за `blend_s`), прогон сети в рабочем потоке.
- Отказ (нет расширения/ORT, нет файла, формат ≠ O1, ошибка ORT, NaN в выходе): при загрузке — аналитика и строка
  `air_model: analytic (нейросеть: <причина>)`; в полёте — прежнее поле. GPU нейросети не нужен (работает headless).
- Удача — строка `air_model: поле (нейросеть <файл>, П2 v<2|4>) <час> ч, <U> м/с с <dir>°: <с> с, k …[; вне области: …]`;
  `last_info` + `engine = "nn"`, `nn_model`, `nn_clamped`, `nn_ms` (время сети).
- `AtmoFingerprint` (`enabled = off`) — не затронут.
- **Тесты** `test_air_nn_runtime`: на малой сети `tests/air_onnx/fixtures/tiny_p2v4.onnx` (ON-1) — поле строится,
  оси и единицы (канал → u/v/w_mech/w_conv/theta, AGL → MSL по правилу выше), отказы дают аналитику без падения,
  настройки — три варианта; без расширения — `skip`.

## O6. Где лежит сеть и как её подменить (версия 1)
**Владелец:** ON-5 (поиск файла), ON-6 (README). **Потребители:** пользователь, сборка.
- Порядок поиска (первый существующий): `--air-nn-model=<путь>` (командная строка) → `user://air_nn/model.onnx` →
  `air_model.nn_model` (по умолчанию `res://data/air_nn/model.onnx`).
- `res://data/air_nn/model.onnx` — файл сети в git этой ветки (кладёт пользователь; до П-2 — нет, тесты берут
  `tiny_p2v4.onnx`); экспорт включает `*.onnx` (`export_presets.cfg → include_filter`), ORT читает из памяти.
- `user://air_nn/model.onnx` — подмена без пересборки (Linux `~/.local/share/godot/app_userdata/<проект>/air_nn/`,
  Windows `%APPDATA%\Godot\app_userdata\<проект>\air_nn\` — точные пути пишет ON-6).
- Проверка файла до игры: `tools/air_onnx/test_contract_o1.py --model <файл>`.

## Расхождения
Вход игры (O4, ON-4) против набора пилота (`airlite_gen.solve_case`), 03.10:
1. **Приток k ≠ 1.** В наборе k = 1; в игре α, max_profile, класс устойчивости — по ветру меню, `row.U10` = k·меню (C2 v6).
   Такой пары в обучении не было. Принято (координатор): сеть получает ту же строку, что решатель; `to_physical` — с теми же
   U10/α/mp, поэтому профиль притока согласован; ошибка — в пределах «скорость важнее точности».
2. **Ключи `day`.** `cap_agl` = ∞ или `z_i` = NAN → ключа нет (в Python — null); `film()` (O3) читает отсутствие как пропуск.
   `z_dry_game_msl`, `valley_msl` в `film` не нужны и не передаются.
3. **Солнце.** `sun_az` — с запаздыванием прогрева 0,3 ч, `sun_el` — без (как в Python).
4. **Нагрев.** `heat` = `d400_H` набора только при `case.taper = true` (по умолчанию).
5. Округления `Day.summary()` (z_i, z_lcl — до метра, heat — 0,001, brk и t — 0,01) воспроизведены намеренно.
6. Эталон N3 строится без `real.make` (тянет CuPy): hc — `grid_domain`, гашение нагрева — формулой air.py.

## Журнал версий
- 03.10 — «Расхождения» O4 по итогу ON-4 (интерфейс не менялся, версия та же).
- 03.10 — O1–O6 v1 (координатор, по коду `prep.py`/`evaluate.py` feature/air-nn bdbda42 и пробнику П5 v2).
