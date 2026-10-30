---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P12: запечённые поля мест удалены (данные, add_baked_field, baked); кеш полей оставлен."
conclusion: "Поле всегда считает Rust; путь «запечённое из данных места» убран целиком (W3 v7, W4 v8, W5 v9). Разбор/запись field::baked остаются: на них кеш полей и field_export*. Опорные T1/k-тесты против GPU-файлов удалены вместе с данными."
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3/baked-islands.md"]
---

# Удаление запечённых полей мест (RW-P12)

Основание: решение пользователя 2026-10-29 «bake_air удалить» и итог RW-P11 (`baked-islands.md`): все 8 файлов отвергались по `model_hash`, перепекать нечем.

## Удалено

- Данные: `data/locations/{training_island,volcano_island}/air/` (8 пар `.json`+`.bin`, ~45 МБ).
- Крейт `dp-air`: `AirModel::add_baked_field` (трейт, `Formula`), `BakedEntry`, `pick_baked`, `JobIn.baked`, `Source::Baked`, ветка «запечённое» в `run_job`; в `field::baked` — `baked_lookup`, `BakedQuery`, `Cond`, `Reject`, `make_key`, `conditions_diff`, `path_of`, `snapped`, константы допусков и `BAKED_ROOT`.
- `dp-gd`: `Bridge::add_baked_field`, `DpAir.add_baked_field`; тест моста переименован в `cache_dir_reaches_the_model` (без файлов).
- GD: `AirPlaceData.baked`, из `fill_crate_inputs` — выбор `start_sites[].id/weather`, `header.data_hash`, чтение файлов; в `atmosphere.gd` — цикл `add_baked_field` после `load_place`.
- Тесты: `rust/dp-air/tests/{baked,baked_islands_probe,k_passes,t1_stability}.rs`, `tests/data/baked/` (дамп GD-эталона `baked_lookup`); `tests/atmosphere/test_{island,volcano}_baked_gpu.gd`; в `acceptance.rs` — раздел T1 (`t1_*`, `t1_open_*`, `t1_field`, `explore_area_iterations`): всё сверяло крейт с GPU-файлами.
- Перенесено на «посчитанное поле»: `field_export.rs`, `terms_sum.rs`, `terms_turb.rs` (остров с одной площадкой, поле считает Formula на настроенной малой области; проверки внутренние — снимок против опроса), `pilot_left_baked…` в `acceptance.rs` (теперь поле берётся из кеша: считается, пишется в кеш, три загрузки из него).
- `runtime.rs`, раздел 9: остались только тесты кеша; `baked_field_is_taken…`, `baked_misses…`, `add_baked_field_follows…` удалены.

## Оставлено ради кеша

- `field::baked`: `BakedField`, `parse_baked`, `encode_baked`, `key_diff`, `gd_num`, `FORMAT/VERSION/KEY_TOL` — кеш (`field_cache`) пишет и читает записи этим форматом; `field_export*` кодирует им же.
- `baked_pending` в `Formula` и его пересчёт окон по выходу фокуса: относится к полю из кеша (`Source::Cache`), не только к запечённому.
- `header.model_hash` (`AirBakedField.model_hash()` в `fill_crate_inputs`): часть ключа кеша; пусто — кеша нет.
- `scripts/atmosphere/air_model/air_baked_field.gd`: зовут `atmosphere.gd` (`load_bytes` для `field_export`), `air_field_cache.gd` (кеш GD-стороны) и GPU-путь `air_model/**` (`air_runtime.gd`, `place_hash`, `path_of` и пр.) — не удалён, убирается в RW-13 вместе с GPU-путём.
- `StartSite` в крейте и так не читал `id/weather` (serde их игнорировал); кеш ключуется по содержимому места, поэтому id/weather/`data_hash` в заголовок не нужны.

## Границы

- Опыты T1 (`t1_open_*`, `stab_*`, `k_passes`) и `tools/research/rust_wind*` (скрипты `dump_baked`, `rust_wind_t1_stability`), ссылающиеся на удалённые тесты и файлы, не тронуты (вне скоупа): воспроизводить — из истории git (коммит до RW-P12).
- `tools/build.sh:50` по-прежнему предупреждает, что без `data/air_model_hash.txt` «запечённые поля не возьмутся» — формулировка устарела (хеш нужен кешу); вне скоупа.
- Игра с загрузкой места и Godot-тестами кроме `air_place_data` не прогонялась; `tests/contracts/test_rust_wind_contracts.gd`: `W3 = 7, W4 = 8, W5 = 9`.
