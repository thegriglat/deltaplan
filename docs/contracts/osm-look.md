---
type: "contract"
status: "active"
module: "osm-look"
updated: "2026-10-11"
summary: "Контракты osm-look (вид объектов OSM): L1 тип дома в записи (O9 v2), L2 стиль домов город/село/промзона и шейдер, L3 трубы и дым, L4 ветер для слоя OSM, L5 модели ЛЭП/мачт/башен/труб, L6 ветряки и кабинки канатки."
related: ["docs/plan/osm-look.md", "docs/contracts/osm-tiles.md", "docs/guide/osm-tiles.md"]
contracts: [{"id": "L1", "version": 1}, {"id": "L2", "version": 1}, {"id": "L3", "version": 1}, {"id": "L4", "version": 1}, {"id": "L5", "version": 1}, {"id": "L6", "version": 1}]
---
# Контракты модуля osm-look

План — `docs/plan/osm-look.md`. Только отрисовка мира: тайлы, упаковщик, формат O1–O8 и лётная модель
не меняются. Контрактные тесты — `tests/contracts/test_osm_look_contracts.gd` (версии, L1, L2, L4) и
`tests/contracts/test_osm_look_models_l5.gd` (L5, создаёт OL-2) и `test_osm_look_models_l6.gd` (L6, создаёт OL-3). Правка контракта —
версия +1 здесь, в frontmatter и в тесте, уведомление потребителей.

Общие правила для всех разделов:
- Всё неизвестное — значение в `configs/world_objects.json` (ключ + `_doc`), не константа в коде.
- Детерминированность: выбор (стиль, цвет, труба, дым, фаза) — только от данных дома/объекта
  (`WorldTiles.hash01` от индекса или от округлённых координат места), не от `randf()` и не от времени.
- Дальности видимости и теней (`visibility_m`, `cast_shadows`, пресеты `quality_presets`) — как сейчас;
  на пресете `low` тени домов выключены, как сейчас.
- Препятствия (`ObstacleIndex`) — те же коробки/цилиндры, что сейчас; меняются только если меняется
  размер объекта, и тогда в той же задаче.
- Производительность: сборка слоя домов Алматы 3×3 (≈ 280 тыс. домов, сейчас ≈ 3,4 с, `OsmBuildings.last_stats`)
  — не больше +15 %; кадр в Алматы (`tools/bench/frame_profile`) — в пределах шума замера.

## L1 v1 — тип дома в записи (O9 → v2)
Владелец: OL-1. Потребители: `BuildingPlacer`, `BuildingStyle` (L2), `VillagePlacer`, тесты.

`OsmData.buildings` — запись `[x, z, w, l, угол_град, высота_стен_м, крыша 0|1, тип, по_правилу]`:
- `тип: int` — код типа O3 (`yes` 0 … прочее 26, таблица — `docs/contracts/osm-tiles.md`, O3 BUILDINGS);
- `по_правилу: int` — 1, если высота взята из `height_rule` (в тайле `hq = 0`: нет ни `height`, ни
  `building:levels`), 0 — высота/этажи из тегов OSM (такие дома поправка L2 не трогает).
Остальные поля — как в O9 v1. Процедурные дома (`VillagePlacer`, формат N3) остаются с 7 полями;
**нет 8-го и 9-го поля = тип `-1` (процедурный дом посёлка), `по_правилу` 1**. `BuildingPlacer.place` принимает обе длины. В `docs/contracts/osm-tiles.md` O9 поднят до версии 2
(строка «что изменилось»), `test_osm_tiles_contracts.gd` — вместе.

## L2 v1 — стиль домов: город / село / промзона
Владелец: OL-1. Потребители: `BuildingPlacer`, `OsmBuildings`, шейдер домов, L3.

