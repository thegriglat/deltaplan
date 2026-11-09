#!/usr/bin/env python3
"""Сводка TB5 v3 (tb5/3) из сырых json flight_probe.gd и flight_frame.gd.

    flight_summary.py <tag> <probe.json> <frame.json> <out.json>

commit — git short HEAD текущей копии; запись одним переименованием (временный файл).
"""
import json
import os
import subprocess
import sys


def main() -> int:
    tag, probe_p, frame_p, out_p = sys.argv[1:5]
    probe = json.load(open(probe_p))
    frame = json.load(open(frame_p))
    commit = subprocess.run(
        ["git", "rev-parse", "--short", "HEAD"], capture_output=True, text=True
    ).stdout.strip()
    out = {
        "schema": "tb5/3",
        "tag": tag,
        "commit": commit,
        "location": probe["location"],
        "weather": probe["weather"],
        "bubble": probe["bubble"],
        "sim_s": probe["sim_s"],
        "frames": probe["frames"],
        "presence": probe["presence"],
        "inflow": probe["inflow"],
        "core": probe["core"],
        "continuity": probe["continuity"],
        "frame": {
            k: frame[k] for k in ("ms_mean", "ms_p99", "ms_max", "hitch_50ms")
        },
        "notes": {
            "frame_sim_s": frame.get("sim_s"),
            "frame_n": frame.get("n"),
            "frame_end": frame.get("end"),
            "diag": probe.get("diag"),
            "probe_relaunches": probe.get("relaunches"),
            "probe_n_observed_cores": probe["presence"].get("n_observed"),
        },
    }
    tmp = out_p + ".tmp"
    with open(tmp, "w") as f:
        json.dump(out, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, out_p)
    print("записан", out_p)
    return 0


if __name__ == "__main__":
    sys.exit(main())
