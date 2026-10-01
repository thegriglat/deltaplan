#!/usr/bin/env python3
"""SP-1: разбивка стены пересчёта в полёте по out/flight_*.json и out/w_*.json (flight_probe.gd).

    python3 tools/research/air_speed/analyze.py            # таблицы out/breakdown.md, out/breakdown.json
                                                            # графики out/fig_timeline_<имя>.png
"""
import glob
import json
import os
import statistics as st

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "out")
STAGES = {0: "IDLE", 1: "PREP", 2: "SOLVE", 3: "BUILD", 4: "WINDOWS", 5: "SHIFT"}


def mean(a):
    return st.mean(a) if a else float("nan")


def segments(frames):
    """[(метка, t0, t1)] — метка = этап (WINDOWS — с подэтапом окна) по кадрам; t — мс от запроса."""
    segs = []
    for f in frames:
        lab = STAGES.get(f["stage"], "?")
        if lab == "WINDOWS":
            lab = "W:" + f["sub"]
        if f["applied"] != frames[0]["applied"]:
            lab = "AFTER"
        if segs and segs[-1][0] == lab:
            segs[-1][2] = f["t"]
        else:
            if segs:
                segs[-1][2] = f["t"]
            segs.append([lab, f["t"], f["t"]])
    return segs


def run_row(name, env, run, idle):
    fr = run["frames"]
    t_apply = run["t_apply_ms"]
    before = [f for f in fr if f["t"] <= t_apply]
    after = [f for f in fr if f["t"] > t_apply]
    segs = segments(fr)
    dur = {}
    for lab, a, b in segs:
        if lab == "AFTER":
            continue
        key = lab.split(":")[0] if not lab.startswith("W:") else lab
        dur[key] = dur.get(key, 0.0) + (b - a)
    jobs = run.get("jobs", [])
    dom = [j for j in jobs if j["kind"] == "AirPicardJob"]
    win = [j for j in jobs if j["kind"] == "AirWindowJob"]
    solve = [f for f in before if f["stage"] == 2]
    # простои GPU между порциями области (метки GPU, нс)
    ch = sorted(run.get("chunks", []), key=lambda c: c["b"])
    gaps = [(ch[i + 1]["b"] - ch[i]["e"]) / 1e6 for i in range(len(ch) - 1)]
    row = {
        "name": name,
        "variant": env.get("variant"),
        "window": env.get("window"),
        "idle_frame_ms": mean([f["dt"] for f in idle]),
        "idle_render_gpu_ms": mean([f["rgpu"] for f in idle]),
        "wall_s": t_apply / 1000.0,
        "iters": run["info"].get("iters"),
        "windows_iters": [w.get("iters") for w in run.get("windows", [])],
        "stage_ms": dur,
        "solve_frames": len(solve),
        "solve_frame_ms": mean([f["dt"] for f in solve]),
        "solve_render_gpu_ms": mean([f["rgpu"] for f in solve]),
        "dom_gpu_ms": sum(j["gpu_ms"] or 0 for j in dom),
        "dom_chunks": sum(j["chunks"] for j in dom),
        "dom_chunk_gpu_ms_mean": mean([c[1] for j in dom for c in j["chunk_log"]]),
        "dom_record_cpu_ms": sum(j["record_cpu_ms"] for j in dom),
        "dom_poll_cpu_ms": sum(j["poll_cpu_ms"] for j in dom),
        "dom_sync_wait_ms": sum(j["sync_wait_ms"] for j in dom),
        "win_gpu_ms": sum(j["gpu_ms"] or 0 for j in win),
        "win_chunks": sum(j["chunks"] for j in win),
        "win_prep_ms": [w.get("prep_ms") for w in run.get("windows", [])],
        "gpu_gap_sum_ms": sum(gaps),
        "gpu_gap_mean_ms": mean(gaps),
        "rt_max_ms": max([f["rt_ms"] for f in before] or [0]),
        "frame_max_before_ms": max([f["dt"] for f in before] or [0]),
        "frame_max_after_ms": max([f["dt"] for f in after] or [0]),
        "frame_p95_before_ms": sorted(f["dt"] for f in before)[int(0.95 * len(before))] if before else 0,
    }
    return row


