---
type: "contract"
status: "active"
module: "live-menu"
area: "game"
updated: "2026-10-17"
summary: "Живое меню: метрики и формат замера старта игры (LM-K1); стык меню с миром за ним — после шлюза Q1."
related: ["docs/plan/live-menu.md", "docs/guide/game/menus-settings.md"]
contracts: [{"id": "LM-K1", "version": 1}]
---
# Контракты модуля live-menu

## LM-K1 v1 — замер старта игры
Владелец — LM-1. Потребители — шлюз Q1, повторный замер в конце модуля (та же методика, тот же скрипт).

**Условия.** Собранная игра (`tools/build.sh linux --release` в копии задачи, `build/linux/deltaplan.x86_64`), настоящий дисплей
`DISPLAY=:0`, 1920×1080, `--audio-driver Dummy`. Один временный профиль на серию (`XDG_DATA_HOME` и дисковые кеши шейдеров
драйвера — `mktemp -d`, как в `tools/bench/startup_bench.sh`): прогон 1 — холодный, прогоны 2–3 — тёплые. Варианты: `main`
(статичный фон, как сейчас) и `proto` (живое меню, флаг `--live-menu-proto`). Окно меню — 40 с без ввода, затем «Лететь» на место по
умолчанию (`--perf` продолжает замер полёта как сейчас).

**Строки вывода** (stdout, по одной на прогон; `unix` — `Time.get_unix_time_from_system()`, секунды):
- `PERF menu_ms=<int> unix=<float>` — меню на экране и принимает ввод (уже есть, `scenes/main.gd:_perf`);
- `PERF menu_window s=<int> frames=<int> median_ms=<int> worst_ms=<int> hitches=<int> total_ms=<int>` — кадры за окно меню,
  рывок — кадр > 50 мс; `total_ms` — сумма рывков;
- `PERF menu_world_ready unix=<float> baked=<0|1>` — только `proto`: бот в воздухе в кадре; `baked=1` — поле воздуха взято
  запечённым (`air/<site>.*`), а не посчитано;
- `PERF fly_ms=…`, `PERF hitches=…` — как сейчас (полёт после «Лететь»).

**Итог** — `tools/research/live_menu/startup.json` (запись во временный файл и переименование):
```json
{"version": 1, "build": "<git short hash>", "display": "1920x1080",
 "runs": [{"variant": "main|proto", "run": 1, "kind": "cold|warm",
           "menu_s": 0.0,            // от запуска процесса до PERF menu_ms (по unix), с
           "menu_frames": 0, "menu_median_ms": 0, "menu_worst_ms": 0, "menu_hitches": 0, "menu_hitch_total_ms": 0,
           "world_ready_s": null,    // от запуска процесса до menu_world_ready, с; null у main
           "baked": null,            // true|false у proto, null у main
           "fly_ms": 0, "fly_worst_ms": 0, "fly_hitches": 0}]}
```
Нет строки в выводе — поле `null`, прогон не выбрасывается. Сводная таблица (медиана тёплых, холодный отдельно) —
`tools/research/live_menu/README.md`.

**Контрактная проверка** — `python3 tools/research/live_menu/check_startup_json.py tools/research/live_menu/startup.json`:
код 0, если все поля на месте и типы верны, есть ≥ 3 прогона каждого варианта (1 холодный).
