# Пачка WPC-3: путевая против ветра и динамик

Данные: `tools/research/wing_physics_check/out/penetration.csv` (4160 строк, контракт К6). Путевая — средняя за последние 30 с вдоль направления «в ветер», м/с (− — сносит назад); ветер в точке `wind_h` — модуль горизонтального ветра там же. Масса пилота 85 кг. Воспроизвести: `tools/flight/wind_penetration_batch.sh`, сводка — `python3 tools/flight/wind_penetration_table.py`.


## Путевая против ветра по группам крыльев — analytic

Ячейка: среднее по крыльям группы (наименьшее), м/с; в скобках после старта — средний ветер в точке wind_h на 30/100/200 м.

| старт | ветер, м/с | трапеция | группа | 30 м | 100 м | 200 м |
|---|---|---|---|---|---|---|
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | 0 | soviet | +6.1 (+5.2) | +5.5 (+4.9) | +5.5 (+4.5) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | 0 | trainer | +6.0 (+5.3) | +5.5 (+5.1) | +5.1 (+4.6) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | 0 | kingpost | +6.8 (+6.2) | +6.5 (+6.1) | +5.7 (+5.1) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | 0 | topless | +6.9 (+6.6) | +6.8 (+6.5) | +5.8 (+5.4) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -0.5 | soviet | +9.8 (+8.7) | +9.9 (+8.8) | +9.5 (+8.5) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -0.5 | trainer | +9.7 (+8.8) | +9.4 (+8.3) | +9.4 (+8.5) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -0.5 | kingpost | +13.2 (+11.8) | +13.0 (+11.4) | +12.7 (+11.2) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -0.5 | topless | +15.2 (+14.7) | +15.0 (+14.5) | +14.6 (+14.2) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -1 | soviet | +13.9 (+12.4) | +13.7 (+12.0) | +13.3 (+12.0) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -1 | trainer | +13.9 (+12.8) | +13.8 (+12.7) | +13.3 (+12.4) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -1 | kingpost | +20.4 (+17.6) | +20.7 (+17.9) | +20.4 (+17.3) |
| altai/sinyukha_west (ветер 3.8/4.0/4.5) | 3 | -1 | topless | +23.9 (+23.3) | +24.1 (+23.5) | +24.1 (+23.5) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | 0 | soviet | +0.6 (+0.1) | +0.8 (+0.2) | -0.2 (-0.7) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | 0 | trainer | -0.4 (-0.8) | -0.1 (-0.3) | -0.5 (-2.1) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | 0 | kingpost | -0.3 (-1.1) | +0.6 (-1.1) | -1.2 (-4.4) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | 0 | topless | -0.0 (-0.7) | +1.5 (+0.8) | -1.1 (-4.5) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -0.5 | soviet | +2.1 (+1.3) | +2.4 (+2.0) | +3.0 (+2.6) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -0.5 | trainer | +1.5 (+1.1) | +1.9 (+1.7) | +2.9 (+2.5) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -0.5 | kingpost | +3.9 (+3.3) | +3.8 (+2.7) | +4.4 (+3.8) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -0.5 | topless | +5.2 (+4.9) | +5.1 (+4.9) | +5.8 (+5.3) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -1 | soviet | +8.7 (+7.6) | +6.7 (+5.2) | +5.8 (+5.5) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -1 | trainer | +6.2 (+4.8) | +5.9 (+4.6) | +4.8 (+3.9) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -1 | kingpost | +12.6 (+9.5) | +12.2 (+9.3) | +10.0 (+8.4) |
| altai/sinyukha_west (ветер 11.8/11.7/12.7) | 6 | -1 | topless | +16.5 (+15.5) | +15.8 (+15.1) | +13.2 (+11.9) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | 0 | soviet | +5.0 (+3.9) | +4.6 (+3.4) | +5.8 (+4.4) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | 0 | trainer | +4.4 (+3.4) | +4.7 (+4.0) | +5.4 (+4.8) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | 0 | kingpost | +5.6 (+5.2) | +6.0 (+5.5) | +6.5 (+5.9) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | 0 | topless | +6.0 (+5.6) | +6.3 (+5.8) | +6.8 (+6.4) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -0.5 | soviet | +9.5 (+8.3) | +9.1 (+7.7) | +9.3 (+8.2) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -0.5 | trainer | +9.0 (+7.8) | +9.1 (+8.4) | +9.5 (+8.8) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -0.5 | kingpost | +12.9 (+11.4) | +13.1 (+11.4) | +13.0 (+11.5) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -0.5 | topless | +14.9 (+14.4) | +14.8 (+14.3) | +14.7 (+14.4) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -1 | soviet | +13.6 (+12.2) | +13.2 (+11.6) | +13.2 (+11.8) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -1 | trainer | +13.5 (+12.5) | +13.3 (+12.1) | +13.2 (+12.3) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -1 | kingpost | +19.8 (+17.1) | +20.1 (+17.2) | +19.5 (+16.9) |
| askarovo/biyagoda_west (ветер 4.1/4.0/4.1) | 3 | -1 | topless | +23.4 (+22.7) | +23.7 (+23.1) | +22.8 (+22.2) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | 0 | soviet | +0.1 (-0.3) | +1.6 (+1.3) | -0.1 (-1.9) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | 0 | trainer | +0.4 (+0.1) | +1.5 (+0.9) | +0.3 (-0.9) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | 0 | kingpost | +0.3 (-0.3) | +1.0 (-0.9) | +0.2 (-2.2) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | 0 | topless | +0.1 (-1.2) | +0.6 (+0.3) | -0.5 (-9.0) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -0.5 | soviet | +2.2 (+2.1) | +2.9 (+2.7) | +2.3 (+1.7) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -0.5 | trainer | +2.2 (+1.6) | +2.3 (+2.1) | +2.1 (+1.9) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -0.5 | kingpost | +4.5 (+3.4) | +3.7 (+3.0) | +3.8 (+3.5) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -0.5 | topless | +5.0 (+4.5) | +5.0 (+4.6) | +4.2 (+3.6) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -1 | soviet | +7.7 (+6.0) | +4.2 (+3.2) | +4.2 (+3.8) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -1 | trainer | +6.0 (+4.3) | +5.3 (+3.9) | +4.4 (+3.5) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -1 | kingpost | +14.6 (+10.6) | +12.5 (+9.6) | +9.4 (+6.6) |
| askarovo/biyagoda_west (ветер 10.7/11.2/12.2) | 6 | -1 | topless | +18.3 (+17.4) | +16.8 (+15.5) | +13.8 (+12.3) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | 0 | soviet | +5.6 (+4.5) | +5.2 (+4.4) | +5.2 (+4.6) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | 0 | trainer | +5.3 (+4.4) | +4.6 (+4.0) | +4.4 (+4.1) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | 0 | kingpost | +6.3 (+5.5) | +5.3 (+4.8) | +4.8 (+4.4) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | 0 | topless | +6.4 (+6.0) | +5.6 (+5.2) | +5.1 (+4.7) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -0.5 | soviet | +9.5 (+8.4) | +9.4 (+8.6) | +9.4 (+8.3) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -0.5 | trainer | +9.3 (+8.7) | +9.5 (+8.8) | +8.9 (+7.9) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -0.5 | kingpost | +13.0 (+11.3) | +13.2 (+11.3) | +12.8 (+11.2) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -0.5 | topless | +15.1 (+14.6) | +15.2 (+14.7) | +14.9 (+14.3) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -1 | soviet | +13.6 (+12.5) | +13.5 (+12.1) | +13.2 (+11.6) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -1 | trainer | +13.8 (+12.6) | +13.3 (+12.1) | +13.5 (+12.3) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -1 | kingpost | +20.3 (+17.5) | +19.8 (+17.3) | +19.9 (+17.2) |
| aushkul/aushtau_east (ветер 3.7/4.1/4.4) | 3 | -1 | topless | +23.7 (+23.1) | +23.2 (+22.5) | +23.3 (+22.5) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | 0 | soviet | +1.0 (+0.2) | +1.5 (+1.0) | -0.2 (-0.5) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | 0 | trainer | +0.1 (-0.5) | +1.3 (+1.2) | -0.3 (-1.0) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | 0 | kingpost | +0.0 (-1.6) | +1.1 (-0.1) | +1.3 (+0.5) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | 0 | topless | +1.5 (-1.2) | +0.2 (-2.2) | +0.2 (-2.7) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -0.5 | soviet | +2.7 (+2.1) | +2.5 (+2.1) | +3.0 (+2.8) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -0.5 | trainer | +2.9 (+2.0) | +2.0 (+1.6) | +2.5 (+2.1) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -0.5 | kingpost | +5.8 (+4.5) | +5.5 (+4.4) | +4.7 (+4.3) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -0.5 | topless | +7.1 (+6.8) | +7.1 (+6.5) | +5.7 (+5.3) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -1 | soviet | +5.3 (+4.1) | +5.8 (+4.5) | +5.4 (+4.3) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -1 | trainer | +6.1 (+4.9) | +5.6 (+4.3) | +5.8 (+4.9) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -1 | kingpost | +12.2 (+9.1) | +11.6 (+8.9) | +11.1 (+8.7) |
| aushkul/aushtau_east (ветер 10.6/10.9/11.3) | 6 | -1 | topless | +16.8 (+15.6) | +15.4 (+14.7) | +14.8 (+14.1) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | 0 | soviet | +6.1 (+4.9) | +6.4 (+5.1) | +5.3 (+4.4) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | 0 | trainer | +5.4 (+5.0) | +4.7 (+3.9) | +4.7 (+4.3) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | 0 | kingpost | +6.7 (+6.2) | +6.3 (+5.4) | +5.7 (+5.2) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | 0 | topless | +7.1 (+6.8) | +6.6 (+6.1) | +6.1 (+5.8) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -0.5 | soviet | +10.2 (+9.2) | +10.4 (+9.2) | +10.1 (+8.8) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -0.5 | trainer | +10.2 (+9.3) | +10.8 (+9.8) | +9.8 (+8.7) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -0.5 | kingpost | +14.3 (+12.7) | +14.7 (+13.2) | +14.0 (+12.3) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -0.5 | topless | +16.1 (+15.4) | +16.3 (+15.9) | +15.5 (+15.1) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -1 | soviet | +14.4 (+12.7) | +14.3 (+12.9) | +14.4 (+13.1) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -1 | trainer | +14.5 (+13.4) | +14.6 (+13.5) | +14.6 (+13.7) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -1 | kingpost | +21.4 (+18.3) | +21.4 (+18.6) | +21.2 (+18.2) |
| ongudai/kayancha_south (ветер 3.9/4.0/4.5) | 3 | -1 | topless | +25.3 (+24.6) | +25.0 (+24.5) | +24.9 (+24.2) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | 0 | soviet | +1.3 (+0.7) | +1.7 (+1.5) | +0.1 (-0.8) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | 0 | trainer | +1.4 (+0.6) | +1.5 (+1.2) | -2.0 (-2.9) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | 0 | kingpost | +1.7 (+0.6) | +2.3 (+1.3) | -2.6 (-3.5) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | 0 | topless | +1.4 (-0.1) | +1.8 (-2.8) | -2.1 (-3.2) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -0.5 | soviet | +4.0 (+3.4) | +3.8 (+2.6) | +3.1 (+2.9) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -0.5 | trainer | +3.3 (+3.0) | +4.0 (+3.6) | +2.9 (+2.1) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -0.5 | kingpost | +4.6 (+4.1) | +5.0 (+4.7) | +5.2 (+4.5) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -0.5 | topless | +6.1 (+4.6) | +5.4 (+5.3) | +5.9 (+5.6) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -1 | soviet | +7.1 (+6.4) | +7.1 (+6.5) | +6.9 (+6.1) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -1 | trainer | +6.7 (+6.3) | +6.4 (+5.4) | +5.4 (+4.5) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -1 | kingpost | +12.8 (+9.3) | +12.1 (+9.6) | +10.4 (+7.4) |
| ongudai/kayancha_south (ветер 11.5/11.4/13.5) | 6 | -1 | topless | +17.2 (+16.6) | +16.1 (+15.1) | +14.3 (+13.3) |

