---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-21a: T9 30 км до цели за 17 мин на 1 ядре, build all и smoke Linux/wine проходят; найдены зависание build.sh и устаревший smoke.gd"
conclusion: "T9 synthetic 30 км: цель за 4885 игровых с, 1003 с CPU (0,21 с на игровую с, Q3 было 1,5); tools/build.sh all --release собирается (с обходом зависшего air_model_hash.gd, 8 мин 46 с); Linux и Windows-под-wine грузят место, подхватывают dp_air (api 6), поле READY, полёт 20 с игрового времени, кадр снят. Ветер и фазу игра в журнал не пишет — подтверждено косвенно; addons/dp_air/smoke.tscn (ветер у земли) падает на api_version 6 != 4"
data: "rw21a-t9-30km.json"
applied_in: ""
---

# RW-21a — предпроверка сдачи (ветка rust-wind до RW-14e/RW-19)

Копия `rust-wind-RW-21a` от `feature/rust-wind` (27eacfa после sync с RW-23), Godot 4.7.2, wine 10.0 (Debian), 20-ядерная машина.
Код игры не менялся. Скрипты: `tools/smoke/build_all_release.sh`, `tools/smoke/export_smoke.sh`, `tools/smoke/t9_30km.sh`.

| проверка | результат | число |
|---|---|---|
| T9 30 км | PASS: бот долетел до цели (`end_reason=goal`), 14 термиков из 15 заходов, 22,1 км/ч | 4885 игровых с; 1003 с CPU (полёт 991 с) = 0,21 с CPU на игровую с; стена 1004 с под `lock cpu` (CPUQuota=100%, одно ядро); READY места 10,7 с |
| build all --release | PASS с обходом (см. проблему 1): Linux, Windows, macOS-каталоги собраны, BUILD_RC=0 | 8 мин 46 с (cargo release linux 4 мин 14 с + windows 2 мин 44 с, fat LTO); dp_air_release.dll 18,5 МБ, libdp_air_release.so 7,0 МБ |
| linux smoke | PASS: место `training_island` загрузилось (4,5 с), `dp_air: расширение загружено, api_version=6`, `READY за 7,7 с, поле подано`, 0 FAILED, 0 SCRIPT ERROR, старт в воздухе `--air-start`, 20 игровых с, кадр снят | rc=0, shot.png 705 КБ |
| wine smoke | PASS: тот же сценарий из `build/windows/deltaplan.exe` под wine с чистым WINEPREFIX: DLL подхватилась (api 6), `READY за 45,9 с`, 0 FAILED, 0 SCRIPT ERROR, 20 игровых с, кадр снят | rc=0, shot.png 702 КБ; READY в 6 раз дольше Linux (см. границы) |

## T9 30 км

Команда: `.dpcli/dpcli lock cpu RW-21a -- tools/smoke/t9_30km.sh 2400` =
`godot --headless res://tests/atmosphere/xc/xc_run.tscn -- --synthetic --seed=1 --wind=0,0 --km=30`.
Итог — `rw21a-t9-30km.json` (рядом): 30,0 км, 4885 с, 236 кругов, средний набор 1,36 м/с, качество планирования 17,1, высота 300 -> 1599 м.
Шаг воздуха от размера места не зависит: прямоугольник вокруг трассы + запас 5 км, а не квадрат 76 км (правка RW-P9). Q3 (1,5 с CPU на игровую с на 3041²) не воспроизводится:
0,21 с на игровую с даже на одном ядре (RW-15, RW-15b тоже его не нашли). Сравнивать с 5 км из t9-xc.md (1407 с игровых, 48 с CPU = 0,034 с/с): на 30 км цена в 6 раз выше за счёт сдвигов окон поля на длинной трассе, но рост ограничен.

## Сборка

`tools/build.sh all --release` включает macOS; Mac-каталог собрался (экспорт с предупреждением «completed with warnings», без расширения). Решения пользователя: macOS не поддерживается — эта ветка `all` излишняя, но не падает.

## Проблемы

1. **`tools/build.sh` зависал навсегда** на `godot --headless --script res://tools/terrain/air_model_hash.gd`: скрипт зовёт `AirBakedField.code_hash_of_sources`, которого после RW-13 нет (SCRIPT ERROR Nonexistent function), а Godot после ошибки в `_initialize` не выходит. Вывод `|| true` не помогает — процесс не завершается. Обход: обёртка `godot` в PATH, пропускающая этот скрипт. Исправлено отдельной задачей RW-23 (влита после моего прогона; повторный полный прогон без обхода не делал).
2. **`addons/dp_air/smoke.gd` устарел**: `API_VERSION := 4`, расширение отдаёт 6 -> `DP_AIR_SMOKE FAIL: api_version = 6, ожидалось 4` (и в Linux, и под wine). `tools/dp_air_smoke.sh` поэтому падает; ветер у земли != 0 этой сценой не проверен. Править `addons/` вне моего скоупа.
3. **Игра не пишет в журнал ни фазу полёта, ни скорость ветра**. «Фаза flying» подтверждена косвенно (`--air-start` = сразу flying, 20 игровых с без ошибок, кадр снят), «ветер != 0» — косвенно (`dp_air: READY ... поле подано`, field_version > 0; в URL мира `wind=2.0`). Число ветра мог бы дать обновлённый smoke.tscn (проблема 2) или строка в журнале.
4. **Первый `--import` и экспорт Linux-release шумят** `Can't open dynamic library ... libdp_air_tune.so`: `build.sh all --release` собирает только release, а редактор берёт ключ debug (tune). Экспорт не ломается (в pck кладётся .gdextension; в экспортированной игре release работает).
5. `lock cpu` одной задачей `RW-21a` ждал в очереди ~15 мин за бенчем RW-19 (полная машина, 18 слотов); не проблема игры.
6. dpcli: процессы из `.dpcli/dpcli job start` и `nohup` в моей сессии могли оставаться висеть (зависший air_model_hash.gd, 3 штуки), пришлось убивать вручную.

## Границы

* Wine READY 45,9 с против 7,7 с на Linux: прогон шёл при параллельной нагрузке (T9 и чужие приёмки), wine добавляет накладные расходы; отдельно скорость dll не мерилась. Если это не шум, DLL (x86-64 baseline, mingw) заметно медленнее — проверить на тихой машине.
* T9 30 км — синтетика (плоская земля, статические термики, без ветра); реальное место и ветер не мерились. Один сид.
* Время T9 под CPUQuota=100% (одно ядро) — верхняя оценка; на полной машине быстрее.
* Smoke — одно место (`training_island`, старт `thermal_plain`), без ботов, 20 игровых с.
* Сборка проверена на коммите до sync с RW-23 (27eacfa содержит только его правки поверх проверенного).
