# lee-turb: литература (LT-1)
- `lit_numbers.csv` — LTL v1; собирается `python3 build_lit.py` (таблица в самом скрипте).
- Проверка: `python3 ../contract/check_contract.py lit_numbers.csv`.
- Выводы: `docs/research/lee_turb.md`.
- Тексты прочитаны: NASA TM-86698 и TM-85851 (общедоступны, ntrs.nasa.gov), Menke 2019 ACP (CC BY 4.0).
  Остальное по памяти, помечено `C`. Лицензий данных нет: берутся числа, не наборы.
- Аналитика erf/tanh: θ/δ_ω=0,2251 (erf), B/δ_ω=1,022; численное интегрирование в build_lit.py не нужно (проверялось отдельно).
