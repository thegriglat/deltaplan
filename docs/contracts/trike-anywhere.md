---
type: contract
status: "active"
module: trike-anywhere
area: flight
updated: "2026-10-23"
summary: "Стыки trike-anywhere: окно выбора старта по «Лететь» (TA-К1) и старт дельталёта и буксировки в любом месте в Game (TA-К2)."
related: ["docs/plan/trike-anywhere.md", "docs/contracts/trike-pilot.md", "docs/contracts/tow.md"]
contracts: [{"id": "TA-К1", "version": 1}, {"id": "TA-К2", "version": 1}]
---
# Контракты trike-anywhere (код задач TA)

Правка интерфейса — только через координатора: версия +1, этот файл и контрактный тест — в том же шаге. Контрактный тест
проверяет версию своего раздела по заголовку (шаблон — `tests/contracts/test_trike_pilot_k5.gd`/`test_trike_model_k1.gd`:
`const DOC`, `const VERSION`, регулярка `^## (TA-К\d) v(\d+)\.`). Основание — решения пользователя 2026-10-23
(`.dpcli/dpcli inbox trike-anywhere`). Заменяет: меню-часть TP-К5 v1 (пункт «Дельталёт» в выборе буксировки,
`trike_allowed(site, mp)`), меню-часть TW-К7 v3 (строка «Буксировка» на вкладке «Место»), Game-часть TP-К6 v2 и
TW-10 в части «нет полосы / полоса не годится → без буксировки». Поля `FlightSettings.vehicle` (TP-К5) и `tow_kind`
(TW-К7), CLI `--vehicle`, `--tow` — без изменений.

## TA-К1 v1. Окно выбора старта по «Лететь»
Владелец — TA-1. Потребитель — TA-2 (через `FlightSettings.vehicle`, `tow_kind`). Контрактный тест —
`tests/contracts/test_trike_anywhere_k1.gd` (пишет TA-1).

- **`StartChoiceDialog`** (`scripts/ui/start_choice_dialog.gd`, `class_name StartChoiceDialog`; окно Godot по образцу
  `GpuFailureDialog`, стиль — `UiKit`). Одно окно, без второго вопроса:
  - заголовок `start_choice_title` («Старт» / «Start»);
  - строка «Буксировка (дельтаплан)» (`start_choice_tow`): `OptionButton` — «Нет» (`setup_tow_none`) + виды
    `FlightSetupScreen.tow_kinds_for_site(site)` (`setup_tow_winch`, `setup_tow_aerotow`): место с блоком `tow` — его
    `tow.kinds`, место без `tow` и точка с карты (`site` пуст) — все виды (`FlightSettings.TOW_KINDS`). Умолчание —
    `settings.tow_kind`, если он в списке, иначе `FlightSetupScreen.default_tow_kind(site)`;
  - кнопки «Дельтаплан» (`start_choice_glider`), «Дельталёт» (`start_choice_trike`), «Отмена» (`common_cancel`, и Esc).
    Фокус — на кнопке аппарата `settings.vehicle`.
  - `func open(settings: FlightSettings, site: Dictionary) -> void` — заполнить и показать.
  - `signal chosen(vehicle: String, tow_kind: String)` — «Дельтаплан» → `("glider", <выбранный вид или "">)`,
    «Дельталёт» → `("trike", "")`. `signal cancelled` — «Отмена»/Esc/закрытие. После любого сигнала окно скрыто.
- **Где показывается** (только одиночная игра):
  - `StartMenu._on_fly` («Лететь» главного меню). `GoalsTab.net_blocked()` → окна нет: `settings.vehicle = "glider"`,
    `tow_kind = ""`, сразу `fly_requested.emit(settings)`. Иначе окно; `chosen` → `settings.vehicle`, `settings.tow_kind`
    из сигнала → `fly_requested.emit(settings)`; `cancelled` → ничего (меню как было).
  - `main.gd _on_pick_fly` («Лететь отсюда» в осмотре карты): то же окно с `site = {}` перед `_fly(flight)`;
    `cancelled` — остаёмся в осмотре (панель точки снова видна).
  - Место для окна: `settings.has_pick()` → `{}`; иначе запись `start_sites` из `Locations.config(settings.location_id)`
    с `id == settings.site_id` (нет такой — первая; нет `start_sites` — `{}`).
  - Окна **нет**: быстрый старт из избранного/недавних (летит как сохранено), «Тренировка», экран сети, `--autostart`.
- **`FlightSetupScreen`** (`scripts/ui/flight_setup_screen.gd`): строка «Буксировка» удалена целиком (`_build_tow`,
  `_tow_opt`, `_tow_hint`, `_tow_ids`, `_refresh_tow`, `_tow_selected` и их вызовы); экран не меняет `vehicle` и
  `tow_kind` (в `done` — как пришли); выбор крыла доступен всегда. `static tow_kinds_for_site`, `default_tow_kind` —
  остаются (используются окном и тестами).
