---
type: "registry"
status: "active"
module: ""
updated: "2026-10-17"
summary: "Точка входа: модули docs/ по подпроектам, прочие документы по типам."
related: []
generated: true
---

# Индекс документации

Точка входа; руками не править (`.dpcli/dpcli docs index`). Читать по кусочку, не целиком:
- найти — `.dpcli/dpcli docs find <слова>` (путь — summary), выводы — `.dpcli/dpcli docs findings <слова>` ([реестр выводов](registry/findings.md)), журналы модулей — `.dpcli/dpcli search`;
- читать — `.dpcli/dpcli docs section <путь>` (оглавление), затем `.dpcli/dpcli docs section <путь> <номер|заголовок>`.

Модули — по подпроектам (area), внутри — по дате плана: строка на модуль, под ней — его прочие документы.

## air

- **cloud-field** — Облака из поля облачности над местом (рост от подъёма до LCL, таяние, снос ветром) вместо «одно облако на термик»; рендер слоем в raymarch. [active 2026-10-17] — [план](plan/cloud-field.md) · [контракты](contracts/cloud-field.md)
  - [docs/research/cloud_field.md](research/cloud_field.md) — CLF-1/CLF-9: поле облачности из поля воздуха (подъём до LCL, таяние, снос) и z_i, частично следующий рельефу (α ⅓, σ 5 км); карты до/после
  - [tools/research/cloud_field/README.md](../tools/research/cloud_field/README.md) — CLF-1/CLF-9: карты поля облачности над Онгудаем, Аскарово, островом, Алматы; z_i по рельефу до/после, потолки термиков; команды, файлы

## flight

- **pendulum-default** — Режим управления «Маятник» — основной: умолчание везде, без пометки «экспериментальный», первым в списке; сайт и доки — по факту. [active 2026-10-15] — [план](plan/pendulum-default.md) · [контракты](contracts/pendulum-default.md)
- **speed-feel** — Скорость ощущается, как у пилота: тряска ∝ V, ленточка различает скорость до 25 м/с, эоловый тон тросов, проверка выравнивания головы. [active 2026-10-15] — [план](plan/speed-feel.md) · [контракты](contracts/speed-feel.md)
  - [docs/research/speed-feel.md](research/speed-feel.md) — Числа SPF-1: болтанка растёт как V^1,2–1,5, θ(V) −15°, St ленты 0,4, тросы Ø2–3,2 мм St 0,2, голова следует на 0,3
  - [tools/research/speed-feel/README.md](../tools/research/speed-feel/README.md) — SPF-1: скрипты и таблицы замеров болтанки, тангажа киля, частот ленты и тросов; команды воспроизведения

## world

- **grass-rocks** — Трава: вблизи натуральная, на 10–40 м бархатная, дальше — шейдер рельефа, цена ≤ 1 мс; камни — честные многогранники на 12–80 треугольников. [active 2026-10-15] — [план](plan/grass-rocks.md) · [контракты](contracts/grass-rocks.md)
  - [docs/perf/grass_rocks.md](perf/grass_rocks.md) — Замеры цены травы и камней модуля grass-rocks по протоколу G3: база (GR-2) и после каждой правки, medium и high, ongudai.
  - [docs/perf/grass_rocks_2.md](perf/grass_rocks_2.md) — Продолжение замеров grass-rocks: GR-22, режим angle против shell (G3, medium и high, ongudai), кадры angle/ и final/9.
  - [docs/perf/offscreen_audit.md](perf/offscreen_audit.md) — Аудит GR-1: работа вне кадра. Заметно: трава (≈ 2 млн вершин за спиной), кресты, импостеры; CPU-отсечение при вращении не годится.
- **offline_world_data** — Отложено 30.09: офлайн-пакет региона и подложка поверхности из OSM; кода нет, роль частично закрыли osm-any и osm-tiles. [postponed 2026-10-15] — [план](plan/offline_world_data.md)
- **osm_vector_pack** — Замер размера офлайн-пакета (Словения ≈ 80 МБ); §9 тайлы 20 км реализованы в osm-tiles, офлайн-пакет не сделан (отложен). [postponed 2026-10-15] — [план](plan/osm_vector_pack.md)
  - [docs/plan/osm_vector_pack/minimal-package.md](plan/osm_vector_pack/minimal-package.md) — Минимальный пакет OSM (замер 10.10.2026, Словения): что нужно игре из вектора и сколько это весит. [postponed]
  - [docs/plan/osm_vector_pack/tiles-20km.md](plan/osm_vector_pack/tiles-20km.md) — Слой «дороги + дома + объекты для пилота» тайлами 20×20 км (замер 10.10.2026, Словения и Алматы); реализован в osm-tiles. [postponed]
- **scene-look** — Картинка сочнее только шейдерами (T-31): свет, лес, сезон, дымка, снег и ледники; открыты вопрос Q4 и TODO T-81, T-82. [active 2026-10-15] — [план](plan/scene-look.md) · [контракты](contracts/scene-look.md)
  - [docs/guide/scene-look/forest-cost.md](guide/scene-look/forest-cost.md) — Лес вдали (дерево в клетке, кресты, стыки), цена GPU модуля и варианты шейдера рельефа, границы модели (SL-11, SL-17…SL-23).
  - [docs/guide/scene-look/ground.md](guide/scene-look/ground.md) — Тропы, скалы и осыпи, сезон, альбедо деревьев, волны ветра по траве, пятна тона, свежий снег и ледники (SL-5…SL-10, SL-14, SL-15).
  - [docs/guide/scene-look/light-atmosphere.md](guide/scene-look/light-atmosphere.md) — Свет неба и земли, дымка с ореолом, дороги вдали, просвет паруса и листвы (SL-2, SL-3, SL-4, SL-7): физика и цена.
  - [docs/guide/scene-look-keys.md](guide/scene-look-keys.md) — Таблицы ключей scene-look: scene_look, trees.*, trees.impostors.seam_*, haze.*, roads.look, sail — по умолчанию и смысл.
  - [docs/guide/scene-look.md](guide/scene-look.md) — Модуль scene-look («картинка сочнее»): принцип, шейдерный include sl_*, конфиг и выключатели; пункты SL-2…SL-23 разнесены по частям.
- **training-island** — Учебный остров: синтетическое место в море, старты «склон», «термики», «посадка», «ротор»; фиксированная погода и запечённый ветер. [active 2026-10-16] — [план](plan/training-island.md) · [контракты](contracts/training-island.md)
  - [docs/research/training_island_air.md](research/training_island_air.md) — TI-5: погода четырёх стартов учебного острова (TI-К2) и проверка воздуха в игре — склон, термики, ротор, посадка

## game

- **goals** — Цели полёта перед стартом (высота, время, дальность, возврат, треугольник, маршрут, скорость, посадка), зачёт, след попытки, IGC/GPX. [active 2026-10-16] — [план](plan/goals.md) · [контракты](contracts/goals.md)
  - [docs/guide/goals.md](guide/goals.md) — Цели полёта и треки: вкладка «Цели», оценка по погоде, засчёт в полёте, итог, прибор, столбы, запись и показ треков, IGC/GPX.

## process

- **docs-rework** — dp → dpcli, area и статусы модулей по коду, раскладка docs (действующее / исследования / архив), docs check без ошибок, сайт без планов. [active 2026-10-15] — [план](plan/docs-rework.md) · [контракты](contracts/docs-rework.md)

## Прочие документы

### Описания систем (guide)

