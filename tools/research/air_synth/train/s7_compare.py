"""SY-11: сравнение старой сети игры (data/air_nn/model.onnx, ORT на CPU) с первым обучением (снимок ep130 и best.pt) на 20 holdout и 4 местах игры,
метрика S7, все срезы, с нагревом и без -> out/eval_compare_old.{json,md}. Финал (учился на этих местах) в сравнение не входит — только строка
«финал на случайных 480 случаях обучающих мест» как санитарная проверка (--final-onnx).
Пересечение мест с обучением старой сети — по координатам (центр места, км) и по именам встроенных мест (README пилота: пул = P6 part=pool + встроенные места кроме ongudai)."""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import s7_data as D  # noqa: E402
import s7_eval as E  # noqa: E402

OLD = HERE.parents[3] / "data/air_nn/model.onnx"
RUN = Path.home() / "air_synth_data/train/hgw24_p2"
HG = RUN / "cache/hg_v2__hgw24__s0-939a467"
GM = RUN / "cache/game2__hgw24__s0-939a467"
REAL = Path.home() / "air_synth_data/real"
BUILTIN_IN_OLD_POOL = {"askarovo", "aushkul", "altai"}   # встроенные места игры в пуле обучения старой сети; ongudai — вне обучения и проверки (README пилота, «Деление v3»)


class OrtNet:
    """Обёртка ORT под интерфейс E.predict (batch 1, как у игры)."""
    def __init__(self, path, threads=4):
        import onnxruntime as ort
        so = ort.SessionOptions(); so.intra_op_num_threads = threads
        self.s = ort.InferenceSession(str(path), so, providers=["CPUExecutionProvider"])

    def to(self, *a, **k):
        return self

    def eval(self):
        return self

    def float(self):
        return self

    def __call__(self, x, f):
        import torch
        o = [self.s.run(None, dict(maps=x[i:i + 1].numpy(), nums=f[i:i + 1].numpy()))[0] for i in range(len(x))]
        return torch.from_numpy(np.concatenate(o))


def km(a, b):
    la, lb = np.radians(a["lat_deg"])[:, None], np.radians(b["lat_deg"])[None]
    dl = np.radians(a["lon_deg"][:, None] - b["lon_deg"][None])
    x = np.sin((lb - la) / 2) ** 2 + np.cos(la) * np.cos(lb) * np.sin(dl / 2) ** 2
    return 2 * 6371 * np.arcsin(np.sqrt(x))


