# Умолчания классов на всех крыльях (PD-12, прототип)

min / медиана / max по крыльям класса. rev45 — перекладка 45->45, с (nan — 45° не достигается полным смещением: исключены из статистики, перечислены); phi10/phi20 — крен через 10/20 с после «в центр» из виража 30°; F30 — усилие рук в вираже 30°, Н (минус — держать против спирали).

| класс | крыльев | rev45, с | phi10, ° | phi20, ° | F30, Н |
|---|---|---|---|---|---|
| trainer | 11 | 3.3 / 4.0 / 4.9 | 19.3 / 29.6 / 30.4 | 10.4 / 26.9 / 29.7 | -24.9 / -13.3 / -5.5 |
| kingpost | 19 | 3.0 / 3.5 / 4.4 | 39.1 / 44.9 / 65.5 | 44.4 / 51.1 / 65.2 | -71.9 / -42.4 / -22.7 |
| topless | 15 | 3.1 / 3.5 / 3.9 | 43.3 / 48.1 / 52.4 | 49.3 / 53.6 / 57.8 | -52.0 / -26.9 / -9.0 |
| soviet | 3 | 3.4 / 3.7 / 4.3 | 18.2 / 19.9 / 31.4 | 8.7 / 12.1 / 32.6 | -17.7 / -5.9 / -5.7 |

Крылья без перекладки 45° или с ошибкой счёта:

- condor_flex (trainer): 45° полным смещением не достигается за 12 с
- fs_space (trainer): 45° полным смещением не достигается за 12 с

| крыло | класс | rev45 | phi10 | phi20 | F30 |
|---|---|---|---|---|---|
| aeros_discus | kingpost | 3.2 | 49 | 55 | -53 |
| air_sting3 | kingpost | 3.2 | 43 | 49 | -36 |
| bautek_astir | kingpost | 3.7 | 65 | 64 | -72 |
| bautek_fizz | kingpost | 3.5 | 49 | 56 | -54 |
| bautek_kite | kingpost | 3.3 | 66 | 65 | -68 |
| fs_crossover | kingpost | 3.7 | 45 | 51 | -42 |
| icaro_alto | kingpost | 3.4 | 41 | 48 | -25 |
| icaro_mastr | kingpost | 3.4 | 49 | 55 | -46 |
| laminar | kingpost | 4.4 | 45 | 51 | -32 |
| magic | kingpost | 4.4 | 41 | 47 | -36 |
| moyes_gecko | kingpost | 3.9 | 45 | 51 | -23 |
| moyes_litesport | kingpost | 3.3 | 48 | 54 | -67 |
| seed_skyrunner_xr | kingpost | 3.7 | 43 | 50 | -33 |
| ww_cross_country | kingpost | 4.2 | 39 | 44 | -32 |
| ww_eagle | kingpost | 3.7 | 39 | 44 | -31 |
| ww_sport3 | kingpost | 3.0 | 60 | 65 | -50 |
| ww_super_sport | kingpost | 3.5 | 44 | 50 | -43 |
| ww_u2 | kingpost | 3.0 | 49 | 56 | -42 |
| ww_ultra_sport | kingpost | 3.4 | 44 | 50 | -47 |
| apogee | soviet | 4.3 | 20 | 12 | -6 |
| atlas | soviet | 3.4 | 31 | 33 | -18 |
| slavutich_ut | soviet | 3.7 | 18 | 9 | -6 |
| aeros_combat_c | topless | 3.3 | 48 | 55 | -49 |
| aeros_combat_l | topless | 3.7 | 48 | 53 | -27 |
| air_c4 | topless | 3.6 | 49 | 55 | -22 |
| air_rev | topless | 3.5 | 49 | 55 | -25 |
| combat | topless | 3.6 | 48 | 54 | -25 |
| dp_she1 | topless | 3.1 | 44 | 49 | -13 |
| icaro_laminar_z9 | topless | 3.4 | 51 | 58 | -48 |
| moyes_litespeed_rx | topless | 3.6 | 46 | 53 | -32 |
| moyes_litespeed_s | topless | 3.3 | 52 | 58 | -27 |
| seed_spyder | topless | 3.3 | 44 | 50 | -18 |
| sport | topless | 3.9 | 47 | 52 | -32 |
| ww_fusion | topless | 3.7 | 43 | 50 | -9 |
| ww_t2c | topless | 3.1 | 50 | 57 | -52 |
| ww_t3 | topless | 3.5 | 47 | 54 | -41 |
| ww_talon | topless | 3.9 | 44 | 51 | -23 |
| aeros_fox | trainer | 3.5 | 19 | 10 | -10 |
| air_f2 | trainer | 4.9 | 30 | 28 | -20 |
| condor_crex3 | trainer | 3.3 | 24 | 19 | -5 |
| condor_flex | trainer | — | 30 | 30 | -10 |
| fs_funky | trainer | 4.0 | 30 | 30 | -16 |
| fs_space | trainer | — | 30 | 29 | -25 |
| icaro_piuma | trainer | 3.6 | 28 | 24 | -13 |
| moyes_malibu2 | trainer | 3.9 | 30 | 27 | -13 |
| target | trainer | 4.6 | 20 | 12 | -13 |
| training | trainer | 4.4 | 28 | 26 | -13 |
| ww_spectrum | trainer | 4.7 | 30 | 28 | -24 |
