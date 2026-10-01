# SP-1: пересчёт поля ветра в полёте — замеры и прототипы

Задача SP-1 модуля air-speed (`docs/plan/air-speed.md`): куда уходит стена пересчёта среднего поля в полёте
(`AirRuntime`, C9 v2), что можно сделать, цена для кадра и AMD; можно ли локальный RenderingDevice в рабочем
потоке в Godot 4.7.2; оценка этапа загрузки одним проходом на RX 5600 XT. Код игры не менялся — только
инструменты здесь. Итог и рекомендация — в отчёте SP-1 координатору (журнал модуля `docs/plan/air-speed_progress.md`).

Машина замеров: RTX 4070 SUPER (драйвер 550.163.01, Vulkan 1.3.277), Xeon E5-2666 v3 (Haswell, 10 ядер),
Linux X11, монитор 75 Гц, VSync вкл. Все GPU-замеры — под `flock /tmp/heat_ca_gpu.lock` (GPU общий с другими
агентами; занятость до/после — `out/*.gpu.txt`: в наших прогонах 4–8 %, только рабочий стол).

## Инструменты

| Файл | Что |
|---|---|
| `rd_thread_probe.gd/.tscn` | (а) локальный RD в `Thread` / `WorkerThreadPool` / между потоками; решатель области целиком в потоке против главного (`run_blocking`, `poll()` раз в кадр), побитная сверка; (б) общий RD — цепочка запусков внутри кадра |
| `gpu_thread_probe.gd/.tscn` | (а) постоянный «поток GPU»: свой RD на всю жизнь потока, задачи по очереди (холодная + 3 тёплых, час +15 мин), рывки кадров главного потока; A7 — запись команды после `submit()` до `sync()` |
| `dispatch_probe.gd/.tscn` | (г) цена запуска ядра с барьером и без (GPU-метки): 64 потока, 500 тыс. и 2 млн элементов |
| `flight_probe.gd/.tscn` | разбивка пересчёта в настоящей игре: меню → полёт (Онгудай 12:00, 3 м/с со 150°) → 3 пересчёта по сроку (+15 мин, тёплый старт); по кадрам этап `AirRuntime`, время главного потока, метки порций, отрисовка кадра (GPU); варианты `base`, `slice<мс>` (порции подряд с sync в том же кадре), `gapoff`, `thread<мс>` (прототип: решатель в своём потоке во время игры); затем `AirThermals.build` в главном и в рабочем потоке |
| `run_flight.sh` | пачка `flight_probe` под одним замком (продолжение с места) |
| `analyze.py` | таблицы `out/breakdown.md/.json`, графики `out/fig_timeline_*.png` |

## Воспроизведение
```bash
cd ~/deltaplan-air-speed-sp1      # или любая копия с этой папкой
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import          # первый раз
G="godot --path . --audio-driver Dummy --resolution 320x240"
XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock $G res://tools/research/air_speed/rd_thread_probe.tscn \
  > tools/research/air_speed/out/rd_thread.log 2>&1
XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock $G res://tools/research/air_speed/dispatch_probe.tscn \
  > tools/research/air_speed/out/dispatch.log 2>&1
XDG_DATA_HOME=$(mktemp -d) flock -w 1800 /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy --resolution 1280x720 \
  res://tools/research/air_speed/gpu_thread_probe.tscn > tools/research/air_speed/out/gpu_thread.log 2>&1
tools/research/air_speed/run_flight.sh      # 5 вариантов в окне игры как есть (развёрнуто, 1918×1036)
tools/research/air_speed/run_flight.sh w_base_1280:base:1280x720 w_base_320:base:320x240 \
  w_slice16_1280:slice16:1280x720 w_thread8_1280:thread8:1280x720 w_thread24_1280:thread24:1280x720 \
  w_thread8_320:thread8:320x240
/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python tools/research/air_speed/analyze.py
```
Godot с окном переписывает `project.godot` — скрипты возвращают его (не коммитить). Прогон игры ~1–2 мин на
вариант. `--resolution` игра не держит (окно развёрнуто по настройкам) — размер окна задаёт `--win=WxH`
(`flight_probe`, после входа в полёт); прогоны `flight_max_*` — развёрнутое окно 1918×1036, `w_*` — заданное.

## Данные (`out/`)
- `rd_thread.json/.log` — (а), (б): строки A1–A5, B1 (лог — с ошибками движка для A3/A4);
- `gpu_thread.json/.log` — постоянный поток GPU: задачи, события потока, все кадры;
- `dispatch.json/.log` — цена запуска;
- `flight_max_*.json/.log/.gpu.txt`, `w_*.json/.log/.gpu.txt` — прогоны игры (кадры, порции, задачи, термики);
- `breakdown.md/.json` — сводные таблицы; `fig_timeline_*.png` — этапы и кадры второго пересчёта прогона;
  `fig_tradeoff.png` — стена решения области против среднего кадра по вариантам.

Важно: окна 1280×720 / 320×240 задать не удалось — игра разворачивает окно по своим настройкам, а вьюпорт
остаётся 1918×1036 (`env.viewport` в json), поэтому все «полётные» числа сняты при отрисовке 1918×1036.
Отрисовка полёта стоит 15–40 мс GPU на кадр; в окне тестов — ~0,1 мс.

## Источники (публичные числа карт и процессоров)
- RX 5600 XT: 2304 потоковых процессора, 7,18 TFLOPS FP32 (буст 1560 МГц), 6 ГБ GDDR6 192 бит, 288 ГБ/с
  (12 Гбит/с; карты с BIOS 14 Гбит/с — 336 ГБ/с), L2 3 МБ —
  [TechSpot](https://www.techspot.com/specs/gpu/213636-amd-radeon-rx-5600-xt.html),
  [videocardz](https://videocardz.com/amd/radeon-rx-5000/radeon-rx-5600-xt).
- RTX 4070 SUPER: 7168 CUDA, 35,5 TFLOPS FP32, 504 ГБ/с, L2 48 МБ —
  [TechSpot](https://www.techspot.com/specs/gpu/289555-nvidia-geforce-rtx-4070-super.html),
  [videocardz](https://videocardz.com/nvidia/geforce-40/geforce-rtx-4070-super).
- PassMark single thread: Xeon E5-2666 v3 — 1956, Ryzen 5 4500 — 2584 (×1,32) —
  [cpubenchmark.net](https://www.cpubenchmark.net/cpu.php?cpu=Intel+Xeon+E5-2666+v3+%40+2.90GHz&id=2471),
  [singleThread](https://www.cpubenchmark.net/singleThread.html).
- Порог «не отвечает» Windows ~5 с без обработки сообщений окна — из задания (Microsoft: «Preventing Hangs in
  Windows Applications», `IsHungAppWindow` — 5 с).

Лицензии: данные — собственные замеры (как весь проект); внешних данных нет, только числа со ссылками.
