#!/usr/bin/env python3
"""OB4: проверка записей стенда этапа 2 (старты Пикара и снимки) и оценка времени полного корпуса.

    check_stage2.py <stage2.jsonl> --spec <corpus_stage2*.json> [--slices <dir>] [--full-spec <corpus_stage2.json>]
        -> OB4: records=<n> invalid=<k> [est_full_h=<x>]   (+ первые 5 нарушений ниже)

Проверяет на каждую запись: ключи и типы OB4 v1 (null — только где разрешено), формат `case_id`, повторы троек
`case_id`+`variant`+`start`, длины `err_hist` (= число снимков) и `inc_hist` (на 1 меньше), номера итераций снимков,
согласие `eN_*` с `err_hist`, `e* = 0` для снимков после остановки при `ok`, `late_spread_* = 0` при `ok`, длину
`start_iters` по старту, `scale = max(u10, wstar)`, рез (размер bin, json) при `--slices`.

`est_full_h` (только с `--full-spec`) — оценка полного корпуса одним процессом на `threads` нитей: на каждую пару
(старт, heat) пилота берётся (t_start_s + t_solve_s) / iters, умножается на ожидаемые итерации случая по U10
(<= 2 м/с — 1000, 3 — 700, 6 — 200; не больше `max_iters`) и суммируется по случаям полного корпуса и стартам,
которые есть в пилоте (в часах). Рядом печатается `est_split_h` — то же, но t_start_s берётся один раз на случай, а
на итерации приходится только t_solve_s / iters (оценка без перекоса от коротких случаев пилота).
"""
import argparse
import json
import re
import sys
from pathlib import Path

HEIGHTS = (10, 50, 300)
VARIANTS = ("hard", "soft", "soft_ns")
STARTS = ("bg", "coarse3", "chain", "phase", "chain_phase")
STATUSES = ("ok", "max", "diverged", "cancelled", "start_failed")
START_STAGES = {"bg": 0, "coarse3": 1, "chain": 2, "phase": 0, "chain_phase": 2}
ID_RE = re.compile(r"^[A-Za-z0-9_]+_d\d{3}_u\d{3}_[mh]$")
EXPECT_ITERS = ((2.0, 1000), (3.0, 700), (6.0, 200))


def is_num(x):
    return isinstance(x, (int, float)) and not isinstance(x, bool)


def is_int(x):
    return isinstance(x, int) and not isinstance(x, bool)


def case_id(place, d, u10, heat):
    return f"{place}_d{round(d):03d}_u{round(u10 * 10):03d}_{'h' if heat else 'm'}"


def cases_of(spec):
    """Случаи спецификации: явный список `cases` или произведение places × dirs × u10 × heat."""
    out = []
    if spec.get("cases"):
        for c in spec["cases"]:
            out.append((c["place"], c["dir_deg"], c["u10_ms"], c["heat"]))
        return out
    for p in spec["places"]:
        for d in p["dirs_deg"]:
            for u in spec["u10_ms"]:
                for h in spec["heat"]:
                    out.append((p["id"], d, u, h))
    return out


def expected_iters(u10, max_iters):
    for lim, n in EXPECT_ITERS:
        if u10 <= lim:
            return min(n, max_iters)
    return min(EXPECT_ITERS[-1][1], max_iters)


def eq(a, b):
    """Числа равны с запасом на текст json."""
    if a is None or b is None:
        return a is None and b is None
    return abs(a - b) <= 1e-9 + 1e-9 * abs(b)