## Путевая против ветра по группам крыльев — field

Ячейка: среднее по крыльям группы (наименьшее), м/с; в скобках после старта — средний ветер в точке wind_h на 30/100/200 м.

| старт | ветер, м/с | трапеция | группа | 30 м | 100 м | 200 м |
|---|---|---|---|---|---|---|
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | 0 | soviet | +5.2 (+5.2) | +4.2 (+4.2) | +3.7 (+3.7) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | 0 | trainer | +5.4 (+5.4) | +4.5 (+4.5) | +4.2 (+4.2) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | 0 | kingpost | +6.4 (+6.4) | +6.0 (+6.0) | +5.6 (+5.6) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | 0 | topless | +6.8 (+6.8) | +6.3 (+6.3) | +6.0 (+6.0) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -0.5 | soviet | +9.4 (+9.4) | +8.4 (+8.4) | +8.2 (+8.2) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -0.5 | trainer | +10.2 (+10.2) | +8.9 (+8.9) | +9.0 (+9.0) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -0.5 | kingpost | +14.3 (+14.3) | +13.2 (+13.2) | +13.4 (+13.4) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -0.5 | topless | +16.0 (+16.0) | +15.3 (+15.3) | +15.2 (+15.2) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -1 | soviet | +13.9 (+13.9) | +13.4 (+13.4) | +12.1 (+12.1) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -1 | trainer | +14.7 (+14.7) | +14.0 (+14.0) | +13.6 (+13.6) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -1 | kingpost | +20.5 (+20.5) | +20.1 (+20.1) | +19.5 (+19.5) |
| altai/sinyukha_west (ветер 3.6/4.4/4.8) | 3 | -1 | topless | +24.2 (+24.2) | +23.6 (+23.6) | +23.5 (+23.5) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | 0 | soviet | -1.5 (-1.5) | -1.5 (-1.5) | -3.7 (-3.7) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | 0 | trainer | +3.3 (+3.3) | -2.1 (-2.1) | -3.6 (-3.6) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | 0 | kingpost | +2.3 (+2.3) | -2.0 (-2.0) | -2.9 (-2.9) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | 0 | topless | +2.1 (+2.1) | -1.8 (-1.8) | -2.7 (-2.7) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -0.5 | soviet | +1.6 (+1.6) | +1.0 (+1.0) | -0.3 (-0.3) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -0.5 | trainer | +2.0 (+2.0) | +0.5 (+0.5) | +0.2 (+0.2) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -0.5 | kingpost | +5.9 (+5.9) | +5.2 (+5.2) | +4.4 (+4.4) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -0.5 | topless | +7.7 (+7.7) | +7.2 (+7.2) | +6.8 (+6.8) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -1 | soviet | +6.3 (+6.3) | +5.8 (+5.8) | +4.1 (+4.1) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -1 | trainer | +6.8 (+6.8) | +5.8 (+5.8) | +5.1 (+5.1) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -1 | kingpost | +13.6 (+13.6) | +12.8 (+12.8) | +12.5 (+12.5) |
| altai/sinyukha_west (ветер 10.4/11.9/12.9) | 6 | -1 | topless | +17.9 (+17.9) | +17.1 (+17.1) | +17.2 (+17.2) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | 0 | soviet | +3.6 (+3.6) | +3.4 (+3.4) | +3.6 (+3.6) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | 0 | trainer | +4.3 (+4.3) | +3.7 (+3.7) | +4.3 (+4.3) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | 0 | kingpost | +6.0 (+6.0) | +5.4 (+5.4) | +5.5 (+5.5) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | 0 | topless | +6.4 (+6.4) | +5.8 (+5.8) | +6.0 (+6.0) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -0.5 | soviet | +9.7 (+9.7) | +9.3 (+9.3) | +8.2 (+8.2) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -0.5 | trainer | +10.8 (+10.8) | +10.2 (+10.2) | +9.3 (+9.3) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -0.5 | kingpost | +15.5 (+15.5) | +15.2 (+15.2) | +14.2 (+14.2) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -0.5 | topless | +17.6 (+17.6) | +17.4 (+17.4) | +16.3 (+16.3) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -1 | soviet | +13.1 (+13.1) | +13.5 (+13.5) | +13.1 (+13.1) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -1 | trainer | +14.6 (+14.6) | +15.1 (+15.1) | +14.8 (+14.8) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -1 | kingpost | +20.9 (+20.9) | +21.2 (+21.2) | +21.9 (+21.9) |
| askarovo/biyagoda_west (ветер 3.2/3.4/3.7) | 3 | -1 | topless | +24.5 (+24.5) | +24.5 (+24.5) | +25.2 (+25.2) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | 0 | soviet | -2.2 (-2.2) | -1.5 (-1.5) | -3.3 (-3.3) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | 0 | trainer | -0.3 (-0.3) | -1.6 (-1.6) | -3.2 (-3.2) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | 0 | kingpost | +0.4 (+0.4) | -0.3 (-0.3) | -1.7 (-1.7) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | 0 | topless | +0.5 (+0.5) | -0.2 (-0.2) | -1.3 (-1.3) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -0.5 | soviet | +5.1 (+5.1) | +2.7 (+2.7) | +1.4 (+1.4) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -0.5 | trainer | +4.9 (+4.9) | +3.8 (+3.8) | +2.3 (+2.3) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -0.5 | kingpost | +10.3 (+10.3) | +9.2 (+9.2) | +7.2 (+7.2) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -0.5 | topless | +12.2 (+12.2) | +11.3 (+11.3) | +9.5 (+9.5) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -1 | soviet | +9.7 (+9.7) | +8.9 (+8.9) | +7.6 (+7.6) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -1 | trainer | +10.5 (+10.5) | +10.2 (+10.2) | +8.7 (+8.7) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -1 | kingpost | +16.7 (+16.7) | +16.2 (+16.2) | +15.9 (+15.9) |
| askarovo/biyagoda_west (ветер 8.1/9.0/10.4) | 6 | -1 | topless | +20.2 (+20.2) | +19.7 (+19.7) | +19.2 (+19.2) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | 0 | soviet | +4.5 (+4.5) | +3.6 (+3.6) | +1.4 (+1.4) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | 0 | trainer | +5.1 (+5.1) | +3.5 (+3.5) | +2.1 (+2.1) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | 0 | kingpost | +6.6 (+6.6) | +5.0 (+5.0) | +4.1 (+4.1) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | 0 | topless | +6.9 (+6.9) | +5.5 (+5.5) | +4.8 (+4.8) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -0.5 | soviet | +9.7 (+9.7) | +9.1 (+9.1) | +7.8 (+7.8) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -0.5 | trainer | +11.1 (+11.1) | +10.4 (+10.4) | +9.2 (+9.2) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -0.5 | kingpost | +15.8 (+15.8) | +15.7 (+15.7) | +14.5 (+14.5) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -0.5 | topless | +17.8 (+17.8) | +17.9 (+17.9) | +16.8 (+16.8) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -1 | soviet | +13.5 (+13.5) | +13.7 (+13.7) | +13.6 (+13.6) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -1 | trainer | +15.7 (+15.7) | +15.5 (+15.5) | +15.0 (+15.0) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -1 | kingpost | +21.4 (+21.4) | +21.7 (+21.7) | +21.6 (+21.6) |
| aushkul/aushtau_east (ветер 3.3/3.8/4.6) | 3 | -1 | topless | +24.4 (+24.4) | +24.7 (+24.7) | +24.6 (+24.6) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | 0 | soviet | -2.4 (-2.4) | -1.4 (-1.4) | -5.9 (-5.9) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | 0 | trainer | +0.4 (+0.4) | -1.7 (-1.7) | -6.3 (-6.3) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | 0 | kingpost | +0.5 (+0.5) | -1.4 (-1.4) | -4.3 (-4.3) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | 0 | topless | +0.6 (+0.6) | -2.5 (-2.5) | -3.7 (-3.7) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -0.5 | soviet | +3.8 (+3.8) | +0.2 (+0.2) | -0.8 (-0.8) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -0.5 | trainer | +3.8 (+3.8) | +2.0 (+2.0) | +0.4 (+0.4) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -0.5 | kingpost | +9.2 (+9.2) | +7.9 (+7.9) | +6.2 (+6.2) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -0.5 | topless | +11.0 (+11.0) | +10.2 (+10.2) | +8.7 (+8.7) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -1 | soviet | +8.9 (+8.9) | +7.9 (+7.9) | +5.8 (+5.8) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -1 | trainer | +9.8 (+9.8) | +8.6 (+8.6) | +6.9 (+6.9) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -1 | kingpost | +15.4 (+15.4) | +14.9 (+14.9) | +14.3 (+14.3) |
| aushkul/aushtau_east (ветер 9.2/10.4/12.4) | 6 | -1 | topless | +18.2 (+18.2) | +17.7 (+17.7) | +17.5 (+17.5) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | 0 | soviet | +4.3 (+4.3) | +3.5 (+3.5) | +4.1 (+4.1) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | 0 | trainer | +4.1 (+4.1) | +4.2 (+4.2) | +4.7 (+4.7) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | 0 | kingpost | +5.4 (+5.4) | +5.8 (+5.8) | +5.7 (+5.7) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | 0 | topless | +5.6 (+5.6) | +6.2 (+6.2) | +5.9 (+5.9) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -0.5 | soviet | +8.7 (+8.7) | +7.6 (+7.6) | +7.4 (+7.4) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -0.5 | trainer | +8.7 (+8.7) | +8.6 (+8.6) | +8.5 (+8.5) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -0.5 | kingpost | +13.6 (+13.6) | +12.8 (+12.8) | +13.0 (+13.0) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -0.5 | topless | +15.9 (+15.9) | +14.9 (+14.9) | +15.2 (+15.2) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -1 | soviet | +13.6 (+13.6) | +13.0 (+13.0) | +11.2 (+11.2) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -1 | trainer | +14.5 (+14.5) | +13.9 (+13.9) | +12.3 (+12.3) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -1 | kingpost | +21.5 (+21.5) | +21.0 (+21.0) | +20.8 (+20.8) |
| ongudai/kayancha_south (ветер 4.7/5.1/5.6) | 3 | -1 | topless | +24.9 (+24.9) | +25.0 (+25.0) | +24.8 (+24.8) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | 0 | soviet | -2.0 (-2.0) | -1.3 (-1.3) | -3.0 (-3.0) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | 0 | trainer | -1.9 (-1.9) | -1.9 (-1.9) | -3.0 (-3.0) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | 0 | kingpost | -1.2 (-1.2) | -1.5 (-1.5) | -2.4 (-2.4) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | 0 | topless | -1.0 (-1.0) | -1.3 (-1.3) | -2.1 (-2.1) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -0.5 | soviet | +2.0 (+2.0) | +1.6 (+1.6) | +0.3 (+0.3) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -0.5 | trainer | +2.5 (+2.5) | +2.1 (+2.1) | +1.3 (+1.3) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -0.5 | kingpost | +7.8 (+7.8) | +7.2 (+7.2) | +6.8 (+6.8) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -0.5 | topless | +10.0 (+10.0) | +9.6 (+9.6) | +9.3 (+9.3) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -1 | soviet | +9.2 (+9.2) | +7.2 (+7.2) | +5.4 (+5.4) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -1 | trainer | +9.3 (+9.3) | +7.7 (+7.7) | +6.6 (+6.6) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -1 | kingpost | +16.7 (+16.7) | +16.2 (+16.2) | +14.8 (+14.8) |
| ongudai/kayancha_south (ветер 10.5/11.0/12.3) | 6 | -1 | topless | +20.2 (+20.2) | +20.2 (+20.2) | +19.1 (+19.1) |

