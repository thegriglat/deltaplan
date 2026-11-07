#!/usr/bin/env python3
"""OB2/OB3: проверка записей стенда корпуса и оценка времени полного корпуса.

    check_records.py <cases.jsonl> --spec <corpus.json> --slices <dir>
        -> OBC2: records=<n> invalid=<k> est_full_h=<x> pilot_s=<сумма t_solve_s>
           (+ первые 5 нарушений ниже)

Проверяет на каждую запись: ключи и типы OB2 v1 (null — только где разрешено), формат и состав `case_id`,
`flux_net_max_rel <= 1e-6` у soft/soft_ns, наличие реза OB3 (bin размером 4*3*3*ny*nx байт + json) и повторы пар.
`est_full_h` — оценка полного корпуса `--spec`: среднее `t_solve_s` на итерацию (по `heat`) × ожидаемые
итерации по корзине U10 (<=2 м/с — 1000, 2,5–3 — 600, >=6 — 200; если итерации пилота в корзине больше — по ним;
не больше `max_iters`) × число пар случай×вариант (3 варианта) / 3600, один процесс на `threads` нитей.
"""
import json
import re
import sys
from pathlib import Path

HEIGHTS = (10, 50, 300)
VARIANTS = ("hard", "soft", "soft_ns")
STATUSES = ("ok", "max", "diverged", "cancelled")
FLUX_TOL = 1e-6
ID_RE = re.compile(r"^[A-Za-z0-9_]+_d\d{3}_u\d{3}_[mh]$")

NUM = (int, float)


def is_num(x):
    return isinstance(x, NUM) and not isinstance(x, bool)


def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def case_id(place, d, u10, heat):
    return f"{place}_d{round(d):03d}_u{round(u10 * 10):03d}_{'h' if heat else 'm'}"


def cases_of(spec):
    """Случаи спецификации (произведение places × dirs × u10 × heat) → список (place, dir, u10, heat)."""
    out = []
    for p in spec["places"]:
        for d in p["dirs_deg"]:
            for u in spec["u10_ms"]:
                for h in spec["heat"]:
                    out.append((p["id"], d, u, h))
    return out


def u10_bin(u):
    return "lo" if u <= 2.0 else ("mid" if u < 6.0 else "hi")


DEFAULT_ITERS = {"lo": 1000, "mid": 600, "hi": 200}


def check_record(r, spec_places, slices_dir, problems, dims):
    def bad(m):
        problems.append(f"{r.get('case_id')} {r.get('variant')}: {m}")

    def need(k, ok, nullable=False):
        if k not in r:
            bad(f"нет ключа {k}")
            return False
        if r[k] is None:
            if not nullable:
                bad(f"{k}: null")
            return nullable
        if not ok(r[k]):
            bad(f"{k}: тип/значение {r[k]!r}")
            return False
        return True

    s = lambda x: isinstance(x, str)  # noqa: E731
    need("case_id", s)
    need("place", s)
    need("kind", lambda x: x in ("real", "ideal"))
    need("shape", s, nullable=True)
    need("h_m", is_num, nullable=True)
    need("dir_deg", is_num)
    need("u10_in", is_num)
    need("heat", lambda x: isinstance(x, bool))
    need("variant", lambda x: x in VARIANTS)
    need("git", s)
    need("status", lambda x: x in STATUSES)
    need("iters", is_int)
    need("t_solve_s", is_num)
    need("threads", is_int)
    for k in ("u10", "fr", "n_bv", "relief_m"):
        need(k, is_num)
    v, st = r.get("variant"), r.get("status")
    # late_spread: число при ok (0) и max; null только при diverged/cancelled
    null_ok = st in ("diverged", "cancelled")
    if need("late_spread60_p90", is_num, nullable=null_ok) and st == "ok" and r["late_spread60_p90"] != 0:
        bad("late_spread60_p90 != 0 при ok")
    # outflow: null у hard, числа у soft*
    soft = v in ("soft", "soft_ns")
    need("faces_out", is_int, nullable=not soft)
    need("flux_in", is_num, nullable=not soft)
    need("flux_net_max_rel", is_num, nullable=not soft)
    need("backflow_faces", is_int, nullable=not soft)
    if not soft:
        for k in ("faces_out", "flux_in", "flux_net_max_rel", "backflow_faces"):
            if r.get(k) is not None:
                bad(f"{k} должен быть null у hard")
    elif is_num(r.get("flux_net_max_rel")) and r["flux_net_max_rel"] > FLUX_TOL:
        bad(f"flux_net_max_rel {r['flux_net_max_rel']:.2e} > {FLUX_TOL:g}")
    # история невязок
    h = r.get("res_hist")
    if not isinstance(h, list) or not h:
        bad("res_hist: пусто или не список")
    else:
        for row in h:
            if not (isinstance(row, list) and len(row) == 6 and is_int(row[0]) and all(x is None or is_num(x) for x in row[1:])):
                bad(f"res_hist: строка {row!r}")
                break
        else:
            if h[-1][0] != r.get("iters"):
                bad("res_hist: последняя проверка не на итерации iters")
    # сравнение с hard
    has_ref = r.get("both_ok") is not None
    if v == "hard" and has_ref:
        bad("both_ok должен быть null у hard")
    need("both_ok", lambda x: isinstance(x, bool), nullable=True)
    if soft and not has_ref and "both_ok" in r:
        bad("нет эталона hard (both_ok null)")
    for hh in HEIGHTS:
        keys = [f"d_start_{hh}_max", f"d_int_{hh}_rms", f"d_int_{hh}_p99", f"d_int_{hh}_max", f"d_band_{hh}_max", f"d_int_{hh}_max_rel"]
        for k in keys:
            if v == "hard":
                if r.get(k, 0) is not None:
                    bad(f"{k} должен быть null у hard")
            else:
                # start: null, если точек старта в области нет; остальные — null только при diverged (NaN)
                need(k, is_num, nullable=(k.startswith("d_start") or st == "diverged" or not has_ref))
        for k in (f"edge_out_{hh}_un_mean", f"edge_out_{hh}_back_frac"):
            need(k, is_num, nullable=True)
    # case_id: формат и состав
    cid = r.get("case_id")
    if isinstance(cid, str):
        if not ID_RE.match(cid):
            bad("case_id: формат")
        elif is_num(r.get("dir_deg")) and is_num(r.get("u10_in")) and isinstance(r.get("heat"), bool):
            if cid != case_id(r.get("place"), r["dir_deg"], r["u10_in"], r["heat"]):
                bad("case_id не сходится с place/dir_deg/u10_in/heat")
        if r.get("place") not in spec_places:
            bad("место не из спецификации")
    # рез OB3
    if isinstance(cid, str) and v in VARIANTS:
        b = Path(slices_dir) / f"{cid}__{v}.bin"
        j = Path(slices_dir) / f"{cid}__{v}.json"
        if not b.is_file() or not j.is_file():
            bad("нет реза OB3 (bin/json)")
        else:
            try:
                m = json.loads(j.read_text())
                ok = (m.get("version") == 1 and m.get("comps") == ["u", "v", "w"] and m.get("agl_m") == list(HEIGHTS)
                      and m.get("case_id") == cid and m.get("variant") == v and is_int(m.get("nx")) and is_int(m.get("ny"))
                      and is_num(m.get("dx_m")) and m.get("status") == st and m.get("iters") == r.get("iters"))
                if not ok:
                    bad("json реза: ключи/значения OB3")
                else:
                    want = 4 * 3 * 3 * m["ny"] * m["nx"]
                    if b.stat().st_size != want:
                        bad(f"bin реза: {b.stat().st_size} байт, нужно {want}")
                    dims.add((m["nx"], m["ny"]))
            except (ValueError, OSError) as e:
                bad(f"json реза не читается: {e}")


