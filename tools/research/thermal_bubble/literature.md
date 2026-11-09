---
type: "research"
status: "active"
module: "thermal-bubble"
area: "air"
updated: "2026-11-09"
summary: "Эталоны сверки TB3 для семи величин термика: числа, диапазоны, источники, надёжность; без источника — пусто, без выдумок."
related: ["docs/plan/thermal-bubble.md", "docs/contracts/thermal-bubble.md", "docs/research/calibration_data/thermals.md", "docs/guide/air-model/thermals.md"]
conclusion: "Из литературы с числом в руках: профиль Lenschow–Stephens (макс. ŵ 0,45 w*), диаметр, доля ядер; приток, растекание, кольцо и скорость подъёма пузыря — нет подтверждённых чисел."
data: "tools/research/thermal_bubble/current.py"
applied_in: []
---
# Эталоны сверки термика (TB-2a)

Правило: число в таблице — только если оно взято из источника, который прочитан (в этом репозитории
или по тексту, найденному поиском). Веб-поиск 2026-11-09 дал лишь библиографию и аннотации
(Schmidt & Schumann 1989, Young 1988, Lenschow & Stephens 1980 — без таблиц и рисунков), поэтому
по LES-величинам чисел нет: **не нашлось — так и записано** (`—`), TB-2b ставит `null`.
Полные тексты (Springer/Cambridge/AMS) за подпиской; снять числа с рисунков — отдельная задача
для человека с доступом.

Уже известное, не переделывалось: [calibration_data/thermals.md](../../../docs/research/calibration_data/thermals.md)
(макс. ŵ ≈ 0,45 w*, медиана w* 2,56 м/с, z_i 1400 м); законы игры — [thermals.md](../../../docs/guide/air-model/thermals.md).

## Таблица эталонов (имена quantity — как в TB3)

| quantity | значение | диапазон | где измерено | источник | надёжность | z/zi |
|---|---|---|---|---|---|---|
| w_core_max_over_wstar | средний подъём термика ŵ_max = 0,45 (условная выборка, усреднение по термику); пик ядра 1–2 | ŵ: 0,45; ядро: 1–2 | самолёт NCAR Electra над морем (AMTEX), термики по влажности | Lenschow & Stephens 1980, Boundary-Layer Meteorol. 19:509–532 (формула ŵ/w* = (z/zi)^⅓(1−1,1 z/zi), как её приводят [thermals.md](../../../docs/research/calibration_data/thermals.md) и Allen 2006); «ядра 1–2 w*» — по пересказу [thermals.md](../../../docs/guide/air-model/thermals.md) (L&S 1980; Young 1988), оригиналы рисунков не читали | high для 0,45 (средний подъём); low для 1–2 (из пересказа) | 0,25 (макс. ŵ); 0 при 0,91 |
| core_radius_over_zi | диаметр d/zi = 0,16 (z/zi)^⅓(1−0,25 z/zi); радиус = d/2 | d/zi: 0,072 (z=0,1), 0,111 (0,5), 0,120 (0,9) | тот же набор, что выше | Lenschow & Stephens 1980; Allen 2006, AIAA 2006-1510 (r₂ = 0,102 ζ^⅓(1−0,25ζ) z_l; у верха R = 0,0765 z_l) | high (подгонка по измерениям над морем; над сушей и горами шире — оценка не проверена) | 0,1…0,9; радиус у верха при ζ = 1 |
| rise_speed_over_wstar | — (не нашлось) | — | — | Скорость подъёма самого термика как целого (по траектории) в поиске не получена. Косвенно: Allen/L&S дают скорость воздуха в ядре, не скорость фронта пузыря; лабораторная теория (Scorer 1957; Turner 1973 — вовлечение α ≈ 0,1–0,25) числа не прочитаны | low (число не взято) | — |
| inflow_ground_over_wstar | — (не нашлось) | — | LES: Schmidt & Schumann 1989 JFM 200:511–562 показывают «спицы» (радиальное втекание в нижней части слоя к крупным апдрафтам), но число притока в доступном тексте не найдено | Schmidt & Schumann 1989; Moeng & Sullivan 1994; Sullivan et al. 1998 — тексты не прочитаны | low (качественно есть, количественно нет) | у земли, < 0,1 |
| outflow_top_over_wstar | — (не нашлось) | — | LES: растекание под инверсией отмечено (Schmidt & Schumann 1989, средняя циркуляция охватывает весь слой), числа нет | то же | low (качественно) | 0,9…1,1 |
| ring_sink_min_over_wstar | — (не нашлось) | — | Окружающее опускание: в нынешней модели кольцо Гедеона × 1,6 (`ring_sink_factor`, подбор игры, не литература). Young 1988 (JAS 45:727–735; ч. III — бюджеты апдрафтов и downdraft окружения) даёт, но числа не прочитаны | Young 1988; Schumann & Moeng 1991 (классификация апдрафт/даундрафт по w) | low | 0,3…0,8 |
| updraft_area_fraction | 0,3–0,4 (воздух подъёма); ядра Аллена ≈ 0,13 | 0,3–0,4; ядра 0,13 | самолёт (L&S 1980; Stull 1988 гл. 4) — по пересказу в [thermals.md](../../../docs/guide/air-model/thermals.md) AM-07б; ядра: Allen 2006 | Lenschow & Stephens 1980; Stull 1988 (учебник), гл. 4; Allen 2006 (n_A = 0,6/(z_l r₂(½)); доля ≈ 0,13) | medium (пересказ из документации проекта; рисунок L&S не сверен) | середина слоя |

