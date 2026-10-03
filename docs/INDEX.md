---
type: "registry"
status: "active"
module: ""
updated: "2026-10-04"
summary: "Все документы docs/ и паспорта исследований: путь, тип, статус, summary; точка входа."
related: []
generated: true
---

# Индекс документации

Точка входа в документацию. Что мы знаем про X — [выводы](/docs/registry/findings.md), `dp docs find`, `dp docs findings`, `dp search`. Файл собран `dp docs index` — руками не править.

## Описания систем (guide)

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [docs/guide/air-model-gpu.md](/docs/guide/air-model-gpu.md) | guide | active | air-model | Модель воздуха на GPU: строительные блоки (AM-02) — Эталоны — tools/research/air3d/gpu_block_refs.py (numpy, float64 по формулам ядер и прикидки) → tests/atmosphere/fixtures/air_model/blocks/*.bin + .json (f32 LE, ~2,5 МБ). |
| [docs/guide/air-model.md](/docs/guide/air-model.md) | guide | active | air-model | Модель воздуха в трёх масштабах — Среднее поле воздуха (решение Пикара, масштаб 1) в игре читается на CPU: air_velocity_at зовут физика крыла (3 точки × 120 Гц), боты, птицы, колдун. |
| [docs/guide/architecture.md](/docs/guide/architecture.md) | guide | active |  | Архитектура — Godot 4.7.2 (godot в PATH), GDScript, рендер Forward+. |
| [docs/guide/atmosphere.md](/docs/guide/atmosphere.md) | guide | active | atmosphere | Атмосфера — Модуль scripts/atmosphere/: ветер, термики, фоновое опускание, склоновый подъём, подветренные зоны и роторы (FR-8, FR-11…FR-16), кучевые облака, их тени и птицы (FR-14, FR-14a, FR-22, VR-1, VR-2). |
| [docs/guide/flight.md](/docs/guide/flight.md) | guide | active | flight | Модель полёта (scripts/flight/) — Реализует FR-1…FR-10. Логика — в RefCounted-классах (тестируются headless), нода Glider — тонкая обёртка: время, ввод, визуал. |
| [docs/guide/game.md](/docs/guide/game.md) | guide | active | game | Сборка игры (scenes/main, scenes/game, scenes/ui) — Главная сцена собирает модули в играбельный полёт: меню → полёт ⇄ пауза → итог. |
| [docs/guide/instruments.md](/docs/guide/instruments.md) | guide | active | instruments | Приборы и звук вариометра — Instrument3D: экран смотрит в локальную +Z, верх — +Y, начало — центр корпуса, хомут сзади снизу. |
| [docs/guide/models.md](/docs/guide/models.md) | guide | active | wings | Модели (крылья, пилот, приборы, деревья) — Все модели генерируются скриптами Blender 4.3 (воспроизводимо, параметры в JSON рядом со скриптами), исходники .blend и текстуры — в assets/source/ (там .gdignore), готовые .glb — в assets/models/. |
| [docs/guide/net-protocol.md](/docs/guide/net-protocol.md) | guide | active | net | Сетевой протокол Deltaplan — Единственный источник правды — server/proto/deltaplan/v1/net.proto (пакет deltaplan.v1). |
| [docs/guide/tasks.md](/docs/guide/tasks.md) | guide | active | game | Задания, тренировки, рекорды — FR-35 (маршрутный полёт), FR-36 (тренировки), FR-37 (рекорды), NFR-6, NFR-7. |
| [docs/guide/telltale.md](/docs/guide/telltale.md) | guide | active | wings | Ленточка на тросе трапеции («ниточка», yaw string) — Просьба пилота: ленточка, привязанная к переднему тросу трапеции (сначала висела на боковом; перевешена по просьбе пользователя, wire: "front"). |
| [docs/guide/terrain.md](/docs/guide/terrain.md) | guide | active | terrain | Рельеф и мир — FR-17…FR-20, VR-3, VR-4, VR-0, NFR-1, NFR-2. |
| [docs/guide/vegetation.md](/docs/guide/vegetation.md) | guide | active | vegetation | Растительность вблизи камеры — Группа «Растительность» (V01: рекомендации 1, 3, 4 из docs/plan/README.md, группа 5; V02 — деревья по маске леса 10 м). |
| [docs/guide/world-objects.md](/docs/guide/world-objects.md) | guide | active | world | Объекты мира (world_objects) — VR-6, VR-7, VR-9, VR-10, VR-12, VR-13, NFR-1, NFR-2. |

## Контракты стыков

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [docs/contracts/air-model.md](/docs/contracts/air-model.md) | contract | active | air-model | Модель воздуха: контракты систем — Интерфейсы на стыках задач плана docs/plan/air_model.md (AM-00…AM-12). |
| [docs/contracts/air-nn-p3.md](/docs/contracts/air-nn-p3.md) | contract | active | air-nn | Контракты пилота П-3 air-nn: П2 v5 — физическая кодировка входа (27 карт) и выхода (117 каналов: разгон/поворот к линейной базе, отрыв от склона), линейная база Б1; П3 v4 — таблица вариантов и сводка заменимости |
| [docs/contracts/air-nn.md](/docs/contracts/air-nn.md) | contract | active | air-nn | Контракты модуля air-nn — Изменение интерфейса — только через координатора: версия +1, что изменилось, уведомление потребителей. |
| [docs/contracts/air-onnx.md](/docs/contracts/air-onnx.md) | contract | active | air-onnx | Контракты модуля air-onnx: формат .onnx сети области (O1), расширение ONNX Runtime (O2), вход/выход сети в GDScript (O3), вход из игры и страж (O4), AirRuntime engine=nn (O5), файл сети (O6). |
| [docs/contracts/control-fix.md](/docs/contracts/control-fix.md) | contract | active | control-fix | Контракты модуля «control-fix» — v1 (до CF-3): pitch: float ∈ [−1, 1] — +1 трапеция от себя (нос вверх), −1 на себя; на земле — угол носа крыла (+ нос вверх). |
| [docs/contracts/easter-eggs.md](/docs/contracts/easter-eggs.md) | contract | active | easter-eggs | Контракты модуля «Пасхалки: живой мир и небо» — Версия: 5 (01.10.2026). v4 → v5: перед E10 — К9 «другая группа»: доп. |
| [docs/contracts/start-fixes.md](/docs/contracts/start-fixes.md) | contract | active | start-fixes | Контракты модуля «start-fixes» |
| [docs/contracts/ui-controls.md](/docs/contracts/ui-controls.md) | contract | active | ui-controls | Контракты модуля «ui-controls» — Действия (имена — смысл, не клавиша): pitch_push_out = [Up] — трапеция от себя → pitch +; pitch_pull_in = [Down] — на себя → pitch −. |
| [docs/contracts/wing-physics-check.md](/docs/contracts/wing-physics-check.md) | contract | active | wing-physics-check | Контракты модуля wing-physics-check |
| [docs/contracts/wings-models3d.md](/docs/contracts/wings-models3d.md) | contract | active | wings-models3d | Контракты направления «3D-модели и конфиги крыльев» — Владелец: tools/blender/build_gliders.py (WingShape, сборка). |

## Исследования в docs/research

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [docs/research/air-model-sensitivity.md](/docs/research/air-model-sensitivity.md) | research | closed | air-model | Чувствительность модели воздуха: отбор по Моррису (все параметры и переключатели) — Исследование по просьбе автора: какие ручки модели двигают какие наблюдаемые, и жёсткая ли модель там, где это важно пилоту. |
| [docs/research/air-model-tune.md](/docs/research/air-model-tune.md) | research | closed | air-model | Калибровка модели воздуха по схеме Professor (AM-09) — Корреляция λ/h–z0 равна 0 (ρ = −0,00). |
| [docs/research/air_field_cache.md](/docs/research/air_field_cache.md) | research | closed | air-model | Размер поля воздуха и кеш вариантов запуска — Вопрос пользователя: сколько весит рассчитанное поле воздуха (GPU-модель scripts/atmosphere/air_model/) и можно ли при сохранении места заранее посчитать поля для всех вариантов запуска и положить их в кеш, чтобы загрузка была … |
| [docs/research/air_physics_primer.md](/docs/research/air_physics_primer.md) | research | active | air-nn | Физика воздуха над рельефом — обзор для автора проекта: уравнения и масштабы, пограничный слой, обтекание, стратификация, седловины, термики, турбулентность; наш решатель, его границы и что выучила сеть. |
| [docs/research/atlas_wing.md](/docs/research/atlas_wing.md) | research | closed | wings | Учебно-тренировочный дельтаплан «Атлас» (СССР): данные из статьи — Выписка для модели крыла configs/wings/atlas.json и 3D-модели glider_atlas.glb. |
| [docs/research/calibration_data.md](/docs/research/calibration_data.md) | research | closed | flight | Табличные данные для калибровки атмосферы и поля ветра — Все наборы данных (что где лежит, статус, ограничения) — в каталоге docs/research/experimental_data.md. |
| [docs/research/competition_rules.md](/docs/research/competition_rules.md) | research | closed | game | Правила маршрутных соревнований (дельтапланеризм) — Кратко — то, что нужно для FR-35. Первоисточники: FAI Sporting Code Section 7A (Cross Country — общие правила, класс 1 = дельтапланы) и Section 7F (XC Scoring — формула GAP, геометрия заданий). |
| [docs/research/control_frame_refs.md](/docs/research/control_frame_refs.md) | research | closed | flight | Референсы: трапеция (control frame) и вид с места пилота — Собрано для повышения реалистичности процедурных Blender-моделей трапеции и деталей, видимых с точки обзора пилота. |
| [docs/research/experimental_data.md](/docs/research/experimental_data.md) | research | closed | flight | Каталог экспериментальных и эталонных данных для модели воздуха — Единая точка входа: какие данные есть, где лежат, что дают и для чего годятся. |
| [docs/research/glider_3d_tz.md](/docs/research/glider_3d_tz.md) | research | closed | wings | ТЗ на 3D-модели крыльев по паспортам (DHV, производители): раздел на крыло, самодостаточный для исполнителя. |
| [docs/research/glider_models.md](/docs/research/glider_models.md) | research | closed | wings | Список моделей дельтапланов — Сгенерировано tools/research/data/wing_passports/consolidate.py (2026-09-30). |
| [docs/research/glider_polars_sources.md](/docs/research/glider_polars_sources.md) | research | closed | flight | Открытые источники характеристик и поляр современных дельтапланов — Разведка от 2026-09-30. Всё, что ниже, проверено скачиванием (кроме помеченного «не проверено»). |
| [docs/research/itch_multiplayer.md](/docs/research/itch_multiplayer.md) | research | closed | net | Сетевая игра «через itch.io»: что даёт itch и какие есть альтернативы — Дата: 01.10.2026. Контекст: семья и друзья (2–10 человек), голос внешний, свой сервер на Go уже есть (server/, docs/guide/net-protocol.md, docs/plan/multiplayer.md). |
| [docs/research/ordodi_1984_konstruktsiya.md](/docs/research/ordodi_1984_konstruktsiya.md) | research | closed | flight | Ордоди М., «Дельтапланеризм» (1984) — глава 3.2 «Как строить дельтапланы» |
| [docs/research/pilot_mass.md](/docs/research/pilot_mass.md) | research | closed | flight | Масса пилота и поляра дельтаплана (FR-3) — Исследование для модели полёта: как масса пилота меняет скорости, снижение, качество и реакцию крыла, и какие реальные данные взяты для трёх крыльев. |
| [docs/research/slope_wind.md](/docs/research/slope_wind.md) | research | closed | air-model | Обтекание склона ветром: что у нас сейчас, как в жизни, что можно сделать — Исследование, без правок кода. Повод — отзыв пилота: «обтекание склона ветром ощущается не физично». |
| [docs/research/sounds.md](/docs/research/sounds.md) | research | closed | instruments | Звук: ассеты и процедурный синтез (FR-28, FR-29) — Итог: 51 файл, 8,2 МБ в assets/sounds/ (ориентир был ≤ 30 МБ). |
| [docs/research/surface_params.md](/docs/research/surface_params.md) | research | closed | air-model | Параметры поверхности по классам покрова (контракт П4 v1) — Для чего выбраны значения: дневной летний полёт (≈10–16 ч местного, ясно или малооблачно), умеренные широты, Альпы/предгорья. |
| [docs/research/terrain_sources.md](/docs/research/terrain_sources.md) | research | closed | terrain | Источники рельефа и карт (FR-17 … FR-20) — Дата проверки: 2026-09-27. Всё ниже проверено запросами с этой машины, кроме помеченного «(по документации)». |
| [docs/research/thermals.md](/docs/research/thermals.md) | research | closed | air-model | Модели термиков, склонового подъёма и подветренных потоков — Исследование для модуля атмосферы (FR-8, FR-11…FR-16). |
| [docs/research/vario_sounds.md](/docs/research/vario_sounds.md) | research | closed | instruments | Звук вариометров 1990-х (кратко, FR-25a) — Цель — правдоподобный «звук той эпохи» для пресета classic_90s, без привязки к модели и бренду (решение пользователя: конкретные модели не нужны). |
| [docs/research/visual_cues.md](/docs/research/visual_cues.md) | research | closed | flight | Визуальные признаки для пилота: что должно быть видно в симуляторе — Исследование к FR-14a, FR-19, FR-20, FR-21, FR-22, FR-26. |
| [docs/research/wing_sources.md](/docs/research/wing_sources.md) | research | closed | wings | Источники по моделям дельтапланов — Где искать внешний вид и характеристики крыльев (для линейки — docs/plan/wings_lineup.md). |
| [docs/research/wings_config_sources.md](/docs/research/wings_config_sources.md) | research | closed | wings | Паспорта крыльев → конфиги configs/wings/*.json: что изменено, источники, противоречия — Принципы: физика прежде «нравится»; число меняется, только если есть паспорт той же модели и размера (или явно помеченный аналог); абсолютным L/D из заявок не верим; при противоречии не подгоняем молча, а фиксир |
| [docs/research/xc_reference.md](/docs/research/xc_reference.md) | research | closed | game | Эталоны маршрутных XC-полётов на дельтаплане (карточка 02) — Ориентиры для сравнения с ботом (tests/atmosphere/xc/, tools/atmosphere/xc_matrix.sh). |

## Исследования в tools/research

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [tools/research/a1/README.md](/tools/research/a1/README.md) | research | closed |  | А1.1 — пробы для плана структурных правок решателя воздуха — Воспроизведение (из этого каталога; venv с CuPy и brotli — tools/research/morris/README.md; здесь использован /home/greg/deltaplan-wf-morris/tools/research/tune/.venv): bash PY=/home/greg/deltaplan-wf-morris/tools/research/tune… |
| [tools/research/a1/review/README.md](/tools/research/a1/review/README.md) | research | closed |  | А1.3 — ревью структурных правок решателя воздуха (А1.2) — Воспроизведение (из этого каталога; venv с CuPy — tools/research/morris/README.md): bash PY=/home/greg/deltaplan-wf-morris/tools/research/tune/.venv/bin/python /home/greg/deltaplan/tools/dp job start a1rev 3600 sh run_all.sh # … |
| [tools/research/a2pre/README.md](/tools/research/a2pre/README.md) | research | closed |  | Разведка перед А2: сходимость и цена решателя воздуха на новых параметрах — Записка с выводом — docs/archive/plan/air-model-a2pre.md. |
| [tools/research/air3d/README.md](/tools/research/air3d/README.md) | research | closed |  | air3d: 3D-Пикар на рельефе Онгудая (оценка для библиотеки опорных полей) — Прикидка к плану docs/plan/air_model.md (масштаб 1 «среднее поле Пикаром», раздел «Библиотека опорных полей»): грубое, но честное 3D-решение на реальном рельефе, чтобы получить числа — время решения, итерации, сходимость, раз |
| [tools/research/air3d/summary.md](/tools/research/air3d/summary.md) | research | closed |  | 3D-Пикар на рельефе Онгудая: время, сходимость, размер поля — итог прикидки — Эталон AM-01 (29.09.2026) — reference.md. |
| [tools/research/air_clipmap/README.md](/tools/research/air_clipmap/README.md) | research | closed | air-model | Стык уровней клипмапа AM-04: профиль поля вдоль линии через края окон 50 и 100 м, выборка игры против отдельных уровней. |
| [tools/research/air_model_baseline/README.md](/tools/research/air_model_baseline/README.md) | research | closed | air-model | AM-00: зонд базовых цифр до новой модели воздуха (время air_velocity_at, статистика рывков за подветренной зоной, термики за день). |
| [tools/research/air_nn_pilot/README.md](/tools/research/air_nn_pilot/README.md) | research | closed | air-nn | Пилот air-nn (этап П): может ли малая сеть заменить решатель поля ветра — В терминале — только строка этапа и одна обновляемая строка прогресса (единицы этапа, %, сколько осталось): пилот air-nn: прогон 2026-10-02_pilot лог: /home/greg/air_nn_data/pilot/runs/2026-10-02_pilot/pilot.log отчёт будет: / |
| [tools/research/air_runtime/README.md](/tools/research/air_runtime/README.md) | research | closed | air-model | AM-06Б: ход среднего поля в точке при пересчёте поля в полёте (плавная подмена уровней, AirRuntime). |
| [tools/research/air_start/README.md](/tools/research/air_start/README.md) | research | closed | air-start | Воздух у старта (air-start) — данные AS-1 — Жалоба пилота на 1.0.0: при 6 м/с на старте «сдувает». |
| [tools/research/air_start/as2/README.md](/tools/research/air_start/as2/README.md) | research | closed |  | AS-2: болтанка и разворот ветра у земли (поле GPU) — замеры — Модель — docs/guide/air-model.md → «Масштаб 3: возмущения из поля» (законы «Механическая болтанка», «Сложение механики и конвекции», «Масштаб конвективной горизонтали», «Перенос вихрей у земли»; таблица «У старта, 1,5 м над зем… |
| [tools/research/air_thermals/README.md](/tools/research/air_thermals/README.md) | research | closed | air-model | AM-07: термики из поля — замеры — Описание модели — docs/guide/air-model.md → «Масштаб 2: термики из поля». |
| [tools/research/air_turb/README.md](/tools/research/air_turb/README.md) | research | closed |  | AM-08: возмущения из поля (масштаб 3) — замеры — Описание модели — docs/guide/air-model.md → «Масштаб 3: возмущения из поля». |
| [tools/research/b2/README.md](/tools/research/b2/README.md) | research | closed |  | Б2: α и λ в игре — профиль притока по устойчивости, пересчёт эталонов и цена — Записка — docs/archive/plan/air-model-b2.md. |
| [tools/research/cases/README.md](/tools/research/cases/README.md) | research | closed | air-model | Случаи калибровки модели воздуха (Askervein, Perdigão, Б1): общие правила постановки и схема решателя, контракт C10. |
| [tools/research/cases/b1/README.md](/tools/research/cases/b1/README.md) | research | closed |  | Б1 — совместная калибровка Askervein + Perdigão (волна Б, контракт C10 v2) — Этап 1 (постановка и сопоставимость) и этап 2 (пачка, совместная подгонка, проверка у лучшей точки, регрессия А2) сделаны; записка — docs/archive/plan/air-model-b1.md. |
| [tools/research/cases/perdigao/README.md](/tools/research/cases/perdigao/README.md) | research | closed |  | Случай Perdigão (А4) — C10 v1 → v2 (Б1) — Б1 (01.10.2026): модуль приведён к C10 v2 — общая схема ../scheme.py, сетка/область/губки/профиль притока по общим правилам ../rules.py (dx 30 м, область 6 км, потолок 1748 м над нулём, губки 1050 м / от высшей точки рельефа, m… |
| [tools/research/data/askervein/README.md](/tools/research/data/askervein/README.md) | research | closed |  | Askervein Hill — данные измерений — Поле измерений на холме Askervein (о. Южный Уист, Шотландия), сентябрь–октябрь 1982–1983: классический эталон обтекания изолированного пологого холма (H ≈ 116 м над окружающей местностью, нейтральная атмосфера, ветер ~210°). |
| [tools/research/data/perdigao/README.md](/tools/research/data/perdigao/README.md) | research | closed |  | Perdigão 2017 — данные для калибровки следа за гребнем — Две параллельные гряды (ось ~SE–NW, азимут перпендикуляра ~45°/225°), расстояние между гребнями ~1.4 км, перепад долина–гребень ~200 м, лес (эвкалипт, сосна) пятнами. |
| [tools/research/data/perdigao/menke2019/summary.md](/tools/research/data/perdigao/menke2019/summary.md) | research | closed |  | Menke et al. 2019 (ACP 19, 2713) — данные для калибровки зоны рециркуляции — Источник: doi:10.5194/acp-19-2713-2019, CC BY 4.0. |
| [tools/research/data/wing_passports/README.md](/tools/research/data/wing_passports/README.md) | research | closed | wings | Паспорта дельтапланов: сводный набор данных — Из страниц/PDF производителей и карточек DHV (разбор LLM Haiku, JSON с цитатами) собран единый набор по моделям и размерам. |
| [tools/research/heat_ca/README.md](/tools/research/heat_ca/README.md) | research | closed |  | Клеточный автомат тепла и массы — 2D-разрез хребта (прототип) — Проверка идеи пользователя (карточка docs/plan/heat_ca_prototype.md): вместо поля ветра «сразу» — клетки, которые обмениваются теплом и массой с соседями, и смотрим, что куда течёт над прогретым склоном. |
| [tools/research/heat_ca/exp1_3_6_kernels/README.md](/tools/research/heat_ca/exp1_3_6_kernels/README.md) | research | closed |  | Опыты 1, 3, 6: линейность, ядра, «ядро струи» — Можно ли «схлопнуть» тысячи шагов клеточного автомата тепла и массы (../model.py, каждый шаг — свёрточный слой с фиксированными весами) в одну свёртку или короткую цепочку фильтров. |
| [tools/research/heat_ca/exp1_3_6_kernels/summary.md](/tools/research/heat_ca/exp1_3_6_kernels/summary.md) | research | closed |  | Опыты 1, 3, 6: линейность, ядра, «ядро струи» — Команды для каждой картинки — README.md. Выходы — в out/, сырые поля — в out/cache/*.npz. |
| [tools/research/heat_ca/exp2_picard/README.md](/tools/research/heat_ca/exp2_picard/README.md) | research | closed |  | Опыт 2: установившееся без шагов по времени — итерации Пикара + прогонки/многосеточный — Прототип клеточного автомата тепла и массы (../README.md) доходит до установившейся картины шагами по времени: ~3–7 ч модели, 1–26 тыс. |
| [tools/research/heat_ca/exp2_picard/summary.md](/tools/research/heat_ca/exp2_picard/summary.md) | research | closed |  | Опыт 2: установившееся без шагов (Пикар + прогонки/многосеточный) — Команды — README.md. Таблицы — out/tables.md, out/results.json; поля — out/runs/*.npz, out/truth/*.npz. |
| [tools/research/heat_ca/exp4_transfer_sweeps/README.md](/tools/research/heat_ca/exp4_transfer_sweeps/README.md) | research | closed |  | Опыт 4: установившееся поле проходами по слоям (матрицы перехода) — Идея пользователя: считать установившееся поле автомата тепла и массы не тысячами шагов по времени, а проходами слой за слоем: «состояние слоя k+1 = M_k · состояние слоя k (+ нагрев у земли)», проход вверх и проход вниз. |
| [tools/research/heat_ca/exp4_transfer_sweeps/summary.md](/tools/research/heat_ca/exp4_transfer_sweeps/summary.md) | research | closed |  | Опыт 4: установившееся поле проходами по слоям (матрицы перехода) — итог — Идея пользователя: установившееся поле автомата тепла и массы считать не тысячами шагов по времени, а проходами слой за слоем — «состояние слоя k+1 = M_k · состояние слоя k (+ нагрев у земли)», проход вверх и проход вниз, мал |
| [tools/research/heat_ca/exp5_adi/README.md](/tools/research/heat_ca/exp5_adi/README.md) | research | closed |  | Опыт 5. Чередующиеся прогонки по линиям (ADI) до установившегося поля автомата — Вопрос: можно ли получить установившееся поле клеточного автомата тепла и массы (../model.py) не тысячами шагов по времени, а раундами неявных прогонок по линиям: в 2D 4 прохода на раунд (вверх/вниз по столбцу, вправо/в |
| [tools/research/heat_ca/exp5_adi/summary.md](/tools/research/heat_ca/exp5_adi/summary.md) | research | closed |  | Опыт 5: чередующиеся прогонки по линиям (ADI) — Невязки считает код самого автомата. Прогонки — только предобусловливатель: коррекция по невязке плюс неполная проекция (SIMPLEC в псевдовремени). |
| [tools/research/morris/README.md](/tools/research/morris/README.md) | research | closed |  | Моррис: чувствительность модели воздуха — Итог и выводы — docs/research/air-model-sensitivity.md. |
| [tools/research/obf_region/README.md](/tools/research/obf_region/README.md) | research | closed |  | Эксперимент: состав OsmAnd OBF региона — К документу docs/plan/offline_world_data.md (раздел «Почему не OsmAnd OBF»). |
| [tools/research/osm_pack/README.md](/tools/research/osm_pack/README.md) | research | closed |  | osm_pack — замер компактного офлайн-пакета (OSM-вектор + рельеф + покров), Словения — Исследование к плану docs/plan/offline_world_data.md (этап 0). |
| [tools/research/recal/README.md](/tools/research/recal/README.md) | research | closed |  | Перекалибровка Askervein по (λ/h, α, z0) с профилем мачты RS — Итог — docs/research/air-model-tune.md, раздел «Перекалибровка (λ/h, α, z0) с профилем RS»; числа — out/fit.json. |
| [tools/research/tune/README.md](/tools/research/tune/README.md) | research | closed | air-model | AM-09: калибровка масштаба 1 и порогов масштаба 3 по Askervein схемой Professor (полиномы по прогонам, χ², eigentunes). |
| [tools/research/wind_compare/README.md](/tools/research/wind_compare/README.md) | research | closed |  | Сравнение поля ветра main и feature/air-model (Онгудай) — Выгрузка из игры (Atmosphere.air_velocity_at / mean_wind_at), не из air.py. |
| [tools/research/windninja/README.md](/tools/research/windninja/README.md) | research | closed | air-nn | WindNinja (массосогласованный) как независимый эталон ветра над рельефом против решателя air-nn: на гребнях разгон совпадает (1,19 против 1,13 от притока), направление совпадает (медиана 10°), но решатель в долинах и подветренных склонах держит 0,3 от притока, WindNinja — 0,84–0,97 (торможения массивом у него нет); как запасной вариант игры годится для разгона на гребнях и поворота, не для затенения. |
| [tools/research/wing_physics_check/README.md](/tools/research/wing_physics_check/README.md) | research | closed | wings | Проверка физики крыльев — данные и инструменты — Модуль wing-physics-check (docs/archive/plan/wing-physics-check.md). |

## Планы (живые и отложенные)

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [docs/plan/README.md](/docs/plan/README.md) | plan | superseded |  | План: группы задач — Верхний уровень плана. Работа делится на группы (области кода). |
| [docs/plan/air_model.md](/docs/plan/air_model.md) | plan | postponed | air-model | План: модель воздуха в трёх масштабах — Документ — для координатора агентов: модули, задачи со скоупом, файлами, приёмкой и оценкой. |
| [docs/plan/air_model_a2.md](/docs/plan/air_model_a2.md) | plan | postponed | air-model | А2: сходимость в штиль — 01.10.2026. Ветка air/a2: feature/air-model 0788cf7 плюс влитая разведка air/a2-pre. |
| [docs/plan/air_nn.md](/docs/plan/air_nn.md) | plan | postponed | air-nn | Нейросеть вместо решателя поля ветра — план — Связанное: модель воздуха — docs/guide/air-model.md, контракты — docs/contracts/air-model.md (C1–C10), код игры — scripts/atmosphere/air_model/; эталонный решатель на CuPy — tools/research/air3d/ (solver.py, air.py, reference.m… |
| [docs/plan/air_nn_p3.md](/docs/plan/air_nn_p3.md) | plan | closed | air-nn | Пилот П-3 air-nn: физическая кодировка входа и выхода сети (база — линейная теория, разгон/поворот, отрыв от склона, уклоны по масштабам, подсеточный рельеф, маска отрыва, формы профиля) на готовых данных П-2; вопрос — что даёт больше: кодировка или ёмкость сети |
| [docs/plan/air_nn_progress.md](/docs/plan/air_nn_progress.md) | journal | postponed | air-nn | air-nn — журнал хода работ — 02.10 (пользователь, через главную сессию): run_pilot.sh в tmux показывает «этап n из N: название» + одну обновляемую строку «сделано/всего, %, ETA» в единицах этапа; после продолжения счётчики учитывают сделанное; подробный ло… |
| [docs/plan/air_onnx.md](/docs/plan/air_onnx.md) | plan | active | air-onnx | Поле ветра в игре считает ONNX-сеть (ORT CPU через GDExtension) вместо GPU-решателя: сквозной путь .onnx → WindField → термики, пункт настроек «нейросеть». |
| [docs/plan/game/01-priemka-kabiny.md](/docs/plan/game/01-priemka-kabiny.md) | plan | closed |  | 12-01. Приёмка кабины по фиксированным кадрам (VR-11, FR-25a, VR-6) |
| [docs/plan/game/02-skvoznoj-test-svobodnyj.md](/docs/plan/game/02-skvoznoj-test-svobodnyj.md) | plan | closed |  | 12-02. Сквозной тест свободного полёта на всех локациях |
| [docs/plan/game/03-geimplej-svobodnogo.md](/docs/plan/game/03-geimplej-svobodnogo.md) | plan | closed |  | 12-03. Геймплей свободного полёта: управление, камеры, приборы, итог |
| [docs/plan/game/04-sled-proshlogo-poleta.md](/docs/plan/game/04-sled-proshlogo-poleta.md) | plan | idea |  | 04. След прошлого полёта (полупрозрачная линия) — ОТЛОЖЕНО (решение пользователя): относится к блоку соревнований (этап 5), пока не делаем. |
| [docs/plan/game/05-stolknoveniya.md](/docs/plan/game/05-stolknoveniya.md) | plan | closed |  | G05. Столкновения с проводами ЛЭП и препятствиями — Цель: задеть провод ЛЭП, дерево у посадки, забор или здание — это авария (итог полёта с понятной причиной), как в жизни (VR-10, VR-12). |
| [docs/plan/game/06-nos-na-razbege-po-vetru.md](/docs/plan/game/06-nos-na-razbege-po-vetru.md) | plan | closed |  | G06. «Нос держится сам» на разбеге учитывает ветер — Цель: игрок, бегущий на W+Shift без подстройки носа, взлетает в любую погоду так же надёжно, как автопилот (F01): автоматический нос держит угол атаки, а не фиксированный угол тангажа. |
| [docs/plan/game/README.md](/docs/plan/game/README.md) | plan | closed | game | Группа 12 — Сцена игры и управление (game/) — В волне 1 параллельно идут ui/01 и ui/02 (папки UI). |
| [docs/plan/heat_ca_prototype.md](/docs/plan/heat_ca_prototype.md) | plan | idea |  | Прототип: клеточный автомат тепла и массы (2D-разрез хребта) |
| [docs/plan/multiplayer.md](/docs/plan/multiplayer.md) | plan | postponed | net | План: сетевая игра — роадмап — 1. «Сетевая игра» в главном меню → экран: адрес сервера (IP:порт, запоминается), своё имя пилота (из настроек). |
| [docs/plan/offline_world_data.md](/docs/plan/offline_world_data.md) | plan | postponed | world | План: офлайн-данные мира — свой пакет региона и подложка поверхности из OSM — 1. Без интернета. Всё нужное для полёта (рельеф, земной покров, OSM) заранее перепаковано в свой компактный формат и лежит рядом с игрой пакетами регионов. |
| [docs/plan/on_demand_location.md](/docs/plan/on_demand_location.md) | plan | idea |  | Идея: список мест полётов из OSM и закачка полных данных по месту — Из OSM брать размеченные места свободных полётов и показывать их списком для выбора старта. |
| [docs/plan/osm_vector_pack.md](/docs/plan/osm_vector_pack.md) | plan | postponed |  | Размер офлайн-пакета: вектор OSM + рельеф + покров (замер на Словении) — Замер к плану offline_world_data.md (этапы 0 и 1). |
| [docs/plan/weather_by_temperature.md](/docs/plan/weather_by_temperature.md) | plan | closed | air-model | План: погода из прогноза — температура и ветер вместо пресетов — Запрос пилота (пилот-консультант, опытный дельтапланерист): выбор «Слабый / Средний / Сильный день / Гроза / Волна» для пилота странный. |
| [docs/plan/wind_field.md](/docs/plan/wind_field.md) | plan | superseded | air-model | План: поле ветра на сетке, согласованное по массе, в compute-шейдерах — Память (5,1 млн ячеек, fp32 = 20,5 МБ на скаляр): / Что / Где / Объём / /---/---/---/ / Векторы PCG (λ, r, z, p, q) + коэффициенты столбцов / VRAM, на время расчёта / ~140 МБ / / Уровни многосеточного метода (если WF-03) / VRAM… |
| [docs/plan/wings_lineup.md](/docs/plan/wings_lineup.md) | plan | closed | wings | План: линейка крыльев — классы, модели, выбор в «Полёт…», 3D — Запрос (пользователь и два пилота-консультанта, оба опытные дельтапланеристы): широкая линейка реальных крыльев, сгруппированных по классам; группы упорядочены по качеству и по ветру, в котором на крыле комфортно летать. |

## Реестры

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [docs/registry/contracts.md](/docs/registry/contracts.md) | registry | active |  | Контракты стыков по модулям: идентификаторы и версии из заголовков. |
| [docs/registry/decisions.md](/docs/registry/decisions.md) | registry | active |  | Решения всех модулей из decisions.jsonl (232 записей), по модулям. |
| [docs/registry/findings.md](/docs/registry/findings.md) | registry | active |  | Реестр выводов из закрытых планов и журналов: тема, вывод (числа как в источнике), источник в архиве, где применено. Пишется вручную. |
| [docs/registry/research.md](/docs/registry/research.md) | registry | active |  | Все исследования docs/research и tools/research: тема, вывод, данные, где применено. |
| [TODO.md](/TODO.md) | registry | active |  | TODO — реестр задач — Цель сейчас: доделать основу — всё, кроме разделов «Идеи», «Позже/отложено», «Места» и явно отложенного. |
| [REQUIREMENTS.md](/REQUIREMENTS.md) | registry | active | ui | Дельтаплан — требования — Идея игры: дать бывшим пилотам (например, тем, кому по возрасту или здоровью уже не подняться в небо) снова летать в «своих» местах. |

## Прочее

| путь | тип | статус | модуль | summary |
|---|---|---|---|---|
| [docs/obsidian.md](/docs/obsidian.md) | guide | active |  | Как смотреть документацию в Obsidian: корень репозитория как vault, настройки ссылок, frontmatter как свойства. |
| [docs/screenshots/cockpit/README.md](/docs/screenshots/cockpit/README.md) | reference | active |  | Приёмка кабины (карточка game/01, VR-11, FR-25a, VR-6) — Кадры: tools/shots/cockpit.sh (1920×1080, Онгудай, --autopilot, время симуляции 20 с; TS — Аскарово, 172 с). |
| [docs/screenshots/e2e/README.md](/docs/screenshots/e2e/README.md) | reference | active |  | Скриншоты 12-02 — сквозной тест свободного полёта — Кадры сняты tools/shots/e2e.sh (драйвер tools/shots/e2e_shot.gd/.tscn): та же цепочка, что в tests/game/test_e2e.gd — меню → «Полёт…» → выбор локации/старта → «Лететь» → разбег W+Shift (Autopilot) → полёт по курсу от склона → с… |
| [docs/screenshots/gameplay/README.md](/docs/screenshots/gameplay/README.md) | reference | active | game | Геймплей свободного полёта — кадры по камерам (карточка game/03) — Снято tools/shots/gameplay.sh (Онгудай, старт по умолчанию, --autopilot, 20 с симуляции, 1920×1080, каждый запуск под timeout 120). |
| [docs/screenshots/site/README.md](/docs/screenshots/site/README.md) | reference | active | site | Кадры для сайта (октябрь 2026) — Сняты готовыми инструментами tools/shots после обновления крыльев (48 моделей). |
| [docs/screenshots/ui/README.md](/docs/screenshots/ui/README.md) | reference | active | ui | Скриншоты ui/01 — меню, «Полёт…», карта, «Управление» — Сняты godot --rendering-method gl_compatibility под xvfb-run (см. |

## Архив

`docs/archive/plan/` — планы и журналы закрытых работ (60 md, без frontmatter, из поиска по умолчанию исключены). Выводы из них — в [реестре выводов](/docs/registry/findings.md); таблица переносов — [moves](/docs/archive/moves.tsv).