## Где сносит назад (путевая < 0)

| режим | старт | ветер, м/с | трапеция | высота, м | крыльев | путевая, м/с (мин) | ветер в точке, м/с | крылья |
|---|---|---|---|---|---|---|---|---|
| analytic | altai/sinyukha_west | 6 | 0 | 30 | 35/48 | -1.1 | 10.6 | 35 крыльев |
| analytic | altai/sinyukha_west | 6 | 0 | 100 | 10/48 | -1.1 | 9.7 | 10 крыльев |
| analytic | altai/sinyukha_west | 6 | 0 | 200 | 38/48 | -4.5 | 11.5 | 38 крыльев |
| analytic | askarovo/biyagoda_west | 6 | 0 | 30 | 14/48 | -1.2 | 9.8 | 14 крыльев |
| analytic | askarovo/biyagoda_west | 6 | 0 | 100 | 1/48 | -0.9 | 9.1 | moyes_gecko |
| analytic | askarovo/biyagoda_west | 6 | 0 | 200 | 23/48 | -9.0 | 9.9 | 23 крыльев |
| analytic | aushkul/aushtau_east | 6 | 0 | 30 | 12/48 | -1.6 | 9.5 | 12 крыльев |
| analytic | aushkul/aushtau_east | 6 | 0 | 100 | 6/48 | -2.2 | 9.6 | aeros_combat_l, air_c4, icaro_laminar_z9, icaro_mastr, sport, ww_talon |
| analytic | aushkul/aushtau_east | 6 | 0 | 200 | 15/48 | -2.7 | 9.4 | 15 крыльев |
| analytic | ongudai/kayancha_south | 6 | 0 | 30 | 1/48 | -0.1 | 9.2 | aeros_combat_l |
| analytic | ongudai/kayancha_south | 6 | 0 | 100 | 1/48 | -2.8 | 7.0 | sport |
| analytic | ongudai/kayancha_south | 6 | 0 | 200 | 46/48 | -3.5 | 12.7 | 46 крыльев |
| field | altai/sinyukha_west | 6 | -0.5 | 200 | 1/4 | -0.3 | 13.0 | slavutich_ut |
| field | altai/sinyukha_west | 6 | 0 | 30 | 1/4 | -1.5 | 10.7 | slavutich_ut |
| field | altai/sinyukha_west | 6 | 0 | 100 | 4/4 | -2.1 | 11.6 | combat, laminar, slavutich_ut, training |
| field | altai/sinyukha_west | 6 | 0 | 200 | 4/4 | -3.7 | 13.1 | combat, laminar, slavutich_ut, training |
| field | askarovo/biyagoda_west | 6 | 0 | 30 | 2/4 | -2.2 | 9.8 | slavutich_ut, training |
| field | askarovo/biyagoda_west | 6 | 0 | 100 | 4/4 | -1.6 | 10.4 | combat, laminar, slavutich_ut, training |
| field | askarovo/biyagoda_west | 6 | 0 | 200 | 4/4 | -3.3 | 11.9 | combat, laminar, slavutich_ut, training |
| field | aushkul/aushtau_east | 6 | -0.5 | 200 | 1/4 | -0.8 | 12.9 | slavutich_ut |
| field | aushkul/aushtau_east | 6 | 0 | 30 | 1/4 | -2.4 | 10.3 | slavutich_ut |
| field | aushkul/aushtau_east | 6 | 0 | 100 | 4/4 | -2.5 | 11.3 | combat, laminar, slavutich_ut, training |
| field | aushkul/aushtau_east | 6 | 0 | 200 | 4/4 | -6.3 | 14.7 | combat, laminar, slavutich_ut, training |
| field | ongudai/kayancha_south | 6 | 0 | 30 | 4/4 | -2.0 | 11.8 | combat, laminar, slavutich_ut, training |
| field | ongudai/kayancha_south | 6 | 0 | 100 | 4/4 | -1.9 | 11.8 | combat, laminar, slavutich_ut, training |
| field | ongudai/kayancha_south | 6 | 0 | 200 | 4/4 | -3.0 | 13.1 | combat, laminar, slavutich_ut, training |

