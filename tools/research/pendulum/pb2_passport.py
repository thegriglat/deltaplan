#!/usr/bin/env python3
"""PB-2: паспорта VG крыльев игры → out/pb2/passport.json и out/pb2/vg_wings.md.

Для каждого крыла configs/wings/<id>.json: класс (wind_class), паспортная запись
(tools/research/data/wing_passports/wings_merged.json по ключу из *_doc «паспорт: Производитель|Модель||размер»),
vmax_vg0_kmh / vmax_vg100_kmh DHV (с цитатой и файлом источника), признак «>90» (DHV не разгоняет выше 90 —
число цензурировано), есть ли VG (по паспорту: колонка VG 100 % в листе DHV или упоминание VG; без паспорта — по классу:
4 безмачтовое — есть, 1 учебное — нет, 2–3 — неизвестно). Данные не меняются, только читаются.

  python3 tools/research/pendulum/pb2_passport.py
"""
from __future__ import annotations

import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = HERE / "out" / "pb2"
MERGED = ROOT / "tools/research/data/wing_passports/wings_merged.json"


def _val(f: dict, k: str):
    x = f.get(k)
    if isinstance(x, dict):
        return x.get("value"), (x.get("sources") or [{}])[0]
    return x, {}


def passport_key(doc: str | None) -> str | None:
    if not doc:
        return None
    m = re.search(r"паспорт:\s*([^:]+?)(?:\s*\(размер[^)]*\))?:\s*DHV", doc)
    return m.group(1).strip() if m else None


def main():
    recs = {}
    for r in json.loads(MERGED.read_text(encoding="utf-8")):  # ключи повторяются: берём запись с большим числом полей
        rank = (int("vmax_vg100_kmh" in r.get("fields", {})), len(r.get("fields", {})))
        if r["key"] not in recs or rank > recs[r["key"]][0]:
            recs[r["key"]] = (rank, r)
    recs = {k: v[1] for k, v in recs.items()}
    out = {}
    for f in sorted((ROOT / "configs/wings").glob("*.json")):
        w = json.loads(f.read_text(encoding="utf-8"))
        wid = f.stem
        cls = int(w.get("wind_class", 0))
        key = passport_key(w.get("full_pull_speed_kmh_doc"))
        rec = recs.get(key) if key else None
        row = {"wind_class": cls, "passport_key": key, "game_full_pull_kmh": w.get("full_pull_speed_kmh"),
               "game_trim_kmh": w.get("trim_speed_kmh"),
               "vmax_vg0_kmh": None, "vmax_vg100_kmh": None, "vmax_vg100_censored": None,
               "vmin_vg0_kmh": None, "vmin_vg100_kmh": None, "takeoff_mass_max_kg": None,
               "has_vg": None, "has_vg_source": None, "source": None}
        if rec is not None:
            fl = rec.get("fields", {})
            v0, s0 = _val(fl, "vmax_vg0_kmh")
            v1, s1 = _val(fl, "vmax_vg100_kmh")
            row["vmax_vg0_kmh"] = v0
            row["vmax_vg100_kmh"] = v1
            row["vmin_vg0_kmh"] = _val(fl, "vmin_vg0_kmh")[0]
            row["vmin_vg100_kmh"] = _val(fl, "vmin_vg100_kmh")[0]
            row["takeoff_mass_max_kg"] = _val(fl, "takeoff_mass_max_kg")[0]
            q1 = (s1.get("quote") or "").replace("\n", " ")
            row["vmax_vg100_censored"] = bool(v1 is not None and ">" in q1)  # «>90»: DHV не разгоняет дальше
            feat = rec.get("features", {})
            if v1 is not None:
                row["has_vg"] = True
                row["has_vg_source"] = f"DHV: колонка VG 100 % ({s1.get('file', '')}: «{q1[:60]}»)"
            elif any("vg" in k.lower() for k in feat):
                row["has_vg"] = True
                row["has_vg_source"] = "DHV: " + "; ".join(f"{k}: «{v.get('quote', '')}»" for k, v in feat.items() if "vg" in k.lower())
            row["source"] = (f"wings_merged.json «{key}», DHV vmax_vg0 {s0.get('file', '')}: «{(s0.get('quote') or '')[:60]}»"
                             + (f"; vmax_vg100 {s1.get('file', '')}: «{q1[:60]}»" if v1 is not None else ""))
        if row["has_vg"] is None:
            if cls == 4:
                row["has_vg"], row["has_vg_source"] = True, "по классу: безмачтовые — все с VG"
            elif cls == 1:
                row["has_vg"], row["has_vg_source"] = False, "по классу: учебные — без VG"
            else:
                row["has_vg"], row["has_vg_source"] = None, "в паспорте нет; класс 2–3 — неизвестно"
        out[wid] = row
    OUT.mkdir(parents=True, exist_ok=True)
    tmp = OUT / "passport.json.tmp"
    tmp.write_text(json.dumps(out, ensure_ascii=False, indent=1), encoding="utf-8")
    tmp.replace(OUT / "passport.json")
    lines = ["| крыло | класс | паспорт | Vmax VG 0 | Vmax VG 100 | Δ | VG | источник VG |", "|---|---|---|---|---|---|---|---|"]
    for wid, r in out.items():
        v0, v1 = r["vmax_vg0_kmh"], r["vmax_vg100_kmh"]
        d = "" if v0 is None or v1 is None else (f"≥ {v1 - v0:+.0f}" if r["vmax_vg100_censored"] else f"{v1 - v0:+.0f}")
        vg = {True: "да", False: "нет", None: "?"}[r["has_vg"]]
        lines.append(f"| {wid} | {r['wind_class']} | {r['passport_key'] or '—'} | {v0 if v0 is not None else '—'} | "
                     f"{('>' if r['vmax_vg100_censored'] else '') + str(v1) if v1 is not None else '—'} | {d} | {vg} | {r['has_vg_source']} |")
    (OUT / "vg_wings.md").write_text("\n".join(lines) + "\n", encoding="utf-8")
    n_vg = sum(1 for r in out.values() if r["has_vg"])
    print(f"крыльев {len(out)}, с VG {n_vg}, с паспортом vg100 {sum(1 for r in out.values() if r['vmax_vg100_kmh'] is not None)}")
    for wid, r in out.items():
        if r["vmax_vg100_kmh"] is not None and not r["vmax_vg100_censored"]:
            print(f"  нецензурированный прирост: {wid} {r['vmax_vg0_kmh']} → {r['vmax_vg100_kmh']}")


if __name__ == "__main__":
    sys.exit(main())
