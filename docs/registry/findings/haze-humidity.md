---
type: "registry"
status: "active"
module: "haze-humidity"
area: "world"
updated: "2026-10-23"
summary: "Выводы haze-humidity (вынесены из findings.md по размеру): Td, дымка, облака, верхний воздух, Tmax, рост ветра, закат."
related: ["docs/registry/findings.md"]
---
# Выводы haze-humidity

- **Td по месту, ERA5 1991–2020**: Алтай июль 14,3 °C против таблицы 9 (+5,3 К, кромка ≈ −640 м); градиент по высоте −4,0 К/км (круче теории −1,7) — [dew_point](/tools/research/haze_humidity/dew_point/README.md#поправка-на-высоту)
- **Td дня против облачности** (2011–2013): ясный суше на 0,28 σ, пасмурный влажнее на 0,13 σ; β 0,6 К/К, от −0,3 до 1,0 по поясу — нужны таблицы — [td_sky](/tools/research/haze_humidity/td_sky/README.md#критерий-единого-значения-и-вывод)
- **Дымка**: f(85 %) ≈ 2,3, γ = 0,6 (0,45–0,74); вечерняя добавка ×1,6 из RH не следует — убрана — [haze](/tools/research/haze_humidity/haze/README.md#предложение)
- **Свет облаков**: таблица 64×64 за 48 мс; GPU-кадр не измерен — [frame_cost](/tools/research/haze_humidity/sun_transmission/frame_cost.md#cpu-цена-таблицы); основание base/top 0,24–0,5 в вилке 0,22–0,66 (Cu), 0,10–0,39 (Cb) — [cloud_base](/tools/research/haze_humidity/cloud_base/README.md#вердикт)
- **Верхний воздух (HH-1f)**: тропопауза 10,6 км (Алтай), 16,5 (Дараб, Кэрнс) против 11 000 м; HCC 0,29–0,39 против `cirrus_base` 0,1; k_sky 0,12–0,35 / 0,48–0,93 / 1,2–2,4 — [upper_misc](/tools/research/haze_humidity/upper_misc/README.md)
- **Сверка с Open-Meteo** (38 мест): в σ Td 67 % (ДИ 59–75), сдвиг +0,72 К; Иран — сетка влажнее на 2,4 К — [verify](/tools/research/haze_humidity/verify/README.md#итог-числа--summaryjson-placescsv-places_summercsv-stationscsv)
- **Tmax и амплитуда ERA5 2011–2020**: TX −61,1…47,8 °C, DTR 0,45…20,4 К; Tmax падает на 5,5–7,8 К/км, амплитуда на 0–1,5 К/км — [surface_t](/tools/research/haze_humidity/surface_t/README.md#градиент-по-высоте-gradientpy-gradientjson)
- **Воздух 700 гПа ERA5**: Алтай на 1,2 °C холоднее таблицы, `z_dry` ≈ −200 м; σ T700 2,7–5,5 К (±10–15 %) — [upper_air](/tools/research/haze_humidity/upper_air/README.md); в σ прогноза 62–64 % дней, сдвиг +0,5 К — [verify](/tools/research/haze_humidity/verify/README.md)
- **Источник ERA5**: остаток — ARCO 1° почасовой (2–6 МБ/с, без очереди); T700 к CDS RMSE 0,087 К — [era5_source](/tools/research/haze_humidity/era5_source/README.md)
- **Яркость заката**: `sky_k` с ESRA ±3 % при ≥ 6°, при ≤ 4° ESRA выше на 9–49 %; экспозиция заката возвращает 2,3 из 3 ступеней — [sky_light](/tools/research/haze_humidity/sky_light/README.md#экспозиция-заката-eel-exposurepy)
- **Цвет облаков на закате**: таблица пропускания верна (спектр: 3–5 %); бока при 2° G/R 0,68, B/R 0,50 (было 1,00 / 1,13) — [sunset_color](/tools/research/haze_humidity/sunset_color/README.md)
- **Солнце у горизонта**: пятно ≈ 3,5 диаметра, ореол 6–7° вместо 21° — [sunset-light](/docs/guide/atmosphere/sunset-light.md)
- **Рост ветра с высотой (HH-1h, Q7)**: WR = |V700|/V10 по ERA5 2018–2019 (ARCO 1°, 723 из 730 суток): медиана 1,47–1,51, суша ≈ 1,6; в Алтае WR 3–6 (V10 на 1° в горах сглажен), погрешность двух лет ±15 %; поэтому gain считается от ветра на высоте старта, а не у земли — [upper_misc](/tools/research/haze_humidity/upper_misc/README.md), [contracts](/docs/contracts/haze-humidity.md)

