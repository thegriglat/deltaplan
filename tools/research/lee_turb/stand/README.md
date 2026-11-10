---
type: "research"
status: "closed"
module: "lee-turb"
area: "air"
updated: "2026-11-10"
summary: "LT-2: разрезы болтанки за гребнем стендом dp-stand lee (LTS v1), база Онгудая"
related: ["docs/research/lee_turb.md"]
conclusion: ""
data: ""
applied_in: ""
---

# lee_turb/stand — разрезы болтанки за гребнем стендом (LT-2, LTS v1)

Разрезы `dp-stand lee` по Онгудаю (случаи W8 `ongudai_medium|strong|storm`, 6 гребней в окнах поля 50 м, 100 м и в области
400 м), анализ и сборка отчёта `docs/research/lee_turb/baseline.md`. Контракт — `docs/contracts/lee-turb.md` (LTS v1).

| файл | что |
|---|---|
| `ridges.py` → `ridges.json` | гребни Онгудая и линии разрезов (от −2H до +12H по ветру 151°, высоты MSL от минимума рельефа до гребня + 2H) |
| `terrain.py` | рельеф места `tests/fixtures/wind/places/ongudai.{json,bin}` (билинейно, как `ground_height`) |
| `run_baseline.sh` | вся пачка: 3 случая × 6 гребней → `out/<случай>_<гребень>.lts.csv`, `out/times.csv`, контрактный тест |
| `analyze.py` | `out/summary.json`: ветви σ_w, максимумы, отрыв/присоединение по u₁₀, ψ = 0, центр и толщина слоя, relief |
| `tables.py`, `make_baseline.py` | таблицы и сборка `baseline.md` |
| `out/summary.json`, `out/times.csv`, `out/strong_a50_focus.extra.csv` | в git (малые); `out/*.lts.csv` (18 файлов, ≈ 60 МБ) — **локально**, в git не входят |

## Воспроизведение (из корня копии)
```bash
cargo build -q --release --manifest-path rust/Cargo.toml -p dp-stand
.dpcli/dpcli lock cpu lt2 -- sh tools/research/lee_turb/stand/run_baseline.sh   # ≈ 26 мин (решение поля 25–150 с на запуск)
python3 tools/research/lee_turb/stand/analyze.py                                # out/summary.json
python3 tools/research/lee_turb/stand/make_baseline.py                          # docs/research/lee_turb/baseline.md
python3 tools/research/lee_turb/contract/check_contract.py tools/research/lee_turb/stand/out/*.lts.csv
# диагностика relief/lee аналитики (вне контракта), один разрез:
rust/target/release/dp-stand lee --case tests/fixtures/wind/cases/ongudai_strong.json --model formula --time 0 \
  --from 7446.1,723.1 --to 5713.7,-2402.2 --ys 1540,2390 --step 10 --timeout 900 --extra /tmp/extra.csv > /tmp/x.lts.csv
```
Python: системный `python3` с numpy (2.2.4), отдельного venv нет. Прогон детерминирован: повторный запуск даёт тот же csv побайтно.

## Источники и лицензии данных
- Рельеф Онгудая — растр места `tests/fixtures/wind/places/ongudai` (высоты Copernicus DEM GLO-30, 25 м): лицензия Copernicus DEM,
  см. `ASSETS.md` (строка `user://locations/ongudai/*`) и `licenses/copernicus-dem.txt`.
- Случаи `tests/fixtures/wind/cases/ongudai_*.json` — наши (W8); разрезы — производные модели игры.
- Формулы моделей (Bell & Mehta 1990; Pope 2000, §5.4 — коэффициенты 0,18/0,14 ΔU) — по коду `rust/dp-air/src/terms/turb`.
