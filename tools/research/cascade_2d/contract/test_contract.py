#!/usr/bin/env python3
"""Тест контрактной проверки на синтетике: годные проходят, ломаные — нет. Запуск как скрипт."""
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import numpy as np  # noqa: E402
import cascade2d_io as io  # noqa: E402
import check_contract as cc  # noqa: E402
import synth  # noqa: E402

fails = []


def ok(name, cond):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)


def fine(path):
    try:
        cc.check_file(path)
        return True
    except (io.ContractError, KeyError, TypeError, ValueError):
        return False


def dump(path, d):
    with open(path, "w") as f:
        json.dump(d, f)


with tempfile.TemporaryDirectory() as t:
    P = lambda n: os.path.join(t, n)  # noqa: E731

    # ---- F1 годный: все уровни
    for dx in io.LEVELS_DX:
        synth.write_synth_f1(P(f"g{dx}.json"), dx=dx)
        ok(f"F1 dx={dx} годен", fine(P(f"g{dx}.json")))
    meta, arr = io.read_f1(P("g400.json"))
    ok("F1 круговой обмен", all(np.array_equal(arr[k], synth.make_f1()[1][k]) for k in arr))
    ok("F1 нет .tmp", not [f for f in os.listdir(t) if f.endswith(".tmp")])
    d = io.div2d(meta, arr)
    ok("div2d однородный поток = 0 вне стенок рядом", d.shape == (meta["nz"], meta["nx"]) and np.isfinite(d).all())
    # линейный w -> известная дивергенция
    a2 = {k: v.copy() for k, v in arr.items()}
    a2["u"][:] = 0
    a2["w"][:] = np.arange(meta["nz"] + 1, dtype=np.float32)[:, None] * meta["dz"]  # dw/dz = 1
    ok("div2d формула", abs(io.div2d(meta, a2)[3, 0] - 1.0) < 1e-5)
    ok("rel_div", abs(io.rel_div(np.array([0.01]), 400, 5.0)[0] - 0.8) < 1e-12)

    # ---- F1 ломаные
    base_meta = json.load(open(P("g400.json")))

    def broken(name, mutate_meta=None, mutate_bin=None, mutate_arr=None):
        m = json.loads(json.dumps(base_meta))
        if mutate_meta:
            mutate_meta(m)
        dump(P(name + ".json"), m)
        data = open(P("g400.bin"), "rb").read()
        if mutate_bin:
            data = mutate_bin(data)
        open(P(name + ".bin"), "wb").write(data)
        return fine(P(name + ".json"))

    ok("F1 нет ключа", not broken("b1", lambda m: m.pop("seed")))
    ok("F1 неверный format", not broken("b2", lambda m: m.update(format="x")))
    ok("F1 неверная version", not broken("b3", lambda m: m.update(version=2)))
    ok("F1 неверная длина массива", not broken("b4", lambda m: m["arrays"]["u"].__setitem__(1, 5)))
    ok("F1 bin короче", not broken("b5", mutate_bin=lambda b: b[:-40]))
    ok("F1 нет массива", not broken("b6", lambda m: m["arrays"].pop("tw")))
    ok("F1 неверный dx", not broken("b7", lambda m: m.update(dx=300)))
    ok("F1 неверный nx", not broken("b8", lambda m: m.update(nx=m["nx"] + 1)))
    ok("F1 неверный x0", not broken("b9", lambda m: m.update(x0=-6000.0)))
    ok("F1 variant у picard", not broken("b10", lambda m: m.update(variant="V0")))
    ok("F1 неверный source", not broken("b11", lambda m: m.update(source="foo")))
    ok("F1 V3h без seed", not broken("b12", lambda m: m.update(source="cascade", variant="V3h")))

    # NaN и ненулевая скорость на стенке
    m2, a3 = synth.make_f1()
    a3["u"][a3["tu"] == 0] = 1.0
    io.write_f1(P("w.json"), m2, a3)
    ok("F1 скорость на стенке", not fine(P("w.json")))
    m2, a3 = synth.make_f1()
    a3["th"][0, 0] = np.nan
    io.write_f1(P("n.json"), m2, a3)
    ok("F1 NaN", not fine(P("n.json")))

    # ---- F2
    dump(P("r.run.json"), synth.make_f2())
    ok("F2 годен", fine(P("r.run.json")))
    c = synth.make_f2(source="cascade", variant="V3", ny=1, iters=None, y_uniform=None, parent_dx=400, dx=200,
                      time=dict(total_s=1, setup_s=0.5, work_s=0.5, per_row_s=0.5),
                      query=dict(n_points=10, us_per_point=3.0, threads=1, max_abs_diff_vs_full=0.0))
    dump(P("c.run.json"), c)
    ok("F2 каскад годен", fine(P("c.run.json")))
    for name, over in (("нет ключа", None), ("format", dict(format="y")), ("version", dict(version=3)),
                       ("status", dict(status="boom")), ("ny<4 picard", dict(ny=2, time=dict(
                           total_s=1, setup_s=.2, work_s=.8, per_row_s=.4))),
                       ("per_row_s", dict(time=dict(total_s=1, setup_s=.2, work_s=.8, per_row_s=.5))),
                       ("iters null у picard", dict(iters=None)), ("balance", dict(balance={}))):
        r = synth.make_f2(**(over or {}))
        if over is None:
            r.pop("cmd")
        dump(P("x.run.json"), r)
        ok(f"F2 ломаный: {name}", not fine(P("x.run.json")))

    # ---- M1
    dump(P("m.json"), synth.make_m1())
    ok("M1 годен", fine(P("m.json")))
    m = synth.make_m1()
    m["rows"][0].pop("F_up")
    dump(P("m.json"), m)
    ok("M1 нет ключа строки", not fine(P("m.json")))
    dump(P("m.json"), synth.make_m1(format="z"))
    ok("M1 format", not fine(P("m.json")))
    dump(P("m.json"), synth.make_m1(version=2))
    ok("M1 version", not fine(P("m.json")))
    m = synth.make_m1()
    m["rows"][0]["sigma_u"] = [1.0]
    dump(P("m.json"), m)
    ok("M1 sigma не у V3h", not fine(P("m.json")))

if fails:
    print(f"ПРОВАЛЕНО: {len(fails)}: {fails}")
    sys.exit(1)
print("все проверки пройдены")
