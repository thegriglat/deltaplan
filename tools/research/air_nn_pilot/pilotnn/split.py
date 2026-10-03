"""Деление случаев v3 (контракт П2 v3, этап П-2) — детерминированно, по хешу id и зерну конфига.

  (б)  `holdout_places` (ongudai) — целиком вне обучения и проверки;
  (г)  отложенные горные системы — все места индекса П6 с `part = holdout` (главная оценка);
  (б′) `holdout_proc_n` процедурных мест с префиксом `holdout_proc_prefix` (первые по хешу (зерно, «hold», место));
  пул обучения — места П6 `part = pool` + встроенные кроме (б) + синтетика + прочие процедурные;
  (а)  у каждого места пула доля `newcond_frac` случаев — «новые условия» (тест), доля `val_frac` — проверка для
       ранней остановки, остальное — обучение (по хешу (зерно, id));
  (в)  кривая: вложенные подмножества мест П6 пула размером `curve_sizes` в порядке «по слоям `stratum` по кругу
       (слои — по имени), внутри слоя — по хешу (зерно, «curve», место)»; прочие места пула (не П6) входят в каждую
       точку; точка с полным пулом П6 = основная сеть (`is_main`, отдельно не обучается); оценка кривой — на (г) и (б).
  Без мест П6 (набор только v1) кривая идёт по всем местам пула в порядке хеша (как v2), прочих мест нет.
  Крошечные наборы (smoke): у места пула — не меньше одного случая обучения; нет случаев проверки — проверка
  по всему пулу, а если и там нет — по обучению (val_is_train; ранняя остановка тогда не значима).
"""
from __future__ import annotations

import hashlib


def u01(*parts) -> float:
    h = hashlib.sha256(":".join(str(p) for p in parts).encode()).digest()
    return int.from_bytes(h[:8], "big") / 2 ** 64


def curve_order(places, p6, seed):
    """Места П6 пула в порядке кривой: слои по имени, по кругу; внутри слоя — по хешу."""
    by = {}
    for l in places:
        by.setdefault(str(p6[l].get("stratum", "")), []).append(l)
    queues = [sorted(by[s], key=lambda l: (u01(seed, "curve", l), l)) for s in sorted(by)]
    out = []
    while any(queues):
        for q in queues:
            if q:
                out.append(q.pop(0))
    return out


def make_split(rows, sc, p6=None):
    """rows — строки случаев (поля id, loc); p6 — {место: строка индекса П6 (part, stratum, system)} или None."""
    seed = sc["seed"]
    p6 = p6 or {}
    locs = sorted({r["loc"] for r in rows})
    unknown = [l for l in locs if l.startswith("t_") and l not in p6]
    if unknown:
        raise ValueError(f"места t_* без строки в индексе П6: {unknown[:5]}")
    hold_places = [l for l in sc["holdout_places"] if l in locs]
    hold_sys = sorted(l for l in locs if l in p6 and p6[l]["part"] == "holdout")
    proc = sorted((l for l in locs if l.startswith(sc["holdout_proc_prefix"]) and l not in hold_places and l not in p6),
                  key=lambda l: (u01(seed, "hold", l), l))
    hold_proc = sorted(proc[: sc["holdout_proc_n"]])
    hold = set(hold_places) | set(hold_sys) | set(hold_proc)
    pool = sorted((l for l in locs if l not in hold), key=lambda l: (u01(seed, "curve", l), l))
    p6_pool = [l for l in pool if l in p6]
    others = sorted(l for l in pool if l not in p6)
    part = {}
    for r in rows:
        if r["loc"] in hold:
            part[r["id"]] = "holdout"
            continue
        u = u01(seed, r["id"])
        part[r["id"]] = ("newcond" if u < sc["newcond_frac"] else
                         "val" if u < sc["newcond_frac"] + sc["val_frac"] else "train")
    for loc in pool:                           # у каждого места пула — хотя бы один случай обучения
        mine = sorted((r["id"] for r in rows if r["loc"] == loc), key=lambda i: (-u01(seed, i), i))
        if mine and all(part[i] != "train" for i in mine):
            part[mine[0]] = "train"
    by = {}
    for r in rows:
        by.setdefault((part[r["id"]], r["loc"]), []).append(r["id"])

    def ids(kind, places):
        return sorted(i for l in places for i in by.get((kind, l), []))

    if p6_pool:
        order, base = curve_order(p6_pool, p6, seed), others
    else:                                        # набор без П6: кривая по всем местам пула (порядок хеша)
        order, base = pool, []
    curve = []
    val_all = ids("val", pool)
    for n in sc["curve_sizes"]:
        n_eff = min(n, len(order))
        if n_eff == 0 or (curve and curve[-1]["n_places"] == n_eff):
            continue
        pl = sorted(order[:n_eff] + base)
        c = dict(n=n, n_places=n_eff, places=pl, curve_places=sorted(order[:n_eff]), is_main=n_eff == len(order),
                 train_ids=ids("train", pl), val_ids=ids("val", pl))
        c["val_ids"] = c["val_ids"] or val_all or c["train_ids"]   # нет проверки у точки — весь пул, иначе обучение
        curve.append(c)
    return dict(seed=seed, holdout_places=hold_places, holdout_sys=hold_sys, holdout_proc=hold_proc,
                pool_order=pool, curve_order=order, curve_base=base, p6_pool=sorted(p6_pool), others=others,
                train_ids=ids("train", pool), val_ids=val_all or ids("train", pool), val_is_train=not val_all,
                newcond_ids=ids("newcond", pool), newcond_p6_ids=ids("newcond", p6_pool),
                newcond_old_ids=ids("newcond", others),
                holdout_place_ids=ids("holdout", hold_places), holdout_sys_ids=ids("holdout", hold_sys),
                holdout_proc_ids=ids("holdout", hold_proc), curve=curve)
