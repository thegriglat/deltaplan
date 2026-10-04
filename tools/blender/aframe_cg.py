"""Офлайн-центровка крыльев и подбор наклона стоек (docs/contracts/aframe-geometry.md, A1).

Запуск из корня проекта (обычный python3, без Blender):
    python3 tools/blender/aframe_cg.py [--pick-tilt] [--report файл.json]

Читает tools/blender/glider_params.json (control_frame.mass_model, записи wings.<id>),
размах — configs/wings/<id>.json, тангаж киля на трим-скорости и плечи пилота в полёте —
tools/blender/aframe_trim.json (его пишет tools/flight/aframe_trim.gd, физику не меняет).
Пишет в wings.<id>: cg_from_nose_m (центр масс по трубам, ткань не учтена, пока
sail_mass_kg не задан) и nose_forward_m = cg_from_nose_m − hang_cg_offset_m. С --pick-tilt
дополнительно выбирает upright_tilt_deg (4…13°) так, чтобы середина базовой штанги в полёте на
балансировке (трапеция в нейтрали, трим-скорость, тангаж киля из aframe_trim.json) оказалась
под серединой плечевых суставов. Повторный запуск без изменений входа даёт те же числа.
Первый запуск (нет crossbar_from_nose_m) переносит прежние константы: центр поперечины —
nose_forward_m − 0,08, длина стойки — как у прежней фиксированной трапеции.
"""
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import aframe_geom as G  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
PARAMS = os.path.join(ROOT, "tools", "blender", "glider_params.json")
TRIM = os.path.join(ROOT, "tools", "blender", "aframe_trim.json")
TILT_RANGE = (4.0, 13.0)
LEN_RANGE = (1.6, 1.75)


def set_keys(text: str, wid: str, kv: dict, after: str) -> str:
    """Задать ключи записи крыла wid в тексте JSON (формат файла сохраняется): есть строка
    ключа — меняется значение, нет — ключи вставляются после строки `after`."""
    m = re.search(r'^    "%s": \{\n' % re.escape(wid), text, re.M)
    end = re.compile(r"^    \},?\n", re.M).search(text, m.end())
    block = text[m.end():end.start()]
    for k, v in kv.items():
        line = '      "%s": %s,\n' % (k, json.dumps(v))
        pat = re.compile(r'^      "%s": [^\n]*,\n' % re.escape(k), re.M)
        if pat.search(block):
            block = pat.sub(lambda _: line, block, count=1)
        else:
            a = re.search(r'^      "%s": [^\n]*,\n' % re.escape(after), block, re.M)
            block = block[:a.end()] + line + block[a.end():]
            after = k
    return text[:m.end()] + block + text[end.start():]


def balance(p: dict, cf: dict, tilt: float, theta_deg: float, shoulder: list) -> tuple:
    """(по горизонтали, по вертикали) середина BaseBar относительно середины плеч в полёте на
    балансировке, м: оси мира, киль под тангажем theta (нос вверх). Плечи — относительно
    HangPoint в осях крыла: [x, y вверх, z вперёд]."""
    fp = G.frame_points(p, cf, tilt)
    dip = cf["speedbar_dip_m"] if p["faired_uprights"] else 0.0
    f = fp["y_bb"] - shoulder[2]
    u = (fp["z_bb"] - dip) - shoulder[1]
    th = math.radians(theta_deg)
    return f * math.cos(th) - u * math.sin(th), f * math.sin(th) + u * math.cos(th)


def main() -> None:
    pick = "--pick-tilt" in sys.argv
    report = sys.argv[sys.argv.index("--report") + 1] if "--report" in sys.argv else None
    text = open(PARAMS, encoding="utf-8").read()
    params = json.loads(text)
    cf = params["control_frame"]
    trim = json.load(open(TRIM, encoding="utf-8"))
    rows = {}
    for wid, p in params["wings"].items():
        upd = {}
        if "crossbar_from_nose_m" not in p:
            upd["crossbar_from_nose_m"] = round(p["nose_forward_m"] - 0.08, 3)
        if "upright_len_m" not in p:  # прежняя трапеция: вершина 0,25, база 0,90 вперёд / 1,55 ниже
            dx = p["basebar_width_m"] * 0.5 - cf["upright_top_x_m"]
            ln = math.sqrt(0.65 ** 2 + (1.55 - cf["keel_z_m"] + cf["upright_top_z_m"]) ** 2 + dx ** 2)
            upd["upright_len_m"] = min(round(ln, 3), LEN_RANGE[1])
        if "upright_tilt_deg" not in p and not pick:
            upd["upright_tilt_deg"] = cf.get("upright_tilt_deg", 8.0)
        p.update(upd)
        cfg = os.path.join(ROOT, "configs", "wings", p["config"] + ".json")
        span = json.load(open(cfg, encoding="utf-8"))["span_m"] if os.path.exists(cfg) else p["span_m"]
        theta = trim["trim_pitch_deg"][wid]
        sh = trim["shoulder_mid"]
        if pick:
            best = None
            for i in range(int(TILT_RANGE[0] * 10), int(TILT_RANGE[1] * 10) + 1):
                t = i / 10
                h, _ = balance(p, cf, t, theta, sh)
                if best is None or abs(h) < abs(best[1]):
                    best = (t, h)
            upd["upright_tilt_deg"] = best[0]
            p["upright_tilt_deg"] = best[0]
        tilt = G.param(p, cf, "upright_tilt_deg")
        cg = round(G.cg_from_nose(p, cf, span, tilt), 3)
        off = G.param(p, cf, "hang_cg_offset_m")
        upd["cg_from_nose_m"] = cg
        upd["nose_forward_m"] = round(cg - off, 3)
        old_nf = p["nose_forward_m"]
        p.update(upd)
        text = set_keys(text, wid, upd, "nose_forward_m")
        h, v = balance(p, cf, tilt, theta, sh)
        rows[wid] = {"tilt": tilt, "len": G.param(p, cf, "upright_len_m"), "cg": cg,
                     "nose_forward_old": old_nf, "nose_forward": upd["nose_forward_m"],
                     "base_h": round(h, 3), "base_v": round(v, 3), "theta": theta}
    open(PARAMS, "w", encoding="utf-8").write(text)
    for wid, r in rows.items():
        print("%-20s tilt %5.1f len %.3f cg %.3f nf %.3f->%.3f base_h %+.3f base_v %+.3f θ %.1f"
              % (wid, r["tilt"], r["len"], r["cg"], r["nose_forward_old"], r["nose_forward"],
                 r["base_h"], r["base_v"], r["theta"]))
    if report:
        json.dump(rows, open(report, "w"), indent=1)


if __name__ == "__main__":
    main()
