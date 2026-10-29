# Эталоны RW-8 (болтанка поля, шум порывов)

Снято с опорной ревизии GD `feature/rust-wind` `c591b1026` (W8, «Опорная ревизия»), Godot 4.7.2.
Читает `rust/dp-air/tests/terms_turb.rs`.

## Файлы
- `rw8_dump.f64` + `manifest.json` — f64 LE подряд, карта `arrays: имя → [смещение, длина]` (в f64).
  Снимает `rw8_dump.gd.txt` (headless): `WindModel.gust_unit` (3 сида × 1500 отсчётов: точка, время, перенос,
  доля крупных вихрей), пятно рывка `_lee_burst_g`-стиля и `burst_mean/std`, `GustSpectrum` (нормировка,
  24 сдвига, таблицы весов `_wu/_ww`, `carried`, 1500 отсчётов на сид), `FieldTurbulence` (`sigma`, `lee`,
  `sep_sigma`, `reverse_unresolved`, `taylor_stretch`, `mil_lw/lu` на 3000 случайных входах). Входы пишутся
  вместе с результатами — Rust ничего не пересчитывает по генератору GD.
- `dbg_ongudai_<случай>.f64` — внутренние величины `_air_velocity_field` в точках эталонов `ongudai_*`
  (набор 1: medium, strong, wave, storm; набор 2: ongudai_day_1..3). По
  64 числа на запись, порядок записей — `[момент][точка]` как в `tests/fixtures/wind/cases/<имя>.bin`; точка вне
  поля (доля `a = 0`) — запись из NaN. Поля записи — модуль `rec` в `terms_turb.rs`.
  Дамп снят на том же прогоне, что файлы случая: `.bin` пересъёмки совпадает с `tests/fixtures/wind/cases`
  побитно (проверено `cmp`).
- `atmo_dump.patch` — правка GD (`atmosphere.gd`: `dbg_on`, `dbg_rec`; `gen_fixtures.gd`: запись
  `dbg_<случай>.f64`), поверх `c591b1026`.
- `rw8_dump.gd.txt`, `rw8_dump.tscn.txt` — headless-дамп (положить в `tools/wind_fixtures/` как `.gd`/`.tscn`).

## Пересъёмка
```
git worktree add <scratch>/gd-ref c591b1026 && cd <scratch>/gd-ref
git apply <это>/atmo_dump.patch
cp <это>/rw8_dump.gd.txt tools/wind_fixtures/rw8_dump.gd; cp <это>/rw8_dump.tscn.txt tools/wind_fixtures/rw8_dump.tscn
# ongudai_* (GPU, окно, ~4 мин на случай): под замком gpu
.dpcli/dpcli job --lock gpu start rw8dump 2400 tools/wind_fixtures/run.sh --out=<dir> --only=ongudai_medium,ongudai_strong,ongudai_wave,ongudai_storm,ongudai_day_1,ongudai_day_2,ongudai_day_3
# шум, спектр, FieldTurbulence (headless, под замком cpu)
godot --headless --path . res://tools/wind_fixtures/rw8_dump.tscn -- --out=<dir>
```
Размер каталога ≤ 5 МБ. `project.godot` после запусков вернуть как был.

## Генератор удалён (RW-13)
`tools/wind_fixtures/gen_fixtures.{gd,gd.uid,tscn}`, `run.sh`, `verify.sh`, `check_k01.py` удалены; восстановление — `git show a5d9387c3:tools/wind_fixtures/<файл>`.
