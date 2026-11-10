#!/usr/bin/env python3
"""Контрактный тест lee-turb (docs/contracts/lee-turb.md): LTL v1, LTO v1, LTS v1.

python3 check_contract.py <файл> [...]   — 0 формат верен, 1 нарушения, 2 ошибка чтения
python3 check_contract.py --selftest     — проверка самого теста
"""
import csv
import io
import math
import os
import re
import sys

LTL_COLS = "id,quantity,value,low,high,unit,flow,definition,source,where,reliability,note".split(",")
LTO_COLS = ("site,case,station,x_m,z_m,H_m,xr_m,x_game,z_game,u_ref_ms,u_ref_def,sigma_u_ms,sigma_v_ms,"
            "sigma_w_ms,tke_m2s2,uw_m2s2,L_u_m,n,stab,source,reliability,note").split(",")
LTS_COLS = "s,x,y,z,agl,u_par,u_perp,w,lee_f,du,u_h,shear,sigma_u,sigma_v,sigma_w,l_u,l_w,src".split(",")
FLOWS = {"mixing_layer_single", "mixing_layer_two", "step", "fence", "hill2d", "hill3d", "ridge_field",
         "escarpment", "general"}
REL = {"A", "B", "C"}
SRC = {"mech", "conv", "mix", "none"}
ID_RE = re.compile(r"^[a-z0-9_]+$")
CASE_RE = re.compile(r"^[A-Za-z0-9_]+$")
BAD_EMPTY = {"nan", "NaN", "NAN", "-", "?", "None", "null"}


def num(v):
    """float или None для пустого; ValueError — не число."""
    if v == "":
        return None
    x = float(v)
    if not math.isfinite(x):
        raise ValueError(v)
    return x


def _rows(text, cols, errs, skip_comment=False):
    lines = text.splitlines()
    if skip_comment:
        if not lines or not lines[0].startswith("# lts v1 "):
            errs.append("первая строка — не '# lts v1 …'")
            return []
        for key in ("case=", "time=", "git=", "model="):
            if key not in lines[0]:
                errs.append(f"в комментарии нет {key}")
        lines = lines[1:]
    rd = csv.reader(io.StringIO("\n".join(lines)))
    try:
        head = next(rd)
    except StopIteration:
        errs.append("пустой файл")
        return []
    if head != cols:
        errs.append(f"заголовок {head} != {cols}")
        return []
    out = []
    for i, r in enumerate(rd, start=2):
        if not r:
            continue
        if len(r) != len(cols):
            errs.append(f"стр {i}: {len(r)} полей вместо {len(cols)}")
            continue
        d = dict(zip(cols, r))
        for k, v in d.items():
            if v.strip() in BAD_EMPTY:
                errs.append(f"стр {i}: {k}={v!r} — пусто пишется пустой ячейкой")
        out.append((i, d))
    if not out:
        errs.append("нет строк данных")
    return out


def _nums(i, d, keys, errs):
    v = {}
    for k in keys:
        try:
            v[k] = num(d[k])
        except ValueError:
            errs.append(f"стр {i}: {k}={d[k]!r} не число")
            v[k] = None
    return v


def check_ltl(text):
    errs = []
    ids = set()
    for i, d in _rows(text, LTL_COLS, errs):
        if not ID_RE.match(d["id"]):
            errs.append(f"стр {i}: id {d['id']!r}")
        if d["id"] in ids:
            errs.append(f"стр {i}: id {d['id']} повторяется")
        ids.add(d["id"])
        if not ID_RE.match(d["quantity"]):
            errs.append(f"стр {i}: quantity {d['quantity']!r}")
        v = _nums(i, d, ["value", "low", "high"], errs)
        if v["value"] is None:
            errs.append(f"стр {i}: value пусто")
        if v["low"] is not None and v["value"] is not None and v["low"] > v["value"]:
            errs.append(f"стр {i}: low > value")
        if v["high"] is not None and v["value"] is not None and v["high"] < v["value"]:
            errs.append(f"стр {i}: high < value")
        if not d["unit"]:
            errs.append(f"стр {i}: unit пусто")
        if d["flow"] not in FLOWS:
            errs.append(f"стр {i}: flow {d['flow']!r}")
        for k in ("definition", "source"):
            if not d[k].strip():
                errs.append(f"стр {i}: {k} пусто")
        if d["reliability"] not in REL:
            errs.append(f"стр {i}: reliability {d['reliability']!r}")
    return errs


def check_lto(text):
    errs = []
    keys = set()
    for i, d in _rows(text, LTO_COLS, errs):
        if not ID_RE.match(d["site"]):
            errs.append(f"стр {i}: site {d['site']!r}")
        if not CASE_RE.match(d["case"]):
            errs.append(f"стр {i}: case {d['case']!r}")
        if not d["station"]:
            errs.append(f"стр {i}: station пусто")
        k = (d["site"], d["case"], d["station"])
        if k in keys:
            errs.append(f"стр {i}: повтор {k}")
        keys.add(k)
        v = _nums(i, d, ["x_m", "z_m", "H_m", "xr_m", "x_game", "z_game", "u_ref_ms", "sigma_u_ms",
                         "sigma_v_ms", "sigma_w_ms", "tke_m2s2", "uw_m2s2", "L_u_m", "n"], errs)
        for req in ("x_m", "z_m", "H_m", "u_ref_ms", "n"):
            if v[req] is None:
                errs.append(f"стр {i}: {req} пусто")
        for pos in ("z_m", "H_m", "u_ref_ms", "L_u_m", "xr_m"):
            if v[pos] is not None and v[pos] <= 0:
                errs.append(f"стр {i}: {pos} ≤ 0")
        for nn in ("sigma_u_ms", "sigma_v_ms", "sigma_w_ms", "tke_m2s2"):
            if v[nn] is not None and v[nn] < 0:
                errs.append(f"стр {i}: {nn} < 0")
        if v["n"] is not None and (v["n"] < 1 or v["n"] != int(v["n"])):
            errs.append(f"стр {i}: n не целое ≥ 1")
        if (v["x_game"] is None) != (v["z_game"] is None):
            errs.append(f"стр {i}: x_game/z_game — оба или ни одного")
        if all(v[s] is None for s in ("sigma_u_ms", "sigma_v_ms", "sigma_w_ms", "tke_m2s2")):
            errs.append(f"стр {i}: нет ни σ, ни tke")
        if not d["u_ref_def"].strip():
            errs.append(f"стр {i}: u_ref_def пусто")
        if d["stab"] != "neutral":
            try:
                num(d["stab"])
                if d["stab"] == "":
                    errs.append(f"стр {i}: stab пусто")
            except ValueError:
                errs.append(f"стр {i}: stab {d['stab']!r}")
        if not d["source"].strip():
            errs.append(f"стр {i}: source пусто")
        if d["reliability"] not in REL:
            errs.append(f"стр {i}: reliability {d['reliability']!r}")
    return errs


