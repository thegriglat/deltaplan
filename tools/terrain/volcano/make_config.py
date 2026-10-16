"""Пишет configs/locations/volcano_island.json по таблице стартов и посадок (метры от центра места → градусы).
Координаты подобраны под правила tests/terrain/test_locations.gd (scan_sites.py); перезапуск перезаписывает файл.
  python3 tools/terrain/volcano/make_config.py"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import sites as S  # noqa: E402

ROOT = HERE.parents[2]
LAT0, LON0 = -27.10, -109.35
# id: (x, z, курс, пояснение). Курсы склоновых стартов в пределах ±30° от пассата 110°.
STARTS = {
    "east_cliffs": (10672, 970, 101, "Склон: верх наветренного склона восточного плато над обрывами, разбег на восток (пассат 110°)"),
    "crater_ridge": (-6750, 9950, 110, "Склон: гребень кратера на юго-западе над обрывом к морю, разбег по пассату"),
    "plateau_landing": (10750, 1145, 90, "Посадка: бровка плато, короткий подлёт; мишень landing_target в 200 м"),
}
LANDINGS = {
    "landing_target": (10950, 1145, "Мишень на плато у восточной бровки"),
    "landing_cliffs": (10872, 970, "Площадка на плато под стартом east_cliffs"),
    "landing_crater": (-6475, 9900, "Площадка на уступе под гребнем кратера (старт crater_ridge)"),
}


def ll(x, z):
    la, lo = S.local_to_latlon(x, z, LAT0, LON0)
    return round(la, 7), round(lo, 7)


def main():
    base = json.loads((ROOT / "configs/locations/training_island.json").read_text())
    cfg = {
        "_doc": "Вулканический остров (VI-К1): реальное место, только для «Тренировки» (training_only). Данные — res://data/locations/volcano_island/ "
                "(собирает tools/terrain/volcano/build.sh; рельеф как есть). Старты — склон над обрывами, гребень кратера, посадка на плато. "
                "Координаты мира: X — восток, −Z — север.",
        "bundled": True,
        "bundled_doc": "Данные места — res://data/locations/volcano_island/ (без сборки и сети)",
        "training_only": True,
        "training_only_doc": "Только окно «Тренировка» (VI-К2): не в меню полёта, не в «Популярных местах», точка с карты в него не превращается",
        "center_lat": LAT0,
        "center_lon": LON0,
        "country": "",
        "utc_offset_h": -6,
        "name": "loc_volcano_island",
        "render": base["render"],
        "start_clearing_radius_m": base["start_clearing_radius_m"],
        "start_position_agl_m": base["start_position_agl_m"],
        "landing_sites": [{"id": k, "lat": ll(v[0], v[1])[0], "lon": ll(v[0], v[1])[1], "name": v[2]} for k, v in LANDINGS.items()],
        "landing_sites_doc": "Посадочные площадки {id, name, lat, lon}; детали — configs/world_objects.json → landing.sites.volcano_island",
        "start_sites": [
            {"id": k, "name": "site_volcano_island_" + k, "name_doc": v[3], "lat": ll(v[0], v[1])[0], "lon": ll(v[0], v[1])[1], "heading_deg": v[2]}
            for k, v in STARTS.items()
        ],
    }
    p = ROOT / "configs/locations/volcano_island.json"
    p.write_text(json.dumps(cfg, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(p)


if __name__ == "__main__":
    main()
