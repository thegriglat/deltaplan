#!/usr/bin/env python3
"""Итог профиля кадра (PF-1): таблицы markdown из build/perf/<run>/*.jsonl (tools/bench/frame_profile.sh).

    python3 tools/bench/frame_profile_report.py build/perf/run1 > build/perf/run1/report.md

Разделы: база по отметкам; опыты (Δ GPU и Δ кадра к среднему base/base2); проходы GPU базы;
пересчёт поля воздуха в полёте (кадры idle/busy, порции DP_AIR_CHUNK_LOG); рывки > 50 мс.
"""
import glob
import json
import os
import statistics
import sys
from collections import defaultdict


def load(run):
    rows = []
    for f in sorted(glob.glob(os.path.join(run, "*.jsonl"))):
        if f.endswith("_air_chunks.jsonl"):
            continue
        for line in open(f):
            line = line.strip()
            if line:
                rows.append(json.loads(line))
    return rows


def f2(x):
    return f"{x:.2f}"


def main(run):
    rows = load(run)
    exp_rows = [r for r in rows if r.get("exp") and not r["exp"].startswith(("_", "air", "fly", "cpu"))]
    fly = [r for r in rows if r.get("exp") == "fly"]
    env = [r for r in rows if r.get("exp") == "_env"]
    out = []
    p = out.append

    p("## Окружение\n")
    seen = set()
    for r in env:
        if (r["tag"], r["loc"]) in seen:
            continue
        seen.add((r["tag"], r["loc"]))
        p(f"- {r['tag']} / {r['loc']}: `{json.dumps(r['env'], ensure_ascii=False)}`")
    p("")

    # ---- база
    base = defaultdict(dict)  # (tag, loc, cam, t) -> exp -> row
    for r in exp_rows:
        base[(r["tag"], r["loc"], r["cam"], r["t"])][r["exp"]] = r
    p("## База (пауза на отметке, среднее base и base2)\n")
    p("| пресет | место | ракурс@с | кадр, мс | 1%-худших, мс | GPU окна, мс | GPU 1%, мс | CPU отрисовки, мс | process макс. за 1 с, мс | вызовов | примитивов, тыс. | облаков |")
    p("|---|---|---|---|---|---|---|---|---|---|---|---|")
    for k in sorted(base):
        e = base[k]
        bs = [e[x] for x in ("base", "base2") if x in e]
        if not bs:
            continue
        m = lambda key: statistics.mean(b.get(key, 0.0) for b in bs)
        p(f"| {k[0]} | {k[1]} | {k[2]}@{k[3]:.0f} | {f2(m('frame_ms'))} | {f2(m('frame_ms_1pct'))} | "
          f"{f2(m('gpu_ms'))} | {f2(m('gpu_ms_1pct'))} | {f2(m('cpu_render_ms'))} | {f2(m('process_ms'))} | "
          f"{m('draw_calls'):.0f} | {m('primitives') / 1000:.0f} | {bs[0].get('cloud_count', '—')} |")
    p("")

    if fly:
        p("## Полёт без паузы (настоящая нагрузка CPU), VSync и предел кадров сняты\n")
        p("| пресет | место | ракурс@с | кадр, мс | 1%-худших, мс | GPU окна, мс | GPU 1%, мс | CPU отрисовки, мс | process макс. за 1 с, мс | physics макс. за 1 с, мс | вызовов |")
        p("|---|---|---|---|---|---|---|---|---|---|---|")
        for r in sorted(fly, key=lambda r: (r["tag"], r["loc"], r["t"])):
            p(f"| {r['tag']} | {r['loc']} | {r['cam']}@{r['t']:.0f} | {f2(r['frame_ms'])} | {f2(r['frame_ms_1pct'])} | "
              f"{f2(r['gpu_ms'])} | {f2(r['gpu_ms_1pct'])} | {f2(r['cpu_render_ms'])} | {f2(r['process_ms'])} | "
              f"{f2(r['physics_ms'])} | {r['draw_calls']:.0f} |")
        p("")

    # ---- опыты
    p("## Опыты: Δ GPU окна к базе, мс (в скобках — % от GPU базы); по отметкам\n")
    tags = sorted({(k[0], k[1]) for k in base})
    exps = []
    for r in exp_rows:
        if r["exp"] not in exps and r["exp"] not in ("base", "base2"):
            exps.append(r["exp"])
    for tag, loc in tags:
        keys = [k for k in sorted(base) if k[0] == tag and k[1] == loc]
        p(f"### {tag} / {loc}\n")
        p("| опыт | " + " | ".join(f"{k[2]}@{k[3]:.0f}" for k in keys) + " | среднее Δ, мс | среднее, % |")
        p("|---|" + "---|" * (len(keys) + 2))
        for ex in exps:
            cells, ds, pcs = [], [], []
            for k in keys:
                e = base[k]
                bs = [e[x]["gpu_ms"] for x in ("base", "base2") if x in e]
                if ex not in e or not bs:
                    cells.append("—")
                    continue
                b = statistics.mean(bs)
                d = e[ex]["gpu_ms"] - b
                ds.append(d)
                pcs.append(100 * d / b if b else 0)
                cells.append(f"{d:+.2f} ({100 * d / b:+.0f} %)")
            if ds:
                p(f"| {ex} | " + " | ".join(cells) + f" | {statistics.mean(ds):+.2f} | {statistics.mean(pcs):+.0f} |")
        # шум: base2 - base
        noise = []
        for k in keys:
            e = base[k]
            if "base" in e and "base2" in e:
                noise.append(e["base2"]["gpu_ms"] - e["base"]["gpu_ms"])
        if noise:
            p(f"\nШум (base2 − base): {', '.join(f'{x:+.2f}' for x in noise)} мс\n")

    # ---- проходы
    p("## Проходы GPU (метки движка, --gpu-profile), база, мс/кадр\n")
    for tag, loc in tags:
        keys = [k for k in sorted(base) if k[0] == tag and k[1] == loc]
        names = defaultdict(list)
        totals = []
        for k in keys:
            b = base[k].get("base")
            if not b or "passes" not in b:
                continue
            totals.append(b["passes"].get("_total", 0))
            for n, v in b["passes"].items():
                names[n].append(v)
        if not totals:
            continue
        tot = statistics.mean(totals)
        p(f"### {tag} / {loc} (всего {f2(tot)} мс)\n")
        p("| проход | " + " | ".join(f"{k[2]}@{k[3]:.0f}" for k in keys) + " | среднее | доля |")
        p("|---|" + "---|" * (len(keys) + 2))
        ranked = sorted(((n, statistics.mean(v)) for n, v in names.items() if n != "_total"), key=lambda x: -x[1])
        for n, v in ranked[:14]:
            vals = names[n]
            p(f"| {n} | " + " | ".join(f2(x) for x in vals) + f" | {f2(v)} | {100 * v / tot:.1f} % |")
        p("")

    # ---- воздух
    air = [r for r in rows if r.get("exp", "").startswith("air")]
    if air:
        p("## Пересчёт поля воздуха в полёте (без паузы)\n")
        p("| пресет | место | состояние | кадров | кадр, мс | 1%-худших, мс | GPU окна, мс | доля кадров с занятым AirRuntime | стена пересчёта, с |")
        p("|---|---|---|---|---|---|---|---|---|")
        groups = defaultdict(list)
        for r in air:
            groups[(r["tag"], r["loc"], r["exp"])].append(r)
        for (tag, loc, ex), rs in sorted(groups.items()):
            fr = [x for r in rs for x in r.get("frames_list", [])]
            gp = [x for r in rs for x in r.get("gpu_list", [])]
            bz = [x for r in rs for x in r.get("air_busy", [])]
            if not fr:
                continue
            s = sorted(fr)
            n1 = max(1, len(s) // 100)
            p(f"| {tag} | {loc} | {ex} | {len(fr)} | {f2(statistics.mean(fr))} | {f2(statistics.mean(s[-n1:]))} | "
              f"{f2(statistics.mean(gp))} | {100 * sum(bz) / max(1, len(bz)):.0f} % | {rs[0].get('wall_s', '—')} |")
        p("")
    chunks = sorted(glob.glob(os.path.join(run, "*_air_chunks.jsonl")))
    if chunks:
        p("## Порции GPU задач воздуха (DP_AIR_CHUNK_LOG: загрузка и пересчёт)\n")
        p("| файл | задача | порций | GPU всего, мс | средн. порция, мс | макс. порция, мс | запусков | запусков/порцию |")
        p("|---|---|---|---|---|---|---|---|")
        for f in chunks:
            by = defaultdict(list)
            for line in open(f):
                if line.strip():
                    r = json.loads(line)
                    by[r["job"]].append(r)
            for job, rs in by.items():
                g = [r["gpu_ms"] for r in rs]
                it = sum(r["items"] for r in rs)
                p(f"| {os.path.basename(f)} | {job} | {len(rs)} | {sum(g):.0f} | {f2(statistics.mean(g))} | "
                  f"{f2(max(g))} | {it} | {it / len(rs):.0f} |")
        p("")

    # ---- CPU по поддеревьям и периодические работы
    cpu = [r for r in rows if r.get("exp") in ("cpu_off", "cpu_base")]
    if cpu:
        p("## CPU: поддеревья Game выключены по очереди (полёт, chase)\n")
        p("Δ — к среднему соседних замеров cpu_base. Шум ±1–2 мс: смотреть только крупное.\n")
        p("| пресет | место | узел (класс) | кадр, мс | Δ кадра, мс | 1%-худших, мс | GPU, мс |")
        p("|---|---|---|---|---|---|---|")
        groups = defaultdict(list)
        for r in cpu:
            groups[(r["tag"], r["loc"])].append(r)
        for (tag, loc), rs in sorted(groups.items()):
            for i, r in enumerate(rs):
                if r["exp"] != "cpu_off":
                    continue
                nb = [x["frame_ms"] for x in (rs[i - 1] if i > 0 else None, rs[i + 1] if i + 1 < len(rs) else None)
                      if x and x["exp"] == "cpu_base"]
                d = r["frame_ms"] - statistics.mean(nb) if nb else 0.0
                p(f"| {tag} | {loc} | {r['node']} ({r['cls']}) | {f2(r['frame_ms'])} | {d:+.2f} | "
                  f"{f2(r['frame_ms_1pct'])} | {f2(r['gpu_ms'])} |")
        p("")
    micro = [r for r in rows if r.get("exp") == "_micro"]
    if micro:
        p("## Периодические работы главного потока (5 вызовов, мс на вызов)\n")
        p("| пресет | место | работа | среднее, мс | худший, мс |")
        p("|---|---|---|---|---|")
        for r in micro:
            for k, v in r["micro"].items():
                p(f"| {r['tag']} | {r['loc']} | {k} | {f2(v['mean'])} | {f2(v['max'])} |")
        p("")

    # ---- рывки
    hit = [r for r in rows if r.get("exp") == "_hitches"]
    if hit:
        p("## Рывки > 50 мс за прогон (не на паузе)\n")
        p("| пресет | место | рывки (мс @ сим.с, стадия AirRuntime) |")
        p("|---|---|---|")
        for r in hit:
            hs = [h for h in r["hitches"] if not h["paused"]]
            p(f"| {r['tag']} | {r['loc']} | " + ", ".join(
                f"{h['ms']:.0f}@{h['sim_t']:.1f}/{h['air_stage']}" for h in hs) + " |")
        p("")
    print("\n".join(out))


if __name__ == "__main__":
    main(sys.argv[1])
