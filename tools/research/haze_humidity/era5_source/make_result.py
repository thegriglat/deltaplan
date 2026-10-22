"""Собирает result.json из замеров (b_totals.jsonl, bench_a.json, bench_ncar.json, diff_vs_cds.json, resume_test.log) и считает экстраполяции."""
import json, os
O = os.path.expanduser("~/data/haze_humidity/era5_source")
H = os.path.dirname(os.path.abspath(__file__))
tot = {(j["var"]): j for j in map(json.loads, open(f"{O}/b_totals.jsonl"))}
A = json.load(open(f"{O}/bench_a.json")); N = json.load(open(f"{O}/bench_ncar.json"))
diff = json.load(open(f"{H}/diff_vs_cds.json"))
t2, t7, u7 = tot["2m_temperature"], tot["temperature"], tot["u_component_of_wind"]
mb_day = {"t2m": t2["total_MB"] / t2["days_done"], "T700": t7["total_MB"] / t7["days_done"], "u700": u7["total_MB"] / u7["days_done"]}
rate = {"t2m": t2["total_MB"] / t2["total_s"], "T700": t7["total_MB"] / t7["total_s"], "u700": u7["total_MB"] / u7["total_s"]}
sday = {"t2m": t2["total_s"] / t2["days_done"], "T700": t7["total_s"] / t7["days_done"], "u700": u7["total_s"] / u7["days_done"]}
def job(var, days, mult=1):
    return {"days": days, "GB": round(mb_day[var] * days * mult / 1000, 1), "hours": round(sday[var] * days * mult / 3600, 1)}
