# Эталоны RW-8s (поверхностный порыв для пыли)

Снято с опорной ревизии GD `c591b1026` (W8), Godot 4.7.2. Читает `rust/dp-air/tests/terms_surface_gust.rs`.

- `gust_dump.f64` + `manifest.json` - f64 LE; сценарий: 6 чисел (сид, ветер на 10 м м/с, откуда °, высота солнца °,
  облачность, `convective_turbulence_ms`) и 1500 записей `(x, z, t, GustDustModel.gust_ms)`; `x, z` в ±6000 м,
  `t` в 0..7200 с (случайные, в том числе «прошлые»). `offset` в манифесте - в f64.
- Сценарии `synth_*` - синтетический мир (ветер задан), `ongudai_*` - сиды и ветер прогноза эталонов Онгудая
  (`tests/fixtures/wind/cases/ongudai_*.json`): без места - шум и профиль не зависят от него.
- `dump.gd.txt`, `dump.tscn.txt` - headless-дамп (положить в `tools/wind_fixtures/RW-8s/` как `.gd`/`.tscn`).
Пересъёмка: `godot --headless --path . res://tools/wind_fixtures/RW-8s/dump.tscn -- --out=<каталог>` (под замком cpu).
