Машина: Intel(R) Xeon(R) CPU E5-2666 v3 @ 2.90GHz (20 потоков), NVIDIA GeForce RTX 4070 SUPER.

| Метод | Окно, м | n_points | Стадия | Потоки | tol | t, с | Части, с |
|---|---|---|---|---|---|---|---|
| panels | 50 | 458752 | cold | — | — | 192.7 | assemble 3.4, gpu_init 0.3, lu 9.5, mesh 0.1, query_jh 179.1, solve 0.1, terrain 0.1 |
| panels | 50 | 458752 | wind_change | — | — | 190.8 | query_jh 190.6, solve 0.1 |
| panels | 100 | 253952 | cold | — | — | 121.8 | assemble 3.5, gpu_init 0.3, lu 8.4, mesh 0.1, query_jh 108.0, solve 0.2, terrain 0.1 |
| panels | 100 | 253952 | wind_change | — | — | 93.8 | query_jh 93.7, solve 0.1 |
| panels_rotor | 50 | 458752 | cold | — | — | 490.7 | assemble 4.7, gpu_init 0.4, lu 14.7, mesh 0.1, query_jh 425.6, rotor 44.5, solve 0.2, terrain 0.1 |
| panels_rotor | 50 | 458752 | wind_change | — | — | 381.7 | query_jh 347.8, rotor 33.8, solve 0.1 |
| panels_rotor | 100 | 253952 | cold | — | — | 198.0 | assemble 2.7, gpu_init 0.3, lu 7.0, mesh 0.1, query_jh 177.4, rotor 10.7, solve 0.1, terrain 0.1 |
| panels_rotor | 100 | 253952 | wind_change | — | — | 214.2 | query_jh 187.5, rotor 16.3, solve 0.1 |
| picard | 50 | 458752 | cold | 2 | 1.0 | 30.9 | bc_start 0.1, solve 30.7 |
| picard | 50 | 458752 | cold | 2 | 5.0 | 16.7 | bc_start 0.1, solve 16.6 |
| picard | 50 | 458752 | cold | 8 | 1.0 | 11.0 | solve 10.9 |
| picard | 50 | 458752 | cold | 8 | 5.0 | 6.2 | solve 6.1 |
| picard | 50 | 458752 | wind_change | 2 | 1.0 | 65.2 | bc_start 0.1, solve 65.0 |
| picard | 50 | 458752 | wind_change | 2 | 5.0 | 36.1 | bc_start 0.1, solve 36.0 |
| picard | 50 | 458752 | wind_change | 8 | 1.0 | 22.5 | solve 22.5 |
| picard | 50 | 458752 | wind_change | 8 | 5.0 | 13.8 | solve 13.7 |
| picard | 100 | 253952 | cold | 2 | 1.0 | 12.2 | bc_start 0.1, solve 12.1 |
| picard | 100 | 253952 | cold | 2 | 5.0 | 7.8 | bc_start 0.1, solve 7.7 |
| picard | 100 | 253952 | cold | 8 | 1.0 | 4.4 | solve 4.3 |
| picard | 100 | 253952 | cold | 8 | 5.0 | 3.1 | solve 3.0 |
| picard | 100 | 253952 | wind_change | 2 | 1.0 | 15.4 | bc_start 0.1, solve 15.3 |
| picard | 100 | 253952 | wind_change | 2 | 5.0 | 9.1 | bc_start 0.1, solve 9.0 |
| picard | 100 | 253952 | wind_change | 8 | 1.0 | 5.3 | solve 5.3 |
| picard | 100 | 253952 | wind_change | 8 | 5.0 | 3.4 | solve 3.4 |
