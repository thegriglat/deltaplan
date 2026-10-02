---
type: "research"
status: "closed"
module: "air-start"
updated: "2026-10-02"
summary: "Воздух у старта (air-start) — данные AS-1 — Жалоба пилота на 1.0.0: при 6 м/с на старте «сдувает»."
related: []
conclusion: ""
data: "tools/research/air_start/"
applied_in: ""
---
# Воздух у старта (air-start) — данные AS-1

Жалоба пилота на 1.0.0: при 6 м/с на старте «сдувает». Причина (WPC-2): ветер меню решатель ставил притоком на
краю области 38,4 км, над стартом на 10 м выходило 1,0–2,1 × меню. AS-1 (решение пользователя): после первого
расчёта поля умножить ветер притока на k = U_меню / U_поля(10 м над стартом) и посчитать ещё раз; класс
устойчивости и z_sat — по ветру меню (`AirRuntime`, контракты C2 v6, C7 v3, C9 v3).

Условия — как WPC-2: 15 июля, 12:00, прогноз по умолчанию (ясно, типичная температура), ветер «в старт»,
болтанка и термики выключены; поле — как в игре (`AirRuntime.load_field`: область 400 м + окна 100/50 м у
старта). U над стартом — `Atmosphere.air_velocity_at` / `mean_wind_at` на высоте над `terrain.height_at`.

## Файлы
- `wind_audit.gd/.tscn/.py`, `wind_audit_run.sh` — копия инструмента WPC-2 (`576550e`,
  `tools/research/wing_physics_check/`) с поправленными путями, колонкой `u_cross_ms` (поперёк ветра, + — к
  правой руке пилота, смотрящего в ветер) и аргументами `--passes`, `--pass-tol` (число проходов подстройки).
- `compare.py` — таблица до/после: U над стартом 1,5/10/50/100/200 м и ÷ меню, направление на 10 м, k, U₁,
  остаток, аналитика рядом, поле/аналитика, время загрузки.
- `passes_probe.gd/.tscn`, `passes_run.sh`, `passes_summary.py` — сходимость по проходам (до 4; проход 2 —
  k·u10/U, дальше секущая по двум последним), время каждого прохода.
- `slow_wind_probe.gd/.tscn`, `slow_wind_run.sh` → `out/slow_wind.csv` — слабый ветер (Онгудай, kayancha_south:
  12:00 3 м/с с 180°, 2 и 1 м/с с 270°, штиль 9:00): по проходам k, итерации области [без нагрева, с нагревом] и
  окон, время, GPU, упор в 3000; варианты p1 (один проход, как 1.0.0), p2 (тёплый проход 2), p2cold.
- `residual_probe.gd/.tscn` → `out/residuals.csv` — история невязок решателя области (k = 1) на слабом ветре.
- `out/before/` — данные WPC-2 из `576550e` (поле посчитано на коде = main 1.0.0): `wind_profile.csv`,
  `wind_profile_meta.jsonl`, `wind_summary.md/.csv`, `terrain_lines.json`, `hill_geometry.json`.
- `out/after/` — ветка `air-start/as1`, два прохода (C9 v3): аналитика и поле, сводка WPC-2 и графики `fig/`.
- `out/after_p3/` — поле с тремя проходами (`--passes=3`, третий — если остаток > 3 %).
- `out/compare_after.md/.csv`, `out/compare_after_p3.md/.csv` — до/после.
- `out/passes.csv`, `out/passes_summary.md` — по проходам (6 м/с — тёплый и холодный старт прохода 2;
  3 и 10 м/с — тёплый; 3 м/с — ещё холодный с тремя проходами).

## Воспроизведение
Из корня рабочей копии (импорт: `XDG_DATA_HOME=$(mktemp -d) godot --headless --path . --import`). GPU-прогоны
идут под `flock /tmp/heat_ca_gpu.lock` (окно 320×240). Готовые ключи пропускаются — для пересчёта удалить csv/jsonl.

    tools/research/air_start/wind_audit_run.sh all after                    # аналитика + поле (2 прохода) + итог
    tools/research/air_start/wind_audit_run.sh field after_p3 --passes=3    # поле, 3 прохода
    tools/research/air_start/passes_run.sh                                  # проходы 1–4
    python3 tools/research/air_start/compare.py after                       # только таблица
    python3 tools/research/air_start/passes_summary.py
    tools/research/air_start/slow_wind_run.sh                               # слабый ветер по проходам
    XDG_DATA_HOME=$(mktemp -d) flock /tmp/heat_ca_gpu.lock godot --path . --audio-driver Dummy \
      --resolution 320x240 res://tools/research/air_start/residual_probe.tscn   # невязки

Сводка WPC-2 (`wind_audit.py`) требует matplotlib (venv `tools/research/heat_ca/.venv`).

Время (`wall_s`) замерено на RTX 4070 SUPER + Xeon E5-2666 v3 при занятой машине (load average ~29 на 20
потоках, параллельные прогоны других модулей) — абсолютные секунды завышены, сравнивать до/после и проходы
между собой. До (WPC-2, 576550e) мерилось при другой загрузке.

Лицензии: только собственные данные игры.
