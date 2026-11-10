# LT-12: сверка LTM v1 на поле со срезанными клетками — прежняя против новой

Один набор разрезов LTS v1 (`dp-stand lee --model formula`), два кода на одном поле игры (срезанные клетки PT уже в обоих):

- **old** — стенд на коммите `7665fb7` (main со срезанными клетками и LT-10, до LT-9; временная отсоединённая копия `git worktree add --detach <scratch>/lt12-old 7665fb7`, свой `CARGO_TARGET_DIR`, после прогона `worktree remove`);
- **new** — стенд копии задачи (`feature/lee-turb` на `715328f7d`, LTM v1: `w_sep`, σ_u/ΔU 0,166, слой смешения LT-9).

Места и случаи — `../places/` (Perdigão SW/NE, Askervein TU03B; растры `~/data/lee_turb/places`, вне git), измерения — `../obs/lee_obs.csv`, Онгудай strong — `tests/fixtures/wind/cases/ongudai_strong.json`
и 6 гребней `../stand/ridges.json` (как `run_baseline.sh`). Константы не подбирались.

| файл | что |
|---|---|
| `lines.py` → `out/lines.json` | копия LT-8: линии разрезов по ветру через станции |
| `run.py` | пачка разрезов `run.py <old\|new> <dp-stand> <корень копии>` → `~/data/lee_turb/lts_verify/<code>_<случай>[_Lxx].lts.csv` (Онгудай: `<code>_ongudai_strong_<гребень>`), `times_<code>.csv` |
| `analyze.py` | `out/mast_compare.csv`, `out/ongudai.csv`, `out/verify.json` |
| `w8_points.py` | `out/w8_points.csv`: положение 70 точек W8 вне допуска (LT-9) |
| `make_doc.py` | числа таблиц `docs/research/lee_turb/verify.md` из json |

## Воспроизведение (из корня копии; ≈ 4 мин на разрез, 26 разрезов на код, два кода параллельно ≈ 1,8 ч под `lock cpu`)
```bash
SP=<scratch>; git worktree add --detach $SP/lt12-old 7665fb7
CARGO_TARGET_DIR=$SP/t-old cargo build -q --release --manifest-path $SP/lt12-old/rust/Cargo.toml -p dp-stand
CARGO_TARGET_DIR=$SP/t-new cargo build -q --release --manifest-path rust/Cargo.toml -p dp-stand
python3 -I tools/research/lee_turb/verify/lines.py
.dpcli/dpcli job start --lock cpu lt12run 9000 sh -c "python3 -I tools/research/lee_turb/verify/run.py old $SP/t-old/release/dp-stand $SP/lt12-old & python3 -I tools/research/lee_turb/verify/run.py new $SP/t-new/release/dp-stand $PWD & wait"
python3 -W ignore -I tools/research/lee_turb/verify/analyze.py
# 70 точек W8: LTM_CURRENT=1 CARGO_TARGET_DIR=$SP/t-new cargo test --release -p dp-air --test terms_turb ongudai_sigma_turb_within_w8 -- --nocapture > w8.log 2>&1
python3 -I tools/research/lee_turb/verify/w8_points.py w8.log
python3 -I tools/research/lee_turb/verify/make_doc.py
python3 tools/research/lee_turb/contract/check_contract.py ~/data/lee_turb/lts_verify/*.lts.csv
git worktree remove $SP/lt12-old
```
Разрезы `*.lts.csv` (≈ 52 файла, 1–6 МБ) — вне git.

## Допущения и границы
- «Прежняя» и «новая» ТКЭ — обе из σ стенда: 0,5(σu²+σv²+σw²) в точке станции (интерполяция по x и по высоте над землёй). Станция берётся с ближайшей линии (смещение поперёк до 128 м, как в LT-8).
- Старый стенд печатает `l_u, l_w` с точностью 0,1 м (в LT-9 стало 0,01): нули в спокойном воздухе `run.py` заменяет на 0,05 (только такие значения, высоко над землёй, на сравнение не влияют).
- Стенд не печатает `w_sep` (в LTS v1 его нет): столбец `w_sep` в `mast_compare.csv` пуст; прямой признак снятия стенки — `src` и `du`.
- Заголовок `git=` в LTS обоих кодов один (печатается git каталога запуска): код определяется именем файла и сборкой.
- Поле одно и то же (срезанные клетки, outflow-bc) только по замыслу: код поля в обоих коммитах — picard-terrain; кеши полей раздельные (`~/data/lee_turb/verify_cache/<code>`).
- Корректность за пределами модели: поле в долине Perdigão стоит (LT-8), это сверка не исправляет.

## Источники и лицензии
Perdigão — NCAR/EOL ISFS (doi 10.26023/ZDMJ-D1TY-FG14); Askervein — Taylor & Teunissen 1983/87 (`../../data/*/README.md`); рельеф — Copernicus DEM GLO-30 (`ASSETS.md`); Menke et al. 2019 (QJRMS, Perdigão лидары).
