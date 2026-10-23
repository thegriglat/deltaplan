#!/usr/bin/env python3
"""Собирает result.json из мер: measure_frames.py (кадры), sizes_top.py (вид сверху), mask_sim.py (реплика маски).

    uv run --with numpy --with scipy --with pillow python make_result.py --shots=<build/screenshots/cloud-look/CLK-2>

Ключи для приёмки CLK-2: banding_ratio_09, banding_ratio_34, edge_noise_ratio_09, size_p90_p10 (после, вид сверху).
"""
import json
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent


def run(args):
    r = subprocess.run([sys.executable, "-I", *map(str, args)], capture_output=True, text=True, check=True)
    return r.stdout


def main():
    o = dict(a.lstrip("-").split("=", 1) for a in sys.argv[1:] if "=" in a)
    shots = Path(o["shots"])
    res = {}
    run([HERE / "measure_frames.py", "--warm=%s" % (shots / "warm"), "--nocloud=%s" % (shots / "nocloud_1080"), "--json=%s" % (HERE / "frames.json")])
    fr = json.loads((HERE / "frames.json").read_text())
    for k, v in fr.items():
        if not k.startswith("detail"):
            res[k] = v
    res["frames_detail"] = {k: v for k, v in fr.items() if k.startswith("detail")}
    sizes = {}
    for tag in ("before", "after"):
        sizes[tag] = json.loads(run([HERE / "sizes_top.py", "--dir=%s" % (shots / "top"), "--tag=%s" % tag]))
    res["size_p90_p10"] = sizes["after"]["size_p90_p10"]
    res["size_p90_p10_before"] = sizes["before"]["size_p90_p10"]
    res["sizes_top"] = sizes
    sys.path.insert(0, str(HERE))
    import mask_sim

    res["mask_sim"] = [mask_sim.sizes(c, 2500.0, legacy=lg) for c in (0.17, 0.33) for lg in (True, False)]
    (HERE / "result.json").write_text(json.dumps(res, indent=1, ensure_ascii=False) + "\n")
    print(json.dumps({k: v for k, v in res.items() if not isinstance(v, (dict, list))}, ensure_ascii=False))


if __name__ == "__main__":
    main()
