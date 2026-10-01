# CF-1: замеры старта (данные исследования)

- `probe_test_cf1probe.gd.txt` — зонд: копировать в `tests/game/test_cf1probe.gd` нужной версии и запускать
  `CF1_OUT=<каталог> CF1_TAG=<метка> [CF1_CASES=крыло:км/ч,...] [CF1_SCENS=idle,run_neutral,...] [CF1_SEEDS=0,1500] [CF1_POST=с] XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tests/run_tests.tscn -- --filter=cf1probe`
  (поле воздуха GPU — то же через окно: `tools/gpu_tests.sh --filter=cf1probe`). Сцена игры (`main.tscn` → `_fly`), без ввода / разбег через InputMap, CSV по 0,1 с.
- `bisect.sh`, `sweep.sh`, `gpubisect.sh` — пачки по версиям (временные копии `~/deltaplan-cf1-bisect-<коммит>`), `summary.py` — сводка.
- `data_bisect1.tar.gz` — CSV первой серии (по умолчанию; крылья training/sport/combat × 3/5/7 м/с × сиды 0/1500/3000; headless и GPU).
