---
type: "registry"
status: "active"
module: ""
area: "process"
updated: "2026-10-15"
summary: "Архив: что влито в игру (план каждого модуля) и что отклонено — почему и что вместо."
related: ["docs/contracts/docs-rework.md", "docs/plan/docs-rework/modules.tsv"]
---
# Архив

Решения по статусам — `docs/plan/docs-rework/modules.tsv` (сверка с кодом и git, 2026-10-15). Журналы модулей — `docs/plan/<модуль>/` (данные dpcli), здесь их нет. `docs/archive/**` в `docs check` не входит, у части старых файлов нет frontmatter.

Раскладка: `plan/` — планы и журналы влитых модулей; `rejected/` — отклонённое (в начале каждого файла: почему и что вместо). Контракты влитых модулей остались в `docs/contracts/` со статусом `closed`, контракты отклонённых лежат в `rejected/` с суффиксом `-contracts`.

## Влито

| Модуль | Что в игре | План |
|---|---|---|
| aframe-geometry | Геометрия трапеции и пилота, вид от первого лица (влито 05.10) | [plan/aframe-geometry.md](plan/aframe-geometry.md) |
| air-model | Модель воздуха: GPU-Пикар, клипмапы, WindField в `scripts/atmosphere/air_model`; AM-11 и AM-12 не начаты и устарели | [plan/air-model.md](plan/air-model.md) |
| air-phase | Поле ветра по фазам + GPU-Пикар вместо сети, 26 задач влиты | [plan/air-phase.md](plan/air-phase.md) |
| air-square | Клетка решателя 400 м, область 38,4 км всегда в слое рельефа (контракты — общие с air-model) | [plan/air-square.md](plan/air-square.md) |
| air-start | Воздух у старта (влито 02.10) | [plan/air-start.md](plan/air-start.md) |
| control-bar | Ввод с физической трапеции через HID-джойстик | [plan/control-bar.md](plan/control-bar.md) |
| control-fix | Исправление регрессии управления на старте в 1.0.0 (влито 02.10) | [plan/control-fix.md](plan/control-fix.md) |
| debug-draw | Аддон Debug Draw 3D удалён, стрелки ветра F5 — своим кодом | [plan/debug-draw.md](plan/debug-draw.md) |
| easter-eggs | Живой мир и небо, 16 задач влиты | [plan/world-easter-eggs.md](plan/world-easter-eggs.md) |
| feedback-1012 | Мелочи по отзыву пилота 12.10: индикатор смещения пилота, старт ровно в точке с карты, крыло на земле без раскачки (FB-1…3) | [plan/feedback-1012.md](plan/feedback-1012.md) |
| feedback-1013 | Время суток и солнце для термиков: при солнце под горизонтом нет нового потока тепла (FBW-1) | [plan/feedback-1013.md](plan/feedback-1013.md) |
| motion-rig | Вывод движения на платформы подвижности: DOF Reality через Sim Racing Studio API и свой UDP (MR-1…6) | [plan/motion-rig.md](plan/motion-rig.md) |
| mountain-look | Сглаживание DSM только в лесу и застройке, заострение дальних вершин; MLK-7 перенесён в TODO T-78 | [plan/mountain-look.md](plan/mountain-look.md) |
| multiplayer | Сетевая игра M0–M5 и сервер на Go (0.8.0); открытое — TODO T-37…T-39 | [plan/multiplayer.md](plan/multiplayer.md) |
| no-osm | Игра без Overpass: посёлки и дома процедурно из пятен застройки WorldCover (9 задач) | [plan/no-osm.md](plan/no-osm.md) |
| on_demand_location | Идея списка мест и закачки данных по месту; сделано модулем osm-any (закрыто 09.10) | [plan/on_demand_location.md](plan/on_demand_location.md) |
| osm-any | Сборка места для любой точки в самой игре, кеш `user://locations` | [plan/osm-any.md](plan/osm-any.md) |
| osm-look | Вид объектов OSM: дома по типам, дым, опоры ЛЭП, ветряки (влито 11.10) | [plan/osm-look.md](plan/osm-look.md) |
| osm-tiles | Тайлы OSM 20 км: упаковщик на Rust, клиент в игре, хранилище R2 | [plan/osm-tiles.md](plan/osm-tiles.md) |
| pendulum | Режим управления «Маятник» — в игре с 1.5.4 как экспериментальный; PD-29 выключен | [plan/pendulum.md](plan/pendulum.md) |
| perf | Оптимизация по замерам PF-1; остатки — TODO T-70, T-79 | [plan/perf.md](plan/perf.md) |
| pilot-hud | Усилие на трапеции, часы, компас и другие честные сигналы пилоту (PH-1…9) | [plan/pilot-hud.md](plan/pilot-hud.md) |
| pilot-view | Вид из кабины: высота подвеса, камера и FOV, изогнутая штанга (влито 08.10) | [plan/pilot-view.md](plan/pilot-view.md) |
| popular-places | Каталог 684 стартов дельтаплана, окно «Популярные места» | [plan/popular-places.md](plan/popular-places.md) |
| qol | Цикл «упал — снова» и мелочи старта (11 задач; QL-2, 4, 6 остановлены пользователем) | [plan/qol.md](plan/qol.md) |
| site-i18n | Сайт на двух языках, en в корне и ru под `/ru/` (влито 05.10) | [plan/site-i18n.md](plan/site-i18n.md) |
| site-update | Обновление сайта, октябрь 2026 | [plan/site-update.md](plan/site-update.md) |
| start-camp | Лётный выезд у старта: палатки, снаряжение, люди (SC-1…12) | [plan/start-camp.md](plan/start-camp.md) |
| start-fixes | Фиксы старта с земли (влито 30.09) | [plan/start-fixes.md](plan/start-fixes.md) |
| start-map | Топокарта на экране выбора старта и высота точки (влито 05.10) | [plan/start-map.md](plan/start-map.md) |
| start-pick | Точный старт: точка и направление разбега (SP-1…4) | [plan/start-pick.md](plan/start-pick.md) |
| steam | `scripts/steam`: лобби, Rich Presence, ачивки | [plan/steam.md](plan/steam.md) |
| steam-assets | Лицензии и атрибуции сборки; SA-5 отменена | [plan/steam-assets.md](plan/steam-assets.md) |
| surface-heat | Поток тепла с поверхности по классу покрова для Пикара и термиков (влито 10.10) | [plan/surface-heat.md](plan/surface-heat.md) |
| ui-controls | Раскладка тангажа «как у дельтапланериста» (влито 02.10) | [plan/ui-controls.md](plan/ui-controls.md) |
| wind-limits | Предельный ветер по классам крыльев; WL-1 отложена пользователем | [plan/wind-limits.md](plan/wind-limits.md) |
| wing-physics-check | Проверка физики и параметров крыльев (влито 01.10) | [plan/wing-physics-check.md](plan/wing-physics-check.md) |
| wings-models3d | 3D-модели и конфиги крыльев по ТЗ (влито 01.10) | [plan/wings-models3d.md](plan/wings-models3d.md) |
| wings-passports | Конфиги крыльев по паспортам и ТЗ на 3D; плана нет, только журнал | [plan/wings-passports-progress.md](plan/wings-passports-progress.md) |
| run-anim, run-heading | Плана и задач нет: журналы заведены 07.10 пустыми | [run-anim](../plan/run-anim/events.jsonl), [run-heading](../plan/run-heading/events.jsonl) |

