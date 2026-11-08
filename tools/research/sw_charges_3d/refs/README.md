---
type: "research"
status: "active"
module: "sw-charges-3d"
updated: "2026-11-08"
summary: "SWD-1: эталоны 3D — поля Пикара (air3d, Б1 nom/adv1) для Askervein и Perdigão NE/SW, мачты и точки по типам, ротор (SWD1)."
related: ["docs/plan/sw-charges-3d.md", "docs/contracts/sw-charges-3d.md", "tools/research/cases/b1/README.md", "tools/research/cases/README.md"]
conclusion: "tools/research/sw_charges_3d/refs/summary.md"
data: "tools/research/sw_charges_3d/out/refs/"
applied_in: ""
---
# refs: эталоны 3D (SWD-1)

Формат — SWD1 v1 (`docs/contracts/sw-charges-3d.md`). Решатель (`tools/research/air3d`) и модули случаев (`tools/research/cases`) не менялись: импортируются, прогоны — как `cases/b1/ctl.py` (`run_one(..., keep=True)`, nom: схема 2-го порядка; adv1: `ctl={'adv2': False}`, 1-й порядок — схема игры).

## Файлы
| Файл | Что |
|---|---|
| `points.py` | определения: растр рельефа, мачты, опорная точка, классификация по типам, синтетические положения, разрезы |
| `make_refs.py` | `run` — 6 прогонов Пикара → `out/refs/<case>.h5` + кэш значений в точках и ротора (`out/refs/_cache/`); `assemble` → `points.json`, `points.csv` |
| `tables.py` | справочная сводка Пикар против мачт → `out/refs/tables.md`, `tables.json` |
| `summary.md` | вывод |

## Воспроизведение
```bash
cd tools/research/sw_charges_3d
# venv ./py: numpy, scipy, h5py, cupy, matplotlib + brotli (air3d/terrain.py импортирует brotli; в requirements.txt его нет — доставлен вручную)
.dpcli/dpcli job start swd1-refs 3600 ./py -I refs/make_refs.py run      # 6 прогонов, ~1,5 мин на RTX 4070 SUPER (GPU-замок cases — свой файловый /tmp/heat_ca_gpu.lock)
./py -I refs/make_refs.py assemble && ./py -I refs/tables.py
./py contract/check_contract.py files out/refs                            # OK для 3 h5 и points.json
```
Прогоны: dx номинала (Askervein 20 м, Perdigão 30 м), 4,2 и 4,7 млн клеток, статус `ok` во всех шести (101/91, 211/161, 191/171 внешних итераций). dx/2 не берётся (не влезает в 12 ГБ — `cases/b1/README.md`).

## Что в файлах
- `<case>.h5` (`ASK_TU03B`, `PERD_NE`, `PERD_SW`; 3,4 + 5,0 + 5,0 МБ): `terrain` (растр 10 м до блочного осреднения; Askervein 400×400 асл; Perdigão 600×600 асл = DSM + 0,7·h_c × доля леса; `z0` Perdigão — по доле леса клетки, в прогоне Пикара — скаляр из `perdigao.z0_nominal()`), `picard_nom`, `picard_adv1` (клетки 200×200; все 11 уровней z_agl 2…300 м; int16, шаг 0,002 м/с, ошибка ≤ 0,001 м/с). `z_ground` Perdigão — асл (hc + BASE 100 м). Боковая губка Пикара (Askervein 700 м, Perdigão 1050 м) в полях не маскирована — граница в `params.sponge_side_m`.
- `points.json/.csv`: 546 строк (мачты 69 + 28 + 25; для каждой — строка Пикара nom и adv1 в той же точке; синтетические точки `P_<тип>_0` типов upstream/windward/crest/lee/valley на z_agl 10, 20, 50, 100, 200, 300 м), `norm`, 18 разрезов, 43 строки ротора.