def thread_row(name, env, run, idle):
    fr = run["frames"]
    th = run["thread"]
    solve = [f for f in fr if run["t_prep_ms"] < f["t"] <= run["t_done_ms"]]
    return {
        "name": name,
        "variant": env.get("variant"),
        "window": env.get("window"),
        "idle_frame_ms": mean([f["dt"] for f in idle]),
        "idle_render_gpu_ms": mean([f["rgpu"] for f in idle]),
        "prep_ms": run["t_prep_ms"],
        "solve_wall_ms": run["t_done_ms"] - run["t_prep_ms"],
        "thread_wall_ms": th["wall_ms"],
        "gpu_ms": th["gpu_ms"],
        "record_cpu_ms": th["record_cpu_ms"],
        "chunks": th["chunks"],
        "max_chunk_gpu_ms": th["max_chunk_gpu_ms"],
        "iters": th["iters"],
        "solve_frame_ms": mean([f["dt"] for f in solve]),
        "solve_frame_p95_ms": sorted(f["dt"] for f in solve)[int(0.95 * len(solve))] if solve else 0,
        "solve_frame_max_ms": max([f["dt"] for f in solve] or [0]),
        "solve_render_gpu_ms": mean([f["rgpu"] for f in solve]),
    }


def fig(name, run, path):
    import matplotlib

    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fr = run["frames"]
    colors = {"PREP": "#8da0cb", "SOLVE": "#e78ac3", "BUILD": "#a6d854", "W:w0:prep": "#ffd92f",
              "W:w0:gpu": "#fc8d62", "W:w0:field": "#66c2a5", "W:w1:prep": "#ffd92f",
              "W:w1:gpu": "#d95f02", "W:w1:field": "#1b9e77", "AFTER": "#cccccc", "IDLE": "#eeeeee"}
    f, (a1, a2) = plt.subplots(2, 1, figsize=(11, 5), sharex=True, gridspec_kw={"height_ratios": [1, 3]})
    for lab, t0, t1 in segments(fr):
        a1.barh(0, (t1 - t0) / 1000, left=t0 / 1000, color=colors.get(lab, "#999999"), edgecolor="none")
        if (t1 - t0) > 600:
            a1.text((t0 + t1) / 2000, 0, lab.replace("W:", ""), ha="center", va="center", fontsize=7)
    a1.set_yticks([])
    a1.set_title(f"{name}: этапы пересчёта (стена {run['t_apply_ms'] / 1000:.1f} с)")
    t = [x["t"] / 1000 for x in fr]
    a2.plot(t, [x["dt"] for x in fr], lw=0.8, label="кадр, мс")
    a2.plot(t, [x["rgpu"] for x in fr], lw=0.8, label="отрисовка кадра (GPU), мс")
    a2.plot(t, [x["rt_ms"] for x in fr], lw=0.8, label="AirRuntime в главном потоке, мс")
    a2.set_ylim(0, min(200, max(x["dt"] for x in fr) * 1.1))
    a2.set_xlabel("с от запроса пересчёта")
    a2.legend(fontsize=8, loc="upper right")
    a2.grid(alpha=0.3)
    f.tight_layout()
    f.savefig(path, dpi=110)
    plt.close(f)