def check_record(r, spec, ids, slices_dir, problems):
    def bad(m):
        problems.append(f"{r.get('case_id')} {r.get('variant')} {r.get('start')}: {m}")

    snap = spec["snap"]
    every = snap["every"]
    limit = -(-spec["max_iters"] // every) * every
    n_snap = limit // every

    def typ(k, ok_types, nullable=False):
        if k not in r:
            bad(f"no key {k}")
            return False
        v = r[k]
        if v is None:
            if not nullable:
                bad(f"{k}: null")
                return False
            return True
        if not ok_types(v):
            bad(f"{k}: bad type/value {v!r:.40}")
            return False
        return True

    cid = r.get("case_id")
    if not (isinstance(cid, str) and ID_RE.match(cid)):
        bad("case_id format")
    elif cid not in ids:
        bad("case_id not in spec")
    typ("place", lambda v: isinstance(v, str))
    typ("kind", lambda v: v in ("real", "ideal"))
    typ("shape", lambda v: isinstance(v, str), True)
    typ("h_m", is_num, True)
    typ("dir_deg", is_num)
    typ("u10_in", is_num)
    typ("heat", lambda v: isinstance(v, bool))
    typ("variant", lambda v: v in VARIANTS)
    typ("start", lambda v: v in STARTS)
    typ("git", lambda v: isinstance(v, str))
    typ("threads", lambda v: is_int(v) and v >= 1)
    typ("status", lambda v: v in STATUSES)
    status = r.get("status")
    typ("start_err", lambda v: isinstance(v, str), True)
    if (status == "start_failed") != isinstance(r.get("start_err"), str):
        bad("start_err is set iff status == start_failed")
    typ("t_start_s", lambda v: is_num(v) and v >= 0)
    if r.get("start") == "bg" and r.get("t_start_s") not in (0, 0.0):
        bad("bg: t_start_s != 0")
    for k in ("u10", "fr", "n_bv", "relief_m", "wstar", "scale"):
        typ(k, is_num)
    if is_num(r.get("u10")) and is_num(r.get("wstar")) and is_num(r.get("scale")):
        if not eq(r["scale"], max(r["u10"], r["wstar"])):
            bad("scale != max(u10, wstar)")
        if r.get("heat") is False and r["wstar"] != 0:
            bad("wstar != 0 without heat")
    if status == "start_failed":
        return
    typ("iters", lambda v: is_int(v) and 0 <= v <= limit + 10)
    typ("t_solve_s", lambda v: is_num(v) and v >= 0)
    for k in ("t_setup_s", "t_iter_s", "t_check_s", "t_snap_s"):
        typ(k, lambda v: is_num(v) and v >= 0)
    if typ("start_iters", lambda v: isinstance(v, list) and all(is_int(x) and x >= 0 for x in v)):
        if len(r["start_iters"]) != START_STAGES.get(r.get("start"), -1):
            bad(f"start_iters: {len(r['start_iters'])} stages")
    hist = r.get("res_hist")
    if not (isinstance(hist, list) and hist and all(isinstance(h, list) and len(h) == 6 and is_int(h[0]) and all(is_num(x) for x in h[1:]) for h in hist)):
        bad("res_hist: rows [it, mom_rms, mom_max, th_rms, thd_rms, div_rms]")
    if status == "diverged":
        return
    iters = r.get("iters")
    ok = status == "ok"
    typ("ref_kind", lambda v: v == ("converged" if ok else "late_mean"))
    for h in HEIGHTS:
        k = f"late_spread_{h}_p90"
        if typ(k, lambda v: is_num(v) and v >= 0) and ok and r[k] != 0:
            bad(f"{k} != 0 at ok")
    err = r.get("err_hist")
    inc = r.get("inc_hist")
    if not (isinstance(err, list) and len(err) == n_snap):
        bad(f"err_hist: length != {n_snap}")
        err = None
    if not (isinstance(inc, list) and len(inc) == n_snap - 1):
        bad(f"inc_hist: length != {n_snap - 1}")
        inc = None
    if err:
        for k, row in enumerate(err):
            if not (isinstance(row, list) and len(row) == 8 and row[0] == (k + 1) * every and all(is_num(x) and x >= 0 for x in row[1:7]) and (row[7] is None or is_num(row[7]))):
                bad(f"err_hist[{k}]: row")
                break
            if ok and is_int(iters) and row[0] > iters and any(x != 0 for x in row[1:] if x is not None):
                bad(f"err_hist[{k}]: not zero after the stop at ok")
                break
    if inc:
        for k, row in enumerate(inc):
            if not (isinstance(row, list) and len(row) == 6 and row[0] == (k + 2) * every and all(is_num(x) and x >= 0 for x in row[1:])):
                bad(f"inc_hist[{k}]: row")
                break
            if ok and is_int(iters) and row[0] > iters and any(x != 0 for x in row[1:]):
                bad(f"inc_hist[{k}]: not zero after the stop at ok")
                break
    for n in snap["n_eval"]:
        row = err[n // every - 1] if err else None
        starts = []
        for i, h in enumerate(HEIGHTS):
            for suf in ("start_max", "int_rms", "int_p99", "int_max"):
                k = f"e{n}_{h}_{suf}"
                if k not in r:
                    bad(f"no key {k}")
                    continue
                v = r[k]
                if v is None and suf != "start_max":
                    bad(f"{k}: null")
                elif v is not None and not (is_num(v) and v >= 0):
                    bad(f"{k}: bad value")
            if row:
                if not eq(r.get(f"e{n}_{h}_int_p99"), row[1 + i]):
                    bad(f"e{n}_{h}_int_p99 != err_hist")
                if not eq(r.get(f"e{n}_{h}_int_max"), row[4 + i]):
                    bad(f"e{n}_{h}_int_max != err_hist")
            if r.get(f"e{n}_{h}_start_max") is not None:
                starts.append(r[f"e{n}_{h}_start_max"])
        if row:
            want = max(starts) if starts else None
            if not eq(row[7], want):
                bad(f"e{n} start_max != err_hist estart_max")
        if ok and is_int(iters) and n > iters:
            for h in HEIGHTS:
                for suf in ("int_rms", "int_p99", "int_max"):
                    if r.get(f"e{n}_{h}_{suf}") != 0:
                        bad(f"e{n}_{h}_{suf} != 0 after the stop at ok")
    if slices_dir is not None:
        check_slice(r, snap, slices_dir, bad)


def check_slice(r, snap, d, bad):
    stem = f"{r['case_id']}__{r['variant']}__{r['start']}"
    bj, bb = d / f"{stem}.json", d / f"{stem}.bin"
    if not (bj.is_file() and bb.is_file()):
        bad("no slice files")
        return
    try:
        m = json.loads(bj.read_text())
    except Exception as e:  # noqa: BLE001
        bad(f"slice json: {e}")
        return
    for k, t in (("version", 1), ("agl_m", [10.0, 50.0, 300.0]), ("comps", ["u", "v", "w"])):
        if m.get(k) != t:
            bad(f"slice json {k}")
    want_fields = ["ref"] + [f"n{n}" for n in snap["n_eval"]]
    if m.get("fields") != want_fields:
        bad(f"slice json fields {m.get('fields')}")
    for k in ("case_id", "variant", "start", "status", "iters", "ref_kind"):
        if m.get(k) != r.get(k):
            bad(f"slice json {k}")
    nx, ny = m.get("nx"), m.get("ny")
    if not (is_int(nx) and is_int(ny)):
        bad("slice json nx, ny")
        return
    size = 4 * len(want_fields) * 3 * 3 * ny * nx
    if bb.stat().st_size != size:
        bad(f"slice bin size {bb.stat().st_size} != {size}")


def estimate(recs, full):
    """(est_full_h, est_split_h) по пилоту; None — оценить нечем."""
    pil = {}
    for r in recs:
        if r.get("status") in ("ok", "max") and r.get("iters"):
            pil[(r["start"], r["heat"])] = r
    total = split = 0.0
    n = 0
    threads_ok = True
    for place, d, u, heat in cases_of(full):
        it = expected_iters(u, full["max_iters"])
        for s in full["starts"]:
            r = pil.get((s, heat))
            if r is None:
                continue
            per = (r["t_start_s"] + r["t_solve_s"]) / r["iters"]
            total += per * it
            split += r["t_start_s"] + r["t_solve_s"] / r["iters"] * it
            n += 1
    if n == 0:
        return None
    return total / 3600.0, split / 3600.0


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("jsonl")
    ap.add_argument("--spec", required=True)
    ap.add_argument("--slices")
    ap.add_argument("--full-spec")
    a = ap.parse_args()
    spec = json.loads(Path(a.spec).read_text())
    ids = {case_id(*c) for c in cases_of(spec)}
    recs, problems, seen = [], [], set()
    for ln, line in enumerate(Path(a.jsonl).read_text().splitlines(), 1):
        if not line.strip():
            continue
        try:
            r = json.loads(line)
        except Exception as e:  # noqa: BLE001
            problems.append(f"line {ln}: json: {e}")
            continue
        recs.append(r)
        key = (r.get("case_id"), r.get("variant"), r.get("start"))
        if key in seen:
            problems.append(f"{key}: repeated")
        seen.add(key)
        check_record(r, spec, ids, Path(a.slices) if a.slices else None, problems)
    bad_recs = {p.split(":")[0] for p in problems}
    out = f"OB4: records={len(recs)} invalid={len(bad_recs)}"
    if a.full_spec:
        full = json.loads(Path(a.full_spec).read_text())
        est = estimate(recs, full)
        if est is None:
            out += " est_full_h=nan"
        else:
            out += f" est_full_h={est[0]:.1f} est_split_h={est[1]:.1f}"
    print(out)
    for p in problems[:5]:
        print("  " + p)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
