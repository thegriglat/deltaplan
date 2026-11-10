# lee_turb/flight — полёт за гребнем (LT-14)

Автопилот игры (`scenes/main.tscn`, «Маятник», воздух dp-air с полем Пикара) летит по ветру через гребень Онгудая
(линия разреза a50_focus стенда LT-2) и за ним; сравниваются прежний код (7665fb7) и LTM v1 (эта ветка).
Описание, таблицы и выводы — `docs/research/lee_turb/flight.md`.

| файл | что |
|---|---|
| `lee_pass.gd/.tscn` | сцена-замер: проходы и строки ячеек (headless) или время кадра (`--frame=1`, окно) |
| `run.sh` | `fly`/`frame`/`merge`; код `old` — отдельная копия, `new` — эта |
| `merge.py` | `out/raw/*.csv` → `out/flights.csv`, `out/frame_time.csv` |
| `out/flights.csv`, `out/frame_time.csv`, `out/summary.md` | результаты (в git); `out/raw/` — локально |

## Столбцы flights.csv
`code` (old|new), `height_rel_crest_m` (заданная высота ячейки над гребнем), `x_over_h` (заданное удаление, в H = 255,2 м),
`seed` (сид мира: термики, порывы), `rep` (повтор прохода в том же процессе, момент позже), `n` (отсчётов в ячейке, 120 Гц),
`landed` (1 — проход прерван у земли/посадкой), `air_unready_frames` (кадров с неготовым воздухом),
`mean_wind_ms` (средний ветер в ячейке), `mean_h_rel_crest_m`, `mean_x_over_h`, `mean_agl_m`, `mean_tas_ms` (фактические),
`sigma_u_ms`, `sigma_v_ms`, `sigma_w_ms` (σ ветра на крыле, `air.sample` полный, оси среднего ветра ячейки, после линейного
тренда), `az_max_abs_ms2`, `az_sigma_ms2` (вертикальное ускорение крыла, разность скорости за 0,1 с), `n_sigma` (σ перегрузки),
`roll_sigma_deg`, `pitch_sigma_deg` (σ крена и тангажа), `frac_dw_gt2` (доля времени, когда |w(t) − w(t − 1 с)| > 2 м/с),
`sigma_model_mean_ms` (σ поля модели `sample.w`, среднее), `sigma_turb_term_mean_ms` (σ слагаемого `turb`, среднее).
Пустые столбцы — в ячейке < 1 с отсчётов.

## Воспроизведение (из корня копии задачи)
```bash
git worktree add --detach <каталог> 7665fb7 && (cd <каталог> && tools/build_rust.sh release linux)   # прежний код
cp addons/dp_air/bin/libdp_air_release.so addons/dp_air/bin/libdp_air_tune.so     # в обеих копиях (редактор берёт tune)
# профиль Godot (место ongudai) — ~/.cache/dp-xdg/<имя копии>/Deltaplan/locations
.dpcli/dpcli lock cpu lt14 -- tools/research/lee_turb/flight/run.sh fly new . 1
.dpcli/dpcli lock cpu lt14 -- tools/research/lee_turb/flight/run.sh fly old <каталог> 1
.dpcli/dpcli lock gpu lt14fps -- tools/research/lee_turb/flight/run.sh frame new . 1
tools/research/lee_turb/flight/run.sh merge
```
