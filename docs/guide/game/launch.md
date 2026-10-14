---
type: "guide"
status: "active"
module: "game"
area: "game"
updated: "2026-10-15"
summary: "Старт полёта: разбег на земле, выбор точки старта и пустырь 160 м вокруг неё, «Осмотр карты», анимации пилота."
related: ["docs/guide/game.md", "docs/guide/flight.md", "docs/guide/terrain.md", "docs/contracts/control-fix.md", "docs/contracts/start-pick.md"]
---
# Старт, разбег, анимации пилота

Часть описания сборки игры (вход — [game.md](../game.md)). Код: `scripts/game/game.gd` (`start`, `_choose_start`, `restart`), `start_placement.gd`, `start_spot.gd`, `pilot_animator.gd`; физика разбега — `docs/guide/flight.md`.

## Разбег

Контракты С1 v2 / С2 v2 / К3 v3 (`docs/contracts/control-fix.md`). **Стоя и шагом:** `W`/`S` — шаг (`walk_forward`/`walk_back`), `A`/`D` — поворот на месте (`turn_left`/`turn_right` → `ControlInput.turn`, крыло не кренится); нос и крен крыла — как в полёте, действиями трапеции (`pitch_pull_in`/`pitch_push_out`, `roll_left`/`roll_right` — только стрелки), плюс мышь (при захвате, `M`) и стик. Стоя без поворота крыло само разворачивается носом против ветра (`flight.json`, «флюгер на земле»).

**Разбег — держать Shift** (`W` не нужен, пилот бежит сам): `W`/`S`/`A`/`D` на разбеге ничего не делают; нос и крен крыла — мышь, стрелки, стик, как в полёте; курс на бегу идёт дугой за креном крыла (`docs/guide/flight.md` → «Крен на земле»). На земле `pitch` — нос крыла (0 — угол разбега крыла `launch.alpha_neutral_deg` из конфига крыла), `roll` — заданный крен «руки пилота» (±`flight.json → ground_bank.command_max_deg`). Клавиши, мышь и стик ведут трапецию одинаково на земле и в полёте — на отрыве `pitch`/`roll` непрерывны, защёлки нет. Знак клавиш задаёт только карта `controls.json → keys` (контракт У1 v3: ↑ — от себя, ↓ — на себя). Автопилот тестов жмёт те же действия: Shift и трапецию по углу атаки киля. В сети пилот не первый в очереди не может бежать (`run_blocked`, `network.md`). Срыв разбега и его причины — `flight-flow.md` → «Итог свободного полёта».

## Выбор старта

`Game._choose_start()` ставит пилота в порядке приоритета:

1. **Точный старт** (`FlightSettings.has_exact_start()`: `start_lat`, `start_lon`, `start_heading_deg` — все три или ни одного, SP-К3): если `StartSpot.check` допускает точку — пилот ровно там, курс задан, курс по ветру не выравнивается; вокруг — `terrain.add_start_clearing`. Недопустима — предупреждение и автостарт.
2. **Точка с карты** (`pick_lat`/`pick_lon`, FR-17): ровно в выбранной точке; `StartPlacement.evaluate` даёт курс вниз по местному уклону (на ровном — север) и годность для разбега по `game.json → start_search` (уклон 12–32°, зонд 25 м, полоса разбега 40 м). После выбора вызывается `terrain.add_start_clearing` (пустырь ниже).
3. **Встроенный старт** локации (`site_id`; пусто — первый из `get_start_sites()`): координаты и курс площадки из `configs/locations/<id>.json`.

`StartSpot.check` (SP-К2, `game.json → start_pick`) — одна проверка для осмотра и запуска; `reason`: `outside` (ближе `edge_margin_m` 200 м к краю детальной зоны), `water`, `built` (застройка), `steep` (уклон > 40°). Лес, кусты и пологий склон допустимы — поляна вырубает лес.

**Курс по ветру.** При «встречном» ветре поле у земли поворачивает поток по рельефу, и на высоте крыла он приходит сбоку — боковой поток кренит крыло на разбеге. Поэтому `Game._align_start_heading()` ставит пилота носом против среднего ветра поля у старта (5 точек в радиусе `start_wind_align.sample_radius_m` 15 м, высота ступней — `takeoff.wing_height_m`), но не дальше `max_turn_deg` (60°) от курса площадки. Штиль (< `min_speed_ms` 1 м/с), аналитический воздух без поля, ветер с румба, точный старт и сеть — курс площадки.

**Пустырь вокруг старта.** Старт с карты может попасть в лес — `Terrain.add_start_clearing(x, z, R)`: лес в круге R → луг (деревьев нет; трава, кусты и камни остаются, `docs/guide/terrain.md`). R = `game.json → start_search.clearing_radius_m` = 160 м; у встроенных стартов — `max(configs/locations/<id>.json → start_clearing_radius_m, 160)`. Правило (решение пользователя): **R ≥ 2 · L_run**, иначе сразу за разбегом деревья и набрать высоту до них нельзя. L_run — разбег с места до отрыва в штиль на самом пологом пригодном склоне (`min_slope_deg` 12°) при эталонной массе по крыльям линейки; не взлетел — дистанция за 10 с (предел самого теста; в игре срыва по времени нет). Замер 30.09.2026 (`tests/game/test_start_clearing.gd`, живой `GroundRun`): sport 71,9 м и combat 69,9 м не отрываются за 10 с; 2 · 71,9 = 144 м, запас ≈ 10 % → 160 м. Тест пересчитывает L_run каждый раз.

**Старт в воздухе** — `--air-start` (`cli-tests.md`): `Game.air_start_position()`, скорость трима, фаза `flying`, полёт сразу «взведён».

## Осмотр карты

Пункт главного меню «Осмотр карты» (`StartMenu.inspect_requested` → `Main._fly(s, true)` → `Game.enter_inspect()`): тот же мир и ветер, но крыло скрыто и ничего не делает, камера свободная и заперта (`CameraRig.locked_free`, `C` не переключает), стрелки ветра (F5) включены, мышь не захвачена. Панель выбора старта (`StartPickPanel`, SP-2): клик ставит точку (`Game.pick`: `x, z, heading, ok, reason, height_m, slope_deg, downhill_deg`, маркер `StartMarker`), кнопки — повернуть курс, «вниз по склону», сбросить, «Лететь отсюда» (обычный полёт из этой точки; место уже загружено). Выбор пишется в настройки полёта как точный старт и в «последний полёт» (`Game.pick_changed` → `Main._on_pick_changed`). Выход — Esc → меню (`Game.leave_inspect()`). Тесты — `tests/game/test_inspect_mode.gd`, `test_start_pick_inspect.gd`, `test_start_pick_game.gd`.

## Анимации пилота

`PilotAnimator` (конфиг `game.json → pilot_animation`, модель пилота — `docs/guide/models.md`): фазы земли → `stand`/`walk`/`run`; отрыв → `run_air` → `climb_in` → `prone` (очередь по длине анимаций во времени симуляции); у земли при снижении (ниже `climb_out_agl_m` = 8 м, не раньше `min_air_time_s` = 10 с) или при выравнивании (`flare_threshold` 0,3) → `climb_out` → `flare`; посадка → `stand`. Нет `AnimationPlayer` — ничего не делает.