- [docs/guide/air-model/debug.md](guide/air-model/debug.md) — Как подать поле из файла, снять срезы и включить F3; числа выборки (AM-05) и замер травы и ряби по полю (WF-10).
- [docs/guide/air-model/field-cpu.md](guide/air-model/field-cpu.md) — Как игра читает среднее поле воздуха на CPU: сетка, выборка, уровни и подмена, клипмапы, стык с аналитикой, ключи air_model.
- [docs/guide/air-model/limits.md](guide/air-model/limits.md) — Границы модели воздуха: разрешение сетки, калибровка AM-09, слова пилота против модели, профиль притока и длина перемешивания.
- [docs/guide/air-model/phases.md](guide/air-model/phases.md) — Фазы поля масштаба 1: классификатор A/B/C/D/F/G/H, механизмы, код и вызов AirPhase, числа CPU-тестов.
- [docs/guide/air-model/runtime.md](guide/air-model/runtime.md) — Как поле считается при загрузке и в полёте: конвейер фазы → Пикар → проекция, два прохода под ветер меню, пересчёт по сроку.
- [docs/guide/air-model/surface-heat.md](guide/air-model/surface-heat.md) — Поток тепла H по классу покрова: Солнце → Rn → H, вода и лёд, z0 по клетке, замер до и после, чего модель не умеет.
- [docs/guide/air-model/thermals.md](guide/air-model/thermals.md) — Термики из поля: законы Аллена и Дирдорфа, выбор источников, числа против литературы, сеть, чего модель не умеет.
- [docs/guide/air-model/turbulence.md](guide/air-model/turbulence.md) — Болтанка, рывки и подветренная зона из поля: законы, числа у старта и за гребнем, чего модель не умеет.
- [docs/guide/air-model-gpu/blocks.md](guide/air-model-gpu/blocks.md) — Блоки решателя на GPU: файлы, раскладка буферов, прогонки, V-цикл, порции и API каркаса, замеры RTX 4070 SUPER, переносимость.
- [docs/guide/air-model-gpu/clipmap.md](guide/air-model-gpu/clipmap.md) — Окна 100 и 50 м вокруг пилота: граница от родителя, сдвиг, сверка с эталоном, стык уровней, время, AirRuntime.
- [docs/guide/air-model-gpu/picard.md](guide/air-model-gpu/picard.md) — Итерация Пикара на GPU: вход AirCase и AirPlace, порядок программы, буферы, сверка с эталоном AM-01, замеры.
- [docs/guide/air-model-gpu.md](guide/air-model-gpu.md) — Решатель среднего поля воздуха на GPU: блоки, Пикар одного уровня, окна 100 и 50 м; вход, части, замеры RTX 4070 SUPER.
- [docs/guide/air-model.md](guide/air-model.md) — Модель воздуха в трёх масштабах: среднее поле (фазы + Пикар на GPU), термики и возмущения из поля; вход и оглавление частей.
- [docs/guide/architecture.md](guide/architecture.md) — Архитектура: правила кода и конфигов, координаты, папки модулей, контракты между модулями, заменяемые ассеты.
- [docs/guide/atmosphere/calibration.md](guide/atmosphere/calibration.md) — Бот-маршрутник и идеальный пилот на матрице погоды, калибровка дней (карточка 03), сила источника термиков из SurfaceHeat.
- [docs/guide/atmosphere/clouds.md](guide/atmosphere/clouds.md) — Облака (compute и boxes), тени, птицы, признаки термиков, перистая пелена, Cb, волна, пылевые вихри, клубы пыли, известные проблемы.
- [docs/guide/atmosphere/ridge-starts.md](guide/atmosphere/ridge-starts.md) — Парение у склона на 10 стартах четырёх локаций: набор за 5 минут, ridge.efficiency 0,85, два слабых старта.
- [docs/guide/atmosphere/weather.md](guide/atmosphere/weather.md) — Как прогноз пилота (температура, ветер, облачность) превращается в погоду дня: верх термиков, кромка, ход дня, закат.
- [docs/guide/atmosphere/wind-field.md](guide/atmosphere/wind-field.md) — Из чего складывается скорость воздуха: пульсации, термик, снос, склон, подветренная зона и ротор, подсос облака, слова пилота в числах.
- [docs/guide/atmosphere.md](guide/atmosphere.md) — Модуль scripts/atmosphere/: API Atmosphere, устройство и части — погода, поле скоростей, облака, калибровка, склон; тесты и конфиги.
- [docs/guide/crash-report.md](guide/crash-report.md) — Отчёты о вылетах: метка сессии, issue в deltaplan-reports при следующем запуске, токен, проверка --crash-report-test.
- [docs/guide/flight/api.md](guide/flight/api.md) — API FlightModel и Glider, визуал крыла и пилота, тень от неба под парусом, оценка усилия на трапеции.
- [docs/guide/flight/ground-bank.md](guide/flight/ground-bank.md) — Крен крыла на земле: уравнение моментов, рука пилота, порог бокового ветра, поворот на бегу, границы модели.
- [docs/guide/flight/ground-pose.md](guide/flight/ground-pose.md) — Поза крыла на земле: зазор над рельефом, крыло стоя на старте (тангаж, флюгер, касания), старт в сильный ветер.
- [docs/guide/flight/model.md](guide/flight/model.md) — Модель FlightModel: точечная масса с ориентацией, силы, трапеция, крен, срыв, воздух, земля, выравнивание и посадка; допущения.
- [docs/guide/flight/pendulum.md](guide/flight/pendulum.md) — Режим «Маятник» (основной, по умолчанию): крыло на 16 полосах, пилот на цепи подвески, руки, земля, срыв, границы.
- [docs/guide/flight/polar-table.md](guide/flight/polar-table.md) — Таблица поляры в спокойном воздухе: трапеция, скорость, снижение, качество для учебного, мачтового и безмачтового крыла.
- [docs/guide/flight/sky-shade.md](guide/flight/sky-shade.md) — Тень от неба под парусом: физика закрытия небосвода, параметры, реализация декалью.
- [docs/guide/flight/wings.md](guide/flight/wings.md) — Параметры (конфиги крыла, пилота, полёта) и каталог из 48 крыльев по группам и классам ветра.
- [docs/guide/flight.md](guide/flight.md) — Вход в гайд по полёту: FlightModel и Glider (scripts/flight/), три режима крена, земля и посадка, Маятник; оглавление частей.
- [docs/guide/game/bots.md](guide/game/bots.md) — Другие пилоты в небе: очередь на старт, разбег, полёт по вариометру, расхождение, вид и имена; число 0–20 (по умолчанию 4).
- [docs/guide/game/cameras-input.md](guide/game/cameras-input.md) — Камеры (кабина, сзади, свободная), поведение головы, раскладка клавиш/мыши/геймпада, приборы на трапеции и отладочные слои F1–F6.
- [docs/guide/game/cli-tests.md](guide/game/cli-tests.md) — Аргументы командной строки главной сцены (кадры, smoke, старт в воздухе, замеры, отладка сети), запуск тестов и проверок.
- [docs/guide/game/flight-flow.md](guide/game/flight-flow.md) — Ход полёта: состояния главной сцены, загрузка, когда и как кончается полёт (info итога), столкновения, «Подождать час».
- [docs/guide/game/launch.md](guide/game/launch.md) — Старт полёта: разбег на земле, выбор точки старта и пустырь 160 м вокруг неё, «Осмотр карты», анимации пилота.
- [docs/guide/game/menus-settings.md](guide/game/menus-settings.md) — Экраны меню: главное меню, «Полёт…», популярные места и избранное, настройки пилота (вкладки, окно и кадры), слои конфигов, «Об игре».
- [docs/guide/game/network.md](guide/game/network.md) — Сетевой полёт в игре: экран «Сетевая игра», зона и ведущий, мир по ключу и часам зоны, очередь на старт, боты ведущего, «Догнать».
- [docs/guide/game/world-air-time.md](guide/game/world-air-time.md) — Как Game связывает рельеф, объекты, воздух, погоду из прогноза, солнце и графику: интерфейс воздуха, ход дня, SunClock, пресеты графики.
- [docs/guide/game.md](guide/game.md) — Сборка игры: главная сцена, Game и порядок шага физики; оглавление частей — камеры и ввод, старт, полёт и итог, мир, меню, боты, сеть.
- [docs/guide/gpu-validation.md](guide/gpu-validation.md) — tools/gpu_validate.sh: загрузка места под слоем валидации Vulkan, lavapipe и wine+vkd3d-proton; пики RAM/VRAM, что ловит каждый режим.
- [docs/guide/instruments.md](guide/instruments.md) — Планшет и вариометр 90-х (Vario, страницы, ветер, центровка), звук вариометра и звуки полёта; API, настройки и проверки.
- [docs/guide/location-data.md](guide/location-data.md) — Сборка места для встроенных мест и точек: стадии dem, rivers, surface, smooth, osm_tiles, WebP, кеш, догрузка, --prefetch.
- [docs/guide/models/camp.md](guide/models/camp.md) — Модели лагеря у старта (assets/models/world): вещи, полусобранный аппарат, люди; ноды, материалы, бюджеты.
- [docs/guide/models/instruments-3d.md](guide/models/instruments-3d.md) — 3D-модели приборов (планшет, вариометр, часы, компас): оси, ноды, крепление к кисти и к штанге, кабинная камера.
- [docs/guide/models/pilot.md](guide/models/pilot.md) — Модель пилота pilot.glb: меши, кости, пустышки, анимации и порядок фаз, перчатки, кабинный вид, сборка (MPFB), высота в подвеске.
- [docs/guide/models/references.md](guide/models/references.md) — Скриншоты моделей, приёмка по фото реальных прототипов, что улучшить, источники референсов.
- [docs/guide/models/sail-shader.md](guide/models/sail-shader.md) — Шейдер паруса: просвечивание, анимация вершин, подключение к GliderVisual, стенд и сравнение с фото.
- [docs/guide/models/trees.md](guide/models/trees.md) — Модели деревьев (5 пород, 8 вариантов, 3 LOD) и их подключение в мире.
- [docs/guide/models/wing-contract.md](guide/models/wing-contract.md) — Контракт имён и осей модели крыла: ноды Sail, Frame, ControlFrame, маркеры (HangPoint, BaseBar, InstrumentMount, Upright*), материалы.
- [docs/guide/models/wings.md](guide/models/wings.md) — Модели крыльев (assets/models/glider_*.glb, 48 шт.): таблица, параметры glider_params.json, трапеция, центровка, подвеска.
- [docs/guide/models.md](guide/models.md) — Вход в гайд по 3D-моделям: крылья, пилот, приборы, лагерь, деревья; как их пересобрать (Blender 4.3) и где контракты имён и осей.
- [docs/guide/motion-rig.md](guide/motion-rig.md) — Вывод движения пилота на платформы подвижности по UDP (SRS API v102, свой DPMR): величины, знаки, поток, настройки, проверки, границы.
- [docs/guide/net-protocol.md](guide/net-protocol.md) — Сетевой протокол: транспорт, сообщения, роль ведущего, ключ мира, LAN-поиск, примеры JSON и сценарии; правда — net.proto.
- [docs/guide/osm-tiles.md](guide/osm-tiles.md) — Тайлы OSM 20 км: что в них (O1–O3), как собрать тест и весь мир, где итог, что делать при падении; клиент игры и состояние прогона.
- [docs/guide/steam.md](guide/steam.md) — Steam: SteamService, ачивки, присутствие, лобби и сеть, облако; включение, тест на App ID 480, ручные проверки, ограничения.
- [docs/guide/tasks.md](guide/tasks.md) — Задания, тренировки, рекорды: логика и конфиги; в игре — через цели полёта (goals.md), меню заданий и тренировок нет; форматы, API.
- [docs/guide/telltale.md](guide/telltale.md) — Ленточка на переднем тросе трапеции: узел из геометрии модели, физика потока и цепочки, рисунок, ограничение модели без скольжения.
- [docs/guide/terrain/forest-sky.md](guide/terrain/forest-sky.md) — Деревья-модели и средний план леса, полог с высоты, небо, солнце, дымка с инверсией, ослепление, ветер на траве и деревьях.
- [docs/guide/terrain/relief.md](guide/terrain/relief.md) — Слои высот (WebP, 25 м и 100 м), height_at, чанки и LOD, юбки, нормали, форма гор вдали, DSM под лесом, поля рельефа.
- [docs/guide/terrain/runtime.md](guide/terrain/runtime.md) — Выбор точки на карте и загрузка места (LoadProgress, ошибки), добавление локации, превью-сцена, четыре места, стенд кадров.
- [docs/guide/terrain/surface.md](guide/terrain/surface.md) — Карта поверхности WorldCover и маска 10 м (лес, вода), раскраска земли, пустыри у стартов, источники термиков, скалы и снег.
- [docs/guide/terrain.md](guide/terrain.md) — Рельеф и мир (Terrain): файлы, контракт height_at/surface_at/forest_at, пример подключения; детали — в частях terrain/.
- [docs/guide/vegetation.md](guide/vegetation.md) — Трава по дистанциям (ближние травинки, средняя: angle/shell/blades), кусты, одиночные деревья, деревья по кромке леса.
- [docs/guide/world-objects/easter-eggs.md](guide/world-objects/easter-eggs.md) — Каркас пасхалок мира: планировщик, как добавить, запреты, место (EggPlace). На сайт не публикуется.
- [docs/guide/world-objects/start-camp.md](guide/world-objects/start-camp.md) — Старт глазами пилота: тропа, палатки, снаряжение и крылья, примятая трава, ткань, люди, костёр — правила размещения и параметры.
- [docs/guide/world-objects/villages-osm.md](guide/world-objects/villages-osm.md) — Просеки для деревьев, процедурные дома в пятнах застройки, OSM-слой из тайлов (дороги, дома, ЛЭП, ветряки, трафик), деревья города.
- [docs/guide/world-objects/wind-landing.md](guide/world-objects/wind-landing.md) — Ветроуказатели по локальному воздуху модели и посадочные площадки с лесополосами: устройство, параметры, сверка с фото.
- [docs/guide/world-objects.md](guide/world-objects.md) — WorldObjects: файлы, подключение к сцене, API; ветроуказатели, посадки, лагерь, посёлки, OSM-слой и пасхалки — в частях world-objects/.
- [docs/obsidian.md](obsidian.md) — Как смотреть документацию в Obsidian: корень репозитория как vault, настройки ссылок, frontmatter как свойства.

