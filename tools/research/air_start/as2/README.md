# AS-2: болтанка и разворот ветра у земли (поле GPU) — замеры

Модель — `docs/air_model.md` → «Масштаб 3: возмущения из поля» (законы «Механическая болтанка»,
«Сложение механики и конвекции», «Масштаб конвективной горизонтали», «Перенос вихрей у земли»;
таблица «У старта, 1,5 м над землёй»). Регрессионный тест — `tests/atmosphere/test_start_air_gpu.gd`.

| Файл | Что |
|---|---|
| `probe_test_as2probe.gd.txt` | зонд: сцена игры (`main.tscn → _fly`), старт, ветер меню встречный; в точке 1,5 м над стартом — разбор по членам (`_decomp.jsonl`: u* столбца и в точке, σ механики/конвекции/слоя смешения, признак отрыва, обратный поток, профиль среднего 1,5–100 м, уклон), ряд 20 с в неподвижной точке (`_fixed.csv`) и как зонд CF-1 — крыло стоит 20 с (`_idle.csv`) |
| `run_probe.sh <метка> [каталог]` | прогон зонда (копирует в `tests/game/test_as2probe.gd`, окно, `flock /tmp/heat_ca_gpu.lock`), по умолчанию 4 старта × 3 и 6 м/с × сиды 0/1500/3000 → `~/as2out` |
| `summary.py <каталог> <метка…>` | таблицы: модель против подобия приземного слоя, ряды, разбор по членам → `<метка>_summary.csv` |
| `sl_table.gd` + `.tscn` | headless: синтетическое поле (ровно, лог-профиль), 1,5–300 м, нейтраль/устойчиво/конвекция, 600 с в точке — σ_u, σ_v, σ_w, σθ, max|θ| и max|ΔU| по 20-с окнам, время корреляции |
| `plot_series.py` | ряды до/после → `/home/greg/deltaplan/build/screenshots/AS-2/` |
| `data/` | `before_*` — 78580e5 (= 1.0.0 по полю у старта), `after1_*` — после AS-2 (до AS-1); `sl_*.jsonl`; всё сырьё — `probe_before_after1.tar.gz` |

Воспроизвести (из корня копии):
```
tools/research/air_start/as2/run_probe.sh after ~/as2out
python3 tools/research/air_start/as2/summary.py ~/as2out after
XDG_DATA_HOME=$(mktemp -d) godot --headless --path . res://tools/research/air_start/as2/sl_table.tscn -- --out=$HOME/as2out/sl_after.jsonl
/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python tools/research/air_start/as2/plot_series.py ~/as2out before after /home/greg/deltaplan/build/screenshots/AS-2
flock /tmp/heat_ca_gpu.lock tools/gpu_tests.sh --filter=start_air_gpu
```
Зонд «до» на старом коде: `sigma()` там без `u_pt` — в `.gd.txt` ветка `has_method("taylor_stretch")`
выбирает вызов, но ссылка `FieldTurbulence.taylor_stretch` не разберётся на старом коде — убрать строку
`out["stretch"]` перед прогоном.