def overlap():
    import h5py
    pl = lambda p: h5py.File(REAL / p / "corpus.h5")["place"][:]  # noqa: E731
    p6, hg, g = pl("p6v3"), pl("hg_v2"), pl("game_hg2")
    pool = p6[p6["part"] == b"pool"]
    hold = hg[hg["part"] == b"holdout"]
    res = dict(criterion=("центры мест ближе 1 км (то же место) или имя места игры среди встроенных мест пула старой сети (askarovo, aushkul, altai); "
                          "отдельно — ближайший обучающий (P6 part=pool) центр, км; область домена 38,4 км, т.е. ближе ~19 км области перекрываются"),
               old_training_pool="P6 part=pool (p6v3, 300 мест) + встроенные места игры кроме ongudai + синтетика/процедурные (README пилота, «Деление v3»)",
               holdout_same_place=[], game=[], holdout_nearest=[])
    for a, nm in ((hold, "holdout"), (g, "game")):
        d = km(a, pool)
        for i, r in enumerate(a):
            name = r["name"].decode()
            near = float(d[i].min())
            if nm == "holdout":
                if near < 1:
                    res["holdout_same_place"].append(name)
                res["holdout_nearest"].append(dict(name=name, nearest_pool_km=round(near, 2)))
            else:
                res["game"].append(dict(name=name, nearest_pool_km=round(near, 1), in_old_training=name in BUILTIN_IN_OLD_POOL,
                                        note="встроенное место игры в пуле обучения старой сети" if name in BUILTIN_IN_OLD_POOL else "вне обучения и проверки старой сети"))
    res["holdout_nearest"].sort(key=lambda r: r["nearest_pool_km"])
    res["holdout_nearest"] = res["holdout_nearest"][:5]
    res["overlap_places"] = res["holdout_same_place"] + [r["name"] for r in res["game"] if r["in_old_training"]]
    return res


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=str(HERE / "out"))
    ap.add_argument("--final-onnx", default=None)
    a = ap.parse_args()
    out = Path(a.out)
    tc = D.Cache([HG])
    thr = E.thresholds({k: v[tc.select(0)] for k, v in tc.meta.items()})
    ho, gm = D.Cache([HG]), D.Cache([GM])
    hi, gi = ho.select(1), gm.select(2)
    nets = {"old": OrtNet(OLD), "first_ep130": E.load_model(RUN / "val/ckpt/ep130.pt")[0], "first_best_ep102": E.load_model(RUN / "val/ckpt/best.pt")[0]}
    res = {}
    for k, net in nets.items():
        res[k] = {}
        for nm, c, idx in (("holdout", ho, hi), ("game", gm, gi)):
            res[k][nm] = E.evaluate(net, c, idx, thr, "cpu", bs=1)["slices"]
        print(k, res[k]["holdout"]["all"]["heat"].get("median_60m"), res[k]["game"]["all"]["heat"].get("median_60m"), flush=True)
    doc = dict(contract="S7 v1", thresholds=thr, nets={"old": str(OLD), "first_ep130": "val/ckpt/ep130.pt", "first_best_ep102": "val/ckpt/best.pt"}, results=res,
               overlap_old_training=overlap())
    if a.final_onnx:
        rng = np.random.default_rng(0)
        idx = np.sort(rng.choice(ho.select(0), 480, replace=False))
        doc["final_sanity_train_places"] = dict(onnx=a.final_onnx, n_cases=480,
                                                slices=E.evaluate(OrtNet(a.final_onnx), ho, idx, thr, "cpu", bs=1)["slices"]["all"],
                                                first_ep130_same_cases=E.evaluate(nets["first_ep130"], ho, idx, thr, "cpu", bs=1)["slices"]["all"])
    (out / "eval_compare_old.json").write_text(json.dumps(doc, indent=1, ensure_ascii=False))
    # --- md
    md = ["# Сравнение: старая сеть игры (`data/air_nn/model.onnx`) и первое обучение P2 на местах дельтаплана (S7 v1, 60 м)", "",
          "Те же 20 отложенных мест (480 случаев) и 4 места игры (96 случаев), поле с нагревом (главное) и без. Медиана, p90 — м/с пулом клеток; отн. — |ΔV|/max(U10,1). "
          "«Первое обучение» — снимок ep130 (по нему выбрана эпоха финала) и best.pt (ep102).", ""]
    ov = doc["overlap_old_training"]
    md += ["## Пересечение мест с обучением старой сети", "", f"Критерий: {ov['criterion']}.", "",
           f"- holdout, то же место (<1 км): {ov['holdout_same_place'] or 'нет'}; ближайшие к обучающему центру P6: " +
           ", ".join(f"{r['name']} {r['nearest_pool_km']} км" for r in ov["holdout_nearest"]),
           "- места игры: " + "; ".join(f"{r['name']} — {r['note']}" for r in ov["game"]),
           "- вывод: на holdout пересечения со старым обучением нет (честное сравнение); на местах игры три из четырёх (askarovo, aushkul, altai) старая сеть видела при обучении "
           "(встроенные места пула; рельеф/условия другие, чем в SY-12, но то же место) — сравнение там идёт в пользу старой сети, честно только ongudai.", ""]
    names = list(res["old"]["holdout"].keys())
    f = lambda d, k: d.get(k, float("nan"))  # noqa: E731
    wins = {}
    for part, title in (("holdout", "Отложенные места"), ("game", "Места игры")):
        for field, lab in (("heat", "с нагревом"), ("noheat", "без нагрева")):
            md += [f"## {title}, {lab}", "", "| срез | n | старая медиана | p90 | отн. | ep130 медиана | p90 | отн. | best(ep102) медиана | p90 | отн. | профиль притока медиана |", "|---|---|---|---|---|---|---|---|---|---|---|---|"]
            for n in names:
                o, e, b = (res[k][part][n][field] for k in ("old", "first_ep130", "first_best_ep102"))
                bs = res["old"][part][n]["base_" + field]
                if not o.get("n_cases"):
                    continue
                md.append(f"| {n} | {o['n_cases']} | {f(o,'median_60m'):.3f} | {f(o,'p90_60m'):.3f} | {f(o,'rel_median_60m'):.3f} | {f(e,'median_60m'):.3f} | {f(e,'p90_60m'):.3f} | "
                          f"{f(e,'rel_median_60m'):.3f} | {f(b,'median_60m'):.3f} | {f(b,'p90_60m'):.3f} | {f(b,'rel_median_60m'):.3f} | {f(bs,'median_60m'):.3f} |")
                wins.setdefault((part, field), []).append((n, f(e, "median_60m") < f(o, "median_60m"), f(e, "p90_60m") < f(o, "p90_60m"), f(e, "rel_median_60m") < f(o, "rel_median_60m")))
            md.append("")
    md += ["## Вывод", ""]
    for (part, field), v in wins.items():
        md.append(f"- {part}, {field}: ep130 лучше старой по медиане в {sum(x[1] for x in v)}/{len(v)} срезов, по p90 — {sum(x[2] for x in v)}/{len(v)}, по относительной — {sum(x[3] for x in v)}/{len(v)}.")
    h, g = res["old"]["holdout"]["all"]["heat"], res["old"]["game"]["all"]["heat"]
    e, eg = res["first_ep130"]["holdout"]["all"]["heat"], res["first_ep130"]["game"]["all"]["heat"]
    md += ["", f"- Итог (все случаи, с нагревом): holdout старая {h['median_60m']:.3f}/{h['p90_60m']:.3f} м/с (отн. {h['rel_median_60m']:.3f}) против первого обучения {e['median_60m']:.3f}/{e['p90_60m']:.3f} (отн. {e['rel_median_60m']:.3f}); "
           f"игра старая {g['median_60m']:.3f}/{g['p90_60m']:.3f} (отн. {g['rel_median_60m']:.3f}) против {eg['median_60m']:.3f}/{eg['p90_60m']:.3f} (отн. {eg['rel_median_60m']:.3f})."]
    if "final_sanity_train_places" in doc:
        s = doc["final_sanity_train_places"]
        md += ["", f"Санитарная проверка финала (ONNX, 480 случайных случаев обучающих мест, с нагревом): медиана {s['slices']['heat']['median_60m']:.3f}, p90 {s['slices']['heat']['p90_60m']:.3f}, "
               f"отн. {s['slices']['heat']['rel_median_60m']:.3f}; ep130 первого обучения на тех же случаях (они в его обучении): {s['first_ep130_same_cases']['heat']['median_60m']:.3f}."]
    (out / "eval_compare_old.md").write_text("\n".join(md) + "\n")


if __name__ == "__main__":
    main()
