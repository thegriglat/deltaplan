PD-33 — разбор правильной посадки «Маятника» (docs/research/pendulum.md → «Посадка (PD-33)»).

- `base_*`, `B06_*`, `X_*`, `A_B06_*` — ход посадки по шагам 0,05 с (`PD27_TRACE=крыло,0,0.5 PD33_DIAG=1`;
  B06 — `PD27_PUSH=0.6`; X — `PD27_PUSH=1.2 PD29_FMAX=2000 PD30_REACH=0`; A_B06 — `PD29_DS=1 PD27_PUSH=0.6`).
  Колонки — шапка `diag_line` в tests/flight/pendulum/test_pendulum_landing_technique.gd; t до отдачи — 0.
- `variants_summary.txt` — пачка `batch1.sh`, сводка `summ.py`: оценка (верт./гор.), «П» — переворот.
- `wind_noround.txt` — сильный встречный 8/10 м/с и заход без выравнивания.
