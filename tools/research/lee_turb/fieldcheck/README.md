---
type: "research"
status: "closed"
module: "lee-turb"
area: "air"
updated: "2026-11-10"
summary: "LT-8: сверка болтанки за гребнем на поле игры (Perdigão, Askervein), прежняя и новая модель"
related: ["docs/research/lee_turb.md"]
conclusion: ""
data: ""
applied_in: ""
---

# LT-8: сверка на поле игры (Perdigão, Askervein) — прежняя / новая модель, поле (а) и (б)

Стенд `dp-stand lee` (LTS v1) считает разрезы болтанки на поле игры; прототип модели слоя LT-7 (`../model/proto.py`) применяется к этим же разрезам
(центр слоя по z½ поля) и сравнивается с мачтами LTO. Вывод и числа — `docs/research/lee_turb/fieldcheck.md`.

| файл | что |
|---|---|
| `lines.py` → `out/lines.json` | линии разрезов по ветру случая через станции (кластеры по смещению поперёк ≤ 250 м цепочкой), границы вдоль: от −2H (или 100 м до первой станции) до +14H (или 100 м за последней), высоты MSL от (низшая станция − 60 м) до гребень + 2H, шаг 10 м |
| `run.py` | пачка `dp-stand lee`: `run.py <a\|b> <dp-stand> <корень с configs>` → `~/data/lee_turb/lts_fieldcheck/<a\|b>_<случай>[_Lxx].lts.csv` (линия опорной станции — без суффикса), `times_<a\|b>.csv`, `*.stderr` |
| `analyze.py` | `out/mast_compare.csv` (LT-8), `out/fieldcheck.json` (пузырь, центр слоя, RMSE, максимумы, время) |
| `out/` | таблица и json (малые, в git) |

Поля: **а** — копия `feature/lee-turb` (в ней outflow-bc из main, срезанных клеток нет); **б** — `feature/picard-terrain` (срезанные клетки PT2 по умолчанию; outflow-bc нет) + стенд `lee.rs` и данные
исследования из `feature/lee-turb`, `main.rs`/`setup.rs` стенда сведены вручную (в отдельной отсоединённой копии вне репозитория задачи, без коммитов; код picard-terrain, dp-air, picard_rs не менялся).

## Воспроизведение (из корня копии; ~3 мин на разрез, 20 разрезов на поле)
```bash
cargo build -q --release --manifest-path rust/Cargo.toml -p dp-stand                       # поле а
.dpcli/dpcli lock cpu lt8 -- python3 tools/research/lee_turb/fieldcheck/lines.py
.dpcli/dpcli lock cpu lt8a -- python3 tools/research/lee_turb/fieldcheck/run.py a $PWD/rust/target/release/dp-stand $PWD
# поле б: git worktree add --detach <tmp>/lt8-pt feature/picard-terrain; в ней
#   git checkout feature/lee-turb -- rust/dp-stand/src/lee.rs tools/research/lee_turb ; свести rust/dp-stand/src/{main,setup,lib}.rs и README (Cmd::Lee + mod timing)
#   CARGO_TARGET_DIR=<tmp>/t cargo build -q --release -p dp-stand ; run.py b <tmp>/t/release/dp-stand <tmp>/lt8-pt
python3 -W ignore -I tools/research/lee_turb/fieldcheck/analyze.py
python3 tools/research/lee_turb/contract/check_contract.py ~/data/lee_turb/lts_fieldcheck/*.lts.csv
```
Места и случаи — `../places/` (растры вне git, `~/data/lee_turb/places/`). Измерения — `../obs/lee_obs.csv`. Разрезы `*.lts.csv` (≈ 40 файлов, 3–6 МБ) — вне git.
Лицензии данных: Perdigão — NCAR/EOL ISFS (doi 10.26023/ZDMJ-D1TY-FG14), Askervein — отчёт Taylor & Teunissen 1983/87 (`../../data/*/README.md`), рельеф игры — Copernicus GLO-30 (см. `ASSETS.md`).