## Профили в ядре (для сверки формы)

| Величина | Формула / число | Источник | Надёжность |
|---|---|---|---|
| w по высоте (средний в термике) | ŵ/w* = (z/zi)^⅓(1 − 1,1 z/zi), макс. 0,45 при z ≈ 0,25 zi, ноль при 0,91 zi | Lenschow & Stephens 1980; Allen 2006 | high |
| Радиус от высоты | r(ζ) = z_l·0,102 ζ^⅓(1−0,25ζ) (r(1) = 0,0765 z_l) | Allen 2006 | high (по самолёту) |
| w по радиусу (нынешняя модель) | Гедеон (1−x²)e^(−x²), x = d/r; кольцо × 1,6 | `rust/dp-air/src/terms/thermal/profile.rs`; Allen 2006 | форма игры, не измерение |
| Пульсации | σ_w²/w*² = 1,8 (z/zi)^{2/3}(1−0,8 z/zi)², макс. σ_w ≈ 0,6 w* при z ≈ 0,3 zi (±15 %) | Lenschow, Wyngaard, Pennell 1980, JAS 37:1313–1326 | medium |
| Сила ядра игры | w0 = 1,24 w* (пик Гедеона при том же потоке); пик Аллена ≈ 1,0 w* | [thermals.md](../../../docs/guide/air-model/thermals.md), «Законы» | model |
| Пузырь, вовлечение | α (радиуса) 0,1–0,25 из лабораторных термиков | Scorer 1957; Turner 1973 (из памяти, не сверено) | low |

## Что это значит для TB-2b

- Твёрдые эталоны есть для `core_radius_over_zi`, профиля ŵ и `updraft_area_fraction`; для
  `w_core_max_over_wstar` — по среднему (0,45), для пика ядра 1–2 w* — слабо.
- `rise_speed`, `inflow_ground`, `outflow_top`, `ring_sink_min`: литературных чисел нет; в compare.json — `null`
  и причина в `note`. Брать их из LES нельзя без чтения оригиналов (или собственного LES).
- Для этих четырёх величин сверка пузыря с нынешним профилем — только качественная (знак, форма), не количественная.

## Источники

- Lenschow D.H., Stephens P.L., 1980, Boundary-Layer Meteorol. 19:509–532, doi:10.1007/bf00122351.
- Lenschow D.H., Wyngaard J.C., Pennell W.T., 1980, J. Atmos. Sci. 37:1313–1326.
- Young G.S., 1988, J. Atmos. Sci. 45:727–735 (ч. II), ч. III там же; https://personal.ems.psu.edu/~young/hp/abstract/jas1988b.htm (аннотация).
- Schmidt H., Schumann U., 1989, J. Fluid Mech. 200:511–562, doi:10.1017/S0022112089000753.
- Schumann U., Moeng C.-H., 1991, J. Atmos. Sci. (классификация апдрафт/даундрафт; https://elib.dlr.de/31447).
- Moeng C.-H., Sullivan P.P., 1994, J. Atmos. Sci. 51:999–1022; Sullivan P.P. et al., 1998 — не читались.
- Allen M.J., 2006, AIAA 2006-1510, https://ntrs.nasa.gov/citations/20060004052 (открытый доступ).
- Stull R.B., 1988, An Introduction to Boundary Layer Meteorology, гл. 4. Scorer R.S., 1957; Turner J.S., 1973 — из памяти.
- Лицензии данных: чисел из закрытых текстов не копировалось; формулы — факты, цитируются со ссылкой.