## Динамик: бот-восьмёрка у гребня, 3 мин, трим

Средний вариометр = набор / время полёта, м/с; набор, м; «земля» — сколько крыльев коснулись земли раньше 3 мин.

| режим | старт | ветер, м/с | группа | крыльев | вариометр, м/с (мин…макс) | набор, м (мин…макс) | земля |
|---|---|---|---|---|---|---|---|
| analytic | altai/sinyukha_west | 3 | soviet | 3 | -0.79 (-0.90…-0.73) | -42 (-59…-21) | 3 |
| analytic | altai/sinyukha_west | 3 | trainer | 11 | -0.43 (-0.56…-0.25) | -65 (-78…-46) | 8 |
| analytic | altai/sinyukha_west | 3 | kingpost | 19 | -0.22 (-0.42…-0.09) | -35 (-74…-14) | 4 |
| analytic | altai/sinyukha_west | 3 | topless | 15 | -0.05 (-0.24…+0.09) | -10 (-43…+16) | 0 |
| analytic | altai/sinyukha_west | 6 | soviet | 3 | -0.05 (-0.55…+0.25) | +2 (-53…+45) | 2 |
| analytic | altai/sinyukha_west | 6 | trainer | 11 | +0.23 (+0.04…+0.35) | +40 (+8…+63) | 1 |
| analytic | altai/sinyukha_west | 6 | kingpost | 19 | +0.36 (+0.22…+0.56) | +38 (+6…+85) | 10 |
| analytic | altai/sinyukha_west | 6 | topless | 15 | +0.34 (-0.21…+0.66) | +63 (-24…+119) | 2 |
| analytic | askarovo/biyagoda_west | 3 | soviet | 3 | -1.19 (-1.23…-1.13) | -85 (-95…-75) | 3 |
| analytic | askarovo/biyagoda_west | 3 | trainer | 11 | -0.79 (-1.11…-0.47) | -78 (-90…-63) | 10 |
| analytic | askarovo/biyagoda_west | 3 | kingpost | 19 | -0.78 (-1.03…-0.36) | -68 (-80…-57) | 18 |
| analytic | askarovo/biyagoda_west | 3 | topless | 15 | -0.56 (-0.68…-0.33) | -76 (-103…-59) | 14 |
| analytic | askarovo/biyagoda_west | 6 | soviet | 3 | +0.36 (+0.35…+0.39) | +61 (+50…+69) | 1 |
| analytic | askarovo/biyagoda_west | 6 | trainer | 11 | +0.43 (+0.37…+0.50) | +76 (+49…+89) | 1 |
| analytic | askarovo/biyagoda_west | 6 | kingpost | 19 | +0.48 (+0.27…+0.56) | +86 (+47…+100) | 1 |
| analytic | askarovo/biyagoda_west | 6 | topless | 15 | +0.48 (+0.11…+1.03) | +73 (+15…+132) | 5 |
| analytic | aushkul/aushtau_east | 3 | soviet | 3 | -0.41 (-0.49…-0.34) | -14 (-29…-6) | 3 |
| analytic | aushkul/aushtau_east | 3 | trainer | 11 | -0.10 (-0.28…+0.10) | -1 (-6…+18) | 10 |
| analytic | aushkul/aushtau_east | 3 | kingpost | 19 | -0.18 (-0.25…+0.03) | -3 (-4…+1) | 19 |
| analytic | aushkul/aushtau_east | 3 | topless | 15 | -0.01 (-0.03…+0.02) | -0 (-0…+0) | 15 |
| analytic | aushkul/aushtau_east | 6 | soviet | 3 | +1.29 (+1.17…+1.36) | +20 (+19…+22) | 3 |
| analytic | aushkul/aushtau_east | 6 | trainer | 11 | +0.65 (-0.14…+1.51) | +33 (-16…+70) | 6 |
| analytic | aushkul/aushtau_east | 6 | kingpost | 19 | +0.35 (-0.05…+0.52) | +62 (-9…+94) | 2 |
| analytic | aushkul/aushtau_east | 6 | topless | 15 | +0.34 (-0.01…+0.50) | +61 (-1…+90) | 2 |
| analytic | ongudai/kayancha_south | 3 | soviet | 3 | -1.18 (-1.33…-1.02) | -85 (-87…-83) | 3 |
| analytic | ongudai/kayancha_south | 3 | trainer | 11 | -0.63 (-0.87…-0.49) | -74 (-82…-66) | 11 |
| analytic | ongudai/kayancha_south | 3 | kingpost | 19 | -0.50 (-0.62…-0.24) | -67 (-82…-43) | 18 |
| analytic | ongudai/kayancha_south | 3 | topless | 15 | -0.31 (-0.38…-0.25) | -54 (-62…-46) | 2 |
| analytic | ongudai/kayancha_south | 6 | soviet | 3 | -0.05 (-0.15…+0.04) | -8 (-28…+7) | 0 |
| analytic | ongudai/kayancha_south | 6 | trainer | 11 | -0.06 (-0.13…+0.05) | -10 (-24…+8) | 0 |
| analytic | ongudai/kayancha_south | 6 | kingpost | 19 | +0.05 (-0.75…+0.26) | +13 (-43…+46) | 1 |
| analytic | ongudai/kayancha_south | 6 | topless | 15 | +0.09 (-0.33…+0.19) | +18 (-43…+35) | 1 |
| field | altai/sinyukha_west | 3 | soviet | 1 | -0.02 (-0.02…-0.02) | -0 (-0…-0) | 1 |
| field | altai/sinyukha_west | 3 | trainer | 1 | -0.10 (-0.10…-0.10) | -6 (-6…-6) | 1 |
| field | altai/sinyukha_west | 3 | kingpost | 1 | +0.13 (+0.13…+0.13) | +8 (+8…+8) | 1 |
| field | altai/sinyukha_west | 3 | topless | 1 | +0.01 (+0.01…+0.01) | +2 (+2…+2) | 1 |
| field | altai/sinyukha_west | 6 | soviet | 1 | +0.23 (+0.23…+0.23) | +13 (+13…+13) | 1 |
| field | altai/sinyukha_west | 6 | trainer | 1 | -0.10 (-0.10…-0.10) | -9 (-9…-9) | 1 |
| field | altai/sinyukha_west | 6 | kingpost | 1 | -0.32 (-0.32…-0.32) | -17 (-17…-17) | 1 |
| field | altai/sinyukha_west | 6 | topless | 1 | -0.15 (-0.15…-0.15) | -8 (-8…-8) | 1 |
| field | askarovo/biyagoda_west | 3 | soviet | 1 | -0.53 (-0.53…-0.53) | -9 (-9…-9) | 1 |
| field | askarovo/biyagoda_west | 3 | trainer | 1 | +0.01 (+0.01…+0.01) | +2 (+2…+2) | 1 |
| field | askarovo/biyagoda_west | 3 | kingpost | 1 | +0.07 (+0.07…+0.07) | +12 (+12…+12) | 0 |
| field | askarovo/biyagoda_west | 3 | topless | 1 | +0.06 (+0.06…+0.06) | +10 (+10…+10) | 0 |
| field | askarovo/biyagoda_west | 6 | soviet | 1 | -0.16 (-0.16…-0.16) | -5 (-5…-5) | 1 |
| field | askarovo/biyagoda_west | 6 | trainer | 1 | -0.16 (-0.16…-0.16) | -8 (-8…-8) | 1 |
| field | askarovo/biyagoda_west | 6 | kingpost | 1 | -0.12 (-0.12…-0.12) | -6 (-6…-6) | 1 |
| field | askarovo/biyagoda_west | 6 | topless | 1 | -0.04 (-0.04…-0.04) | -2 (-2…-2) | 1 |
| field | aushkul/aushtau_east | 3 | soviet | 1 | -0.12 (-0.12…-0.12) | -10 (-10…-10) | 1 |
| field | aushkul/aushtau_east | 3 | trainer | 1 | +0.02 (+0.02…+0.02) | +3 (+3…+3) | 1 |
| field | aushkul/aushtau_east | 3 | kingpost | 1 | +0.25 (+0.25…+0.25) | +45 (+45…+45) | 0 |
| field | aushkul/aushtau_east | 3 | topless | 1 | +0.31 (+0.31…+0.31) | +55 (+55…+55) | 0 |
| field | aushkul/aushtau_east | 6 | soviet | 1 | +0.61 (+0.61…+0.61) | +20 (+20…+20) | 1 |
| field | aushkul/aushtau_east | 6 | trainer | 1 | +0.31 (+0.31…+0.31) | +17 (+17…+17) | 1 |
| field | aushkul/aushtau_east | 6 | kingpost | 1 | +0.36 (+0.36…+0.36) | +20 (+20…+20) | 1 |
| field | aushkul/aushtau_east | 6 | topless | 1 | +0.26 (+0.26…+0.26) | +17 (+17…+17) | 1 |
| field | ongudai/kayancha_south | 3 | soviet | 1 | -1.19 (-1.19…-1.19) | -51 (-51…-51) | 1 |
| field | ongudai/kayancha_south | 3 | trainer | 1 | -0.73 (-0.73…-0.73) | -57 (-57…-57) | 1 |
| field | ongudai/kayancha_south | 3 | kingpost | 1 | -0.77 (-0.77…-0.77) | -48 (-48…-48) | 1 |
| field | ongudai/kayancha_south | 3 | topless | 1 | -0.73 (-0.73…-0.73) | -45 (-45…-45) | 1 |
| field | ongudai/kayancha_south | 6 | soviet | 1 | -1.07 (-1.07…-1.07) | -32 (-32…-32) | 1 |
| field | ongudai/kayancha_south | 6 | trainer | 1 | -0.08 (-0.08…-0.08) | -3 (-3…-3) | 1 |
| field | ongudai/kayancha_south | 6 | kingpost | 1 | -0.15 (-0.15…-0.15) | -6 (-6…-6) | 1 |
| field | ongudai/kayancha_south | 6 | topless | 1 | -0.06 (-0.06…-0.06) | -2 (-2…-2) | 1 |

