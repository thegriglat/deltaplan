---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-29"
summary: "RW-P6: почему cores() пуст у динамических термиков (mode 0) в тестах стенда air_rig.gd; в игре термики есть."
conclusion: "Стенд берёт шаг сетки 100 м, поле принимает только 25 м - загрузка Failed, опросы при Failed молчали; на игровом месте (25 м) динамические термики рождаются. Починено Formula::query (Failed отвечает по запасному пути, W1) и тесты dynamic_thermals."
data: "rust/dp-air/tests/zz_dynamic_thermals.rs"
applied_in: "rust/dp-air/src/formula.rs"
related: ["docs/research/rust-wind-stage3/rw10-thermals.md", "docs/contracts/rust-wind.md"]
---

# Динамические термики (mode 0): cores() пуст (RW-P6)

## Симптом
RW-P4: `tests/atmosphere/test_atmosphere.gd::test_deterministic_generation` - через фасад `cores()`
пуст у динамических термиков (mode 0), с preset и с прогнозом, до 3600 с, на местах 10 и 40 км;
статичные (mode 1, 2) есть.

## Причина (воспроизведено в cargo)
1. Стенд `tests/atmosphere/air_rig.gd` строит место `AirPlaceData.from_functions(..., spacing=100)`.
   Поле Пикара принимает только сетку места 25 м с началом кратным 25 м
   (`field/weather_core.rs:721`, `domain: place grid must be 25 m ...`). Загрузка → `State::Failed`
   (причина в `status().reason`), поля нет.
2. При `Failed` опросы слагаемых (`cores`, `clouds`, `weather_json`, ...) шли через
   `Formula::query`, который требовал `Ready`, - пусто. Контракт W1 велит при `Failed` отвечать по
   запасному пути. Исправлено: `query` пропускает `Ready` и `Failed`.
3. Даже с ответом при `Failed` динамических ядер на таком месте мало или нет: без поля источники
   термиков берутся по клеткам (`Setup::spawn`) из `ground.source` со статичным солнцем мира; на
   пологих холмах стенда это ~0,27, порог `sun_min` не проходит. Это свойство запасной модели,
   а не ошибка; термики поля (основной путь) рождаются из источников поля.
4. Статичные термики (mode 1) от погоды, поля и источников не зависят - потому были.

## В игре
Место игры всегда 25 м (слой detail), поле считается, динамические термики рождаются: на месте
как у стенда, но с шагом 25 м, `cores()` даёт ~100 ядер в радиусе 8 км на всех моментах
0…3600 с (тест `dynamic_thermals_born_on_rig_place_deterministic`), сильный день сильнее слабого.
Полёта без термиков из-за этого быть не могло.

Отдельно (не ошибка): вне детерминированного режима первый набор термиков собирается в фоне,
`cores()` пуст первые ~0,2 с (в -O0) после `Ready` до публикации (тест
`dynamic_thermals_background_first_snapshot_appears`). Подряд идущие `advance_to` без пауз
(как в тесте Godot с прыжком времени) этого времени не дают.

## Что сделать вне скоупа (для координатора)
- `tests/atmosphere/air_rig.gd`: `spacing` по умолчанию 25 (а не 100), `half` кратно 25; тогда
  `test_deterministic_generation` и родственные работают на поле. Либо стенд должен проверять
  `is_ready()`/`status().state != FAILED` и падать с причиной, а не молча давать пустоту.
- Красные `test_ridge_lift_windward_and_lee_sink` и `test_turbulence_deterministic_and_ground_stronger`
  из RW-P4, вероятно, того же происхождения (место стенда `Failed` → аналитика без поля); проверить
  после смены шага.

## Сверка слагаемого с эталоном RW-2b
Слагаемое thermal сверено с эталонами `synth_*` тестами `rust/dp-air/tests/terms_thermal.rs`
(RW-10b, зелёные); данная задача слагаемое не меняла.