### Планы (plan)

- [docs/plan/game/05-vr.md](plan/game/05-vr.md) — VR (OpenXR): голова — шлем, ручка — джойстик. Идея (05.10), не в работе; риск — производительность, первый шаг — замер. [idea]

### Контракты стыков (contract)

- [docs/contracts/aframe-geometry.md](contracts/aframe-geometry.md) — Трапеция и центровка крыла (A1), маркеры стоек в модели (A2), поза пилота и вид от первого лица (A3). [closed]
- [docs/contracts/air-model/divergences-journal.md](contracts/air-model/divergences-journal.md) — Модель воздуха: расхождения контракта с кодом на 29.09.2026 (Р1…) и журнал версий C1–C10 по датам. [closed]
- [docs/contracts/air-model/field-consumers.md](contracts/air-model/field-consumers.md) — Модель воздуха, стыки C4–C8: WindField/AirFieldSet → атмосфера, термики, сеть, часы старта, клипмапы, пересчёт. [closed]
- [docs/contracts/air-model/input-solver.md](contracts/air-model/input-solver.md) — Модель воздуха, стыки C1–C3: эталон AM-01 → GPU, вход места AirPlace/AirCase, выход решателя в WindField. [closed]
- [docs/contracts/air-model/runtime-calibration.md](contracts/air-model/runtime-calibration.md) — Модель воздуха, стыки C9–C10: жизненный цикл поля AirRuntime в игре и случай калибровки. [closed]
- [docs/contracts/air-model.md](contracts/air-model.md) — Модель воздуха, стыки C1–C10: правило изменения, общие соглашения, список стыков и ссылки на части (эталон, вход, WindField, AirRuntime). [closed]
- [docs/contracts/air-phase/assembly-game.md](contracts/air-phase/assembly-game.md) — Контракты air-phase P8–P15: сборка поля по фазам, фазы + Пикар, GPU-Пикар, AirRuntime без сети, проверки и шлюз классификатора. [closed]
- [docs/contracts/air-phase/experiments-solver.md](contracts/air-phase/experiments-solver.md) — Контракты air-phase P1–P7: идеальные рельефы, план опытов (protobuf), результаты HDF5, пакетный решатель, run_phase.py, метрики. [closed]
- [docs/contracts/air-phase.md](contracts/air-phase.md) — Контракты air-phase P1–P15: общие правила (данные, оси, изменение интерфейса), список стыков и ссылки на части (опыты, сборка, игра). [closed]
- [docs/contracts/control-bar.md](contracts/control-bar.md) — Устройство трапеции в controls.json → gamepad (CB-К1), ход ручки → управление, класс BarAxis (CB-К2). [closed]
- [docs/contracts/control-fix.md](contracts/control-fix.md) — Тангаж на старте: pitch ∈ [−1, 1], +1 — трапеция от себя (нос вверх); на земле pitch — угол носа крыла. [closed]
- [docs/contracts/easter-eggs/framework.md](contracts/easter-eggs/framework.md) — Контракты пасхалок К1–К7: планировщик, EggContext, EasterEgg, расписание, конфиг, форс кадров, тест «не трогает физику», цена. [closed]
- [docs/contracts/easter-eggs/models-sound.md](contracts/easter-eggs/models-sound.md) — Контракты пасхалок К13–К16: модель гуся, звук гусиной стаи, модель брелока-чайки, брелок на трапеции. [closed]
- [docs/contracts/easter-eggs/place-world.md](contracts/easter-eggs/place-world.md) — Контракты пасхалок К8–К12: EggPlace и условия, другая группа ботов, FieldPlots, модель рулона сена, стёкла машин. [closed]
- [docs/contracts/easter-eggs.md](contracts/easter-eggs.md) — Контракты модуля «Пасхалки», К1–К16: версии модуля и инвариант (только картинка и звук), список стыков и ссылки на части. [closed]
- [docs/contracts/feedback-1012.md](contracts/feedback-1012.md) — Смещение пилота относительно подвески в телеметрии для HUD (FB-К1); флаг начала перехода в лётное положение (FB-К2). [closed]
- [docs/contracts/feedback-1013.md](contracts/feedback-1013.md) — Время суток и солнце для источников тепла и термиков: при солнце под горизонтом нет нового тепла и термиков (FBW-К2). [closed]
- [docs/contracts/motion-rig.md](contracts/motion-rig.md) — Точка пилота и величины (MR-К1), поток UDP: живые/удержание/нейтраль, множитель на земле (MR-К2), настройки (MR-К3). [closed]
- [docs/contracts/mountain-look.md](contracts/mountain-look.md) — Сглаживание высот в лесу и застройке (MLK-К1), дальнее заострение рельефа (MLK-К2), формат зонда силуэта гор (MLK-К3). [closed]
- [docs/contracts/no-osm.md](contracts/no-osm.md) — Застройка 10 м и пятна места (N1–N2), процедурные дома (N3), игра без OSM (N4), файлы места в WebP и версия кеша (N5). [closed]
- [docs/contracts/osm-any.md](contracts/osm-any.md) — Контракты osm-any: папка места (встроенного и кешированного), файл OSM места, API стадий сборки места в игре, сборщик/кеш/реестр мест. [closed]
- [docs/contracts/osm-look.md](contracts/osm-look.md) — Вид OSM: тип дома (L1), стиль и шейдер домов (L2), дым труб (L3), ветер слоя (L4), ЛЭП, ветряки (L5–L6), дороги, земля, шлейфы (L7–L9). [closed]
- [docs/contracts/osm-tiles.md](contracts/osm-tiles.md) — Сетка 20 км (O1), файл тайла (O2), потоки (O3), склейка регионов (O4), CLI упаковщика (O5–O7), оркестратор (O8), клиент (O9). [closed]
- [docs/contracts/pendulum.md](contracts/pendulum.md) — Модель полёта «Маятник» (PD-К1), конфиг маятника (PD-К2), настройки «Аппарат» (PD-К3), сеть и поза (PD-К4–К5), касание ногами (PD-К6). [closed]
- [docs/contracts/perf.md](contracts/perf.md) — Размер буфера облаков и параметры качества (PF-К2), источники термиков при сборке поля в рабочем потоке (PF-К4). [closed]
- [docs/contracts/pilot-hud.md](contracts/pilot-hud.md) — Усилие на трапеции (PH-К1), часы и компас (PH-К2, К4), крепления и материалы (PH-К3), тело в кабине (PH-К5), трава, подошвы (PH-К6–К7). [closed]
- [docs/contracts/pilot-view.md](contracts/pilot-view.md) — Направление крена (PV1), X возвращает мышь-трапецию в нейтраль (PV2), изгиб базовой штанги по крыльям (PV3). [closed]
- [docs/contracts/popular-places.md](contracts/popular-places.md) — Файл каталога стартов дельтаплана (PP-К1), данные и окно «Популярные места» в меню полёта (PP-К2). [closed]
- [docs/contracts/qol.md](contracts/qol.md) — Номер полёта и перезапуски (QL-К1), снимок состояния для «с наивысшей точки» (QL-К2), файл сохранённого полёта (QL-К3). [closed]
- [docs/contracts/site-i18n.md](contracts/site-i18n.md) — Языки и URL сайта (en в корне, ru под /ru/), файлы переводов, ключи i18n, ссылки между языками, генератор крыльев (SI-К1–К6). [closed]
- [docs/contracts/start-camp.md](contracts/start-camp.md) — Зона старта (SC-K1), снаряжение у старта (SC-K2), модели вещей (SC-K3), люди у лагеря (SC-K4), ткань лагеря и примятая трава (SC-K5–K6). [closed]
- [docs/contracts/start-fixes.md](contracts/start-fixes.md) — Фиксы старта с земли: карта поверхности и поляны (К1), трава по классам (К2), крен на земле (К3), поза крыла на земле (К4). [closed]
- [docs/contracts/start-map.md](contracts/start-map.md) — Подложки карты выбора старта в конфиге (SM-К1), высота точки по Terrarium и интерфейс MapPicker (SM-К2). [closed]
- [docs/contracts/start-pick.md](contracts/start-pick.md) — Точный старт в FlightSettings (SP-К1), проверка точки StartSpot (SP-К2), старт в сети: Zone и WorldKey v2 (SP-К3), камни на разбеге (SP-К4). [closed]
- [docs/contracts/steam-assets.md](contracts/steam-assets.md) — Инвентарь сборки (SA-К1), лицензии и атрибуции (SA-К2), формат ASSETS.md (SA-К3), ассеты страницы Steam (SA-К4). [closed]
- [docs/contracts/steam.md](contracts/steam.md) — SteamService и заглушка (S1), события для ачивок (S2), Rich Presence (S3), транспорт (S4), лобби (S5), ачивки (S6), Cloud (S7). [closed]
- [docs/contracts/surface-heat.md](contracts/surface-heat.md) — Конфиг параметров поверхности (SH1), ядро SurfaceHeat (SH2), вход решателя по клеткам (SH3), сила источника термиков (SH4), замер (SH5). [closed]
- [docs/contracts/ui-controls.md](contracts/ui-controls.md) — Действия тангажа: pitch_push_out = [Up] (трапеция от себя, pitch +), pitch_pull_in = [Down] (на себя, pitch −). [closed]
- [docs/contracts/wind-limits.md](contracts/wind-limits.md) — Контракты модуля wind-limits: класс крыла и предел ветра в конфигах (WL-К1), таблицы ветра сноса и удержания на старте (WL-К2). [closed]
- [docs/contracts/wing-physics-check.md](contracts/wing-physics-check.md) — Конфиг крыла → модель (К1), скорость воздуха (К2), ветер меню (К3), «паспорт против модели» (К4), профили ветра, пачка полётов (К5–К6). [closed]
- [docs/contracts/wings-models3d.md](contracts/wings-models3d.md) — Параметры формы крыла в glider_params.json (К1), конфиг ↔ модель ↔ перевод (К2), спецификация новых крыльев (К3), поляра нового крыла (К4). [closed]