## Разброс за окно (СКО, болтанка): 4 крыла (slavutich_ut, training, laminar, combat)

СКО отсчётов 10 Гц за окно усреднения (до 30 с); турбулентность включена в обоих режимах. «σ среднего» ≈ СКО·√(τ/T) — оценка ошибки среднего при времени корреляции τ ≈ 3 с и окне T = 30 с (≈ 0,32·СКО).

| режим | серия | ветер, м/с | трапеция | строк | путевая, м/с (ср.) | СКО путевой | СКО воздушной | СКО vz | СКО w воздуха |
|---|---|---|---|---|---|---|---|---|---|
| analytic | penetration | 3 | 0 | 48 | +5.5 | 0.98 | 0.83 | 0.94 | 0.65 |
| analytic | penetration | 3 | -0.5 | 48 | +11.7 | 0.89 | 0.89 | 0.63 | 0.55 |
| analytic | penetration | 3 | -1 | 48 | +17.8 | 0.61 | 0.91 | 0.54 | 0.61 |
| analytic | penetration | 6 | 0 | 48 | +0.2 | 3.29 | 2.96 | 3.32 | 1.34 |
| analytic | penetration | 6 | -0.5 | 48 | +3.8 | 1.97 | 2.19 | 1.59 | 1.41 |
| analytic | penetration | 6 | -1 | 48 | +9.8 | 1.65 | 2.22 | 1.38 | 1.44 |
| analytic | ridge | 3 | 0 | 16 | -2.4 | 6.58 | 0.96 | 0.89 | 0.46 |
| analytic | ridge | 6 | 0 | 16 | -1.2 | 3.90 | 2.68 | 2.96 | 1.35 |
| field | penetration | 3 | 0 | 48 | +4.9 | 0.90 | 0.53 | 0.91 | 0.80 |
| field | penetration | 3 | -0.5 | 48 | +12.2 | 1.07 | 0.81 | 1.01 | 1.00 |
| field | penetration | 3 | -1 | 48 | +18.3 | 1.23 | 0.97 | 0.91 | 0.98 |
| field | penetration | 6 | 0 | 48 | -1.7 | 1.73 | 0.94 | 1.29 | 0.98 |
| field | penetration | 6 | -0.5 | 48 | +5.1 | 1.26 | 0.92 | 1.06 | 1.10 |
| field | penetration | 6 | -1 | 48 | +12.2 | 1.31 | 1.03 | 1.02 | 1.15 |
| field | ridge | 3 | 0 | 16 | -1.8 | 6.08 | 0.64 | 0.79 | 0.62 |
| field | ridge | 6 | 0 | 16 | -2.3 | 5.42 | 1.47 | 2.03 | 1.34 |