- **`FlightSettings.trike_allowed(multiplayer: bool) -> bool`** = `not multiplayer` (параметр места убран).
- `locale/ui.csv`: новые ключи `start_choice_title`, `start_choice_tow`, `start_choice_glider`, `start_choice_trike`
  (ru/en); `setup_start_trike`, `setup_tow_mp_off` — удалить, если больше не используются.
- **Инварианты теста:** (1) `trike_allowed(false)` true, `trike_allowed(true)` false; (2) окно для `wilotree_park/runway_36`
  — пункты «Нет» + `tow.kinds` места; для `altai/sinyukha_west` и `{}` — «Нет» + оба вида; (3) `StartMenu` без сети:
  «Лететь» → окно видно, `fly_requested` не испущен; «Дельталёт» → `fly_requested` с `vehicle "trike"`, `tow_kind ""`;
  «Дельтаплан» с «Лебёдка» → `"glider"`, `"winch_static"`; «Отмена» → сигнала нет; (4) в сети — `fly_requested` сразу,
  `"glider"`, `""`, окна нет; (5) у `FlightSetupScreen` нет `_tow_opt`; `vehicle "trike"`, `tow_kind "aerotow"` проходят
  через `set_settings` → `done` без изменений.

## TA-К2 v1. Старт дельталёта и буксировки в любом месте (`Game`)
Владелец — TA-2. Потребители — нет (игра). Контрактный тест — `tests/contracts/test_trike_anywhere_k2.gd` (пишет TA-2).

`scripts/game/game.gd`, `_choose_tow_start()` (`kind` = `"aerotow"` у дельталёта, иначе `settings.tow_kind`):
- Сеть или старт в воздухе → `false`, дельтаплан без буксировки (как сейчас). `kind` пуст у дельтаплана → `false`.
- **Линия** (начало — точка старта, ось — курс старта):
  - точный старт — его точка и курс (площадка с `tow` в пределах 5 м — её ось, длина, ширина: как сейчас);
  - точка с карты — точка, курс выбранный или `StartPlacement` (как сейчас);
  - иначе площадка `settings.site_id` (нет — первая): `position`, `heading_deg`; длина и ширина — из её блока `tow`, а у
    площадки без `tow` — общие: `configs/tow.json` `winch_static.rope_length_m` / `aerotow.runway_length_m`,
    ширина `TOW_DEFAULT_WIDTH_M` (раньше такая площадка давала `false` — снято);
  - места без площадок — точка `(0, h(0,0), 0)`, курс 0.
- **Рельеф не проверяется** (решение 2026-10-23, «пусть экспериментирует»): старт не отклоняется по уклону, перепаду,
  ровной длине, границам рельефа и т. п. — берутся начало линии (`start_pos` на земле) и курс. Отказ (`false` с
  `push_warning`) — только при нечисловых входах. `_tow_site` заполнен как сейчас (`start_pos`, `end_pos`, `heading_deg`,
  `width_m`, `length_m`), `TowSession` строится как сейчас (лебёдка/Ан-2 на линии — даже если упираются в склон).
- Поляна: площадка с блоком `tow` — без вырубки (как сейчас); иначе — `_clear_tow_runway()` (как у точки с карты сейчас).
- Курс по ветру не выравнивается (`_exact_start = true`, как сейчас).
- **Дельталёт** (`vehicle == "trike"`, не сеть, не в воздухе): всегда `_trike_start = true` — на колёсах
  (`glider.reset_on_wheels(_start_pos, _start_heading)`), заглушен, полный бак, без `TowSession`, на любом месте и склоне;
  дельтапланом не подменяется. «Ещё раз» (R) — снова на колёса в начале линии. Прочее TP-К6 — без изменений.
- Дельтаплан без буксировки — без изменений.
- **Инварианты теста** (главная сцена с `LaunchOptions` `--autostart`, по образцу `test_trike_pilot_k6.gd
  test_game_trike_start`; без лётных проверок — только что старт собирается):
  (1) `--location=altai --site=sinyukha_west --vehicle=trike`: в полёте, `glider.is_trike()`, `phase() == "wheels"`,
  `input_controller.vehicle == "trike"`, `tow_session == null`, двигатель `"off"`, положение модели ≤ 3 м от позиции
  площадки (`get_start()`), курс старта = `heading_deg` площадки ± 1°; после `restart()` — снова `"wheels"` ≤ 3 м;
  (2) то же — вторая горная площадка `aushkul/aushtau_east`;
  (3) `--location=altai --site=sinyukha_west --tow=winch_static` и `--tow=aerotow`: в полёте, `tow_session != null`,
  положение ≤ 3 м от площадки, 2 с `tick` без ошибок и без NaN в положении;
  (4) `wilotree_park` с `--vehicle=trike` — как TP-К6 (5) (`test_trike_pilot_k6.gd` зелёный).
