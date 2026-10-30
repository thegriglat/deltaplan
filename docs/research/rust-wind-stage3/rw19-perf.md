---
type: "research"
status: "active"
module: "rust-wind"
area: "air"
updated: "2026-10-30"
summary: "RW-19: multiversion (avx2+fma) на 15 горячих функций dp-air, итераторы вместо индексов; замер step_cost 3041 до/после."
conclusion: "Шаг воздуха 3041² не изменился в пределах шума: полный прогон 1000 с — 42,13/41,73 до и 41,83/41,93 мс/игр.с после (порог 45 держится при load 7-12); короткий 60 с — медиана 27,25 до и 27,72 после. Выигрыш не виден: время уходит в пересчёт окон поля (раз в ~66 с, секунды, это picard_rs), а не в циклы выборки dp-air."
data: "examples/step_cost.rs"
applied_in: ""
related: ["docs/research/rust-wind-stage3/rw12z.md"]
---

# RW-19: multiversion и итераторы в горячих циклах dp-air

## Что сделано
`#[cfg_attr(target_arch = "x86_64", multiversion::multiversion(targets("x86_64+avx2+fma")))]`, как в picard_rs, на функциях-пачках (не на функциях одной точки). Атрибут не работает на методах с `self`, поэтому тела циклов вынесены в свободные функции:
`wind_field`: `sample_chunk`, `scalar_chunk`, `limit_chunk`, `box_row`; `field_set`: `sample_chunk`; `level`: `row`, `nest_row`, `shift_plane`; `formula`: `sample_points`; `clouds`: `density_batch`; `surface_gust`: `gust_batch`; `thermal_air/columns`: `cols_band`; `thermal_src`: `strength_row`; `phase/classifier`: `phase_fractions`.
Циклы по индексу в этих местах заменены на `zip`/`iter_mut`/`chunks_exact`. unsafe нет. target-cpu не менялся. Windows-DLL (`x86_64-pc-windows-gnu`) собирается.

## Замер step_cost, n=3041, 60 игр. с, под `lock cpu` (18 слотов), 3 пары подряд
| прогон | до, мс/игр.с | после, мс/игр.с |
|---|---|---|
| 1 | 28,02 | 27,40 |
| 2 | 26,75 | 27,72 |
| 3 | 27,25 | 28,84 |
| медиана | 27,25 | 27,72 |

Отношение после/до = 1,017 (шум). Load average во время замера 38-49 (другие агенты на машине): абсолютные значения приблизительны. «До» собрано до синхронизации с feature/rust-wind, «после» — после неё.

## Полный прогон (acceptance step_cost, 1000 игр. с), `lock cpu`, по 2 раза
| до | после |
|---|---|
| 42,13 (load 7,2) | 41,83 (load 7,7) |
| 41,73 (load 10,6) | 41,93 (load 12,1) |

60-секундные прогоны выше не захватывают пересчёты окон (первый на 66,7 с), поэтому дают 27 мс: стоимость шага без решателя. Приёмка step_cost_3041 при load 30+ дала 122,9 (решатель Пикара конкурирует за ядра с другими задачами), на тихой машине — 42.

## Границы
Не тронуты (методы `&self`/`&mut self` с телом цикла): шаг облаков (`clouds/field.rs`), `build` волн и земли, сборка кейса и фазы при загрузке места. Выигрыш там не измерен.