def estimate(recs, spec):
    """Часы полного корпуса по пилоту (см. докстринг)."""
    per_it = {}
    for r in recs:
        if r.get("iters") and is_num(r.get("t_solve_s")):
            per_it.setdefault(r.get("heat"), []).append(r["t_solve_s"] / r["iters"])
    allv = [x for v in per_it.values() for x in v]
    if not allv:
        return float("nan")
    mean = lambda v: sum(v) / len(v)  # noqa: E731
    exp = dict(DEFAULT_ITERS)
    pil = {}
    for r in recs:
        if is_num(r.get("u10_in")) and is_int(r.get("iters")):
            pil.setdefault(u10_bin(r["u10_in"]), []).append(r["iters"])
    for b, v in pil.items():
        exp[b] = max(exp[b], mean(v))
    cap = spec.get("max_iters", 1000)
    total_s = 0.0
    for _, _, u, heat in cases_of(spec):
        t = mean(per_it.get(heat, allv))
        total_s += len(VARIANTS) * t * min(exp[u10_bin(u)], cap)
    return total_s / 3600.0


def main(argv):
    if len(argv) < 2 or "-h" in argv:
        print(__doc__)
        return 2
    path = argv[1]
    opts = {a: argv[i + 1] for i, a in enumerate(argv) if a in ("--spec", "--slices") and i + 1 < len(argv)}
    spec = json.loads(Path(opts["--spec"]).read_text())
    spec_places = {p["id"] for p in spec["places"]}
    recs, problems, seen, dims = [], [], set(), set()
    for n, line in enumerate(Path(path).read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except ValueError as e:
            problems.append(f"строка {n}: не json ({e})")
            recs.append({})
            continue
        recs.append(r)
        key = (r.get("case_id"), r.get("variant"))
        if key in seen:
            problems.append(f"{key}: повтор пары")
        seen.add(key)
        check_record(r, spec_places, opts["--slices"], problems, dims)
    if len(dims) > 1:
        problems.append(f"разные размеры резов: {sorted(dims)}")
    invalid = len({p.split(":")[0] for p in problems}) if problems else 0
    est = estimate(recs, spec)
    pilot_s = sum(r["t_solve_s"] for r in recs if is_num(r.get("t_solve_s")))
    print(f"OBC2: records={len(recs)} invalid={invalid} est_full_h={est:.1f} pilot_s={pilot_s:.1f}")
    for p in problems[:5]:
        print("  " + p)
    return 0 if invalid == 0 else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
