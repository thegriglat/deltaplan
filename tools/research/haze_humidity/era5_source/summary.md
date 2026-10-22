---
type: "research"
status: "closed"
module: "haze-humidity"
updated: "2026-10-23"
summary: "HH-17: остаток ERA5 качать из ARCO-1° почасового; T700 RMSE к CDS 0.09 K, u700 0.19 м/с, T2m max 0.52 K; NCAR и ARCO-0.25° не нужны"
conclusion: "ARCO-ERA5 1° — источник для остатка"
data: "tools/research/haze_humidity/era5_source/result.json"
applied_in: []
related: ["tools/research/haze_humidity/era5_source/README.md"]
---
# Вывод HH-17
ARCO-ERA5 1° (почасовой, консервативный пересчёт) — быстрый источник: T2m 4 МБ/сутки, 3D 145-194 МБ/сутки, 2-6 МБ/с, без очереди.
Сверка с CDS daily-statistics: T700 RMSE 0.087 K, u700 0.19 м/с, T2m max 0.52 K (береговые ячейки до 11 K). Докачка проверена (kill -9, 40 % обрывов — побитово).
NCAR S3: 0.3-0.5 МБ/с, чанк 1 ч×37 ур.×0.25° (53 МБ); ARCO 0.25°: 85 МБ/час — в 10-60x тяжелее. Подробности — README.md, result.json.