**Классификация** — `BuildingStyle` (`scripts/world_objects/osm/building_style.gd`):
`static func classify(buildings: Array, cfg: Dictionary) -> PackedByteArray` — по стилю на запись, в том же
порядке: `CITY = 0`, `VILLAGE = 1`, `INDUSTRIAL = 2` (константы класса). `cfg` — `world_objects.json → buildings`
(раздел `style`). O(n) по числу домов, без нод и без GPU; вызывается в том же потоке, что и `BuildingPlacer.place`.

Признаки (только клиент, тайлы не меняются): тип L1, площадь следа `A = w·l`, вытянутость `l/w`, плотность
застройки клетки `style.cell_m` (≈ 200 м): число домов и доля площади клетки под домами (считается при
загрузке по всем записям). Порядок правил (пороги — в `style`, значения подбирает OL-1 по смыслу, не по картинке):
1. тип ∈ `industrial_types` (`industrial`, `warehouse`) → INDUSTRIAL;
2. тип ∈ `city_types` (`apartments`, `residential`, `office`, `hotel`, `commercial`, `retail`, `public`, `civic`,
   `school`) → CITY;
3. тип ∈ `village_types` (`house`, `detached`, `terrace`, `farm`, `barn`, `shed`, `garage`, `garages`, `hut`, `cabin`,
   `roof`, `service`, `construction`) и процедурные (`-1`) → VILLAGE;
4. `yes`/прочее: большой вытянутый след (`A ≥ industrial_min_area_m2` и `l/w ≥ industrial_min_ratio`) в редкой
   застройке → INDUSTRIAL; `A ≥ city_min_area_m2` или клетка плотная (доля ≥ `city_coverage`) → CITY; иначе VILLAGE.

**Поправка этажности города** (решение пользователя: Алматы выглядит маленьким) — там же, в `BuildingStyle`:
`static func adjust(buildings: Array, style: PackedByteArray, rule: Dictionary) -> PackedByteArray` — **меняет на
месте** высоту стен (поле 5) записей CITY с `по_правилу = 1` и возвращает флаг фасада на запись (`0` обычный,
`1` стекло). Параметры — `configs/osm_tiles.json → height_rule.metro` (+ `_doc`), правило не подгоняется по
картинке. Признаки — по всем загруженным домам (3×3 тайла), сеткой (не O(n²)):
- плотность центра — доля площади под домами в радиусе `metro.core_radius_m` (≈ 500–1000 м) от дома;
- масштаб города — площадь застройки в радиусе `metro.city_radius_m` (≈ 8–10 км): отличает миллионник от
  райцентра (названий и населения нет).
Множитель этажей (типы `apartments`, `residential`, `office`, `hotel`, `commercial`, `yes` при
`A ≥ metro.yes_min_area_m2`) растёт с обоими признаками: средний город ≈ 1 (как сейчас), центр миллионника —
до `metro.max_mult` (≈ 1,5–2,5); этажи округляются до целых. В самом плотном ядре мегаполиса часть крупных
`office`/`hotel`/`commercial`/`yes` (доля `metro.glass_fraction`, выбор детерминированный по координатам) —
«стекляшки» `metro.glass_floors` (15–30) этажей, флаг фасада 1. VILLAGE и INDUSTRIAL, дома с высотой из тегов —
без поправки. Препятствия (`building_obstacles`) — по поправленной высоте. Если это заметно усложняет — минимум:
множитель только от плотности + стекляшки в ядре (описать в отчёте).

**Вид** (инварианты, проверяются тестом на подставных данных и кадрами):
- крыша **всегда** другого цвета, чем стены этого дома (палитры крыш и стен стиля не пересекаются; разница
  яркости ≥ `style.min_roof_contrast`, по умолчанию 0,08 по относительной яркости);
- CITY и INDUSTRIAL — плоская крыша (верхняя грань коробки своим цветом: серый/битум у города, профлист у
  промзоны), без призмы; VILLAGE — двускатная крыша (призма, палитра `roof_colors`), этажность из правила O9;
