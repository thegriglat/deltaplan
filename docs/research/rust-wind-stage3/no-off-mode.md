---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P3: упрощённый режим ветра (off, set_air_mode, synth_off) убран; поле считается всегда; что удалено и что осталось."
---

# RW-P3: упрощённого режима ветра нет

Решение пользователя 2026-10-29: режим «ветер без поля» был запасным путём на случай сбоя GPU-расчёта; с полем в Rust не нужен. Контракты: W2 v5, W3 v6, W4 v7, W8 v3. `API_VERSION` / `WIND_API_VERSION` = 5.

## Почему пилот не увидел «Рассчитываем ветер»

В фасаде поле просили у крейта только если режим не `off` и (в `auto`) окно не headless; режим брался из `air_model.enabled` (по умолчанию `auto`, у пользователя мог лежать `off` из настроек «Эвристика» или из «безопасной графики» `GpuSafety.apply_safe`, которая писала `off` в машинный конфиг). При `off` крейт получал `set_field_enabled(false)`, поле не считалось, надпись этапа не появлялась. Теперь ключа нет и поле считается всегда, когда заданы условия с прогнозом. Оставшиеся значения `air_model.enabled` в пользовательских конфигах никем не читаются.

## Что удалено

Крейт:
- `AirModel::set_field_enabled` (трейт, `Calm`, `Formula`), поле `field_on`, режим тихой загрузки `quiet_load`, ветки `!field_on` в `try_launch`, `configure`, `load_place`, `set_conditions`;
- `terms/analytic/off.rs` (`config_is_off`, `apply`), `Terms::air_off`, `Terms::set_air_off`;
- `DpAir.set_field_enabled` и `Bridge::set_field_enabled` (dp-gd); `WIND_API_VERSION`, `API_VERSION` = 5.

Godot:
- `Atmosphere.set_air_mode`, `_air_mode`, `_dp_mode_sent`, `_dp_sync_mode`; `_dp_field_wanted()` теперь только «заданы условия с прогнозом» (эталон-пресет без прогноза идёт без поля, как и раньше);
- пункт настроек «Ветер над рельефом» (`_wind_model`, три строки `locale/ui.csv`, чтение и запись `air_model.enabled`);
- ключ `air_model.enabled` и `enabled_doc` в `configs/atmosphere.json`; запись `air_model.enabled = off` в `GpuSafety` (`apply_safe`/`restore` теперь трогают только `clouds.renderer` и `display.gpu`); ключ `air_model.enabled` в метке сеанса `CrashDiag.gpu_switches`;
- принудительный `off` в `AtmoFingerprint.make_world` (отпечаток мира теперь считается с полем: поле на CPU одинаково у всех клиентов; см. «Где не уверен»).

Эталоны и тесты:
- `synth_off` (json, bin, desc.json) и все ссылки; ключ `atmosphere.air_model.enabled` из `extra.config_overrides` случаев `synth_*` (и копий в `rust/dp-air/tests/data/RW-10f`);
- тесты режима: `tests/ui/test_wind_model_setting.gd`, `tests/atmosphere/test_wind_profile_simple.gd`, `test_simple_wind_releases_rd`, `test_mode_off_and_on`, `test_headless_auto_has_no_field` (rw7), `test_field_off_in_headless_auto`, в cargo — `off_mode_case_equals_medium_and_uses_simple_profile`, `field_off_and_on_again`, `field_off_before_load_is_remembered`, `no_recompute_while_field_is_off`, `field_off_drops_air_sources_and_back`.

## Что осталось и почему

- `WindModel::set_simple_profile` и `wind_profile_simple` в конфиге: эталоны `synth_*` сняты GD-кодом с упрощённым профилем 0.8.0 (README фикстур), поэтому сверка слагаемых по ним в cargo применяет профиль к этим случаям явно (`terms_analytic.rs`, `terms_objects.rs`, `terms_thermal*.rs`, `terms_storm.rs`, `terms_waves.rs`). В игре профиль не вызывается. Убрать можно только после пересъёмки `synth_*` на профиле с полем.
- `FAILED` (подготовка не удалась — опросы по запасному пути, W1) и «нет расширения — ветер без поля» (W9, до RW-13) — это не режим.
- `scripts/atmosphere/air_model/` (в т. ч. `air_runtime.gd`, `unavailable_reason`) и `scripts/atmosphere/wind_model.gd` не тронуты (границы карточки): там остаются упоминания `air_model.enabled = off` в мёртвом GD-коде, уйдут с RW-13. Так же `docs/guide/*` (границы), `docs/contracts/crash-reports.md`: там ещё описан `air_model.enabled` в `apply_safe`/`restore`.

## Тесты, которым поле нужно, а считать долго

- `test_rust_wind_consumers.gd::test_place_from_terrain_and_field_in_facade` (прогноз на месте из рельефа Онгудая): `cfg_override.air.domain_l_m = 9600`, поле считается на малой области.
- Тесты cargo `formula_facade.rs` (Онгудай в `weather_sun_and_version_follow_the_day`, `background_wind_*`) прежде шли без поля; теперь поле считается.
- Нижние границы числа сверенных точек в `terms_thermal.rs` снижены (600 → 500, 1500 → 1000): прежние учитывали `synth_off`, дубль `synth_medium`.

## Где не уверен

См. поле `uncertain` отчёта задачи.
