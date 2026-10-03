#!/usr/bin/env python3
"""P3E8: признаки сходимости случаев (метаданные П1), правило «уверенно», списки обучения/проверки, охват.
  .venv/bin/python p3/p3e8_conv.py   → p3/out/p3e8/{conv_stats.json,conv_stats.md}, $AIR_NN_DATA/pilot/runs/2026-10-04_p3e8/conf_ids.json
"""
import json, sys, collections
from pathlib import Path
import numpy as np
HERE = Path(__file__).resolve().parents[1]; sys.path.insert(0, str(HERE))
from pilotnn import common as C
from pilotnn.data import Datasets, solution_info, confident, CONF_ITERS_FRAC
RUN = "2026-10-04_p3e8"
cfg = C.load_config(HERE/"config.yaml"); base = C.expand(cfg["paths"]["base"], cfg)
p2 = base/"runs"/cfg["p3"]["p2_run"]
info2 = json.loads((p2/"run_info.json").read_text())
D = Datasets([(d["name"], d["root"]) for d in info2["datasets"]])
rows = {r["id"]: r for r in D.case_rows()}
t = json.loads((base/"runs"/cfg["p3"]["run"]/"v0_ctrl/net/task.json").read_text())
split = json.loads((p2/"split.json").read_text())
out = HERE/"p3/out/p3e8"; out.mkdir(parents=True, exist_ok=True)
run = base/"runs"/RUN; run.mkdir(parents=True, exist_ok=True)
L = ["# P3E8: сходимость случаев", ""]
S = {}
mx = lambda r: float((r.get("solver") or {}).get("max_outer") or 3000)
ids_all = t["train_ids"] + t["val_ids"]
L += ["## Признаки в метаданных (П1)", "",
      "- `runs.d400_h/d400_m.status`: `ok` (критерий решателя выполнен, цель — конечное состояние), `max` (предел итераций, цель — среднее поздних снимков `late_mean` у terrain, последнее состояние `last` у main v1);",
      "- `runs.*.iters` — число внешних итераций до остановки (предел `solver.max_outer`: terrain 1000, main 3000);",
      "- `runs.*.late_spread60_p90`, `late_n`, `late_its` — только у `max` terrain: p90 разброса ветра на 60 м между поздними снимками, м/с;",
      "- невязки и истории нет: критерий — внутри решателя, наружу пишется только статус и iters.", ""]
for key in ("d400_h", "d400_m"):
    for ds in ("main", "terrain"):
        it = np.array([rows[i]["runs"][key]["iters"] for i in ids_all if rows[i]["ds"] == ds and rows[i]["runs"][key]["status"] == "ok"])
        S[f"iters_ok_{key}_{ds}"] = dict(n=len(it), q=dict(zip(("p50", "p75", "p90", "p95", "p99", "max"), np.percentile(it, [50, 75, 90, 95, 99, 100]).round().tolist())))
sp = np.array([rows[i]["runs"]["d400_h"]["late_spread60_p90"] for i in ids_all if rows[i]["runs"]["d400_h"]["status"] != "ok" and rows[i]["runs"]["d400_h"].get("late_spread60_p90") is not None])
S["late_spread_h_nc_terrain"] = dict(n=len(sp), q=dict(zip(("p10", "p25", "p50", "p75", "p90"), np.percentile(sp, [10, 25, 50, 75, 90]).round(3).tolist())))
L += ["## Распределения (обучение + проверка, 2400 случаев)", "", "| что | n | p50 | p75 | p90 | p95 | p99 | max |", "|---|---|---|---|---|---|---|---|"]
for k, v in S.items():
    if k.startswith("iters_ok"):
        q = v["q"]; L.append(f"| iters, ok, {k[9:]} | {v['n']} | {q['p50']} | {q['p75']} | {q['p90']} | {q['p95']} | {q['p99']} | {q['max']} |")
L.append(f"\nРазброс поздних состояний у несошедших h (terrain, n={S['late_spread_h_nc_terrain']['n']}), м/с: {S['late_spread_h_nc_terrain']['q']} — это сравнимо с самим ветром (0,3–2 м/с): цель «среднее поздних» шумная.\n")
L += ["## Правило «уверенно сошёлся»", "",
      f"Оба решения (`h` и `m`) со статусом `ok` и iters ≤ {CONF_ITERS_FRAC} · max_outer (terrain ≤ 300, main ≤ 900).",
      "Обоснование: статус `ok` — собственный критерий решателя (невязки наружу не пишутся). Запас: у `ok` медиана iters 60–120, p95 у terrain ≈ 260–320, у main 170–380; "
      "30 % предела отсекает хвост медленно сходящихся (у terrain ≈ 5–10 % из `ok`; у main ≈ 2–7 %), которые стоят у предела и по скорости близки к `max`. "
      "Колебаний в конце проверить нельзя — истории нет; для `ok` критерий означает, что изменение за итерацию ниже порога решателя. Сошедшиеся несошедшие (`max` с малым late-разбросом) в «уверенные» не входят: сходимость не подтверждена критерием.", ""]
