# SY-5: настройка параметров генератора рельефа схемой Professor

Метод — `tools/research/tune/professor.py` (копия `professor_core.py`) и `docs/research/air-model-tune.md`. Генератор — `../corpus/generator.py` (S3 v3).
Окружение: `../corpus/setup_env.sh`, затем `uv pip install --python ../corpus/.venv/bin/python brotli`. Все счёты — `OMP_NUM_THREADS=1`.

| шаг | команда | выход (`out/`) |
|---|---|---|
| 1. эталон: наблюдаемые на 4 detail + 64 far квадратах 384×384 (100 м), сравнение detail/far на одном участке | `../corpus/.venv/bin/python ref_obs.py` | `ref_obs.json` |
| 2. план (латинский гиперкуб по TUNABLE) и прогоны | `OMP_NUM_THREADS=1 dp job start sy5_runs <с> ../corpus/.venv/bin/python run_design.py --points 150 --seeds 4 --workers 12` (продолжение — той же командой; пробное время `--trial 2 --workers 2 --out /tmp/x`) | `design.json`, `runs.jsonl` |
| 3. полиномы, подгонка к каждому квадрату, облако, eigentunes | `../corpus/.venv/bin/python fit.py` | `theta_cloud.json`, `tune_summary.json` |
| тесты (восстановление θ по синтетической функции) | `../corpus/.venv/bin/python -m pytest -q tests` | |

Наблюдаемые (`observables.py`): ln(1+N) вершин при prominence ≥ 30/100/300 м (100 м) и ≥ 100/300 м (на 400 м), медианное расстояние до ключевой
седловины, ln перепада, ln локального перепада 2,5 км, квантили уклона p50/p90 (100 и 400 м), β спектра в полосах 3–12 км / 1–3 км / 0,4–1 км,
плотность русел при водосборе ≥ 1 км², анизотропия. Квадрат — 384×384 клеток (38,4 км) из detail (25→100 м, центр) или far (4×4 на место).
Знаменатель χ²: σ² = σ_ген² (шум одной реализации по зёрнам) + σ_LOO² (ошибка полинома) + (систематика detail−far)² + пол².
Разброс эталона между квадратами района — в `reference_spread` отчёта (`ref_obs.json: far_std`), в χ² отдельного квадрата не входит
(каждый квадрат подгоняется сам; разброс облака и есть этот разброс).
Данные эталона: `data/terrain` (Copernicus GLO-30, Terrarium/Mapzen — лицензии в `meta.json` мест и `ASSETS.md`).