Не в архиве, потому что живые: `docs/plan/scene-look.md` (идёт, открыты Q4, T-81, T-82), `offline_world_data` и `osm_vector_pack` (отложены), `docs-rework`, идеи в `docs/plan/game/`.

Исследования модели воздуха и другие материалы для статьи остаются в `docs/research/` и `tools/research/`.

## Отклонено

| Модуль | Почему | Вместо | Файлы |
|---|---|---|---|
| air-nn | Сеть не достигла заменимости решателя; вытеснена фазовой сборкой и GPU-Пикаром, удалена из игры в AP-21 (07.10.2026, CHANGELOG 1.3.0) | [air-phase](plan/air-phase.md) | [план](rejected/air-nn.md), [контракты](rejected/air-nn-contracts.md), [журнал до 02.10](rejected/air-nn-progress.md) |
| air-nn, этап P3 | Этап P3 модуля air-nn; сеть удалена из игры в AP-21 | [air-phase](plan/air-phase.md) | [план](rejected/air-nn-p3.md), [контракты](rejected/air-nn-p3-contracts.md) |
| air-onnx | ONNX-рантайм сети удалён из игры в AP-21 (коммит a9fca9fa) вместе с сетью | [air-phase](plan/air-phase.md) | [план](rejected/air-onnx.md), [контракты](rejected/air-onnx-contracts.md) |
| air-synth | Сеть SY-11 влита 05.10, удалена в AP-21 вместе с остальными; корпус остался в `tools/research/air_synth` | [air-phase](plan/air-phase.md) | [план](rejected/air-synth.md), [контракты](rejected/air-synth-contracts.md) |
| ann2 | AN-4: ошибка ≈ 22 % при цели 10–15 %, направление отложено 04.10.2026 (`docs/plan/ann2/decisions.jsonl`), затем сети удалены | [air-phase](plan/air-phase.md) | [план](rejected/ann2.md), [контракты](rejected/ann2-contracts.md) |
| wind-field | План поля ветра заменён планом air-model (три масштаба, среднее поле — Пикар; 29.09.2026) | [air-model](plan/air-model.md) | [план](rejected/wind-field.md) |