- CITY — сетка окон по этажам (этаж `style.floor_m` = 3 м), светлые/бетонные стены, разброс по окнам (часть
  светлее/отражает небо); фасад «стекло» (флаг `adjust`) — сплошное голубовато-серое стекло с отражением неба; VILLAGE — мало окон (1–2 на стену на этаж); INDUSTRIAL — профлист, без окон;
- затемнение стен у земли (`style.ground_dark`, высота ≈ 1 м);
- без роста геометрии: окна, крыша, затемнение — в шейдере домов (`scripts/world_objects/osm/building.gdshader`)
  по данным экземпляра MultiMesh (`INSTANCE_CUSTOM`: стиль, этажи, зерно; раскладка — внутреннее дело OL-1,
  описать в шапке шейдера). Тот же шейдер получают процедурные дома посёлков (VILLAGE).

## L3 v1 — трубы и дым в сёлах
Владелец: OL-1. Потребители: L4.
- Труба — маленькая коробка на скате крыши (размер — `buildings.chimney`), только у VILLAGE с двускатной
  крышей; доля домов с трубой — `chimney.fraction`; выбор детерминированный (по округлённым координатам места).
- Дым — у доли `smoke.fraction` (по умолчанию 0,25, диапазон 0,2–0,3) домов с трубой, выбор детерминированный.
- Дым — **готовый дым костра** (`smoke_particles.gdshader` / `smoke_puff.gdshader`, как в `campfire.gd`), новый не
  делать. Не тысячи GPUParticles: пул эмиттеров `smoke.max_emitters` (≈ 32–64), ставятся у ближайших к камере
  дымящих труб в радиусе `smoke.visibility_m` (сотни м – 1–2 км), пересчёт раз в `smoke.update_s`; дальние не
  рисуются. Слабее и мельче костра (параметры в `smoke`).
- Снос по ветру — L4: ветер на кластер (тайл MultiMesh домов или клетка `smoke.cluster_m`), не на дом.

## L4 v1 — ветер для слоя OSM
Владелец: OL-1 (провод `WorldObjects` → `OsmLayer`). Потребители: дым (L3), ветряки (L6, OL-3).
- `WorldObjects` в своём обновлении раз в `world_objects.json → osm_wind.update_s` (по умолчанию 0,5 с) вызывает
  `osm_layer.update_wind(air_fn: Callable, cam: Vector3)`; `air_fn(p: Vector3) -> Vector3` — скорость воздуха
  модели в точке, м/с, мир (`WorldObjects._air_at`, т. е. `Atmosphere.air_velocity_at`); `cam` — позиция камеры
  (мир, м). Нет атмосферы — `air_fn` возвращает `Vector3.ZERO`.
- `OsmLayer.update_wind` вызывает `osm_wind(air_fn, cam)` у каждого своего потомка (обход дерева потомков с `is_in_group`, работает и вне SceneTree) в группе `&"osm_wind"`.
  Подсистемы (дым, ветряки, кабинки) добавляют свои узлы в эту группу и сами решают, где спрашивать воздух:
  не больше одного вызова `air_fn` на кластер на вызов, только кластеры в своей дальности видимости; суммарно
  по слою ≤ `osm_wind.max_samples` (по умолчанию 64) за вызов.
- Высота опроса: дым — `smoke.sample_h_m` над трубой; ветряк — высота ступицы.

## L5 v1 — модели опор ЛЭП, мачт, башен, труб
Владелец: OL-2. Потребитель: `OsmPilot` (`_power`, `_verticals`).
- Модели — скрипт Blender `tools/blender/build_osm_objects.py` (как `build_rocks.py`, помощники `bl_util.py`) →
  `assets/models/osm/<имя>.glb`, исходник `assets/source/osm/*.blend`. Имена: `power_tower` (решётчатая опора),
  `power_pole` (столб), `mast_lattice` (решётчатая мачта), `tv_tower` (телебашня), `chimney` (промышленная труба).
  Связь с OSM: `power=tower` → `power_tower`; опоры `minor_line` → `power_pole`; `mast` → `mast_lattice`;
  `tower` → `tv_tower` при `comm` или `h ≥ verticals.tv_tower_min_h_m`, иначе `mast_lattice`; `chimney` → `chimney`;
  `wind` — L6.