def check_lts(text):
    errs = []
    numcols = [c for c in LTS_COLS if c != "src"]
    always = ["s", "x", "y", "z", "agl"]
    for i, d in _rows(text, LTS_COLS, errs, skip_comment=True):
        v = _nums(i, d, numcols, errs)
        if d["src"] not in SRC:
            errs.append(f"стр {i}: src {d['src']!r}")
            continue
        for k in always:
            if v[k] is None:
                errs.append(f"стр {i}: {k} пусто")
        if v["agl"] is not None and v["agl"] < 0:
            errs.append(f"стр {i}: agl < 0")
        if d["src"] == "none":
            continue
        for k in numcols:
            if v[k] is None:
                errs.append(f"стр {i}: {k} пусто при src={d['src']}")
        if v["lee_f"] is not None and not (0.0 <= v["lee_f"] <= 1.0):
            errs.append(f"стр {i}: lee_f вне [0,1]")
        for k in ("du", "u_h", "shear", "sigma_u", "sigma_v", "sigma_w"):
            if v[k] is not None and v[k] < 0:
                errs.append(f"стр {i}: {k} < 0")
        for k in ("l_u", "l_w"):
            if v[k] is not None and v[k] <= 0:
                errs.append(f"стр {i}: {k} ≤ 0")
    return errs


def kind_of(path):
    b = os.path.basename(path)
    if b == "lit_numbers.csv":
        return check_ltl
    if b == "lee_obs.csv":
        return check_lto
    if b.endswith(".lts.csv"):
        return check_lts
    return None


def selftest():
    ok_ltl = ",".join(LTL_COLS) + "\n" + \
        'a1,ddelta_omega_dx,0.18,0.16,0.2,1,mixing_layer_single,"δ_ω=ΔU/max dU/dy, x от кромки",Brown & Roshko 1974,fig 9,B,\n'
    ok_lto = ",".join(LTO_COLS) + "\n" + \
        "perdigao,SW,tse09_20m,700,20,200,500,,,8.5,U100 tse04,1.2,1.0,0.8,1.9,-0.3,,12,neutral,ISFS 5-min,A,1 h\n"
    ok_lts = "# lts v1 case=x time=0 git=abc model=field\n" + ",".join(LTS_COLS) + "\n" + \
        "0,1,2,3,4,5,0,0.1,0.5,2,6,0.01,1,0.9,0.7,40,30,mix\n" + \
        "10,1,2,3,4,,,,,,,,,,,,,none\n"
    assert check_ltl(ok_ltl) == [], check_ltl(ok_ltl)
    assert check_lto(ok_lto) == [], check_lto(ok_lto)
    assert check_lts(ok_lts) == [], check_lts(ok_lts)
    assert check_ltl(ok_ltl.replace(",0.16,0.2,", ",0.19,0.2,"))  # low > value
    assert check_ltl(ok_ltl.replace("mixing_layer_single", "jet"))
    assert check_ltl(ok_ltl.replace(",B,", ",D,"))
    assert check_lto(ok_lto.replace(",200,500,", ",0,500,"))  # H ≤ 0
    assert check_lto(ok_lto.replace(",,,8.5,", ",1,,8.5,"))  # x_game без z_game
    assert check_lto(ok_lto.replace("1.2,1.0,0.8,1.9", ",,,"))  # нет σ и tke
    assert check_lto(ok_lto.replace(",12,", ",nan,"))
    assert check_lts(ok_lts.replace("mix", "rot"))
    assert check_lts(ok_lts.replace(",0.5,2,", ",1.5,2,"))  # lee_f > 1
    assert check_lts(ok_lts.replace("# lts v1", "# lts v2"))
    assert check_lts(ok_lts.replace(",40,30,", ",,30,"))
    assert check_ltl(ok_ltl.replace("id,", "ident,", 1))
    print("selftest ok")
    return 0


def main(argv):
    if argv[1:] == ["--selftest"]:
        return selftest()
    if len(argv) < 2:
        print(__doc__)
        return 2
    rc = 0
    for p in argv[1:]:
        f = kind_of(p)
        if f is None:
            print(f"{p}: неизвестный тип файла")
            return 2
        try:
            with open(p, encoding="utf-8") as fh:
                text = fh.read()
        except OSError as e:
            print(f"{p}: {e}")
            return 2
        errs = f(text)
        if errs:
            rc = 1
            print(f"{p}: {len(errs)} нарушений")
            for e in errs[:50]:
                print("  " + e)
        else:
            print(f"{p}: ok")
    return rc


if __name__ == "__main__":
    sys.exit(main(sys.argv))
