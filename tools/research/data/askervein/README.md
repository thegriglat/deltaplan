---
type: "research"
status: "closed"
module: ""
updated: "2026-09-29"
summary: "Askervein Hill — данные измерений — Поле измерений на холме Askervein (о. Южный Уист, Шотландия), сентябрь–октябрь 1982–1983: классический эталон обтекания изолированного пологого холма (H ≈ 116 м над окружающей местностью, нейтральная атмосфера, ветер ~210°)."
related: []
conclusion: ""
data: "tools/research/data/askervein/"
applied_in: ""
---
# Askervein Hill — данные измерений

Поле измерений на холме Askervein (о. Южный Уист, Шотландия), сентябрь–октябрь 1982–1983: классический эталон обтекания изолированного пологого холма (H ≈ 116 м над окружающей местностью, нейтральная атмосфера, ветер ~210°).

## Файлы
| Файл | Что | Источник, лицензия |
|---|---|---|
| `askervein_validation1.txt` | измерения по мачтам (линии A, AA, B, вершина HT, CP, эталон RS): координаты, высота над землёй, скорость S, TKE, **FSR** — относительный разгон ΔS/S_ref (fractional speed-up ratio) с min/max, TKE* | Zenodo 4095052 (IEA-Wind Task 31 Wakebench / WEMEP), оцифровано из отчётов Taylor & Teunissen 1983/1985; CC BY 4.0 |
| `askervein_inlet1.txt` | набегающий профиль на эталонной мачте RS | то же |
| `askervein_sensor1.txt` | список датчиков | то же |
| `askervein_elevation-roughness.map` | рельеф и шероховатость (формат WAsP .map) | то же |
| `ASK83.pdf` | *не в git* (36 МБ): исходный отчёт — Taylor P.A., Teunissen H.W. «The Askervein Hill Project: Report on the Sept./Oct. 1983 main field experiment», Tech. Rep. MSRB-84-6, AES Canada, 1985 | https://www.yorku.ca/pat/research/Askervein/ASK83.pdf (скачивается без авторизации; `curl -LO`) |

Цитировать: Taylor & Teunissen 1987, «The Askervein Hill Project: Overview and background data», Boundary-Layer Meteorol. 39:15–39; данные — Zenodo https://zenodo.org/records/4095052 (CC BY 4.0); описание бенчмарка — https://wemep.readthedocs.io/en/latest/windconditions/benchmarks/askervein.html.

Скачать заново: `for f in askervein_sensor1.txt askervein_elevation-roughness.map askervein_validation1.txt askervein_inlet1.txt; do curl -sL -o $f https://zenodo.org/api/records/4095052/files/$f/content; done`.

Для калибровки (docs/plan/wind_field.md WF-16, docs/research/calibration_data.md): FSR на вершине на 10 м ≈ 0,8; профиль разгона по высоте на вершине; FSR вдоль линий A и AA через холм — эталон формы и затухания разгона с высотой.
