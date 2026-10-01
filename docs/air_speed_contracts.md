# Ускорение расчёта ветра: контракты стыков (модуль air-speed)

Стыки задач плана `docs/plan/air-speed.md` (SP-1…SP-3) поверх `docs/air_model_contracts.md` (в `main`: C2 v5, C7 v2,
C9 v2). Зафиксировано по коду `feature/air-speed` от `main` a554502 (01.10.2026). Контрактный тест —
`tests/contracts/test_air_speed_contracts.gd` (headless, без GPU):
`godot --headless --path . res://tests/run_tests.tscn -- --filter=test_air_speed_contracts`.

Правило изменения — как в `docs/air_model_contracts.md` («Правило изменения контракта»): интерфейс меняет только
координатор модуля (версия +1, журнал версий ниже, потребители правятся в том же шаге, тест — в том же коммите).
При слиянии в `main` (после модуля air-start, который берёт C2 v6, C7 v3, C9 v3) S1/S2 переносятся в
`air_model_contracts.md` следующими версиями C2/C7/C9 — делает координатор при слиянии.

## S1 v1 — подготовка входа решателя (SP-3) → решатель, `AirRuntime`, клипмап
**Владелец:** SP-3. **Потребители:** `AirRuntime` (C9: `_prep_task`, `PreparedCase`), `AirClipmap` (C7:
`_prepare_case`), `AirPicardJob.start` (C2), тесты/инструменты (`test_air_place`, `test_air_window_case`, калибровочные
обёртки, если зовут `domain_case`). Параллельно: air-start меняет аргументы `domain_case`/`window_case` (C2 v6
`inflow_k`) — S1 сигнатуры не трогает.

**Интерфейс — без изменений (C2 v5, C7 v2):**
| Функция | Сигнатура (как в коде a554502) | Выход |
|---|---|---|
| `AirPlace.domain_case` | `(detail, water, loc, dx, hour, u10, wdir, t_max = NAN, sky = "clear", heat = true) -> AirCase` | случай с `hc`, `heat`, `gam`, `z_i`, α/max_profile; null — вне слоя |
| `AirPlace.block_mean` | `(layer: HeightLayer, x0, y0, dx, nx, ny) -> PackedFloat64Array` | (ny·nx), j — север, м над морем; пусто — вне слоя |
| `AirPlace.water_fraction` | `(img: Image, layer, x0, y0, dx, nx, ny) -> PackedFloat64Array` | (ny·nx) доля 0..1; пусто — нет маски |
| `AirPlace.solar_flux` | `(hc, dx, nx, ny, d, ctx, cfg, water) -> PackedFloat64Array` | (ny·nx) Вт/м² |
| `AirCase.prepare` | `() -> bool` | `col` (NCOL·nyx_h), `lev` (NLEV·nz_h), `prm` (32) — float32; `n_unk`, `n_fluid`, `heat_used`, `h_bl`, `fixed_scale`, `closure_info` |
| `AirWindowCase.window_case` / `window_at` / `prepare_pair` | как C7 v2 | то же для окна |
| `AirCase.gauss2d` (static) | `(a, w, h, sigma) -> PackedFloat64Array` | отражение «reflect» numpy |

- **Поток:** все функции выше вызываются из рабочего потока (`WorkerThreadPool`), без RenderingDevice — как сейчас.
  Если реализации нужен RD (compute), подготовка переезжает на главный поток — это **S1 v2** (где и как зовётся,
  аргумент устройства), только через координатора, до кода.
- **Допуск против нынешнего кода** (эталон — выходы кода a554502, фикстура SP-3):
  - точно: `kf` (столбец `col[nyx..2nyx)`), `n_unk`, `n_fluid`, доля воды, `nz`, `z_bot`, размеры;
  - `hc` — |Δ| ≤ 1e-3 м; `heat` / `heat_used` — |Δ| ≤ 1e-3 Вт/м²; `h_bl` — ≤ 1e-3 м;
  - `col`, `lev`, `prm` (float32) — |Δ| ≤ 1e-5·max(1, |x|); `fixed_scale` — относительная ≤ 1e-6;
  - после решателя (GPU): итерации [с нагревом, без нагрева] — те же; |Δu|, |Δv|, |Δw|, |Δw_mech| ≤ 1e-3 м/с, |Δθ′| ≤
    1e-4 К (область 400 м и окна 100/50 м Онгудая 12:00, 3 м/с со 150°). Побитно — лучше, но не обязательно.
  - сдвиг хоть одной клетки `kf` из-за float32 — нарушение S1 (к координатору), а не «в допуске».
