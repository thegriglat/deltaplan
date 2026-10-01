# Контракты направления «3D-модели и конфиги крыльев»

Ветка `wings/models3d`, координатор — dp-coordinator. План — `docs/plan/wings_models3d.md`, журнал — `docs/plan/wings_models3d_progress.md`. Меняет интерфейс только координатор: версия +1, что изменилось, правка всех потребителей в том же шаге.

## К1. Параметры формы крыла `tools/blender/glider_params.json → wings.<id>` — версия 1 (как в коде)

- Владелец: `tools/blender/build_gliders.py` (`WingShape`, сборка). Потребители: генератор новых записей (W3-02), `tools/research/data/wing_passports/wings3d_geometry.py`, `tests/game/test_wing_models_contract.gd`, `render_views.py`.
- Поля и единицы — `docs/models.md`, «Параметры крыла» (метры, градусы; оси Blender: X вправо, +Y нос, Z вверх). Обязательные: `config` (= id), `out` (= `glider_<id>`), `nose_angle_deg`, `root_chord_m`, `tip_chord_m`, `nose_forward_m`, `keel_extra_m`, `dihedral_deg`, `washout_deg`, `camber` [3], `double_surface`, `lower_cover`, `le_thickness`, `battens_per_side`, `kingpost_m`, `crossbar_u`, `luff_lines`, `basebar_width_m`, `faired_uprights`, `wheels`, `tube_color`, `tube_rough`, `tube_metal`, `design`. Необязательные — по `docs/models.md`.
- Размах и площадь: берутся из `configs/wings/<id>.json`; `span_m`/`area_m2` в записи — только если конфига нет; если есть — обязаны совпадать с конфигом (размах ±0,01 м).
- Хорда: `c(a) = tip + (root − tip)(1 − a^0,85)`, скругление законцовки при `a > 0,9` (если `tip_round` не false). Площадь в плане `S = b·∫c(a)da`.
- Инварианты: площадь в плане — ±2 % от `area_m2` конфига; `kingpost_m > 0` ⇔ `kingpost: true` в конфиге; при `double_surface_pct ≥ 50` — `double_surface: true` и `lower_cover = pct/100 ± 0,1`; `battens_per_side` 5…20.

## К2. Конфиг крыла ↔ модель ↔ перевод — версия 1

- Владелец: конфиги `configs/wings/<id>.json` (W3-01 — существующие, W3-02 и волны N — новые). Потребители: игра (`WingCatalog`, `Config`, `GliderVisual`), тесты крыльев.
- `visual.visual_model` = `res://assets/models/glider_<id>.glb`, файл есть; `name` — ключ `locale/ui.csv` с непустыми `ru` и `en`; `group` — id из `configs/wing_groups.json`; поля и `_doc` — как у существующих конфигов (`tests/flight/test_wings.gd`, `NEW_FIELDS`).
- Модель: контракт имён и осей — `docs/models.md` (`Sail`, `Frame`, `ControlFrame`, `HangPoint`, `BaseBar`, `InstrumentMount`, `VarioMount`, `WingTipL/R`; ≤ 14 тыс. треугольников), проверка — `scenes/models_preview/check_models.gd`.
- Контрактный тест: `tests/game/test_wing_models_contract.gd` (К1-инварианты + К2) — для **всех** `configs/wings/*.json`, без списка id.

## К3. Машиночитаемая спецификация новых крыльев `tools/research/data/wing_passports/out/wings3d_spec.json` — версия 2 (ввела W3-02)

v2 (2026-10-01, по итогам W3-02; потребитель — только `make_new_wings.py`, правки в том же шаге): `span_m`/`area_m2` — только в `config`, в `params` их нет (К1: при наличии конфига лишние); необязательное поле `manual` — строки «Что задать» без числа (например, «небольшой» кингпост у N15) — решает исполнитель волны с пометкой; блок `dhv` — только из карточек DHV или цитат с «DHV» (плакаты HGMA не дают «Startgewicht»); массы пилота округляются до 1 кг. Правки вида крыла сверх спецификации — `tools/research/data/wing_passports/wings3d_overrides/<id>.json` (по файлу на крыло, скрипт применяет их при каждом запуске).

