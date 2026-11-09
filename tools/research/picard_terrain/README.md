---
type: "research"
status: "active"
module: "picard-terrain"
updated: "2026-11-09"
summary: "picard-terrain: срезанные клетки и ограниченный 2-й порядок в picard_rs на той же сетке — случаи, прогоны, таблицы."
related: ["docs/plan/picard-terrain.md", "docs/contracts/picard-terrain.md", "rust/picard_rs/README.md", "tools/research/air3d/reference.md"]
conclusion: ""
data: "tools/research/picard_terrain/out/; крупное — $PICARD_TERRAIN_DATA (~/data/picard_terrain)"
applied_in: ""
---
# picard_terrain — мелкий рельеф в Пикаре

Контракты — `docs/contracts/picard-terrain.md` (PT1–PT5). Контрактный тест:
`python3 contract/check_contract.py selftest | cases <case.json>… | rows <rows.jsonl>…`;
побитно прежний путь `picard_rs` без флагов — `contract/check_default.sh` (`identical=4/4`).

| Путь | Что | Задача |
|---|---|---|
| `contract/` | контрактный тест, проверка побитности | координатор |
| `make_cases.py`, `sample.py` | случаи PT1, выборка PT5 | PT-1 |
| `out/<ID>/` | строки замеров PT4 (`rows.jsonl`), таблицы, команды воспроизведения | все |

Крупные данные (случаи R1, снимки R4, растры) — `$PICARD_TERRAIN_DATA` (по умолчанию `~/data/picard_terrain`).

## PT-1: случаи опыта, выборка, база (`out/PT-1/`)

Воспроизведение (из корня копии; `PY=tools/research/sw_charges_3d/py` — venv с numpy/scipy/h5py/cupy/Pillow/matplotlib):

```bash
cargo build --release --manifest-path rust/picard_rs/Cargo.toml
$PY tools/research/picard_terrain/make_cases.py          # 9 случаев + растры + решение air3d -> $D/{cases,terrain,states}, out/PT-1/air3d_runs
$PY tools/research/picard_terrain/run_base.py solve      # picard solve 6 баз под замком cpu -> out/PT-1/r2, $D/states/*_base
$PY tools/research/picard_terrain/run_base.py rows       # out/PT-1/rows.jsonl
$PY tools/research/picard_terrain/run_base.py table      # out/PT-1/table.md
python3 tools/research/picard_terrain/contract/check_contract.py cases $D/cases/*.json
python3 tools/research/picard_terrain/contract/check_contract.py rows tools/research/picard_terrain/out/PT-1/rows.jsonl
$PY tools/research/picard_terrain/sample.py $D/cases/askervein_d100.json $D/states/askervein_d100_base.json   # выборка PT5
```

`D = $PICARD_TERRAIN_DATA` (по умолчанию `~/data/picard_terrain`, ~3 ГБ). Файлы: `cases/<case>.{json,bin}` (PT1),
`terrain/{askervein,kayancha,perdigao}.h5` (растр 30 м), `states/<case>_{base,air3d}.{json,bin}` (R4 v2).

### Постановки и допущения
- **Одна область на site для всех dx**: Askervein — 4 км (x0, y0 как `air3d/askervein.py` при L < 6 км), верх 1000 м (абсолютно, как
  прогон 12,5 м в reference.md §4), `Params(z0 0,03; alpha 0,17; max_profile 2,0; f_cor 1,22e-4; sponge_side 1000 м)`, ветер 210°, U10 8,9 м/с;
  Каянча — 4 км с центром на старте `kayancha_south` (x0, y0 кратны 100 м), потолок — max рельефа области + 1000 м (округл. вверх до 100 м),
  `z_bot` — кратно 100 м, ветер 150°, U10 6 м/с, нейтрально (dθ̄/dz = 0, H = 0), `Params` по умолчанию (z0 0,1; alpha 0,24), губка по бокам 1000 м
  (как у Askervein 4 км; в задании для Каянчи губки не заданы — допущение); Perdigão — `cases/perdigao.grid_and_case(sub, 30)` (правила C10 v2:
  6 км, dx 30, `Params` с калибровкой Б1), `adv2`/`limiter` схемы калибровки заменены на 1-й порядок (база).
- **air3d**: dx >= 30 м — 1-й порядок, float64, решение в `sol_*`; dx <= 25 м — `adv2 = true`, `limiter = 1` (ван Лир), float64,
  решения в `.bin` нет. **Исключение: `askervein_d12p5` — float32** (16,6 млн клеток, float64 не помещается в 12 ГБ GPU: OOM на 10 ГБ);
  в reference.md этот прогон тоже был float32. Критерий: tol_mom 2e-5, tol_th 5e-7, tol_div 1e-6 (проверка раз в 10 итераций).
- **Растр подсетки**: среднее по квадрату 30 м вокруг узла (6x6 точек по 5 м), узлы сдвинуты на −45 м от `x0, y0` сетки (запас по краям).
  Askervein — исходная карта WAsP (треугольная интерполяция; вне карты 0, как в `air3d/askervein.py`: 271 узел в углу ЮЗ, внутри губки);
  Каянча — слой detail игры (25 м, GLO-30) из закоммиченной фикстуры `tests/fixtures/locations/ongudai/detail.webp` (**не** нынешний слой
  пользователя `~/.local/share/Deltaplan/locations/ongudai`: они различаются до 8 м после пересборки сглаживания; нужна воспроизводимость);
  Perdigão — десятиметровое производное `cases/perdigao/out/terrain10.npz` (GLO-30 DSM) в системе сетки: `DSM − 100 м + 12,6 м * доля леса`
  (смещение полога d = 0,7 h_c, как в `perdigao.terrain`); уровень моря = `h + z_offset_m` (атрибут `z_offset_m = 100`). Пары ne/sw — один файл `perdigao.h5`.
- **Perdigão**: `pt.U10 = null` (ветер задан U100 на мачте, U10 = 3,27 / 3,12 — подгонка модели фона, меньше 5 м/с; U100 8,8 м/с в `pt.U_ref`).
  Мачты — `sw_charges_3d/out/refs/points.json` (ref_kind mast), `z_agl` над растром (в строках points.json — над землёй мачты; поправка DSM-земли ≈ 1 м).
- **Выборка PT5** — `sample.py`; правило и ограничения — в строке документации модуля. `ground="model"` — только для сверки с primer (старое правило).

Лицензии данных: Askervein — Taylor & Teunissen 1987 (Zenodo 4095052, см. `tools/research/data/askervein/README.md`); Copernicus GLO-30 (Каянча, Perdigão) —
© DLR e.V. 2010-2014 и © Airbus Defence and Space GmbH 2014-2018 по лицензии COPERNICUS (ЕС/ESA), см. `ASSETS.md`.