- Оси и единицы: метры, +Y вверх, начало — центр основания на уровне земли; у опор ЛЭП траверсы вдоль
  локального X (поперёк линии), линия — вдоль Z. Точки подвеса проводов модели = `osm_pilot.power.tower_arms_m` /
  `pole_arms_m` (±0,1 м): скрипт Blender читает их из `configs/world_objects.json`, а не дублирует числа.
- Высота: верх объекта = `h` (OSM или `default_h_m`) ± 2 %; правило масштаба (по Y с повтором текстуры или
  равномерно в пределах) — OL-2, описать в `_doc`. След не шире препятствия `radius_m` (иначе `radius_m` правится
  в той же задаче).
- Лоупольный меш + хорошая текстура: решётки — плоскости/коробки с альфа-текстурой решётки (`alpha scissor`, не
  blend — тени и сортировка), не тысячи балок. Бюджет: ≤ 600 треугольников на модель, ≤ 2 материала, текстуры
  ≤ 1024² (лучше 512²). Текстуры — CC0 (ambientCG, Poly Haven, Kenney) или процедурные из скрипта; каждая —
  строка в `ASSETS.md` (источник, лицензия с коммерческим использованием).
- Отрисовка — MultiMesh по тайлам с прежними дальностями (`tower_visibility_m`, `verticals.visibility_m`) и тенями.
  `osm_pilot.verticals.skip: Array[String]` — классы, которые `_verticals` не рисует (по умолчанию `[]`; OL-3
  ставит `["wind"]`, когда ветряки рисует L6).

## L6 v1 — ветряки и кабинки канатки
Владелец: OL-3. Потребители: `OsmLayer` (новые части слоя), L4.
- Модели — `tools/blender/build_osm_wind_cable.py` → `assets/models/osm/wind_tower.glb` (башня + гондола) и
  `wind_rotor.glb` (ротор: начало — ступица, ось вращения — локальная Z), `cable_cabin.glb` (кабинка с подвесом;
  начало — точка зацепа на тросе, кабина ниже). Оси, единицы, бюджет, текстуры, `ASSETS.md` — как L5.
- Ветряки — своя часть слоя (`scripts/world_objects/osm/osm_wind_turbines.gd`, узел в `OsmLayer`), класс `wind` из
  `OsmData.verticals`; `osm_pilot.verticals.skip` += `"wind"`. Высота ступицы = `h` или `default_h_m.wind`.
  Ротор разворачивается навстречу ветру на высоте ступицы (скорость поворота ограничена, `yaw_deg_s`) и крутится:
  0 ниже `cut_in_ms`, линейно до `rated_rpm` при `rated_ms`, стоп выше `cut_out_ms` (значения в конфиге, по
  паспорту типичной турбины 2–3 МВт). Вращение без рывков при смене ветра (угол копится, не `TIME·ω`). Фаза —
  детерминированная от координат. Препятствие — как сейчас (цилиндр башни).
- Кабинки — своя часть слоя (`scripts/world_objects/osm/osm_cable_cars.gd`), для `aerialways` классов `cable_car`,
  `gondola`, `mixed_lift` (кресла `chair_lift` — по желанию, флаг конфига): кабинки на тросе (провис как у троса
  `_aerialways`), шаг и скорость по классу (`aerialways.cabins`), движутся по линии; дальность — `aerialways.visibility_m`.
  Кабинки — не препятствия (трос уже препятствие).
- Ветер — только через L4 (группа `&"osm_wind"`); без вызова `update_wind` ветряк стоит носом по `+X` и не крутится.
