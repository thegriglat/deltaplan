# Проверка физики крыльев (wing-physics-check)

- WPC-3, пачка полётов против ветра и в динамике: `tools/flight/wind_penetration_batch.sh` (аналитика + поле на GPU; поля — `build/wpc3/fields/`, части — `build/wpc3/parts/`) → `out/penetration.csv` (К6), сводка `python3 tools/flight/wind_penetration_table.py` → `out/penetration_summary.md`, `out/penetration_by_wing.csv`.