- Владелец: `make_3d_tz.py` (тот же расчёт, что пишет таблицы «Что задать» ТЗ — числа в ТЗ и в спецификации обязаны совпадать). Потребители: применяющий скрипт (W3-02), исполнители волн N.
- Форма (по id, ключи — id из сводки ТЗ):
  ```
  {"<id>": {"section": "N1", "title": "Icaro Piuma", "size": "M", "priority": "P1",
            "base": "training",                     // id базовой записи glider_params и базового конфига
            "params": {<поле К1>: значение, …},      // только то, что задаёт таблица «Что задать»; остальное — от базы
            "config": {"span_m", "area_m2", "wing_mass_kg", "pilot_mass_min_kg", "pilot_mass_max_kg",
                       "double_surface_pct", "kingpost", "group", "era", "prototype",
                       "dhv": {"vmin_vg0_kmh", "vmax_vg0_kmh", "takeoff_mass_min_kg", "takeoff_mass_max_kg", "vne_kmh", "cert"}},
                                                     // значение null — нет в паспорте; единицы SI/км/ч/кг
            "sources": ["ключи wings_merged.json"]}}
  ```
- Нет значения в паспорте — `null`, не выдумывать; применяющий скрипт тогда берёт значение базы и пишет это в `_doc`.

## К4. Поляра и скорости нового крыла (правило, версия 2)

v2 (2026-10-01, решение пользователя на шлюзе 1 — вариант А): порог 10 % отменён; расхождение сваливания поляры с DHV Vmin пишется в `_doc` всегда и сравнивается с таким же расхождением у базы (DHV-аналоги баз: combat — Combat GT 12.7, laminar — Orbiter 14, target — Fox 13; у training, sport, magic данных нет — «сравнить не с чем»). Пересчёт DHV Vmin — по нагрузке на крыло √((m/S)/(m_DHV/S_DHV)). У самих баз расхождение −10 % (combat), −21 % (laminar), −11 % (target): DHV Vmin систематически выше сваливания поляры (вероятно, другое определение). Потребитель — `make_new_wings.py`, правка в том же шаге.

Решения пользователя: приоритет DHV; поляры без данных DHV не менять; абсолютным L/D заявок не верить. Своих поляр у новых крыльев нет, поэтому поляра — **поляра базового крыла того же класса (база из ТЗ), перенесённая подобием на нагрузку нового крыла**:

- `f = √( (m_ref,new·g / S_new) / (m_ref,base·g / S_base) )`, где `m_ref` = `pilot_mass_ref_kg + wing_mass_kg` (полная эталонная масса), `S` = `area_m2`.
- Все скорости поляры, `trim_speed_kmh`, `full_pull_speed_kmh`, `full_push_speed_kmh`, скорости в `reference` × `f`; снижения поляры и в `reference` × `f`; `reference.best_glide` — как у базы (подобие не меняет L/D: мы не придумываем качество). Остальная физика (крен, сваливание, разбег, `wind_max_ms`) — как у базы.
- DHV `vmin_vg0_kmh` (если есть) — **проверка, не подгонка**: пересчёт на эталонную массу по √(m_ref / m_DHV), где m_DHV — середина испытательного диапазона «Startgewicht» (оговорка: при какой массе DHV мерил Vmin, в карточке не сказано); расхождение — в `_doc` конфига (v2: всегда, относительно базы), не править.
- `pilot_mass_min/max_kg` — hook-in производителя, иначе DHV «Startgewicht» минус масса крыла (с пометкой); `pilot_mass_ref_kg` — как у базы по положению в диапазоне: `min + (ref_base − min_base)/(max_base − min_base)·(max − min)`, округлить до 1 кг.
- Если по модели DHV даёт точки поляры (сейчас таких нет) — правило пересматривается через координатора.
