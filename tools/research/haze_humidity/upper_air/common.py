"""Общее: сетки усреднения ERA5 0.25° -> ячейки 1° (по площади)."""
import numpy as np

ARCO = "gcp-public-data-arco-era5/ar/full_37-1h-0p25deg-chunk-1.zarr-v3"
RAW = "~/data/haze_humidity"  # сырые данные вне репозитория


def _overlap(lo_a, hi_a, lo_b, hi_b):
    return np.clip(np.minimum(hi_a[:, None], hi_b[None, :]) - np.maximum(lo_a[:, None], lo_b[None, :]), 0, None)


def weights():
    """Матрицы усреднения: Wlat (180x721), Wlon (360x1440; колонки источника уже в порядке -180..180 после roll).
    Источник: узлы 0.25°, каждый представляет бокс 0.25° вокруг узла. Вес по широте = перекрытие * cos(lat узла)."""
    lat_n = 90 - 0.25 * np.arange(721)  # ARCO: 90 -> -90
    lat_c = -89.5 + np.arange(180)  # 1° ячейки, j=0 юг
    ov = _overlap(lat_c - 0.5, lat_c + 0.5, lat_n - 0.125, lat_n + 0.125)
    ov = ov * np.cos(np.radians(lat_n))[None, :]
    # у полюсов боксы узлов шире ячеек; нормировка ниже
    wlat = ov / ov.sum(1, keepdims=True)
    lon_n = -180 + 0.25 * np.arange(1440)  # после roll: -180 .. 179.75
    lon_c = -179.5 + np.arange(360)
    ovl = _overlap(lon_c - 0.5, lon_c + 0.5, lon_n - 0.125, lon_n + 0.125)
    wlon = ovl / ovl.sum(1, keepdims=True)
    return wlat.astype(np.float64), wlon.astype(np.float64)


def to_1deg(field721x1440):
    """(721,1440) с lat 90->-90, lon 0->359.75  ->  (180,360) j=0 юг, i=0 -179.5°."""
    wlat, wlon = weights()
    f = np.roll(np.asarray(field721x1440, dtype=np.float64), 720, axis=1)
    return wlat @ f @ wlon.T
ARCO6 = "gcp-public-data-arco-era5/ar/1959-2022-6h-1440x721.zarr"  # 6-часовой, 13 уровней, чанк = один срок
