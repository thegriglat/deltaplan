---
type: "research"
status: "active"
module: "lee-turb"
updated: "2026-11-09"
summary: "lee_obs.csv (LTO v1): ТКЭ за гребнем по x/H, z/H — Perdigão NE/SW (ISFS) и Askervein TU03B; Bolund недоступен; σ Perdigão ждут сервера"
related: []
conclusion: ""
data: "tools/research/lee_turb/obs/"
applied_in: ""
---
# Измерения болтанки за гребнем (LTO v1)

Файл `lee_obs.csv` — 152 строки, 92 из них за гребнем (x>0) с ТКЭ. Контракт — `docs/contracts/lee-turb.md`, «LTO v1», проверка
`python3 tools/research/lee_turb/contract/check_contract.py tools/research/lee_turb/obs/lee_obs.csv`. Выводы — `docs/research/lee_turb/obs.md`.

## Что внутри
| site/case | строк | x>0 | что измерено | надёжность |
|---|---|---|---|---|
| perdigao/NE | 59 | 48 | ТКЭ 0.5(u'u'+v'v'+w'w') ультразвуковых анемометров ISFS, среднее 24 пятиминуток (17-19 UTC 2017-04-27), ветер с 61 град через СВ гряду (гребень tse13) | A |
| perdigao/SW | 53 | 38 | то же, 12 пятиминуток (10 UTC 2017-05-11), ветер с 216 град через ЮЗ гряду (гребень tse04) | A |
| askervein/TU03B | 40 | 6 за HT | ТКЭ и (только мачта RS, наветренная) σ_u,σ_v,σ_w,u'w' ; ветер 210 град, x от вершины HT | A (gill/sonic), B (чашки), C |

Все `sigma_*` Perdigão пусты: сервер данных не отвечал (см. ниже). `uw_m2s2`, `L_u_m`, `xr_m`, `x_game`, `z_game` пусты (xr на случай у Menke 2019 не дана — только статистика по 1619 периодам; места стенда строит другая задача).

## Источники, лицензии, цитирование
- Perdigão: ISFS 5-мин, UCAR/NCAR-EOL 2019, doi:10.26023/ZDMJ-D1TY-FG14, v1.1 («Data provided by NCAR/EOL under the sponsorship of the National Science Foundation»); политика проекта — после 12 мес. public domain с цитированием. Раскладка Palma et al. 2018 (NEWA). Подробнее: `tools/research/data/perdigao/README.md`. Входы: `tools/research/data/perdigao/cases/*_windowmean.csv`, координаты и высоты земли — `tools/research/cases/perdigao/out/masts.csv` (Copernicus GLO-30 для DSM; ground_asl из раскладки).
- Askervein: Taylor & Teunissen 1987, BLM 39:15-39; отчёт MSRB-84-6 (1985); цифровая таблица — Zenodo 4095052 (IEA Wind Task 31 Wakebench), CC BY 4.0; `tools/research/data/askervein/`.
- Bolund: Berg et al. 2011 BLM 141:219 и Bechmann et al. 2011 BLM 141:245 (blind comparison, данные DTU). **Не включён**: источник на момент работы отдавал 403 (координатор указал пропустить). Не выдумывал и не оцифровывал по памяти.

## Как отобраны и посчитаны строки (`build_lee_obs.py`)
- Направление «куда дует» = (dir на 100 м наветренной гребневой мачты в окне)+180: NE — tse13 (dir 60.7), SW — tse04 (216.5). x_m — проекция (мачта − гребневая мачта) на эту ось по координатам кадра игры (E,N, та же ориентация, что в PT-TM06; сверено по tse04-tse13: 1142 против 1142 м). Берутся станции с поперечным смещением от оси ≤ 500 м (смещение в `note`); отброшены rne*/rsw01,02,07,08/v01,06,07 и т.п. (список печатает скрипт).
- H_m = высота земли гребневой мачты минус дно долины tse09 (305 м): NE 147.6 м, SW 167.7 м (в Menke 2019 ~200 м от дна до гребня; наши — по мачтам).
- u_ref = U100 (спектр. скорость спд) гребневой мачты за окно: NE 8.79 м/с, SW 8.82 м/с. stab = z/L по tse04 100 м (часы из `screen_all_hours.csv`): NE -0.089 (среднее часов 17, 18), SW -0.14.
- Askervein: x = проекция (станция − HT) на ось 30 град (ветер 210 град, как в TU03B); H=116 м (вершина 126 м над ~10 м), u_ref = S эталонной мачты RS на 10 м (8.895 м/с; это определение TKE* = tke/S_RS² в таблице Zenodo — сверено). Название случая TU03B — по эталону 210 град и S_RS=8.9 м/с (Zenodo-файл имя прогона не называет — **допущение**). Все станции файла с известной ТКЭ; дубли станций (второй блок файла, другая обработка CP gill 10 м: 1.42 против 1.16) оставлены как отдельные строки с суффиксом датчика. Период осреднения в таблице не указан.
- Сводка `summarize.py` -> `summary_tke.json`, `summary_tke.txt`: ТКЭ/U_ref² по ячейкам x/H и z/H.

## Ограничения (кратко; полнее в docs/research/lee_turb/obs.md)
- Один ветровой период на сторону (2 ч и 1 ч), разброс между периодами не оценить; n = число пятиминуток.
- ТКЭ из 5-мин ковариаций не содержит пульсаций периода > 5 мин (на склонах это занижение).
- Мачты Perdigão часто в лесу (10-30 м внутри кроны), ветер в долине на SW-случае развёрнут на 130-170 град, поэтому разрез по одной оси не строгий; станции за x/H>8-9 стоят на следующей гряде.
- Эквивалентное σ_iso = sqrt(2 ТКЭ/3) не σ_w; анизотропию даст только σ по компонентам.

## Воспроизведение
```bash
cd /home/greg/worktrees/deltaplan/lee-turb-LT-3          # или своя копия
python3 tools/research/lee_turb/obs/build_lee_obs.py      # stdlib; пишет lee_obs.csv (и подставляет σ, если есть sigma_perdigao.csv)
python3 tools/research/lee_turb/obs/summarize.py
python3 tools/research/lee_turb/contract/check_contract.py tools/research/lee_turb/obs/lee_obs.csv
```
σ по компонентам Perdigão (отложено: THREDDS windsptds.fe.up.pt давал сбой, проверено 2026-11-09 — curl без ответа):
```bash
python3 tools/research/lee_turb/obs/dl_isfs.py ~/data/lee_turb/isfs5        # 2 файла ~3 МБ, не в git
/home/greg/deltaplan/tools/research/heat_ca/.venv/bin/python -m pip list | grep -i netcdf   # нужен netCDF4+numpy; иначе venv из data/perdigao/scripts
python3 tools/research/lee_turb/obs/sigma_perdigao.py ~/data/lee_turb/isfs5   # -> sigma_perdigao.csv; потом build_lee_obs.py ещё раз
```
`sigma_perdigao.py` проверен только `--selftest` (поворот осей); на реальных NetCDF не запускался, имена переменных (`u_u__<z>m_<мачта>` и т.д.) взяты из `extract_profiles.py`.
