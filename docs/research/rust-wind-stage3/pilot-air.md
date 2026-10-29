---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P1: воздух в release Linux грузится, поле доходит до READY, ветер ≠ 0; журнал пилота — не от этой сборки."
conclusion: "На release-экспорте DpAir грузится (api 4), поле на месте без запечённого доходит до READY за ~15 с, ветер у земли 3,6 м/с; в журнале пилота нет строки godot-rust и нет путей фасада — это не сборка linux-rust-wind"
data: ""
applied_in: ""
related: ["docs/research/rust-wind-stage3-path.md"]
---

# RW-P1: воздух в release-сборке Linux

## Факты

1. **Расширение грузится.** Экспортированный бинарь `build/linux-rust-wind/deltaplan.x86_64` (запуск headless) печатает
   `Initialize godot-rust (API v4.7...)`; `libdp_air_release.so` резолвится (`ldd` без «not found»), в pck есть
   `dp_air.gdextension` и `extension_list.cfg`. Гипотеза 1 (расширение не грузится) опровергнута.
2. **Поле считается в release-экспорте.** Обновлённый `tools/dp_air_smoke.sh`: экспорт Linux, headless-запуск, режим поля on,
   плоское место 10×10 км (клетка 25 м), конфиги из pck. Результат: `api_version=4`, этапы
   prepare, phases, coarse, solve_mech, solve_heat, windows, `READY за 14.8 с`, `field_version=2`, снимок поля не пуст,
   ветер у земли 3.60 м/с. Первый запуск старого smoke падал на устаревших проверках (api_version == 1) и на сетке 50 м
   («place grid must be 25 m») — это ошибки теста, не поставки.
3. **Журнал пилота — не от сборки rust-wind.** В `godot2026-10-29T17.00.15.log` нет строки `Initialize godot-rust`
   (в release-сборке она есть всегда), нет ни одной строки `dp_air:`; зато есть `air_model: analytic (нет поля)`,
   `air_model: поле (фазы+Пикар) ... GPU 1.76`, `air_cache: ...` — их печатает `AirRuntime` (GDScript+GPU), а в коммите
   `70e491dcb` игра `AirRuntime` не создаёт (`git grep` по `scripts/` и `*.tscn` — только статические константы).
   Вывод: пилот запускал старую сборку (вероятно `build/linux` из main), а не `build/linux-rust-wind`.
   Подтвердить у пилота: какой каталог запускался.
4. **Режим поля auto.** `_dp_field_wanted()`: off, если условия без `forecast` или headless; в игре `_air_conditions()` всегда
   с `forecast`, на не-headless auto даёт поле on. Настройку пилот исключил (GPU auto).

## Что сделано

- `addons/dp_air/smoke.gd` и `tools/dp_air_smoke.sh`: проверка api 4, режим on, READY на не запечённом месте, ветер ≠ 0,
  этапы с итерациями печатаются.
- Фасад `atmosphere.gd` пишет в журнал: загрузку расширения и версию API, начало подготовки места (режим поля), каждую
  смену этапа с итерациями и временем, итог READY/FAILED с временем и `last_error()` (в опросе, не чаще смены этапа).
  Нет расширения — прежняя строка `dp_air: нет расширения — воздух недоступен`.

## Где не уверен

- `scripts/atmosphere/atmosphere.gd` `_dp_log_progress`: не прогонялась целиком игра (случайное место) на экспорте;
  проверено smoke и тестом фасада (строки журнала видны).
- Вывод п. 3 косвенный (по содержимому журнала); окончательно — повторный запуск пилотом `build/linux-rust-wind` и поиск
  `dp_air:` в новом журнале.
- `tests/atmosphere/test_atmosphere.gd`: 10 из 11 падают и без правок (`air_place_data.gd:281`, read-only Dictionary) —
  существовавшая ошибка ветки, не от этой задачи.