# охват
def split_stats(name, ids):
    d = dict(n=len(ids), conf=sum(confident(rows[i]) for i in ids), ok_both=sum(solution_info(rows[i], "d400_h")["converged"] and solution_info(rows[i], "d400_m")["converged"] for i in ids))
    return d
sets = dict(train=t["train_ids"], val=t["val_ids"], holdout_sys=split["holdout_sys_ids"])
for n, ids in sets.items(): S[f"set_{n}"] = split_stats(n, ids)
conf_train = [i for i in t["train_ids"] if confident(rows[i])]; conf_val = [i for i in t["val_ids"] if confident(rows[i])]
S["places_train_before"] = len({rows[i]["loc"] for i in t["train_ids"]}); S["places_train_after"] = len({rows[i]["loc"] for i in conf_train})
S["places_val_before"] = len({rows[i]["loc"] for i in t["val_ids"]}); S["places_val_after"] = len({rows[i]["loc"] for i in conf_val})
ids_list = t["train_ids"] + t["val_ids"]
def bins(name, key, edges, lab):
    L.append(f"| {name} | " + " | ".join(
        f"{sum(confident(rows[i]) for i in ids_list if a <= key(rows[i]) < b)}/{sum(1 for i in ids_list if a <= key(rows[i]) < b)}" for a, b in edges) + " |")
L += ["## Охват: сколько случаев остаётся", "", "| набор | всего | оба ok | уверенно |", "|---|---|---|---|"]
for n in sets: v = S[f"set_{n}"]; L.append(f"| {n} | {v['n']} | {v['ok_both']} | {v['conf']} ({100*v['conf']/v['n']:.0f} %) |")
L.append(f"\nМест в обучении: {S['places_train_before']} → {S['places_train_after']}; в проверке: {S['places_val_before']} → {S['places_val_after']}.\n")
ue = ((0, 1), (1, 2), (2, 3), (3, 5), (5, 8), (8, 99))
L += ["Доля «уверенных» (уверенно/всего, обучение+проверка):", "", "| | " + " | ".join(f"U10 {a}–{b}" for a, b in ue) + " |", "|---|" + "---|"*len(ue)]
bins("по ветру U10, м/с", lambda r: r["U10"], ue, None)
he = ((0, 10), (10, 13), (13, 16), (16, 25))
L += ["", "| | " + " | ".join(f"час {a}–{b}" for a, b in he) + " |", "|---|" + "---|"*len(he)]
bins("по часу", lambda r: r["hour"], he, None)
L += ["", "| набор данных | всего | уверенно |", "|---|---|---|"]
for ds in ("main", "terrain"):
    ii = [i for i in ids_list if rows[i]["ds"] == ds]; L.append(f"| {ds} | {len(ii)} | {sum(confident(rows[i]) for i in ii)} |")
cnt = collections.Counter(rows[i]["loc"] for i in t["train_ids"]); cc = collections.Counter(rows[i]["loc"] for i in conf_train)
frac = sorted(cc.get(l, 0)/c for l, c in cnt.items())
S["place_conf_frac_q"] = np.percentile(frac, [0, 10, 25, 50, 75, 100]).round(2).tolist()
L.append(f"\nДоля «уверенных» случаев по местам обучения (мин, p10, p25, медиана, p75, макс): {S['place_conf_frac_q']}; мест без уверенных случаев: {sum(1 for l in cnt if cc.get(l,0)==0)}.")
# слабый ветер U10<1
w = [i for i in ids_list if rows[i]["U10"] < 1.0]
L.append(f"Слабый ветер U10 < 1 м/с: {sum(confident(rows[i]) for i in w)} из {len(w)} остаются — слабый ветер не выпадает целиком, но остаётся около половины.")
(out/"conv_stats.md").write_text("\n".join(L)+"\n"); (out/"conv_stats.json").write_text(json.dumps(S, ensure_ascii=False, indent=1))
C.atomic_write_json(run/"conf_ids.json", dict(train_ids=conf_train, val_ids=conf_val, frac=CONF_ITERS_FRAC))
print("\n".join(L))