def main():
    rows, trows, therm = [], [], {}
    for p in sorted(glob.glob(os.path.join(OUT, "flight_*.json")) + glob.glob(os.path.join(OUT, "w_*.json"))):
        name = os.path.basename(p)[:-5]
        d = json.load(open(p))
        env = d["env"]
        for i, run in enumerate(d.get("runs", [])):
            if "thread" in run:
                trows.append(thread_row(f"{name}#{i}", env, run, d["idle"]))
            else:
                rows.append(run_row(f"{name}#{i}", env, run, d["idle"]))
                if i == 1:
                    fig(name, run, os.path.join(OUT, f"fig_timeline_{name}.png"))
        if "thermals" in d:
            therm[name] = d["thermals"]
    json.dump({"recompute": rows, "thread": trows, "thermals": therm}, open(os.path.join(OUT, "breakdown.json"), "w"),
              ensure_ascii=False, indent=1)
    L = ["# Пересчёт в полёте — разбивка (RTX 4070 SUPER; analyze.py)", "",
         "| прогон | окно | кадр покоя / отрисовка GPU, мс | стена, с | итераций обл. / окон | PREP | SOLVE (кадров; кадр мс) | GPU области, мс (порций; ср. порция) | простои GPU между порциями, мс | BUILD | окна: подготовка / GPU / поле (w0; w1), мс | макс. кадр до / после подачи, мс |",
         "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    for r in rows:
        s = r["stage_ms"]
        w = lambda k: s.get(k, 0)
        L.append(
            f"| {r['name']} | {r['window']} | {r['idle_frame_ms']:.0f} / {r['idle_render_gpu_ms']:.0f} | {r['wall_s']:.2f} | "
            f"{r['iters']} / {r['windows_iters']} | {w('PREP'):.0f} | {w('SOLVE'):.0f} ({r['solve_frames']}; {r['solve_frame_ms']:.0f}) | "
            f"{r['dom_gpu_ms']:.0f} ({r['dom_chunks']}; {r['dom_chunk_gpu_ms_mean']:.1f}) | {r['gpu_gap_sum_ms']:.0f} | {w('BUILD'):.0f} | "
            f"{w('W:w0:prep'):.0f}/{w('W:w0:gpu'):.0f}/{w('W:w0:field'):.0f}; {w('W:w1:prep'):.0f}/{w('W:w1:gpu'):.0f}/{w('W:w1:field'):.0f} | "
            f"{r['frame_max_before_ms']:.0f} / {r['frame_max_after_ms']:.0f} |")
    if trows:
        L += ["", "## Прототип: решатель области в своём потоке (игра рисует)", "",
              "| прогон | окно | кадр покоя / отрисовка GPU, мс | подготовка, мс | решатель (стена), мс | GPU, мс | запись CPU, мс | порций (макс. порция, мс) | итераций | кадр во время: ср. / p95 / макс, мс | отрисовка GPU во время, мс |",
              "|---|---|---|---|---|---|---|---|---|---|---|"]
        for r in trows:
            L.append(
                f"| {r['name']} | {r['window']} | {r['idle_frame_ms']:.0f} / {r['idle_render_gpu_ms']:.0f} | {r['prep_ms']:.0f} | {r['solve_wall_ms']:.0f} | "
                f"{r['gpu_ms']:.0f} | {r['record_cpu_ms']:.0f} | {r['chunks']} ({r['max_chunk_gpu_ms']:.1f}) | {r['iters']} | "
                f"{r['solve_frame_ms']:.0f} / {r['solve_frame_p95_ms']:.0f} / {r['solve_frame_max_ms']:.0f} | {r['solve_render_gpu_ms']:.0f} |")
    if therm:
        L += ["", "## AirThermals.build (грубейший уровень, главный поток и WorkerThreadPool)", "",
              "| прогон | build в главном, мс | _update_air, мс | в рабочем потоке: стена мс / макс. кадр мс / совпало |", "|---|---|---|---|"]
        for k, t in therm.items():
            thr = "; ".join(f"{x['wall_ms']:.0f}/{x['frame_max_ms']:.0f}/{'да' if x['same_as_main'] else 'нет'}" for x in t["thread"])
            L.append(f"| {k} | {', '.join(f'{x:.0f}' for x in t['main_build_ms'])} | {', '.join(f'{x:.0f}' for x in t['update_air_ms'])} | {thr} |")
    open(os.path.join(OUT, "breakdown.md"), "w").write("\n".join(L) + "\n")
    print("\n".join(L))


if __name__ == "__main__":
    main()
