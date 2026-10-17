# FL-21: полный прогон headless-тестов, модуль против main

Дата 2026-10-17. Команда: `godot --headless --path . res://tests/run_tests.tscn` (временный XDG_DATA_HOME), копия задачи = ветка fast-load/FL-21 (от feature/fast-load) и отдельный worktree main (`~/deltaplan-fl21-main`).

| ветка | итог |
|---|---|
| модуль (FL-21) | 1956 тестов, 10 упало, 78 пропущено |
| main | 1923 теста, 7 упало, 76 пропущено |

## Падения

| тест | модуль | main | пометка |
|---|---|---|---|
| test_osm_look_contracts::test_versions | FAIL | FAIL | есть и на main |
| test_steam_assets_contracts::test_k3_assets_md_tables | FAIL | FAIL | есть и на main |
| test_steam_assets_contracts_sa4::test_licenses_set | FAIL | FAIL | есть и на main |
| test_pendulum_symmetry::test_mouse_symmetric | FAIL | FAIL | есть и на main |
| test_game_logic::test_pilot_animator_sequence | FAIL | FAIL | есть и на main |
| test_achievements_e2e::test_flight_opens_first_flight | FAIL | FAIL | есть и на main |
| test_e2e::test_e2e_all_locations | FAIL (volcano_island: kind == landed, takeoff_failed) | ok | только в модуле |
| test_matrix::test_matrix_all_combinations | FAIL (training_island, взлёт не провален; предупреждение: запечённое поле не берётся, хеш модели воздуха 6da65c77ab23e850 ≠ 1e8142f77fc07fba) | ok | только в модуле |
| test_osm_threaded::test_osm_layer_census | FAIL (CityTrees h 2790219326 ≠ 124663825) | ok | только в модуле |
| test_osm_threaded::test_villages_census | FAIL (Villages h 64495078 ≠ 1339889249) | ok | только в модуле |
| test_osm_road_look::test_city_ground_mask | ok | FAIL (земля города не построена) | только на main |

## Замечания

- Только в модуле: два теста переписи OSM (хеши слоёв отличаются от эталона) и два полётных (e2e volcano_island, matrix training_island). В matrix предупреждение о несовпадении хеша модели воздуха: запечённое поле другой версии, расчёт идёт заново. Возможно, расхождение идёт от слияния соседних модулей в feature/fast-load, а не от самих правок загрузки; причину не разбирал.
- Число тестов различается (1956 против 1923): в модуле есть новые тесты.
- GPU-тесты не запускались: замок gpu занят другой задачей (clf7b), а headless-прогон их пропускает (нет RenderingDevice). Покрытие GPU остаётся за отдельным прогоном.
- Первый прогон через `tools/check.sh --no-build` оборвался (процесс пропал); результаты взяты из повторного прогона. Заодно gdlint в копии выдал 3167 замечаний длины строк (стиль, не чиним).