- **Тесты:** `test_s1_prep_signatures` (сигнатуры, без GPU); эталонный `tests/atmosphere/test_air_prep_ref.gd` (SP-3:
  фикстура из старого кода, проходит и на старом, и на новом коде).

## S2 v1 — загрузка поля одним блокирующим проходом (SP-2) → `game.gd`, экран загрузки
**Владелец:** SP-2. **Потребители:** `game.gd` (`_load_air_field`), экран загрузки (`LoadProgress`,
`loading_screen.gd`), `tools/loading/load_probe.gd`, GPU-тесты `test_air_runtime_gpu.gd`, `test_air_window_gpu.gd`.
Меняет строку «Кадр» C9 v2 (загрузка — было `poll_slice(40 мс)`) и добавляет метод в C7 v2.

- `await AirRuntime.load_field() -> bool` — сигнатура, сигналы и ошибки без изменений (C9 v2). Новое поведение при
  расчёте:
  1. `progress_changed(0.0)`; затем ждать, пока экран загрузки с этапом «Рассчитываем ветер» **нарисован** (не меньше
     одного `RenderingServer.frame_post_draw` после `progress_changed(0.0)`);
  2. весь этап — вход места и обе `prepare` (S1), решатель области, сборка `WindField` области, окна 100/50 м
     (подготовка, решатель, сборка) — на главном потоке **без возврата в главный цикл** (`AirGpuJob.run_blocking`,
     `AirClipmap.run_blocking`); рабочие потоки внутри прохода — можно (параллельно GPU: подготовка окон, сборка полей),
     главный поток их ждёт;
  3. `AirRuntime.LOAD_BLOCK_MS: float` — наибольший непрерывный кусок главного потока в этапе, мс; **1500** (решение
     пользователя по шлюзу (б), 02.10.2026) — кусками с одним кадром между ними (прокачка событий окна, чтобы Windows
     не помечал окно «не отвечает»); `INF` — один проход;
  4. в конце — `set_air_field(levels, 0.0)`, `progress_changed(1.0)`, `field_applied` — как C9 v2.
- `last_info` при загрузке дополнительно: `prep_s` (вход места и обе `prepare` области), `solve_s` (решатель области,
  стена), `build_s` (сборка поля области), `windows_s` (окна целиком), `block_max_s` (наибольший непрерывный кусок
  главного потока за этап), `blocking: true`. В полёте — без изменений (`blocking: false` или нет ключа).
- `AirClipmap.run_blocking() -> bool` (C7 + метод): довести очередь окон до конца без кадров (подготовка — ждать
  рабочие потоки; решатель — `run_blocking` задачи окна; сборка поля — синхронно или ждать задачу); `levels_changed`
  / `failed` — как при `poll_slice`. true — набор готов.
- **Инварианты:** поле загрузки побитно то же, что при нарезке `poll_slice` (те же входы, итерации, порядок);
  пересчёт в полёте, сдвиг окон — без изменений (`poll()` раз в кадр, `FLIGHT_CHUNK_MS`); таймаут
  `air_model.timeout_s` — проверяется и внутри блокирующего прохода (ошибка → аналитика, как C9 v2).
- **Тесты:** `test_s2_blocking_api` (без GPU: `AirRuntime.LOAD_BLOCK_MS`, `AirClipmap.run_blocking`); GPU — SP-2
  дополняет `test_air_runtime_gpu.gd` (побитно с нарезкой, ключи `last_info`).

## Журнал версий
| Контракт | Версия | Дата | Что |
|---|---|---|---|
| S1 | v1 | 01.10.2026 | координатор air-speed до SP-3: сигнатуры подготовки C2 v5/C7 v2 без изменений, рабочий поток без RD, допуски против кода a554502 |
| S2 | v1 | 02.10.2026 | без смены версии: `LOAD_BLOCK_MS` по умолчанию 1500 мс (шлюз (б)) вместо INF — значение, не интерфейс |
| S2 | v1 | 01.10.2026 | координатор air-speed до SP-2: загрузка одним блокирующим проходом после кадра этапа «ветер», `LOAD_BLOCK_MS`, `AirClipmap.run_blocking`, разбивка времени в `last_info` |