vol = {
    "HH-1e_t2m_max_min_mean_2018-2019 (один проход даёт все три)": job("t2m", 730),
    "t2m_10_лет_2011-2020": job("t2m", 3652),
    "HH-1g_T700_daily_mean_2019": job("T700", 365),
    "u700+v700_daily_mean_за_год (v принят равным u по объёму)": job("u700", 365, 2),
    "u700+v700_daily_mean_2018-2020": job("u700", 1095, 2),
    "T700_10_лет": job("T700", 3652),
}
res = {
 "sources": {
  "B_ARCO_1deg": {"url": "gs://gcp-public-data-arco-era5/ar/1959-2022-1h-360x181_equiangular_with_poles_conservative.zarr", "access": "анонимно, zarr v2 + gcsfs",
     "grid": "360x181, 1°, консервативный пересчёт с 0.25°, почасовой, 37 уровней, оси [time, lon 0..359, lat -90..90]", "chunks": "t2m (8 ч,360,181) ~1.33 МБ; 3D (8 ч, 37 ур., 360,181) ~48 МБ сжатого (T), ~65 МБ (u)", "coverage": "1959-2022 (проверено 2018)"},
  "A_ARCO_0p25": {"url": "gs://gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3", "access": "анонимно, zarr, gcsfs", "grid": "721x1440, 0.25°, почасовой, чанк = 1 час (3D: 37 уровней)", "chunks": "t2m ~2.3 МБ/ч; 3D ~85 МБ/ч"},
  "NCAR_S3": {"url": "s3://nsf-ncar-era5 (e5.oper.an.sfc, e5.oper.an.pl; RDA ds633.0)", "access": "анонимно, HTTPS/S3, NetCDF4 (HDF5, gzip-1)", "grid": "0.25°, почасовой",
     "chunks": "t2m: файл на месяц 1.07 ГБ, чанки (27 ч,139,277); pl: файл на сутки 1.2 ГБ, чанк (1 ч, 37 ур., 721,1440) ~53 МБ"},
  "CDS_reference": {"what": "derived-era5-*-daily-statistics 1°, уже скачано нами (surface_t_cds/daily, upper_air_cds_daily, upper_misc_cds)", "observed_wait": "очередь: T700 2018_h2 33895 с (9.4 ч) на 33 МБ; uv700_2018_h1_u 8801 с (2.4 ч) на 38 МБ; daily_max t2m полугодие ~27 МБ"}
 },
 "speed": {
  "link_baseline": "односточный curl с S3 NCAR 0.23 МБ/с; 8 параллельных потоков суммарно 1.5 МБ/с; GCS (ARCO) 2-6 МБ/с — канал машины общий, цифры зависят от нагрузки",
  "B_t2m_per_day": {"MB": round(mb_day["t2m"], 1), "s": round(sday["t2m"], 2), "MB_per_s": round(rate["t2m"], 2), "threads": 3, "days": t2["days_done"]},
  "B_T700_per_day": {"MB": round(mb_day["T700"], 1), "s": round(sday["T700"], 1), "MB_per_s": round(rate["T700"], 2), "threads": 3, "days": t7["days_done"], "month_s": t7["total_s"], "month_GB": round(t7["total_MB"] / 1000, 2)},
  "B_u700_per_day": {"MB": round(mb_day["u700"], 1), "s": round(sday["u700"], 1), "MB_per_s": round(rate["u700"], 2), "threads": 3, "days": u7["days_done"]},
  "A_t2m_day_24h": A["t2m_day_24h_4thr"], "A_T700_one_hour": A["T700_one_hour_chunk"],
  "A_T700_per_day_extrapolated": {"MB": round(24 * A["T700_one_hour_chunk"]["MB"]), "note": "24 чанка по часу, каждый 37 уровней"},
  "NCAR_t2m_day_24h_measured": N["t2m_day_24h_1thr"], "NCAR_T700_one_hour": N["T700_one_hour_chunk"],
  "NCAR_note": "t2m: 984 МБ за сутки — завышено из-за кэша чанков HDF5 по умолчанию 1 МБ < чанка 4.2 МБ (перечитывание); теоретический минимум ~2 временных чанка = ~40-80 МБ/сутки, т.е. всё равно 10-20x ARCO-1°. Скорость с этой машины 0.3-0.5 МБ/с (в 10-20x ниже GCS).",
  "NCAR_T700_per_day_extrapolated": {"MB": round(24 * N["T700_one_hour_chunk"]["MB"]), "hours_at_measured_rate": round(24 * N["T700_one_hour_chunk"]["s"] / 3600, 2)}
 },
 "volume": vol,
 "volume_assumptions": "времена — по измеренной скорости B на этой машине (3 потока); по правилу CPU/сети ≤2 потока скорость может снизиться; все 24 часа суток, 3 чанка по 8 ч, на каждую переменную отдельно; 3D-чанки содержат все 37 уровней (нельзя качать один уровень)",
 "diff_vs_cds": diff,
 "diff_vs_cds_summary": {
  "t2m_daily_max_2018-07": "bias -0.07 K, RMSE 0.52 K, MAE 0.23 K, p99 2.4 K; хвосты до 11 K — береговые/озёрные ячейки (69N 76E Обская губа, 53N 279E Гурон): консервативное среднее суша+вода против интерполяции в точку",
  "t2m_daily_min_2018-06": "bias +0.075 K, RMSE 0.44 K",
  "t700_daily_mean_2018-07": "bias 0.0003 K, RMSE 0.087 K, p99 0.70 K, max 7.0 K (рельеф: 700 гПа под поверхностью — экстраполяция, разные схемы)",
  "u700_daily_mean_2018-06-01..10": "bias 0.0001 м/с, RMSE 0.19 м/с, p99 1.9 м/с",
  "subsampling_error_rmse": "T700: 4 срока 0.29 K, 2 срока 0.68 K, 12 UTC 0.70 K; u700: 4 срока 0.67 м/с, 2 срока 1.57, 12 UTC 1.70 — полные 24 ч (3 чанка) надёжнее; экономия только у 12 UTC (1/3 объёма)",
  "A_vs_NCAR": "A (ARCO 0.25°) и NCAR — одно поле: сверка T2m 2018-07-01 с одним и тем же эталоном даёт rmse 3.004819 K у обоих, max 21.1990 vs 21.1984 K (разница 6.5e-4 K); эталон — локальный surface_t_cds/t2m_2018.nc, он расходится с обоими на 3 K RMS — см. uncertain"
 },
 "resume": open(f"{O}/resume_test.log").read().strip().splitlines(),
 "recommendation": None
}
res["recommendation"] = {
 "use": "ARCO-ERA5 1° (B) для всего остатка: t2m max/min/mean, T700, u/v 700; запускать fetch_arco.py (возобновляемо, 24 ч = 3 чанка, суточные mean/max/min за один проход)",
 "why": "в 10-60x меньше байт, чем A и NCAR (чанки 1° и 8 ч), скорость 2-6 МБ/с против 0.3-0.5 у NCAR, нет очереди; отличие от CDS daily statistics: T700 RMSE 0.09 K, u700 0.19 м/с, T2m max 0.5 K",
 "order": "1) t2m 2018-2019 (≈25 мин, 2.9 ГБ) — закрывает HH-1e; 2) T700 2019 (≈2.7 ч, 53 ГБ) — HH-1g; 3) u,v 700 за остаток — самый тяжёлый (≈21 ч на 3 года при 3 потоках; по ≤2 потоков дольше); CDS-запросы на u,v можно оставить в очереди параллельно и взять то, что придёт раньше (файлы совместимы: сетка 1° lat 90..-90, lon 0..359)",
 "not_use": "NCAR S3 (0.3-0.5 МБ/с, чанки 0.25° — на 1 уровень тянется все 37) и ARCO 0.25° (85 МБ на час 3D) — только если нужен 0.25°"
}
json.dump(res, open(f"{H}/result.json", "w"), ensure_ascii=False, indent=1)
print(json.dumps(vol, ensure_ascii=False, indent=1))
