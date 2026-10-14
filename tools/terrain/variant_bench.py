#!/usr/bin/env python3
"""Замер «эффект → мс» по вариантам шейдера рельефа (контракт SL-К6, scene-look).

Части шейдера — блоки `#ifndef T_<ЧАСТЬ>_OFF` в scripts/terrain/terrain_main.gdshaderinc и его
include-ах (список строится по коду, не вручную). Для каждой части пишется временный вариант
scripts/terrain/variants/_bench/terrain_no_<часть>.gdshader (одна строка #define, не коммитится).
Замер — стенд tools/terrain/shots.sh (terrain_preview --bench-static, Онгудай kayancha_south, AGL 800,
1920x1080 fullscreen, --gpu-profile): по одному прогону на (пресет, вариант[, режим]). Пресет —
world/vegetation/atmosphere/world_objects-конфиги пресета (tools/terrain/variant_setup.tscn →
GraphicsPresets.select); viewport-часть пресета (scale_3d/FSR, MSAA, атлас теней) стенд НЕ применяет.

  python3 tools/terrain/variant_bench.py parts                 # список частей (define → вариант)
  python3 tools/terrain/variant_bench.py gen                   # только записать _bench-варианты
  .dpcli/dpcli lock gpu terrain-variants -- \\
    python3 tools/terrain/variant_bench.py run --out=build/variant_bench \\
      [--presets=low,medium,high] [--variants=full,min,no_sl_light,preset,...] [--relief] [--frames=120]
      [--no-warm] [--repeat=N]
  (вариант "preset" — как в игре: variant/variant_far пресета; "full+far" — ближний + дальний;
   имя закоммиченного варианта — как есть, иное — _bench/<имя>)
  python3 tools/terrain/variant_bench.py summary --out=build/variant_bench

run продолжает с места (results.jsonl: строка на прогон; уже снятые пропускаются), в конце пишет
summary.csv / summary.md (мс кадра и «цена части» = no_X − full со знаком минус: сколько снимает
выключение). Профиль Godot — постоянный ~/.cache/dp-xdg/<копия> (кэш шейдеров); в конце вариант
в профиле возвращается на "full". Запускать только под .dpcli/dpcli lock gpu (замер GPU — один на машину).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TERRAIN_DIR = ROOT / "scripts/terrain"
MAIN = TERRAIN_DIR / "terrain_main.gdshaderinc"
FULL = TERRAIN_DIR / "terrain.gdshader"
VARIANTS = TERRAIN_DIR / "variants"
BENCH_DIR = VARIANTS / "_bench"
INC_RE = re.compile(r'#include\s+"res://([^"]+)"')
PART_RE = re.compile(r"#ifndef\s+(T_[A-Z0-9_]+_OFF)\b")
BENCH_ARGS = ["--location=ongudai", "--site=kayancha_south", "--agl=800", "--clearings"]
RELIEF_ARGS = ["--no-trees", "--no-grass", "--no-haze"]
PRESET = "preset"   # вариант «как в игре»: variant/variant_far пресета, без подмены


def _sources() -> list[Path]:
    """terrain_main и все include-ы (рекурсивно), в порядке подключения."""
    seen: list[Path] = []

    def walk(p: Path) -> None:
        if p in seen or not p.exists():
            return
        seen.append(p)
        for m in INC_RE.finditer(p.read_text(encoding="utf-8")):
            walk(ROOT / m.group(1))

    walk(MAIN)
    return seen


def parts() -> list[str]:
    out: list[str] = []
    for p in _sources():
        for m in PART_RE.finditer(p.read_text(encoding="utf-8")):
            if m.group(1) not in out:
                out.append(m.group(1))
    return out


def part_variant(define: str) -> str:
    return "_bench/no_" + define[2:-4].lower()


def header() -> list[str]:
    """shader_type/render_mode варианта «full» (SL-К6 v2: в каждом файле варианта)."""
    return [
        ln
        for ln in FULL.read_text(encoding="utf-8").splitlines()
        if ln.startswith("shader_type") or ln.startswith("render_mode")
    ]


def gen() -> dict[str, str]:
    BENCH_DIR.mkdir(parents=True, exist_ok=True)
    inc = '#include "res://scripts/terrain/terrain_main.gdshaderinc"'
    out = {}
    for d in parts():
        v = part_variant(d)
        f = VARIANTS / (v.replace("no_", "terrain_no_", 1) + ".gdshader")
        f.write_text("\n".join(header() + [f"#define {d}", inc, ""]), encoding="utf-8")
        out[v] = d
    return out


def _godot(args: list[str], timeout_s: int, headless: bool = False) -> str:
    env = dict(os.environ)
    env["XDG_DATA_HOME"] = str(Path.home() / ".cache/dp-xdg" / ROOT.name)
    env.setdefault("DISPLAY", ":0")
    cmd = ["systemd-run", "--user", "--scope", "-q", "-p", "MemoryMax=8G", "-p", "MemorySwapMax=0",
           "timeout", str(timeout_s), "godot", "--path", str(ROOT)]
    if headless:
        cmd += ["--headless"]
    else:
        cmd += ["--audio-driver", "Dummy", "--resolution", "1920x1080", "--fullscreen", "--gpu-profile"]
    r = subprocess.run(cmd + args, env=env, capture_output=True, text=True, cwd=ROOT)
    return r.stdout + r.stderr


def _setup(preset: str | None, variant: str) -> None:
    # "preset" — варианты как в игре: terrain.variant / variant_far из пресета (GraphicsPresets.select)
    a = ["res://tools/terrain/variant_setup.tscn", "--"]
    if variant != PRESET:
        near, _, far = variant.partition("+")   # "full+far" — ближний + дальний (LOD ≥ variant_far_lod)
        a += [f"--variant={near}", f"--variant-far={far}"]
    if preset:
        a.insert(2, f"--preset={preset}")
    log = _godot(a, 120, headless=True)
    if "-> ok" not in log:
        sys.exit(f"variant_setup {preset} {variant}: ошибка\n{log[-2000:]}")


def _bench(frames: int, relief: bool) -> tuple[dict | None, str]:
    a = ["res://scenes/terrain/terrain_preview.tscn", "--", *BENCH_ARGS, f"--bench-static={frames}"]
    if relief:
        a += RELIEF_ARGS
    log = _godot(a, 300)
    for ln in log.splitlines():
        if "BENCH_STATIC_JSON:" in ln:
            return json.loads(ln.split("BENCH_STATIC_JSON:", 1)[1]), log
    return None, log


def run(o: argparse.Namespace) -> None:
    out = Path(o.out)
    if not out.is_absolute():
        out = ROOT / out
    out.mkdir(parents=True, exist_ok=True)
    gen()
    all_v = ["full", "min"] + [part_variant(d) for d in parts()]
    variants = all_v
    if o.variants:
        want = [v.strip() for v in o.variants.split(",") if v.strip()]
        def norm(v: str) -> str:
            if v in ("full", "min", PRESET, "") or v.startswith("_bench/") or (VARIANTS / f"terrain_{v}.gdshader").exists():
                return v
            return "_bench/" + v

        variants = ["+".join(norm(x) for x in v.split("+")) for v in want]
    presets = [p.strip() for p in o.presets.split(",") if p.strip()]
    modes = ["full", "relief"] if o.relief else ["full"]
    res_path = out / "results.jsonl"
    done = set()
    if res_path.exists():
        for ln in res_path.read_text(encoding="utf-8").splitlines():
            if ln.strip():
                r = json.loads(ln)
                done.add((r["preset"], r["variant"], r["mode"], int(r.get("rep", 0))))
    # --repeat=N: N кругов по всем вариантам подряд (A B C A B C …) — шум и дрейф видны по кругам
    plan = [(p, v, m, k) for k in range(o.repeat) for p in presets for v in variants for m in modes
            if (p, v, m, k) not in done]
    print(f"variant_bench: {len(plan)} прогонов (всего {o.repeat * len(presets) * len(variants) * len(modes)}), выход {out}")
    t0 = time.time()
    warmed: set[str] = set()
    cur = None
    for i, (p, v, m, k) in enumerate(plan):
        if cur != (p, v):
            _setup(p, v)
            cur = (p, v)
        if not o.no_warm and v not in warmed:
            _bench(10, False)   # прогрев: компиляция шейдера варианта в кэш профиля
            warmed.add(v)
        r, log = _bench(o.frames, m == "relief")
        rec = {"preset": p, "variant": v, "mode": m, "rep": k, "t": time.strftime("%Y-%m-%d %H:%M:%S")}
        if r is None:
            rec["error"] = "нет BENCH_STATIC_JSON"
            rec["shader_error"] = "SHADER ERROR" in log
            (out / f"fail_{p}_{v.replace('/', '_')}_{m}.log").write_text(log, encoding="utf-8")
        else:
            rec.update({q: r.get(q) for q in ("gpu_ms_mean", "gpu_ms_p95", "gpu_ms_p10", "n", "w", "draw_calls", "passes",
                                          "vram_tex_mb", "vram_mb")})
        with res_path.open("a", encoding="utf-8") as f:
            f.write(json.dumps(rec, ensure_ascii=False) + "\n")
        el = time.time() - t0
        print(f"[{i + 1}/{len(plan)}] {p} {v} {m}: {rec.get('gpu_ms_mean', rec.get('error'))} "
              f"(прошло {el:.0f} с, осталось ~{el / (i + 1) * (len(plan) - i - 1):.0f} с)", flush=True)
    _setup(None, "full")
    summary(out)


def summary(out: Path) -> None:
    out = Path(out)
    if not out.is_absolute():
        out = ROOT / out
    runs: dict[tuple[str, str, str], list[dict]] = {}
    for ln in (out / "results.jsonl").read_text(encoding="utf-8").splitlines():
        if ln.strip():
            r = json.loads(ln)
            runs.setdefault((r["preset"], r["variant"], r["mode"]), []).append(r)
    # несколько кругов (--repeat) — среднее по прогонам с числом
    rows: dict[tuple[str, str, str], dict] = {}
    for key, rs in runs.items():
        xs = [float(r["gpu_ms_mean"]) for r in rs if r.get("gpu_ms_mean") is not None]
        rows[key] = {"gpu_ms_mean": sum(xs) / len(xs) if xs else None}
    presets = list(dict.fromkeys(k[0] for k in rows))
    modes = list(dict.fromkeys(k[2] for k in rows))
    variants = list(dict.fromkeys(k[1] for k in rows))
    defs = {part_variant(d): d for d in parts()}
    cols = [(p, m) for p in presets for m in modes]

    def ms(p: str, v: str, m: str) -> float | None:
        r = rows.get((p, v, m))
        return None if r is None or r.get("gpu_ms_mean") is None else float(r["gpu_ms_mean"])

    lines_csv = ["variant,define," + ",".join(f"{p}_{m}_ms,{p}_{m}_saving_ms" for p, m in cols)]
    head = "| вариант | define | " + " | ".join(f"{p} {m}, мс (снимает)" for p, m in cols) + " |"
    lines_md = [head, "|" + "---|" * (2 + len(cols))]
    for v in variants:
        cells_csv, cells_md = [], []
        for p, m in cols:
            x, f = ms(p, v, m), ms(p, "full", m)
            s = None if x is None or f is None or v == "full" else f - x
            cells_csv += ["" if x is None else f"{x:.3f}", "" if s is None else f"{s:.3f}"]
            cells_md.append("—" if x is None else (f"{x:.2f}" + ("" if s is None else f" ({s:+.2f})")))
        lines_csv.append(f"{v},{defs.get(v, '')}," + ",".join(cells_csv))
        lines_md.append(f"| {v} | {defs.get(v, '')} | " + " | ".join(cells_md) + " |")
    (out / "summary.csv").write_text("\n".join(lines_csv) + "\n", encoding="utf-8")
    note = ("\n\nGPU кадра, мс (bench-static, Онгудай kayancha_south AGL 800, 1920x1080; один прогон на вариант). "
            "В скобках — сколько снимает выключение части (full − вариант); шум замера 0,2–0,6 мс. "
            "Пресет — world-конфиги пресета; viewport-часть (scale_3d/FSR, MSAA, атлас теней) стенд не применяет.\n")
    (out / "summary.md").write_text("\n".join(lines_md) + note, encoding="utf-8")
    print("\n".join(lines_md))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sp = ap.add_subparsers(dest="cmd", required=True)
    sp.add_parser("parts")
    sp.add_parser("gen")
    r = sp.add_parser("run")
    r.add_argument("--out", default="build/variant_bench")
    r.add_argument("--presets", default="low,medium,high")
    r.add_argument("--variants", default="")
    r.add_argument("--relief", action="store_true")
    r.add_argument("--frames", type=int, default=120)
    r.add_argument("--no-warm", action="store_true")
    r.add_argument("--repeat", type=int, default=1)
    s = sp.add_parser("summary")
    s.add_argument("--out", default="build/variant_bench")
    o = ap.parse_args()
    if o.cmd == "parts":
        for d in parts():
            print(f"{d}\t{part_variant(d)}")
    elif o.cmd == "gen":
        for v, d in gen().items():
            print(f"{v}\t{d}")
    elif o.cmd == "run":
        run(o)
    else:
        summary(Path(o.out))


if __name__ == "__main__":
    main()