### Исследования (research)

- [docs/perf/frame_profile/after-fixes.md](perf/frame_profile/after-fixes.md) — PF-10: GPU medium 14–29 → 5,3–8,2 мс, high 33–83 → 10–12 мс; что дало каждое исправление, что осталось
- [docs/perf/frame_profile/air-shaders.md](perf/frame_profile/air-shaders.md) — Поле воздуха на GPU в кадре: задачи и проходы, синхронизации и чтения на CPU, рабочие группы, что можно объединить
- [docs/perf/frame_profile/baseline.md](perf/frame_profile/baseline.md) — Профиль кадра PF-1: прежние замеры (NFR-1, AM-00) устарели; стенд, пресеты, опыты и метки движка
- [docs/perf/frame_profile/measurements.md](perf/frame_profile/measurements.md) — Замеры PF-1 на ongudai: проходы GPU, вклад облаков, травы, рельефа, теней; CPU-рывки главного потока раз в 1 с
- [docs/perf/frame_profile/proposals.md](perf/frame_profile/proposals.md) — Ранжированные предложения по ускорению кадра и грубая оценка для RX 5600 XT + Ryzen 5 4500 (оценка, не замер)
- [docs/perf/frame_profile/render-settings.md](perf/frame_profile/render-settings.md) — Проверка настроек рендера Godot: пресеты, шейдер рельефа, почему assets/shaders весит 23 МБ
- [docs/perf/frame_profile.md](perf/frame_profile.md) — Профиль кадра PF-1: облака 56–93 % GPU; после PF-4…12 GPU medium 14–29 → 5,3–8,2 мс, high 33–83 → 10–12 мс
- [docs/research/air-model-sensitivity/conclusions.md](research/air-model-sensitivity/conclusions.md) — Модель не жёсткая; перекалибровать Askervein по (λ/h, α, z0) с профилем RS, λ — по следу за гребнем; Pr_t, τ выхолаживания — правки схемы
- [docs/research/air-model-sensitivity/figures-reproduction.md](research/air-model-sensitivity/figures-reproduction.md) — Список картинок и таблиц tools/research/morris/out, команды воспроизведения (5,3 ч GPU, SALib), источники
- [docs/research/air-model-sensitivity/method-factors.md](research/air-model-sensitivity/method-factors.md) — Метод Морриса (12 траекторий × 17 точек), 16 факторов с диапазонами и обоснованием границ, 6 случаев, наблюдаемые и пороги
- [docs/research/air-model-sensitivity/results.md](research/air-model-sensitivity/results.md) — S = μ*/порог: Askervein двигают α, замыкание, порядок, local_k (94 % — одно направление); heat_mode меняет подъём на ±1,5 м/с
- [docs/research/air-model-sensitivity.md](research/air-model-sensitivity.md) — Моррис, 1230 прогонов: модель мягкая по переключателям и α, жёсткая от данных; λ/h, α, порядок переноса и local_k вырождены
- [docs/research/air-model-tune/am09-method.md](research/air-model-tune/am09-method.md) — Схема Professor (AM-09): правила, метод, 2 подогнанных и фиксированные параметры, наблюдаемые Askervein и масштабов 2–3, систематика сетки
- [docs/research/air-model-tune/am09-results.md](research/air-model-tune/am09-results.md) — Заменено совместной калибровкой Б1: AM-09 дал λ/h = 0,25 (χ²/ndf 86,2/38 на Askervein), в коде теперь 0,0158 [superseded]
- [docs/research/air-model-tune/am09b.md](research/air-model-tune/am09b.md) — AM-09б: единые LAM_FRAC и NEUTRAL_BL_K = 0,3 для решателя и масштаба 3, ТКЭ Askervein χ² 141 → 33, вырождение (λ/h)·k
- [docs/research/air-model-tune/joint-askervein-perdigao.md](research/air-model-tune/joint-askervein-perdigao.md) — Б1, 765 прогонов: λ = 27 м → LAM_FRAC 0,0158 (пол 40 м), α_Askervein 0,242, χ²/ndf 208/76; одно λ не даёт и зону за грядой, и слабый след
- [docs/research/air-model-tune/recalibration-rs.md](research/air-model-tune/recalibration-rs.md) — Заменено Б1: профиль мачты RS дал λ/h 0,031, α 0,235, z0 0,09 м (χ²/ндф 68,2/44) и разорвал долину λ/h–α [superseded]
- [docs/research/air-model-tune.md](research/air-model-tune.md) — Калибровка воздуха по Askervein и Perdigão: в игре λ/h = 0,0158 (пол λ 40 м), α = 0,24; оценка AM-09 (λ/h 0,25) заменена
- [docs/research/air_field_cache/field-size.md](research/air_field_cache/field-size.md) — Размер одного варианта (три уровня): float32 23,5 МБ, float16 + zstd 5,8–6,4 МБ, квантование 0,01–0,02 м/с + zstd 0,94–1,2 МБ [closed]
- [docs/research/air_field_cache/paths-and-recommendation.md](research/air_field_cache/paths-and-recommendation.md) — Предрасчёт всей сетки нереален (2,3–2,9 ГБ, 4,5–6,5 ч на старт); рекомендован ленивый кеш на диске, 1,2–6 МБ на вариант [closed]
- [docs/research/air_field_cache/time-and-surrogate.md](research/air_field_cache/time-and-surrogate.md) — Этап ветра 7–8 с, но 25–60 с на слабом ветре (3000 итераций, в 9:00 в штиль — таймаут 60 с); формула годится лишь для узких величин у старта [closed]
- [docs/research/air_field_cache/variants-sensitivity.md](research/air_field_cache/variants-sensitivity.md) — 57 564 варианта на старт; без потерь можно огрубить дату, небо, температуру и верхние скорости — до ≈ 2 160; направление и час нельзя [closed]
- [docs/research/air_field_cache.md](research/air_field_cache.md) — Поле воздуха — 23,5 МБ на вариант (1–6 МБ сжатое), 57 564 варианта на старт: предрасчёт нереален, нужен ленивый кеш (не сделан) [closed]
- [docs/research/air_phase/axes-and-phases.md](research/air_phase/axes-and-phases.md) — Оси Fr, s, −z_i/L, h/z_i (π-теорема, диапазоны корпуса SY-12 из 7320 случаев) и классы решений A–H с порогами по литературе
- [docs/research/air_phase/empirical-map.md](research/air_phase/empirical-map.md) — Карта по 7320 случаям SY-12: параметры порядка плавны на две декады Fr; фаза — свойство точки (при Fr области 0,49 клеток в A 88 %)
- [docs/research/air_phase/order-and-picard.md](research/air_phase/order-and-picard.md) — Несходимость Пикара (≈10 % SY-12) — прежде всего слабый ветер U10 < 2,5 м/с, затем Fr < 0,3; нагрев её не объясняет
- [docs/research/air_phase/solvers-and-experiments.md](research/air_phase/solvers-and-experiments.md) — Решатель на каждую фазу, план опытов на идеальном рельефе (выполнен, итоги в air_phase_results.md), риски и команды воспроизведения
- [docs/research/air_phase.md](research/air_phase.md) — Фазовая диаграмма ветра над рельефом: несходимость Пикара — слабый ветер (U10 < 2,5 м/с) и Fr < 0,3, не нагрев; основа фаз в игре
- [docs/research/air_phase_experts.md](research/air_phase_experts.md) — Фазы почти аналитичны; целевая архитектура — сборка поля по фазам на GPU без сети (классификатор, механизмы, сшивка проекцией)
- [docs/research/air_phase_refs.md](research/air_phase_refs.md) — Литература к air-phase: пороги Fr, срыва, конвекции, стоков, Пикара; у каждой ссылки и числа — пометка надёжности
- [docs/research/air_phase_results.md](research/air_phase_results.md) — Опыты на идеальном рельефе (7686+296+231 случаев): блокирование резкое при Fr ≈ 0,8–1,1, гистерезиса нет, U/N ≲ 340–440 м — граница Пикара
- [docs/research/air_phase_results_tables.md](research/air_phase_results_tables.md) — Приложение к air_phase_results.md: полные таблицы AP-7…AP-14 — границы фаз, пересчёт при ω = 0,5, перенос на рельеф с эрозией
- [docs/research/air_physics_primer.md](research/air_physics_primer.md) — Справочник по физике воздуха над рельефом; §8–9 (решатель AM-01, сеть) устарели: в игре фазы + Пикар, сети нет [closed]
- [docs/research/ann2_data_limit.md](research/ann2_data_limit.md) — AN-1: ошибка сети P2 против шума цели решателя — шум цели на 1–3 порядка меньше ошибки, дело в сети (вариант б). [closed]
- [docs/research/atlas_wing.md](research/atlas_wing.md) — Дельтаплан «Атлас» (СССР): S 15,5 м², размах 9,8 м, 25 кг, срыв 29–30 км/ч; выписка для configs/wings/atlas.json и модели
- [docs/research/calibration_data/saddles-diurnal.md](research/calibration_data/saddles-diurnal.md) — Седловины: Gebbies Pass +40–60 %, Бреннер > 21 м/с на выходе; справочные диапазоны суточного хода, инверсий и склоновых ветров [closed]
- [docs/research/calibration_data/slope-flow.md](research/calibration_data/slope-flow.md) — Разгон ΔS = B·H/L (B ≈ 2,0 у хребта), труба Lubitz–White, Altamont, порог отрыва 15–18°, пузырь Bolund, правила FAA [closed]
- [docs/research/calibration_data/sources.md](research/calibration_data/sources.md) — Список источников таблицы: Allen 2006, Lenschow–Stephens 1980, Lubitz–White 2007, Taylor–Lee 1984, Hernández-Aguayo 2026, Stull, FAA [closed]
- [docs/research/calibration_data/surface-atmosphere.md](research/calibration_data/surface-atmosphere.md) — Боуэн по поверхностям, лес ≈ 2× луга по явному теплу (+121 Вт/м²), альбедо, Γ_d = 9,76 K/км, полуэмпирика дельтапланов 80–90-х [closed]
- [docs/research/calibration_data/thermals.md](research/calibration_data/thermals.md) — Термики: профиль Lenschow–Stephens (макс. ŵ ≈ 0,45 w*), медиана w* 2,56 м/с и z_i 1400 м, набор парапланов Франции, правила Dr Jack [closed]
- [docs/research/calibration_data/usage-gaps-questions.md](research/calibration_data/usage-gaps-questions.md) — Как сравнивать модель с таблицей (WF-16), чего нет в открытых источниках, вопросы пилотам; данные Askervein позже скачаны [closed]
- [docs/research/calibration_data.md](research/calibration_data.md) — 34 наблюдаемые с σ и надёжностью для χ² калибровки воздуха: термики, склон, седловины, поверхность, облака; пробелы и вопросы [closed]
- [docs/research/competition_rules.md](research/competition_rules.md) — Правила XC-соревнований (FAI S7A/S7F): типы заданий, цилиндры, оптимизированный маршрут, GAP, формат .xctsk; сделано в scripts/tasks
- [docs/research/control-bar-input.md](research/control-bar-input.md) — Самодельная трапеция как стандартный USB HID-джойстик с двумя осями: платы, датчики, Godot 4.5+ (SDL3); принято в CB-2/CB-3
- [docs/research/control_frame_refs.md](research/control_frame_refs.md) — Размеры и узлы трапеции, подвески и вид из кабины для Blender-моделей: мануал Wills Wing T2/T2C, советские аппараты
- [docs/research/experimental_data.md](research/experimental_data.md) — Каталог данных для калибровки модели воздуха: Askervein, Perdigão, Menke 2019, Lubitz & White; где лежат, что дают, пробелы
- [docs/research/glider_3d_tz.md](research/glider_3d_tz.md) — ТЗ на 3D-модели крыльев по паспортам (DHV, производители): раздел на крыло, самодостаточный для исполнителя. [closed]
- [docs/research/glider_models.md](research/glider_models.md) — Список моделей дельтапланов — Сгенерировано tools/research/data/wing_passports/consolidate.py (2026-09-30). [closed]
- [docs/research/glider_polars_sources.md](research/glider_polars_sources.md) — Готовых поляр современных дельтапланов в открытых данных нет: берём паспорта, поляру строим по якорям с пометкой «оценка»
- [docs/research/itch_multiplayer.md](research/itch_multiplayer.md) — У itch.io нет сетевого функционала; без VPS — сервер на ПК пилота поверх Tailscale/ZeroTier; решение 01.10.2026: отложено. [closed]
- [docs/research/lakes_worldcover.md](research/lakes_worldcover.md) — Озёра OSM для H не нужны: WorldCover видит озёра ≥ 10 га (IoU 0,86–0,97); вода в канале A — WorldCover и реки по рельефу.
- [docs/research/location_compression.md](research/location_compression.md) — Данные мест в WebP lossless (24 бит в RGB8, шаг 1/32 м): высоты 11 → ≈5,5 МБ на место, чтение 0,12 с; применено (NO-8, NO-9).
- [docs/research/motion-rig-protocols.md](research/motion-rig-protocols.md) — Платформы DOF Reality принимают SRS API v102 (UDP 33001, 236 байт); SimTools и FlyPT Mover без своего плагина — нет.
- [docs/research/openfreemap_vs_overpass.md](research/openfreemap_vs_overpass.md) — Заменено: OFM z14 совпадал с Overpass на 99–100 % (нет ЛЭП), но игра берёт OSM из своих тайлов 20 км (osm-tiles). [superseded]
- [docs/research/ordodi_1984_konstruktsiya.md](research/ordodi_1984_konstruktsiya.md) — Ордоди М., «Дельтапланеризм» (1984) — глава 3.2 «Как строить дельтапланы» [closed]
- [docs/research/pendulum/landing-pd27-30.md](research/pendulum/landing-pd27-30.md) — Посадка PD-27/29/30: полосы гасят скорость медленнее, чем за 0,3–0,9 с до касания; запаздывание отрыва даёт 3,3–4,4 м/с, но качает sport
- [docs/research/pendulum/landing-pd33-35.md](research/pendulum/landing-pd33-35.md) — Посадка PD-33/35: в штиль горизонтальная при касании 5,9–7,2 м/с против выбегаемых 5 м/с — мягкой посадки в квазистационарной модели нет
- [docs/research/pendulum/lateral-yaw.md](research/pendulum/lateral-yaw.md) — Боковой канал и рыскание (PD-21/23/24): голландский шаг 1,7–2,1 рад/с против 0,92 у Hiway Demon; Cnβ, Cnp, Cnr, Clp подогнаны к литературе
- [docs/research/pendulum/pilot-answers-game-check.md](research/pendulum/pilot-answers-game-check.md) — Умолчания «Аппарата» по классам из ответов пилота 11.10, подвеска ЦМ +2–3 см вперёд; сверка игры с прототипом: расхождений >15 % нет
- [docs/research/pendulum/prototype.md](research/pendulum/prototype.md) — Прототип этапа A (16 полос, цепь из 3 звеньев): трим ±0,3 км/ч, фугоида T 5,2–5,7 с, подвеска 0,4–0,9 км/ч на см; параметры «Аппарата»
- [docs/research/pendulum/stall-spin.md](research/pendulum/stall-spin.md) — Срыв по Viterna вместо 2D-пластины, место срыва по критическому сечению, C_N 90° ≈ 1,2; сваливание и штопор в прототипе (PD-22)
- [docs/research/pendulum/takeoff-ground.md](research/pendulum/takeoff-ground.md) — Разбег и старт PD-28 (пилот: «за 10 м не взлетел — не взлетишь» против 21–31 м модели), подскоки PD-36, ноги PD-38, авария PD-39
- [docs/research/pendulum-yaw-literature.md](research/pendulum-yaw-literature.md) — Боковые производные Hiway Demon (Cook): Cnβ 0,0275, голландский шаг 0,92 рад/с, спираль устойчива; в игре Cnβ 0,05
- [docs/research/pendulum.md](research/pendulum.md) — Маятник: прототип с 16 полосами даёт трим ±0,3 км/ч и фугоиду T 5,2–5,7 с; крен задаёт гибкость паруса; мягкой посадки в штиль нет
- [docs/research/pendulum_pitch.md](research/pendulum_pitch.md) — Тангаж «Маятника»: «нос −24…−43°» — пикирование при резком «на себя», не жёсткость; на 1,6·V_трим Δθ −9,6° (эталон −9,5°) [closed]
- [docs/research/pilot_mass.md](research/pilot_mass.md) — Масса пилота: поляра растягивается на k = √(M·ρ_эт/(M_эт·ρ)), качество не меняется; τ крена ∝ √M; данные четырёх крыльев
- [docs/research/simhub.md](research/simhub.md) — SimHub не читает SRS и DPMR; путь — «External sim integration» (simdef + UDP 55 байт заголовка, бета, Windows); не реализовано. [closed]
- [docs/research/slope_wind/coupled-system.md](research/slope_wind/coupled-system.md) — Связанная система по этапам; рекомендация: этап 1 (WF-13) и T по N из погоды сразу, крышку по инверсии и термики-источники — позже [closed]
- [docs/research/slope_wind/current-heuristic.md](research/slope_wind/current-heuristic.md) — Эвристика air_velocity_at на 29.09: степенной профиль, w_ridge с полосой 250 м, линия тени 12°; где не физично и что не ломать (провалы) [closed]
- [docs/research/slope_wind/mass-consistent-field.md](research/slope_wind/mass-consistent-field.md) — Массосогласованное поле на Rust/GPU: уравнение Пуассона, линейность по ветру (ранг 2), нейросеть; сравнение с вариантом A [closed]
- [docs/research/slope_wind/options-recommendation.md](research/slope_wind/options-recommendation.md) — Condor, WindNinja, CFD; варианты A (дни), B (БПФ), C (массосогласованное поле), D (CFD) и рекомендация: A, затем B [closed]
- [docs/research/slope_wind/pilot-answer.md](research/slope_wind/pilot-answer.md) — Ответ пилота 29.09: усиление до 2 высот горы от подножия, на 2,5 H ламинарно, седловина ×1,5 вдоль оси при косом ветре до 15° [closed]
- [docs/research/slope_wind/real-physics.md](research/slope_wind/real-physics.md) — ΔS_max ≈ B·H/L (B ≈ 2,0 хребет), спад exp(−A·z/L), отрыв при уклонах 15–20°, седловина +40–60 %, полоса подъёма [closed]
- [docs/research/slope_wind/sources.md](research/slope_wind/sources.md) — Источники: Jackson–Hunt 1975, Taylor–Lee 1984, Askervein, ASCE 7, Wood 1995, работы по отрыву за холмами [closed]
- [docs/research/slope_wind/thermals-network.md](research/slope_wind/thermals-network.md) — Ветер не видит термики и облака; ложная турбулентность mean_wind_at; ветер постоянен на полёт; GPU не мешает сети (физика на клиенте) [closed]
- [docs/research/slope_wind.md](research/slope_wind.md) — Обтекание склона: в эвристике нет разгона на бровке и полоса подъёма 250 м; варианты A–D; вместо них — поле Пикара [closed]
- [docs/research/sounds.md](research/sounds.md) — Звук: ассеты и процедурный синтез (FR-28, FR-29) — Итог: 51 файл, 8,2 МБ в assets/sounds/ (ориентир был ≤ 30 МБ). [closed]
- [docs/research/steam_godotsteam.md](research/steam_godotsteam.md) — GodotSteam GDExtension 4.22.1 (MIT, Steamworks 1.65): только в пресетах с меткой steam, без аддона в itch; Cloud — Auto-Cloud.
- [docs/research/steam_license_audit.md](research/steam_license_audit.md) — Аудит лицензий сборки для Steam: NC-материалов нет; 100 файлов без строки ASSETS.md, на 15.10 осталось 12 (build_inventory --check). [closed]
- [docs/research/steam_tile_policy.md](research/steam_tile_policy.md) — Карта выбора старта и правила OSM/OpenTopoMap: из 3 нарушений закрыты User-Agent с версией, пауза после 403/429, 2 потока OSM.
- [docs/research/surface_params/class-details.md](research/surface_params/class-details.md) — Откуда числа таблицы: альбедо (Oke), Боуэн и влажность почвы, z0 (Wieringa), доля G/Rn; диапазоны и ключи источников
- [docs/research/surface_params/game-classes-config.md](research/surface_params/game-classes-config.md) — Соответствие классов игры строкам П4, блок для configs/surface_heat.json, что вне модели
- [docs/research/surface_params/game-moisture-water.md](research/surface_params/game-moisture-water.md) — Влажность рельефа → β (m_dry 0,25, m_norm 0,47), нагрев воды (C_H 1,4·10⁻³, запаздывание 30 сут), H_ref = 360 Вт/м²
- [docs/research/surface_params/game-radiation.md](research/surface_params/game-radiation.md) — K↓ = S₀·T_r·sin ψ по Stull (S₀ = 1361, T_r = 0,6 + 0,2·sin ψ, облака 1 − 0,7·cover), длинноволновая L*, доля прямой и рассеянной
- [docs/research/surface_params/laws-limits.md](research/surface_params/laws-limits.md) — Законы за таблицей, сезонность, границы применимости (баланс FLUXNET замкнут на ≈ 80 %), числа без источника (EST), как использовать
- [docs/research/surface_params/references.md](research/surface_params/references.md) — Ключи источников таблицы П4 и файла surface_params.csv: Oke, Stull, Wieringa, FLUXNET и другие
- [docs/research/surface_params.md](research/surface_params.md) — Альбедо, Боуэн (влажно/норма/сухо), z0 и G/Rn по классам покрова (контракт П4 v1); числа §9 стоят в configs/surface_heat.json
- [docs/research/terrain_sources.md](research/terrain_sources.md) — Источники высот и подложки карты: Copernicus GLO-30 (детально) и Terrarium (фон) бесплатны без ключа; оба DSM, лес +15…25 м.
- [docs/research/terrain_statistics/distributions.md](research/terrain_statistics/distributions.md) — Уклон p99 на 100 м — 35° (Онгудай), на 400 м — 26°; закон Корчака подтверждён по порядку (K = 0,55–0,95). [closed]
- [docs/research/terrain_statistics/generation-methods.md](research/terrain_statistics/generation-methods.md) — Для 40 км выбран Fastscape (SPL + диффузия + порог уклона): 6,4 с на рельеф 384²; параметры по двум типам рельефа. [closed]
- [docs/research/terrain_statistics/limits-and-literature.md](research/terrain_statistics/limits-and-literature.md) — Замерены 4 места (Южный Урал, Алтай); Альпы и Кавказ не измерены; первоисточники ряда законов не открывались. [closed]
- [docs/research/terrain_statistics/measurements.md](research/terrain_statistics/measurements.md) — Сумма форм: 30 форм дают 92–96 % дисперсии на 400 м, вершин в 3–7 раз меньше; у Fastscape в 1,5–6 раз меньше. [closed]
- [docs/research/terrain_statistics/peaks-and-saddles.md](research/terrain_statistics/peaks-and-saddles.md) — Вершин prominence ≥ 30 м на квадрат 40 × 40 км: 26–67 (Урал), 83–138 (Алтай), 91–116 (Онгудай); b = 1,1–1,9. [closed]
- [docs/research/terrain_statistics.md](research/terrain_statistics.md) — Горный рельеф 40 × 40 км, 4 места: Fastscape ближе к реальному, чем сумма форм (вершин в 1,5–6 раз меньше); сводка и 5 частей. [closed]
- [docs/research/terrain_tuning.md](research/terrain_tuning.md) — Настройка 8 параметров генератора рельефа fs1 по 367 квадратам: медиана χ²/ndf 1,47 против 1,79; настроенные θ лучше ручных. [closed]
- [docs/research/thermals.md](research/thermals.md) — Термик — профиль Gedeon с радиусом по Allen (∝ξ^⅓), наклон ветром, распад снизу; склон и ротор — по градиенту рельефа; детерминированно. [closed]
- [docs/research/vario_sounds.md](research/vario_sounds.md) — Пресет classic_90s: меандр до 11-й гармоники, резонанс 3,2 кГц, 700 → 2000 Гц и 2 → 11 писков/с; звучание по умолчанию.
- [docs/research/visual_cues.md](research/visual_cues.md) — Визуальные признаки для пилота: что должно быть видно в симуляторе — Исследование к FR-14a, FR-19, FR-20, FR-21, FR-22, FR-26. [closed]
- [docs/research/wing_sources.md](research/wing_sources.md) — Источники по моделям дельтапланов — Где искать внешний вид и характеристики крыльев (для линейки — docs/archive/plan/wings-lineup.md). [closed]
- [docs/research/wings_config_sources.md](research/wings_config_sources.md) — Паспорта → configs/wings/*.json: поправлены массы и двойная поверхность, противоречия не подгонялись; приоритет у DHV
- [docs/research/xc_reference.md](research/xc_reference.md) — Эталоны XC: набор 1–2 / 2–3,5 м/с, маршрутная 20–30 / 30–45 км/ч, 2–4 / 1,5–3 термика на 10 км (средний / сильный день)
- [docs/research/zheglov-1983/era-gliders.md](research/zheglov-1983/era-gliders.md) — Аппараты эпохи: учебные S 13–18 м², 18–25 кг, угол 100–120°, K 5–8; спортивные до K 12; перегрузка +4/−2
- [docs/research/zheglov-1983/glide-turn-stall.md](research/zheglov-1983/glide-turn-stall.md) — Кинематика: n = 1/cosγ, r = V²/(g·tgγ), V_сп = V/√cosγ; срыв начинается на концах, на обучении крен ≤ 25–30°
- [docs/research/zheglov-1983/model-comparison.md](research/zheglov-1983/model-comparison.md) — Что книга меняет в модели (спираль, подвеска, Cnβ, срыв, разбег) и 10 эталонов для тестов кинематики
- [docs/research/zheglov-1983/stability.md](research/zheglov-1983/stability.md) — Устойчивость: S-образный киль и крутка, подвеска «чуть вперёд» (шаг 20–30 мм), поворот через скольжение и флюгерный момент
- [docs/research/zheglov-1983/takeoff-landing.md](research/zheglov-1983/takeoff-landing.md) — Старт и посадка: отрыв при ≈ 25 км/ч воздушной, плоскость каркаса 5–6° к горизонту, выдерживание на 1–1,5 м
- [docs/research/zheglov-1983/turbulence-thermals.md](research/zheglov-1983/turbulence-thermals.md) — Болтанка и термики: порывы обычно ≤ 1–2 м/с, под кучевыми 2,5–4 м/с (65 % случаев), в болтанке — около наивыгоднейшей
- [docs/research/zheglov-1983.md](research/zheglov-1983.md) — Учебник 1983 (Жеглов и др.): качественная теория и практика без аэродинамических производных; формулы виража, эталоны для тестов
- [tools/research/a1/README.md](../tools/research/a1/README.md) — А1.1: пробы правок решателя Пикара (Pr_t 0,85, второй скаляр тепла θ′_d, h слоя при closure=const); правки А1.2 влиты в игру
- [tools/research/a1/review/README.md](../tools/research/a1/review/README.md) — А1.3: ревью правок А1.2 — числа проб совпали, χ² Askervein 68,06/44, диагноз несходимости эталона 200 м, цена итерации
- [tools/research/a2pre/README.md](../tools/research/a2pre/README.md) — Разведка перед А2: сходимость и цена решателя воздуха на новых параметрах — Записка с выводом — docs/archive/plan/air-model-a2pre.md. [closed]
- [tools/research/air3d/README.md](../tools/research/air3d/README.md) — 3D-Пикар на Онгудае (прикидка): 182/182 решений сходятся, 400 м — 0,3–0,8 с, 200 м — 1,2–4,2 с на 4070 SUPER; эталон — reference.md
- [tools/research/air_clipmap/README.md](../tools/research/air_clipmap/README.md) — Стык уровней клипмапа AM-04: профиль поля вдоль линии через края окон 50 и 100 м, выборка игры против отдельных уровней. [closed]
- [tools/research/air_model_baseline/README.md](../tools/research/air_model_baseline/README.md) — AM-00: зонд базовых цифр до новой модели воздуха (время air_velocity_at, статистика рывков за подветренной зоной, термики за день). [closed]
- [tools/research/air_nn_pilot/README.md](../tools/research/air_nn_pilot/README.md) — Пилот air-nn: сеть U-Net+FiLM как замена решателя поля ветра; в игру сеть вошла и затем заменена фазовой сборкой (AP-21) [closed]
- [tools/research/air_phase/assembly/README.md](../tools/research/air_phase/assembly/README.md) — AP-17, P8 v1: сборка поля по фазам — классификатор и механизмы A, D, LEE, E/F, H из рельефа и условий без поля решателя
- [tools/research/air_phase/hybrid/README.md](../tools/research/air_phase/hybrid/README.md) — AP-18, P9 v1: прототип «фазы + Пикар» — код готов и протестирован на CPU, счёт против Пикара не проводился; вход для AP-19 [closed]
- [tools/research/air_runtime/README.md](../tools/research/air_runtime/README.md) — AM-06Б: ход среднего поля в точке при пересчёте поля в полёте (плавная подмена уровней, AirRuntime). [closed]
- [tools/research/air_start/README.md](../tools/research/air_start/README.md) — Воздух у старта (air-start) — данные AS-1 — Жалоба пилота на 1.0.0: при 6 м/с на старте «сдувает». [closed]
- [tools/research/air_start/as2/README.md](../tools/research/air_start/as2/README.md) — AS-2: болтанка и разворот ветра у земли из поля GPU — зонд 1,5 м над стартом до/после, разбор по членам, регрессионный тест
- [tools/research/air_thermals/README.md](../tools/research/air_thermals/README.md) — AM-07: термики из поля — замеры — Описание модели — docs/guide/air-model/thermals.md → «Масштаб 2: термики из поля». [closed]
- [tools/research/air_turb/README.md](../tools/research/air_turb/README.md) — AM-08: возмущения из поля (масштаб 3) — замеры — Описание модели — docs/guide/air-model/turbulence.md → «Масштаб 3: возмущения из поля». [closed]
- [tools/research/ann2/README.md](../tools/research/ann2/README.md) — Код и команды ann2 (AN-1…AN-4): предел данных, сеть 2,5D-оператор, пилот, AN-4. Отложено 05.10; данные прогонов удалены, таблицы — в out/. [postponed]
- [tools/research/b2/README.md](../tools/research/b2/README.md) — Б2: α и λ в игре — профиль притока по устойчивости, пересчёт эталонов и цена — Записка — docs/archive/plan/air-model-b2.md. [closed]
- [tools/research/basebar_curve/README.md](../tools/research/basebar_curve/README.md) — Изгиб базовой штанги по 48 крыльям: 37 изогнутых (вынос 0,07–0,11 м, оценка класса), 11 прямых; shape — по руководствам, bow_m — оценка [closed]
- [tools/research/cases/README.md](../tools/research/cases/README.md) — Случаи калибровки модели воздуха (Askervein, Perdigão, Б1): общие правила постановки и схема решателя, контракт C10. [closed]
- [tools/research/cases/b1/README.md](../tools/research/cases/b1/README.md) — Б1: совместная калибровка Askervein + Perdigão (C10 v2): 765 прогонов, подгонка, проверка у лучшей точки, регрессия А2 [closed]
- [tools/research/cases/perdigao/README.md](../tools/research/cases/perdigao/README.md) — Случай Perdigão (А4) для калибровки: модуль C10 v2 (dx 30 м, область 6 км, NE и SW), пробный прогон А4 — история [closed]
- [tools/research/data/askervein/README.md](../tools/research/data/askervein/README.md) — Данные Askervein Hill (Zenodo 4095052, CC BY 4.0): мачты, профиль притока, рельеф; FSR на вершине на 10 м ≈ 0,8 [closed]
- [tools/research/data/perdigao/README.md](../tools/research/data/perdigao/README.md) — Данные Perdigão 2017: мачты ISFS, лидары DTU, положение мачт, отобранные случаи; доступ, лицензия и цитирование [closed]
- [tools/research/data/wing_passports/README.md](../tools/research/data/wing_passports/README.md) — Паспорта дельтапланов: сводный набор по моделям и размерам из страниц производителей и карточек DHV, с цитатами [closed]
- [tools/research/fb1013_evening/README.md](../tools/research/fb1013_evening/README.md) — FBW-1: вечерние термики осенью при облачности — поле считалось на 15 июля при любой дате; разбор у старта до/после починки [closed]
- [tools/research/heat_ca/README.md](../tools/research/heat_ca/README.md) — Клеточный автомат тепла и массы, 2D-разрез хребта: сохранение точное, установление 3–7 ч модели; 3D 200 м ~5–10 с на 4070 SUPER [closed]
- [tools/research/heat_ca/exp1_3_6_kernels/README.md](../tools/research/heat_ca/exp1_3_6_kernels/README.md) — Опыты 1, 3, 6: автомат одной линейной свёрткой не заменить; «ядро струи» — быстрая диагностика и начальное приближение [closed]
- [tools/research/heat_ca/exp2_picard/README.md](../tools/research/heat_ca/exp2_picard/README.md) — Опыт 2: установившееся поле итерациями Пикара с прогонками и многосеточным Пуассоном — без шагов по времени, в 2–36× быстрее [closed]
- [tools/research/heat_ca/exp4_transfer_sweeps/README.md](../tools/research/heat_ca/exp4_transfer_sweeps/README.md) — Опыт 4: установившееся поле проходами по слоям (матрицы перехода) — код, запуск и файлы; итог — summary.md [closed]
- [tools/research/heat_ca/exp5_adi/README.md](../tools/research/heat_ca/exp5_adi/README.md) — Опыт 5: чередующиеся прогонки по линиям (ADI) доводят автомат до той же точки за 100–190 раундов, в 9–23× быстрее шагов [closed]
- [tools/research/lakes_worldcover/README.md](../tools/research/lakes_worldcover/README.md) — Озёра: WorldCover 10 м против OSM на 4 местах — IoU по крупным озёрам 0,86–0,97, вода не теряется на шагах сборки и в H [closed]
- [tools/research/location_compression/README.md](../tools/research/location_compression/README.md) — Сжатие данных мест (data/terrain, user://locations): почему выросли после перехода на GDScript и какие форматы Godot 4.7 дают выигрыш [closed]
- [tools/research/morris/README.md](../tools/research/morris/README.md) — Моррис: чувствительность модели воздуха — Итог и выводы — docs/research/air-model-sensitivity.md. [closed]
- [tools/research/mountain_look/README.md](../tools/research/mountain_look/README.md) — Замер «до»: как слои, сглаживание σ 0,8 и шаг LOD меняют силуэт гор (Эверест, Эльбрус, Монблан, Домбай, Онгудай); зонд MLK-К3 [closed]
- [tools/research/obf_region/README.md](../tools/research/obf_region/README.md) — Эксперимент: состав OsmAnd OBF региона — К документу docs/plan/offline_world_data.md (раздел «Почему не OsmAnd OBF»). [closed]
- [tools/research/openfreemap/README.md](../tools/research/openfreemap/README.md) — Сравнение векторных тайлов OpenFreeMap z14 с эталоном osm.json (Overpass) на месте aushkul: скрипты и числа. [closed]
- [tools/research/osm_pack/README.md](../tools/research/osm_pack/README.md) — osm_pack: замер компактного офлайн-пакета (OSM-вектор + рельеф + покров), Словения — этап 0 плана offline_world_data [closed]
- [tools/research/pendulum/README.md](../tools/research/pendulum/README.md) — Прототип «честного маятника» на Python: крыло — тело с 16 полосами, пилот — точка на цепи из N звеньев (XPBD), руки с пределом силы
- [tools/research/pendulum/pd33/README.md](../tools/research/pendulum/pd33/README.md) — Данные разбора правильной посадки маятника (PD-33): ход посадки по шагам, варианты, сильный ветер.
- [tools/research/pendulum/pd35/README.md](../tools/research/pendulum/pd35/README.md) — PD-35: посадка маятника — ход рук по досягаемости, касание «встал на ноги / пробежал / жёстко», C_N 90° × cos²Λ; скрипты пачек
- [tools/research/pendulum_pitch/README.md](../tools/research/pendulum_pitch/README.md) — Тангаж «Маятника» на разгоне: скрипт замеров (pendulum_pitch.gd), разбор против точечной массы с полярой, фугоида; команды воспроизведения [closed]
- [tools/research/pilot_view/README.md](../tools/research/pilot_view/README.md) — PV-1: геометрия пилота лёжа и вид из кабины — штанга позади глаз на 112–120°; нужна ~0,5 м впереди плеч, FOV ~90°
- [tools/research/qol_load/README.md](../tools/research/qol_load/README.md) — QL-6: замер времени «Рассчитываем ветер» после air-phase — прервано, отменено решением пользователя 07.10 (Q-07 отложен); 20 из 32 строк [postponed]
- [tools/research/qol_signs/README.md](../tools/research/qol_signs/README.md) — QL-5: почему не видно птиц (размер 1,6 м → 1–2 px на типичных 1–1,5 км) и сколько признаков термика за 10 минут на 4 местах × 13:00/15:00. [closed]
- [tools/research/recal/README.md](../tools/research/recal/README.md) — Перекалибровка Askervein по (λ/h, α, z0) с профилем мачты RS: сетка 495 прогонов, подгонка χ² iminuit [closed]
- [tools/research/steam/README.md](../tools/research/steam/README.md) — ST-1: прототип загрузки GodotSteam GDExtension 4.22.1 в Godot 4.7.2 headless — скрипты, команды воспроизведения, лицензии [closed]
- [tools/research/steam_license/README.md](../tools/research/steam_license/README.md) — Команды воспроизведения аудита лицензий сборки SA-1: настоящий экспорт, разбор PCK, сверка с эмуляцией, сводки. [closed]
- [tools/research/surface_heat/README.md](../tools/research/surface_heat/README.md) — SH-3: инструмент замера до/после (контракт SH5) — H поля, источники термиков, потолок, подъём на склоне, вода; прогон «до»
- [tools/research/surface_heat/moisture/README.md](../tools/research/surface_heat/moisture/README.md) — Перцентили влажности рельефа по 4 местам: медиана 0,475, p10 0,26, p90 0,68; пороги m_dry 0,25, m_norm 0,47, m_wet 0,70 [closed]
- [tools/research/tune/README.md](../tools/research/tune/README.md) — AM-09: калибровка масштаба 1 и порогов масштаба 3 по Askervein схемой Professor (полиномы по прогонам, χ², eigentunes). [closed]
- [tools/research/wind_compare/README.md](../tools/research/wind_compare/README.md) — Сравнение поля ветра main и feature/air-model (Онгудай) — Выгрузка из игры (Atmosphere.air_velocity_at / mean_wind_at), не из air.py. [closed]
- [tools/research/windninja/README.md](../tools/research/windninja/README.md) — WindNinja как эталон: гребневой разгон и поворот потока совпадают с решателем air-nn, торможения массивом нет — как запасной вариант условно [closed]
- [tools/research/wing_physics_check/README.md](../tools/research/wing_physics_check/README.md) — Проверка физики крыльев — данные и инструменты — Модуль wing-physics-check (docs/archive/plan/wing-physics-check.md). [closed]
- [tools/research/air3d/summary.md](../tools/research/air3d/summary.md) — 3D-Пикар на рельефе Онгудая: время, сходимость, размер поля — итог прикидки — Эталон AM-01 (29.09.2026) — reference.md. [closed]
- [tools/research/air_nn_pilot/p3/out/cond_p2b/summary.md](../tools/research/air_nn_pilot/p3/out/cond_p2b/summary.md) — Ошибка сети P2b на 60 м по условиям: U10 объясняет 70 % дисперсии, три четверти разброса — внутри случая (720 случаев) [closed]
- [tools/research/air_nn_pilot/p3/out/cond_p3e0/summary.md](../tools/research/air_nn_pilot/p3/out/cond_p3e0/summary.md) — Ошибка сети P3E0 на 60 м по условиям: медиана ветра 0,68 м/с у сошедшихся и 0,48 у несошедшихся (720 случаев) [closed]
- [tools/research/air_nn_pilot/p3/out/cond_p3e6/summary.md](../tools/research/air_nn_pilot/p3/out/cond_p3e6/summary.md) — Ошибка сети P3E6 на 60 м по условиям: медиана ветра 0,69 м/с у сошедшихся и 0,48 у несошедшихся (720 случаев) [closed]
- [tools/research/air_nn_pilot/p3/out/smooth_p2b/summary.md](../tools/research/air_nn_pilot/p3/out/smooth_p2b/summary.md) — Размытие выхода сети σ 0–2 клетки не помогает: оптимум медианы ошибки ветра при σ = 0 (720 случаев, 60 м) [closed]
- [tools/research/air_synth/hg_sites/summary.md](../tools/research/air_synth/hg_sites/summary.md) — Каталог мест дельтаплана из OSM — сводка — Выгрузка Overpass: 2026-10-04. © OpenStreetMap contributors, ODbL. [closed]
- [tools/research/data/perdigao/menke2019/summary.md](../tools/research/data/perdigao/menke2019/summary.md) — Menke et al. 2019 (ACP 19, 2713) — данные для калибровки зоны рециркуляции — Источник: doi:10.5194/acp-19-2713-2019, CC BY 4.0. [closed]
- [tools/research/heat_ca/exp1_3_6_kernels/summary.md](../tools/research/heat_ca/exp1_3_6_kernels/summary.md) — Опыты 1, 3, 6: линейность, ядра, «ядро струи» — Команды для каждой картинки — README.md. Выходы — в out/, сырые поля — в out/cache/*.npz. [closed]
- [tools/research/heat_ca/exp2_picard/summary.md](../tools/research/heat_ca/exp2_picard/summary.md) — Опыт 2, итог: Пикар доходит до неподвижной точки автомата (≤ 10⁻⁴ за 2 ч); схема итерации, точность, время по клеткам 200–25 м [closed]
- [tools/research/heat_ca/exp4_transfer_sweeps/summary.md](../tools/research/heat_ca/exp4_transfer_sweeps/summary.md) — Опыт 4, итог: проходы вверх-вниз дают ту же точку, что автомат; повторов 50–240, выигрыш 2,5× (200 м) до 74× (25–12,5 м) [closed]
- [tools/research/heat_ca/exp5_adi/summary.md](../tools/research/heat_ca/exp5_adi/summary.md) — Опыт 5, итог: ADI даёт тот же ответ без многосеточного; итераций как в опыте 2, но итерация в 3–6× дороже [closed]
- [tools/research/heat_ca/out/s1_sun_one_slope/summary.md](../tools/research/heat_ca/out/s1_sun_one_slope/summary.md) — Сценарий 1 (солнце на крутой склон, штиль): подъём до 1,65 м/с на 475 м над землёй, высота подъёма 1400 м, 5754 шага [closed]
- [tools/research/heat_ca/out/s2_both_slopes/summary.md](../tools/research/heat_ca/out/s2_both_slopes/summary.md) — Сценарий 2 (оба склона прогреты, штиль): подъём до 2,47 м/с, высота подъёма 1800 м над подножием, 6302 шага [closed]
- [tools/research/heat_ca/out/s2_sym/summary.md](../tools/research/heat_ca/out/s2_sym/summary.md) — Сценарий 2б (симметричный хребет, штиль): подъём до 2,08 м/с строго над гребнем, картина зеркальная [closed]
- [tools/research/heat_ca/out/s3_wind/summary.md](../tools/research/heat_ca/out/s3_wind/summary.md) — Сценарий 3 (фоновый ветер 3 м/с): подъём до 1,40 м/с, высота подъёма 2650 м над подножием, 5480 шагов [closed]
- [tools/research/heat_ca/out/s4_inversion/summary.md](../tools/research/heat_ca/out/s4_inversion/summary.md) — Сценарий 4 (инверсия на 1,5 км): подъём до 2,33 м/с, высота подъёма 1550 м против 1800 м без инверсии [closed]
- [tools/research/heat_ca/out/summary.md](../tools/research/heat_ca/out/summary.md) — Клеточный автомат тепла и массы, общий итог 2D-разреза хребта: сценарии против условий приёмки, сходимость, вывод для игры [closed]
- [tools/research/mountain_look/summary.md](../tools/research/mountain_look/summary.md) — Вывод замера MLK-1: Эверест с 23–29 км рисует фон, LOD-шаг важнее сетки 100 м, σ 0,8 срезает ~35–50 % кривизны гребней [closed]
- [tools/research/tune/out/am09b/summary.md](../tools/research/tune/out/am09b/summary.md) — AM-09б: пробы 0,1 → 0,25 — сила термиков из поля меняется ≤ 3 %, сумма χ² проверок масштабов 2–3 по литературе 5,43 → 5,26 [closed]

### Справка (reference)

- [docs/screenshots/cockpit/README.md](screenshots/cockpit/README.md) — Кадры приёмки кабины (VR-11, FR-25a, VR-6): tools/shots/cockpit.sh, Онгудай, 1920×1080, автопилот
- [docs/screenshots/e2e/README.md](screenshots/e2e/README.md) — Кадры сквозного теста свободного полёта (меню → старт → разбег → полёт): tools/shots/e2e.sh
- [docs/screenshots/gameplay/README.md](screenshots/gameplay/README.md) — Кадры геймплея свободного полёта по камерам: tools/shots/gameplay.sh, Онгудай, 1920×1080, 20 с
- [docs/screenshots/site/README.md](screenshots/site/README.md) — Кадры для сайта (октябрь 2026) — Сняты готовыми инструментами tools/shots после обновления крыльев (48 моделей).
- [docs/screenshots/ui/README.md](screenshots/ui/README.md) — Скриншоты ui/01 — меню, «Полёт…», карта, «Управление» — Сняты godot --rendering-method gl_compatibility под xvfb-run (см.
- [tools/research/_legacy_terrain/README.md](../tools/research/_legacy_terrain/README.md) — Замороженная Python-сборка данных мест (fetch_dem, landcover, rivers, osm) — только для воспроизведения perdigao, osm_pack, hg_sites [closed]
- [tools/research/air_phase/README.md](../tools/research/air_phase/README.md) — Код воспроизведения эмпирической фазовой карты по полям решателя SY-12: признаки на случай, таблицы, схема диаграммы
- [tools/research/air_synth/corpus/README.md](../tools/research/air_synth/corpus/README.md) — Корпус air-synth: чтение/запись S1/S2 (corpus_io.py), запуск корпуса (run_corpus.py), тесты, замер времени [closed]
- [tools/research/air_synth/hg_real/README.md](../tools/research/air_synth/hg_real/README.md) — SY-10: рельеф мест дельтаплана (363 → 304 места корпуса S1 v4) квадратом как в игре, деление train/holdout, сверка с кодом игры [closed]
- [tools/research/air_synth/hg_sites/README.md](../tools/research/air_synth/hg_sites/README.md) — Каталог стартов дельтаплана из OSM (S6): все старты, неясные, только параплан, места 10 км, выжимка для игры; команды выгрузки и сборки [closed]
- [tools/research/air_synth/real/README.md](../tools/research/air_synth/real/README.md) — Реальные места air-nn v3 (360 + 4 места игры) в корпусе S1 v3 (HDF5): конвейер П6, упаковка, команды воспроизведения [closed]
- [tools/research/air_synth/solver/README.md](../tools/research/air_synth/solver/README.md) — SY-8: счёт решателя P2 по рельефам × условиям p2c12 (S5 v2) — скрипты, команды, пробный прогон и оценка [closed]
- [tools/research/air_synth/terrain_stats/README.md](../tools/research/air_synth/terrain_stats/README.md) — Код и команды воспроизведения статистик рельефа, разложения на формы и генерации (Fastscape, сумма форм) для air-synth [closed]
- [tools/research/air_synth/train/README.md](../tools/research/air_synth/train/README.md) — SY-11: обучение сети P2 (U-Net+FiLM) на счёте решателя по местам дельтаплана; сеть заменена фазовой сборкой [closed]
- [tools/research/air_synth/tune/README.md](../tools/research/air_synth/tune/README.md) — Код и команды воспроизведения настройки параметров генератора рельефа схемой Professor (SY-5): эталон, прогоны, подгонка, облако θ [closed]

### Реестры (registry)

- [docs/registry/findings.md](registry/findings.md) — Реестр выводов закрытых работ: раздел на модуль, пункт — одна строка с числом и ссылкой; отклонённые модули помечены (отклонено).
- [TODO.md](../TODO.md) — Реестр задач T-NN по блокам (воздух, полёт, мир, графика, сеть, релиз): строка с состоянием и ссылкой на план
- [REQUIREMENTS.md](../REQUIREMENTS.md) — Требования к игре: физика, атмосфера, мир, интерфейс, звук, управление, визуал (MVP → позже) и нефункциональные NFR-1…7

архив: 115 документов — `.dpcli/dpcli docs find --status closed`