## Допущения и правила (проверять при чтении)
1. **Опорные точки (`norm`).** Askervein — RS, 10 м, 8,895 м/с (данные). Perdigão — мачта гребня наветренной гряды 100 м, как в `perdigao.py` (`ref`): NE — `tse13`, SW — `tse04` (выбор не мой: на ней в модуле случая калибруется U10, поэтому s_norm Пикара на ней = 1 по построению масштаба; U100 окна — данные). Для Пикара `s_norm` — к скорости Пикара в той же опорной точке.
2. **Askervein `dS`.** При H = 10 м — опубликованный FSR из `askervein_validation1.txt` (он считан относительно RS своего прогона и отличается от S/8,895 − 1 до 0,06 на отдельных точках, в среднем 0,002); при других H — S/S_RS(H) − 1 по строкам RS файла, нет RS на этом H — null. `ref_err` = max(FSRmin, FSRmax)/(1 + FSR) (в файле это ±погрешность FSR, не границы); -999 → null. `s_norm` мачт — S/8,895 по контракту (поэтому s_norm и 1 + dS у мачт могут расходиться на ту же 0,06). Строки H < 2 м (HT cups 1 м) не взяты.
3. **Perdigão мачты.** Окна-средние `data/perdigao/cases/*_windowmean.csv` (NE 17–19 UTC 2017-04-27, SW 10–11 UTC 2017-05-11), уровни ≥ 30 м (ниже — в пологе, как `perdigao.MIN_Z_TOWER`), n_5min ≥ 6. u, v — из `spd` и `dir_deg` (допущение: `spd` ≈ модуль среднего вектора; разница с векторным средним не оценивалась), w — столбец `w`. `ref_err` = √(σ_5мин² + (0,10·r)² + 0,03²)/r, r = s_norm (SIG_REP, SIG_FLOOR из `perdigao.py`; σ_5мин — разброс отношения по 5-мин окнам). Положение мачты — в 2D-проекте было «привязка к линии»; здесь мачты берутся в их положении, смещение от линии гребней (поперёк ветра) — в `ref_source`.
4. **Типы точек.** Perdigão — по положению вдоль ветра s относительно двух гребней и дна на линии мачт (`t_line` −100 NE / +130 SW, сглаживание σ 40 м, заметность ≥ 60 м, как panels_exp): upstream s < c1 − 600; windward c1 − 600…c1 − 150 и дно…c2 − 150 (склон второй гряды); crest ±150 м от c1/c2; lee c1 + 150…дно − 150 и после c2 − 150; valley дно ± 150. Askervein — по высоте над RS в долях (HT − RS): ≥ 0,85 crest; ниже и до вершины по ветру windward (h > 0,12) или upstream; после — lee (h > 0,12) или valley. Это эвристики; в Askervein «valley» — только низкая земля с подветренной стороны (в областях 4 км долины нет); границы типов не проверялись на картах.
5. **Синтетические точки** — на линии вдоль ветра через вершину HT (Askervein) / через гребень c1 по `t_line` (Perdigão): upstream 1500 м до гребня; windward — полувысота наветренного склона; crest; lee — полувысота подветренного; valley — минимум (Perdigão: дно между гребнями; Askervein: минимум на линии до границы внутренности области — всего ≈ 400 м вниз по ветру от HT, у границы боковой губки: **подветренная часть Askervein в области мала**). Все точки внутри области без боковой губки (проверено `in_box`).
6. **Значения Пикара в точках** — `perdigao.sample` (билинейно по столбцам Пикара, линейно по z над землёй Пикара, `surface_at`), ниже 1·dz над землёй — значение первой клетки (`ref_source` помечает такие точки; для Perdigão это z_agl < 15 м, для Askervein < 10 м). В h5 — те же значения по `synth.agl` на центрах клеток (расхождение с точечным — интерполяция по x, y).
7. **Ротор.** Критерий — как SWD5: u∥ < −0,5 м/с на z_agl 15 м, самый длинный участок > 50 м вдоль разреза (шаг 10 м); глубина — наибольший z_agl (шаг 15 м) связной области u∥ < −0,5 м/с. У Menke 2019 критерий другой (≥ 15 м слепая зона, условная статистика по периодам с рециркуляцией) — сравнение приблизительное. Разрезы Perdigão `sec−500/+0/+500` — линии вдоль ветра через центр области со сдвигами вдоль гряды (как `perdigao.zone_metrics`); `menke_T1–T3` — **условно** те же линии: положение лидара WS105 в данных не задано, нумерацию T1–T3 со сдвигами сопоставить нельзя. L Menke по разрезам — `menke2019/fig8_zones_approx.csv` (приближение по рисунку, ±50 м), для SW-случая направление «SW», для NE — «NE»; глубина 157 м — среднее, по разрезам не дано. Строки `masts` у Askervein — `present = null` (измерений обратного течения нет).

## Данные и лицензии
- Askervein: Zenodo 4095052 (CC BY 4.0), Taylor & Teunissen 1987, Boundary-Layer Meteorol. 39:15–39 — `tools/research/data/askervein/`.
- Perdigão: ISFS NCAR/EOL doi:10.26023/ZDMJ-D1TY-FG14; Menke et al. 2019, ACP 19, 2713 (CC BY 4.0); рельеф Copernicus GLO-30 (производные в `cases/perdigao/out/terrain10.npz`); лес ESA WorldCover 2021 (CC BY 4.0) — `tools/research/data/perdigao/README.md`, `tools/research/cases/perdigao/README.md`, `ASSETS.md`.
- Новых внешних данных не скачивалось; `out/refs/*.h5` — производные от перечисленного (условия те же).
